import Foundation

/// A captured Claude desktop account, identified by the app's own `lastKnownAccountUuid`
/// (found in `~/Library/Application Support/Claude/config.json`). We never learn the
/// account's email locally -- the user labels each account themselves.
struct DesktopAccount: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var isActive: Bool
    var lastUsed: Date?
    let createdAt: Date

    init(
        id: UUID,
        label: String,
        isActive: Bool = false,
        lastUsed: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.isActive = isActive
        self.lastUsed = lastUsed
        self.createdAt = createdAt
    }

    /// Falls back to a short, stable name derived from the UUID if the user hasn't labeled it yet.
    var effectiveLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Account \(id.uuidString.prefix(4))"
            : label
    }
}
