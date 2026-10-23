import SwiftUI

/// The open tabs. The first is the one the agent works in; the others are the person's own.
@MainActor
final class TabStore: ObservableObject {
    static let shared = TabStore()

    @Published private(set) var tabs: [BrowserModel] = [BrowserModel.shared]
    @Published var activeID: UUID = BrowserModel.shared.id

    var active: BrowserModel { tabs.first { $0.id == activeID } ?? BrowserModel.shared }

    func isAgentTab(_ tab: BrowserModel) -> Bool { tab === BrowserModel.shared }

    func newTab(url: String = "https://www.google.com") {
        let tab = BrowserModel(url: url)
        tabs.append(tab)
        activeID = tab.id
    }

    func select(_ tab: BrowserModel) { activeID = tab.id }

    func close(_ tab: BrowserModel) {
        guard !isAgentTab(tab), let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
        tab.view.destroyBrowser()
    }
}
