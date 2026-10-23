import SwiftUI

/// The triple-dot menu: the page actions a tab strip and address bar don't have room for.
struct BrowserMenu: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("New Tab", "plus.square", shortcut: "⌘T") { store.newTab() }
            row("Duplicate Tab", "plus.square.on.square") { store.duplicate(tab) }
            row(tab.isPinned ? "Unpin Tab" : "Pin Tab", tab.isPinned ? "pin.slash" : "pin") {
                store.togglePin(tab)
            }
            Divider().padding(.vertical, 4)
            row("Find in Page\u{2026}", "magnifyingglass", shortcut: "⌘F") { tab.startFinding() }
            row("Print\u{2026}", "printer", shortcut: "⌘P") { tab.printPage() }
            Divider().padding(.vertical, 4)
            zoomRow
            Divider().padding(.vertical, 4)
            layoutRow
            if !store.isAgentTab(tab) {
                Divider().padding(.vertical, 4)
                row("Close Tab", "xmark.square", shortcut: "⌘W") { store.close(tab) }
            }
        }
        .padding(8)
        .frame(width: 230)
    }

    private func row(_ title: String, _ systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var zoomRow: some View {
        HStack(spacing: 10) {
            Button { tab.zoomOut() } label: { Image(systemName: "minus") }
                .buttonStyle(.chrome)
                .disabled(tab.zoomLevel <= -7)
            Text("\(tab.zoomPercent)%")
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 40)
                .onTapGesture { tab.zoomReset() }
                .help("Reset zoom")
            Button { tab.zoomIn() } label: { Image(systemName: "plus") }
                .buttonStyle(.chrome)
                .disabled(tab.zoomLevel >= 7)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private var layoutRow: some View {
        HStack {
            Text("Tabs").font(.system(size: 12.5))
            Spacer()
            Picker("", selection: $store.verticalLayout) {
                Image(systemName: "menubar.rectangle").tag(false)
                Image(systemName: "sidebar.left").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
    }
}

/// The floating find-in-page bar: text, match count, step through, close.
struct FindBar: View {
    @ObservedObject var tab: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in page", text: $tab.findText)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 160)
                .onSubmit { tab.search(next: true, backward: NSEvent.modifierFlags.contains(.shift)) }
            if !tab.findText.isEmpty {
                Text(tab.findMatchCount == 0 ? "No results" : "\(tab.findActiveMatch)/\(tab.findMatchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button { tab.search(next: true, backward: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.chrome)
                .disabled(tab.findText.isEmpty)
                .help("Previous match (⇧↩)")
            Button { tab.search(next: true, backward: false) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.chrome)
                .disabled(tab.findText.isEmpty)
                .help("Next match (↩)")
            Button { tab.stopFinding() } label: { Image(systemName: "xmark") }
                .buttonStyle(.chrome)
                .help("Close (esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.top, 8)
        .padding(.trailing, 24)
        .onAppear { focused = true }
        .onExitCommand { tab.stopFinding() }
    }
}
