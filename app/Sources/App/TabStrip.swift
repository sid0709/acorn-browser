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

/// The row of tabs across the top of the window, on the canvas, with the new-tab button after
/// them. Pinned tabs lead as icon-only squares; a group's tabs follow its colored label, with a
/// line of its color beneath them.
struct TabStrip: View {
    @ObservedObject var store: TabStore
    @State private var frames: [UUID: CGRect] = [:]
    @State private var middleClickMonitor: Any?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.runs()) { run in
                Group {
                    switch run {
                    case .tab(let tab):
                        TabPill(tab: tab, store: store)
                    case .group(let group, let members):
                        GroupCluster(group: group, members: members, store: store)
                    }
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            Button { store.commandBar = .newTab } label: { Image(systemName: "plus") }
                .buttonStyle(.chrome)
                .help("New tab (⌘T)")
        }
        .onPreferenceChange(TabFrameKey.self) { frames = $0 }
        .onAppear { installMiddleClickMonitor() }
        .onDisappear { removeMiddleClickMonitor() }
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

/// A group's label, which collapses its tabs to a count, then the tabs over a line of its color.
private struct GroupCluster: View {
    let group: TabGroup
    let members: [BrowserModel]
    @ObservedObject var store: TabStore
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 2) {
            Button { store.toggleCollapse(group.id) } label: {
                HStack(spacing: 4) {
                    Text(group.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if group.collapsed {
                        Text("\(members.count)").font(.system(size: 10.5, weight: .medium)).opacity(0.75)
                    }
                }
                .foregroundStyle(group.color)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(group.color.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(group.collapsed ? "Show \u{201C}\(group.name)\u{201D}" : "Collapse \u{201C}\(group.name)\u{201D}")
            .contextMenu { GroupContextMenu(group: group, store: store) }
            .onDrop(of: [TabDrag.type], delegate: GroupDropDelegate(groupID: group.id, store: store, targeted: $targeted))
            .dropIndicator(targeted ? .into : nil, axis: .horizontal, color: group.color, radius: 11)

            if !group.collapsed {
                HStack(spacing: 2) {
                    ForEach(members, id: \.id) { tab in TabPill(tab: tab, store: store) }
                }
                .overlay(alignment: .bottom) {
                    Capsule().fill(group.color.opacity(0.7)).frame(height: 2).padding(.horizontal, 6).offset(y: 3)
                }
            }
        }
    }
}

private struct TabPill: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var zone: DropZone?
    @State private var width: CGFloat = 0

    private var isActive: Bool { store.activeID == tab.id }
    private var isAgent: Bool { store.isAgentTab(tab) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous) }

    var body: some View {
        content
            .background(
                ZStack {
                    shape
                        .fill(isActive ? palette.selection : hovering ? palette.hover : .clear)
                        .shadow(color: .black.opacity(isActive && !palette.isDark ? 0.07 : 0), radius: 3, y: 1)
                    GeometryReader { geo in
                        Color.clear.preference(key: TabFrameKey.self, value: [tab.id: geo.frame(in: .global)])
                    }
                }
            )
            .contentShape(shape)
            .onTapGesture { store.select(tab) }
            .onHover { hovering = $0 }
            .help(isAgent ? "The agent's tab" : tab.title)
            .animation(Theme.hover, value: isActive)
            .animation(Theme.hover, value: hovering)
            .contextMenu { if !isAgent { TabContextMenu(tab: tab, store: store) } }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .tabDraggable(tab, store: store)
            .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(target: tab, store: store, axis: .horizontal,
                                                                 extent: width, groups: !tab.isPinned, zone: $zone))
            .dropIndicator(zone, axis: .horizontal, color: palette.accent)
    }

    @ViewBuilder
    private var content: some View {
        if tab.isPinned {
            TabIcon(tab: tab, isAgent: isAgent).frame(width: 32, height: 32)
        } else {
            HStack(spacing: 7) {
                TabIcon(tab: tab, isAgent: isAgent)
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(isActive ? Theme.Text.bodyStrong : Theme.Text.body)
                    .foregroundStyle(isActive ? palette.ink : palette.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !isAgent && (hovering || isActive) {
                    Button { store.close(tab) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(ChromeButtonStyle(size: 18))
                    .help("Close tab (⌘W)")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(minWidth: 96, idealWidth: 180, maxWidth: 210)
            .frame(height: 32)
        }
    }
}

/// A tab's favicon (a globe until the page has one), with the agent's sparkle on the agent's
/// tab and a spinner while the page loads.
struct TabIcon: View {
    @ObservedObject var tab: BrowserModel
    var isAgent = false
    var size: CGFloat = 16
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = tab.favicon {
                Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.8)).foregroundStyle(palette.inkTertiary)
                    .frame(width: size, height: size)
            }
            if isAgent {
                Image(systemName: "sparkle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.sparkle)
                    .offset(x: 4, y: 3)
            }
            if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: size, height: size)
                    .background(palette.card.opacity(0.7), in: Circle())
            }
        }
    }
}

/// What a right click on one of the person's tabs offers, in the strip and in the sidebar.
struct TabContextMenu: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore

    var body: some View {
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
}

/// What a right click on a group's label or folder offers.
struct GroupContextMenu: View {
    let group: TabGroup
    @ObservedObject var store: TabStore

    var body: some View {
        Button(group.collapsed ? "Expand" : "Collapse") { store.toggleCollapse(group.id) }
        Menu("Color") {
            ForEach(Array(TabStore.groupColors.enumerated()), id: \.offset) { _, color in
                Button { store.recolor(group.id, to: color) } label: {
                    Label(color.description.capitalized, systemImage: color == group.color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Divider()
        Button("Ungroup") { store.ungroup(group.id) }
        Button("Close Group") { store.closeGroup(group.id) }
    }
}
