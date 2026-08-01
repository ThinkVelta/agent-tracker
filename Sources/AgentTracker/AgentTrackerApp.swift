import AppKit
import Combine
import SwiftUI

@main
struct AgentTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar presence is a raw NSStatusItem owned by the AppDelegate:
        // MenuBarExtra's label is a single click target, and per-dot filtering
        // needs to know WHERE in the icon the click landed. The never-opened
        // Settings scene is the conventional placeholder that keeps a SwiftUI
        // app alive without any window.
        Settings {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hitRegions: [StatusIconRenderer.HitRegion] = []
    private var storeSubscription: AnyCancellable?
    private var dismissMonitor: Any?
    private var focusObserver: TerminalFocusObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        if runRenderPreviewIfRequested() { return }

        let store = SessionStore()
        self.store = store
        setUpStatusItem(for: store)
        focusObserver = TerminalFocusObserver(store: store)
    }

    private func setUpStatusItem(for store: SessionStore) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
        }

        // .transient would also dismiss on the status-item click itself (its
        // mouse-down close fires before our button action, so every toggle
        // click would close-then-reopen). applicationDefined keeps the button
        // click fully ours; a per-show global monitor plus the resign-active
        // observer below cover every other dismissal path.
        popover.behavior = .applicationDefined
        popover.animates = false
        let host = NSHostingController(
            rootView: MenuContentView(store: store) { [weak self] in self?.closePopover() }
        )
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        storeSubscription = store.$sessions.sink { [weak self] sessions in
            Task { @MainActor in self?.updateIcon(for: SessionCounts(of: sessions)) }
        }
        updateIcon(for: store.counts)

        // Covers keyboard-driven context switches (Cmd+Tab, Spotlight launch)
        // that never produce an outside click.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func updateIcon(for counts: SessionCounts) {
        guard let button = statusItem?.button else { return }
        let rendering = StatusIconRenderer.render(for: counts)
        button.image = rendering.image
        hitRegions = rendering.hitRegions
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let store else { return }
        let clicked = clickedState(in: sender)
        if popover.isShown {
            if let clicked, clicked != store.selectedFilter {
                store.selectedFilter = clicked
            } else {
                // Same dot again, or a non-dot click: toggle closed.
                closePopover()
            }
        } else {
            store.selectedFilter = clicked
            showPopover(from: sender)
        }
    }

    /// Maps the click's x-position inside the status button back to the dot it
    /// hit; nil = outside every dot region → unfiltered.
    private func clickedState(in button: NSStatusBarButton) -> SessionState? {
        guard let event = NSApp.currentEvent, let image = button.image else { return nil }
        let point = button.convert(event.locationInWindow, from: nil)
        // The button centers its image; hit regions are in image coordinates.
        let originX = (button.bounds.width - image.size.width) / 2
        let imageX = point.x - originX
        return hitRegions.first { $0.range.contains(imageX) }?.state
    }

    private func showPopover(from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        // Global monitors never see this app's own events (so clicks inside
        // the popover or on the status button stay ours); installed only
        // while the popover is shown to catch clicks anywhere else — other
        // apps, other status items, the desktop.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }
        guard popover.isShown else { return }
        popover.performClose(nil)
        // Opening activated this accessory app so the popover could take
        // keyboard focus; hand activation back, or a toggle-close strands the
        // user on an active app with no key window (their typing goes
        // nowhere).
        NSApp.deactivate()
    }

    /// Debug utility: `AgentTracker --render-preview out.png [--filter needsYou]`
    /// renders the dropdown with live data to a PNG and exits — lets the
    /// popover be inspected/iterated without clicking the menu bar. Returns
    /// true when preview mode is active (the status item is skipped).
    private func runRenderPreviewIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--render-preview"),
            arguments.count > flagIndex + 1
        else { return false }
        let path = arguments[flagIndex + 1]
        Task {
            let store = SessionStore()
            if let filterIndex = arguments.firstIndex(of: "--filter"),
                arguments.count > filterIndex + 1,
                let state = SessionState(rawValue: arguments[filterIndex + 1])
            {
                store.selectedFilter = state
            }
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
        return true
    }
}
