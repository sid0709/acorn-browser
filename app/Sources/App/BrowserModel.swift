import SwiftUI

/// One tab: the Chromium view and the state the toolbar shows.
@MainActor
final class BrowserModel: NSObject, ObservableObject, ChromiumBrowserViewDelegate {
    /// The one tab, until there are several.
    static let shared = BrowserModel(url: "https://www.wikipedia.org")

    let view: ChromiumBrowserView

    @Published var address = ""
    @Published var title = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress = 0.0

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
    }

    func browserView(_ browserView: ChromiumBrowserView,
                     adoptPopup popup: ChromiumBrowserView,
                     inBackground: Bool) -> Bool {
        // One tab for now: a page that opens a window is blocked until there are tabs.
        false
    }

    func browserViewDidRequestClose(_ browserView: ChromiumBrowserView) {}

    func browserView(_ browserView: ChromiumBrowserView, didChangeFullscreen fullscreen: Bool) {}
}
