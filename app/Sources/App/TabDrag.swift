import SwiftUI
import AppKit

/// Dragging tabs: onto another tab's ends to move it there, onto its middle to group the two
/// (or join the group the other is in), onto a group's label to join it, onto open space to
/// leave its group, among the pinned tiles to pin it, onto the page's right side to open it in
/// a split. The agent's tab neither moves nor takes a drop.
///
/// The drag is the app's own, not AppKit's: a drag gesture on the tab, and the drop targets'
/// frames in the window, looked up under the pointer. AppKit's drag went by the pasteboard,
/// where a tab is no type the system knows, and the page's Chromium view sits above SwiftUI and
/// took the drag over the page, so a drop came to nothing.
@MainActor
enum TabDrag {
    /// How far the pointer moves before a press on a tab becomes a drag.
    static let threshold: CGFloat = 6

    static func moved(_ tab: BrowserModel, store: TabStore, to location: CGPoint) {
        if store.draggedTab != tab.id {
            store.draggedTab = tab.id
            watchForEnd(store)
        }
        store.dragPointer.location = location
        let spot = spot(at: location, dragging: tab, in: store)
        if store.dropSpot != spot { store.dropSpot = spot }
    }

    static func ended(_ tab: BrowserModel, store: TabStore, at location: CGPoint) {
        let spot = spot(at: location, dragging: tab, in: store)
        finish(store)
        guard let spot else { return }
        switch spot.target {
        case .tab(let id):
            guard let target = store.tabs.first(where: { $0.id == id }) else { return }
            switch spot.zone {
            case .before: store.move(tab, to: target, after: false)
            case .after: store.move(tab, to: target, after: true)
            case .into: store.group(tab, with: target)
            case nil: break
            }
        case .group(let id): store.join(tab, groupID: id)
        case .release: store.release(tab)
        case .pin: store.pin(tab)
        case .split(let hostID):
            guard let host = store.tabs.first(where: { $0.id == hostID }) else { return }
            store.select(host)
            store.openSplit(with: tab)
        }
    }

    private static func finish(_ store: TabStore) {
        store.draggedTab = nil
        store.dropSpot = nil
    }

    /// A gesture can be cut short without an end (its view went away): while a drag lasts,
    /// look every quarter second whether the button is still down.
    private static func watchForEnd(_ store: TabStore) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard store.draggedTab != nil else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                watchForEnd(store)
            } else {
                finish(store)
            }
        }
    }

    /// The innermost target under the pointer (a tab over the list it sits in), if it takes
    /// this tab.
    static func spot(at point: CGPoint, dragging tab: BrowserModel, in store: TabStore) -> TabDropSpot? {
        let under = store.dropRegions.all
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let region = under else { return nil }
        switch region.target {
        case .tab(let id):
            guard let target = store.tabs.first(where: { $0.id == id }), target !== tab,
                  !store.isAgentTab(target) else { return nil }
            let extent = region.vertical ? region.frame.height : region.frame.width
            let position = region.vertical ? point.y - region.frame.minY : point.x - region.frame.minX
            let fraction = extent > 0 ? position / extent : 1
            let zone: DropZone
            if fraction < 0.25 {
                zone = .before
            } else if fraction > 0.75 {
                zone = .after
            } else if region.groups {
                zone = .into
            } else {
                zone = fraction < 0.5 ? .before : .after
            }
            return TabDropSpot(target: region.target, zone: zone)
        case .group(let id):
            return tab.groupID == id ? nil : TabDropSpot(target: region.target)
        case .release:
            return tab.groupID != nil || tab.isPinned ? TabDropSpot(target: region.target) : nil
        case .pin:
            return tab.isPinned ? nil : TabDropSpot(target: region.target)
        case .split(let hostID):
            return hostID == tab.id ? nil : TabDropSpot(target: region.target)
        }
    }
}

/// Something a tab can be dropped on.
enum TabDropTarget: Hashable {
    case tab(UUID)
    case group(UUID)
    /// Open space: out of any group, and unpinned.
    case release
    /// Among the pinned tiles.
    case pin
    /// The page of this tab, to open the dragged one beside it.
    case split(UUID)
}

/// Where on a tab a drop would land.
enum DropZone: Equatable {
    case before, into, after
}

/// Where the dragged tab would land now.
struct TabDropSpot: Equatable {
    let target: TabDropTarget
    var zone: DropZone?
}

