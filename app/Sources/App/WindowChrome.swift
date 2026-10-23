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
    /// Hands over the window once the view is in it.
    var onWindow: (NSWindow) -> Void = { _ in }

    /// The height of the header rows the buttons sit in (the sidebar's top row, the tab row).
    static let headerHeight: CGFloat = 44
    /// The close button's left edge, from the window's.
    static let leading: CGFloat = 16
    /// The room the three buttons take, with a margin, for the header to leave clear.
    static let reserved: CGFloat = 78

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.headerHeight = headerHeight
        view.buttonsVisible = buttonsVisible
        view.place()
    }

    final class ConfiguratorView: NSView {
        var headerHeight = WindowConfigurator.headerHeight
        var buttonsVisible = true
        var onWindow: (NSWindow) -> Void = { _ in }
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
            // See-through, so the canvas can blur the desktop behind it (`WindowCanvas`). The
            // pages are opaque views of their own and are not affected.
            window.isOpaque = false
            window.backgroundColor = .clear
            // The sidebar's edge watch needs the pointer's moves over the whole window.
            window.acceptsMouseMovedEvents = true
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            // AppKit lays its buttons out again on its own (showing them, hovering the zoom
            // button): whenever one moves, put it back.
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                button.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            let onWindow = onWindow
            DispatchQueue.main.async { [weak self] in
                onWindow(window)
                self?.place()
            }
        }

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
            if container.frame != frame { container.frame = frame }
            if titlebar.frame != container.bounds { titlebar.frame = container.bounds }

            for (index, button) in [close, minimize, zoom].enumerated() {
                if button.isHidden == buttonsVisible { button.isHidden = !buttonsVisible }
                let origin = NSPoint(x: WindowConfigurator.leading + CGFloat(index) * step,
                                     y: ((headerHeight - button.frame.height) / 2).rounded())
                // Only a button out of place is moved, so its own move notice ends here.
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}

/// While the sidebar is put away: the pointer at the window's left edge brings it out, and
/// moving well past it puts it back. Moves over another window (a popover the sidebar opened)
/// are not this window's and change nothing.
@MainActor
final class EdgePeek {
    private var monitor: Any?
    /// How near the window's left edge the pointer brings the sidebar out, and how far past
    /// the sidebar it may go before it is put back.
    private static let edge: CGFloat = 10
    private static let slack: CGFloat = 32

