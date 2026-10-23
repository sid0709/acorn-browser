import SwiftUI

/// Hosts the Chromium view. SwiftUI only places it; the page draws itself.
struct BrowserPane: NSViewRepresentable {
    let view: ChromiumBrowserView

    func makeNSView(context: Context) -> ChromiumBrowserView { view }
    func updateNSView(_ nsView: ChromiumBrowserView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var store: TabStore
    @StateObject private var runner = AgentRunner()

    /// The main window shows the shared tabs, the agent's among them; any other window starts
    /// with tabs of its own.
    init(kind: WindowKind = .main) {
        _store = StateObject(wrappedValue: kind == .main ? TabStore.shared : TabStore(kind: kind))
    }

    var body: some View {
        Shell(store: store, runner: runner, showAgent: $store.showAgent)
            .themed(fixed: store.isIncognito ? ThemePreset.incognito : nil)
    }
}

/// The window's contents, under the theme `ContentView` resolves: the tabs in a sidebar or
/// across the top, the page in a card, and the agent panel in another.
private struct Shell: View {
    @ObservedObject var store: TabStore
    @ObservedObject var runner: AgentRunner
    @Binding var showAgent: Bool
    @ObservedObject private var agentTab = BrowserModel.shared
    @Environment(\.palette) private var palette
    @State private var peeking = false

    static let agentPanelWidth: CGFloat = 340

    /// While the harness drives the agent's tab and it is the one shown, the sidebar steps
    /// aside: the page the agent sees stays as wide as it was before there was a sidebar.
    private var agentHoldsPage: Bool { store.hasAgent && agentTab.isDriven && store.isShowing(agentTab) }
    private var showsSidebar: Bool { store.verticalLayout && !store.sidebarHidden && !agentHoldsPage }
    /// The window's buttons live in the sidebar's top row, so they go away with it, and come
    /// back while it peeks out.
    private var buttonsVisible: Bool { !store.verticalLayout || showsSidebar || peeking }

    var body: some View {
        Group {
            if store.verticalLayout { sidebarLayout } else { topLayout }
        }
        .frame(minWidth: 960, minHeight: 580)
        .background(WindowDragArea())
        .background(WindowConfigurator(buttonsVisible: buttonsVisible))
        .background(WindowShortcuts(store: store))
        .overlay {
            if let mode = store.commandBar {
                CommandBar(store: store, runner: runner, mode: mode)
                    .id(mode)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.commandBar)
        .sheet(isPresented: $store.showingHistory) { HistoryView(store: store) }
        .sheet(item: $store.boostTarget) { BoostEditor(host: $0.host) }
        .focusedSceneObject(store)
        .containerBackground(for: .window) { WindowCanvas() }
        .navigationTitle(store.active.title.isEmpty ? "Acorn Browser" : store.active.title)
        .ignoresSafeArea(.container, edges: .top)
        .animation(Theme.layout, value: showsSidebar)
        .onChange(of: showsSidebar) { _, shown in if shown { peeking = false } }
        .onChange(of: agentTab.isDriven) { _, driven in store.agentDrivingChanged(driven) }
    }

    // MARK: Sidebar layout

    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                Sidebar(store: store, runner: runner, showAgent: $showAgent)
                    .frame(width: store.sidebarWidth)
                    .overlay(alignment: .trailing) { SidebarResizeHandle(store: store).offset(x: 3) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            pagesAndAgent(toolbar: false)
                .padding(Theme.gutter)
                .padding(.leading, showsSidebar ? -Theme.Space.xs : 0)
        }
        .overlay(alignment: .leading) {
            if !showsSidebar { peekingSidebar }
        }
    }

