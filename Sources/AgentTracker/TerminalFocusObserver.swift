import AppKit
import ApplicationServices

/// Auto-acknowledges needs-you sessions when the user visits their terminal
/// directly (without going through the dropdown): once a known terminal app is
/// frontmost and one window title stays focused for a few seconds, the session
/// that title unambiguously identifies is acknowledged — the user has seen it.
///
/// Deliberately conservative: only an exact (normalized) title match with a
/// single winner acknowledges. Substring hits and ties do nothing — wrongly
/// silencing a red session is worse than leaving it red.
@MainActor
final class TerminalFocusObserver {
    /// How long one window must stay focused before it counts as "visited".
    static let dwell: TimeInterval = 3

    private weak var store: SessionStore?
    private var pollTimer: Timer?
    private var frontTerminalPid: pid_t?
    private var stableTitle: String?
    private var stableSince: Date?
    /// Memo of the last (title, session states) world an acknowledge attempt
    /// ran against. Attempts re-run exactly when that world changes — so a
    /// session going red WHILE the user is already dwelling on its window
    /// still fires, and a fruitless attempt (nothing red, ambiguous title)
    /// doesn't burn the title forever.
    private var lastAttemptKey: String?

    init(store: SessionStore) {
        self.store = store
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor in self?.appActivated(app) }
        }
        appActivated(NSWorkspace.shared.frontmostApplication)
    }

    private func appActivated(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier?.lowercased(),
            TerminalFocuser.knownTerminalBundleIDs.contains(bundleID)
        else {
            frontTerminalPid = nil
            stableTitle = nil
            stableSince = nil
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        frontTerminalPid = app.processIdentifier
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let pid = frontTerminalPid, TerminalFocuser.hasAccessibilityPermission,
            let title = Self.focusedWindowTitle(pid: pid), !title.isEmpty
        else { return }
        if title != stableTitle {
            stableTitle = title
            stableSince = Date()
            return
        }
        guard let since = stableSince, Date().timeIntervalSince(since) >= Self.dwell,
            let store
        else { return }
        let sessions = store.sessions
        let key =
            title + "|"
            + sessions.map { "\($0.id)=\($0.state.rawValue)" }.sorted().joined(separator: ",")
        guard key != lastAttemptKey else { return }
        lastAttemptKey = key
        attemptAcknowledge(windowTitle: title, sessions: sessions, store: store)
    }

    private func attemptAcknowledge(
        windowTitle: String, sessions: [AgentSession], store: SessionStore
    ) {
        // Match against ALL sessions: a running sibling whose window could
        // equally bear this title must count as a tie, not be invisible.
        let matchable = sessions.map { ($0, store.exactWindowTitle(for: $0)) }
        guard
            let winner = TerminalFocuser.unambiguousMatch(
                windowTitle: windowTitle, among: matchable),
            winner.state == .needsYou
        else { return }
        print(
            "[auto-ack] \(DebugLog.timestamp()) dwelled on \"\(windowTitle)\" — "
                + "acknowledging \(winner.provider):\(winner.projectName)")
        store.acknowledge(winner)
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                unsafeDowncast(window, to: AXUIElement.self), kAXTitleAttribute as CFString,
                &title) == .success
        else { return nil }
        return title as? String
    }
}
