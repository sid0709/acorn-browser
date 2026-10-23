import SwiftUI

/// The row of tabs along the top of the window, with the new-tab button after them.
struct TabStrip: View {
    @ObservedObject var store: TabStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs, id: \.id) { tab in
                TabPill(tab: tab, store: store)
            }
            Button { store.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.chrome)
                .help("New tab")
        }
    }
}

private struct TabPill: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @State private var hovering = false

    private var isActive: Bool { store.activeID == tab.id }
    private var isAgent: Bool { store.isAgentTab(tab) }

    var body: some View {
        HStack(spacing: 7) {
            icon
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(Theme.ink.opacity(isActive ? 0.95 : 0.65))
                .lineLimit(1)
            Spacer(minLength: 0)
            if !isAgent && (hovering || isActive) {
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink.opacity(0.5))
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 90, idealWidth: 170, maxWidth: 200)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color.white.opacity(0.9) : Color.white.opacity(hovering ? 0.35 : 0))
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 4, y: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .onHover { hovering = $0 }
        .help(isAgent ? "The agent's tab" : tab.title)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    @ViewBuilder
    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = tab.favicon {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.45))
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
                    .background(Color.white.opacity(0.7), in: Circle())
            }
        }
    }
}
