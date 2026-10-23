import SwiftUI

/// The Settings window (⌘,): the look, the tabs' layout, search and translation, and clearing
/// what the browser keeps. The agent's model is chosen in the agent panel, not here.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            GeneralSettings(store: .shared)
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings(store: .shared)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 460)
    }
}

private struct AppearanceSettings: View {
    var body: some View {
        VStack(spacing: 0) {
            ThemePicker()
            Text("Changes show on every window as you make them.")
                .font(Theme.Text.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, Theme.Space.l)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        Form {
            Picker("Tabs", selection: $store.verticalLayout) {
                Text("In a sidebar").tag(true)
                Text("Across the top").tag(false)
            }
            Picker("Search with", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
            }
            Picker("Translate pages into", selection: $settings.translateLanguage) {
                ForEach(BrowserSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

private struct PrivacySettings: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var history = HistoryStore.shared
    @State private var cleared = ""

    var body: some View {
        Form {
            LabeledContent("History") {
                Button("Clear History") {
                    clearBrowsingData(history: true, cookies: false, using: store.active.view)
                    cleared = "History cleared."
                }
                .disabled(history.entries.isEmpty)
            }
            LabeledContent("Cookies and cache") {
                Button("Clear Cookies and Cache") {
                    clearBrowsingData(history: false, cookies: true, using: store.active.view)
                    cleared = "Cookies and cache cleared. Sites, the agent's included, will ask you to sign in again."
                }
            }
            if !cleared.isEmpty {
                Text(cleared).font(Theme.Text.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 200)
    }
}
