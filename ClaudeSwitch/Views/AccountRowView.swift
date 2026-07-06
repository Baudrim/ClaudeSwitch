import SwiftUI

/// A single account entry: avatar, editable label, active badge, and switch/remove actions.
struct AccountRowView: View {
    @Environment(AppState.self) private var appState
    let account: DesktopAccount

    @State private var isEditingLabel = false
    @State private var editedLabel = ""
    @State private var isConfirmingRemove = false
    @State private var isHovered = false

    var body: some View {
        GlassCard(tinted: account.isActive) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    AccountAvatar(account: account)

                    VStack(alignment: .leading, spacing: 2) {
                        if isEditingLabel {
                            TextField("Label", text: $editedLabel)
                                .textFieldStyle(.plain)
                                .font(.subheadline.weight(.semibold))
                                .onSubmit(commitLabel)
                        } else {
                            Text(account.effectiveLabel)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }

                        if let lastUsed = account.lastUsed {
                            Text(lastUsed, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never used")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 4)

                    if account.isActive {
                        Text("Active")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }

                HStack(spacing: 8) {
                    if isEditingLabel {
                        Button("Cancel") { isEditingLabel = false }
                            .buttonStyle(HoverPillButtonStyle())
                            .font(.caption)

                        Spacer()

                        Button("Save", action: commitLabel)
                            .buttonStyle(HoverPillButtonStyle(hoverTint: Theme.accent))
                            .font(.caption.weight(.semibold))
                    } else if isConfirmingRemove {
                        Text("Remove this account?")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Cancel") { isConfirmingRemove = false }
                            .buttonStyle(HoverPillButtonStyle())
                            .font(.caption)

                        Button("Remove") {
                            appState.remove(account)
                        }
                        .buttonStyle(HoverPillButtonStyle(destructive: true))
                        .font(.caption.weight(.semibold))
                    } else {
                        Button {
                            editedLabel = account.label
                            isEditingLabel = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .buttonStyle(HoverPillButtonStyle())
                        .font(.caption)

                        Button {
                            isConfirmingRemove = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(HoverPillButtonStyle(destructive: true))
                        .font(.caption)

                        Spacer()

                        if account.isActive {
                            Button {
                                Task { await appState.refreshActiveSnapshot() }
                            } label: {
                                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: Theme.accent, minWidth: 64))
                        } else {
                            Button {
                                Task { await appState.switchTo(account) }
                            } label: {
                                Label("Switch", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: Theme.accent, minWidth: 64))
                        }
                    }
                }
            }
            .padding(12)
        }
        // Hover ring over the whole card, so rows read as interactive surfaces before the
        // user hunts for the small inline buttons.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(isHovered ? 0.18 : 0), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .disabled(appState.isBusy)
    }

    private func commitLabel() {
        let trimmed = editedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appState.rename(account, to: trimmed)
        }
        isEditingLabel = false
    }
}
