import SwiftUI
import AppKit
import CryptoKit

/// An extension the browser has: one the Web Store installed into the profile, or one the app
/// installed itself (unpacked, loaded at launch).
struct ExtensionInfo: Identifiable, Hashable {
    enum Source { case webStore, acorn }

    let id: String
    let name: String
    let version: String
    let icon: URL?
    /// The page its toolbar button opens, relative to the extension.
    let popup: String?
    let source: Source
    let folder: URL
}

/// Chrome Web Store extensions. The person's tabs are Chrome-style views, which run Chrome's
/// extension system, so the Store's own "Add to Chrome" may install straight into the profile.
/// Where it cannot, "Add to Acorn" in the address installs it the way Chromium installs an
/// unpacked one: the Store's package is fetched, unpacked beside the runs (keeping the Store's
/// id), and loaded at the next launch. The agent's tab is an Alloy view and runs none of them.
@MainActor
final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()

    /// Where the app's own installs live, and the profile Chromium keeps the Store's in.
    /// Plain values, read off the main actor while an install downloads.
    nonisolated static let folder = appDirectory.appendingPathComponent("Extensions")
    private nonisolated static let profileExtensions = appDirectory.appendingPathComponent("Chromium/Default/Extensions")
    private nonisolated static var appDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.acorn.browser")
    }

    @Published private(set) var installed: [ExtensionInfo] = []
    /// The app's installs the person turned off; they are left out at the next launch.
    @Published private(set) var disabled: [String] = UserDefaults.standard.stringArray(forKey: "disabledExtensions") ?? []
    /// Something changed that takes effect at the next launch.
    @Published private(set) var needsRelaunch = false
    @Published private(set) var installing: Set<String> = []
    @Published var lastError: String?

    private init() { refresh() }

    /// The folders to load at launch: the app's installs that are on.
    static func launchDirectories() -> [String] {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledExtensions") ?? [])
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { !disabled.contains($0.lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .map(\.path)
    }

    func refresh() {
        var found: [ExtensionInfo] = []
        let manager = FileManager.default
        for folder in (try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] {
            if let info = Self.read(folder, id: folder.lastPathComponent, source: .acorn) { found.append(info) }
        }
        // The profile keeps each Store extension as <id>/<version>/; the newest version is it.
        for idFolder in (try? manager.contentsOfDirectory(at: Self.profileExtensions, includingPropertiesForKeys: nil)) ?? [] {
            let id = idFolder.lastPathComponent
            guard Self.isID(id), !found.contains(where: { $0.id == id }) else { continue }
            let versions = ((try? manager.contentsOfDirectory(at: idFolder, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            if let newest = versions.last, let info = Self.read(newest, id: id, source: .webStore) { found.append(info) }
        }
        installed = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether the person's tabs can run extensions, as the engine reports it for the tabs it
    /// has made: a tab asked for Chrome style may have been given Alloy, which runs none.
    enum Support { case unknown, on, off }

    static func support(in store: TabStore) -> Support {
        if ChromiumBrowserView.chromeStyleRefused { return .off }
        let live = store.tabs.filter { !store.isAgentTab($0) && $0.view.hasBrowser }
        if live.isEmpty { return .unknown }
        return live.contains { $0.view.isChromeStyle } ? .on : .off
    }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }
    func isEnabled(_ info: ExtensionInfo) -> Bool { info.source == .webStore || !disabled.contains(info.id) }

    func setEnabled(_ info: ExtensionInfo, _ enabled: Bool) {
        guard info.source == .acorn else { return }
        disabled.removeAll { $0 == info.id }
        if !enabled { disabled.append(info.id) }
        UserDefaults.standard.set(disabled, forKey: "disabledExtensions")
        needsRelaunch = true
    }

    func remove(_ info: ExtensionInfo) {
        guard info.source == .acorn else { return }
        try? FileManager.default.removeItem(at: info.folder)
        refresh()
        needsRelaunch = true
    }

    // MARK: Installing

    /// The Store id in a Web Store address, as in
    /// chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh.
    static func webStoreID(in address: String) -> String? {
        guard let url = URL(string: address), let host = url.host(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last(where: isID)
    }

    nonisolated static func isID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    func install(_ id: String) {
        guard !installing.contains(id) else { return }
        installing.insert(id)
        lastError = nil
        Task {
            do {
                try await Self.download(id)
                refresh()
                needsRelaunch = true
            } catch {
                lastError = "The extension could not be installed: \(error.localizedDescription)"
            }
            installing.remove(id)
        }
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Fetches the Store's package for `id`, unpacks it into the app's folder, and writes the
    /// Store's public key into its manifest so it keeps the Store's id when loaded unpacked.
    private nonisolated static func download(_ id: String) async throws {
        let version = await ChromiumEngine.chromiumVersion
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: version),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw InstallError("the Web Store did not send it")
        }
        let package = try CRX(data)

        let manager = FileManager.default
        let destination = folder.appendingPathComponent(id)
        let archive = manager.temporaryDirectory.appendingPathComponent("\(id).zip")
        try package.zip.write(to: archive)
        defer { try? manager.removeItem(at: archive) }
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw InstallError("its package could not be opened") }

        // Chromium refuses an unpacked extension holding names it reserves, like the Store's
        // signature folder.
        try? manager.removeItem(at: destination.appendingPathComponent("_metadata"))

        let manifestURL = destination.appendingPathComponent("manifest.json")
        if let key = package.publicKey,
           let manifestData = try? Data(contentsOf: manifestURL),
           var manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
            manifest["key"] = key.base64EncodedString()
            if let updated = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
                try updated.write(to: manifestURL)
            }
        }
    }

    // MARK: Reading

    private static func read(_ folder: URL, id: String, source: ExtensionInfo.Source) -> ExtensionInfo? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let messages = localeMessages(folder, manifest)
        func text(_ key: String) -> String {
            let raw = manifest[key] as? String ?? ""
            guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
            let name = String(raw.dropFirst(6).dropLast(2)).lowercased()
            return messages[name] ?? raw
        }
        let action = (manifest["action"] ?? manifest["browser_action"] ?? manifest["page_action"]) as? [String: Any]
        let icons = manifest["icons"] as? [String: String] ?? [:]
        let iconPath = icons.keys.compactMap(Int.init).filter { $0 <= 128 }.max().flatMap { icons[String($0)] }
            ?? icons.values.first
        let name = text("short_name").isEmpty ? text("name") : text("short_name")
        return ExtensionInfo(id: id, name: name.isEmpty ? id : name,
                             version: manifest["version"] as? String ?? "",
                             icon: iconPath.map { folder.appendingPathComponent($0) },
                             popup: action?["default_popup"] as? String,
                             source: source, folder: folder)
    }

    /// The manifest's messages in its default locale, by lowercased name.
    private static func localeMessages(_ folder: URL, _ manifest: [String: Any]) -> [String: String] {
        let locale = manifest["default_locale"] as? String ?? "en"
        let file = folder.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in json { if let message = value["message"] as? String { result[key.lowercased()] = message } }
        return result
    }

    // MARK: Relaunching

    /// Quits, and opens the app again once this process has gone (the profile can only be
    /// open in one at a time).
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open '\(app)'"]
        try? shell.run()
        NSApp.terminate(nil)
    }
}

