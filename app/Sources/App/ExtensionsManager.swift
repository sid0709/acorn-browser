import SwiftUI
import AppKit

/// `acorn://extensions`: Chrome's extensions page, on Acorn's palette. Every extension as a
/// card with its switch, a search over them, the way to the Web Store, and the site boosts
/// beneath. An extension's own page (`acorn://extensions/<id>`) has its details: what it may
/// reach, its id and folder.
struct ExtensionsManager: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject var store: TabStore
    let part: String?
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var palette
    @State private var query = ""

    private var detailed: ExtensionInfo? {
        guard let part else { return nil }
        return extensions.installed.first { $0.id == part }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let detailed {
                        ExtensionDetails(info: detailed, back: { tab.load(AcornPage.extensions.address()) })
                    } else {
                        status
                        installedList
                        BoostsSection(store: store, query: query)
                    }
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Rectangle().fill(palette.canvas))
        .onAppear { extensions.refresh() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.accent)
                Text("Extensions")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .frame(width: 200, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.inkTertiary)
                TextField("Search extensions and boosts", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.body)
                    .foregroundStyle(palette.ink)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(maxWidth: 480, minHeight: 34)
            .background(palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.hairline))
            Spacer(minLength: 0)
            Button { store.newTab(url: "https://chromewebstore.google.com") } label: {
                Label("Chrome Web Store", systemImage: "bag")
            }
            .frame(width: 200, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
    }

    /// Whether extensions can run here, and anything waiting for a relaunch.
    @ViewBuilder
    private var status: some View {
        SettingsCard {
            HStack(spacing: Theme.Space.m) {
                SupportLine(support: ExtensionStore.support(in: store))
                Spacer(minLength: Theme.Space.l)
                if extensions.needsRelaunch {
                    Button { extensions.relaunch() } label: { Label("Relaunch to Apply Changes", systemImage: "arrow.clockwise") }
                }
            }
            .padding(Theme.Space.l)
            if let error = extensions.lastError {
                RowDivider()
                Text(error)
                    .font(Theme.Text.secondary)
                    .foregroundStyle(Color.orange)
                    .padding(Theme.Space.l)
            }
        }
    }

    private var shown: [ExtensionInfo] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return extensions.installed.filter { info in
            let text = (info.name + " " + info.summary + " " + info.id).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    @ViewBuilder
    private var installedList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionTitle("Installed", count: extensions.installed.count)
            if extensions.installed.isEmpty {
                SettingsCard {
                    SettingRow("No extensions yet",
                               detail: "Find some in the Chrome Web Store. On an extension's page, use its Add button, or Add to Acorn in the address.") {
                        Button("Open the Web Store") { store.newTab(url: "https://chromewebstore.google.com") }
                    }
                }
            } else if shown.isEmpty {
                Text("No extensions match \u{201C}\(query)\u{201D}.")
                    .font(Theme.Text.body)
                    .foregroundStyle(palette.inkSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: Theme.Space.l)], spacing: Theme.Space.l) {
                    ForEach(shown) { info in
                        ExtensionCard(info: info) { tab.load(AcornPage.extensions.address(info.id)) }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.ink)
            Text("\(count)").font(Theme.Text.secondary).foregroundStyle(palette.inkTertiary)
        }
    }
}

