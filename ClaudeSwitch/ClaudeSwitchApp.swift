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
            MenuBarIcon(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

/// The status bar glyph, with a small dot when a newer release is out. A View of its own (rather
/// than an inline Image) so Observation reliably re-renders the label when that changes.
private struct MenuBarIcon: View {
    let appState: AppState

    var body: some View {
        // Custom swap glyph matching the app icon's arrows. It renders correctly in the status
        // bar because the asset declares an 18pt intrinsic size and template rendering (a large
        // intrinsic size is what previously made a vector asset render oversized).
        if appState.availableUpdate != nil {
            Image(nsImage: Self.glyphWithDot)
        } else {
            Image("MenuBarSwap")
        }
    }

    /// The glyph with a dot in its top-right corner, set apart from it by a cut-out ring. Kept a
    /// template image, like system status items' badges, so it follows the menu bar's color.
    @MainActor private static let glyphWithDot: NSImage = {
        guard let glyph = NSImage(named: "MenuBarSwap") else { return NSImage() }
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            let diameter = rect.width * 0.36
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