/// A Web Store package (CRX2 or CRX3): the zip inside it, and the public key the Store's id
/// comes from.
private struct CRX {
    let zip: Data
    let publicKey: Data?

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 16, bytes[0] == 0x43, bytes[1] == 0x72, bytes[2] == 0x32, bytes[3] == 0x34 else {
            throw CRXError()
        }
        func uint32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        switch uint32(4) {
        case 2:
            let keyLength = uint32(8), signatureLength = uint32(12)
            let keyStart = 16, zipStart = 16 + keyLength + signatureLength
            guard zipStart <= bytes.count else { throw CRXError() }
            publicKey = Data(bytes[keyStart..<(keyStart + keyLength)])
            zip = Data(bytes[zipStart...])
        case 3:
            let headerLength = uint32(8)
            let zipStart = 12 + headerLength
            guard zipStart <= bytes.count else { throw CRXError() }
            publicKey = Self.storeKey(Array(bytes[12..<zipStart]))
            zip = Data(bytes[zipStart...])
        default:
            throw CRXError()
        }
    }

    struct CRXError: LocalizedError {
        var errorDescription: String? { "the package is not one the Web Store makes" }
    }

    /// CRX3's header is a protobuf: proofs (fields 2 and 3) each carry a public key (field 1),
    /// and the signed data (field 10000) carries the id (its field 1). The key whose SHA-256
    /// begins with the id is the Store's.
    private static func storeKey(_ header: [UInt8]) -> Data? {
        var keys: [[UInt8]] = []
        var crxID: [UInt8]?
        for (field, value) in fields(header) {
            switch field {
            case 2, 3:
                for (inner, bytes) in fields(value) where inner == 1 { keys.append(bytes) }
            case 10000:
                for (inner, bytes) in fields(value) where inner == 1 { crxID = bytes }
            default:
                break
            }
        }
        if let crxID {
            for key in keys where Array(SHA256.hash(data: Data(key)).prefix(16)) == crxID { return Data(key) }
        }
        return keys.first.map { Data($0) }
    }

    /// The length-delimited fields of a protobuf message, by field number.
    private static func fields(_ bytes: [UInt8]) -> [(Int, [UInt8])] {
        var result: [(Int, [UInt8])] = []
        var index = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while index < bytes.count, let tag = varint() {
            switch tag & 7 {
            case 0: guard varint() != nil else { return result }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = varint(), length >= 0, index + length <= bytes.count else { return result }
                result.append((tag >> 3, Array(bytes[index..<(index + length)])))
                index += length
            default: return result
            }
        }
        return result
    }
}

// MARK: - Interface

/// The puzzle piece beside the address: the extensions, each opening its popup, and the way to
/// the Web Store and Chromium's own extensions page.
struct ExtensionsButton: View {
    @ObservedObject var store: TabStore
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "puzzlepiece.extension") }
            .buttonStyle(.chrome)
            .help("Extensions")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ExtensionsList(store: store) { showing = false }
            }
    }
}

