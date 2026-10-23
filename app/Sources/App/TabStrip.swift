import SwiftUI
import AppKit

/// Tracks each tab pill's frame in the window (SwiftUI's top-left-origin convention) so a
/// middle click — which SwiftUI has no gesture for — can find which tab it landed on.
private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The row of tabs along the top of the window, with the new-tab button after them. Pinned
/// tabs lead as icon-only squares; grouped tabs cluster inside a labeled, colored bracket.
struct TabStrip: View {
    @ObservedObject var store: TabStore
    /// Across the top (the default) or down the side, for windows with many tabs open.
    var vertical = false
    @State private var frames: [UUID: CGRect] = [:]
    @State private var middleClickMonitor: Any?

    private enum Run: Identifiable {
        case tab(BrowserModel)
        case group(TabGroup, [BrowserModel])
        var id: String {
            switch self {
            case .tab(let tab): "t-\(tab.id)"
            case .group(let group, _): "g-\(group.id)"
            }
        }
    }

    /// `store.tabs` in order, with consecutive same-group tabs folded into one `.group` run.
    private var runs: [Run] {
        var result: [Run] = []
        var i = 0
        let tabs = store.tabs
        while i < tabs.count {
            if let groupID = tabs[i].groupID, let group = store.group(groupID) {
                var members: [BrowserModel] = []
                while i < tabs.count, tabs[i].groupID == groupID {
                    members.append(tabs[i])
                    i += 1
                }
                result.append(.group(group, members))
            } else {
                result.append(.tab(tabs[i]))
                i += 1
            }
        }
        return result
    }

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 4) { tabRuns; newTabButton }
            } else {
                HStack(spacing: 4) { tabRuns; newTabButton }
            }
        }
        .onAppear { installMiddleClickMonitor() }
        .onDisappear { removeMiddleClickMonitor() }
    }

    @ViewBuilder
    private var tabRuns: some View {
        ForEach(runs) { run in
            Group {
                switch run {
                case .tab(let tab):
                    TabPill(tab: tab, store: store, frames: $frames, vertical: vertical)
                case .group(let group, let members):
                    GroupCluster(group: group, members: members, store: store, frames: $frames, vertical: vertical)
                }
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .scale(scale: 0.85).combined(with: .opacity)))
        }
    }

    private var newTabButton: some View {
        Button {
            store.newTab()
        } label: {
            if vertical {
                Label("New Tab", systemImage: "plus").font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: "plus")
            }
        }
        .buttonStyle(.chrome)
        .help("New tab (⌘T)")
    }

    private func installMiddleClickMonitor() {
        guard middleClickMonitor == nil else { return }
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 2 else { return event }
            let height = event.window?.contentView?.bounds.height ?? 0
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            if let hitID = frames.first(where: { $0.value.contains(point) })?.key,
               let tab = store.tabs.first(where: { $0.id == hitID }), !store.isAgentTab(tab) {
                store.close(tab)
            }
            return event
        }
    }

    private func removeMiddleClickMonitor() {
        if let monitor = middleClickMonitor { NSEvent.removeMonitor(monitor) }
        middleClickMonitor = nil
    }
}

/// A group's tabs inside a colored bracket, with a label that collapses them to a count.
private struct GroupCluster: View {
    let group: TabGroup
    let members: [BrowserModel]
    @ObservedObject var store: TabStore
    @Binding var frames: [UUID: CGRect]
    var vertical = false

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 4) { label; memberList }
            } else {
                HStack(spacing: 4) { label; memberList }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(group.color.opacity(0.3)))
    }

    private var label: some View {
        Button { store.toggleCollapse(group.id) } label: {
            HStack(spacing: 4) {
                Circle().fill(group.color).frame(width: 7, height: 7)
                Text(group.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if group.collapsed {
                    Text("\(members.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if vertical { Spacer(minLength: 0) }
            }
            .foregroundStyle(group.color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: vertical ? .infinity : nil)
            .background(group.color.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(group.collapsed ? "Show \u{201C}\(group.name)\u{201D}" : "Collapse \u{201C}\(group.name)\u{201D}")
    }

    @ViewBuilder
    private var memberList: some View {
        if !group.collapsed {
            ForEach(members, id: \.id) { tab in
                TabPill(tab: tab, store: store, frames: $frames, vertical: vertical)
            }
        }
    }
}

private struct TabPill: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Binding var frames: [UUID: CGRect]
    var vertical = false
    @State private var hovering = false
    @Environment(\.palette) private var palette

    private var isActive: Bool { store.activeID == tab.id }
    private var isAgent: Bool { store.isAgentTab(tab) }

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isActive ? palette.selection : hovering ? palette.hover : .clear)
                        .shadow(color: .black.opacity(isActive && !palette.isDark ? 0.08 : 0), radius: 4, y: 1)
                    GeometryReader { geo in
                        Color.clear.preference(key: TabFrameKey.self, value: [tab.id: geo.frame(in: .global)])
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { store.select(tab) }
            .onHover { hovering = $0 }
            .help(isAgent ? "The agent's tab" : tab.title)
            .animation(Theme.hover, value: isActive)
            .contextMenu { if !isAgent { contextMenuItems } }
    }

    @ViewBuilder
    private var content: some View {
        if tab.isPinned && !vertical {
            icon.frame(width: 30, height: 30)
        } else {
            HStack(spacing: 7) {
                icon
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? palette.ink : palette.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if tab.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(palette.inkTertiary)
                }
                if !isAgent && (hovering || isActive) {
                    Button { store.close(tab) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.inkSecondary)
                    .help("Close tab")
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: vertical ? nil : 90, idealWidth: vertical ? nil : 170, maxWidth: vertical ? .infinity : 200)
            .frame(height: 30)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Duplicate Tab") { store.duplicate(tab) }
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab) }
        Divider()
        if tab.groupID != nil {
            Button("Remove from Group") { store.removeFromGroup(tab) }
        } else if store.groups.isEmpty {
            Button("New Group") { store.newGroup(with: tab) }
        } else {
            Menu("Add to Group") {
                ForEach(store.groups) { group in
                    Button(group.name) { store.addToGroup(tab, groupID: group.id) }
                }
                Divider()
                Button("New Group") { store.newGroup(with: tab) }
            }
        }
        Divider()
        Button("Close Tab") { store.close(tab) }
        Button("Close Other Tabs") { store.closeOthers(keeping: tab) }
        Button("Close Tabs to the Right") { store.closeToTheRight(of: tab) }
    }

    @ViewBuilder
    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = tab.favicon {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(palette.inkTertiary)
                    .frame(width: 15, height: 15)
            }
            if isAgent {
                Image(systemName: "sparkle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.sparkle)
                    .offset(x: 4, y: 3)
            }
            if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 15, height: 15)
                    .background(palette.card.opacity(0.7), in: Circle())
            }
        }
    }
}
