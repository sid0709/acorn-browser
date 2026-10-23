import SwiftUI

/// A site's boost: styles and a script of the person's own, put into every page of that site
/// when it loads. This is how the browser is extended: the engine runs Chromium's Alloy
/// style, which cannot load Web Store extensions.
struct Boost: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var host: String
    var css = ""
    var script = ""
    var enabled = true
}

/// The site whose boost is being edited, for the sheet.
struct BoostTarget: Identifiable {
    let host: String
    var id: String { host }
}

@MainActor
final class BoostStore: ObservableObject {
    static let shared = BoostStore()

    private let file = JSONFile<[Boost]>("boosts.json")
    @Published private(set) var boosts: [Boost]

    private init() { boosts = file.load() ?? [] }

    func boost(for host: String) -> Boost? { boosts.first { $0.host == host } }

    func save(_ boost: Boost) {
        if let index = boosts.firstIndex(where: { $0.id == boost.id }) {
            boosts[index] = boost
        } else {
            boosts.append(boost)
        }
        file.save(boosts, after: 0.3)
    }

    func remove(_ boost: Boost) {
        boosts.removeAll { $0.id == boost.id }
        file.save(boosts, after: 0.3)
    }

    func setEnabled(_ boost: Boost, _ enabled: Bool) {
        var changed = boost
        changed.enabled = enabled
        save(changed)
    }

    /// Puts the site's boost into the page shown, once per document. The agent's tab is left
    /// alone: the pages the agent sees are the site's own.
    func apply(to tab: BrowserModel) {
        guard tab !== BrowserModel.shared, let host = URL(string: tab.address)?.host(),
              let boost = boost(for: host), boost.enabled, !(boost.css.isEmpty && boost.script.isEmpty),
              let css = try? String(data: JSONEncoder().encode(boost.css), encoding: .utf8) else { return }
        let expression = """
        (() => {
          if (window.__acornBoost) return;
          window.__acornBoost = true;
          const style = document.createElement('style');
          style.textContent = \(css);
          document.documentElement.appendChild(style);
          try {
        \(boost.script)
          } catch (error) { console.error('Acorn boost:', error); }
        })();
        """
        tab.view.sendDevToolsMethod("Runtime.evaluate", params: ["expression": expression]) { _, _ in }
    }
}

/// Writes a site's boost: its styles and its script, with a switch to turn it off.
struct BoostEditor: View {
    let host: String
    @ObservedObject private var store = BoostStore.shared
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var boost = Boost(host: "")

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(palette.accent)
                Text("Boost \(host)").font(Theme.Text.title).foregroundStyle(palette.ink)
                Spacer()
                Toggle("On", isOn: $boost.enabled).toggleStyle(.switch).controlSize(.small)
            }
            Text("Styles and a script of your own, put into every page of this site when it loads. Reload the page to see a change.")
                .font(Theme.Text.secondary).foregroundStyle(palette.inkSecondary)
            editor("CSS", text: $boost.css)
            editor("JavaScript", text: $boost.script)
            HStack {
                if store.boost(for: host) != nil {
                    Button("Delete Boost", role: .destructive) {
                        store.remove(boost)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.save(boost)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560, height: 520)
        .background(palette.card)
        .onAppear { boost = store.boost(for: host) ?? Boost(host: host) }
    }

    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Text.section).foregroundStyle(palette.inkSecondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .background(palette.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
    }
}
