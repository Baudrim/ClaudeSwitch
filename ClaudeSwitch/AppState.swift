import Foundation
import Observation

private let log = FileLog("AppState")

/// Central app state: the list of captured Claude desktop accounts, which one is active, and
/// the add/switch/rename/remove actions the UI drives. All Claude.app lifecycle and snapshot
/// I/O is delegated to `ClaudeDesktopService` / `ProfileStore`; this class just orchestrates
/// them and persists lightweight account metadata (never tokens) to `UserDefaults`.
// Observation (@Observable) rather than ObservableObject: its per-property access tracking is
// reliable through a MenuBarExtra(.window) scene, where Combine-based ObservableObject updates
// are dropped and leave the popover showing stale content after first appearance.
@MainActor
@Observable
final class AppState {
    private(set) var accounts: [DesktopAccount] = []
    private(set) var isBusy = false
    private(set) var busyMessage: String?
    private(set) var isClaudeInstalled = false
    var lastError: ActionableError?

    @ObservationIgnored private let store = ProfileStore()
    @ObservationIgnored private lazy var desktop = ClaudeDesktopService(store: store)
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let accountsKey = "com.claudeswitch.accounts"

    var activeAccount: DesktopAccount? { accounts.first(where: \.isActive) }
    var hasManualClaudeAppOverride: Bool { desktop.hasManualAppOverride }
    var resolvedClaudeAppPath: String? { desktop.resolvedAppPath }

    init() {
        loadAccounts()
        refreshInstallState()
    }

    /// Re-checks whether Claude.app can be found. Call whenever the menu/settings reopen, or
    /// after the user picks (or resets) a manual app location, since Launch Services state can
    /// change without us being notified.
    func refreshInstallState() {
        isClaudeInstalled = desktop.isInstalled
    }

    // MARK: - Add / Refresh

    /// The account id Claude is currently signed into on disk, if any -- a cheap, non-destructive
    /// read used to detect duplicates before the user commits to adding an account.
    func currentLiveAccountId() -> UUID? {
        desktop.readLiveAccountId()
    }

    func existingAccount(for id: UUID) -> DesktopAccount? {
        accounts.first { $0.id == id }
    }

    /// Captures whichever account is currently logged into Claude and saves it under `label`.
    /// Fails with `.notLoggedIn` if Claude has never signed in (no `lastKnownAccountUuid` yet).
    /// If that account was already saved, this just refreshes its snapshot under the new label
    /// rather than creating a duplicate entry.
    func addCurrentAccount(label: String) async {
        await run(busyMessage: "Adding account…") {
            guard let id = self.desktop.readLiveAccountId() else {
                throw ClaudeDesktopError.notLoggedIn
            }
            try await self.desktop.captureCurrentSession(id: id)
            self.upsert(id: id, label: label, markActive: true)
        }
    }

    /// Launches Claude (or brings it to the front) so the user can sign in before adding an
    /// account -- the recovery action offered when `.notLoggedIn` is surfaced.
    func launchClaudeIfNeeded() async {
        do {
            try await desktop.launchOrActivate()
            lastError = nil
        } catch {
            lastError = ActionableError(error)
        }
    }

    // MARK: - Claude App Location

    func selectClaudeApp(at url: URL) async {
        do {
            try desktop.setManualAppURL(url)
            refreshInstallState()
            lastError = nil
        } catch {
            lastError = ActionableError(error)
        }
    }

    func resetClaudeAppLocation() {
        desktop.clearManualAppOverride()
        refreshInstallState()
    }

    /// Re-captures an already-known account's snapshot with whatever is currently live --
    /// useful if the token in an old snapshot has gone stale.
    func refreshActiveSnapshot() async {
        guard let active = activeAccount else { return }
        await run(busyMessage: "Refreshing \(active.effectiveLabel)…") {
            try await self.desktop.captureCurrentSession(id: active.id)
            self.touch(active.id)
        }
    }

    // MARK: - Switch

    func switchTo(_ account: DesktopAccount) async {
        guard account.id != activeAccount?.id else { return }
        await run(busyMessage: "Switching to \(account.effectiveLabel)…") {
            try await self.desktop.switchAccount(to: account, currentActiveId: self.activeAccount?.id)
            self.markActive(account.id)
        }
    }

    // MARK: - Manage

    func rename(_ account: DesktopAccount, to newLabel: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].label = newLabel
        saveAccounts()
    }

    func remove(_ account: DesktopAccount) {
        accounts.removeAll { $0.id == account.id }
        store.deleteSnapshot(for: account.id)
        saveAccounts()
    }

    /// Removes every saved account and its snapshot. Claude's own live session is untouched --
    /// this only clears what ClaudeSwitch stored, so the user can start over cleanly.
    func resetAll() {
        log.info("[resetAll] Removing \(accounts.count) account(s) and their snapshots")
        for account in accounts {
            store.deleteSnapshot(for: account.id)
        }
        accounts = []
        saveAccounts()
        lastError = nil
    }

    // MARK: - Internals

    private func run(busyMessage: String, _ operation: () async throws -> Void) async {
        isBusy = true
        self.busyMessage = busyMessage
        lastError = nil
        do {
            try await operation()
        } catch {
            log.error("Operation failed: \(error.localizedDescription)")
            lastError = ActionableError(error)
        }
        isBusy = false
        self.busyMessage = nil
        refreshInstallState()
    }

    private func upsert(id: UUID, label: String, markActive: Bool) {
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].label = label
        } else {
            accounts.append(DesktopAccount(id: id, label: label))
        }
        if markActive {
            self.markActive(id)
        } else {
            saveAccounts()
        }
    }

    private func markActive(_ id: UUID) {
        for idx in accounts.indices {
            let isTarget = accounts[idx].id == id
            accounts[idx].isActive = isTarget
            if isTarget { accounts[idx].lastUsed = Date() }
        }
        saveAccounts()
    }

    private func touch(_ id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].lastUsed = Date()
        saveAccounts()
    }

    private func loadAccounts() {
        guard let data = defaults.data(forKey: accountsKey) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        do {
            accounts = try JSONDecoder().decode([DesktopAccount].self, from: data)
            log.info("[loadAccounts] Loaded \(accounts.count) account(s)")
        } catch {
            log.error("[loadAccounts] Decode failed: \(error.localizedDescription)")
        }
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: accountsKey)
    }
}