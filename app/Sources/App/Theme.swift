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

// MARK: - Glass

/// How much a pane of glass carries, and so how much it holds back of what is behind it: a bar
/// of buttons stays clear, a panel of text is denser, and what floats over a page (the command
/// bar, a peeking sidebar, suggestions) is densest.
enum GlassWeight {
    case bar, panel, overlay
}

/// The window's shell is glass, after Liquid Glass. On macOS 26 it is the real thing: the
/// system's glass bends and lights what lies beneath it (the canvas's glows, the desktop),
/// tinted faintly with the theme. Before that it is built the way crystal catches light: a
/// blur of what is behind, a tinted body, a soft sheen across the upper part, a rim lit along
/// the top and leading edges and fainter along the far ones, and a lift of shadow.
///
/// It is drawn behind what it carries, never applied to it, so text keeps the palette's ink and
/// the Chromium view inside a card is not touched.
struct GlassPlate<S: InsettableShape>: View {
    let shape: S
    var weight: GlassWeight = .bar
    /// A pane that floats (a panel, a card) casts a shadow; a bar within one does not.
    var lifted = true
    @Environment(\.palette) private var palette

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(palette.glassTint(weight)), in: shape)
                .overlay(GlassRim(shape: shape, strength: 0.5))
        } else {
            crystal
        }
        #else
        crystal
        #endif
    }

    private var crystal: some View {
        ZStack {
            shape.fill(weight == .bar ? Material.ultraThinMaterial : Material.thinMaterial)
            shape.fill(palette.glassFill(weight))
            shape.fill(LinearGradient(colors: [palette.sheen, palette.sheen.opacity(0)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
            GlassRim(shape: shape)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(lifted ? (palette.isDark ? 0.28 : 0.05) : 0), radius: 1, y: 1)
        .shadow(color: .black.opacity(lifted ? (palette.isDark ? 0.34 : 0.09) : 0), radius: 14, y: 6)
    }
}

/// The lit edge of a pane of glass: brightest at the top leading corner, where the light falls,
/// fading along the sides, and picking up again faintly at the bottom trailing one, as light
/// does through the far side of a crystal.
struct GlassRim<S: InsettableShape>: View {
    let shape: S
    var strength: Double = 1
    @Environment(\.palette) private var palette

    var body: some View {
        shape
            .strokeBorder(LinearGradient(stops: [
                .init(color: palette.rimLight, location: 0),
                .init(color: palette.rimShade, location: 0.4),
                .init(color: palette.rimShade, location: 0.7),
                .init(color: palette.rimLight.opacity(0.55), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            .overlay(shape.strokeBorder(palette.hairline, lineWidth: 0.5))
            .opacity(strength)
            .allowsHitTesting(false)
    }
}

/// A drop of glass under the row or tab in use: the selection's fill with a lit rim and a
/// close shadow. No blur, so a list of rows costs no more than before.
struct GlassBead<S: InsettableShape>: View {
    let shape: S
    @Environment(\.palette) private var palette

    var body: some View {
        shape
            .fill(palette.selection)
            .overlay(shape.fill(LinearGradient(colors: [palette.sheen, palette.sheen.opacity(0)],
                                               startPoint: .top, endPoint: .center)))
            .overlay(GlassRim(shape: shape, strength: 0.8))
            .shadow(color: .black.opacity(palette.isDark ? 0.25 : 0.07), radius: 3, y: 1)
    }
}

/// A card: content on a pane of glass, clipped to it, with the rim drawn over the content too,
/// so the edge reads as glass even where a page fills the card to its border.
struct CardStyle: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var weight: GlassWeight = .panel

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            .background(GlassPlate(shape: shape, weight: weight))
            .overlay(GlassRim(shape: shape, strength: 0.7))
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card, weight: GlassWeight = .panel) -> some View {
        modifier(CardStyle(radius: radius, weight: weight))
    }

    /// Sets the view on a pane of glass of the given shape, without clipping it.
    func glass<S: InsettableShape>(_ shape: S, weight: GlassWeight = .bar, lifted: Bool = true) -> some View {
        background(GlassPlate(shape: shape, weight: weight, lifted: lifted))
    }
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
            .onHover {
                HoverWatch.flipped("a toolbar button")
                hovering = $0
            }
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
            .onHover {
                HoverWatch.flipped("a row button")
                hovering = $0
            }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}
