import SwiftUI
import AppKit
import Combine

/// The parts of Settings, in the sidebar's order, grouped as Chrome groups its own. Each has an
/// address (`acorn://settings/privacy`) and the words its search looks through.
enum SettingsSection: String, CaseIterable, Identifiable {
    case agent, appearance, search, tabs, privacy, content, downloads, languages, system, reset, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent: "You and the Agent"
        case .appearance: "Appearance"
        case .search: "Search Engine"
        case .tabs: "Start Page and Tabs"
        case .privacy: "Privacy and Security"
        case .content: "Site Settings"
        case .downloads: "Downloads"
        case .languages: "Languages"
        case .system: "System"
        case .reset: "Reset Settings"
        case .help: "About Acorn"
        }
    }

    var icon: String {
        switch self {
        case .agent: "sparkles"
        case .appearance: "paintpalette"
        case .search: "magnifyingglass"
        case .tabs: "house"
        case .privacy: "hand.raised"
        case .content: "slider.horizontal.3"
        case .downloads: "arrow.down.circle"
        case .languages: "character.bubble"
        case .system: "wrench.and.screwdriver"
        case .reset: "arrow.counterclockwise"
        case .help: "info.circle"
        }
    }

    /// A divider goes above it in the sidebar.
    var startsGroup: Bool { self == .privacy || self == .help }

    /// What the search finds this part by, besides its title.
    var terms: String {
        switch self {
        case .agent: "model openrouter key api runs agent panel"
        case .appearance: "theme colors intensity grain glass translucency dark light mode font size minimum tabs layout sidebar top"
        case .search: "search engine google duckduckgo bing kagi custom address bar"
        case .tabs: "start page greeting shortcuts agent rows new tab startup"
        case .privacy: "clear browsing data history cookies cache site data incognito"
        case .content: "site settings permissions camera microphone location notifications clipboard apps links protocols"
        case .downloads: "download location folder ask where to save"
        case .languages: "translate language always never"
        case .system: "chrome extensions tabs engine chromium data folder log"
        case .reset: "reset restore defaults"
        case .help: "about version chromium cef user agent"
        }
    }

    func matches(_ words: [String]) -> Bool {
        let haystack = (title + " " + terms).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// `acorn://settings`: Chrome's settings page, on Acorn's palette. A sidebar of the sections,
/// a search over all of them, and the section the address names (`acorn://settings/privacy`),
/// so back and forward go between sections.
struct SettingsPage: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    let part: String?
    @Environment(\.palette) private var palette
    @State private var query = ""

    private var section: SettingsSection { part.flatMap(SettingsSection.init(rawValue:)) ?? .agent }
    private var words: [String] { query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
            Rectangle().fill(palette.hairline).frame(width: 1)
            VStack(spacing: 0) {
                searchField
                    .padding(.vertical, Theme.Space.l)
                    .padding(.horizontal, Theme.Space.xl)
                ScrollView {
                    content
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.bottom, 48)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Rectangle().fill(palette.canvas))
        .environment(\.settingsQuery, words)
    }

    @ViewBuilder
    private var content: some View {
        if words.isEmpty {
            SettingsSectionView(section: section, tab: tab, store: store)
                .id(section)
        } else {
            let found = SettingsSection.allCases.filter { $0.matches(words) }
            if found.isEmpty {
                Text("No settings match \u{201C}\(query)\u{201D}.")
                    .font(Theme.Text.body)
                    .foregroundStyle(palette.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 36) {
                    ForEach(found) { SettingsSectionView(section: $0, tab: tab, store: store) }
                }
            }
        }
    }

    private func open(_ section: SettingsSection) {
        query = ""
        tab.load(AcornPage.settings.address(section.rawValue))
    }

    // MARK: Sidebar and search

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(palette.accent)
                    Text("Settings")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)
                ForEach(SettingsSection.allCases) { item in
                    if item.startsGroup { sidebarDivider }
                    if item == .help {
                        sidebarRow("Extensions", icon: "puzzlepiece.extension", selected: false, trailing: "arrow.up.forward") {
                            store.openPage(.extensions)
                        }
                    }
                    sidebarRow(item.title, icon: item.icon, selected: words.isEmpty && item == section) { open(item) }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.xl)
        }
    }

    private var sidebarDivider: some View {
        Rectangle().fill(palette.hairline).frame(height: 1)
            .padding(.vertical, Theme.Space.s)
            .padding(.horizontal, Theme.Space.s)
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool, trailing: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(selected ? palette.accent : palette.inkSecondary)
                Text(title)
                    .font(selected ? Theme.Text.bodyStrong : Theme.Text.body)
                    .foregroundStyle(selected ? palette.accent : palette.ink)
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing).font(.system(size: 10)).foregroundStyle(palette.inkTertiary)
                }
            }
            .frame(height: 22)
        }
        .buttonStyle(.row)
        .background(selected ? palette.selection : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.inkTertiary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Text.body)
                .foregroundStyle(palette.ink)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.inkTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: 560, minHeight: 36)
        .background(palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.hairline))
    }
}

