import SwiftUI

@main
struct AcornBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window: one of it, holding the agent's tab.
        Window("Acorn Browser", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands() }

        // Further windows (⌘N) and incognito ones (⇧⌘N), with tabs of their own.
        WindowGroup("Window", id: "browser", for: WindowRequest.self) { $request in
            ContentView(kind: request?.kind ?? .normal)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
    }
}

/// The menu bar: every command the window has, with its key. The keys themselves are also
/// held by `WindowShortcuts` inside the window, which gets them first when the page has focus;
/// either way one press does one thing. ⌘W is left to the window, where it closes the tab.
struct BrowserCommands: Commands {
    @FocusedObject private var store: TabStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Settings is a page in a tab (acorn://settings), as in Chrome, not a window of its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { (store ?? TabStore.shared).openPage(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store?.commandBar = .newTab }
                .keyboardShortcut("t")
            Button("New Window") { openWindow(id: "browser", value: WindowRequest(kind: .normal)) }
                .keyboardShortcut("n")
            Button("New Incognito Window") { openWindow(id: "browser", value: WindowRequest(kind: .incognito)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Location\u{2026}") { if let store { store.editingAddress = store.activeID } }
                .keyboardShortcut("l")
            Divider()
            Button("Close Tab") { if let store { store.close(store.active) } }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { store?.active.printPage() }
                .keyboardShortcut("p")
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Page\u{2026}") { store?.active.startFinding() }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") { store?.active.view.reload() }
                .keyboardShortcut("r")
            Divider()
            Button("Zoom In") { store?.active.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { store?.active.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { store?.active.zoomReset() }
                .keyboardShortcut("0")
            Divider()
            Button(store?.verticalLayout == true ? "Use Tabs Across the Top" : "Use a Sidebar for Tabs") {
                withAnimation(Theme.layout) { store?.verticalLayout.toggle() }
            }
            Button(store?.sidebarHidden == true ? "Show Sidebar" : "Hide Sidebar") { store?.toggleSidebar() }
                .keyboardShortcut("s")
                .disabled(store?.verticalLayout != true)
            Button(store?.showAgent == true ? "Hide Agent" : "Show Agent") { store?.toggleAgent() }
                .keyboardShortcut("k")
                .disabled(store?.hasAgent != true)
            Button(store?.shownSplit == nil ? "Open Split View" : "Close Split View") { store?.toggleSplit() }
                .keyboardShortcut("\\")
            Divider()
        }
        CommandMenu("Tab") {
            Button(store?.active.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                if let store { store.togglePin(store.active) }
            }
            .disabled(store.map { $0.isAgentTab($0.active) } ?? true)
            Button("Duplicate Tab") { if let store { store.duplicate(store.active) } }
                .disabled(store.map { $0.isAgentTab($0.active) } ?? true)
            Button("Copy Link") { store?.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button(store?.active.translation == .done ? "Show Original" : "Translate Page") { store?.active.translate() }
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") { store?.toggleBookmark() }
                .keyboardShortcut("d")
        }
        CommandMenu("History") {
            Button("Show All History") { store?.showingHistory = true }
                .keyboardShortcut("y")
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Extensions") { (store ?? TabStore.shared).openPage(.extensions) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Notes every moment the window stops answering, and what held it (perf.log).
        ChromiumPerf.startWatching()
        // The Keychain check delays the first page by several seconds, and this browser
        // keeps no saved logins yet.
        ChromiumEngine.usesSystemKeychain = false
        // Extensions the app installed itself load with the engine.
        ChromiumEngine.extensionDirectories = ExtensionStore.launchDirectories()
        if !ChromiumEngine.start() {
            NSLog("AcornBrowser: Chromium did not start.")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentServer.shared.start(driver: AgentDriver(model: BrowserModel.shared))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Chromium is not shut down gracefully; it flushes cookies and exits within a second.
        ChromiumEngine.quitImmediately()
        return .terminateLater
    }
}
