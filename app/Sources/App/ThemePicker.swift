import SwiftUI

/// Picks the window's colors: presets along the top, a pad where one to three knobs set the
/// tint's hues, then how strong the tint is, how much grain, how clear the glass, and light or
/// dark. Every change
/// shows on the window at once.
struct ThemePicker: View {
    @ObservedObject var store: ThemeStore = .shared
    @Environment(\.palette) private var palette
    /// The knob the last drag or tap moved: a tap on the pad moves this one.
    @State private var selected = 0

    private static let padHeight: CGFloat = 168
    private static let maxColors = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            swatches
            pad
            HStack(spacing: Theme.Space.l) {
                slider("Intensity", value: $store.settings.intensity)
                slider("Grain", value: $store.settings.grain)
            }
            slider("Glass", value: $store.settings.glass)
                .help("How clear the glass of the window's panes is")
            Picker("", selection: $store.settings.appearance) {
                ForEach(ThemeAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(Theme.Space.l)
        .frame(width: 320)
    }

    // MARK: Presets

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(ThemePreset.all) { preset in
                Button { store.apply(preset); selected = 0 } label: {
                    Circle()
                        .fill(swatchFill(preset.settings))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(palette.accent, lineWidth: 2)
                                .opacity(store.preset?.id == preset.id ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A preset's swatch shows its colors as they would tint a light window, or a dark one for
    /// the dark presets.
    private func swatchFill(_ settings: ThemeSettings) -> LinearGradient {
        let dark = settings.appearance == .dark
        let stops = settings.colors.map { color in
            RGB(hsl: color.hue, max(color.saturation, 0.15) * (dark ? 0.6 : 0.9), dark ? 0.24 : 0.78).color
        }
        return LinearGradient(colors: stops.count == 1 ? [stops[0], stops[0]] : stops,
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Pad

    /// x is the hue, y how much color: vivid along the top, soft along the bottom.
    private var pad: some View {
        VStack(spacing: Theme.Space.s) {
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .fill(LinearGradient(
                            colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { RGB(hsl: $0, 0.85, 0.62).color },
                            startPoint: .leading, endPoint: .trailing))
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.92)],
                                             startPoint: .top, endPoint: .bottom))
                    ForEach(Array(store.settings.colors.enumerated()), id: \.offset) { index, color in
                        // The drag sits on the knob before it is positioned: after, it
                        // would cover the whole pad.
                        knob(color, selected: index == selected)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
                                .onChanged { move(index, to: $0.location, in: size) })
                            .position(x: color.hue * size.width, y: (1 - color.saturation) * size.height)
                    }
                }
                .coordinateSpace(.named("pad"))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .named("pad"))
                    .onEnded { move(selected, to: $0.location, in: size) })
            }
            .frame(height: Self.padHeight)

            HStack(spacing: Theme.Space.l) {
                Button { removeColor() } label: { Image(systemName: "minus") }
                    .buttonStyle(.chrome)
                    .disabled(store.settings.colors.count <= 1)
                    .help("Use one color fewer")
                Button { addColor() } label: { Image(systemName: "plus") }
                    .buttonStyle(.chrome)
                    .disabled(store.settings.colors.count >= Self.maxColors)
                    .help("Blend in another color")
            }
        }
    }

    private func knob(_ color: ThemeColor, selected: Bool) -> some View {
        Circle()
            .fill(RGB(hsl: color.hue, color.saturation * 0.85, 0.62 + (1 - color.saturation) * 0.3).color)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(selected ? 0.35 : 0.2), radius: selected ? 5 : 3, y: 1)
            .scaleEffect(selected ? 1.12 : 1)
            .animation(Theme.hover, value: selected)
    }

    private func move(_ index: Int, to point: CGPoint, in size: CGSize) {
        guard store.settings.colors.indices.contains(index), size.width > 0, size.height > 0 else { return }
        selected = index
        store.settings.colors[index] = ThemeColor(
            hue: min(max(point.x / size.width, 0), 1),
            saturation: min(max(1 - point.y / size.height, 0), 1))
    }

    /// A new color starts a third of the way round the wheel from the last, so the blend shows.
    private func addColor() {
        guard let last = store.settings.colors.last, store.settings.colors.count < Self.maxColors else { return }
        var next = last
        next.hue = (last.hue + 0.33).truncatingRemainder(dividingBy: 1)
        withAnimation(Theme.layout) { store.settings.colors.append(next) }
        selected = store.settings.colors.count - 1
    }

    private func removeColor() {
        guard store.settings.colors.count > 1 else { return }
        let index = store.settings.colors.indices.contains(selected) ? selected : store.settings.colors.count - 1
        withAnimation(Theme.layout) { _ = store.settings.colors.remove(at: index) }
        selected = max(0, min(selected, store.settings.colors.count - 1))
    }

    // MARK: Sliders

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Text.caption).foregroundStyle(palette.inkSecondary)
            Slider(value: value, in: 0...1).controlSize(.small).tint(palette.accent)
        }
    }
}
