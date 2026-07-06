import Foundation

/// Describes the on-disk layout of a captured Claude desktop auth profile under
/// `~/Library/Application Support/ClaudeSwitch/snapshots/<uuid>/`. Every item here is copied
/// as opaque bytes -- ClaudeSwitch never decrypts Claude's "Claude Safe Storage" protected data.
enum SnapshotFile {
    /// Extracted subset of `config.json` (see `ProfileStore.identityKeys`) that identifies the
    /// account and its OAuth session, kept separate from the live app's unrelated settings.
    static let configFragment = "config-fragment.json"

    /// Chromium cookie store (SQLite) + its WAL/journal sidecars, copied together so a
    /// snapshot taken while the DB was mid-write-ahead-log still restores consistently.
    static let cookieFiles = ["Cookies", "Cookies-wal", "Cookies-journal"]

    /// Web storage directories that may carry additional session state.
    static let storageDirectories = ["Local Storage", "Session Storage"]

    static let metadata = "metadata.json"
}

/// Small sidecar written alongside every snapshot, useful for diagnostics (`Settings` panel,
/// logs) without needing to peek into the opaque captured files.
struct SnapshotMetadata: Codable {
    let accountId: UUID
    let capturedAt: Date
}
