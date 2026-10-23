import SwiftUI
import AppKit

/// One suggestion: where it goes or what it does.
struct CommandItem: Identifiable {
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

/// What the typed words could mean, best first: the address or a search, an open tab, a
/// bookmark, a page from history, one of the window's commands, or a task for the agent. Ranked
/// from what the browser already knows; nothing typed leaves the machine until it is opened.
/// The command bar and the start page both ask this, so they always agree.
@MainActor
struct Suggestions {
    let store: TabStore
    let runner: AgentRunner
    /// Where what is chosen opens.
    let mode: CommandBarMode
    let openSettings: () -> Void

    private var settings: BrowserSettings { .shared }

    private var target: BrowserModel? {
        guard case .tab(let id) = mode else { return nil }
        return store.tabs.first { $0.id == id }
    }

    func items(for query: String, historyWhenEmpty: Bool = true) -> [CommandItem] {
        ChromiumPerf.enter("suggestions")
        defer { ChromiumPerf.leave() }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ haystack: String) -> Bool {
            let lowered = haystack.lowercased()
            return words.allSatisfy { lowered.contains($0) }
        }

        var items: [CommandItem] = []
        let isAddress = !text.isEmpty && settings.resolve(text) != settings.searchURL(text)
        let store = self.store
        let mode = self.mode

        if !text.isEmpty {
            if isAddress {
                let url = settings.resolve(text)
                items.append(CommandItem(id: "go", section: .top, icon: "arrow.up.right", title: url,
                                         hint: mode == .newTab ? "Open in new tab" : "Open") {
                    store.open(url, in: mode)
                })
            } else {
                let url = settings.searchURL(text)
                items.append(CommandItem(id: "search", section: .top, icon: "magnifyingglass",
                                         title: text, hint: "Search \(settings.searchEngine.title)") {
                    store.open(url, in: mode)
                })
            }
        }

        if !words.isEmpty {
            for tab in store.tabs where tab !== target && !tab.isStart && matches(tab.title + " " + tab.address) {
                items.append(CommandItem(id: "tab-\(tab.id)", section: .tabs, icon: "square.on.square",
                                         favicon: tab.favicon, title: tab.title.isEmpty ? tab.address : tab.title,
                                         subtitle: tab.address, hint: "Switch to tab") {
                    store.select(tab)
                })
                if items.count >= 5 { break }
            }
            for mark in BookmarkStore.shared.matches(words, limit: 3) {
                items.append(CommandItem(id: "mark-\(mark.id)", section: .bookmarks, icon: "star",
                                         title: mark.title, subtitle: mark.url) {
                    store.open(mark.url, in: mode)
                })
            }
        }

        if !words.isEmpty || historyWhenEmpty {
            let shownURLs = Set(items.map(\.subtitle))
            for entry in HistoryStore.shared.matches(words, limit: words.isEmpty ? 6 : 5) where !shownURLs.contains(entry.url) {
                items.append(CommandItem(id: "history-\(entry.url)", section: .history, icon: "clock",
                                         favicon: FaviconCache.shared.image(forURL: entry.url),
                                         title: entry.title.isEmpty ? entry.url : entry.title,
                                         subtitle: entry.url) {
                    store.open(entry.url, in: mode)
                })
            }
        }

        if !words.isEmpty {
            items += commands.filter { matches($0.title) }.prefix(4)
            if !isAddress && store.hasAgent {
                let runner = self.runner
                items.append(CommandItem(id: "agent", section: .agent, icon: "sparkles",
                                         title: "Ask the agent: \(text)", hint: "Runs in the agent's tab") {
                    runner.submit(text)
                    store.select(BrowserModel.shared)
                    withAnimation(Theme.layout) { store.showAgent = true }
                })
            }
        }
        return items
    }

    /// The window's commands, acting on the tab shown.
    private var commands: [CommandItem] {
        let store = self.store
        let tab = store.active
        let openSettings = self.openSettings
        var list: [CommandItem] = [
            command("Start Page", "house") { tab.view.loadURL(BrowserModel.startURL) },
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
            command(store.verticalLayout ? "Use Tabs Across the Top" : "Use a Sidebar for Tabs",
                    store.verticalLayout ? "menubar.rectangle" : "sidebar.left") {
                withAnimation(Theme.layout) { store.verticalLayout.toggle() }
            },
            command("Settings\u{2026}", "gearshape", "⌘,") { openSettings() },
        ]
        if store.hasAgent {
            list.append(command(store.showAgent ? "Hide Agent" : "Show Agent", "sparkles", "⌘K") { store.toggleAgent() })
        }
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
}

/// A suggestion as a row: its icon (the site's, where known), title and address, and a hint.
struct SuggestionRow: View {
    let item: CommandItem
    let selected: Bool
    @Environment(\.palette) private var palette

    var body: some View {
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
}

/// Suggestions in sections, with the selected one marked; a click or Return runs one.
struct SuggestionList: View {
    let items: [CommandItem]
    @Binding var selection: Int
    let run: (Int) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
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
                        SuggestionRow(item: item, selected: index == selection)
                            .id(index)
                            .onTapGesture { run(index) }
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

/// Up, down and Escape for a suggestion list while its field has the keys. A local monitor,
/// since a text field keeps the arrow keys to itself.
@MainActor
final class SuggestionKeys {
    private var monitor: Any?

    func start(up: @escaping () -> Void, down: @escaping () -> Void, escape: @escaping () -> Void,
               active: @escaping () -> Bool = { true }) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard active() else { return event }
            switch event.keyCode {
            case 125: down(); return nil
            case 126: up(); return nil
            case 53: escape(); return nil
            default: return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
