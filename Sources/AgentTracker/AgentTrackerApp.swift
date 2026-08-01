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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: SessionStore?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hitRegions: [StatusIconRenderer.HitRegion] = []
    private var storeSubscription: AnyCancellable?
    private var dismissMonitor: Any?
    private var focusObserver: TerminalFocusObserver?
    private var onboardingWindow: NSWindow?

    private static let onboardingCompletedKey = "onboardingCompleted"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        if runRenderPreviewIfRequested() { return }

        let store = SessionStore()
        self.store = store
        setUpStatusItem(for: store)
        focusObserver = TerminalFocusObserver(store: store)
        showOnboardingIfNeeded()
    }

    /// First-run only: a menu bar app that silently appears and does nothing
    /// until an unrequested permission is granted makes a terrible first
    /// impression. One window, shown once — see `Onboarding.shouldShow`.
    private func showOnboardingIfNeeded() {
        let environment = Onboarding.Environment(
            accessibilityGranted: TerminalFocuser.hasAccessibilityPermission,
            claudeHookInstalled: HookSetup.claudeHookInstalled(),
            codexHookInstalled: HookSetup.codexHookInstalled(),
            claudePresent: HookSetup.claudePresent(),
            codexPresent: HookSetup.codexPresent(),
            completedBefore: UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        )
        // `--onboarding` re-opens the window on demand (debugging, support,
        // "how do I set this up again") without wiping the completion flag.
        let forced = CommandLine.arguments.contains("--onboarding")
        guard forced || Onboarding.shouldShow(environment) else { return }

        let host = NSHostingController(
            rootView: OnboardingView { [weak self] in self?.onboardingWindow?.close() })
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    /// Any dismissal of the onboarding window — Done, Skip, the close button,
    /// Cmd+W — counts as completed, so it can never nag twice.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else {
            return
        }
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        onboardingWindow = nil
        // Onboarding activated this accessory app; hand focus back like the
        // popover does, or the user is stranded with no key window.
        NSApp.deactivate()
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
        // The `[ui]` trace mirrors `[focus]`: menu bar interaction is hard to
        // test programmatically, so misbehavior must be diagnosable from a
        // single paste of the app's output.
        let dot = clicked?.rawValue ?? "none"
        let filter = store.selectedFilter?.rawValue ?? "none"
        if popover.isShown {
            if let clicked, clicked != store.selectedFilter {
                print("[ui] \(DebugLog.timestamp()) dot=\(dot) while open → switch filter")
                store.selectedFilter = clicked
            } else {
                print("[ui] \(DebugLog.timestamp()) dot=\(dot) filter=\(filter) → toggle close")
                closePopover()
            }
        } else {
            print("[ui] \(DebugLog.timestamp()) dot=\(dot) → open")
            store.selectedFilter = clicked
            showPopover(from: sender)
        }
    }

    /// Maps the click's x-position inside the status button back to the dot it
    /// hit (near-misses snap to the nearest dot); nil = beyond snap tolerance
    /// of every dot → unfiltered.
    private func clickedState(in button: NSStatusBarButton) -> SessionState? {
        guard let event = NSApp.currentEvent, let image = button.image else {
            print("[ui] click mapping failed: no current event or image")
            return nil
        }
        let point = button.convert(event.locationInWindow, from: nil)
        // The button centers its image; hit regions are in image coordinates.
        let originX = (button.bounds.width - image.size.width) / 2
        let imageX = point.x - originX
        let hit = StatusIconRenderer.state(atImageX: imageX, regions: hitRegions)
        let exact = hitRegions.contains { $0.range.contains(imageX) }
        let label = "\(hit?.rawValue ?? "none")\(hit != nil && !exact ? " (snapped)" : "")"
        let regions = hitRegions.map {
            "\($0.state.rawValue):\(Int($0.range.lowerBound))-\(Int($0.range.upperBound))"
        }
        print(
            "[ui] click x=\(String(format: "%.1f", imageX)) "
                + "→ \(label) (regions \(regions.joined(separator: " ")))")
        return hit
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

    /// Debug utility:
    /// `AgentTracker --render-preview out.png [--filter needsYou] [--appearance dark]
    ///  [--view onboarding]`
    /// renders the dropdown (or the onboarding window) with live data to a PNG
    /// and exits — lets the UI be inspected/iterated without clicking the menu
    /// bar. Returns true when preview mode is active (the status item is
    /// skipped).
    ///
    /// Caveat worth knowing before trusting a preview: `ImageRenderer` does not
    /// rasterize AppKit-backed views, so `TextField` renders as a coloured
    /// placeholder bar and any `NSVisualEffectView` material is simply absent.
    /// Those need a real popover screenshot.
    private func runRenderPreviewIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--render-preview"),
            arguments.count > flagIndex + 1
        else { return false }
        let path = arguments[flagIndex + 1]
        var darkMode = false
        if let appearanceIndex = arguments.firstIndex(of: "--appearance") {
            // A typo silently rendering light mode would send someone hunting
            // for a dark-mode bug in a light-mode screenshot.
            let value =
                arguments.count > appearanceIndex + 1
                ? arguments[appearanceIndex + 1].lowercased() : ""
            switch value {
            case "dark": darkMode = true
            case "light": darkMode = false
            default:
                FileHandle.standardError.write(
                    Data("[preview] --appearance expects light or dark\n".utf8))
                exit(2)
            }
        }
        let appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        var view = "popover"
        if let viewIndex = arguments.firstIndex(of: "--view"), arguments.count > viewIndex + 1 {
            view = arguments[viewIndex + 1]
        }
        Task {
            let content: AnyView
            switch view {
            case "onboarding":
                content = AnyView(OnboardingView())
            case "popover":
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
                content = AnyView(MenuContentView(store: store))
            default:
                FileHandle.standardError.write(
                    Data("[preview] --view expects popover or onboarding\n".utf8))
                exit(2)
            }
            let renderer = ImageRenderer(
                content:
                    content
                    .environment(\.colorScheme, darkMode ? .dark : .light)
                    // The real window's background is the system's; here there
                    // is none, so dark-mode text would render white on
                    // transparency and flatten to white-on-white. Hard-coded
                    // rather than semantic because dynamic NSColors do not
                    // resolve to the dark variant inside ImageRenderer.
                    .background(darkMode ? Color(white: 0.145) : Color(white: 0.98))
            )
            renderer.scale = 2
            var rendered: (data: Data, size: NSSize)?
            // Dynamic colors resolve against the current *drawing* appearance,
            // which ImageRenderer does not inherit from NSApp on its own.
            appearance?.performAsCurrentDrawingAppearance {
                if let image = renderer.nsImage,
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                {
                    rendered = (png, image.size)
                }
            }
            if let rendered {
                try? rendered.data.write(to: URL(fileURLWithPath: path))
                let size = "\(Int(rendered.size.width))x\(Int(rendered.size.height))"
                print("[preview] wrote \(path) (\(size) pt)")
            } else {
                print("[preview] render failed")
            }
            NSApp.terminate(nil)
        }
        return true
    }
}
