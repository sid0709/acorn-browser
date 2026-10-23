import SwiftUI
import AppKit

/// The ⋮ menu: everything the strip and the address have no room for, in Chromium's order, on
/// the window's palette. New tabs and windows lead as tiles; then what acts on this page; then
/// the browser's lists (bookmarks, history, the tab, extensions), which open in the menu itself.
struct BrowserMenu: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Binding var isPresented: Bool
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var palette
    @Environment(\.openWindow) private var openWindow
    @State private var page: Page = .main

    private enum Page { case main, bookmarks, history, tab, extensions }

    private var isWeb: Bool { tab.address.hasPrefix("http://") || tab.address.hasPrefix("https://") }
    private var isAgent: Bool { store.isAgentTab(tab) }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .main: mainPage.transition(.move(edge: .leading).combined(with: .opacity))
            case .bookmarks: subpage("Bookmarks") { bookmarksPage }
            case .history: subpage("History") { historyPage }
            case .tab: subpage("Tab") { tabPage }
            case .extensions: subpage("Extensions") { extensionsPage }
            }
        }
        .frame(width: 320)
        .animation(Theme.layout, value: page)
    }

    // MARK: Main

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                tile("New Tab", "plus.square") { store.commandBar = .newTab }
                tile("New Window", "macwindow.badge.plus") { openWindow(id: "browser", value: WindowRequest(kind: .normal)) }
                tile("Incognito", "eye.slash") { openWindow(id: "browser", value: WindowRequest(kind: .incognito)) }
            }

            section("This page") {
                zoomRow
                if !tab.isIncognito {
                    let marked = bookmarks.isBookmarked(tab.shownAddress)
                    row(marked ? "Remove Bookmark" : "Bookmark This Page", marked ? "star.fill" : "star", shortcut: "⌘D") {
                        store.toggleBookmark()
                    }
                    .disabled(tab.address.isEmpty)
                }
                row(tab.isPinned ? "Unpin Tab" : "Pin Tab", tab.isPinned ? "pin.slash" : "pin") { store.togglePin(tab) }
                    .disabled(isAgent)
                row(store.shownSplit == nil ? "Open in Split View" : "Close Split View", "rectangle.split.2x1",
                    shortcut: "⌘\\") { store.toggleSplit() }
                row("Find in Page\u{2026}", "doc.text.magnifyingglass", shortcut: "⌘F") { tab.startFinding() }
                row(tab.translation == .done || tab.translation == .working
                        ? "Show Original" : "Translate to \(settings.translateLanguageName)",
                    "character.bubble") { tab.translate() }
                    .disabled(!isWeb)
                row("Print\u{2026}", "printer", shortcut: "⌘P") { tab.printPage() }
                row("Copy Link", "link", shortcut: "⇧⌘C") { copyToPasteboard(tab.shownAddress) }
                    .disabled(tab.address.isEmpty)
            }

            section("Browser") {
                row("Start Page", "house") { tab.view.loadURL(BrowserModel.startURL) }
                row("Bookmarks", "star.square.on.square", chevron: true, closes: false) { page = .bookmarks }
                row("History", "clock.arrow.circlepath", chevron: true, closes: false) { page = .history }
                row("Tab", "square.on.square", chevron: true, closes: false) { page = .tab }
                row("Extensions", "puzzlepiece.extension", chevron: true, closes: false) { page = .extensions }
                layoutRow
            }

            HStack {
                Button { store.openPage(.settings, part: "help"); isPresented = false } label: {
                    Label("About Acorn", systemImage: "info.circle")
                }
                Spacer()
                Button { store.openPage(.settings); isPresented = false } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Text.bodyStrong)
            .foregroundStyle(palette.accent)
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, 2)
        }
        .padding(Theme.Space.m)
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(Theme.Text.caption.weight(.medium))
            }
            .foregroundStyle(palette.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile + 2, style: .continuous)
                .strokeBorder(palette.accent.opacity(0.35), lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Zoom, stepped in place, and full screen beside it.
    private var zoomRow: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "plus.magnifyingglass").frame(width: 18).foregroundStyle(palette.inkSecondary)
            Text("Zoom").font(Theme.Text.body).foregroundStyle(palette.ink)
            Spacer()
            roundButton("minus") { tab.zoomOut() }.disabled(tab.zoomLevel <= -7)
            Button { tab.zoomReset() } label: {
                Text("\(tab.zoomPercent)%").font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.ink)
                    .frame(width: 44)
            }
            .buttonStyle(.plain)
            .help("Actual size (⌘0)")
            roundButton("plus") { tab.zoomIn() }.disabled(tab.zoomLevel >= 7)
            Rectangle().fill(palette.hairline).frame(width: 1, height: 20)
            roundButton("arrow.up.left.and.arrow.down.right") {
                isPresented = false
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .help("Full screen")
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 38)
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(palette.card, in: Circle())
                .overlay(Circle().strokeBorder(palette.hairline))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.ink)
    }

    private var layoutRow: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "rectangle.split.3x1").frame(width: 18).foregroundStyle(palette.inkSecondary)
            Text("Tabs").font(Theme.Text.body).foregroundStyle(palette.ink)
            Spacer()
            Picker("", selection: $store.verticalLayout) {
                Image(systemName: "sidebar.left").tag(true).help("In a sidebar")
                Image(systemName: "menubar.rectangle").tag(false).help("Across the top")
            }
            .pickerStyle(.segmented)
            .frame(width: 92)
            .labelsHidden()
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 34)
    }

    // MARK: Subpages

    private var bookmarksPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(settings.showBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar", "menubar.rectangle",
                shortcut: "⇧⌘B", closes: false) { settings.showBookmarksBar.toggle() }
            if bookmarks.bookmarks.isEmpty {
                empty("No bookmarks yet. ⌘D or the star in the address saves a page.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(bookmarks.bookmarks) { mark in
                            PageRow(title: mark.title, subtitle: mark.url, icon: "star") {
                                isPresented = false
                                store.open(mark.url, in: .tab(tab.id))
                            } remove: {
                                bookmarks.remove(mark)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            let recent = Array(HistoryStore.shared.entries.prefix(12))
            if recent.isEmpty {
                empty("Pages you visit appear here.")
            } else {
                ForEach(recent) { entry in
                    PageRow(title: entry.title.isEmpty ? entry.url : entry.title, subtitle: entry.url, icon: "clock") {
                        isPresented = false
                        store.open(entry.url, in: .tab(tab.id))
                    } remove: {
                        HistoryStore.shared.remove(entry)
                    }
                }
            }
            divider
            row("Show All History", "clock.arrow.circlepath", shortcut: "⌘Y") { store.showingHistory = true }
        }
    }

    private var tabPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Duplicate Tab", "plus.square.on.square") { store.duplicate(tab) }.disabled(isAgent)
            row(tab.isPinned ? "Unpin Tab" : "Pin Tab", tab.isPinned ? "pin.slash" : "pin") { store.togglePin(tab) }
                .disabled(isAgent)
            divider
            if tab.groupID != nil {
                row("Remove from Group", "folder.badge.minus") { store.removeFromGroup(tab) }
            } else {
                row("Add to New Group", "folder.badge.plus") { store.newGroup(with: tab) }.disabled(isAgent)
                ForEach(store.groups) { group in
                    row("Add to \u{201C}\(group.name)\u{201D}", "folder") { store.addToGroup(tab, groupID: group.id) }
                        .disabled(isAgent)
                }
            }
            if store.shownSplit != nil {
                divider
                row("Swap Sides", "arrow.left.arrow.right") { store.swapSplit() }
                row("Close Split View", "rectangle") { store.closeSplit() }
            }
            divider
            row("Close Other Tabs", "xmark.square") { store.closeOthers(keeping: tab) }
            row("Close Tabs to the Right", "arrow.right.square") { store.closeToTheRight(of: tab) }
            row("Close Tab", "xmark", shortcut: "⌘W") { store.close(tab) }.disabled(isAgent)
        }
    }

    private var extensionsPage: some View {
        ExtensionsPage(tab: tab, store: store, isPresented: $isPresented)
    }

    private func subpage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                Button { page = .main } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.chrome)
                Text(title).font(Theme.Text.title).foregroundStyle(palette.ink)
                Spacer()
            }
            content()
        }
        .padding(Theme.Space.m)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: Pieces

    /// A titled group of rows on a faint tray, as Chromium's menu draws them.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Text.section).foregroundStyle(palette.inkSecondary).padding(.leading, Theme.Space.s)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(Theme.Space.xs)
                .background(palette.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.popover - 2, style: .continuous))
        }
    }

    private func row(_ title: String, _ icon: String, shortcut: String? = nil, chevron: Bool = false,
                     closes: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            if closes { isPresented = false }
            action()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(palette.inkSecondary)
                Text(title).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                if let shortcut {
                    Text(shortcut).font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
                }
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.inkTertiary)
                }
            }
        }
        .buttonStyle(.row)
    }

    private var divider: some View {
        Rectangle().fill(palette.hairline).frame(height: 1).padding(.vertical, Theme.Space.xs)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.Text.secondary).foregroundStyle(palette.inkSecondary)
            .padding(Theme.Space.s)
    }
}

