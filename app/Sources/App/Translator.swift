import SwiftUI
import NaturalLanguage

/// Where a tab's translation stands.
enum TranslationState: Equatable {
    case idle, working, done, failed
}

/// Translates pages the way Chrome does: in place. The page's language is told from its text;
/// when it is not the person's, the address offers a translation. Translating walks the page's
/// text nodes, sends their text to Google's translator in batches (the visible part first),
/// and swaps each node's text where it stands, keeping the original for "Show Original". Text
/// that appears later (a feed, a reply) is translated as it comes. The request is made by the
/// app rather than the page, so no site's security policy can stop it. The agent's tab is
/// never translated: the pages it sees are the site's own.
@MainActor
final class Translator {
    static let shared = Translator()

    /// How much text goes in one request, and how many requests are out at once.
    private static let batchCharacters = 3_500
    private static let parallel = 4
    private static let binding = "__acornTranslateMore"

    /// Tabs being worked through now, so a burst of new text does not start a second pass.
    private var pumping: Set<UUID> = []
    /// Tabs whose page can call back for more (a DevTools binding, set once per tab).
    private var bound: Set<UUID> = []

    // MARK: Detecting

    /// After a load: tell the page's language, and translate at once when the person said to
    /// always translate it.
    func pageLoaded(_ tab: BrowserModel) {
        guard tab !== BrowserModel.shared, !tab.isStart,
              tab.address.hasPrefix("http://") || tab.address.hasPrefix("https://") else { return }
        Task {
            let value = await evaluate(tab, """
            JSON.stringify({ lang: document.documentElement.lang || '',
                             text: (document.body ? document.body.innerText : '').slice(0, 2000) })
            """)
            guard let json = value as? String, let data = json.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            let language = Self.language(text: page["text"] ?? "", declared: page["lang"] ?? "")
            tab.pageLanguage = language
            if let language, BrowserSettings.shared.alwaysTranslate.contains(Self.base(language)),
               offers(tab) {
                translate(tab)
            }
        }
    }

    /// Whether the address should offer a translation: the page is in a language other than
    /// the one pages are turned into, and the person has not said never for it.
    func offers(_ tab: BrowserModel) -> Bool {
        guard let language = tab.pageLanguage else { return false }
        let settings = BrowserSettings.shared
        let base = Self.base(language)
        return base != Self.base(settings.translateLanguage) && !settings.neverTranslate.contains(base)
    }

    /// The language the text is written in, or failing that the one the page declares.
    private static func language(text: String, declared: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let detected = recognizer.dominantLanguage, detected != .undetermined {
            switch detected {
            case .simplifiedChinese: return "zh-CN"
            case .traditionalChinese: return "zh-TW"
            default: return detected.rawValue
            }
        }
        return declared.isEmpty ? nil : declared
    }

    /// "zh-CN" stays itself (the two Chinese scripts differ); "en-GB" is "en".
    static func base(_ code: String) -> String {
        if code.lowercased().hasPrefix("zh") {
            return code.lowercased().contains("tw") || code.lowercased().contains("hant") ? "zh-TW" : "zh-CN"
        }
        return String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    static func name(of code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    // MARK: Translating

    func translate(_ tab: BrowserModel) {
        guard tab !== BrowserModel.shared, tab.translation != .working else { return }
        tab.translation = .working
        Task {
            await bind(tab)
            _ = await evaluate(tab, Self.pageScript)
            _ = await evaluate(tab, "window.__acornT.start()")
            await pump(tab)
        }
    }

    func showOriginal(_ tab: BrowserModel) {
        Task { _ = await evaluate(tab, "window.__acornT && window.__acornT.restore()") }
        tab.translation = .idle
    }

    /// Takes batches of text from the page and puts their translations back, a few at a
    /// time, until the page has none left.
    private func pump(_ tab: BrowserModel) async {
        guard !pumping.contains(tab.id) else { return }
        pumping.insert(tab.id)
        defer { pumping.remove(tab.id) }
        let target = BrowserSettings.shared.translateLanguage
        var failures = 0
        while tab.translation == .working || tab.translation == .done {
            var batches: [[(id: Int, text: String)]] = []
            for _ in 0..<Self.parallel {
                let batch = await take(tab)
                if batch.isEmpty { break }
                batches.append(batch)
            }
            if batches.isEmpty { break }
            let results = await withTaskGroup(of: [Int: String]?.self) { group in
                for batch in batches {
                    group.addTask { await Self.request(batch, to: target) }
                }
                var all: [[Int: String]?] = []
                for await result in group { all.append(result) }
                return all
            }
            for result in results {
                guard let result else {
                    failures += 1
                    continue
                }
                guard let data = try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: result.map { (String($0.key), $0.value) })),
                      let json = String(data: data, encoding: .utf8),
                      let literal = try? String(data: JSONEncoder().encode(json), encoding: .utf8) else { continue }
                _ = await evaluate(tab, "window.__acornT.apply(\(literal))")
            }
            if failures > 0, results.allSatisfy({ $0 == nil }) {
                tab.translation = .failed
                return
            }
            if tab.translation == .working { tab.translation = .done }
        }
        if tab.translation == .working { tab.translation = .done }
    }

