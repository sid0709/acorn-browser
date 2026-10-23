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
    }

    /// Tabs on the left (clear of the window's own buttons), the agent toggle on the right.
    private var topBar: some View {
        HStack(spacing: 10) {
            TabStrip(store: store)
                .padding(.leading, 78)
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
        }
        .frame(height: 44)
        .background(WindowDragArea())
    }
}

/// The page, with its own address row above it in one rounded card.
private struct BrowserCard: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @State private var addressField = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressRow
            ZStack(alignment: .top) {
                BrowserPane(view: tab.view)
                ProgressView(value: tab.isLoading ? tab.progress : 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .opacity(tab.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: tab.isLoading)
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
                .keyboardShortcut("t", modifiers: .command)
                .help("New tab (⌘T)")
            Button { addressFocused = true } label: { EmptyView() }
                .keyboardShortcut("l", modifiers: .command)
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
