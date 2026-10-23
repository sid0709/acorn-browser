import SwiftUI

/// Hosts the Chromium view. SwiftUI only places it; the page draws itself.
struct BrowserPane: NSViewRepresentable {
    let view: ChromiumBrowserView

    func makeNSView(context: Context) -> ChromiumBrowserView { view }
    func updateNSView(_ nsView: ChromiumBrowserView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var store = TabStore.shared
    @StateObject private var runner = AgentRunner()
    @State private var showAgent = true

    var body: some View {
        VStack(spacing: 8) {
            topBar
            HStack(alignment: .top, spacing: 8) {
                if store.verticalLayout {
                    ScrollView {
                        TabStrip(store: store, vertical: true).padding(8)
                    }
                    .frame(width: 220)
                    .background(Color.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                BrowserCard(tab: store.active, store: store)
                    .id(store.activeID)
                if showAgent {
                    ChatSidebar(runner: runner, onClose: { withAnimation(.snappy) { showAgent = false } })
                        .frame(width: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 960, minHeight: 580)
        .background(Theme.wash.opacity(0.75))
        .containerBackground(.regularMaterial, for: .window)
        .navigationTitle(store.active.title.isEmpty ? "Acorn Browser" : store.active.title)
        .toolbar(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Tabs after the window's own close/minimize/zoom, the agent toggle on the right.
    ///
    /// The system's own buttons are asked for (`.windowStyle(.hiddenTitleBar)`) but do not
    /// paint on this build of macOS: the `NSWindow` reports them present, unhidden, fully
    /// opaque and correctly framed, yet nothing draws and Accessibility finds none — a
    /// compositor bug outside this app's window code, not something more AppKit calls fix.
    /// `WindowControls` below draws working stand-ins in their place.
    private var topBar: some View {
        HStack(spacing: 10) {
            WindowControls()
            if !store.verticalLayout { TabStrip(store: store) }
            Spacer(minLength: 8)
            Button { withAnimation(.snappy) { showAgent.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.sparkle)
                    Text("Ask AI").font(.system(size: 13, weight: .semibold))
                    if runner.isRunning { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(showAgent ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Show or hide the agent (⌘K)")
            .padding(.trailing, 10)

            // Window-level shortcuts that don't belong to any one tab's own card.
            Button { store.newTab() } label: { EmptyView() }
                .keyboardShortcut("t", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
            Button { store.close(store.active) } label: { EmptyView() }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
        }
        .padding(.leading, 20)
        .frame(height: 44)
        .background(WindowDragArea())
    }
}

/// Close, minimize and zoom, drawn and wired by hand (see the note on `topBar`).
private struct WindowControls: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(color: Color(red: 1.00, green: 0.37, blue: 0.34), glyph: "xmark") {
                NSApp.keyWindow?.performClose(nil)
            }
            light(color: Color(red: 1.00, green: 0.74, blue: 0.18), glyph: "minus") {
                NSApp.keyWindow?.miniaturize(nil)
            }
            light(color: Color(red: 0.16, green: 0.78, blue: 0.25), glyph: "plus") {
                NSApp.keyWindow?.zoom(nil)
            }
        }
        .onHover { hovering = $0 }
    }

    private func light(color: Color, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                if hovering {
                    Image(systemName: glyph)
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.5))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

/// The page, with its own address row above it in one rounded card.
private struct BrowserCard: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @State private var addressField = ""
    @FocusState private var addressFocused: Bool
    @State private var showingMenu = false

    var body: some View {
        VStack(spacing: 0) {
            addressRow
            ZStack(alignment: .topTrailing) {
                BrowserPane(view: tab.view)
                ProgressView(value: tab.isLoading ? tab.progress : 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .opacity(tab.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: tab.isLoading)
                    // Clear of the page's own vertical scrollbar, which draws in this
                    // same top strip and would otherwise cut into the bar.
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .top)
                if tab.isFinding {
                    FindBar(tab: tab).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .onChange(of: tab.address) { _, new in
            if !addressFocused { addressField = new }
        }
        .onAppear { addressField = tab.address }
    }

    private var addressRow: some View {
        HStack(spacing: 4) {
            Button { tab.view.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.chrome).disabled(!tab.canGoBack)
            Button { tab.view.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.chrome).disabled(!tab.canGoForward)
            Button {
                tab.isLoading ? tab.view.stopLoading() : tab.view.reload()
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.chrome)
            .keyboardShortcut("r", modifiers: .command)

            HStack(spacing: 8) {
                Image(systemName: isSecure ? "lock.fill" : "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.4))
                TextField("Search or enter address", text: $addressField)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($addressFocused)
                    .onSubmit {
                        tab.go(to: addressField)
                        addressFocused = false
                        tab.view.focusBrowser()
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.black.opacity(addressFocused ? 0.05 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(addressFocused ? 0.35 : 0), lineWidth: 1.5))

            Button { store.newTab() } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(.chrome)
                .help("New tab (⌘T)")
            Button { showingMenu = true } label: { Image(systemName: "ellipsis.circle") }
                .buttonStyle(.chrome)
                .help("More")
                .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                    BrowserMenu(tab: tab, store: store, isPresented: $showingMenu)
                }

            Button { addressFocused = true } label: { EmptyView() }
                .keyboardShortcut("l", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button { tab.startFinding() } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button { tab.printPage() } label: { EmptyView() }
                .keyboardShortcut("p", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button { tab.zoomIn() } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button { tab.zoomOut() } label: { EmptyView() }
                .keyboardShortcut("-", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button { tab.zoomReset() } label: { EmptyView() }
                .keyboardShortcut("0", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var isSecure: Bool { tab.address.hasPrefix("https://") }
}

/// Lets the empty part of the top bar move the window, as a title bar would.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