// MARK: - Sections

/// One section: its title and its cards.
private struct SettingsSectionView: View {
    let section: SettingsSection
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(section.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, Theme.Space.l)
            switch section {
            case .agent: AgentSettings(store: store)
            case .appearance: AppearanceSettings(store: store)
            case .search: SearchSettings()
            case .tabs: StartPageSettings(store: store)
            case .privacy: PrivacySettings(tab: tab, store: store)
            case .content: SiteSettings()
            case .downloads: DownloadSettings()
            case .languages: LanguageSettings()
            case .system: SystemSettings(store: store)
            case .reset: ResetSettings(store: store)
            case .help: AboutAcorn()
            }
        }
    }
}

private struct AgentSettings: View {
    @ObservedObject var store: TabStore
    @EnvironmentObject private var runner: AgentRunner
    @Environment(\.palette) private var palette
    @State private var choosingModel = false
    @State private var hasKey = false

    private var envFile: URL { AgentRunner.appDirectory.appendingPathComponent(".env") }

    var body: some View {
        SettingsCard {
            SettingRow("Model that drives the page",
                       detail: "Any model OpenRouter lists. The checks between its batches use the runner's own decision model.") {
                Button { choosingModel.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(runner.model).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                }
                .disabled(runner.isRunning)
                .popover(isPresented: $choosingModel, arrowEdge: .bottom) {
                    ModelPicker(selection: $runner.model)
                }
            }
            RowDivider()
            SettingRow("OpenRouter key",
                       detail: hasKey ? "Found in Acorn's .env file." : "Not set. Put OPENROUTER_API_KEY=… in the .env file in Acorn's folder.") {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasKey ? Color.green : Color.orange)
                    Button("Show in Finder") { revealInFinder(envFile, orFolder: AgentRunner.appDirectory) }
                }
            }
            RowDivider()
            SettingRow("Runs", detail: "Each run's task, steps and pictures are kept in the runs folder.") {
                Button("Open Folder") { revealInFinder(nil, orFolder: AgentRunner.appDirectory.appendingPathComponent("runs")) }
            }
            if store.hasAgent {
                RowDivider()
                SettingRow("Show the agent panel", detail: "Beside the page in this window (⌘K).") {
                    Toggle("", isOn: $store.showAgent).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { hasKey = Self.keyIsSet(in: envFile) }
    }

    private static func keyIsSet(in file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "OPENROUTER_API_KEY"
                && !parts[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))).isEmpty
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        SettingsCard {
            SettingRow("Theme", detail: "Colors, tint, grain and glass for every window, and light or dark. Changes show as you make them.") { EmptyView() }
            ThemePicker()
                .padding(.bottom, Theme.Space.s)
                .frame(maxWidth: .infinity)
        }
        SettingsCard {
            SettingRow("Tabs") {
                Picker("", selection: $store.verticalLayout) {
                    Text("In a sidebar").tag(true)
                    Text("Across the top").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            if store.verticalLayout {
                RowDivider()
                SettingRow("Show the sidebar", detail: "Hidden, it comes out when the pointer reaches the window's edge (⌘S).") {
                    Toggle("", isOn: Binding(get: { !store.sidebarHidden }, set: { store.sidebarHidden = !$0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
        SettingsCard {
            SettingRow("Font size", detail: "For pages in new tabs. The agent's tab keeps Chromium's sizes.") {
                Picker("", selection: $settings.defaultFontSize) {
                    ForEach(BrowserSettings.fontSizes, id: \.size) { Text($0.name).tag($0.size) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            RowDivider()
            SettingRow("Minimum font size", detail: "No text in a page is drawn smaller.") {
                Picker("", selection: $settings.minimumFontSize) {
                    ForEach(BrowserSettings.minimumFontSizes, id: \.self) { size in
                        Text(size == 0 ? "None" : "\(size) px").tag(size)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }
}

private struct SearchSettings: View {
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var palette

    private var templateIsValid: Bool {
        let template = settings.customSearchTemplate
        return template.contains("%s") && URL(string: template.replacingOccurrences(of: "%s", with: "q"))?.host() != nil
    }

    var body: some View {
        SettingsCard {
            SettingRow("Search engine used in the address bar",
                       detail: "What you type that is not an address is searched for here.") {
                Picker("", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if settings.searchEngine == .custom {
                RowDivider()
                SettingRow("Name") {
                    TextField("Startpage", text: $settings.customSearchName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                RowDivider()
                SettingRow("Address",
                           detail: templateIsValid
                               ? "%s is where your search goes."
                               : "Use %s where the search goes, as in https://www.startpage.com/do/search?q=%s. Until then Google is used.") {
                    TextField("https://example.com/search?q=%s", text: $settings.customSearchTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }
        }
    }
}

private struct StartPageSettings: View {
    @ObservedObject var store: TabStore
    @AppStorage("startPage.greeting") private var showGreeting = true
    @AppStorage("startPage.shortcuts") private var showShortcuts = true
    @AppStorage("startPage.agent") private var showAgentChip = true
    @AppStorage("startPage.rows") private var rows = 2

    var body: some View {
        SettingsCard {
            SettingRow("Greeting", detail: "Good morning, and the date, above the search.") {
                Toggle("", isOn: $showGreeting).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow("Shortcuts", detail: "The sites you go to most, and the ones you added.") {
                Toggle("", isOn: $showShortcuts).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow("Rows of shortcuts") {
                Picker("", selection: $rows) {
                    Text("One").tag(1)
                    Text("Two").tag(2)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(!showShortcuts)
            }
            RowDivider()
            SettingRow("Ask the agent", detail: "A button on the start page that hands a task to the agent.") {
                Toggle("", isOn: $showAgentChip).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow("Reset shortcuts", detail: "Brings back the ones you removed and drops the ones you added.") {
                Button("Reset") { ShortcutStore.shared.reset() }
            }
        }
        SettingsCard {
            SettingRow("New tab", detail: "⌘T opens the command bar; a new tab with no address opens your search engine's page.") {
                Button("Open a Start Page") { store.newTab(url: BrowserModel.startURL) }
            }
        }
    }
}

private struct PrivacySettings: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var range = ClearRange.allTime
    @State private var clearHistory = true
    @State private var clearCookies = false
    @State private var clearCache = true
    @State private var confirming = false
    @State private var cleared = ""

    enum ClearRange: String, CaseIterable, Identifiable {
        case hour, day, week, month, allTime
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hour: "Last hour"
            case .day: "Last 24 hours"
            case .week: "Last 7 days"
            case .month: "Last 4 weeks"
            case .allTime: "All time"
            }
        }
        var since: Date? {
            switch self {
            case .hour: Date().addingTimeInterval(-3_600)
            case .day: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-28 * 86_400)
            case .allTime: nil
            }
        }
    }

    var body: some View {
        SettingsCard {
            SettingRow("Clear browsing data", detail: "Cookies and the cache are cleared whatever the time range.") {
                Picker("", selection: $range) {
                    ForEach(ClearRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            RowDivider()
            SettingRow("Browsing history", detail: "\(history.entries.count) pages. Pages the agent opens are never kept.") {
                Toggle("", isOn: $clearHistory).labelsHidden()
            }
            RowDivider()
            SettingRow("Cookies and other site data", detail: "Signs you out of most sites, in the agent's tab too.") {
                Toggle("", isOn: $clearCookies).labelsHidden()
            }
            RowDivider()
            SettingRow("Cached images and files", detail: "Some sites load more slowly the next time.") {
                Toggle("", isOn: $clearCache).labelsHidden()
            }
            RowDivider()
            SettingRow(cleared.isEmpty ? "" : cleared) {
                Button("Clear Data\u{2026}") { confirming = true }
                    .disabled(!clearHistory && !clearCookies && !clearCache)
            }
        }
        .confirmationDialog("Clear browsing data?", isPresented: $confirming) {
            Button("Clear Data", role: .destructive, action: clear)
        } message: {
            Text("This can't be undone.")
        }
        SettingsCard {
            LinkRow("Site settings", detail: "What sites may use (camera, location, notifications) and the apps they may open.") {
                tab.load(AcornPage.settings.address(SettingsSection.content.rawValue))
            }
            RowDivider()
            LinkRow("New incognito window", detail: "Nothing it visits is kept: no history, cookies or site data once it closes.") {
                openWindow(id: "browser", value: WindowRequest(kind: .incognito))
            }
        }
    }

    private func clear() {
        // An incognito window's tabs keep their own cookies: clear the profile's.
        let view = tab.isIncognito ? BrowserModel.shared.view : tab.view
        clearBrowsingData(history: clearHistory, cookies: clearCookies, cache: clearCache,
                          since: range.since, using: view)
        cleared = "Cleared."
    }
}

private struct SiteSettings: View {
    @ObservedObject private var permissions = SitePermissions.shared
    @Environment(\.palette) private var palette
    @State private var confirming = false

    var body: some View {
        Group {
            if permissions.sites.isEmpty {
                SettingsCard {
                    SettingRow("No sites yet",
                               detail: "When a site asks to use your camera, microphone or location, or to open another app, the choice you keep shows here.") {
                        EmptyView()
                    }
                }
            } else {
                ForEach(permissions.sites, id: \.self) { host in site(host) }
                SettingsCard {
                    SettingRow("Forget every site's choices", detail: "Sites ask again the next time.") {
                        Button("Forget All\u{2026}") { confirming = true }
                    }
                }
            }
        }
        .onAppear { permissions.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            permissions.reload()
        }
        .confirmationDialog("Forget every site's choices?", isPresented: $confirming) {
            Button("Forget All", role: .destructive) { permissions.forgetAll() }
        }
    }

    private func site(_ host: String) -> some View {
        let decisions = (permissions.decisions[host] ?? [:]).sorted { $0.key < $1.key }
        let schemes = permissions.protocols[host] ?? []
        return SettingsCard {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "globe").foregroundStyle(palette.inkTertiary)
                Text(host).font(Theme.Text.bodyStrong).foregroundStyle(palette.ink)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            ForEach(decisions, id: \.key) { decision in
                let action = decision.key
                RowDivider()
                SettingRow(String(action.prefix(1)).uppercased() + String(action.dropFirst())) {
                    HStack(spacing: Theme.Space.s) {
                        Picker("", selection: Binding(get: { decision.value }, set: { permissions.set(host, action, allowed: $0) })) {
                            Text("Allow").tag(true)
                            Text("Block").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                        forget { permissions.forget(host, action) }
                    }
                }
            }
            ForEach(schemes, id: \.self) { scheme in
                RowDivider()
                SettingRow("Open \(scheme): links in another app", detail: "Without asking first.") {
                    forget { permissions.forgetProtocol(host, scheme) }
                }
            }
        }
    }

    private func forget(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }
            .buttonStyle(ChromeButtonStyle(size: 26))
            .help("Forget: the site asks again")
    }
}

private struct DownloadSettings: View {
    @ObservedObject private var settings = BrowserSettings.shared

    private var folder: URL {
        settings.downloadFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        SettingsCard {
            SettingRow("Location", detail: (folder.path as NSString).abbreviatingWithTildeInPath) {
                HStack(spacing: Theme.Space.s) {
                    if settings.downloadFolder != nil {
                        Button("Use Downloads") { settings.downloadFolder = nil }
                    }
                    Button("Change\u{2026}", action: choose)
                }
            }
            RowDivider()
            SettingRow("Ask where to save each file before downloading",
                       detail: "Downloads made while the agent works always go straight to the folder, so a run is never stopped to ask.") {
                Toggle("", isOn: $settings.askWhereToSave).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow("Open the folder") {
                Button("Show in Finder") { revealInFinder(nil, orFolder: folder) }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url.path }
    }
}

private struct LanguageSettings: View {
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        SettingsCard {
            SettingRow("Translate pages into", detail: "Offered in the address when a page is in another language.") {
                Picker("", selection: $settings.translateLanguage) {
                    ForEach(BrowserSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
        SettingsCard {
            list("Always translate", empty: "Languages you choose to always translate, in a page's translate menu.",
                 codes: settings.alwaysTranslate) { code in settings.alwaysTranslate.removeAll { $0 == code } }
        }
        SettingsCard {
            list("Never offer to translate", empty: "Languages you choose never to translate, in a page's translate menu.",
                 codes: settings.neverTranslate) { code in settings.neverTranslate.removeAll { $0 == code } }
        }
    }

    @ViewBuilder
    private func list(_ title: String, empty: String, codes: [String], remove: @escaping (String) -> Void) -> some View {
        SettingRow(title, detail: codes.isEmpty ? empty : nil) { EmptyView() }
        ForEach(codes, id: \.self) { code in
            RowDivider()
            SettingRow(Translator.name(of: code)) {
                Button { remove(code) } label: { Image(systemName: "xmark") }
                    .buttonStyle(ChromeButtonStyle(size: 26))
                    .help("Remove")
            }
        }
    }
}

private struct SystemSettings: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        SettingsCard {
            SettingRow("Chrome extensions in tabs",
                       detail: ChromiumBrowserView.chromeStyleRefused
                           ? "On this Mac the engine can't make Chrome-style tabs inside Acorn's window, so tabs are plain views and run no extensions. Site boosts still work."
                           : "Tabs run as Chrome-style views, which can run Web Store extensions. New tabs take the change; the agent's tab is never one.") {
                Toggle("", isOn: $settings.chromeTabs)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(ChromiumBrowserView.chromeStyleRefused)
            }
            RowDivider()
            SettingRow("Extension support") {
                SupportLine(support: ExtensionStore.support(in: store))
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        SettingsCard {
            SettingRow("Acorn's folder", detail: "History, bookmarks, runs and Chromium's profile.") {
                Button("Show in Finder") { revealInFinder(nil, orFolder: AgentRunner.appDirectory) }
            }
            RowDivider()
            SettingRow("Chromium's log", detail: "Errors the engine wrote down.") {
                Button("Show in Finder") {
                    let chromium = AgentRunner.appDirectory.appendingPathComponent("Chromium")
                    revealInFinder(chromium.appendingPathComponent("chromium.log"), orFolder: chromium)
                }
            }
        }
    }
}

private struct ResetSettings: View {
    @ObservedObject var store: TabStore
    @State private var confirming = false
    @State private var done = false

    var body: some View {
        SettingsCard {
            SettingRow("Restore settings to their original defaults",
                       detail: done
                           ? "Settings were restored."
                           : "The theme, search engine, start page, languages, downloads, font sizes and sites' kept choices. History, bookmarks, extensions, boosts and the agent's model stay.") {
                Button("Reset Settings\u{2026}") { confirming = true }
            }
        }
        .confirmationDialog("Reset settings?", isPresented: $confirming) {
            Button("Reset Settings", role: .destructive, action: reset)
        }
    }

    private func reset() {
        BrowserSettings.shared.reset()
        ThemeStore.shared.apply(ThemePreset.all[0])
        SitePermissions.shared.forgetAll()
        for key in ["startPage.greeting", "startPage.shortcuts", "startPage.agent", "startPage.rows"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        store.verticalLayout = false
        store.sidebarHidden = false
        done = true
    }
}

private struct AboutAcorn: View {
    @Environment(\.palette) private var palette

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: Theme.Space.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Acorn Browser").font(Theme.Text.title).foregroundStyle(palette.ink)
                    Text("Version \(version)").font(Theme.Text.secondary).foregroundStyle(palette.inkSecondary)
                }
                Spacer()
            }
            .padding(Theme.Space.l)
            RowDivider()
            SettingRow("Chromium") { value(ChromiumEngine.chromiumVersion) }
            RowDivider()
            SettingRow("Chromium Embedded Framework") { value(ChromiumEngine.cefVersion) }
            RowDivider()
            SettingRow("User agent", detail: ChromiumEngine.userAgent) { EmptyView() }
                .textSelection(.enabled)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text.isEmpty ? "Not started" : text)
            .font(Theme.Text.secondary)
            .foregroundStyle(palette.inkSecondary)
            .textSelection(.enabled)
    }
}

// MARK: - Pieces

/// Shows a file in Finder, or opens the folder when the file is not there.
@MainActor
func revealInFinder(_ file: URL?, orFolder folder: URL) {
    if let file, FileManager.default.fileExists(atPath: file.path) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    } else {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// The search's words, which rows they match light up.
private struct SettingsQueryKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

private extension EnvironmentValues {
    var settingsQuery: [String] {
        get { self[SettingsQueryKey.self] }
        set { self[SettingsQueryKey.self] = newValue }
    }
}

/// A card of settings rows, as Chrome groups them.
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }
}

/// One setting: its name, a line on what it does, and its control on the right. It lights up
/// when the search's words are in it.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control
    @Environment(\.palette) private var palette
    @Environment(\.settingsQuery) private var query

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    private var lit: Bool {
        guard !query.isEmpty else { return false }
        let text = (title + " " + (detail ?? "")).lowercased()
        return query.allSatisfy { text.contains($0) }
    }

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                if !title.isEmpty {
                    Text(title).font(Theme.Text.body).foregroundStyle(palette.ink)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Text.secondary)
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.l)
            control
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(minHeight: 50)
        .background(lit ? palette.accent.opacity(0.1) : .clear)
    }
}

/// A row that goes somewhere: another section, another page, a window.
struct LinkRow: View {
    let title: String
    let detail: String?
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    init(_ title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingRow(title, detail: detail) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.inkTertiary)
            }
            .background(hovering ? palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct RowDivider: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle().fill(palette.hairline).frame(height: 1).padding(.leading, Theme.Space.l)
    }
}
