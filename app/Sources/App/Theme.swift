import SwiftUI

/// The measures every view shares: a 4-point grid, a few radii, the type sizes and the motion.
/// Color is not here: it comes from the person's theme as a `Palette` (ThemeStore.swift), read
/// from the environment with `@Environment(\.palette)`.
enum Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 10
        static let row: CGFloat = 8
        static let tile: CGFloat = 10
        static let popover: CGFloat = 14
    }

    /// Between the window's edge and its cards, and between cards.
    static let gutter: CGFloat = 8

    enum Text {
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .medium)
        static let secondary = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let section = Font.system(size: 11, weight: .semibold)
        static let title = Font.system(size: 15, weight: .semibold)
    }

    /// Layout changes (a tab opening, a panel sliding in) and hover feedback.
    static let layout = Animation.snappy(duration: 0.22)
    static let hover = Animation.easeOut(duration: 0.12)

    /// The agent's mark, the same in every theme.
    static let sparkle = LinearGradient(
        colors: [Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 0.85, green: 0.35, blue: 0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A card: the palette's card color, a hairline edge and a two-layer shadow (a close one for
/// the edge, a wide soft one for the lift).
struct CardStyle: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(palette.card, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.hairline))
            .shadow(color: .black.opacity(palette.isDark ? 0.3 : 0.06), radius: 1, y: 1)
            .shadow(color: .black.opacity(palette.isDark ? 0.35 : 0.08), radius: 12, y: 6)
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card) -> some View { modifier(CardStyle(radius: radius)) }
}

/// A borderless toolbar button that lights up under the pointer.
struct ChromeButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, size: size)
    }
}

private struct ChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? palette.inkSecondary : palette.inkTertiary)
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(configuration.isPressed ? palette.pressed : hovering && isEnabled ? palette.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Theme.hover, value: hovering)
    }
}

extension ButtonStyle where Self == ChromeButtonStyle {
    static var chrome: ChromeButtonStyle { ChromeButtonStyle() }
}

/// A full-width menu or list row: icon, title, and whatever trails it, with a hover fill.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(Theme.Text.body)
            .foregroundStyle(isEnabled ? palette.ink : palette.inkTertiary)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(configuration.isPressed ? palette.pressed : hovering && isEnabled ? palette.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}
