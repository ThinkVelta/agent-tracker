import AppKit
import Combine
import SwiftUI

@main
struct AgentTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar presence is a raw NSStatusItem owned by the AppDelegate:
        // MenuBarExtra's label is a single click target, and per-dot filtering
        // needs to know WHERE in the icon the click landed. The Settings scene
        // both keeps the SwiftUI app alive without a window and provides the
        // real settings UI (Cmd+, and the popover's gear).
        Settings { SettingsView() }
    }
}

/// The dropdown's window. Borderless panels refuse key status by default, and
/// the search field needs it; `.nonactivatingPanel` means typing works without
/// activating the app (the Spotlight pattern), so opening the dropdown never
/// steals focus from whatever the user was doing.
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: SessionStore?
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var panelHost: NSHostingController<MenuContentView>?
    private var hitRegions: [StatusIconRenderer.HitRegion] = []
    private var storeSubscription: AnyCancellable?
    private var dismissMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var focusObserver: TerminalFocusObserver?
    private var onboardingWindow: NSWindow?

    private static let onboardingCompletedKey = "onboardingCompleted"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        if runRenderPreviewIfRequested() { return }

        Preferences.shared.applyAppearance()
        let store = SessionStore()
        self.store = store
        setUpStatusItem(for: store)
        focusObserver = TerminalFocusObserver(store: store)
        showOnboardingIfNeeded()

        // Debug utility: `--show-panel` opens the dropdown at launch, so
        // panel chrome (radius, material, position) can be screenshotted
        // without a scripted menu-bar click. Delayed a beat: at
        // didFinishLaunching the status button's window has no menu bar
        // position yet (anchor reads as x=0,y=-11) and the panel would land
        // off-screen. Real clicks never hit this — a clickable button is a
        // positioned one.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let button = self?.statusItem?.button else { return }
                self?.showPanel(from: button)
            }
        }
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

        // A hand-built panel rather than NSPopover: the popover's corner
        // radius is system chrome and not configurable (user feedback: too
        // round), and its arrow nub adds height. The panel also never
        // activates the app, so opening it doesn't steal focus. Dismissal is
        // the same recipe the popover used: a per-show global monitor for
        // outside clicks plus the resign-active observer below.
        panel = makePanel(for: store)

        storeSubscription = store.$sessions.sink { [weak self] sessions in
            Task { @MainActor in
                guard let self else { return }
                self.updateIcon(for: SessionCounts(of: sessions))
                // A live update can change the list's height while the panel
                // is open; re-anchor so it stays hung from the menu bar.
                if self.panel?.isVisible == true, let button = self.statusItem?.button {
                    self.layoutPanel(relativeTo: button)
                }
            }
        }
        updateIcon(for: store.counts)

        // Covers keyboard-driven context switches (Cmd+Tab, Spotlight launch)
        // that never produce an outside click.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func makePanel(for store: SessionStore) -> NSPanel {
        let host = NSHostingController(
            rootView: MenuContentView(
                store: store,
                dismiss: { [weak self] in self?.closePanel() },
                onSizeChange: { [weak self] in
                    guard let self, self.panel?.isVisible == true,
                        let button = self.statusItem?.button
                    else { return }
                    self.layoutPanel(relativeTo: button)
                }
            )
        )
        host.sizingOptions = .preferredContentSize
        panelHost = host

        let panel = StatusPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        // Follows the user across Spaces, like the popover did; auxiliary so
        // it can appear over full-screen apps.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false

        // The popover material the system dropdown had, behind our content,
        // clipped to our own (tighter) radius.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.Metrics.panelCornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let hostView = host.view
        hostView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    /// Hangs the panel from the menu bar, centered under the status item and
    /// clamped to the screen edges.
    private func layoutPanel(relativeTo button: NSStatusBarButton) {
        guard let panel, let buttonWindow = button.window, let screen = buttonWindow.screen,
            let size = panelHost?.view.fittingSize, size.width > 0
        else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let clampedX = min(
            max(anchor.midX - size.width / 2, screen.frame.minX + 8),
            screen.frame.maxX - size.width - 8)
        let originY = anchor.minY - Theme.Metrics.panelTopGap - size.height
        let frame = NSRect(x: clampedX, y: originY, width: size.width, height: size.height)
        print(
            "[ui] \(DebugLog.timestamp()) panel frame=\(frame) anchor=\(anchor) "
                + "screen=\(screen.frame)")
        panel.setFrame(frame, display: true)
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
        if panel?.isVisible == true {
            if let clicked, clicked != store.selectedFilter {
                print("[ui] \(DebugLog.timestamp()) dot=\(dot) while open → switch filter")
                store.selectedFilter = clicked
            } else {
                print("[ui] \(DebugLog.timestamp()) dot=\(dot) filter=\(filter) → toggle close")
                closePanel()
            }
        } else {
            print("[ui] \(DebugLog.timestamp()) dot=\(dot) → open")
            store.selectedFilter = clicked
            showPanel(from: sender)
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

    private func showPanel(from button: NSStatusBarButton) {
        guard let panel else { return }
        layoutPanel(relativeTo: button)
        // Key so the search field types; the app itself stays inactive
        // (.nonactivatingPanel), so no focus is stolen and none needs
        // handing back on close.
        panel.makeKeyAndOrderFront(nil)
        // Global monitors never see this app's own events (so clicks inside
        // the panel or on the status button stay ours); installed only while
        // the panel is shown to catch clicks anywhere else — other apps,
        // other status items, the desktop.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        // The click monitor cannot see keyboard-only context switches, and a
        // nonactivating panel means didResignActive never fires (the app was
        // never active) — so a Cmd+Tab would strand the panel on screen.
        // Another app becoming active is the close signal.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activated =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
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
            case "settings":
                content = AnyView(SettingsPreviewStack())
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
                    Data("[preview] --view expects popover, onboarding or settings\n".utf8))
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
