import AppKit
import Foundation

private let log = FileLog("ClaudeDesktop")

enum ClaudeDesktopError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case automationPermissionDenied
    case quitTimedOut
    case stillWorking
    case quitCancelled
    case launchFailed(String)
    case invalidAppSelection
    case store(ProfileStoreError)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude.app wasn't found automatically. If it's installed somewhere unusual, pick it manually."
        case .notLoggedIn:
            return "Claude isn't logged in to any account right now."
        case .automationPermissionDenied:
            return "ClaudeSwitch needs permission to quit Claude. Enable it under Automation in System Settings, then try again."
        case .quitTimedOut:
            return "Claude didn't quit in time -- it may be asking you to confirm in its window. Quit it manually, then try again."
        case .stillWorking:
            return "Claude is still working and didn't quit, so nothing was changed. Try again once its background tasks are done."
        case .quitCancelled:
            return "Stopped waiting for Claude -- nothing was changed."
        case .launchFailed(let reason):
            return "Couldn't relaunch Claude: \(reason)"
        case .invalidAppSelection:
            return "That doesn't look like Claude -- pick the actual Claude.app bundle."
        case .store(let underlying):
            return underlying.errorDescription
        }
    }
}

/// Drives Claude.app's lifecycle (quit/relaunch) around `ProfileStore` snapshot operations.
///
/// Claude keeps config.json, its cookie database, and web storage open (and partly
/// memory-mapped) for as long as it runs, so every capture/restore must happen with the app
/// fully quit -- there is no way to hot-swap accounts in a running Electron app the way the
/// Claude Code CLI re-reads its credentials on every invocation. Quitting and relaunching is a
/// deliberate, expected part of the switch here.
@MainActor
final class ClaudeDesktopService {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    private let store: ProfileStore
    private let defaults = UserDefaults.standard
    private let manualAppPathKey = "com.claudeswitch.manualAppPath"

    /// Called whenever the reason a quit is taking a while changes, so the UI can explain it.
    var onQuitHeld: (@MainActor (QuitHold) -> Void)?
    private var pendingQuitApp: NSRunningApplication?
    private var pendingQuitAction: PendingQuitAction?

    private enum PendingQuitAction {
        case stopWaiting
        case forceQuit
    }

    init(store: ProfileStore) {
        self.store = store
    }

    /// True once a manual override has been set (regardless of whether that path is still valid).
    var hasManualAppOverride: Bool { defaults.string(forKey: manualAppPathKey) != nil }

    /// Absolute path to the Claude.app bundle ClaudeSwitch will use, or nil if it can't find one
    /// -- either automatically via Launch Services, or via a manually chosen location.
    var resolvedAppPath: String? { resolvedAppURL()?.path }

    var isInstalled: Bool { resolvedAppURL() != nil }

    var isRunning: Bool { runningApp != nil }

    /// The main Claude instance: the one on Claude's default data folder, which is what switching
    /// swaps. Side-by-side instances run the same bundle but are launched with `--user-data-dir`,
    /// so they're excluded here and never quit by a switch.
    private var runningApp: NSRunningApplication? {
        runningInstances.first { userDataDir(of: $0) == nil }
    }

