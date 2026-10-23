import SwiftUI
import AppKit

/// Puts the system's own close, minimize and zoom buttons where the window's header wants
/// them, and keeps them there. The window has no title bar of its own (`.hiddenTitleBar`), so
/// the buttons would sit high in the corner; this makes the transparent title bar as tall as
/// the header row and centers them in it, keeping the system's spacing. AppKit lays the title
/// bar out again on resize, on leaving full screen and on key changes, so it is redone then.
/// The buttons hide where the header they belong to is put away (a hidden sidebar).
struct WindowConfigurator: NSViewRepresentable {
    var headerHeight: CGFloat = WindowConfigurator.headerHeight
    var buttonsVisible = true

    /// The height of the header rows the buttons sit in (the sidebar's top row, the tab row).
    static let headerHeight: CGFloat = 44
    /// The close button's left edge, from the window's.
    static let leading: CGFloat = 16
    /// The room the three buttons take, with a margin, for the header to leave clear.
    static let reserved: CGFloat = 78

    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView() }

    func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.headerHeight = headerHeight
        view.buttonsVisible = buttonsVisible
        view.place()
    }

    final class ConfiguratorView: NSView {
        var headerHeight = WindowConfigurator.headerHeight
        var buttonsVisible = true
        /// The system's distance from one button to the next, read before moving them.
        private var spacing: CGFloat?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.place()
                })
            }
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func place() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            if spacing == nil { spacing = minimize.frame.minX - close.frame.minX }
            let step = spacing ?? 20

            // The title bar's container, as tall as the header and pinned to the window's top.
            var frame = container.frame
            frame.size.height = headerHeight
            frame.origin.y = window.frame.height - headerHeight
            container.frame = frame
            titlebar.frame = container.bounds

            for (index, button) in [close, minimize, zoom].enumerated() {
                button.isHidden = !buttonsVisible
                button.setFrameOrigin(NSPoint(
                    x: WindowConfigurator.leading + CGFloat(index) * step,
                    y: ((headerHeight - button.frame.height) / 2).rounded()))
            }
        }
    }
}

/// Leaves room in a header row for the window's buttons.
struct WindowButtonsSpace: View {
    /// How far the row already sits from the window's left edge.
    var inset: CGFloat = 0

    var body: some View {
        Color.clear.frame(width: max(WindowConfigurator.reserved - inset, 0), height: 1)
    }
}

/// Lets the canvas move the window, as a title bar would.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Marks an incognito window, beside its tabs.
struct IncognitoBadge: View {
    var compact = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.slash.fill").font(.system(size: 10, weight: .semibold))
            if !compact { Text("Incognito").font(.system(size: 11.5, weight: .semibold)) }
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, compact ? 7 : 10)
        .frame(height: 24)
        .background(palette.selection, in: Capsule())
        .help("Incognito: nothing this window visits is kept, and its cookies go when it closes")
    }
}

/// Back, forward, and reload (stop while loading).
struct NavigationButtons: View {
    @ObservedObject var tab: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            Button { tab.view.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.chrome).disabled(!tab.canGoBack)
                .help("Back")
            Button { tab.view.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.chrome).disabled(!tab.canGoForward)
                .help("Forward")
            Button {
                tab.isLoading ? tab.view.stopLoading() : tab.view.reload()
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.chrome)
            .help(tab.isLoading ? "Stop" : "Reload (⌘R)")
        }
    }
}

/// The address as a quiet pill: the site's name, a copy-link button and the bookmark star. A
/// click opens the command bar on this tab, with the whole address ready to replace.
struct AddressPill: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var copied = false

    private var isBookmarked: Bool { bookmarks.isBookmarked(tab.address) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.address.hasPrefix("https://") ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.inkTertiary)
                .frame(width: 14)
            Text(host.isEmpty ? "Search or enter address" : host)
                .font(Theme.Text.body)
                .foregroundStyle(host.isEmpty ? palette.inkTertiary : palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering && !tab.isStart {
                Button(action: copyLink) {
                    Image(systemName: copied ? "checkmark" : "link").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ChromeButtonStyle(size: 22))
                .help("Copy link (⇧⌘C)")
                .transition(.opacity)
            }
            if (hovering || isBookmarked) && !tab.isStart && !tab.isIncognito {
                Button { bookmarks.toggle(url: tab.address, title: tab.title) } label: {
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isBookmarked ? palette.accent : palette.inkSecondary)
                }
                .buttonStyle(ChromeButtonStyle(size: 22))
                .help(isBookmarked ? "Remove bookmark (⌘D)" : "Bookmark this page (⌘D)")
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(hovering ? palette.selection : palette.hover,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.commandBar = .tab(tab.id) }
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .help(tab.address)
    }

    /// "en.wikipedia.org/wiki/Acorn" as "en.wikipedia.org"; "www." is dropped.
    private var host: String {
        if tab.isStart { return "" }
        guard let url = URL(string: tab.address), let host = url.host(), !host.isEmpty else { return tab.address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func copyLink() {
        copyToPasteboard(tab.address)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// The page card's header in the top layout: navigation, the address, a new tab and the menu.
struct PageToolbar: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var showingMenu = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            NavigationButtons(tab: tab)
            AddressPill(tab: tab, store: store)
                .padding(.horizontal, Theme.Space.xs)
            Button { store.commandBar = .newTab } label: { Image(systemName: "plus") }
                .buttonStyle(.chrome)
                .help("New tab (⌘T)")
            Button { showingMenu = true } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.chrome)
                .help("More")
                .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                    BrowserMenu(tab: tab, store: store, isPresented: $showingMenu)
                }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 42)
        .background(palette.card)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }
}

/// The ring round a page the agent is working in: the agent's colors, turning slowly. It runs
/// only while the agent drives and the window is in front, and stands still under Reduce Motion.
struct AgentGlow: View {
    var radius: CGFloat = Theme.Radius.card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    private static let colors: [Color] = [
        Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 0.85, green: 0.35, blue: 0.85),
        Color(red: 0.45, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.55, blue: 0.35),
    ]

    var body: some View {
        let still = reduceMotion || activeState == .inactive
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let turn = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(turn * 360)),
                              lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// The window's keyboard shortcuts, as buttons nobody sees, so they work in either layout and
/// with the page focused (Chromium's view takes key equivalents a menu would miss). The menu
/// bar lists the same commands with the same keys.
struct WindowShortcuts: View {
    @ObservedObject var store: TabStore

    var body: some View {
        ZStack {
            key("t") { store.commandBar = .newTab }
            key("w") { store.close(store.active) }
            key("k") { store.toggleAgent() }
            key("s") { store.toggleSidebar() }
            key("l") { store.commandBar = .tab(store.activeID) }
            key("r") { store.active.view.reload() }
            key("f") { store.active.startFinding() }
            key("p") { store.active.printPage() }
            key("d") { store.toggleBookmark() }
            key("y") { store.showingHistory = true }
            key("\\") { store.toggleSplit() }
            key("c", modifiers: [.command, .shift]) { store.copyLink() }
            key("=") { store.active.zoomIn() }
            key("-") { store.active.zoomOut() }
            key("0") { store.active.zoomReset() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func key(_ character: Character, modifiers: EventModifiers = .command,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}
