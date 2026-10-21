import SwiftUI

/// Root content shown when the menu bar icon is clicked.
private let log = FileLog("MenuContent")

struct MenuContentView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var isAddingAccount = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.isClaudeInstalled {
                notInstalledState
            } else if appState.accounts.isEmpty && !isAddingAccount {
                emptyState
            } else {
                accountList
            }

            if isAddingAccount {
                AddAccountView(isPresented: $isAddingAccount)
                    .padding(14)
            }

            if let error = appState.lastError {
                errorBanner(error)
            }

            footer
        }
        .frame(width: Theme.contentWidth)
        // Room for the held-up quit card even when only one account is listed.
        .frame(minHeight: appState.quitHold == nil ? nil : 280)
        .overlay {
            if appState.isBusy {
                busyOverlay
            }
        }
        .environment(appState)
        .onAppear {
            log.debug("[onAppear] accounts=\(appState.accounts.count) installed=\(appState.isClaudeInstalled)")
            appState.refreshInstallState()
        }
    }

    /// The MenuBarExtra(.window) panel sizes itself from the content's ideal height, and a
    /// ScrollView reports a collapsed (zero) ideal height on the panel's first layout pass --
    /// the accounts only appeared after something else (like toggling the add form) forced a
    /// re-layout. So render the short list as a plain VStack with intrinsic height, and only
    /// fall back to a ScrollView with an explicit fixed height when the list is actually long.
    private var accountList: some View {
        let rows = VStack(spacing: 8) {
            ForEach(sortedAccounts) { account in
                AccountRowView(account: account)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        // Animate the post-switch reorder (newly active account slides to the top) so the
        // change is legible instead of the list snapping instantly.
        .animation(.snappy(duration: 0.4), value: appState.accounts)

        return Group {
            if sortedAccounts.count <= 4 {
                rows
            } else {
                ScrollView {
                    rows
                }
                .frame(height: 340)
            }
        }
    }

    private var sortedAccounts: [DesktopAccount] {
        appState.accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return (lhs.lastUsed ?? lhs.createdAt) > (rhs.lastUsed ?? rhs.createdAt)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            // Reuse the app's swap glyph (tinted amber) so the popup header matches the icon
            // and the status bar item instead of a generic placeholder symbol.
            Image("MenuBarSwap")
                .resizable()
                .renderingMode(.template)
                .frame(width: 16, height: 16)
                .foregroundStyle(Theme.accent)
            Text("ClaudeSwitch")
                .font(.headline)
            if let update = appState.availableUpdate {
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .frame(width: 6, height: 6)
                        Text("v\(update.version)")
                    }
                    // Same solid look as the Active badge: a translucent tint was unreadable on glass.
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("ClaudeSwitch \(update.version) is available -- see Settings")
            }
            Spacer()
            if appState.isClaudeInstalled && !isAddingAccount {
                Button {
                    withAnimation(.snappy) { isAddingAccount = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Add current Claude account")
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No accounts yet")
                .font(.subheadline.weight(.semibold))
            Text("Sign in to Claude, then tap + to save that account here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.snappy) { isAddingAccount = true }
            } label: {
                Label("Add Current Account", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 4)
        }
        .padding(20)
    }

    private var notInstalledState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Claude wasn't found")
                .font(.subheadline.weight(.semibold))
            Text("Install the Claude desktop app, or point ClaudeSwitch at it if it's installed somewhere unusual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Choose Claude.app…") {
                pickClaudeApp()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func errorBanner(_ error: ActionableError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Button {
                    appState.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(HoverIconButtonStyle())
                .foregroundStyle(.secondary)
            }

            if let recovery = error.recovery {
                HStack {
                    Spacer()
                    recoveryButton(recovery)
                }
            }
        }
        .padding(10)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func recoveryButton(_ recovery: ActionableError.Recovery) -> some View {
        switch recovery {
        case .openClaude:
            Button("Open Claude") {
                Task { await appState.launchClaudeIfNeeded() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .selectAppLocation:
            Button("Choose App…") {
                pickClaudeApp()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .openAutomationSettings:
            Button("Open Automation Settings") {
                AutomationPermission.openSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func pickClaudeApp() {
        ClaudeAppPicker.present { url in
            Task { await appState.selectClaudeApp(at: url) }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(GlassPillButtonStyle())

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(GlassPillButtonStyle(tint: .red))
        }
        .padding(14)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
            Group {
                if let hold = appState.quitHold {
                    quitHoldCard(hold)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        if let message = appState.busyMessage {
                            Text(message)
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 14)
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.25), value: appState.quitHold)
    }

    /// Explains why Claude hasn't quit yet and offers the way out that fits: answering Claude's
    /// own prompt, or force quitting once it's only lingering.
    private func quitHoldCard(_ hold: QuitHold) -> some View {
        VStack(spacing: 10) {
            Image(systemName: hold == .askingToConfirm ? "exclamationmark.bubble.fill" : "hourglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, isActive: hold == .stillClosing)

            Text(hold == .askingToConfirm ? "Claude is still working" : "Claude is still closing")
                .font(.subheadline.weight(.semibold))

            Group {
                switch hold {
                case .askingToConfirm:
                    Text("Background tasks are running, so Claude is asking before it quits. Choose **Quit Anyway** in Claude to stop them, and ClaudeSwitch will carry on.")
                case .stillClosing:
                    Text("Its windows are closed, but background tasks are still finishing. ClaudeSwitch will carry on as soon as Claude is gone.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Stop Waiting") {
                    appState.stopWaitingForClaude()
                }
                .buttonStyle(GlassPillButtonStyle())
                .help("Leave Claude as it is and cancel this action")

                switch hold {
                case .askingToConfirm:
                    Button {
                        appState.showClaudeBeingQuit()
                    } label: {
                        Label("Show Claude", systemImage: "macwindow")
                    }
                    .buttonStyle(GlassPillButtonStyle(tint: Theme.accent))
                case .stillClosing:
                    Button {
                        appState.forceQuitClaude()
                    } label: {
                        Label("Force Quit", systemImage: "xmark.octagon")
                    }
                    .buttonStyle(GlassPillButtonStyle(tint: .red))
                    .help("Stop Claude's remaining background tasks now")
                }
            }
            .padding(.top, 2)
        }
    }
}
