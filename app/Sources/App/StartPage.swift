import SwiftUI
import AppKit

/// What the app opens on, and what an empty tab shows: a greeting, a search, the sites the
/// person goes to most, and a way to ask the agent. Drawn by the app over an empty page, so it
/// is there at once and the same with no network. Nothing on it is fetched or animated.
struct StartPage: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @EnvironmentObject private var runner: AgentRunner
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.palette) private var palette
    @Environment(\.openSettings) private var openSettings
    @AppStorage("startPage.greeting") private var showGreeting = true
    @AppStorage("startPage.shortcuts") private var showShortcuts = true
    @AppStorage("startPage.agent") private var showAgentChip = true
    @AppStorage("startPage.rows") private var rows = 2
    @State private var query = ""
    @State private var selection = 0
    @State private var keys = SuggestionKeys()
    @State private var addingSite = false
    @State private var customizing = false
    @FocusState private var searchFocused: Bool

    private static let columns = 4

    private var items: [CommandItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Suggestions(store: store, runner: runner, mode: .tab(tab.id), openSettings: { openSettings() })
            .items(for: query, historyWhenEmpty: false)
    }

    var body: some View {
        ZStack {
            StartBackdrop()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 34) {
                        if showGreeting { Greeting() }
                        search.zIndex(1)
                        if showShortcuts { speedDial }
                        if showAgentChip && store.hasAgent { agentChip }
                    }
                    .frame(maxWidth: 600)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 56)
                    // Centered in the card while it fits; scrolls when it does not.
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .overlay(alignment: .bottomTrailing) { customizeButton }
        .sheet(isPresented: $addingSite) { AddSiteSheet() }
        .onAppear(perform: start)
        .onDisappear { keys.stop() }
    }

    // MARK: Search

    private var search: some View {
        let items = self.items
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
            TextField("Search \(BrowserSettings.shared.searchEngine.title) or enter an address", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(palette.ink)
                .focused($searchFocused)
                .onSubmit { run(items, at: selection) }
                .onChange(of: query) { _, _ in selection = 0 }
            if !query.isEmpty {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.inkTertiary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(palette.card.opacity(palette.isDark ? 0.18 : 0.55),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(searchFocused ? palette.accent.opacity(0.5) : palette.hairline, lineWidth: searchFocused ? 1.5 : 1))
        .shadow(color: .black.opacity(palette.isDark ? 0.35 : 0.08), radius: 18, y: 8)
        .overlay(alignment: .top) {
            if !items.isEmpty {
                SuggestionList(items: items, selection: $selection) { run(items, at: $0) }
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous).strokeBorder(palette.hairline))
                    .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.16), radius: 24, y: 10)
                    .offset(y: 64)
            }
        }
    }

    private func run(_ items: [CommandItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        query = ""
        item.run()
    }

    private func start() {
        keys.start(
            up: { selection = max(selection - 1, 0) },
            down: { selection = min(selection + 1, max(items.count - 1, 0)) },
            escape: { query = "" },
            active: { searchFocused && !query.isEmpty })
        // Give the page underneath its moment first; then the search takes the keys.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !tab.isDriven { searchFocused = true }
        }
    }

    // MARK: Speed dial

    private var speedDial: some View {
        let tiles = shortcuts.tiles(limit: rows * Self.columns - 1)
        let grid = Array(repeating: GridItem(.flexible(), spacing: 18), count: Self.columns)
        return LazyVGrid(columns: grid, spacing: 22) {
            ForEach(tiles) { shortcut in
                SpeedDialTile(shortcut: shortcut) {
                    tab.view.loadURL(shortcut.url)
                } remove: {
                    withAnimation(Theme.layout) { shortcuts.remove(shortcut) }
                }
            }
            AddSiteTile { addingSite = true }
        }
        // History feeds the dial; look again when it changes.
        .id(history.entries.count)
    }

    // MARK: Agent

    private var agentChip: some View {
        Button {
            withAnimation(Theme.layout) { store.showAgent = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.sparkle)
                Text("Ask the agent to do something for you").foregroundStyle(palette.inkSecondary)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Opens the agent panel (⌘K). You can also type a task in the search above.")
    }

    // MARK: Customize

    private var customizeButton: some View {
        Button { customizing.toggle() } label: { Image(systemName: "slider.horizontal.3") }
            .buttonStyle(.chrome)
            .help("Customize the start page")
            .padding(Theme.Space.l)
            .popover(isPresented: $customizing, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Start Page").font(Theme.Text.title)
                    Toggle("Greeting", isOn: $showGreeting)
                    Toggle("Shortcuts", isOn: $showShortcuts)
                    if store.hasAgent { Toggle("Ask the agent", isOn: $showAgentChip) }
                    Picker("Rows of shortcuts", selection: $rows) {
                        Text("One").tag(1)
                        Text("Two").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!showShortcuts)
                    Divider()
                    Button("Reset Shortcuts") { withAnimation(Theme.layout) { shortcuts.reset() } }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(Theme.Space.l)
                .frame(width: 240)
            }
    }
}

