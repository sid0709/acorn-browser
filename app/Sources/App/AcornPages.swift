import SwiftUI

/// A page the app draws itself, at an `acorn://` address, the way Chrome's own pages live at
/// `chrome://`. Chromium cannot load the scheme, and in Alloy views it has no settings or
/// extensions page of its own, so the tab loads an empty page marked with the page's name
/// underneath (`about:blank#acorn-settings/privacy`) and the app draws the page over it, as it
/// does the start page. The marked page keeps back, forward, reload and duplicate working.
enum AcornPage: String, CaseIterable {
    case settings, extensions

    static let scheme = "acorn"
    private static let marker = "about:blank#acorn-"

    var title: String {
        switch self {
        case .settings: "Settings"
        case .extensions: "Extensions"
        }
    }

    var icon: String {
        switch self {
        case .settings: "gearshape"
        case .extensions: "puzzlepiece.extension"
        }
    }

    /// The page, or one part of it ("acorn://settings/privacy"), as the address shows it.
    func address(_ part: String? = nil) -> String {
        "\(Self.scheme)://\(rawValue)" + (part.map { "/\($0)" } ?? "")
    }

    /// What a tab really loads for an address: the marked empty page for one of these (Chrome's
    /// own `chrome://settings` and `chrome://extensions` included, which Acorn's tabs cannot
    /// show), anything else as it is.
    static func loadable(_ url: String) -> String {
        guard let location = location(typed: url) else { return url }
        return marker + location.page.rawValue + (location.part.map { "/\($0)" } ?? "")
    }

    /// The page a tab's loaded address stands for, if it is one of these.
    static func location(loaded: String) -> AcornLocation? {
        guard loaded.hasPrefix(marker) else { return nil }
        return location(path: String(loaded.dropFirst(marker.count)))
    }

    private static func location(typed url: String) -> AcornLocation? {
        let lowered = url.lowercased()
        for prefix in ["\(scheme)://", "chrome://"] where lowered.hasPrefix(prefix) {
            return location(path: String(url.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func location(path: String) -> AcornLocation? {
        let pieces = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = pieces.first, let page = AcornPage(rawValue: first.lowercased()) else { return nil }
        let part = pieces.count > 1 ? pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        return AcornLocation(page: page, part: part.isEmpty ? nil : part)
    }
}

/// Where on one of the app's own pages a tab is: the page, and the part of it (a section of
/// Settings, an extension's details).
struct AcornLocation: Equatable {
    let page: AcornPage
    let part: String?

    var address: String { page.address(part) }
}

/// The app's page shown over a tab's empty page.
struct AcornPageView: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    let location: AcornLocation

    var body: some View {
        switch location.page {
        case .settings: SettingsPage(tab: tab, store: store, part: location.part)
        case .extensions: ExtensionsManager(tab: tab, store: store, part: location.part)
        }
    }
}

extension TabStore {
    /// Opens one of the app's pages: in the tab shown when that is an empty one of the person's,
    /// in the tab already showing it, or in a new tab. Never in the agent's tab, which the
    /// harness may take at any moment.
    func openPage(_ page: AcornPage, part: String? = nil) {
        let address = page.address(part)
        if !isAgentTab(active), active.isStart || active.acornLocation?.page == page {
            active.load(address)
        } else if let tab = tabs.first(where: { !isAgentTab($0) && $0.acornLocation?.page == page }) {
            if part != nil { tab.load(address) }
            select(tab)
        } else {
            newTab(url: address)
        }
    }
}

// MARK: - Site permissions

/// What the person decided when a site asked for something (the camera, the location), kept
/// when they left "Remember for this site" ticked, and the other apps sites may open links in.
/// The Chromium bridge asks, reads and writes the same defaults keys; this is the Settings
/// page's view of them.
@MainActor
final class SitePermissions: ObservableObject {
    static let shared = SitePermissions()

    /// Site host → what it asked to do ("use your camera") → allowed.
    static let decisionsKey = "browser.sitePermissions"
    /// Site host → the link schemes ("zoommtg") it may hand to another app without asking.
    static let protocolsKey = "browser.externalProtocolAllowList"

    @Published private(set) var decisions: [String: [String: Bool]] = [:]
    @Published private(set) var protocols: [String: [String]] = [:]

    private init() { reload() }

    /// Reads what the bridge may have written since.
    func reload() {
        let defaults = UserDefaults.standard
        let decisions = defaults.dictionary(forKey: Self.decisionsKey) as? [String: [String: Bool]] ?? [:]
        let protocols = defaults.dictionary(forKey: Self.protocolsKey) as? [String: [String]] ?? [:]
        if decisions != self.decisions { self.decisions = decisions }
        if protocols != self.protocols { self.protocols = protocols }
    }

    var sites: [String] { Set(decisions.keys).union(protocols.keys).sorted() }

    func set(_ host: String, _ action: String, allowed: Bool) {
        decisions[host, default: [:]][action] = allowed
        UserDefaults.standard.set(decisions, forKey: Self.decisionsKey)
    }

    func forget(_ host: String, _ action: String) {
        decisions[host]?[action] = nil
        if decisions[host]?.isEmpty == true { decisions[host] = nil }
        UserDefaults.standard.set(decisions, forKey: Self.decisionsKey)
    }

    func forgetProtocol(_ host: String, _ scheme: String) {
        protocols[host]?.removeAll { $0 == scheme }
        if protocols[host]?.isEmpty == true { protocols[host] = nil }
        UserDefaults.standard.set(protocols, forKey: Self.protocolsKey)
    }

    func forgetAll() {
        decisions = [:]
        protocols = [:]
        UserDefaults.standard.removeObject(forKey: Self.decisionsKey)
        UserDefaults.standard.removeObject(forKey: Self.protocolsKey)
    }
}
