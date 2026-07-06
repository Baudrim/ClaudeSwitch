import Foundation

private let log = FileLog("ProfileStore")

enum ProfileStoreError: LocalizedError {
    case liveProfileNotFound
    case snapshotNotFound
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .liveProfileNotFound:
            return "Claude's config.json wasn't found -- log in to Claude at least once first."
        case .snapshotNotFound:
            return "No saved snapshot for this account."
        case .ioFailure(let reason):
            return "Local file operation failed: \(reason)"
        }
    }
}

/// Captures and restores the subset of Claude desktop's on-disk state that identifies a
/// logged-in account, without ever decrypting it.
///
/// Claude (an Electron/Chromium app) protects its OAuth tokens and cookies with a
/// Keychain-backed encryption key ("Claude Safe Storage"), stable per machine. That means
/// ClaudeSwitch never needs to touch the Keychain or decrypt anything itself: swapping the
/// still-encrypted files in and out of Claude's profile directory is enough to switch identity,
/// exactly as CCSwitcher moves an opaque OAuth token blob for Claude Code.
///
/// All capture/restore operations must run while Claude is fully quit -- see
/// `ClaudeDesktopService`, which owns that lifecycle and calls into this store.
final class ProfileStore {
    private let fm = FileManager.default
    let liveDir: String
    private let snapshotsRoot: String

    /// `config.json` keys that together identify the logged-in account and its OAuth session.
    /// Only these are merged back on restore -- everything else in config.json (theme, locale,
    /// window state, extension settings, ...) always reflects the user's live app preferences.
    private static let identityKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]

    convenience init() {
        let home = NSHomeDirectory()
        self.init(
            liveDir: home + "/Library/Application Support/Claude",
            snapshotsRoot: home + "/Library/Application Support/ClaudeSwitch/snapshots"
        )
    }

    /// Test-only seam: lets validation exercise the real capture/restore logic against
    /// throwaway directories instead of the user's live Claude profile.
    init(liveDir: String, snapshotsRoot: String) {
        self.liveDir = liveDir
        self.snapshotsRoot = snapshotsRoot
        try? fm.createDirectory(atPath: snapshotsRoot, withIntermediateDirectories: true)
    }

    var liveConfigPath: String { liveDir + "/config.json" }

    /// Reads `lastKnownAccountUuid` from the live config, if Claude has ever logged in.
    /// Safe to call while Claude is running (this is a read, not a write).
    func readLiveAccountId() -> UUID? {
        guard let json = readJSONObject(atPath: liveConfigPath),
              let raw = json["lastKnownAccountUuid"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    func hasSnapshot(for id: UUID) -> Bool {
        fm.fileExists(atPath: snapshotDir(for: id))
    }

    /// Copies the live identity fragment + cookies + web storage into a snapshot folder for `id`.
    /// Call only while Claude is NOT running, so files are fully flushed to disk.
    func capture(id: UUID) throws {
        guard let liveJSON = readJSONObject(atPath: liveConfigPath) else {
            throw ProfileStoreError.liveProfileNotFound
        }

        let dir = snapshotDir(for: id)
        try? fm.removeItem(atPath: dir)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw ProfileStoreError.ioFailure(error.localizedDescription)
        }

        var fragment: [String: Any] = [:]
        for key in Self.identityKeys { fragment[key] = liveJSON[key] }
        try writeJSONObject(fragment, toPath: dir + "/" + SnapshotFile.configFragment)

        for name in SnapshotFile.cookieFiles {
            copyIfExists(from: liveDir + "/" + name, to: dir + "/" + name)
        }
        for name in SnapshotFile.storageDirectories {
            copyIfExists(from: liveDir + "/" + name, to: dir + "/" + name)
        }

        let metadata = SnapshotMetadata(accountId: id, capturedAt: Date())
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: URL(fileURLWithPath: dir + "/" + SnapshotFile.metadata))
        }

        log.info("[capture] Saved snapshot for \(id)")
    }

    /// Restores a previously captured snapshot into the live Claude profile, merging the
    /// identity keys into the existing config.json rather than overwriting it wholesale.
    /// Call only while Claude is NOT running.
    func restore(id: UUID) throws {
        let dir = snapshotDir(for: id)
        guard fm.fileExists(atPath: dir) else { throw ProfileStoreError.snapshotNotFound }

        guard let fragment = readJSONObject(atPath: dir + "/" + SnapshotFile.configFragment) else {
            throw ProfileStoreError.ioFailure("missing \(SnapshotFile.configFragment) in snapshot")
        }
        var liveJSON = readJSONObject(atPath: liveConfigPath) ?? [:]
        for key in Self.identityKeys {
            if let value = fragment[key] { liveJSON[key] = value }
        }
        try writeJSONObject(liveJSON, toPath: liveConfigPath)

        for name in SnapshotFile.cookieFiles {
            try? fm.removeItem(atPath: liveDir + "/" + name)
            copyIfExists(from: dir + "/" + name, to: liveDir + "/" + name)
        }
        for name in SnapshotFile.storageDirectories {
            try? fm.removeItem(atPath: liveDir + "/" + name)
            copyIfExists(from: dir + "/" + name, to: liveDir + "/" + name)
        }

        log.info("[restore] Restored snapshot for \(id)")
    }

    func deleteSnapshot(for id: UUID) {
        try? fm.removeItem(atPath: snapshotDir(for: id))
        log.info("[deleteSnapshot] Removed snapshot for \(id)")
    }

    // MARK: - Helpers

    private func snapshotDir(for id: UUID) -> String {
        snapshotsRoot + "/" + id.uuidString
    }

    private func readJSONObject(atPath path: String) -> [String: Any]? {
        guard let data = fm.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], toPath path: String) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw ProfileStoreError.ioFailure(error.localizedDescription)
        }
    }

    /// Copies a file or directory if the source exists, replacing any existing destination.
    /// Best-effort: cookie/storage sidecars are optional (e.g. no WAL file if cleanly closed).
    private func copyIfExists(from source: String, to destination: String) {
        guard fm.fileExists(atPath: source) else { return }
        try? fm.removeItem(atPath: destination)
        do {
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            log.warning("[copyIfExists] Failed copying \(source): \(error.localizedDescription)")
        }
    }
}
