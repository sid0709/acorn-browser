import SwiftUI
import AppKit

/// One queue for every write, so two saves of a file land in the order they were made.
private let libraryQueue = DispatchQueue(label: "com.acorn.browser.library", qos: .utility)

/// Reads and writes one JSON file in the app's folder. Writes wait a moment and happen off the
/// main thread, so a burst of changes (a page that redirects three times) costs one write.
@MainActor
final class JSONFile<Value: Codable & Sendable> {
    private let url: URL
    private var pending: DispatchWorkItem?

    init(_ name: String) { url = AgentRunner.appDirectory.appendingPathComponent(name) }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value, after delay: TimeInterval = 2) {
        pending?.cancel()
        let url = url
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        pending = work
        libraryQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var url: String
    var title: String
    var lastVisit: Date
    var visits: Int
    var id: String { url }

    /// How likely this is the page meant: visited often and lately.
    func score(at now: Date) -> Double {
        let days = max(now.timeIntervalSince(lastVisit) / 86_400, 0)
        return Double(visits).squareRoot() / (1 + days / 3)
    }
}

/// The pages the person opened, newest first, one entry per address. Pages the agent opens
/// while the harness drives its tab are not the person's and are not kept.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 5_000

    private let file = JSONFile<[HistoryEntry]>("history.json")
    @Published private var stored: [HistoryEntry]

    var entries: [HistoryEntry] { stored }

    private init() { stored = file.load() ?? [] }

    func record(url: String, title: String) {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
        ChromiumPerf.enter("history record")
        defer { ChromiumPerf.leave() }
        if let index = stored.firstIndex(where: { $0.url == url }) {
            var entry = stored.remove(at: index)
            entry.visits += 1
            entry.lastVisit = Date()
            if !title.isEmpty { entry.title = title }
            stored.insert(entry, at: 0)
        } else {
            stored.insert(HistoryEntry(url: url, title: title, lastVisit: Date(), visits: 1), at: 0)
            if stored.count > Self.limit { stored.removeLast(stored.count - Self.limit) }
        }
        file.save(stored)
    }

    /// A title that arrived after the page was recorded.
    func retitle(url: String, title: String) {
        guard !title.isEmpty, let index = stored.firstIndex(where: { $0.url == url }),
              stored[index].title != title else { return }
        stored[index].title = title
        file.save(stored)
    }

    func remove(_ entry: HistoryEntry) {
        stored.removeAll { $0.url == entry.url }
        file.save(stored, after: 0)
    }

    func clear() {
        stored = []
        file.save(stored, after: 0)
    }

    /// The entries whose title or address holds every word, best first.
    func matches(_ words: [String], limit: Int) -> [HistoryEntry] {
        ChromiumPerf.enter("history ranking")
        defer { ChromiumPerf.leave() }
        let found = words.isEmpty ? entries : entries.filter { entry in
            let haystack = (entry.title + " " + entry.url).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        // Each entry scored once, against one clock: sorting on the score itself worked it out
        // twice per comparison, with a fresh clock each time, over as many as 5,000 entries.
        let now = Date()
        return Array(found
            .map { ($0, $0.score(at: now)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 })
    }
}

// MARK: - Bookmarks

struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var url: String
    var title: String
    var added = Date()
}

/// The pages the person saved (⌘D, or the star in the address).
@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    private let file = JSONFile<[Bookmark]>("bookmarks.json")
    @Published private(set) var bookmarks: [Bookmark]

    private init() { bookmarks = file.load() ?? [] }

    func isBookmarked(_ url: String) -> Bool { bookmarks.contains { $0.url == url } }

    func toggle(url: String, title: String) {
        guard !url.isEmpty else { return }
        if isBookmarked(url) {
            bookmarks.removeAll { $0.url == url }
        } else {
            bookmarks.insert(Bookmark(url: url, title: title.isEmpty ? url : title), at: 0)
        }
        file.save(bookmarks, after: 0.3)
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        file.save(bookmarks, after: 0.3)
    }

    func matches(_ words: [String], limit: Int) -> [Bookmark] {
        Array(bookmarks
            .filter { mark in
                let haystack = (mark.title + " " + mark.url).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .prefix(limit))
    }
}

// MARK: - Favicons

