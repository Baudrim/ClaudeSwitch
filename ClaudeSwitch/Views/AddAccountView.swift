import SwiftUI

/// Inline "add account" form. Captures whichever account is currently signed into Claude --
/// there is no separate login flow to trigger, since Claude's own UI already handles login.
///
/// Detects up front if that account was already saved (comparing Claude's own
/// `lastKnownAccountUuid`, not the user-chosen label) so re-adding it refreshes the existing
/// entry instead of silently renaming it or creating a confusing duplicate.
struct AddAccountView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    @State private var label = ""
    @State private var duplicateOf: DesktopAccount?
    @FocusState private var isLabelFocused: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                if let duplicate = duplicateOf {
                    duplicateNotice(duplicate)
                } else {
                    addForm
                }
            }
            .padding(14)
        }
        .onAppear(perform: checkForDuplicate)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add current Claude account")
                .font(.subheadline.weight(.semibold))

            Text("Make sure you're signed into the account you want to save in Claude, then name it below. Claude will quit and relaunch to capture it safely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labelField

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(HoverPillButtonStyle())
                .font(.caption)

                Spacer()

                Button("Add Account", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func duplicateNotice(_ duplicate: DesktopAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Already saved", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("Claude is signed into an account you already saved as “\(duplicate.effectiveLabel)”. Adding it again just refreshes that snapshot -- rename it below if you'd like.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labelField

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(HoverPillButtonStyle())
                .font(.caption)

                Spacer()

                Button("Refresh Account", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func checkForDuplicate() {
        if let id = appState.currentLiveAccountId(), let existing = appState.existingAccount(for: id) {
            duplicateOf = existing
            label = existing.label
        }
        isLabelFocused = true
    }

    private func submit() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPresented = false
        Task { await appState.addCurrentAccount(label: trimmed) }
    }
}
