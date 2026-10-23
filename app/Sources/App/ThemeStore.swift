import SwiftUI
import AppKit

/// One base color of a theme: where its knob sits on the picker's pad. Lightness is not part
/// of it; the appearance (light or dark) decides that, so any pick reads well in either.
struct ThemeColor: Codable, Hashable {
    var hue: Double          // 0...1
    var saturation: Double   // 0...1
}

enum ThemeAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// What AppKit is told. SwiftUI's `preferredColorScheme` cannot be trusted here: on macOS,
    /// once it forced light or dark, going back to nil leaves the window as it was, and the
    /// popovers and sheets follow it only part of the way. Nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// What the person chose: one to three colors, how strongly they tint the window, how much
/// grain sits on top, how much of the desktop the glass lets through, and light or dark.
struct ThemeSettings: Codable, Hashable {
    var colors: [ThemeColor]
    var intensity: Double    // 0...1
    var grain: Double        // 0...1
    var appearance: ThemeAppearance
    var glass: Double = ThemeSettings.defaultGlass    // 0...1

    static let defaultGlass = 0.6
}

extension ThemeSettings {
    /// A theme saved before there was glass reads with the default, rather than not at all.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        colors = try values.decode([ThemeColor].self, forKey: .colors)
        intensity = try values.decode(Double.self, forKey: .intensity)
        grain = try values.decode(Double.self, forKey: .grain)
        appearance = try values.decode(ThemeAppearance.self, forKey: .appearance)
        glass = try values.decodeIfPresent(Double.self, forKey: .glass) ?? Self.defaultGlass
    }
}

struct ThemePreset: Identifiable {
    let name: String
    let settings: ThemeSettings
    var id: String { name }
}

extension ThemePreset {
    private static func make(_ name: String, _ colors: [(Double, Double)], intensity: Double = 0.55,
                             appearance: ThemeAppearance = .system) -> ThemePreset {
        ThemePreset(name: name, settings: ThemeSettings(
            colors: colors.map { ThemeColor(hue: $0.0 / 360, saturation: $0.1) },
            intensity: intensity, grain: 0, appearance: appearance))
    }

    /// Incognito windows wear this whatever the theme, so they are never mistaken for others.
    static let incognito = ThemeSettings(colors: [ThemeColor(hue: 0.68, saturation: 0.18)],
                                         intensity: 0.3, grain: 0.25, appearance: .dark, glass: 0.35)

    static let all: [ThemePreset] = [
        // The wash this window always had: peach into pink into lavender.
        make("Sunset", [(14, 0.85), (328, 0.70), (252, 0.65)], intensity: 0.6),
        make("Acorn", [(28, 0.55)]),
        make("Mist", [(205, 0.60)]),
        make("Sage", [(110, 0.30)]),
        make("Lilac", [(270, 0.50)]),
        make("Rose", [(345, 0.60)]),
        make("Graphite", [(220, 0.08)], intensity: 0.4, appearance: .dark),
        make("Midnight", [(230, 0.60), (262, 0.50)], intensity: 0.6, appearance: .dark),
    ]
}

/// The person's theme, kept between launches. Views do not read this directly: the window
/// turns it into a `Palette` and hands that down the environment.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "theme"

    @Published var settings: ThemeSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.appearance != oldValue.appearance { applyAppearance() }
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ThemeSettings.self, from: data), !saved.colors.isEmpty {
            settings = saved
        } else {
            settings = ThemePreset.all[0].settings
        }
        applyAppearance()
    }

    /// Light, dark or the system's, for every window, popover and sheet at once. An incognito
    /// window sets its own (`WindowAppearance`).
    func applyAppearance() {
        NSApplication.shared.appearance = settings.appearance.nsAppearance
    }

    func apply(_ preset: ThemePreset) {
        withAnimation(.easeOut(duration: 0.25)) { settings = preset.settings }
    }

    /// The preset the current settings came from, if they were not changed since.
    var preset: ThemePreset? { ThemePreset.all.first { $0.settings == settings } }
}

// MARK: - Palette

/// Every color the interface uses, derived from the theme and the appearance in force. Nothing
/// draws with a fixed color: text is picked to stay readable on what is under it, and the
/// accent is darkened (or, in dark, lightened) until it reads on a card.
struct Palette {
    let isDark: Bool
    /// The window's tint, one stop per base color.
    let canvasStops: [Color]
    let ink: Color
    let inkSecondary: Color
    let inkTertiary: Color
    let card: Color
    let raised: Color
    let selection: Color
    let hover: Color
    let pressed: Color
    let hairline: Color
    let accent: Color
    let onAccent: Color
    let grain: Double
    /// How much of the desktop shows through the canvas, 0 (none) to 1.
    let glass: Double
    /// The theme's colors at full strength, for the light the canvas holds under the glass.
    let glows: [Color]
    /// The glass's own color, the theme's hue very faint, at each weight.
    private let glassBase: RGB
    /// The lit edge of glass (top and leading, where the light falls) and its far edge.
    let rimLight: Color
    let rimShade: Color
    /// The soft highlight across the upper part of a pane of glass.
    let sheen: Color

