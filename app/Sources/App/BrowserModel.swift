import SwiftUI

/// One tab: the Chromium view and the state the toolbar shows.
@MainActor
final class BrowserModel: NSObject, ObservableObject, ChromiumBrowserViewDelegate {
    /// The one tab, until there are several.
    static let shared = BrowserModel(url: "https://www.wikipedia.org")

    let view: ChromiumBrowserView
    let id = UUID()

    @Published var favicon: NSImage?
    @Published var address = ""
    @Published var title = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress = 0.0

    /// Tab organization: not the page's own state, but kept here since every tab already
    /// carries one of these and `TabStrip` already observes it per tab.
    @Published var isPinned = false
    @Published var groupID: UUID?

    /// CEF's zoom levels: 0 is 100%, and each whole step is about a 20% change.
    @Published var zoomLevel: Double = 0 { didSet { view.zoomLevel = zoomLevel } }
    var zoomPercent: Int { Int((pow(1.2, zoomLevel) * 100).rounded()) }
    func zoomIn() { zoomLevel = min(zoomLevel + 1, 7) }
    func zoomOut() { zoomLevel = max(zoomLevel - 1, -7) }
    func zoomReset() { zoomLevel = 0 }

    /// Find-in-page. `findText`'s didSet restarts the search; `Enter`/`Shift+Enter` in the
    /// find bar step through it without retyping.
    @Published var isFinding = false
    @Published var findText = "" {
        didSet { if isFinding { search(next: false) } }
    }
    @Published var findMatchCount = 0
    @Published var findActiveMatch = 0

    func startFinding() { isFinding = true }

    func search(next: Bool, backward: Bool = false) {
        guard !findText.isEmpty else {
            findMatchCount = 0
            findActiveMatch = 0
            view.stopFinding(true)
            return
        }
        view.find(findText, forward: !backward, matchCase: false, findNext: next)
    }

    func stopFinding() {
        isFinding = false
        findText = ""
        findMatchCount = 0
        findActiveMatch = 0
        view.stopFinding(true)
    }

    func printPage() { view.printPage() }

    init(url: String) {
        view = ChromiumBrowserView(url: url)
        // A page's own drag and drop (a card to another column) is part of using it.
        view.allowsDragAndDrop = true
        address = url
        super.init()
        view.delegate = self
    }

    /// Opens what the person typed: a web address as it is, anything else as a search.
    func go(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        view.loadURL(Self.resolve(trimmed))
    }

    private static func resolve(_ text: String) -> String {
        if text.contains("://") { return text }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost { return "https://" + text }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return "https://www.google.com/search?q=" + query
    }

    // MARK: ChromiumBrowserViewDelegate

    func browserViewDidUpdateState(_ browserView: ChromiumBrowserView) {
        address = browserView.currentURL
        title = browserView.title
        isLoading = browserView.isLoading
        canGoBack = browserView.canGoBack
        canGoForward = browserView.canGoForward
        progress = browserView.loadingProgress
        favicon = browserView.favicon
    }

    func browserView(_ browserView: ChromiumBrowserView,
                     adoptPopup popup: ChromiumBrowserView,
                     inBackground: Bool) -> Bool {
        // One tab for now: a page that opens a window is blocked until there are tabs.
        false
    }

    func browserViewDidRequestClose(_ browserView: ChromiumBrowserView) {}

    func browserView(_ browserView: ChromiumBrowserView, didChangeFullscreen fullscreen: Bool) {}

    func browserView(_ browserView: ChromiumBrowserView, didUpdateFindCount count: Int, activeMatch: Int) {
        findMatchCount = count
        findActiveMatch = activeMatch
    }
}
