import SwiftUI

/// One tab: the Chromium view and the state the toolbar shows.
@MainActor
final class BrowserModel: NSObject, ObservableObject, ChromiumBrowserViewDelegate {
    /// The agent's tab, the first of the main window. It opens on the start page, which needs
    /// no network; the harness navigates it wherever a task begins.
    /// An Alloy view: the plain page `AgentDriver` was built for, which runs no extensions.
    static let shared = BrowserModel(url: startURL, chromeStyle: false)

    /// A tab here shows the start page, drawn by the app over an empty page.
    static let startURL = "about:blank"
    var isStart: Bool { address.isEmpty || address == Self.startURL }

    /// The tab's name in the strip and the sidebar.
    var displayTitle: String {
        if isStart { return "Start Page" }
        return title.isEmpty ? "New Tab" : title
    }

    let view: ChromiumBrowserView
    let id = UUID()

    @Published var favicon: NSImage?
    @Published var address = ""
    @Published var title = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress = 0.0

    /// The harness has this tab (between `AgentDriver`'s attach and detach). The page's card
    /// glows while it does, and the sidebar steps aside so the page keeps its width.
    @Published var isDriven = false

    /// A tab of a private window: nothing it visits is kept.
    let isIncognito: Bool

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

    /// `chromeStyle`: Chrome's own browser features in the page, Web Store extensions among
    /// them. The person's tabs have it (unless turned off in Settings); the agent's does not.
    init(url: String, incognito: Bool = false, chromeStyle: Bool? = nil) {
        isIncognito = incognito
        view = ChromiumBrowserView(url: url, incognito: incognito)
        view.usesChromeStyle = chromeStyle ?? BrowserSettings.shared.chromeTabs
        // A page's own drag and drop (a card to another column) is part of using it.
        view.allowsDragAndDrop = true
        address = url
        super.init()
        view.delegate = self
    }

    /// Opens what the person typed: a web address as it is, anything else as a search with the
    /// engine chosen in Settings.
    func go(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        view.loadURL(BrowserSettings.shared.resolve(trimmed))
    }

    /// The page's language, once told from its text, and how far translating it has got.
    @Published var pageLanguage: String?
    @Published var translation: TranslationState = .idle

    /// Translates the page in place, into the language chosen in Settings; again shows the
    /// original.
    func translate() {
        if translation == .done || translation == .working {
            Translator.shared.showOriginal(self)
        } else {
            Translator.shared.translate(self)
        }
    }

    /// The address last written to history, to give it its title when that comes later.
    private var recorded = ""
    /// Whether the page was loading at the last update: a boost goes in when a load ends.
    private var wasLoading = false

    /// Pages the person opens go to history; those the agent opens while it drives do not.
    private func noteInHistory() {
        guard !isDriven, !isIncognito else { return }
        if !isLoading, address != recorded {
            recorded = address
            HistoryStore.shared.record(url: address, title: title)
        } else if address == recorded {
            HistoryStore.shared.retitle(url: address, title: title)
        }
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
        // Once the load is done, so the icon is this page's and not the last one's.
        if let favicon, !isLoading, !isIncognito { FaviconCache.shared.remember(favicon, forURL: address) }
        noteInHistory()
        if isLoading && !wasLoading {
            // A new document: what was told or translated about the last one no longer holds.
            pageLanguage = nil
            translation = .idle
        }
        if wasLoading && !isLoading {
            BoostStore.shared.apply(to: self)
            Translator.shared.pageLoaded(self)
        }
        wasLoading = isLoading
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
