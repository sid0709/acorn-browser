import SwiftUI
import AppKit

/// The tabs down the left of the window, Arc's way, below the window's top row (which holds the
/// window's buttons, navigation and the address): pinned tabs as tiles, the agent's tab, then
/// groups as folders and the open tabs, with the theme, the agent toggle, extensions, the menu
/// and a new tab along the bottom. It sits on the canvas itself rather than in a card.
struct Sidebar: View {
    @ObservedObject var store: TabStore
    @ObservedObject var runner: AgentRunner
    @Binding var showAgent: Bool
    @Environment(\.palette) private var palette
    @State private var choosingTheme = false
    @State private var showingMenu = false
    @State private var pinTargeted = false
    @State private var releaseTargeted = false

    private var favorites: [BrowserModel] { store.tabs.filter { $0.isPinned && !store.isAgentTab($0) } }

    /// A tab the list shows on its own row: not pinned, not the agent's.
    private func listed(_ tab: BrowserModel) -> Bool { !tab.isPinned && !store.isAgentTab(tab) }

    /// The list's runs. A split's two tabs share one row, at the left one's place, when both
    /// would be listed.
    private var listRuns: [TabRun] {
        store.runs { tab in
            guard listed(tab) else { return false }
            if let split = store.split, split.right == tab.id,
               let left = store.tabs.first(where: { $0.id == split.left }), listed(left) { return false }
            return true
        }
    }

    private func splitPartner(of tab: BrowserModel) -> BrowserModel? {
        guard let split = store.split, split.left == tab.id,
              let right = store.tabs.first(where: { $0.id == split.right }), listed(right) else { return nil }
        return right
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !favorites.isEmpty { favoritesGrid } else if store.draggedTab != nil { pinPlaceholder }
            if store.hasAgent { AgentRow(agentTab: BrowserModel.shared, store: store, runner: runner) }
            Rectangle().fill(palette.hairline).frame(height: 1).padding(.horizontal, Theme.Space.xs)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Button { store.commandBar = .newTab } label: {
                        Label("New Tab", systemImage: "plus").foregroundStyle(palette.inkSecondary)
                    }
                    .buttonStyle(.row)
                    ForEach(listRuns) { run in
                        switch run {
                        case .tab(let tab):
                            if let partner = splitPartner(of: tab) {
                                SidebarSplitRow(left: tab, right: partner, store: store)
                            } else {
                                SidebarTabRow(tab: tab, store: store)
                            }
                        case .group(let group, let members):
                            SidebarFolder(group: group, members: members, store: store)
                        }
                    }
                    // Open space below the tabs: a tab dropped here leaves its group or pin.
                    RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous)
                        .fill(releaseTargeted ? palette.accent.opacity(0.1) : .clear)
                        .frame(height: 64)
                        .contentShape(Rectangle())
                        .onDrop(of: [TabDrag.type],
                                delegate: SpaceDropDelegate(kind: .release, store: store, targeted: $releaseTargeted))
                }
            }
            .scrollIndicators(.never)
            footer
        }
        .padding(.leading, Theme.Space.s + 2)
        .padding(.trailing, Theme.Space.xs)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.s)
    }

    private var favoritesGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s),
                            count: store.sidebarWidth < 232 ? 3 : 4)
        return LazyVGrid(columns: columns, spacing: Theme.Space.s) {
            ForEach(favorites, id: \.id) { tab in FavoriteTile(tab: tab, store: store) }
        }
        .onDrop(of: [TabDrag.type], delegate: SpaceDropDelegate(kind: .pin, store: store, targeted: $pinTargeted))
    }

    /// Where a tab is dropped to pin it, while there are no pinned tabs to drop it among.
    private var pinPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin")
            Text("Drop here to pin")
        }
        .font(Theme.Text.secondary)
        .foregroundStyle(pinTargeted ? palette.accent : palette.inkTertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            .strokeBorder(pinTargeted ? palette.accent : palette.inkTertiary, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
        .contentShape(Rectangle())
        .onDrop(of: [TabDrag.type], delegate: SpaceDropDelegate(kind: .pin, store: store, targeted: $pinTargeted))
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { choosingTheme.toggle() } label: { Image(systemName: "paintpalette") }
                .buttonStyle(.chrome)
                .help("Theme")
                .popover(isPresented: $choosingTheme, arrowEdge: .top) { ThemePicker() }
            if store.hasAgent {
                Button { withAnimation(Theme.layout) { showAgent.toggle() } } label: {
                    Image(systemName: "sparkles").foregroundStyle(Theme.sparkle)
                }
                .buttonStyle(.chrome)
                .help(showAgent ? "Hide the agent (⌘K)" : "Ask the agent (⌘K)")
            }
            Spacer(minLength: 0)
            ExtensionsButton(store: store)
            Button { showingMenu = true } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.chrome)
                .help("More")
                .popover(isPresented: $showingMenu, arrowEdge: .top) {
                    BrowserMenu(tab: store.active, store: store, isPresented: $showingMenu)
                }
            Button { store.commandBar = .newTab } label: { Image(systemName: "plus") }
                .buttonStyle(.chrome)
                .help("New tab (⌘T)")
        }
    }
}

