import SwiftUI

@main
struct AcornBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The Keychain check delays the first page by several seconds, and this browser
        // keeps no saved logins yet.
        ChromiumEngine.usesSystemKeychain = false
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
