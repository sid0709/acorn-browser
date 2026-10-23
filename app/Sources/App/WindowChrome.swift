import SwiftUI
import AppKit

/// Close, minimize and zoom, drawn and wired by hand.
///
/// The system's own buttons are asked for (`.windowStyle(.hiddenTitleBar)`) but do not paint on
/// this build of macOS: the `NSWindow` reports them present, unhidden, fully opaque and
/// correctly framed, yet nothing draws and Accessibility finds none — a compositor bug outside
/// this app's window code, not something more AppKit calls fix. These are working stand-ins.
struct WindowControls: View {
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
            if hovering && !tab.address.isEmpty {
                Button(action: copyLink) {
                    Image(systemName: copied ? "checkmark" : "link").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ChromeButtonStyle(size: 22))
                .help("Copy link (⇧⌘C)")
                .transition(.opacity)
            }
            if (hovering || isBookmarked) && !tab.address.isEmpty && !tab.isIncognito {
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