/// The drop targets on screen and their frames in the window, kept where a change redraws
/// nothing: they move with every scroll and animation, and only a drag reads them.
@MainActor
final class TabDropRegions {
    struct Region {
        let target: TabDropTarget
        var frame: CGRect
        var vertical: Bool
        /// A drop on the middle groups the two tabs.
        var groups: Bool
    }

    private var regions: [UUID: Region] = [:]

    var all: Dictionary<UUID, Region>.Values { regions.values }

    func set(_ key: UUID, _ region: Region) { regions[key] = region }
    func setGroups(_ key: UUID, _ groups: Bool) { regions[key]?.groups = groups }
    func remove(_ key: UUID) { regions[key] = nil }
}

/// The pointer during a drag, which only the floating tab under it watches.
@MainActor
final class TabDragPointer: ObservableObject {
    @Published var location: CGPoint = .zero
}

extension View {
    /// Makes a tab draggable, unless it is the agent's. It dims where it was while it is away.
    @ViewBuilder
    func tabDraggable(_ tab: BrowserModel, store: TabStore) -> some View {
        if store.isAgentTab(tab) {
            self
        } else {
            modifier(TabDragSource(tab: tab, store: store))
        }
    }

    /// Marks the view as somewhere a tab can be dropped.
    func tabDropTarget(_ target: TabDropTarget, store: TabStore, vertical: Bool = false,
                       groups: Bool = false) -> some View {
        modifier(TabDropRegistration(target: target, store: store, vertical: vertical, groups: groups))
    }

    /// Shows where a dragged tab would go: a line at the near end, or a ring for "into".
    func dropIndicator(_ zone: DropZone?, axis: Axis, color: Color, radius: CGFloat = Theme.Radius.row + 1) -> some View {
        overlay {
            switch zone {
            case .into:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                    .allowsHitTesting(false)
            case .before, .after:
                let alignment: Alignment = axis == .vertical
                    ? (zone == .before ? .top : .bottom)
                    : (zone == .before ? .leading : .trailing)
                ZStack(alignment: alignment) {
                    Color.clear
                    Capsule().fill(color)
                        .frame(width: axis == .vertical ? nil : 2, height: axis == .vertical ? 2 : nil)
                        .offset(x: axis == .horizontal ? (zone == .before ? -2 : 2) : 0,
                                y: axis == .vertical ? (zone == .before ? -2 : 2) : 0)
                }
                .allowsHitTesting(false)
            case nil:
                EmptyView()
            }
        }
    }
}

extension TabStore {
    /// Where on this tab the dragged one would land, if it is the one under the pointer.
    func dropZone(on tab: BrowserModel) -> DropZone? {
        guard let dropSpot, dropSpot.target == .tab(tab.id) else { return nil }
        return dropSpot.zone
    }

    func isDropTargeted(_ target: TabDropTarget) -> Bool { dropSpot?.target == target }
}

private struct TabDragSource: ViewModifier {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore

    func body(content: Content) -> some View {
        content
            .opacity(store.draggedTab == tab.id ? 0.45 : 1)
            .gesture(DragGesture(minimumDistance: TabDrag.threshold, coordinateSpace: .global)
                .onChanged { TabDrag.moved(tab, store: store, to: $0.location) }
                .onEnded { TabDrag.ended(tab, store: store, at: $0.location) })
    }
}

private struct TabDropRegistration: ViewModifier {
    let target: TabDropTarget
    let store: TabStore
    let vertical: Bool
    let groups: Bool
    @State private var key = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                store.dropRegions.set(key, .init(target: target, frame: frame, vertical: vertical, groups: groups))
            }
            .onChange(of: groups) { _, now in store.dropRegions.setGroups(key, now) }
            .onDisappear { store.dropRegions.remove(key) }
    }
}

/// The tab under the pointer while it is dragged, drawn over the whole window.
struct TabDragGhost: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var pointer: TabDragPointer
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            HStack(spacing: 7) {
                TabIcon(tab: tab)
                Text(tab.displayTitle)
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: 200, height: 30, alignment: .leading)
            .glass(RoundedRectangle(cornerRadius: Theme.Radius.row + 1, style: .continuous), weight: .overlay)
            .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.14), radius: 12, y: 5)
            .rotationEffect(.degrees(-2))
            .position(x: pointer.location.x - origin.x + 24, y: pointer.location.y - origin.y + 14)
        }
        .allowsHitTesting(false)
    }
}
