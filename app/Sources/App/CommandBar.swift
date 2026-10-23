import SwiftUI
import AppKit

/// The one place to go anywhere or do anything: an address or a search, an open tab, a
/// bookmark, a page from history, a command, or a task for the agent (`Suggestions` ranks
/// them). ⌘T opens it for a new tab, ⌘L (or a click on the address) for the tab shown.
struct CommandBar: View {
    @ObservedObject var store: TabStore
    @ObservedObject var runner: AgentRunner
    let mode: CommandBarMode
    @Environment(\.palette) private var palette
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selection = 0
    @State private var keys = SuggestionKeys()
    @FocusState private var focused: Bool

    private static let width: CGFloat = 600

    private var target: BrowserModel? {
        guard case .tab(let id) = mode else { return nil }
        return store.tabs.first { $0.id == id }
    }

    private var items: [CommandItem] {
        Suggestions(store: store, runner: runner, mode: mode, openSettings: { openSettings() }).items(for: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(palette.isDark ? 0.4 : 0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            panel.padding(.top, 84)
        }
        .onAppear(perform: start)
        .onDisappear { keys.stop() }
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
                SuggestionList(items: items, selection: $selection) { run(items, at: $0) }
            }
        }
        .frame(width: Self.width)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.popover + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover + 2, style: .continuous).strokeBorder(palette.hairline))
        .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.2), radius: 30, y: 12)
    }

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
        if let target, !target.isStart { query = target.address }
        DispatchQueue.main.async {
            focused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        keys.start(
            up: { selection = max(selection - 1, 0) },
            down: { selection = min(selection + 1, max(items.count - 1, 0)) },
            escape: close)
    }
}