    private var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
    }

    private static let userDataDirFlag = "--user-data-dir="

    private func userDataDir(of app: NSRunningApplication) -> String? {
        ProcessArguments.of(pid: app.processIdentifier)?
            .first { $0.hasPrefix(Self.userDataDirFlag) }
            .map { String($0.dropFirst(Self.userDataDirFlag.count)) }
    }

    /// Manually points ClaudeSwitch at a specific Claude.app, for the (rare) case Launch Services
    /// can't find it automatically -- e.g. it lives outside /Applications or was never indexed.
    /// Verifies the picked bundle's identifier actually matches Claude before accepting it.
    func setManualAppURL(_ url: URL) throws {
        guard Bundle(url: url)?.bundleIdentifier == Self.bundleIdentifier else {
            throw ClaudeDesktopError.invalidAppSelection
        }
        defaults.set(url.path, forKey: manualAppPathKey)
        log.info("[setManualAppURL] Using \(url.path)")
    }

    func clearManualAppOverride() {
        defaults.removeObject(forKey: manualAppPathKey)
    }

    private func resolvedAppURL() -> URL? {
        if let manualPath = defaults.string(forKey: manualAppPathKey) {
            let url = URL(fileURLWithPath: manualPath)
            if FileManager.default.fileExists(atPath: manualPath) {
                return url
            }
            log.warning("[resolvedAppURL] Manual override no longer exists at \(manualPath)")
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    func readLiveAccountId() -> UUID? {
        store.readLiveAccountId()
    }

    /// Launches Claude if it isn't already running, or brings it to the front if it is.
    /// Used for the "Open Claude" recovery action when the user hasn't logged in yet.
    func launchOrActivate() async throws {
        if let app = runningApp {
            app.activate()
            return
        }
        try await launch()
    }

    /// Quits Claude, captures whatever session is currently live under `id`, then relaunches.
    /// Used both to onboard a freshly logged-in account and to refresh an existing snapshot
    /// with the latest cookies/tokens before switching away from it.
    func captureCurrentSession(id: UUID) async throws {
        try await quit()
        do {
            try store.capture(id: id)
        } catch let error as ProfileStoreError {
            try? await launch()
            throw ClaudeDesktopError.store(error)
        }
        try await launch()
    }

    /// Quits Claude, best-effort backs up whichever account was live (so its session stays
    /// fresh next time), restores `target`'s snapshot, then relaunches.
    func switchAccount(to target: DesktopAccount, currentActiveId: UUID?) async throws {
        try await quit()

        if let currentActiveId, currentActiveId != target.id {
            // Best-effort: a stale backup of the outgoing account is recoverable later;
            // failing the whole switch over it would not be.
            do {
                try store.capture(id: currentActiveId)
            } catch {
                log.warning("[switchAccount] Backing up outgoing account failed: \(error.localizedDescription)")
            }
        }

        // If the target was last used side by side, that session is fresher than its snapshot.
        if sideBySideApp(for: target.id) == nil {
            store.syncSnapshotFromSideBySide(id: target.id)
        }

        do {
            try store.restore(id: target.id)
        } catch let error as ProfileStoreError {
            try? await launch()
            throw ClaudeDesktopError.store(error)
        }

        try await launch()
    }

    /// Quits Claude, clears the live session so it reopens on the login screen, and relaunches --
    /// letting the user sign into a different account to add it. Safe for an already-saved account:
    /// its snapshot is untouched and there is no server-side logout, so it stays restorable.
    func logOutForNewAccount() async throws {
        try await quit()
        do {
            try store.clearLiveSession()
        } catch let error as ProfileStoreError {
            try? await launch()
            throw ClaudeDesktopError.store(error)
        }
        try await launch()
    }

    // MARK: - Side by Side

    /// Accounts currently open in their own side-by-side Claude instance.
    var runningSideBySideIds: Set<UUID> {
        Set(runningInstances.compactMap { app in
            userDataDir(of: app).flatMap(store.sideBySideAccountId(forDataDir:))
        })
    }

    /// Opens `id` in a second Claude instance with its own data folder, leaving the main instance
    /// (and its account) untouched -- so two accounts can be used at once. Brings that window
    /// forward instead if it's already open.
    func openSideBySide(_ id: UUID) async throws {
        if let app = sideBySideApp(for: id) {
            app.activate()
            return
        }
        let dataDir: String
        do {
            dataDir = try store.prepareSideBySide(for: id)
        } catch let error as ProfileStoreError {
            throw ClaudeDesktopError.store(error)
        }
        try await launch(arguments: [Self.userDataDirFlag + dataDir])
    }

    func activateSideBySide(_ id: UUID) {
        sideBySideApp(for: id)?.activate()
    }

    func closeSideBySide(_ id: UUID) async throws {
        guard let app = sideBySideApp(for: id) else { return }
        try await terminate(app)
    }

    private func sideBySideApp(for id: UUID) -> NSRunningApplication? {
        runningInstances.first { app in
            userDataDir(of: app).flatMap(store.sideBySideAccountId(forDataDir:)) == id
        }
    }

    // MARK: - Lifecycle

    private func quit() async throws {
        guard isInstalled else { throw ClaudeDesktopError.notInstalled }
        guard let app = runningApp else { return }
        try await terminate(app)
    }

    /// Asks `app` to quit and waits until it really has.
    ///
    /// Two things can hold that up, and both used to surface as a bare "didn't quit in time":
    /// - Claude's quit guard: while a session is working or running background commands, Claude
    ///   refuses to quit and asks the user instead ("Claude is still working": Quit Anyway / Wait
    ///   for Claude / Cancel). ClaudeSwitch can't answer that prompt for them, and force-killing
    ///   would lose that work, so it brings the prompt forward and waits for their call.
    /// - A slow exit: Claude hides its windows and runs its cleanup right away (its log reports it
    ///   done in well under a second), yet its process can stay alive for a while after that -- the
    ///   dimmed Dock dot. ClaudeSwitch keeps waiting, and offers to force quit, which is what users
    ///   otherwise did by hand; Claude's cleanup has already run by then.
    private func terminate(_ app: NSRunningApplication, patience: TimeInterval = 4) async throws {
        // Resolve the Automation permission before touching Claude. If the user denied it, stop
        // here with an actionable error rather than hard-killing Claude, which would skip its
        // graceful shutdown and risk leaving the outgoing account's cookie DB inconsistent.
        let permission = await AutomationPermission.requestQuitPermission(for: Self.bundleIdentifier)
        guard permission == .authorized else {
            throw ClaudeDesktopError.automationPermissionDenied
        }

        let claudeLog = ClaudeQuitLog()
        log.info("[quit] Terminating pid=\(app.processIdentifier)")
        app.terminate()

        // Quick path: most quits finish within a second or two.
        let quickDeadline = Date().addingTimeInterval(patience)
        while !app.isTerminated && Date() < quickDeadline && !claudeLog.contains(.vetoed) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if !app.isTerminated {
            try await waitWhileHeld(app, watching: claudeLog)
        }
        await settleAfterQuit()
    }

    /// Waits out a held-up quit, keeping the UI told why (via `onQuitHeld`) and honoring the
    /// user's Stop Waiting / Force Quit choices.
    private func waitWhileHeld(_ app: NSRunningApplication, watching claudeLog: ClaudeQuitLog, timeout: TimeInterval = 600) async throws {
        pendingQuitApp = app
        pendingQuitAction = nil
        defer {
            pendingQuitApp = nil
            pendingQuitAction = nil
        }

        var reported: QuitHold?
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isTerminated && Date() < deadline {
            // Once the user confirms in Claude's prompt, Claude starts its cleanup: from then on
            // it's simply closing, whatever held it up before.
            let hold: QuitHold = claudeLog.contains(.vetoed) && !claudeLog.contains(.cleanedUp, afterLast: .vetoed)
                ? .askingToConfirm
                : .stillClosing
            if hold != reported {
                log.info("[quit] Claude hasn't quit yet: \(hold)")
                reported = hold
                onQuitHeld?(hold)
                if hold == .askingToConfirm { app.activate() }
            }

            switch pendingQuitAction {
            case .stopWaiting:
                log.info("[quit] User stopped waiting for Claude")
                throw ClaudeDesktopError.quitCancelled
            case .forceQuit:
                log.warning("[quit] Force quitting pid=\(app.processIdentifier) at the user's request")
                app.forceTerminate()
                pendingQuitAction = nil
            case nil:
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard app.isTerminated else {
            log.warning("[quit] Claude still hadn't quit after \(Int(timeout))s")
            throw reported == .askingToConfirm ? ClaudeDesktopError.stillWorking : ClaudeDesktopError.quitTimedOut
        }
    }

    /// Brings the Claude instance being quit to the front (and with it, any prompt it's showing).
    func showClaudeBeingQuit() {
        pendingQuitApp?.activate()
    }

    func stopWaitingForQuit() {
        pendingQuitAction = .stopWaiting
    }

    func forceQuitPending() {
        pendingQuitAction = .forceQuit
    }

    /// Small grace period so the OS finishes flushing the cookie DB's write-ahead log after exit.
    private func settleAfterQuit() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func launch(arguments: [String] = []) async throws {
        guard let url = resolvedAppURL() else {
            throw ClaudeDesktopError.notInstalled
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.arguments = arguments
        // Callers only launch once the instance they want isn't running. Without this, Launch
        // Services would just bring forward whichever other Claude instance is already open.
        config.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            log.info("[launch] Claude launched")
        } catch {
            log.error("[launch] Failed: \(error.localizedDescription)")
            throw ClaudeDesktopError.launchFailed(error.localizedDescription)
        }
    }
}

/// Why a quit is taking a while, so the UI can say what's going on instead of just spinning.
enum QuitHold: Equatable {
    /// Claude is showing its "Claude is still working" prompt and waits for the user's answer.
    case askingToConfirm
    /// Claude has accepted the quit and cleaned up, but its process hasn't exited yet.
    case stillClosing
}

/// Reads what Claude writes to its main.log while quitting -- the only outside signal telling
/// its quit-guard prompt apart from a merely slow exit.
private struct ClaudeQuitLog {
    enum Marker: String {
        /// Claude's quit guard turned the quit down and is asking the user.
        case vetoed = "vetoed by before-quit interceptor"
        /// Claude finished its quit cleanup and is going down.
        case cleanedUp = "marking readyForQuit"
    }

    private static let path = NSHomeDirectory() + "/Library/Logs/Claude/main.log"

    /// Size of the log when watching started; only lines written after it count.
    private let startOffset: UInt64

    init() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.path)
        startOffset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func contains(_ marker: Marker) -> Bool {
        newLines()?.range(of: Data(marker.rawValue.utf8)) != nil
    }

    /// True if `marker` was logged after the last `other` (or at all, if `other` never was).
    func contains(_ marker: Marker, afterLast other: Marker) -> Bool {
        guard let data = newLines() else { return false }
        let start = data.range(of: Data(other.rawValue.utf8), options: .backwards)?.upperBound ?? data.startIndex
        return data.range(of: Data(marker.rawValue.utf8), in: start..<data.endIndex) != nil
    }

    private func newLines() -> Data? {
        guard let handle = FileHandle(forReadingAtPath: Self.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A smaller file means the log rotated since we started: read the new one from the top.
        try? handle.seek(toOffset: size < startOffset ? 0 : startOffset)
        return try? handle.readToEnd()
    }
}