/// Sites' icons, kept as small PNGs beside the runs whenever a tab shows one, so the start page
/// can show them without asking the network.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private let folder = AgentRunner.appDirectory.appendingPathComponent("favicons")
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    /// "https://www.youtube.com/watch" as "youtube.com".
    nonisolated static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func image(forHost host: String) -> NSImage? {
        if let image = images[host] { return image }
        if missing.contains(host) { return nil }
        if let image = NSImage(contentsOf: folder.appendingPathComponent(host + ".png")) {
            images[host] = image
            return image
        }
        missing.insert(host)
        return nil
    }

    func image(forURL url: String) -> NSImage? { Self.host(of: url).flatMap(image(forHost:)) }

    /// Keeps a site's icon, once per launch.
    func remember(_ image: NSImage, forURL url: String) {
        guard let host = Self.host(of: url), images[host] == nil else { return }
        ChromiumPerf.enter("favicon save")
        defer { ChromiumPerf.leave() }
        images[host] = image
        missing.remove(host)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let file = folder.appendingPathComponent(host + ".png")
        let folder = folder
        libraryQueue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }
}

// MARK: - Shortcuts

/// A site on the start page's speed dial.
struct Shortcut: Codable, Identifiable, Hashable, Sendable {
    var title: String
    var url: String
    var id: String { url }
    var host: String { FaviconCache.host(of: url) ?? url }
}

/// The start page's speed dial: the sites the person added, then the sites they visit most,
/// then a few well-known ones while there is room, less any they removed.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    struct Saved: Codable, Sendable {
        var added: [Shortcut] = []
        var hidden: [String] = []
    }

    private let file = JSONFile<Saved>("shortcuts.json")
    @Published private(set) var saved: Saved

    static let starters: [Shortcut] = [
        Shortcut(title: "Google", url: "https://www.google.com"),
        Shortcut(title: "YouTube", url: "https://www.youtube.com"),
        Shortcut(title: "Gmail", url: "https://mail.google.com"),
        Shortcut(title: "GitHub", url: "https://github.com"),
        Shortcut(title: "Wikipedia", url: "https://www.wikipedia.org"),
    ]

    private init() { saved = file.load() ?? Saved() }

    func tiles(limit: Int) -> [Shortcut] {
        var result: [Shortcut] = []
        var hosts = Set(saved.hidden)
        func offer(_ shortcut: Shortcut) {
            guard result.count < limit, hosts.insert(shortcut.host).inserted else { return }
            result.append(shortcut)
        }
        saved.added.forEach(offer)
        for entry in HistoryStore.shared.matches([], limit: 80) {
            guard let full = URL(string: entry.url)?.host(), let host = FaviconCache.host(of: entry.url) else { continue }
            offer(Shortcut(title: Self.name(for: host), url: "https://" + full))
        }
        Self.starters.forEach(offer)
        return result
    }

    func add(title: String, url: String) {
        let address = BrowserSettings.shared.resolve(url.trimmingCharacters(in: .whitespacesAndNewlines))
        let shortcut = Shortcut(title: title.isEmpty ? Self.name(for: FaviconCache.host(of: address) ?? address) : title,
                                url: address)
        saved.hidden.removeAll { $0 == shortcut.host }
        saved.added.removeAll { $0.host == shortcut.host }
        saved.added.append(shortcut)
        file.save(saved, after: 0.3)
    }

    func remove(_ shortcut: Shortcut) {
        saved.added.removeAll { $0.host == shortcut.host }
        if !saved.hidden.contains(shortcut.host) { saved.hidden.append(shortcut.host) }
        file.save(saved, after: 0.3)
    }

    func reset() {
        saved = Saved()
        file.save(saved, after: 0.3)
    }

    /// "news.ycombinator.com" as "Ycombinator", "bbc.co.uk" as "Bbc": the site's own name.
    static func name(for host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host.capitalized }
        var name = parts[parts.count - 2]
        if parts.count >= 3, name.count <= 3 { name = parts[parts.count - 3] }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

// MARK: - Settings

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, kagi
    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        }
    }

    var queryURL: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        case .kagi: "https://kagi.com/search?q="
        }
    }

    var home: String {
        switch self {
        case .google: "https://www.google.com"
        case .duckDuckGo: "https://duckduckgo.com"
        case .bing: "https://www.bing.com"
        case .kagi: "https://kagi.com"
        }
    }
}

/// The browser's own preferences (the look is `ThemeStore`'s).
@MainActor
final class BrowserSettings: ObservableObject {
    static let shared = BrowserSettings()

    @Published var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    /// The language Translate turns pages into, as a language code ("en", "ja").
    @Published var translateLanguage: String {
        didSet { UserDefaults.standard.set(translateLanguage, forKey: "translateLanguage") }
    }

    /// The person's tabs as Chrome-style views, which run Web Store extensions. Off, they are
    /// plain Alloy views like the agent's. New tabs take the change.
    @Published var chromeTabs: Bool {
        didSet { UserDefaults.standard.set(chromeTabs, forKey: "chromeTabs") }
    }

