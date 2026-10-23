import SwiftUI

/// A named, colored cluster of tabs. Membership lives on each `BrowserModel.groupID`; this
/// just carries the label and color shown for it.
struct TabGroup: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var color: Color
    var collapsed = false
}

/// The open tabs. The first is the one the agent works in; the others are the person's own.
@MainActor
final class TabStore: ObservableObject {
    static let shared = TabStore()

    @Published private(set) var tabs: [BrowserModel] = [BrowserModel.shared]
    @Published var activeID: UUID = BrowserModel.shared.id
    @Published private(set) var groups: [TabGroup] = []

    /// Tabs on the side instead of across the top, for windows with many of them open.
    @AppStorage("verticalTabs") var verticalLayout = false

    static let groupColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

    var active: BrowserModel { tabs.first { $0.id == activeID } ?? BrowserModel.shared }

    func isAgentTab(_ tab: BrowserModel) -> Bool { tab === BrowserModel.shared }

    func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Tabs in a group, in the order they already sit in `tabs`.
    func members(of groupID: UUID) -> [BrowserModel] { tabs.filter { $0.groupID == groupID } }

    func newTab(url: String = "https://www.google.com") {
        let tab = BrowserModel(url: url)
        withAnimation(.snappy) {
            tabs.append(tab)
            activeID = tab.id
        }
    }

    func duplicate(_ tab: BrowserModel) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let copy = BrowserModel(url: tab.address)
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

    func rename(_ groupID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = name
    }

    func recolor(_ groupID: UUID, to color: Color) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].color = color
    }
}
