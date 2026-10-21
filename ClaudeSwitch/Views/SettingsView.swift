import ServiceManagement
import SwiftUI

/// Native Settings window (⌘,). Kept intentionally small: version and updates, launch-at-login,
/// and quick access to the local data ClaudeSwitch keeps (logs, snapshots) for troubleshooting.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isConfirmingReset = false

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Updates") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)

                if let update = appState.availableUpdate {
                    updateBanner(update)
                }

                Toggle("Check for updates automatically", isOn: $appState.checksForUpdatesAutomatically)

                HStack {
                    updateStatus
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appState.isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Check Now") {
                            Task { await appState.checkForUpdates() }
                        }
                    }
                }

                if let error = appState.updateCheckError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

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
        .frame(width: 420, height: 480)
        .onAppear { appState.refreshInstallState() }
    }

    private func updateBanner(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Version \(update.version) is available", systemImage: "app.badge")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)

            Group {
                if let publishedAt = update.publishedAt {
                    Text("Released \(publishedAt, format: .dateTime.day().month()) · You have \(UpdateChecker.currentVersion)")
                } else {
                    Text("You have \(UpdateChecker.currentVersion)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Download on GitHub") {
                    NSWorkspace.shared.open(update.downloadURL)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button("What's New") {
                    NSWorkspace.shared.open(update.releaseURL)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var updateStatus: some View {
        if appState.isCheckingForUpdates {
            Text("Checking GitHub…")
        } else if let lastCheck = appState.lastUpdateCheck {
            Text(appState.availableUpdate == nil
                 ? "Up to date · checked \(lastCheck, format: .relative(presentation: .named))"
                 : "Checked \(lastCheck, format: .relative(presentation: .named))")
        } else {
            Text("Not checked yet")
        }
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
