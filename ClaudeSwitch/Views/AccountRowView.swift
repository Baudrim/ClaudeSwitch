import SwiftUI

/// A single account entry: avatar, editable label, active / side-by-side badge, and the
/// switch, side-by-side and remove actions.
struct AccountRowView: View {
    @Environment(AppState.self) private var appState
    let account: DesktopAccount

    private var isSideBySide: Bool { appState.isSideBySide(account) }

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

                        if isSideBySide {
                            Text("Open in its own window")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if let lastUsed = account.lastUsed {
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
                    } else if isSideBySide {
                        Label("Side by Side", systemImage: "rectangle.split.2x1")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.accent)
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
                        // Icon-only so the row keeps room for two labeled actions on the right.
                        Button {
                            editedLabel = account.label
                            isEditingLabel = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(HoverPillButtonStyle())
                        .font(.caption)
                        .help("Rename")

                        // Its data folder is in use while open side by side.
                        if !isSideBySide {
                            Button {
                                isConfirmingRemove = true
                            } label: {
                                Label("Remove", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(HoverPillButtonStyle(destructive: true))
                            .font(.caption)
                            .help("Remove")
                        }

                        Spacer()

                        if account.isActive {
                            Button {
                                Task { await appState.refreshActiveSnapshot() }
                            } label: {
                                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: Theme.accent, minWidth: 64))
                        } else if isSideBySide {
                            Button {
                                Task { await appState.closeSideBySide(account) }
                            } label: {
                                Label("Close", systemImage: "xmark")
                            }
                            .buttonStyle(GlassPillButtonStyle())
                            .help("Quit this account's Claude window")

                            Button {
                                appState.showSideBySide(account)
                            } label: {
                                Label("Show", systemImage: "macwindow")
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: Theme.accent, minWidth: 64))
                            .help("Bring this account's Claude window to the front")
                        } else {
                            Button {
                                Task { await appState.openSideBySide(account) }
                            } label: {
                                Label("Side by Side", systemImage: "rectangle.split.2x1")
                            }
                            .buttonStyle(GlassPillButtonStyle())
                            .help("Open this account in a second Claude window, alongside the active one")

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
