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
            // SF Symbol matches the swap-arrows concept and is auto-sized/monochrome for the
            // status bar. A custom vector asset ignores frame constraints inside MenuBarExtra and
            // renders at its huge intrinsic size, so the symbol is the reliable choice here; the
            // colorful app icon stays reserved for Finder/About.
            Image(systemName: "arrow.left.arrow.right")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
