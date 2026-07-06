import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned by the delegate so it is created eagerly at launch: saved accounts load before the
    // menu bar popover is first opened. A `@StateObject` on the App would defer creation (and thus
    // `loadAccounts()`) until the scene closure is first evaluated, i.e. the first popover open.
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App runs as agent/accessory due to LSUIElement -- no Dock icon, no main window.
    }
}

@main
struct ClaudeSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // Pass appState explicitly as an observed dependency: SwiftUI fails to track a
            // scene-level environmentObject injected inside the MenuBarExtra(.window) closure, so
            // the popover would go stale after first appearance. The view re-injects it into the
            // environment for descendant rows.
            MenuContentView(appState: appDelegate.appState)
        } label: {
            // Custom swap glyph matching the app icon's arrows. It renders correctly in the
            // status bar because the asset declares an 18pt intrinsic size and template rendering
            // (a large intrinsic size is what previously made a vector asset render oversized).
            Image("MenuBarSwap")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
