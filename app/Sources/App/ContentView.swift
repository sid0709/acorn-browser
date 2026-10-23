import SwiftUI

/// Hosts the Chromium view. SwiftUI only places it; the page draws itself.
struct BrowserPane: NSViewRepresentable {
    let view: ChromiumBrowserView

    func makeNSView(context: Context) -> ChromiumBrowserView { view }
    func updateNSView(_ nsView: ChromiumBrowserView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject private var browser = BrowserModel.shared
    @State private var addressField = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                ProgressView(value: browser.isLoading ? browser.progress : 0)
                    .progressViewStyle(.linear)
                    .opacity(browser.isLoading ? 1 : 0)
                    .frame(height: 2)
                BrowserPane(view: browser.view)
            }
            Divider()
            ChatSidebar()
                .frame(width: 340)
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(browser.title.isEmpty ? "Acorn Browser" : browser.title)
        .onChange(of: browser.address) { _, new in
            if !addressFocused { addressField = new }
        }
        .onAppear { addressField = browser.address }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { browser.view.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
            Button { browser.view.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward)
            Button {
                browser.isLoading ? browser.view.stopLoading() : browser.view.reload()
            } label: {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            TextField("Search or enter address", text: $addressField)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit {
                    browser.go(to: addressField)
                    addressFocused = false
                    browser.view.focusBrowser()
                }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