    var canvas: LinearGradient {
        let stops = canvasStops.count == 1 ? [canvasStops[0], canvasStops[0]] : canvasStops
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The tint at a given strength, for washes over a card (a group, a done message).
    func tint(_ opacity: Double) -> Color { accent.opacity(isDark ? opacity * 1.4 : opacity) }

    /// How solid the canvas gradient lies over the blurred desktop.
    var canvasOpacity: Double { 1 - 0.7 * glass }

    /// The color glass is tinted with: more of it the more a surface carries (a panel of text
    /// more than a bar of buttons), so what is written on it stays readable over any page.
    func glassTint(_ weight: GlassWeight) -> Color {
        let alpha: Double = switch weight {
        case .bar: isDark ? 0.22 : 0.18
        case .panel: isDark ? 0.42 : 0.38
        case .overlay: isDark ? 0.62 : 0.58
        }
        return glassBase.color.opacity(alpha)
    }

    /// The same, drawn over a material where real Liquid Glass is not there (before macOS 26):
    /// the material is clearer than Liquid Glass, so the body is denser.
    func glassFill(_ weight: GlassWeight) -> Color {
        let alpha: Double = switch weight {
        case .bar: isDark ? 0.30 : 0.34
        case .panel: isDark ? 0.52 : 0.58
        case .overlay: isDark ? 0.72 : 0.78
        }
        return glassBase.color.opacity(alpha)
    }

    init(_ theme: ThemeSettings, dark: Bool) {
        isDark = dark
        grain = theme.grain
        glass = theme.glass
        let colors = theme.colors.isEmpty ? [ThemeColor(hue: 0.08, saturation: 0.5)] : theme.colors
        let k = theme.intensity
        canvasStops = colors.map { color in
            let s = color.saturation * (dark ? 0.25 + 0.5 * k : 0.35 + 0.6 * k)
            let l = dark ? 0.12 + 0.08 * k : 0.955 - 0.075 * k
            return RGB(hsl: color.hue, s, l).color
        }
        let base = colors[0]
        let inkRGB = dark ? RGB(hsl: base.hue, 0.08, 0.94) : RGB(hsl: base.hue, 0.30, 0.13)
        ink = inkRGB.color
        inkSecondary = inkRGB.color.opacity(0.62)
        inkTertiary = inkRGB.color.opacity(0.4)
        let cardRGB = dark ? RGB(0.118, 0.118, 0.125) : RGB(1, 1, 1)
        card = cardRGB.color
        raised = dark ? RGB(0.16, 0.16, 0.17).color : Color.white
        selection = dark ? Color.white.opacity(0.11) : Color.white.opacity(0.75)
        hover = inkRGB.color.opacity(dark ? 0.08 : 0.06)
        pressed = inkRGB.color.opacity(dark ? 0.14 : 0.11)
        hairline = dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)

        glows = colors.map { color in
            RGB(hsl: color.hue, min(0.35 + color.saturation * 0.6, 1) * (0.55 + 0.45 * k), dark ? 0.42 : 0.70).color
        }
        glassBase = dark ? RGB(hsl: base.hue, base.saturation * 0.35, 0.14) : RGB(hsl: base.hue, base.saturation * 0.45, 0.975)
        rimLight = Color.white.opacity(dark ? 0.26 : 0.85)
        rimShade = dark ? Color.white.opacity(0.05) : Color.white.opacity(0.22)
        sheen = Color.white.opacity(dark ? 0.07 : 0.32)

        // The accent keeps the base hue, with enough color to be one, at a lightness that
        // gives 4.5:1 against a card.
        let accentSaturation = max(base.saturation, 0.45)
        var lightness = dark ? 0.62 : 0.46
        var accentRGB = RGB(hsl: base.hue, accentSaturation, lightness)
        while accentRGB.contrast(with: cardRGB) < 4.5, lightness > 0.05, lightness < 0.95 {
            lightness += dark ? 0.02 : -0.02
            accentRGB = RGB(hsl: base.hue, accentSaturation, lightness)
        }
        accent = accentRGB.color
        onAccent = accentRGB.contrast(with: RGB(1, 1, 1)) >= 3 ? .white : RGB(0.08, 0.08, 0.09).color
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(ThemePreset.all[0].settings, dark: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Resolves the theme against the appearance in force and hands the palette down. Put it at
/// the root of a window.
///
/// Light and dark are AppKit's to set, not SwiftUI's: the store sets the app's appearance and
/// a fixed theme (an incognito window's) sets its window's, and either reaches here as the
/// color scheme. The setting is read first all the same, so the palette never waits a frame.
struct Themed: ViewModifier {
    @ObservedObject var store: ThemeStore
    /// A theme that stands in for the person's (an incognito window's).
    var fixed: ThemeSettings?
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let settings = fixed ?? store.settings
        let scheme = settings.appearance.scheme ?? systemScheme
        return content
            .environment(\.palette, Palette(settings, dark: scheme == .dark))
            .background(WindowAppearance(appearance: fixed?.appearance.nsAppearance))
    }
}

extension View {
    /// `store` is the person's theme unless given: a default argument is worked out off the
    /// main actor, where the shared store cannot be reached, so the body supplies it.
    @MainActor
    func themed(_ store: ThemeStore? = nil, fixed: ThemeSettings? = nil) -> some View {
        modifier(Themed(store: store ?? .shared, fixed: fixed))
    }
}

/// Gives the window it sits in an appearance of its own, or (nil) the app's.
private struct WindowAppearance: NSViewRepresentable {
    let appearance: NSAppearance?

    final class Probe: NSView {
        var appearanceToSet: NSAppearance?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window, window.appearance?.name != appearanceToSet?.name else { return }
            window.appearance = appearanceToSet
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.appearanceToSet = appearance
        view.apply()
    }
}

// MARK: - Canvas

/// The window's background, the stuff the glass is made over: the desktop, blurred, through the
/// theme's gradient, with the theme's colors glowing in two corners for the glass to bend, and
/// the grain over it all. Nothing in it moves, so it costs nothing once drawn.
struct WindowCanvas: View {
    /// Handed in rather than read from the environment: the window's background is hosted
    /// apart from its content, where the palette the content sees does not reliably reach.
    let palette: Palette

    /// Where the glows sit, as fractions of the window: top leading, bottom trailing, and a
    /// third color's at the top trailing.
    private static let glowCenters: [UnitPoint] = [UnitPoint(x: 0.08, y: 0.05), UnitPoint(x: 0.95, y: 0.98),
                                                   UnitPoint(x: 0.82, y: 0.08)]

    var body: some View {
        ZStack {
            if palette.glass > 0 { DesktopBlur() }
            Rectangle().fill(palette.canvas).opacity(palette.canvasOpacity)
            ForEach(Array(glows.enumerated()), id: \.offset) { index, glow in
                Rectangle().fill(EllipticalGradient(
                    colors: [glow.color.opacity(glow.strength), glow.color.opacity(0)],
                    center: Self.glowCenters[index], startRadiusFraction: 0, endRadiusFraction: 0.75))
            }
            if palette.grain > 0 {
                Image(nsImage: Grain.tile)
                    .resizable(resizingMode: .tile)
                    .blendMode(palette.isDark ? .screen : .multiply)
                    .opacity(palette.grain * (palette.isDark ? 0.10 : 0.16))
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// One glow per color; a single color glows in both corners, fainter in the second.
    private var glows: [(color: Color, strength: Double)] {
        let strength = palette.isDark ? 0.38 : 0.5
        guard let first = palette.glows.first else { return [] }
        if palette.glows.count == 1 { return [(color: first, strength: strength), (color: first, strength: strength * 0.6)] }
        return palette.glows.prefix(3).map { (color: $0, strength: strength) }
    }
}

/// The desktop behind the window, blurred: the window itself is see-through (see
/// `WindowConfigurator`), and this is what shows there, light or dark with the appearance.
private struct DesktopBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A square of random grey speckle, made once and tiled: the cost of grain is one small image.
enum Grain {
    static let tile: NSImage = {
        let size = 128
        var bytes = [UInt8](repeating: 0, count: size * size)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in bytes.indices {
            // xorshift: the same speckle every launch, with no dependence on a random source.
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            bytes[i] = UInt8(truncatingIfNeeded: 128 + Int(seed % 128))
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
                            bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: image, size: NSSize(width: size / 2, height: size / 2))
    }()
}

// MARK: - Color math

/// sRGB components, for the conversions and contrast checks SwiftUI's `Color` does not offer.
struct RGB: Hashable {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hsl h: Double, _ s: Double, _ l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let r1, g1, b1: Double
        switch hp {
        case ..<1: r1 = c; g1 = x; b1 = 0
        case ..<2: r1 = x; g1 = c; b1 = 0
        case ..<3: r1 = 0; g1 = c; b1 = x
        case ..<4: r1 = 0; g1 = x; b1 = c
        case ..<5: r1 = x; g1 = 0; b1 = c
        default: r1 = c; g1 = 0; b1 = x
        }
        let m = l - c / 2
        self.init(r1 + m, g1 + m, b1 + m)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
