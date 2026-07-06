import SwiftUI

/// Inline "add account" form. There is no separate login flow to drive -- Claude's own UI handles
/// sign-in -- so this view watches Claude's live account (`lastKnownAccountUuid`) and reacts:
///   - a new, unsaved account is live  -> green "new account detected", name and save it;
///   - an already-saved account is live -> offer to refresh it, or sign out to add another;
///   - no account is live (logged out)  -> wait for the user to sign in, detecting it live.
struct AddAccountView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    @State private var label = ""
    @State private var liveAccountId: UUID?
    @State private var alreadySaved: DesktopAccount?
    @FocusState private var isLabelFocused: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                if let alreadySaved {
                    duplicateNotice(alreadySaved)
                } else if liveAccountId != nil {
                    newAccountForm
                } else {
                    waitingForLogin
                }
            }
            .padding(14)
        }
        // Reset the label (and focus it) only when the live account actually changes, so polling
        // never clobbers what the user is typing.
        .onChange(of: liveAccountId) { _, id in
            if let id, let existing = appState.existingAccount(for: id) {
                label = existing.label
            } else {
                label = ""
                isLabelFocused = true
            }
        }
        .task { await pollLiveAccount() }
    }

    // MARK: - States

    private var newAccountForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New account detected", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            Text("Claude is signed into a new account. Give it a name to save it here. Claude will quit and relaunch to capture it safely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labelField

            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(HoverPillButtonStyle())
                    .font(.caption)

                Spacer()

                Button("Add Account", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .disabled(trimmedLabel.isEmpty)
            }
        }
    }

    private func duplicateNotice(_ duplicate: DesktopAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("“\(duplicate.effectiveLabel)” is already saved", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)

            Text("Claude is currently signed into an account you've already saved. To add a different one, sign out and log into it -- ClaudeSwitch will detect it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Primary call to action: this is usually why the user opened the form while already
            // on a saved account. Signing out here is local only, so "\(duplicate.effectiveLabel)"
            // stays saved and valid.
            Button {
                Task { await appState.logOutToAddAccount() }
            } label: {
                Label("Sign out & add another account", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)

            HStack {
                Button("Refresh saved session", action: submit)
                    .buttonStyle(HoverPillButtonStyle(hoverTint: Theme.accent))
                    .font(.caption)
                    .help("Re-capture this account's current session so its snapshot doesn't go stale")

                Spacer()

                Button("Cancel") { isPresented = false }
                    .buttonStyle(HoverPillButtonStyle())
                    .font(.caption)
            }
        }
    }

    private var waitingForLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for Claude sign-in…")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Sign into the account you want to add in the Claude window -- it'll be detected here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(HoverPillButtonStyle())
                    .font(.caption)
            }
        }
    }

    private var labelField: some View {
        TextField("e.g. Work, Personal", text: $label)
            .textFieldStyle(.plain)
            .padding(8)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($isLabelFocused)
            .onSubmit(submit)
    }

    // MARK: - Logic

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap poll of Claude's live account so the UI reacts to sign-in/out without the user having
    /// to reopen the form. Reads `lastKnownAccountUuid` from config.json (a plain file read).
    private func pollLiveAccount() async {
        while !Task.isCancelled {
            let id = appState.currentLiveAccountId()
            if id != liveAccountId { liveAccountId = id }
            let saved = id.flatMap { appState.existingAccount(for: $0) }
            if saved != alreadySaved { alreadySaved = saved }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func submit() {
        guard !trimmedLabel.isEmpty else { return }
        isPresented = false
        Task { await appState.addCurrentAccount(label: trimmedLabel) }
    }
}
