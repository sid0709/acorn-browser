import SwiftUI
import AppKit

/// A named, colored cluster of tabs. Membership lives on each `BrowserModel.groupID`; this
/// just carries the label and color shown for it.
struct TabGroup: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var color: Color
    var collapsed = false
}

/// Which window a `TabStore` belongs to. The main window holds the agent's tab; others are
/// the person's alone, and an incognito one keeps nothing.
enum WindowKind: String, Codable, Hashable {
    case main, normal, incognito
}

/// What opens a window. Each carries its own id: SwiftUI brings forward an open window whose
/// value is equal rather than opening another, and two windows of one kind are different.
struct WindowRequest: Codable, Hashable {
    var kind: WindowKind
    var id = UUID()
}

enum CommandBarMode: Hashable {
    case newTab
    case tab(UUID)
}

/// A stretch of the tab list as the strip and the sidebar show it: a lone tab, or a group's
/// consecutive members folded together.
enum TabRun: Identifiable {
    case tab(BrowserModel)
    case group(TabGroup, [BrowserModel])

    var id: String {
        switch self {
        case .tab(let tab): "t-\(tab.id)"
        case .group(let group, _): "g-\(group.id)"
        }
    }
}

/// The open tabs. The first is the one the agent works in; the others are the person's own.
@MainActor
final class TabStore: ObservableObject {
    /// The main window's tabs, the agent's among them.
    static let shared = TabStore(kind: .main)

    let kind: WindowKind
    @Published private(set) var tabs: [BrowserModel]
    @Published var activeID: UUID
    @Published private(set) var groups: [TabGroup] = []

    /// Tabs in a sidebar on the left (Arc's way) instead of across the top. Kept as a plain
    /// default, published by hand: `@AppStorage` does not tell an `ObservableObject`'s views.
    @Published var verticalLayout = UserDefaults.standard.bool(forKey: "verticalTabs") {
        didSet { UserDefaults.standard.set(verticalLayout, forKey: "verticalTabs") }
    }