/// A pinned tab as a tile: its icon on a soft square, ringed while it is the one shown.
private struct FavoriteTile: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var zone: DropZone?
    @State private var width: CGFloat = 0

    private var isActive: Bool { store.activeID == tab.id }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous) }

    var body: some View {
        TabIcon(tab: tab, size: 18)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(shape.fill(isActive ? palette.selection : palette.selection.opacity(hovering ? 0.75 : 0.45)))
            .overlay(shape.strokeBorder(palette.accent.opacity(isActive ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(shape)
            .onTapGesture { store.select(tab) }
            .onHover { hovering = $0 }
            .animation(Theme.hover, value: hovering)
            .help(tab.title)
            .contextMenu { TabContextMenu(tab: tab, store: store) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .tabDraggable(tab, store: store)
            .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(target: tab, store: store, axis: .horizontal,
                                                                 extent: width, groups: false, zone: $zone))
            .dropIndicator(zone, axis: .horizontal, color: palette.accent, radius: Theme.Radius.tile)
    }
}

/// The agent's tab, kept apart from the person's: it cannot be closed, grouped or moved, and
/// it says when the agent is at work in it.
private struct AgentRow: View {
    @ObservedObject var agentTab: BrowserModel
    @ObservedObject var store: TabStore
    @ObservedObject var runner: AgentRunner
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var isActive: Bool { store.activeID == agentTab.id }
    private var working: Bool { agentTab.isDriven || runner.isRunning }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Theme.sparkle).frame(width: 18, height: 18)
                Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Agent").font(isActive ? Theme.Text.bodyStrong : Theme.Text.body).foregroundStyle(palette.ink)
                Text(agentTab.displayTitle)
                    .font(Theme.Text.caption).foregroundStyle(palette.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if working {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Working").font(Theme.Text.caption).foregroundStyle(palette.inkSecondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 42)
        .background(SidebarRowBackground(active: isActive, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { store.select(agentTab) }
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: working)
        .help("The agent's tab: the page it works in")
    }
}

/// One of the person's tabs in the sidebar's list.
private struct SidebarTabRow: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var zone: DropZone?

    private static let height: CGFloat = 34
    private var isActive: Bool { store.activeID == tab.id }

    var body: some View {
        HStack(spacing: 9) {
            TabIcon(tab: tab)
            Text(tab.displayTitle)
                .font(isActive ? Theme.Text.bodyStrong : Theme.Text.body)
                .foregroundStyle(isActive ? palette.ink : palette.ink.opacity(0.82))
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(ChromeButtonStyle(size: 20))
                .help("Close tab (⌘W)")
            }
        }
        .padding(.leading, Theme.Space.s + 1)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: Self.height)
        .background(SidebarRowBackground(active: isActive, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .onHover { hovering = $0 }
        .help(tab.title)
        .contextMenu { TabContextMenu(tab: tab, store: store) }
        .tabDraggable(tab, store: store)
        .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(target: tab, store: store, axis: .vertical,
                                                             extent: Self.height, zone: $zone))
        .dropIndicator(zone, axis: .vertical, color: palette.accent)
    }
}

/// A split's two tabs on one row, as halves; a click on either shows the split with that one
/// in use.
private struct SidebarSplitRow: View {
    @ObservedObject var left: BrowserModel
    @ObservedObject var right: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var isActive: Bool { store.activeID == left.id || store.activeID == right.id }

    var body: some View {
        HStack(spacing: 0) {
            half(left)
            Rectangle().fill(palette.hairline).frame(width: 1, height: 18)
            half(right)
        }
        .frame(height: 34)
        .background(SidebarRowBackground(active: isActive, hovering: hovering))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Swap Sides") { store.swapSplit() }
            Button("Close Split View") { store.closeSplit() }
        }
    }

    private func half(_ tab: BrowserModel) -> some View {
        HStack(spacing: 7) {
            TabIcon(tab: tab, size: 14)
            Text(tab.displayTitle)
                .font(store.activeID == tab.id ? Theme.Text.bodyStrong : Theme.Text.body)
                .foregroundStyle(store.activeID == tab.id ? palette.ink : palette.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .help(tab.title)
    }
}

/// A tab group as a folder: a disclosure, the group's color and name (a double click renames
/// it), and its tabs indented beneath.
private struct SidebarFolder: View {
    let group: TabGroup
    let members: [BrowserModel]
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var renaming = false
    @State private var name = ""
    @State private var targeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !group.collapsed {
                ForEach(members, id: \.id) { tab in
                    SidebarTabRow(tab: tab, store: store).padding(.leading, Theme.Space.m)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.inkTertiary)
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .frame(width: 10)
            Image(systemName: group.collapsed ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(group.color)
            if renaming {
                TextField("Group", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(palette.ink)
                    .focused($nameFocused)
                    .onSubmit(finishRenaming)
                    .onExitCommand { renaming = false }
                    .onChange(of: nameFocused) { _, now in if !now { finishRenaming() } }
            } else {
                Text(group.name).font(Theme.Text.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
            }
            Spacer(minLength: 0)
            if group.collapsed {
                Text("\(members.count)").font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
                    .padding(.trailing, Theme.Space.s)
            }
        }
        .padding(.leading, Theme.Space.xs + 1)
        .frame(height: 32)
        .background(SidebarRowBackground(active: false, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRenaming() }
        .onTapGesture { store.toggleCollapse(group.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename\u{2026}") { startRenaming() }
            GroupContextMenu(group: group, store: store)
        }
        .onDrop(of: [TabDrag.type], delegate: GroupDropDelegate(groupID: group.id, store: store, targeted: $targeted))
        .dropIndicator(targeted ? .into : nil, axis: .vertical, color: group.color)
        .onAppear { renameIfJustMade() }
        .onChange(of: store.renamingGroup) { _, _ in renameIfJustMade() }
    }

    /// A group a drag just made opens its name for typing.
    private func renameIfJustMade() {
        guard store.renamingGroup == group.id else { return }
        store.renamingGroup = nil
        startRenaming()
    }

    private func startRenaming() {
        name = group.name
        renaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        guard renaming else { return }
        renaming = false
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { store.rename(group.id, to: trimmed) }
    }
}

/// The fill under a sidebar row: a raised white (or, in dark, a lighter) pill while it is the
/// one shown, a faint one under the pointer.
private struct SidebarRowBackground: View {
    let active: Bool
    let hovering: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous)
            .fill(active ? palette.selection : hovering ? palette.hover : .clear)
            .shadow(color: .black.opacity(active && !palette.isDark ? 0.06 : 0), radius: 2, y: 1)
            .animation(Theme.hover, value: hovering)
    }
}

/// The sidebar's trailing edge: drag to set its width, which is kept between launches.
struct SidebarResizeHandle: View {
    @ObservedObject var store: TabStore
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? store.sidebarWidth
                    startWidth = start
                    let range = TabStore.sidebarWidths
                    store.sidebarWidth = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startWidth = nil })
    }
}
