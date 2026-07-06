import AppKit
import Foundation

private let log = FileLog("Automation")

/// Checks (and, on first use, prompts for) the TCC "Automation" permission ClaudeSwitch needs
/// to send Claude a Quit Apple event. Without it, `NSRunningApplication.terminate()` silently
/// does nothing, so we resolve the permission up front and surface a clear, recoverable error
/// instead of falling back to a hard kill that could corrupt the outgoing account's cookie DB.
enum AutomationPermission {
    enum Status {
        case authorized
        case denied
    }

    /// Determines whether we may send a Quit event to `bundleIdentifier`, prompting the user the
    /// first time. Must run off the main thread: `AEDeterminePermissionToAutomateTarget` can
    /// block on the TCC prompt and is documented to occasionally deadlock on the main thread.
    static func requestQuitPermission(for bundleIdentifier: String) async -> Status {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: determine(bundleIdentifier))
            }
        }
    }

    private static func determine(_ bundleIdentifier: String) -> Status {
        guard let bundleData = bundleIdentifier.data(using: .utf8) else { return .denied }

        var target = AEAddressDesc()
        let createStatus = bundleData.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, bundleData.count, &target)
        }
        guard createStatus == noErr else {
            log.error("[determine] AECreateDesc failed: \(createStatus)")
            return .denied
        }
        defer { AEDisposeDesc(&target) }

        // askUserIfNeeded: true -> prompts on first run, then returns noErr (allowed) or
        // errAEEventNotPermitted (denied). procNotFound means Claude isn't running, in which
        // case no quit event is needed and we can safely proceed.
        let status = AEDeterminePermissionToAutomateTarget(
            &target, kCoreEventClass, kAEQuitApplication, true
        )

        switch status {
        case noErr, OSStatus(procNotFound):
            return .authorized
        case OSStatus(errAEEventNotPermitted):
            log.warning("[determine] Automation permission denied for \(bundleIdentifier)")
            return .denied
        default:
            log.warning("[determine] Unexpected AEDeterminePermission status: \(status)")
            return .denied
        }
    }

    /// Opens System Settings directly at Privacy & Security > Automation.
    @MainActor
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