    private func take(_ tab: BrowserModel) async -> [(id: Int, text: String)] {
        guard let json = await evaluate(tab, "window.__acornT ? window.__acornT.take(\(Self.batchCharacters)) : '[]'") as? String,
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return items.compactMap { item in
            guard item.count == 2, let id = (item[0] as? NSNumber)?.intValue, let text = item[1] as? String else { return nil }
            return (id, text)
        }
    }

    /// The page calls `__acornTranslateMore` when new text has appeared; the tab's DevTools
    /// events carry the call here. The agent's tab, whose events `AgentDriver` takes, is never
    /// bound.
    private func bind(_ tab: BrowserModel) async {
        guard !bound.contains(tab.id) else { return }
        bound.insert(tab.id)
        tab.view.devToolsEventHandler = { [weak self, weak tab] method, params in
            MainActor.assumeIsolated {
                guard method == "Runtime.bindingCalled", let self, let tab,
                      (params?["name"] as? String) == Self.binding, tab.translation == .done else { return }
                Task { await self.pump(tab) }
            }
        }
        await call(tab, "Runtime.enable")
        await call(tab, "Runtime.addBinding", ["name": Self.binding])
    }

    // MARK: The translator

    /// Sends a batch to Google's translator (the endpoint its own tools use, which needs no
    /// key) and returns each piece's translation by the page's id for it.
    private nonisolated static func request(_ batch: [(id: Int, text: String)], to target: String) async -> [Int: String]? {
        var request = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/t?client=gtx&sl=auto&tl=\(target)&format=text")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = batch
            .map { "q=" + ($0.text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // One piece comes back as a string or [text, language]; several as an array of those.
        func text(_ value: Any) -> String? {
            if let string = value as? String { return string }
            if let pair = value as? [Any], let string = pair.first as? String { return string }
            return nil
        }
        let pieces: [String]
        if batch.count == 1, let one = text(json) {
            pieces = [one]
        } else if let array = json as? [Any] {
            pieces = array.compactMap(text)
        } else {
            return nil
        }
        guard pieces.count == batch.count else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(batch.map(\.id), pieces))
    }

    // MARK: DevTools

    private func call(_ tab: BrowserModel, _ method: String, _ params: [String: Any] = [:]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tab.view.sendDevToolsMethod(method, params: params) { _, _ in continuation.resume() }
        }
    }