    func start(window: NSWindow, width: @escaping () -> CGFloat, isOpen: @escaping () -> Bool,
               set: @escaping (Bool) -> Void) {
        stop()
        let edge = Self.edge, slack = Self.slack
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak window] event in
            guard let window, event.window === window else { return event }
            let x = event.locationInWindow.x
            if !isOpen() {
                if x <= edge { set(true) }
            } else if x > width() + slack {
                set(false)
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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

/// The page's title and site, centered ("Acorn · en.wikipedia.org"), with the page's own
/// buttons beside them: translate, add an extension, bookmark, copy the link. A click (or ⌘L)
/// opens it for editing in place: the whole address, selected, with the command bar's
/// suggestions beneath it as one types, as Chrome's address does.
struct AddressField: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    /// In the top layout's toolbar it sits on a field's fill; above a page in the sidebar
    /// layout it is just the page's title until it is pointed at.
    var filled = true
    @EnvironmentObject private var runner: AgentRunner
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var copied = false
    @State private var showingTranslate = false
    @State private var editing = false
    @State private var text = ""
    @State private var selection = 0
    @State private var keys = SuggestionKeys()
    @FocusState private var focused: Bool

    private static let height: CGFloat = 30
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous) }

    private var isBookmarked: Bool { bookmarks.isBookmarked(tab.shownAddress) }
    /// Chrome's translate offer: shown while the page is in another language, or translated.
    private var offersTranslation: Bool {
        !tab.isStart && tab.acornLocation == nil && (tab.translation != .idle || Translator.shared.offers(tab))
    }

    private var items: [CommandItem] {
        guard editing, text != tab.shownAddress else { return [] }
        return Suggestions(store: store, runner: runner, mode: .tab(tab.id))
            .items(for: text, historyWhenEmpty: false)
    }

    var body: some View {
        let items = self.items
        return Group {
            if editing { field(items) } else { label }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background { plate }
        .overlay(shape.strokeBorder(palette.accent.opacity(editing ? 0.5 : 0), lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture { if !editing { beginEditing() } }
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .overlay(alignment: .top) {
            if !items.isEmpty {
                SuggestionList(items: items, selection: $selection) { run(items, at: $0) }
                    .frame(minWidth: 420)
                    .card(radius: Theme.Radius.popover, weight: .overlay)
                    .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.12), radius: 24, y: 10)
                    .offset(y: Self.height + 6)
            }
        }
        .zIndex(1)
        .onChange(of: store.editingAddress) { _, id in
            guard id == tab.id else { return }
            store.editingAddress = nil
            beginEditing()
        }
        .onDisappear { keys.stop() }
        .help(editing ? "" : tab.shownAddress)
    }

    /// Being edited, it is a pane of glass of its own; in the toolbar, which is glass already,
    /// a well in it with a lit rim; above a page in the sidebar layout, nothing until pointed at.
    @ViewBuilder
    private var plate: some View {
        if editing {
            GlassPlate(shape: shape, weight: .overlay)
        } else if filled {
            shape.fill(hovering ? palette.selection : palette.hover)
                .overlay(GlassRim(shape: shape, strength: hovering ? 0.8 : 0.5))
        } else {
            shape.fill(hovering ? palette.hover : .clear)
        }
    }

    // MARK: Showing

    private var label: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
            if tab.isStart || tab.acornLocation != nil {
                Text(tab.displayTitle).font(Theme.Text.bodyStrong).foregroundStyle(palette.ink)
            } else {
                // The title gives way first; the site always shows.
                Text(tab.title.isEmpty ? host : tab.title)
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .layoutPriority(0)
                if !tab.title.isEmpty && !host.isEmpty {
                    Text("·").foregroundStyle(palette.inkTertiary)
                    Text(host)
                        .font(Theme.Text.body)
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
            accessories
        }
    }

    @ViewBuilder
    private var accessories: some View {
        if hovering && !tab.isStart {
            Button(action: copyLink) {
                Image(systemName: copied ? "checkmark" : "link").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(ChromeButtonStyle(size: 22))
            .help("Copy link (⇧⌘C)")
            .transition(.opacity)
        }
        if let id = ExtensionStore.webStoreID(in: tab.address), !tab.isIncognito, !ChromiumBrowserView.chromeStyleRefused {
            AddExtensionButton(id: id)
        }
        if offersTranslation {
            Button { showingTranslate.toggle() } label: {
                Image(systemName: "character.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tab.translation == .done ? palette.accent : palette.inkSecondary)
            }
            .buttonStyle(ChromeButtonStyle(size: 22))
            .help(tab.translation == .done ? "Translated: show the original" : "Translate this page")
            .popover(isPresented: $showingTranslate, arrowEdge: .bottom) { TranslatePopover(tab: tab) }
        }
        if (hovering || isBookmarked) && !tab.isStart && !tab.isIncognito {
            Button { bookmarks.toggle(url: tab.shownAddress, title: tab.acornLocation == nil ? tab.title : tab.displayTitle) } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isBookmarked ? palette.accent : palette.inkSecondary)
            }
            .buttonStyle(ChromeButtonStyle(size: 22))
            .help(isBookmarked ? "Remove bookmark (⌘D)" : "Bookmark this page (⌘D)")
            .transition(.opacity)
        }
    }

    private var icon: String {
        if tab.isStart { return "house" }
        if let location = tab.acornLocation { return location.page.icon }
        return tab.address.hasPrefix("https://") ? "lock.fill" : "globe"
    }

    /// "en.wikipedia.org/wiki/Acorn" as "en.wikipedia.org"; "www." is dropped.
    private var host: String {
        if tab.isStart { return "" }
        guard let url = URL(string: tab.address), let host = url.host(), !host.isEmpty else { return tab.address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Editing

    private func field(_ items: [CommandItem]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Text.body)
                .foregroundStyle(palette.ink)
                .focused($focused)
                .onSubmit { submit(items) }
                .onChange(of: text) { _, _ in selection = 0 }
                .onChange(of: focused) { _, now in if !now { endEditing() } }
        }
    }

    private func beginEditing() {
        text = tab.isStart ? "" : tab.shownAddress
        selection = 0
        editing = true
        keys.start(
            up: { selection = max(selection - 1, 0) },
            down: { selection = min(selection + 1, max(items.count - 1, 0)) },
            escape: endEditing,
            active: { editing })
        // Focus once the field exists, then select what is in it so typing replaces it.
        DispatchQueue.main.async {
            focused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
        focused = false
        keys.stop()
    }

    /// Return opens the chosen suggestion, or, with none (the address unchanged), the text.
    private func submit(_ items: [CommandItem]) {
        if items.indices.contains(selection) {
            let item = items[selection]
            endEditing()
            item.run()
        } else {
            let typed = text
            endEditing()
            tab.go(to: typed)
        }
        tab.view.focusBrowser()
    }

    private func run(_ items: [CommandItem], at index: Int) {
        selection = index
        submit(items)
    }

    private func copyLink() {
        copyToPasteboard(tab.shownAddress)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// The sidebar layout's top row, the same whether the sidebar is shown or put away: the
/// window's buttons, the sidebar toggle and back, forward and reload on the left (as wide as
/// the sidebar while it shows, so they sit over it), and the page's title and site centered over
/// the page, which a click opens for editing. In a split each pane carries its own address, so
/// the row leaves the middle empty.
struct SidebarTopBar: View {
    @ObservedObject var store: TabStore
    /// The sidebar shows beneath, so the controls take its width.
    var sidebarShown: Bool
    /// Room kept on the right (the agent panel's column), so the address centers on the page.
    var trailingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                WindowButtonsSpace()
                Button { store.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.chrome)
                    .help(store.sidebarHidden ? "Show the sidebar (⌘S)" : "Hide the sidebar (⌘S)")
                if store.isIncognito { IncognitoBadge(compact: true) }
                if sidebarShown { Spacer(minLength: 0) }
                NavigationButtons(tab: store.active).id(store.activeID)
            }
            .padding(.trailing, sidebarShown ? Theme.Space.xs : Theme.Space.m)
            .frame(width: sidebarShown ? store.sidebarWidth : nil, alignment: .leading)

            if store.shownSplit == nil {
                AddressField(tab: store.active, store: store, filled: false)
                    .id(store.activeID)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.trailing, trailingInset)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: WindowConfigurator.headerHeight)
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
            AddressField(tab: tab, store: store)
                .padding(.horizontal, Theme.Space.xs)
            Button { store.commandBar = .newTab } label: { Image(systemName: "plus") }
                .buttonStyle(.chrome)
                .help("New tab (⌘T)")
            ExtensionsButton(store: store)
            Button { showingMenu = true } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.chrome)
                .help("More")
                .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                    BrowserMenu(tab: tab, store: store, isPresented: $showingMenu)
                }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 42)
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
            key("l") { store.editingAddress = store.activeID }
            key("r") { store.active.view.reload() }
            key("f") { store.active.startFinding() }
            key("p") { store.active.printPage() }
            key("d") { store.toggleBookmark() }
            key("y") { store.showingHistory = true }
            key(",") { store.openPage(.settings) }
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
