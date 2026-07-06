import SwiftUI

/// Shared design tokens for ClaudeSwitch's amber/copper "Liquid Glass" look --
/// deliberately distinct from CCSwitcher's purple/flat-card style.
enum Theme {
    static let accent = Color(red: 0.90, green: 0.52, blue: 0.16)
    static let accentSoft = Color(red: 0.98, green: 0.72, blue: 0.35)

    static let cornerRadius: CGFloat = 16
    static let rowCornerRadius: CGFloat = 14
    static let contentWidth: CGFloat = 340

    static func avatarGradient(for id: UUID) -> LinearGradient {
        // Deterministic per-account hue so each avatar stays visually stable across launches.
        var hasher = Hasher()
        hasher.combine(id)
        let hue = Double(abs(hasher.finalize()) % 360) / 360.0
        let base = Color(hue: hue, saturation: 0.55, brightness: 0.88)
        let dark = Color(hue: hue, saturation: 0.65, brightness: 0.62)
        return LinearGradient(colors: [base, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A rounded translucent surface used throughout ClaudeSwitch's interface. Uses the real
/// Liquid Glass material on macOS 26+, and falls back to a frosted `.ultraThinMaterial`
/// look on older systems so the same view code keeps compiling and looking reasonable.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.rowCornerRadius
    var tinted: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(background)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(tinted ? .regular.tint(Theme.accent.opacity(0.35)) : .regular, in: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.strokeBorder(
                        tinted ? Theme.accent.opacity(0.4) : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
                )
        }
    }
}

/// Button style for the small inline text actions (Rename, Settings, Quit...) that otherwise
/// look like static labels: hovering reveals a translucent capsule and lifts the label color,
/// pressing dims it, so interactive elements are discoverable at a glance.
struct HoverPillButtonStyle: ButtonStyle {
    /// Label color once hovered; idle state stays `.secondary` to keep the UI calm.
    var hoverTint: Color = .primary
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HoverPill(configuration: configuration, hoverTint: destructive ? .red : hoverTint)
    }

    private struct HoverPill: View {
        let configuration: Configuration
        let hoverTint: Color
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? hoverTint : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isHovered
                            ? AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.18 : 0.1))
                            : AnyShapeStyle(Color.clear)
                    )
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Round icon button (the header "+"): grows slightly and gains a glass halo on hover.
struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(configuration: configuration)
    }

    private struct HoverIcon: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(4)
                .background(Circle().fill(isHovered ? Color.primary.opacity(0.1) : Color.clear))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.9 : (isHovered ? 1.1 : 1))
                .onHover { isHovered = $0 }
                .animation(.snappy(duration: 0.15), value: isHovered)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Small circular initials avatar, colored deterministically from the account id.
struct AccountAvatar: View {
    let account: DesktopAccount
    var size: CGFloat = 34

    var body: some View {
        Circle()
            .fill(Theme.avatarGradient(for: account.id))
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }

    private var initials: String {
        let words = account.effectiveLabel
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        return words.isEmpty ? "?" : String(words).uppercased()
    }
}