    /// With the sidebar put away, the window's left edge brings it out over the page while the
    /// pointer stays on it.
    private var peekingSidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 { withAnimation(Theme.layout) { peeking = true } } }
            if peeking {
                Sidebar(store: store, runner: runner, showAgent: $showAgent)
                    .frame(width: store.sidebarWidth)
                    .padding(.bottom, Theme.Space.xs)
                    .background {
                        WindowCanvas()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
                            .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.18), radius: 24, y: 8)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                        .strokeBorder(palette.hairline))
                    // Flush with the window's top, so its first row lines up with the
                    // window's buttons, which come back while it is out.
                    .padding([.leading, .bottom], Theme.gutter)
                    .onHover { if !$0 { withAnimation(Theme.layout) { peeking = false } } }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    // MARK: Top layout

    private var topLayout: some View {
        VStack(spacing: 0) {
            topBar
            pagesAndAgent(toolbar: true)
                .padding([.horizontal, .bottom], Theme.gutter)
        }
    }

    /// The window's controls, the tabs, then the theme and the agent toggle on the right.
    private var topBar: some View {
        HStack(spacing: Theme.Space.m) {
            WindowButtonsSpace()
            TabStrip(store: store)
            Spacer(minLength: Theme.Space.s)
            if store.isIncognito { IncognitoBadge() }
            ThemeButton()
            if store.hasAgent { askButton }
        }
        .padding(.trailing, Theme.Space.m)
        .frame(height: WindowConfigurator.headerHeight)
    }

    private var askButton: some View {
        Button { withAnimation(Theme.layout) { showAgent.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.sparkle)
                Text("Ask").font(.system(size: 13, weight: .semibold))
                if runner.isRunning || agentTab.isDriven {
                    Circle().fill(Theme.sparkle).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(showAgent ? palette.selection : palette.hover,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(showAgent ? "Hide the agent (⌘K)" : "Ask the agent (⌘K)")
    }

    // MARK: Shared

    private func pagesAndAgent(toolbar: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.gutter) {
            if let pair = store.shownSplit, let left = store.tabs.first(where: { $0.id == pair.left }),
               let right = store.tabs.first(where: { $0.id == pair.right }) {
                SplitView(store: store, left: left, right: right)
            } else {
                PageCard(tab: store.active, store: store, showsToolbar: toolbar)
                    .id(store.activeID)
            }
            if showAgent && store.hasAgent {
                ChatSidebar(runner: runner, onClose: { withAnimation(Theme.layout) { showAgent = false } })
                    .frame(width: Self.agentPanelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

/// The palette button and the theme picker it opens.
private struct ThemeButton: View {
    @State private var choosing = false

    var body: some View {
        Button { choosing.toggle() } label: { Image(systemName: "paintpalette") }
            .buttonStyle(.chrome)
            .help("Theme")
            .popover(isPresented: $choosing, arrowEdge: .bottom) { ThemePicker() }
    }
}

/// The page in a card: its toolbar on top in the top layout and in a split (the sidebar
/// carries navigation otherwise), a hairline of progress while it loads, the find bar over it,
/// the agent's ring round it while the agent works in it, and the accent's edge on the pane in
/// use of a split. While a tab is dragged, its right edge takes it to open a split.
struct PageCard: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    var showsToolbar: Bool
    var focused = false
    @Environment(\.palette) private var palette
    @State private var splitTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if showsToolbar { PageToolbar(tab: tab, store: store) }
            ZStack(alignment: .top) {
                BrowserPane(view: tab.view)
                Rectangle()
                    .fill(palette.accent)
                    .frame(height: 2)
                    .scaleEffect(x: max(tab.progress, 0.08), y: 1, anchor: .leading)
                    .opacity(tab.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: tab.progress)
                    .animation(.easeOut(duration: 0.25), value: tab.isLoading)
                    // Clear of the page's own vertical scrollbar, which draws in this
                    // same top strip and would otherwise cut into the bar.
                    .padding(.trailing, 16)
                    .allowsHitTesting(false)
                if tab.isFinding {
                    FindBar(tab: tab)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .card()
        .overlay {
            if tab.isDriven {
                AgentGlow().transition(.opacity)
            } else if focused {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(palette.accent.opacity(0.8), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if store.draggedTab != nil && store.shownSplit == nil { splitDropZone }
        }
        .animation(Theme.layout, value: tab.isDriven)
    }

    private var splitDropZone: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(palette.accent.opacity(splitTargeted ? 0.18 : 0.06))
            .overlay {
                Label("Open in split view", systemImage: "rectangle.split.2x1")
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(palette.accent)
                    .opacity(splitTargeted ? 1 : 0.6)
            }
            .frame(width: 220)
            .padding(Theme.Space.s)
            .contentShape(Rectangle())
            .onDrop(of: [TabDrag.type], delegate: SplitDropDelegate(store: store, host: tab, targeted: $splitTargeted))
            .transition(.opacity)
    }
}