    private func evaluate(_ tab: BrowserModel, _ expression: String) async -> Any? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            tab.view.sendDevToolsMethod("Runtime.evaluate", params: ["expression": expression, "returnByValue": true]) { success, result in
                guard success, let result = result as? [String: Any], result["exceptionDetails"] == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (result["result"] as? [String: Any])?["value"])
            }
        }
    }

    /// What goes into the page, once per document: it finds the text worth translating, hands
    /// it out in batches (what is on screen first), swaps translations in, puts originals back,
    /// and watches for new text, calling back when some has come.
    private static let pageScript = #"""
    (() => {
      if (window.__acornT) return;
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'INPUT', 'SELECT',
                            'OPTION', 'SVG', 'MATH', 'CANVAS', 'IFRAME', 'KBD', 'SAMP', 'VAR', 'TEMPLATE']);
      const originals = new Map();
      const ids = new WeakMap();
      let next = 1, pending = [], observer = null, active = false, timer = null;

      const eligible = (node) => {
        const text = node.nodeValue;
        if (!text || !/\p{L}/u.test(text)) return false;
        for (let el = node.parentElement; el; el = el.parentElement) {
          if (SKIP.has(el.tagName) || el.isContentEditable || el.getAttribute('translate') === 'no' ||
              el.classList.contains('notranslate')) return false;
        }
        return true;
      };
      const gather = (root, out) => {
        if (root.nodeType === 3) {
          if (!ids.has(root) && eligible(root)) out.push(root);
        } else {
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          for (let n = walker.nextNode(); n; n = walker.nextNode()) if (!ids.has(n) && eligible(n)) out.push(n);
        }
        for (const n of out) if (!ids.has(n)) {
          const id = next++;
          ids.set(n, id);
          originals.set(id, { node: n, text: n.nodeValue });
        }
      };
      const onScreen = (n) => {
        const el = n.parentElement;
        if (!el) return 0;
        const r = el.getBoundingClientRect();
        return r.bottom > 0 && r.top < innerHeight * 1.5 ? 1 : 0;
      };
      const more = () => {
        clearTimeout(timer);
        timer = setTimeout(() => { if (active && pending.length && window.__acornTranslateMore) window.__acornTranslateMore('1'); }, 400);
      };

      window.__acornT = {
        start() {
          active = true;
          const nodes = [];
          gather(document.body, nodes);
          nodes.sort((a, b) => onScreen(b) - onScreen(a));
          pending.push(...nodes.map((n) => ids.get(n)));
          if (!observer) {
            observer = new MutationObserver((mutations) => {
              if (!active) return;
              const nodes = [];
              for (const m of mutations) for (const added of m.addedNodes) gather(added, nodes);
              if (nodes.length) { pending.push(...nodes.map((n) => ids.get(n))); more(); }
            });
            observer.observe(document.body, { childList: true, subtree: true });
          }
        },
        take(limit) {
          const batch = [];
          let size = 0;
          while (pending.length && size < limit) {
            const id = pending.shift();
            const o = originals.get(id);
            if (!o || !o.node.isConnected || o.translated !== undefined) continue;
            const text = o.text.trim();
            batch.push([id, text]);
            size += text.length;
          }
          return JSON.stringify(batch);
        },
        apply(json) {
          for (const [id, text] of Object.entries(JSON.parse(json))) {
            const o = originals.get(Number(id));
            if (!o || !o.node.isConnected || !active) continue;
            const lead = o.text.match(/^\s*/)[0], trail = o.text.match(/\s*$/)[0];
            o.translated = text;
            o.node.nodeValue = lead + text + trail;
          }
        },
        restore() {
          active = false;
          if (observer) observer.disconnect();
          observer = null;
          pending = [];
          for (const o of originals.values()) {
            if (o.translated !== undefined && o.node.isConnected) o.node.nodeValue = o.text;
            delete o.translated;
          }
        },
      };
    })();
    """#
}

/// The address's translate offer: what the page is in, and Translate or Show Original, with
/// always and never for its language.
struct TranslatePopover: View {
    @ObservedObject var tab: BrowserModel
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var palette

    private var language: String { tab.pageLanguage.map(Translator.base) ?? "" }
    private var languageName: String { Translator.name(of: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "character.bubble").foregroundStyle(palette.accent)
                Text("Translate").font(Theme.Text.title).foregroundStyle(palette.ink)
            }
            Text(status).font(Theme.Text.body).foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if tab.translation == .done || tab.translation == .working {
                    Button("Show Original") { Translator.shared.showOriginal(tab) }
                } else {
                    Button("Translate to \(Translator.name(of: settings.translateLanguage))") {
                        Translator.shared.translate(tab)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if tab.translation == .working { ProgressView().controlSize(.small) }
            }
            Divider()
            Toggle("Always translate \(languageName)", isOn: Binding(
                get: { settings.alwaysTranslate.contains(language) },
                set: { on in
                    settings.alwaysTranslate.removeAll { $0 == language }
                    if on {
                        settings.alwaysTranslate.append(language)
                        settings.neverTranslate.removeAll { $0 == language }
                    }
                }))
            Toggle("Never offer for \(languageName)", isOn: Binding(
                get: { settings.neverTranslate.contains(language) },
                set: { on in
                    settings.neverTranslate.removeAll { $0 == language }
                    if on {
                        settings.neverTranslate.append(language)
                        settings.alwaysTranslate.removeAll { $0 == language }
                    }
                }))
        }
        .toggleStyle(.checkbox)
        .padding(Theme.Space.l)
        .frame(width: 300)
    }

    private var status: String {
        switch tab.translation {
        case .idle: "This page is in \(languageName)."
        case .working: "Translating from \(languageName)\u{2026}"
        case .done: "Translated from \(languageName)."
        case .failed: "The page could not be translated. Check the connection and try again."
        }
    }
}