struct ExtensionsList: View {
    @ObservedObject var store: TabStore
    var close: () -> Void = {}
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var palette
    @State private var open: ExtensionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let open {
                HStack {
                    Button { self.open = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.chrome)
                    Text(open.name).font(Theme.Text.title).foregroundStyle(palette.ink).lineLimit(1)
                }
                ExtensionPopup(info: open).frame(width: 380, height: 520)
            } else {
                list
            }
        }
        .padding(Theme.Space.m)
        .onAppear { extensions.refresh() }
    }

    private var list: some View {
        let support = ExtensionStore.support(in: store)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Extensions").font(Theme.Text.title).foregroundStyle(palette.ink)
            SupportLine(support: support)
            if extensions.installed.isEmpty {
                Text("None yet. Find some in the Chrome Web Store; on an extension's page, use its Add button or Add to Acorn in the address.")
                    .font(Theme.Text.secondary).foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(extensions.installed) { info in row(info) }
            if extensions.needsRelaunch {
                HStack {
                    Text("Relaunch to apply the changes.").font(Theme.Text.secondary).foregroundStyle(palette.ink)
                    Spacer()
                    Button("Relaunch") { extensions.relaunch() }
                }
                .padding(Theme.Space.s)
                .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            Rectangle().fill(palette.hairline).frame(height: 1)
            Button {
                close()
                store.newTab(url: "https://chromewebstore.google.com")
            } label: { Label("Chrome Web Store", systemImage: "bag") }
                .buttonStyle(.row)
            if support == .on {
                Button {
                    close()
                    store.newTab(url: "chrome://extensions")
                } label: { Label("Chromium's Extensions Page", systemImage: "gearshape") }
                    .buttonStyle(.row)
            }
        }
        .frame(width: 320)
    }

    private func row(_ info: ExtensionInfo) -> some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if let icon = info.icon, let image = NSImage(contentsOf: icon) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(palette.inkTertiary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name).font(Theme.Text.body).foregroundStyle(palette.ink).lineLimit(1)
                Text(info.source == .acorn ? "Added by Acorn · \(info.version)" : "Web Store · \(info.version)")
                    .font(Theme.Text.caption).foregroundStyle(palette.inkTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            if info.popup != nil && extensions.isEnabled(info) && !ChromiumBrowserView.chromeStyleRefused {
                Button { open = info } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(ChromeButtonStyle(size: 24))
                    .help("Open \(info.name)")
            }
            if info.source == .acorn {
                Toggle("", isOn: Binding(get: { extensions.isEnabled(info) }, set: { extensions.setEnabled(info, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                Button { extensions.remove(info) } label: { Image(systemName: "trash") }
                    .buttonStyle(ChromeButtonStyle(size: 24))
                    .help("Remove")
            }
        }
        .frame(height: 38)
    }
}

/// What the engine says about extensions here, in a line.
struct SupportLine: View {
    let support: ExtensionStore.Support
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(support == .on ? Color.green : support == .off ? Color.orange : palette.inkTertiary)
                .frame(width: 7, height: 7)
            Text(text).font(Theme.Text.caption).foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        switch support {
        case .on: "On: your tabs run Chrome's extension system."
        case .off: "Off: on this Mac the engine can't run extensions inside Acorn's tabs, so they are plain views. Site boosts still work."
        case .unknown: "Open a tab of your own to see whether extensions can run."
        }
    }
}

/// An extension's popup page, in a Chrome-style view of its own, closed with the popover.
private struct ExtensionPopup: View {
    let info: ExtensionInfo
    @StateObject private var holder = Holder()

    final class Holder: ObservableObject {
        @Published var view: ChromiumBrowserView?
    }

    var body: some View {
        Group {
            if let view = holder.view { BrowserPane(view: view) } else { Color.clear }
        }
        .onAppear {
            guard holder.view == nil, let popup = info.popup else { return }
            let view = ChromiumBrowserView(url: "chrome-extension://\(info.id)/\(popup)")
            view.usesChromeStyle = true
            holder.view = view
        }
        .onDisappear {
            holder.view?.destroyBrowser()
            holder.view = nil
        }
    }
}

/// "Add to Acorn" in the address of a Web Store extension's page, for when the Store's own
/// button cannot install into this browser.
struct AddExtensionButton: View {
    let id: String
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if extensions.installing.contains(id) {
                ProgressView().controlSize(.small)
            } else if extensions.isInstalled(id) {
                if extensions.needsRelaunch {
                    Button("Relaunch to Turn On") { extensions.relaunch() }
                } else {
                    Label("Added", systemImage: "checkmark").foregroundStyle(palette.inkSecondary)
                }
            } else {
                Button { extensions.install(id) } label: {
                    Label("Add to Acorn", systemImage: "puzzlepiece.extension")
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(palette.accent.opacity(0.12), in: Capsule())
        .help(extensions.lastError ?? "Install this extension into Acorn")
    }
}
