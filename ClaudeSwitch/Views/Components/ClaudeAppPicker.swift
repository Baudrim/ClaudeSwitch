import AppKit
import UniformTypeIdentifiers

/// Shared "pick Claude.app manually" file panel, used from both the menu's error banner and
/// Settings when automatic detection (Launch Services lookup by bundle id) doesn't find it.
enum ClaudeAppPicker {
    @MainActor
    static func present(onPick: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Claude.app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPick(url)
        }
    }
}
