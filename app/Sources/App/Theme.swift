import SwiftUI
import AppKit

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

/// What a pane carries, and so how much of what is behind it its glass holds back.
enum GlassWeight {
    /// A bar of buttons: the top bar, the sidebar.
    case bar
    /// A panel of text: the agent panel.
    case panel
    /// What floats over the page: the command bar, suggestions, the find bar.
    case overlay
}

/// The shell's glass: soft, milky and only a little see-through, the theme's color held in it,
/// and no edge drawn round it. The canvas's colors show through it as a haze. There is no blur:
/// what is behind the shell is the canvas, whose blur would look the same as the canvas itself,
/// so the haze is a tinted body lighter towards the top, which costs nothing.
///
/// A pane of it can move the window, as a title bar does, wherever nothing on it takes the
/// click.
struct FrostedPane<S: InsettableShape>: View {
    let shape: S
    var weight: GlassWeight = .bar
    var movesWindow = false
    /// A double click zooms the window, as on a title bar.
    var zooms = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            shape.fill(reduceTransparency ? palette.glassSolid : palette.glassBody(weight))
            shape.fill(LinearGradient(colors: [palette.sheen, palette.sheen.opacity(0)],
                                      startPoint: .top, endPoint: .bottom))
            if !palette.isDark { shape.strokeBorder(palette.hairline.opacity(0.6), lineWidth: 0.5) }
            if movesWindow { WindowMover(shape: shape, zooms: zooms) }
        }
    }
}

/// The glass of what floats over the page: true crystal. On macOS 26 it is the system's Liquid
/// Glass, which bends and lights the page beneath. Before that it is a frosted blur of the page,
/// faintly tinted, lit across the top, with a short glint along the top leading edge where the
/// light falls, and the shadow of something lifted off the page. Its content is clipped to it.
struct CrystalGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if reduceTransparency {
                drawn(content)
            } else {
                content
                    .clipShape(shape)
                    .glassEffect(.regular.tint(palette.glassTint(.overlay)), in: shape)
            }
        } else {
            drawn(content)
        }
        #else
        drawn(content)
        #endif
    }

    private func drawn(_ content: Content) -> some View {
        content
            .clipShape(shape)
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(palette.raised)
                    } else {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(palette.glassBody(.overlay))
                        shape.fill(LinearGradient(colors: [palette.sheen, palette.sheen.opacity(0)],
                                                  startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)))
                    }
                    CrystalGlint(shape: shape)
                }
                .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.14), radius: 22, y: 10)
            }
    }
}

/// Where light catches crystal: a short, fading glint along the top leading edge, and a fainter
/// one at the bottom trailing corner. Not a border: most of the edge is not drawn at all.
struct CrystalGlint<S: InsettableShape>: View {
    let shape: S
    @Environment(\.palette) private var palette

    var body: some View {
        shape
            .strokeBorder(LinearGradient(stops: [
                .init(color: palette.rimLight, location: 0),
                .init(color: palette.rimLight.opacity(0), location: 0.28),
                .init(color: palette.rimLight.opacity(0), location: 0.8),
                .init(color: palette.rimLight.opacity(0.35), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            .allowsHitTesting(false)
    }
}

/// A drop of the shell's glass under the row or tab in use: the selection's fill, lighter at
/// the top, with a close shadow. No edge.
struct GlassBead<S: InsettableShape>: View {
    let shape: S
    @Environment(\.palette) private var palette

    var body: some View {
        shape
            .fill(palette.selection)
            .overlay(shape.fill(LinearGradient(colors: [palette.sheen, palette.sheen.opacity(0)],
                                               startPoint: .top, endPoint: .center)))
            .shadow(color: .black.opacity(palette.isDark ? 0.22 : 0.06), radius: 3, y: 1)
    }
}

/// Moves the window when dragged, and (if asked) zooms it on a double click, as a title bar
/// does. It lies under everything else on its pane, so it only gets what nothing else takes.
struct WindowMover<S: Shape>: View {
    let shape: S
    var zooms = false

    var body: some View {
        shape.fill(Color.clear)
            .contentShape(shape)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .onTapGesture(count: 2) { if zooms { Self.titleBarDoubleClick() } }
    }

    /// What the person chose in System Settings for a double click on a title bar.
    @MainActor
    static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

/// A card in a page (Settings, Extensions) and the page's own card: solid, with a hairline edge
/// and a two-layer shadow (a close one for the edge, a wide soft one for the lift).
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

    /// Sets the view on the shell's frosted glass, clipped to it.
    func frosted<S: InsettableShape>(_ shape: S, weight: GlassWeight = .bar, movesWindow: Bool = false,
                                     zooms: Bool = false) -> some View {
        clipShape(shape)
            .background(FrostedPane(shape: shape, weight: weight, movesWindow: movesWindow, zooms: zooms))
    }

    /// Sets the view on crystal glass, for what floats over the page.
    func crystal<S: InsettableShape>(_ shape: S) -> some View { modifier(CrystalGlass(shape: shape)) }
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
