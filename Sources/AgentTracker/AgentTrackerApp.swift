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

        // Debug utility: `AgentTracker --render-preview out.png` renders the
        // dropdown with live data to a PNG and exits — lets the popover be
        // inspected/iterated without clicking the menu bar.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
            CommandLine.arguments.count > flagIndex + 1
        {
            let path = CommandLine.arguments[flagIndex + 1]
            Task { @MainActor in
                let store = SessionStore()
                // Wait for the codex scanner's first publish (slow lsof pass +
                // multi-MB bootstraps), up to 15s; renders early once a codex
                // row lands.
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if store.sessions.contains(where: { $0.provider == "codex" }) { break }
                }
                let renderer = ImageRenderer(content: MenuContentView(store: store))
                renderer.scale = 2
                if let image = renderer.nsImage,
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                {
                    try? png.write(to: URL(fileURLWithPath: path))
                    let size = "\(Int(image.size.width))x\(Int(image.size.height))"
                    print("[preview] wrote \(path) (\(size) pt)")
                } else {
                    print("[preview] render failed")
                }
                NSApp.terminate(nil)
            }
        }
    }
}
