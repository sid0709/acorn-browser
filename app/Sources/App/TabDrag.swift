import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Dragging tabs: onto another tab's ends to move it there, onto its middle to group the two,
/// onto a group's label to join it, onto open space to leave its group, among the pinned tiles
/// to pin it. The agent's tab neither moves nor takes a drop.
@MainActor
enum TabDrag {
    /// A type of this app's own, so a tab dropped on a page is not taken for text.
    static let type = UTType(exportedAs: "com.acorn.browser.tab")

    static func item(_ tab: BrowserModel, store: TabStore) -> NSItemProvider {
        store.draggedTab = tab.id
        watchForEnd(store)
        let provider = NSItemProvider()
        let id = Data(tab.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(id, nil)
            return nil
        }
        return provider
    }

    /// SwiftUI says when a drag starts but not when one is let go somewhere that takes no tab:
    /// while it lasts, look every quarter second whether the button is still down.
    private static func watchForEnd(_ store: TabStore) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if NSEvent.pressedMouseButtons & 1 != 0 {
                watchForEnd(store)
            } else if store.draggedTab != nil {
                store.draggedTab = nil
            }
        }
    }
}

/// Where on a tab a drop would land.
enum DropZone: Equatable {
    case before, into, after
}

extension View {
    /// Makes a tab draggable, unless it is the agent's.
    @ViewBuilder
    func tabDraggable(_ tab: BrowserModel, store: TabStore) -> some View {
        if store.isAgentTab(tab) {
            self
        } else {
            onDrag { TabDrag.item(tab, store: store) }
        }
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

/// A drop on one tab. Its first and last quarters (along the list) put the dragged tab before
/// or after it; the middle half groups the two, where grouping is offered.
struct TabDropDelegate: DropDelegate {
    let target: BrowserModel
    let store: TabStore
    let axis: Axis
    let extent: CGFloat
    var groups = true
    @Binding var zone: DropZone?

    private func zone(for info: DropInfo) -> DropZone {
        let position = axis == .vertical ? info.location.y : info.location.x
        guard extent > 0 else { return .after }
        let fraction = position / extent
        if fraction < 0.25 { return .before }
        if fraction > 0.75 { return .after }
        if groups { return .into }
        return fraction < 0.5 ? .before : .after
    }

    private var dragged: BrowserModel? {
        guard let tab = store.dragged, tab !== target, !store.isAgentTab(target) else { return nil }
        return tab
    }

    func validateDrop(info: DropInfo) -> Bool { dragged != nil }

    func dropEntered(info: DropInfo) { if dragged != nil { zone = zone(for: info) } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dragged != nil else { return DropProposal(operation: .forbidden) }
        zone = zone(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            zone = nil
            store.draggedTab = nil
        }
        guard let tab = dragged else { return false }
        switch zone(for: info) {
        case .before: store.move(tab, to: target, after: false)
        case .after: store.move(tab, to: target, after: true)
        case .into: store.group(tab, with: target)
        }
        return true
    }
}

/// A drop on a group's label or folder: the tab joins the group.
struct GroupDropDelegate: DropDelegate {
    let groupID: UUID
    let store: TabStore
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard let tab = store.dragged else { return false }
        return tab.groupID != groupID
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            targeted = false
            store.draggedTab = nil
        }
        guard let tab = store.dragged else { return false }
        store.join(tab, groupID: groupID)
        return true
    }
}

/// A drop on open space (the rest of the sidebar's list, the strip's empty end) or among the
/// pinned tiles: out of any group to the end, or pinned.
struct SpaceDropDelegate: DropDelegate {
    enum Kind { case release, pin }
    let kind: Kind
    let store: TabStore
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard let tab = store.dragged else { return false }
        switch kind {
        case .release: return tab.groupID != nil || tab.isPinned
        case .pin: return !tab.isPinned
        }
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            targeted = false
            store.draggedTab = nil
        }
        guard let tab = store.dragged, validateDrop(info: info) else { return false }
        switch kind {
        case .release: store.release(tab)
        case .pin: store.pin(tab)
        }
        return true
    }
}