    /// Languages to translate without asking, and never to offer for (base codes: "ja", "zh-CN").
    @Published var alwaysTranslate: [String] {
        didSet { UserDefaults.standard.set(alwaysTranslate, forKey: "alwaysTranslate") }
    }
    @Published var neverTranslate: [String] {
        didSet { UserDefaults.standard.set(neverTranslate, forKey: "neverTranslate") }
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-CN", "Chinese (Simplified)"), ("zh-TW", "Chinese (Traditional)"),
        ("ja", "Japanese"), ("ko", "Korean"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi"),
    ]

    private init() {
        searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        let system = Locale.current.language.languageCode?.identifier ?? "en"
        translateLanguage = UserDefaults.standard.string(forKey: "translateLanguage")
            ?? (Self.languages.contains { $0.code == system } ? system : "en")
        chromeTabs = UserDefaults.standard.object(forKey: "chromeTabs") as? Bool ?? true
        alwaysTranslate = UserDefaults.standard.stringArray(forKey: "alwaysTranslate") ?? []
        neverTranslate = UserDefaults.standard.stringArray(forKey: "neverTranslate") ?? []
    }

    /// What the person typed as an address: a web address as it is, anything else a search.
    func resolve(_ text: String) -> String {
        if text.contains("://") || text.hasPrefix("about:") { return text }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost { return "https://" + text }
        return searchURL(text)
    }

    func searchURL(_ query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))) ?? query
        return searchEngine.queryURL + encoded
    }

    var translateLanguageName: String {
        Self.languages.first { $0.code == translateLanguage }?.name ?? translateLanguage
    }
}

// MARK: - Clearing

/// Forgets history, and the cookies and cache of every tab (they share one profile).
@MainActor
func clearBrowsingData(history: Bool, cookies: Bool, using view: ChromiumBrowserView) {
    if history { HistoryStore.shared.clear() }
    if cookies {
        view.sendDevToolsMethod("Network.clearBrowserCookies", params: nil) { _, _ in }
        view.sendDevToolsMethod("Network.clearBrowserCache", params: nil) { _, _ in }
    }
}

// MARK: - History sheet

/// Everything visited, by day, with a search over it (⌘Y). A click opens the page in a new tab.
struct HistoryView: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmingClear = false

    private var days: [(day: Date, entries: [HistoryEntry])] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = history.entries.filter { entry in
            words.isEmpty || words.allSatisfy { (entry.title + " " + entry.url).lowercased().contains($0) }
        }
        let calendar = Calendar.current
        return Dictionary(grouping: shown) { calendar.startOfDay(for: $0.lastVisit) }
            .map { (day: $0.key, entries: $0.value.sorted { $0.lastVisit > $1.lastVisit }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text("History").font(Theme.Text.title).foregroundStyle(palette.ink)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.inkTertiary)
                    TextField("Search history", text: $search).textFieldStyle(.plain).foregroundStyle(palette.ink)
                }
                .padding(.horizontal, 10)
                .frame(width: 220, height: 28)
                .background(palette.hover, in: Capsule())
                Button("Clear Browsing Data\u{2026}") { confirmingClear = true }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.chrome)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 56)
            Rectangle().fill(palette.hairline).frame(height: 1)

            if history.entries.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(palette.inkTertiary)
                    Text("Pages you visit appear here.").font(Theme.Text.body).foregroundStyle(palette.inkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.day) { day in
                            Section {
                                ForEach(day.entries) { entry in HistoryRow(entry: entry, open: { open(entry) }) }
                            } header: {
                                Text(title(for: day.day))
                                    .font(Theme.Text.section)
                                    .foregroundStyle(palette.inkSecondary)
                                    .padding(.horizontal, Theme.Space.s)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(palette.card)
                            }
                        }
                    }
                    .padding(Theme.Space.s)
                }
            }
        }
        .frame(width: 680, height: 540)
        .background(palette.card)
        .confirmationDialog("Clear browsing data?", isPresented: $confirmingClear) {
            Button("Clear History") { clearBrowsingData(history: true, cookies: false, using: store.active.view) }
            Button("Clear History, Cookies and Cache", role: .destructive) {
                clearBrowsingData(history: true, cookies: true, using: store.active.view)
            }
        } message: {
            Text("Clearing cookies signs you out of sites, in the agent's tab too.")
        }
    }

    private func open(_ entry: HistoryEntry) {
        store.newTab(url: entry.url)
        dismiss()
    }

    private func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                .font(Theme.Text.caption.monospacedDigit())
                .foregroundStyle(palette.inkTertiary)
                .frame(width: 64, alignment: .leading)
            Text(entry.title.isEmpty ? entry.url : entry.title)
                .font(Theme.Text.body).foregroundStyle(palette.ink).lineLimit(1)
            Text(URL(string: entry.url)?.host() ?? "")
                .font(Theme.Text.caption).foregroundStyle(palette.inkTertiary).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            if hovering {
                Button { HistoryStore.shared.remove(entry) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(ChromeButtonStyle(size: 20))
                .help("Remove from history")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}
