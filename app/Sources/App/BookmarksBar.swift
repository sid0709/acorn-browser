import SwiftUI
import AppKit

/// The bookmarks under the toolbar, Chrome's way: each page saved with ⌘D or the star, as its
/// icon and title, in the order saved. A click opens it in this tab, ⌘-click in a new one; what
/// does not fit waits behind » at the end. ⇧⌘B shows or hides the bar. It steps aside while the
/// agent drives the tab, so the page the agent sees keeps its height.
struct BookmarksBar: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @Environment(\.palette) private var palette

    static let height: CGFloat = 30
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let maxTitleWidth: CGFloat = 150
    /// An item's room beside its title: the icon, the gap after it, and the padding.
    private static let chrome: CGFloat = 16 + 6 + 16
    private static let spacing: CGFloat = 2
    private static let overflowWidth: CGFloat = 28

    /// The oldest first, as Chrome adds each new bookmark at the end of the bar.
    private var marks: [Bookmark] { bookmarks.bookmarks.reversed() }

    var body: some View {
        GeometryReader { geo in
            let marks = self.marks
            let shown = Self.fitting(marks, in: geo.size.width - 2 * Theme.Space.s)
            HStack(spacing: Self.spacing) {
                if marks.isEmpty {
                    Text("Bookmark a page with ⌘D or the star in the address, and it shows here")
                        .font(Theme.Text.caption)
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                        .padding(.leading, Theme.Space.xs)
                }
                ForEach(marks.prefix(shown)) { mark in
                    BookmarkItem(mark: mark, tab: tab, store: store)
                }
                Spacer(minLength: 0)
                if shown < marks.count { overflow(Array(marks.dropFirst(shown))) }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    /// How many items fit, keeping room for » when some do not.
    private static func fitting(_ marks: [Bookmark], in width: CGFloat) -> Int {
        let widths = marks.map(itemWidth)
        let total = widths.reduce(0) { $0 + $1 + spacing }
        if total <= width { return marks.count }
        var used: CGFloat = overflowWidth
        for (index, item) in widths.enumerated() {
            used += item + spacing
            if used > width { return index }
        }
        return marks.count
    }

    static func itemWidth(_ mark: Bookmark) -> CGFloat { titleWidth(mark) + chrome }

    /// The title's own width, up to a limit past which it is cut short.
    static func titleWidth(_ mark: Bookmark) -> CGFloat {
        let text = (mark.title as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(text) + 1, maxTitleWidth)
    }

    private func overflow(_ rest: [Bookmark]) -> some View {
        Menu {
            ForEach(rest) { mark in
                Button(mark.title) { BookmarkItem.open(mark, from: tab, store: store) }
            }
        } label: {
            Image(systemName: "chevron.right.2")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: Self.overflowWidth)
        .help("More bookmarks")
    }
}

/// One bookmark on the bar.
private struct BookmarkItem: View {
    let mark: Bookmark
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(mark.title)
                .font(.system(size: 12))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: BookmarksBar.titleWidth(mark), alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                store.open(mark.url, in: .newTab)
            } else {
                Self.open(mark, from: tab, store: store)
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .help("\(mark.title)\n\(mark.url)")
        .contextMenu {
            Button("Open") { Self.open(mark, from: tab, store: store) }
            Button("Open in New Tab") { store.open(mark.url, in: .newTab) }
            Divider()
            Button("Copy Link") { copyToPasteboard(mark.url) }
            Divider()
            Button("Remove Bookmark") { BookmarkStore.shared.remove(mark) }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = FaviconCache.shared.image(forURL: mark.url) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(palette.inkTertiary)
                .frame(width: 16, height: 16)
        }
    }

    /// In the tab the bar belongs to, as the address would.
    static func open(_ mark: Bookmark, from tab: BrowserModel, store: TabStore) {
        store.open(mark.url, in: .tab(tab.id))
    }
}