/// An extension's icon, or a puzzle piece when it has none.
private struct ExtensionIcon: View {
    let info: ExtensionInfo
    var size: CGFloat = 36
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let icon = info.icon, let image = NSImage(contentsOf: icon) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(palette.inkTertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// One extension, as chrome://extensions shows it: icon, name, version and description, then
/// Details, Remove and its switch.
private struct ExtensionCard: View {
    let info: ExtensionInfo
    let details: () -> Void
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var palette
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ExtensionIcon(info: info)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(info.name).font(Theme.Text.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
                        Text(info.version).font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
                    }
                    Text(info.summary.isEmpty ? "No description." : info.summary)
                        .font(Theme.Text.secondary)
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                }
            }
            HStack(spacing: Theme.Space.s) {
                Button("Details", action: details)
                if info.source == .acorn {
                    Button("Remove") { confirmingRemove = true }
                }
                Spacer()
                if info.source == .acorn {
                    Toggle("", isOn: Binding(get: { extensions.isEnabled(info) }, set: { extensions.setEnabled(info, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                } else {
                    Text("From the Web Store").font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
                }
            }
        }
        .padding(Theme.Space.l)
        .card()
        .confirmationDialog("Remove \(info.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { extensions.remove(info) }
        } message: {
            Text("It goes at the next launch.")
        }
    }
}

/// An extension's own page: everything the card has no room for.
private struct ExtensionDetails: View {
    let info: ExtensionInfo
    let back: () -> Void
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var palette
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Button(action: back) { Label("Extensions", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .font(Theme.Text.bodyStrong)
                .foregroundStyle(palette.accent)
            SettingsCard {
                HStack(spacing: Theme.Space.l) {
                    ExtensionIcon(info: info, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name).font(Theme.Text.title).foregroundStyle(palette.ink)
                        Text(info.summary.isEmpty ? "No description." : info.summary)
                            .font(Theme.Text.secondary)
                            .foregroundStyle(palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(Theme.Space.l)
                RowDivider()
                SettingRow("On", detail: info.source == .acorn
                               ? "Turning it on or off takes effect at the next launch."
                               : "Installed by the Web Store into Chromium's profile, which manages it.") {
                    Toggle("", isOn: Binding(get: { extensions.isEnabled(info) }, set: { extensions.setEnabled(info, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(info.source != .acorn)
                }
                RowDivider()
                SettingRow("Version") { value(info.version) }
                RowDivider()
                SettingRow("ID") { value(info.id) }
                RowDivider()
                SettingRow("Source") { value(info.source == .acorn ? "Added to Acorn from the Web Store" : "Chrome Web Store") }
                RowDivider()
                SettingRow("Permissions",
                           detail: info.permissions.isEmpty ? "None asked for." : info.permissions.joined(separator: "\n")) {
                    EmptyView()
                }
                .textSelection(.enabled)
                RowDivider()
                SettingRow("Folder", detail: (info.folder.path as NSString).abbreviatingWithTildeInPath) {
                    Button("Show in Finder") { revealInFinder(info.folder, orFolder: info.folder) }
                }
                if info.source == .acorn {
                    RowDivider()
                    SettingRow("Remove extension", detail: "It goes at the next launch.") {
                        Button("Remove\u{2026}") { confirmingRemove = true }
                    }
                }
            }
        }
        .confirmationDialog("Remove \(info.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                extensions.remove(info)
                back()
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.secondary)
            .foregroundStyle(palette.inkSecondary)
            .textSelection(.enabled)
    }
}

/// The site boosts, Acorn's own way to change a site: styles and a script put into its pages.
/// They work in every tab of the person's, whatever the engine allows.
private struct BoostsSection: View {
    @ObservedObject var store: TabStore
    let query: String
    @ObservedObject private var boosts = BoostStore.shared
    @Environment(\.palette) private var palette
    @State private var newHost = ""

    private var shown: [Boost] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return boosts.boosts.filter { boost in words.allSatisfy { boost.host.lowercased().contains($0) } }
    }

    /// "https://www.example.com/page" as "www.example.com"; a bare host as it is.
    private var typedHost: String? {
        let text = newHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let host = URL(string: text.contains("://") ? text : "https://" + text)?.host()
        return host?.isEmpty == false ? host : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("Site Boosts").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.ink)
                Text("\(boosts.boosts.count)").font(Theme.Text.secondary).foregroundStyle(palette.inkTertiary)
            }
            Text("Styles and a script of your own, put into every page of a site when it loads. They work in every tab of yours, never the agent's.")
                .font(Theme.Text.secondary)
                .foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                SettingRow("New boost") {
                    HStack(spacing: Theme.Space.s) {
                        TextField("example.com", text: $newHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit(add)
                        Button("Add", action: add).disabled(typedHost == nil)
                    }
                }
            }
            if !shown.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: Theme.Space.l)], spacing: Theme.Space.l) {
                    ForEach(shown) { boost in card(boost) }
                }
            }
        }
    }

    private func add() {
        guard let host = typedHost else { return }
        newHost = ""
        store.boostTarget = BoostTarget(host: host)
    }

    private func card(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "bolt.fill").foregroundStyle(boost.enabled ? palette.accent : palette.inkTertiary)
                Text(boost.host).font(Theme.Text.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { boost.enabled }, set: { boosts.setEnabled(boost, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(Self.describe(boost))
                .font(Theme.Text.secondary)
                .foregroundStyle(palette.inkSecondary)
            HStack(spacing: Theme.Space.s) {
                Button("Edit") { store.boostTarget = BoostTarget(host: boost.host) }
                Button("Visit") { store.newTab(url: "https://\(boost.host)") }
                Spacer()
                Button { boosts.remove(boost) } label: { Image(systemName: "trash") }
                    .buttonStyle(ChromeButtonStyle(size: 26))
                    .help("Delete this boost")
            }
        }
        .padding(Theme.Space.l)
        .card()
    }

    private static func describe(_ boost: Boost) -> String {
        func lines(_ text: String) -> Int {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? 0 : text.split(whereSeparator: \.isNewline).count
        }
        let css = lines(boost.css), script = lines(boost.script)
        if css == 0 && script == 0 { return "Empty: nothing is put into the site." }
        return "\(css) \(css == 1 ? "line" : "lines") of CSS · \(script) \(script == 1 ? "line" : "lines") of script"
    }
}