    /// The sidebar put away (⌘S). It still slides out over the page from the window's left edge.
    @Published var sidebarHidden = UserDefaults.standard.bool(forKey: "sidebarHidden") {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: "sidebarHidden") }
    }

    static let sidebarWidths: ClosedRange<CGFloat> = 200...360
    @Published var sidebarWidth: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
        return saved > 0 ? min(max(saved, TabStore.sidebarWidths.lowerBound), TabStore.sidebarWidths.upperBound) : 248
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }

    /// The agent panel beside the page (⌘K).
    @Published var showAgent = true

    /// The command bar, when open: for a new tab (⌘T) or to send one tab elsewhere (⌘L).
    @Published var commandBar: CommandBarMode?

    /// The history sheet (⌘Y).
    @Published var showingHistory = false

    /// The site whose boost is being written, in a sheet.
    @Published var boostTarget: BoostTarget?

    /// The tab being dragged, while it is: drop targets read it instead of the drag's payload,
    /// which only says "a tab of this app".
    @Published var draggedTab: UUID?
    /// A group just made by a drag, whose name is waiting to be typed.
    @Published var renamingGroup: UUID?

    static let groupColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

    var active: BrowserModel { tabs.first { $0.id == activeID } ?? tabs.first ?? BrowserModel.shared }

    /// Only the main window has the agent, its tab and its panel.
    var hasAgent: Bool { kind == .main }
    var isIncognito: Bool { kind == .incognito }

    init(kind: WindowKind) {
        self.kind = kind
        let first = kind == .main
            ? BrowserModel.shared
            : BrowserModel(url: BrowserSettings.shared.searchEngine.home, incognito: kind == .incognito)
        tabs = [first]
        activeID = first.id
        showAgent = kind == .main
    }

    func isAgentTab(_ tab: BrowserModel) -> Bool { tab === BrowserModel.shared }

    func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Tabs in a group, in the order they already sit in `tabs`.
    func members(of groupID: UUID) -> [BrowserModel] { tabs.filter { $0.groupID == groupID } }

    /// A tab on `url`, or on the search engine's page.
    func newTab(url: String? = nil) {
        let tab = BrowserModel(url: url ?? BrowserSettings.shared.searchEngine.home, incognito: isIncognito)
        withAnimation(.snappy) {
            tabs.append(tab)
            activeID = tab.id
        }
    }

    func duplicate(_ tab: BrowserModel) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let copy = BrowserModel(url: tab.address, incognito: isIncognito)
        copy.groupID = tab.groupID
        copy.isPinned = tab.isPinned
        withAnimation(.snappy) {
            tabs.insert(copy, at: index + 1)
            activeID = copy.id
        }
    }

    func select(_ tab: BrowserModel) { activeID = tab.id }

    func close(_ tab: BrowserModel) {
        guard !isAgentTab(tab), let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        withAnimation(.snappy) {
            tabs.remove(at: index)
            if activeID == tab.id, !tabs.isEmpty { activeID = tabs[min(index, tabs.count - 1)].id }
        }
        tab.view.destroyBrowser()
        // A window of the person's own goes with its last tab, as in other browsers. The
        // person is acting in it, so it is the key window.
        if tabs.isEmpty { NSApp.keyWindow?.performClose(nil) }
    }

    func closeOthers(keeping tab: BrowserModel) {
        for other in tabs where other.id != tab.id && !isAgentTab(other) { close(other) }
    }

    func closeToTheRight(of tab: BrowserModel) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for other in tabs[(index + 1)...] where !isAgentTab(other) { close(other) }
    }

    func togglePin(_ tab: BrowserModel) {
        guard !isAgentTab(tab) else { return }
        withAnimation(.snappy) {
            tab.isPinned.toggle()
            // Either way the tab belongs right at the boundary between the pinned tabs and
            // the ordinary ones: at the end of the pinned group when pinning, at its start
            // (the same boundary) when unpinning.
            guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            tabs.remove(at: index)
            tabs.insert(tab, at: tabs.prefix(while: \.isPinned).count)
        }
    }

    /// Puts `tab` in a fresh group of its own.
    func newGroup(with tab: BrowserModel, color: Color? = nil) {
        let used = Set(groups.map(\.color))
        let pick = color ?? Self.groupColors.first { !used.contains($0) } ?? Self.groupColors.randomElement()!
        let group = TabGroup(name: "Group", color: pick)
        withAnimation(.snappy) { groups.append(group) }
        addToGroup(tab, groupID: group.id)
    }

    /// Adds `tab` to an existing group, moving it next to the group's other members.
    func addToGroup(_ tab: BrowserModel, groupID: UUID) {
        withAnimation(.snappy) {
            tab.groupID = groupID
            guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            guard let lastMember = tabs.last(where: { $0.groupID == groupID && $0.id != tab.id }) else { return }
            tabs.remove(at: index)
            let reinsertAt = tabs.firstIndex(where: { $0.id == lastMember.id }).map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: reinsertAt)
        }
    }

    func removeFromGroup(_ tab: BrowserModel) {
        let groupID = tab.groupID
        withAnimation(.snappy) { tab.groupID = nil }
        // A group with nobody left in it is gone.
        if let groupID, members(of: groupID).isEmpty {
            groups.removeAll { $0.id == groupID }
        }
    }

    func toggleCollapse(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        withAnimation(.snappy) { groups[index].collapsed.toggle() }
    }

    /// `tabs` in order, consecutive same-group tabs folded into one run, those `included` only.
    func runs(where included: (BrowserModel) -> Bool = { _ in true }) -> [TabRun] {
        var result: [TabRun] = []
        let shown = tabs.filter(included)
        var i = 0
        while i < shown.count {
            if let groupID = shown[i].groupID, let group = self.group(groupID) {
                var members: [BrowserModel] = []
                while i < shown.count, shown[i].groupID == groupID {
                    members.append(shown[i])
                    i += 1
                }
                result.append(.group(group, members))
            } else {
                result.append(.tab(shown[i]))
                i += 1
            }
        }
        return result
    }

    /// Lets the group's tabs go free; the group itself goes with its last member.
    func ungroup(_ groupID: UUID) {
        for tab in members(of: groupID) { removeFromGroup(tab) }
    }

    func closeGroup(_ groupID: UUID) {
        for tab in members(of: groupID) { close(tab) }
        groups.removeAll { $0.id == groupID }
    }

    // MARK: Dragging

    var dragged: BrowserModel? { tabs.first { $0.id == draggedTab } }

    /// Puts `tab` just before or after `target`, in `target`'s group and pinned or not as it
    /// is, so groups stay together and pinned tabs stay first.
    func move(_ tab: BrowserModel, to target: BrowserModel, after: Bool) {
        guard tab !== target, !isAgentTab(tab), tabs.contains(where: { $0 === target }),
              let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let oldGroup = tab.groupID
        withAnimation(.snappy) {
            tabs.remove(at: from)
            let at = tabs.firstIndex(where: { $0 === target })!
            tabs.insert(tab, at: after ? at + 1 : at)
            tab.isPinned = target.isPinned && !isAgentTab(target)
            tab.groupID = tab.isPinned ? nil : target.groupID
        }
        dissolveIfEmpty(oldGroup)
    }

    /// `tab` dropped onto `target`: into `target`'s group, or a new group of the two.
    func group(_ tab: BrowserModel, with target: BrowserModel) {
        guard tab !== target, !isAgentTab(tab), !isAgentTab(target), !target.isPinned else { return }
        if tab.isPinned { togglePin(tab) }
        let oldGroup = tab.groupID
        if let groupID = target.groupID {
            addToGroup(tab, groupID: groupID)
        } else {
            newGroup(with: target)
            if let groupID = target.groupID {
                addToGroup(tab, groupID: groupID)
                renamingGroup = groupID
            }
        }
        if oldGroup != tab.groupID { dissolveIfEmpty(oldGroup) }
    }

    /// `tab` dropped on a group's label or folder.
    func join(_ tab: BrowserModel, groupID: UUID) {
        guard !isAgentTab(tab), tab.groupID != groupID else { return }
        if tab.isPinned { togglePin(tab) }
        let oldGroup = tab.groupID
        addToGroup(tab, groupID: groupID)
        dissolveIfEmpty(oldGroup)
    }

    /// `tab` dropped in open space: out of its group and its pin, to the end of the list.
    func release(_ tab: BrowserModel) {
        guard !isAgentTab(tab), let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let oldGroup = tab.groupID
        withAnimation(.snappy) {
            tabs.remove(at: from)
            tab.isPinned = false
            tab.groupID = nil
            tabs.append(tab)
        }
        dissolveIfEmpty(oldGroup)
    }

    /// `tab` dropped among the pinned tiles.
    func pin(_ tab: BrowserModel) {
        guard !isAgentTab(tab), !tab.isPinned else { return }
        let oldGroup = tab.groupID
        tab.groupID = nil
        togglePin(tab)
        dissolveIfEmpty(oldGroup)
    }

    /// A group with nobody left in it is gone.
    private func dissolveIfEmpty(_ groupID: UUID?) {
        guard let groupID, members(of: groupID).isEmpty else { return }
        withAnimation(.snappy) { groups.removeAll { $0.id == groupID } }
    }

    func rename(_ groupID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = name
    }

    func recolor(_ groupID: UUID, to color: Color) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].color = color
    }
}

// MARK: - Window commands

/// What the shortcuts, the menu bar, the ⋮ menu and the command bar all do, in one place.
extension TabStore {
    func toggleAgent() {
        guard hasAgent else { return }
        withAnimation(Theme.layout) { showAgent.toggle() }
    }

    func toggleSidebar() {
        guard verticalLayout else { return }
        withAnimation(Theme.layout) { sidebarHidden.toggle() }
    }

    func toggleBookmark() {
        guard !active.isIncognito else { return }
        BookmarkStore.shared.toggle(url: active.address, title: active.title)
    }

    func copyLink() { copyToPasteboard(active.address) }

    /// Opens what the command bar was given: in the tab it was opened for, or a new one.
    func open(_ url: String, in mode: CommandBarMode) {
        switch mode {
        case .newTab:
            newTab(url: url)
        case .tab(let id):
            let tab = tabs.first { $0.id == id } ?? active
            tab.view.loadURL(url)
            select(tab)
            tab.view.focusBrowser()
        }
    }
}

