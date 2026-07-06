import Foundation

/// A user-facing error paired with an optional one-tap recovery action, so the UI can offer
/// "Open Claude" or "Choose App…" instead of just a dead-end message.
struct ActionableError: Identifiable {
    enum Recovery {
        case openClaude
        case selectAppLocation
        case openAutomationSettings
    }

    let id = UUID()
    let message: String
    let recovery: Recovery?

    init(message: String, recovery: Recovery? = nil) {
        self.message = message
        self.recovery = recovery
    }

    init(_ error: Error) {
        switch error {
        case ClaudeDesktopError.notInstalled:
            self.init(
                message: ClaudeDesktopError.notInstalled.errorDescription ?? "Claude isn't installed.",
                recovery: .selectAppLocation
            )
        case ClaudeDesktopError.notLoggedIn:
            self.init(
                message: ClaudeDesktopError.notLoggedIn.errorDescription ?? "Not logged in.",
                recovery: .openClaude
            )
        case ClaudeDesktopError.automationPermissionDenied:
            self.init(
                message: ClaudeDesktopError.automationPermissionDenied.errorDescription ?? "Automation permission needed.",
                recovery: .openAutomationSettings
            )
        case ClaudeDesktopError.invalidAppSelection:
            self.init(
                message: ClaudeDesktopError.invalidAppSelection.errorDescription ?? "That's not Claude.",
                recovery: .selectAppLocation
            )
        default:
            self.init(message: error.localizedDescription)
        }
    }
}
