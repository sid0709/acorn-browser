import SwiftUI
import AppKit

/// Two tabs side by side, each in its own card with its own toolbar, and a handle between them
/// that sets their shares. The pane last clicked is the active tab and wears the accent's edge.
struct SplitView: View {
    @ObservedObject var store: TabStore
    @ObservedObject var left: BrowserModel
    @ObservedObject var right: BrowserModel
    @State private var dragStart: CGFloat?
    @State private var clickMonitor: Any?
    @State private var hoveringHandle = false
    @Environment(\.palette) private var palette

    private static let handleWidth: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let available = max(geo.size.width - Self.handleWidth, 1)
            let leftWidth = store.splitLeftWidth(in: available)
            HStack(spacing: 0) {
                pane(left).frame(width: leftWidth)
                handle(available: available, leftWidth: leftWidth)
                pane(right)
            }
        }
        .onAppear(perform: watchClicks)
        .onDisappear(perform: stopWatchingClicks)
    }

    private func pane(_ tab: BrowserModel) -> some View {
        PageCard(tab: tab, store: store, showsToolbar: true, focused: store.activeID == tab.id)
            .id(tab.id)
    }

    /// Drag to share the width out; a double click evens it.
    private func handle(available: CGFloat, leftWidth: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(hoveringHandle || dragStart != nil ? palette.inkTertiary : .clear)
                .frame(width: 3, height: 36)
        }
        .frame(width: Self.handleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveringHandle = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? leftWidth
                dragStart = start
                store.splitRatio = min(max((start + value.translation.width) / available, 0.2), 0.8)
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { withAnimation(Theme.layout) { store.splitRatio = 0.5 } }
        .help("Drag to resize; double-click to even out")
    }

    /// A click in a page goes to Chromium, not SwiftUI: watch the window's clicks to learn
    /// which pane was clicked, and make its tab the active one.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            for tab in [left, right] where tab.view.window === event.window {
                let point = tab.view.convert(event.locationInWindow, from: nil)
                if tab.view.bounds.contains(point), store.activeID != tab.id {
                    store.select(tab)
                }
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// A tab dropped on the right edge of a page opens beside it.
struct SplitDropDelegate: DropDelegate {
    let store: TabStore
    let host: BrowserModel
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard let tab = store.dragged else { return false }
        return tab !== host
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            targeted = false
            store.draggedTab = nil
        }
        guard let tab = store.dragged, tab !== host else { return false }
        store.select(host)
        store.openSplit(with: tab)
        return true
    }
}
