import SwiftUI
import AppKit

/// One line of the command bar: where it goes or what it does.
private struct CommandItem: Identifiable {
    enum Section: String {
        case top = ""
        case tabs = "Open Tabs"
        case bookmarks = "Bookmarks"
        case history = "History"
        case commands = "Commands"
        case agent = "Agent"
    }

    let id: String
    let section: Section
    let icon: String
    var favicon: NSImage?
    let title: String
    var subtitle = ""
    var hint = ""
    let run: () -> Void
}

/// The one place to go anywhere or do anything: an address or a search, an open tab, a
/// bookmark, a page from history, a command, or a task for the agent. ⌘T opens it for a new
/// tab, ⌘L (or a click on the address) for the tab shown. Everything is ranked here, from what
/// the browser already knows: nothing typed leaves the machine until it is opened.
struct CommandBar: View {
    @ObservedObject var store: TabStore
    @ObservedObject var runner: AgentRunner
    let mode: CommandBarMode
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var palette
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private static let width: CGFloat = 600

    private var target: BrowserModel? {
        guard case .tab(let id) = mode else { return nil }
        return store.tabs.first { $0.id == id }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var words: [String] { trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(palette.isDark ? 0.4 : 0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            panel.padding(.top, 84)
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var panel: some View {
        let items = self.items
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.inkTertiary)
                TextField(mode == .newTab ? "Search or enter address" : "Search, enter an address, or ask", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundStyle(palette.ink)
                    .focused($focused)
                    .onSubmit { run(items, at: selection) }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, Theme.Space.l + 2)
            .frame(height: 56)

            if !items.isEmpty {
                Rectangle().fill(palette.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if item.section != .top, index == 0 || items[index - 1].section != item.section {
                                    Text(item.section.rawValue)
                                        .font(Theme.Text.section)
                                        .foregroundStyle(palette.inkTertiary)
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.top, Theme.Space.s)
                                        .padding(.bottom, 2)
                                }
                                row(item, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { run(items, at: index) }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(Theme.Space.s - 2)
                    }
                    .frame(maxHeight: 400)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { _, now in proxy.scrollTo(now) }
                }
            }
        }
        .frame(width: Self.width)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.popover + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover + 2, style: .continuous).strokeBorder(palette.hairline))
        .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.2), radius: 30, y: 12)
    }

    private func row(_ item: CommandItem, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? palette.accent.opacity(0.16) : palette.hover)
                if let favicon = item.favicon {
                    Image(nsImage: favicon).resizable().scaledToFit().frame(width: 15, height: 15)
                } else if item.section == .agent {
                    Image(systemName: item.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sparkle)
                } else {
                    Image(systemName: item.icon).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? palette.accent : palette.inkSecondary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Theme.Text.body).foregroundStyle(palette.ink).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(Theme.Text.caption).foregroundStyle(palette.inkTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if !item.hint.isEmpty {
                Text(item.hint).font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
            }
            if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.inkTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: item.subtitle.isEmpty ? 36 : 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(selected ? palette.accent.opacity(palette.isDark ? 0.22 : 0.1) : .clear))
        .contentShape(Rectangle())
    }

    // MARK: Results

    private var items: [CommandItem] {
        var items: [CommandItem] = []
        let text = trimmed
        let isAddress = !text.isEmpty && settings.resolve(text) != settings.searchURL(text)

        if !text.isEmpty {
            if isAddress {
                let url = settings.resolve(text)
                items.append(CommandItem(id: "go", section: .top, icon: "arrow.up.right", title: url,
                                         hint: mode == .newTab ? "Open in new tab" : "Open") { [store, mode] in
                    store.open(url, in: mode)
                })
            } else {
                items.append(CommandItem(id: "search", section: .top, icon: "magnifyingglass",
                                         title: text, hint: "Search \(settings.searchEngine.title)") { [store, mode, settings] in
                    store.open(settings.searchURL(text), in: mode)
                })
            }
        }

        if !words.isEmpty {
            for tab in store.tabs where tab !== target && matches(tab.title + " " + tab.address) {
                items.append(CommandItem(id: "tab-\(tab.id)", section: .tabs, icon: "square.on.square",
                                         favicon: tab.favicon, title: tab.title.isEmpty ? tab.address : tab.title,
                                         subtitle: tab.address, hint: "Switch to tab") { [store] in
                    store.select(tab)
                })
                if items.count >= 5 { break }
            }
            for mark in BookmarkStore.shared.matches(words, limit: 3) {
                items.append(CommandItem(id: "mark-\(mark.id)", section: .bookmarks, icon: "star",
                                         title: mark.title, subtitle: mark.url) { [store, mode] in
                    store.open(mark.url, in: mode)
                })
            }
        }

        let shownURLs = Set(items.map(\.subtitle))
        for entry in HistoryStore.shared.matches(words, limit: words.isEmpty ? 6 : 5) where !shownURLs.contains(entry.url) {
            items.append(CommandItem(id: "history-\(entry.url)", section: .history, icon: "clock",
                                     title: entry.title.isEmpty ? entry.url : entry.title,
                                     subtitle: entry.url) { [store, mode] in
                store.open(entry.url, in: mode)
            })
        }

        if !words.isEmpty {
            items += commands.filter { matches($0.title) }.prefix(4)
            if !isAddress {
                items.append(CommandItem(id: "agent", section: .agent, icon: "sparkles",
                                         title: "Ask the agent: \(text)", hint: "Runs in the agent's tab") { [store, runner] in
                    runner.submit(text)
                    store.select(BrowserModel.shared)
                    withAnimation(Theme.layout) { store.showAgent = true }
                })
            }
        }
        return items
    }

    private func matches(_ haystack: String) -> Bool {
        let lowered = haystack.lowercased()
        return words.allSatisfy { lowered.contains($0) }
    }

    /// The window's commands, acting on the tab shown.
    private var commands: [CommandItem] {
        let tab = store.active
        var list: [CommandItem] = [
            command("Find in Page", "magnifyingglass", "⌘F") { tab.startFinding() },
            command("Print\u{2026}", "printer", "⌘P") { tab.printPage() },
            command("Zoom In", "plus.magnifyingglass", "⌘=") { tab.zoomIn() },
            command("Zoom Out", "minus.magnifyingglass", "⌘-") { tab.zoomOut() },
            command("Actual Size", "1.magnifyingglass", "⌘0") { tab.zoomReset() },
            command("Copy Link", "link", "⇧⌘C") { store.copyLink() },
            command("Translate Page", "character.bubble") { tab.translate() },
            command("Show History", "clock", "⌘Y") { store.showingHistory = true },
            command(store.shownSplit == nil ? "Open Split View" : "Close Split View", "rectangle.split.2x1", "⌘\\") {
                store.toggleSplit()
            },
            command(store.showAgent ? "Hide Agent" : "Show Agent", "sparkles", "⌘K") { store.toggleAgent() },
            command(store.verticalLayout ? "Use Tabs Across the Top" : "Use a Sidebar for Tabs",
                    store.verticalLayout ? "menubar.rectangle" : "sidebar.left") {
                withAnimation(Theme.layout) { store.verticalLayout.toggle() }
            },
            command("Settings\u{2026}", "gearshape", "⌘,") { [openSettings] in openSettings() },
        ]
        if store.verticalLayout {
            list.append(command(store.sidebarHidden ? "Show Sidebar" : "Hide Sidebar", "sidebar.left", "⌘S") {
                store.toggleSidebar()
            })
        }
        if !store.isAgentTab(tab) {
            list.append(command(tab.isPinned ? "Unpin Tab" : "Pin Tab", tab.isPinned ? "pin.slash" : "pin") {
                store.togglePin(tab)
            })
            list.append(command("Duplicate Tab", "plus.square.on.square") { store.duplicate(tab) })
            list.append(command("Close Tab", "xmark.square", "⌘W") { store.close(tab) })
        }
        if !tab.isIncognito {
            let marked = BookmarkStore.shared.isBookmarked(tab.address)
            list.append(command(marked ? "Remove Bookmark" : "Bookmark This Page", marked ? "star.slash" : "star", "⌘D") {
                store.toggleBookmark()
            })
        }
        return list
    }

    private func command(_ title: String, _ icon: String, _ hint: String = "", run: @escaping () -> Void) -> CommandItem {
        CommandItem(id: "command-\(title)", section: .commands, icon: icon, title: title, hint: hint, run: run)
    }

    // MARK: Acting

    private func run(_ items: [CommandItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        close()
        item.run()
    }

    private func close() { store.commandBar = nil }

    /// Fills in the tab's address (selected, so typing replaces it), focuses the field, and
    /// takes the arrow keys and Escape for the list while the bar is open.
    private func start() {
        if let target { query = target.address }
        DispatchQueue.main.async {
            focused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: // down
                selection = min(selection + 1, max(items.count - 1, 0))
                return nil
            case 126: // up
                selection = max(selection - 1, 0)
                return nil
            case 53: // escape
                close()
                return nil
            default:
                return event
            }
        }
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
