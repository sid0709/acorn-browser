import SwiftUI

/// The look of the window: a soft pastel wash behind frosted panels, white cards for content,
/// and one warm brown for the actions that matter.
enum Theme {
    static let ink = Color(red: 0.24, green: 0.15, blue: 0.12)
    static let accent = Color(red: 0.36, green: 0.20, blue: 0.15)
    static let card = Color.white.opacity(0.86)
    static let hairline = Color.black.opacity(0.07)

    static let wash = LinearGradient(
        colors: [
            Color(red: 0.99, green: 0.86, blue: 0.80),
            Color(red: 0.98, green: 0.80, blue: 0.90),
            Color(red: 0.84, green: 0.80, blue: 0.98),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let sparkle = LinearGradient(
        colors: [Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 0.85, green: 0.35, blue: 0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A white rounded panel with a hairline edge and a soft shadow.
struct CardStyle: ViewModifier {
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardStyle(radius: radius)) }
}

/// A round, borderless toolbar button that lights up under the pointer.
struct ChromeButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(0.75))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == ChromeButtonStyle {
    static var chrome: ChromeButtonStyle { ChromeButtonStyle() }
}
