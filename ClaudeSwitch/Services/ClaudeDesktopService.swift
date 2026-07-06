import AppKit
import Foundation

private let log = FileLog("ClaudeDesktop")

enum ClaudeDesktopError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case automationPermissionDenied
    case quitTimedOut
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
            return "Claude didn't quit in time. Quit it manually, then try again."
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

    private var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first
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

        do {
            try store.restore(id: target.id)
        } catch let error as ProfileStoreError {
            try? await launch()
            throw ClaudeDesktopError.store(error)
        }

        try await launch()
    }

    // MARK: - Lifecycle

    private func quit(timeout: TimeInterval = 8) async throws {
        guard isInstalled else { throw ClaudeDesktopError.notInstalled }
        guard let app = runningApp else { return }

        // Resolve the Automation permission before touching Claude. If the user denied it, stop
        // here with an actionable error rather than hard-killing Claude, which would skip its
        // graceful shutdown and risk leaving the outgoing account's cookie DB inconsistent.
        let permission = await AutomationPermission.requestQuitPermission(for: Self.bundleIdentifier)
        guard permission == .authorized else {
            throw ClaudeDesktopError.automationPermissionDenied
        }

        log.info("[quit] Terminating pid=\(app.processIdentifier)")
        app.terminate()
        guard await waitUntilTerminated(app, timeout: timeout) else {
            log.warning("[quit] Claude did not quit within \(timeout)s")
            throw ClaudeDesktopError.quitTimedOut
        }
        await settleAfterQuit()
    }

    private func waitUntilTerminated(_ app: NSRunningApplication, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isTerminated && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return app.isTerminated
    }

    /// Small grace period so the OS finishes flushing the cookie DB's write-ahead log after exit.
    private func settleAfterQuit() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func launch() async throws {
        guard let url = resolvedAppURL() else {
            throw ClaudeDesktopError.notInstalled
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            log.info("[launch] Claude launched")
        } catch {
            log.error("[launch] Failed: \(error.localizedDescription)")
            throw ClaudeDesktopError.launchFailed(error.localizedDescription)
        }
    }
}
