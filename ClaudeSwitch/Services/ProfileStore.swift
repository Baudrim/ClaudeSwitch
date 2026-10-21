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
    /// Parent of the per-account Claude data folders used to run accounts side by side.
    private let sideBySideRoot: String

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
        self.sideBySideRoot = (snapshotsRoot as NSString).deletingLastPathComponent + "/side-by-side"
        try? fm.createDirectory(atPath: snapshotsRoot, withIntermediateDirectories: true)
    }

    var liveConfigPath: String { liveDir + "/config.json" }

    /// Last time Claude wrote its config.json. It does so on every launch and token refresh, so
    /// this tells how recently the live session was used.
    var liveSessionModifiedAt: Date? {
        (try? fm.attributesOfItem(atPath: liveConfigPath))?[.modificationDate] as? Date
    }

    func snapshotCapturedAt(for id: UUID) -> Date? {
        guard let data = fm.contents(atPath: snapshotDir(for: id) + "/" + SnapshotFile.metadata),
              let metadata = try? JSONDecoder().decode(SnapshotMetadata.self, from: data) else { return nil }
        return metadata.capturedAt
    }

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

    /// Clears the live account's identity (config identity keys + cookies + web storage) so the
    /// next launch lands on Claude's login screen. Deliberately does NOT touch saved snapshots or
    /// perform a server-side logout, so an already-captured account stays restorable and valid.
    /// Call only while Claude is NOT running.
    func clearLiveSession() throws {
        var liveJSON = readJSONObject(atPath: liveConfigPath) ?? [:]
        for key in Self.identityKeys { liveJSON.removeValue(forKey: key) }
        try writeJSONObject(liveJSON, toPath: liveConfigPath)

        for name in SnapshotFile.cookieFiles {
            try? fm.removeItem(atPath: liveDir + "/" + name)
        }
        for name in SnapshotFile.storageDirectories {
            try? fm.removeItem(atPath: liveDir + "/" + name)
        }
        log.info("[clearLiveSession] Cleared live account identity")
    }

    func deleteSnapshot(for id: UUID) {
        try? fm.removeItem(atPath: snapshotDir(for: id))
        log.info("[deleteSnapshot] Removed snapshot for \(id)")
    }

    // MARK: - Side by Side

    /// Claude data folder `id` uses when running side by side with the main instance (passed to
    /// Claude as `--user-data-dir`), so both can stay signed into different accounts at once.
    func sideBySideDir(for id: UUID) -> String {
        sideBySideRoot + "/" + id.uuidString
    }

    /// Inverse of `sideBySideDir(for:)`: which account a running instance's data folder belongs to.
    func sideBySideAccountId(forDataDir path: String) -> UUID? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == URL(fileURLWithPath: sideBySideRoot).standardizedFileURL.path else {
            return nil
        }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Makes sure `id`'s side-by-side data folder holds its freshest session, and returns it.
    /// The folder is seeded from the snapshot the first time, and again whenever the snapshot is
    /// newer (the account was used, then re-captured, in the main instance since). Otherwise it
    /// is left alone: the side-by-side session is itself the freshest copy.
    /// Call only while that side-by-side instance is NOT running.
    func prepareSideBySide(for id: UUID) throws -> String {
        let instance = sideBySideStore(for: id)
        let snapshotDate = snapshotCapturedAt(for: id) ?? .distantPast
        let sessionDate = instance.liveSessionModifiedAt ?? .distantPast
        if instance.readLiveAccountId() != id || snapshotDate > sessionDate {
            do {
                try fm.createDirectory(atPath: instance.liveDir, withIntermediateDirectories: true)
            } catch {
                throw ProfileStoreError.ioFailure(error.localizedDescription)
            }
            try instance.restore(id: id)
            log.info("[prepareSideBySide] Seeded side-by-side folder for \(id) from its snapshot")
        }
        return instance.liveDir
    }

    /// Copies `id`'s side-by-side session back into its snapshot when it is the fresher of the
    /// two, so switching the main instance to that account picks up where the side-by-side
    /// window left off instead of restoring stale tokens.
    /// Call only while that side-by-side instance is NOT running.
    func syncSnapshotFromSideBySide(id: UUID) {
        let instance = sideBySideStore(for: id)
        guard instance.readLiveAccountId() == id,
              let sessionDate = instance.liveSessionModifiedAt,
              sessionDate > snapshotCapturedAt(for: id) ?? .distantPast else { return }
        do {
            try instance.capture(id: id)
        } catch {
            log.warning("[syncSnapshotFromSideBySide] Failed for \(id): \(error.localizedDescription)")
        }
    }

    func deleteSideBySideData(for id: UUID) {
        try? fm.removeItem(atPath: sideBySideDir(for: id))
    }

    /// A store whose "live" profile is `id`'s side-by-side folder, so the same capture/restore
    /// logic can seed that folder from the snapshot or sync it back.
    private func sideBySideStore(for id: UUID) -> ProfileStore {
        ProfileStore(liveDir: sideBySideDir(for: id), snapshotsRoot: snapshotsRoot)
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