/// A page in one of the menu's lists: a click opens it, the × under the pointer forgets it.
private struct PageRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(palette.inkTertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.Text.body).foregroundStyle(palette.ink).lineLimit(1)
                Text(subtitle).font(Theme.Text.caption).foregroundStyle(palette.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(ChromeButtonStyle(size: 20))
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

/// The menu's Extensions page: the Web Store's extensions, then the site boosts and a boost for
/// the site shown.
private struct ExtensionsPage: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Binding var isPresented: Bool
    @ObservedObject private var boosts = BoostStore.shared
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var palette

    private var host: String? { URL(string: tab.address)?.host() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(extensions.installed) { info in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "puzzlepiece.extension").frame(width: 18).foregroundStyle(palette.inkTertiary)
                    Text(info.name).font(Theme.Text.body).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer()
                    if !extensions.isEnabled(info) {
                        Text("Off").font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(height: 28)
            }
            if extensions.needsRelaunch {
                Button { extensions.relaunch() } label: { Label("Relaunch to Apply Changes", systemImage: "arrow.clockwise") }
                    .buttonStyle(.row)
            }
            Button {
                isPresented = false
                store.newTab(url: "https://chromewebstore.google.com")
            } label: { Label("Chrome Web Store", systemImage: "bag") }
                .buttonStyle(.row)
            Button {
                isPresented = false
                store.openPage(.extensions)
            } label: { Label("Manage Extensions", systemImage: "puzzlepiece.extension") }
                .buttonStyle(.row)
            SupportLine(support: ExtensionStore.support(in: store))
                .padding(.horizontal, Theme.Space.s)

            Rectangle().fill(palette.hairline).frame(height: 1).padding(.vertical, Theme.Space.xs)
            Text("Site Boosts").font(Theme.Text.section).foregroundStyle(palette.inkSecondary)
                .padding(.horizontal, Theme.Space.s)
            Text("Styles and a script of your own, put into a site's pages.")
                .font(Theme.Text.caption)
                .foregroundStyle(palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.s)
            if let host {
                Button {
                    isPresented = false
                    store.boostTarget = BoostTarget(host: host)
                } label: {
                    Label(boosts.boost(for: host) == nil ? "Boost \(host)" : "Edit the Boost for \(host)", systemImage: "bolt.fill")
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.row)
            }
            if !boosts.boosts.isEmpty {
                Rectangle().fill(palette.hairline).frame(height: 1).padding(.vertical, Theme.Space.xs)
                ForEach(boosts.boosts) { boost in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "bolt").frame(width: 18).foregroundStyle(palette.inkTertiary)
                        Button(boost.host) {
                            isPresented = false
                            store.boostTarget = BoostTarget(host: boost.host)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.ink)
                        Spacer()
                        Toggle("", isOn: Binding(get: { boost.enabled }, set: { boosts.setEnabled(boost, $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: 30)
                }
            }
        }
    }
}

/// The floating find-in-page bar: text, match count, step through, close.
struct FindBar: View {
    @ObservedObject var tab: BrowserModel
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in page", text: $tab.findText)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.ink)
                .focused($focused)
                .frame(width: 160)
                .onSubmit { tab.search(next: true, backward: NSEvent.modifierFlags.contains(.shift)) }
            if !tab.findText.isEmpty {
                Text(tab.findMatchCount == 0 ? "No results" : "\(tab.findActiveMatch)/\(tab.findMatchCount)")
                    .font(Theme.Text.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize()
            }
            Button { tab.search(next: true, backward: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.chrome)
                .disabled(tab.findText.isEmpty)
                .help("Previous match (⇧↩)")
            Button { tab.search(next: true, backward: false) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.chrome)
                .disabled(tab.findText.isEmpty)
                .help("Next match (↩)")
            Button { tab.stopFinding() } label: { Image(systemName: "xmark") }
                .buttonStyle(.chrome)
                .help("Close (esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.hairline))
        .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.12), radius: 10, y: 3)
        .padding(.top, 8)
        .padding(.trailing, 24)
        .onAppear {
            // Claiming focus in the same beat the bar is inserted loses the race against
            // its own entrance transition (and the page underneath, which is glad to take
            // the keystrokes instead): give the transition a moment to finish first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
        .onExitCommand { tab.stopFinding() }
    }
}
