import AppKit
import SwiftUI

@main
struct AgentTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Image(nsImage: StatusIconRenderer.image(for: store.counts))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}
