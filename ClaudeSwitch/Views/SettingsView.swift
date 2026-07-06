import ServiceManagement
import SwiftUI

/// Native Settings window (⌘,). Kept intentionally small: launch-at-login, and quick access
/// to the local data ClaudeSwitch keeps (logs, snapshots) for troubleshooting.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        toggleLaunchAtLogin(enabled)
                    }
            }

            Section("Claude App Location") {
                LabeledContent("Detected at", value: appState.resolvedClaudeAppPath ?? "Not found")

                HStack {
                    Button("Choose…") {
                        ClaudeAppPicker.present { url in
                            Task { await appState.selectClaudeApp(at: url) }
                        }
                    }
                    if appState.hasManualClaudeAppOverride {
                        Button("Reset to Automatic") {
                            appState.resetClaudeAppLocation()
                        }
                    }
                }

                if let error = appState.lastError {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Accounts") {
                LabeledContent("Saved accounts", value: "\(appState.accounts.count)")

                Button("Reveal Snapshots in Finder") {
                    let path = NSHomeDirectory() + "/Library/Application Support/ClaudeSwitch/snapshots"
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }

                Button("Reset All Accounts…", role: .destructive) {
                    isConfirmingReset = true
                }
                .disabled(appState.accounts.isEmpty)
                .confirmationDialog(
                    "Remove all saved accounts?",
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Remove All", role: .destructive) {
                        appState.resetAll()
                    }
                } message: {
                    Text("All saved accounts and their snapshots will be deleted. Claude's current session is not affected, and you can re-add accounts anytime.")
                }
            }

            Section("Troubleshooting") {
                Button("Reveal Log File in Finder") {
                    let path = NSHomeDirectory() + "/Library/Logs/ClaudeSwitch-app.log"
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: NSHomeDirectory() + "/Library/Logs")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ClaudeSwitch never decrypts Claude's stored credentials. It only quits Claude, copies its still-encrypted profile files, and relaunches it -- the same trust boundary Claude itself uses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 400)
        .onAppear { appState.refreshInstallState() }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