/// "Good evening, Robin" and the date, kept current by the minute.
private struct Greeting: View {
    @Environment(\.palette) private var palette

    private static let firstName: String = {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 6) {
                Text(greeting(at: context.date))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink)
                Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
            }
        }
    }

    private func greeting(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<18: part = "Good afternoon"
        default: part = "Good evening"
        }
        return Self.firstName.isEmpty ? part : "\(part), \(Self.firstName)"
    }
}

/// A site on the dial: its icon on a frosted square and its name beneath. It lifts under the
/// pointer and offers a × to take it off.
private struct SpeedDialTile: View {
    let shortcut: Shortcut
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 9) {
            TileFace(lifted: hovering) { icon }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button(action: remove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(palette.inkSecondary)
                                .frame(width: 18, height: 18)
                                .background(palette.raised, in: Circle())
                                .overlay(Circle().strokeBorder(palette.hairline))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .help("Remove from the start page")
                        .transition(.opacity)
                    }
                }
            Text(shortcut.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.ink.opacity(0.8))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .help(shortcut.url)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = FaviconCache.shared.image(forHost: shortcut.host) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Text(String(shortcut.title.prefix(1)).uppercased())
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.accent)
                .frame(width: 44, height: 44)
                .background(palette.accent.opacity(0.12), in: Circle())
        }
    }
}

private struct AddSiteTile: View {
    let add: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 9) {
            TileFace(lifted: hovering, dashed: true) {
                Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(palette.inkSecondary)
            }
            Text("Add a site").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.inkSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: add)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
    }
}

/// The square a dial tile shows its icon on: frosted, with a hairline edge, lifting when asked.
private struct TileFace<Content: View>: View {
    var lifted: Bool
    var dashed = false
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        content
            .frame(width: 76, height: 76)
            .background(dashed ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Material.ultraThinMaterial), in: shape)
            .background(palette.card.opacity(dashed ? 0 : palette.isDark ? 0.1 : 0.45), in: shape)
            .overlay(shape.strokeBorder(dashed ? palette.inkTertiary : palette.hairline,
                                        style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
            .shadow(color: .black.opacity(dashed ? 0 : palette.isDark ? 0.3 : lifted ? 0.14 : 0.06),
                    radius: lifted ? 14 : 6, y: lifted ? 7 : 2)
            .offset(y: lifted ? -2 : 0)
    }
}

/// The start page's ground: the theme's canvas with a few wide, soft pools of its colors. Made
/// of gradients, not blurs, so it costs nothing once drawn.
private struct StartBackdrop: View {
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                Rectangle().fill(palette.canvas)
                pool(palette.accent, strength: palette.isDark ? 0.32 : 0.2, size: side * 0.9)
                    .position(x: geo.size.width * 0.15, y: geo.size.height * 0.1)
                pool(palette.canvasStops.last ?? palette.accent, strength: palette.isDark ? 0.9 : 0.85, size: side * 0.8)
                    .position(x: geo.size.width * 0.9, y: geo.size.height * 0.85)
                pool(palette.accent, strength: palette.isDark ? 0.18 : 0.1, size: side * 0.6)
                    .position(x: geo.size.width * 0.8, y: geo.size.height * 0.05)
                if palette.grain > 0 {
                    Image(nsImage: Grain.tile)
                        .resizable(resizingMode: .tile)
                        .blendMode(palette.isDark ? .screen : .multiply)
                        .opacity(palette.grain * (palette.isDark ? 0.1 : 0.16))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func pool(_ color: Color, strength: Double, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(strength), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

/// Puts a site on the dial by its address, with a name of the person's choosing.
private struct AddSiteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Add a Site").font(Theme.Text.title).foregroundStyle(palette.ink)
            TextField("Name (optional)", text: $title)
            TextField("Address, like example.com", text: $address)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    ShortcutStore.shared.add(title: title, url: address)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(Theme.Space.xl)
        .frame(width: 360)
    }
}
