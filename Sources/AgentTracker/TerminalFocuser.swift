import AppKit
import ApplicationServices

/// Jumps to the terminal window a session lives in.
///
/// Strategy: verify Accessibility permission, then find the window whose title
/// best matches the session (Claude Code sets window titles to "✳ <task
/// summary>"; plain shells and the Codex TUI show the working directory or
/// project name) and raise it. Raising a window on another Space makes macOS
/// switch to it.
///
/// Every attempt prints a `[focus]` trace to stdout — visible in the terminal
/// running `swift run AgentTracker` — so misbehavior is diagnosable from a
/// single paste.
enum TerminalFocuser {
    enum Outcome {
        /// Raised a specific matching window.
        case focusedWindow(title: String)
        /// No window title matched; brought the terminal app forward instead.
        case activatedAppOnly
        /// No known terminal app is running.
        case noTerminalFound
        /// Accessibility permission missing — the system prompt was triggered.
        case needsPermission
    }

    private struct AXMatch {
        let element: AXUIElement
        let title: String
        let score: Int
    }

    /// A window-title probe derived from a session, ordered by weight.
    struct TitleCandidate {
        let text: String
        let weight: Int
        /// Exact-title candidates must match the whole (normalized) window
        /// title: a substring hit would confidently raise a sibling session
        /// whose name shares a prefix (e.g. "api refactor" matching the
        /// "api refactor tests" window) — the exact bug this candidate exists
        /// to prevent. Path/summary fallbacks keep substring matching.
        let exactOnly: Bool

        init(_ text: String, weight: Int, exactOnly: Bool = false) {
            self.text = text
            self.weight = weight
            self.exactOnly = exactOnly
        }
    }

    private static let bundleIdentifiers: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "wezterm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
    ]

    /// Lowercased bundle ids of every terminal app the focuser knows, for
    /// "is the frontmost app a terminal?" checks (TerminalFocusObserver).
    static let knownTerminalBundleIDs: Set<String> = Set(
        bundleIdentifiers.values.map { $0.lowercased() })

    /// True when the process can drive the Accessibility API. Does not prompt.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func focus(_ session: AgentSession, exactTitle: String? = nil) -> Outcome {
        log(
            "focusing \(session.providerDisplayName) session \(session.sessionId) "
                + "(cwd: \(session.cwd ?? "?"))"
        )

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            log(
                "no Accessibility permission — system prompt triggered. NOTE: when run "
                    + "via `swift run` from a terminal, macOS attributes the permission to "
                    + "that terminal (the responsible process). After granting, QUIT AND "
                    + "RE-RUN AgentTracker for it to take effect."
            )
            return .needsPermission
        }

        guard let app = terminalApp(for: session) else {
            let known = bundleIdentifiers.values.sorted().joined(separator: ", ")
            log("no known terminal app is running (looked for: \(known))")
            return .noTerminalFound
        }
        log(
            "terminal app: \(app.localizedName ?? "?") "
                + "(\(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier))"
        )

        let candidates = titleCandidates(for: session, exactTitle: exactTitle)
        let described = candidates.map {
            "\"\($0.text)\" (w\($0.weight)\($0.exactOnly ? ", exact" : ""))"
        }
        log("title candidates: \(described.joined(separator: ", "))")

        if let outcome = pressWindowMenuItem(in: app, candidates: candidates) {
            return outcome
        }
        if let outcome = raiseAXWindow(in: app, candidates: candidates) {
            return outcome
        }
        log("no title matched — activating \(app.localizedName ?? "the app") only")
        app.activate()
        return .activatedAppOnly
    }

    // MARK: - Focus strategies

    /// Primary: the app's Window menu. Unlike the AX window list (current Space
    /// only), it enumerates every window AND tab across all Spaces, and
    /// pressing an entry performs the exact jump the user would.
    private static func pressWindowMenuItem(
        in app: NSRunningApplication,
        candidates: [TitleCandidate]
    ) -> Outcome? {
        guard let menu = windowMenu(of: app), let items = children(of: menu) else { return nil }
        log("\(items.count) Window-menu item(s):")
        guard let hit = bestTitleMatch(in: items, candidates: candidates, logZeroScores: false)
        else { return nil }
        log("pressing Window-menu item \"\(hit.title)\" (score \(hit.score))")
        let result = AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
        app.activate()
        guard result == .success else {
            log("menu press failed (\(result.rawValue)) — falling back to AX window raise")
            return nil
        }
        return .focusedWindow(title: hit.title)
    }

    /// Fallback: raise a matching window from the AX window list (only sees the
    /// current Space).
    private static func raiseAXWindow(
        in app: NSRunningApplication,
        candidates: [TitleCandidate]
    ) -> Outcome? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = copyAttribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]
        else {
            log(
                "AXWindows query failed — permission granted but not yet effective? "
                    + "Try restarting AgentTracker."
            )
            return nil
        }
        log("\(windows.count) window(s) visible via Accessibility (current Space only):")
        guard let best = bestTitleMatch(in: windows, candidates: candidates, logZeroScores: true)
        else { return nil }
        log("raising window \"\(best.title)\" (score \(best.score))")
        AXUIElementPerformAction(best.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(best.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
        return .focusedWindow(title: best.title)
    }

    // MARK: - AX plumbing

    /// Finds the app's "Window" menu. Matching the English title is a
    /// documented limitation; localized menu bars fall back to the AX window
    /// list.
    private static func windowMenu(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = axElement(copyAttribute(axApp, kAXMenuBarAttribute as String)) else {
            log("no AX menu bar exposed")
            return nil
        }
        guard let topItems = children(of: menuBar) else { return nil }
        guard let windowItem = topItems.first(where: { title(of: $0) == "Window" }) else {
            log("no menu titled \"Window\" found")
            return nil
        }
        return children(of: windowItem)?.first
    }

    private static func bestTitleMatch(
        in elements: [AXUIElement],
        candidates: [TitleCandidate],
        logZeroScores: Bool
    ) -> AXMatch? {
        var best: AXMatch?
        for element in elements {
            guard let title = title(of: element), !title.isEmpty else { continue }
            let score = matchScore(windowTitle: title, candidates: candidates)
            if score > 0 || logZeroScores { log("  \"\(title)\" -> score \(score)") }
            if score > (best?.score ?? 0) {
                best = AXMatch(element: element, title: title, score: score)
            }
        }
        return best
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    }

    private static func title(of element: AXUIElement) -> String? {
        copyAttribute(element, kAXTitleAttribute as String) as? String
    }

    // MARK: - Matching

    private static func terminalApp(for session: AgentSession) -> NSRunningApplication? {
        if let termProgram = session.termProgram?.lowercased(),
            let bundleID = bundleIdentifiers[termProgram],
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        {
            return app
        }
        for bundleID in bundleIdentifiers.values.sorted() {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first
            {
                return app
            }
        }
        return nil
    }

    /// Ordered by reliability: the live window title (statusline-sourced) is
    /// exact per session, the Claude task summary near-unique, and path
    /// fragments can collide across sessions in the same repo. Internal for
    /// tests.
    static func titleCandidates(
        for session: AgentSession, exactTitle: String? = nil
    ) -> [TitleCandidate] {
        var candidates: [TitleCandidate] = []
        if let exactTitle, !exactTitle.isEmpty {
            candidates.append(TitleCandidate(exactTitle, weight: 150, exactOnly: true))
        }
        if let summary = TranscriptTitle.latestSummary(atPath: session.transcriptPath) {
            candidates.append(TitleCandidate(summary, weight: 100))
        }
        if let cwd = session.cwd {
            // Full path — some terminals title with it.
            candidates.append(TitleCandidate(cwd, weight: 60))
        }
        if let context = session.pathContext {
            candidates.append(TitleCandidate(context, weight: 50))
        }
        if session.projectName != "Session" {
            candidates.append(TitleCandidate(session.projectName, weight: 40))
        }
        return candidates
    }

    /// Scores only the exact-equality tier: nonzero only when the normalized
    /// window title equals one of the candidates outright. This is the
    /// confidence bar for state-changing actions (acknowledging a session) —
    /// substring hits are good enough to *raise* a window, not to silence one.
    static func exactScore(windowTitle: String, candidates: [TitleCandidate]) -> Int {
        let title = normalize(windowTitle)
        guard !title.isEmpty else { return 0 }
        var score = 0
        for candidate in candidates {
            let text = normalize(candidate.text)
            guard !text.isEmpty, title == text else { continue }
            score = max(score, candidate.weight * 2)
        }
        return score
    }

    /// The single session the window title identifies beyond doubt: exactly
    /// one session may exact-match, no matter through which candidate or at
    /// what weight — a second exact match means two windows could plausibly
    /// bear this title, and weight cannot tell WHICH physical window the user
    /// is looking at. Ties return nil — never guess. Callers should pass ALL
    /// sessions (not just needs-you ones) so invisible siblings count as ties.
    static func unambiguousMatch(
        windowTitle: String,
        among sessions: [(session: AgentSession, exactTitle: String?)]
    ) -> AgentSession? {
        let matches = sessions.filter { entry in
            exactScore(
                windowTitle: windowTitle,
                candidates: titleCandidates(for: entry.session, exactTitle: entry.exactTitle)
            ) > 0
        }
        guard matches.count == 1, let winner = matches.first else { return nil }
        return winner.session
    }

    /// Whether the raised window belongs to `session` more than to any other
    /// session: a positive match score, strictly ahead of every sibling's.
    /// Softer than `unambiguousMatch` (substring tiers count) — used to gate
    /// the row-click acknowledge, where the user already chose the session and
    /// the only question is whether the raise landed on a plausible window;
    /// decorated titles ("… — zsh — 80x24") must still clear the red state.
    static func isPreferredMatch(
        windowTitle: String,
        for session: AgentSession,
        exactTitle: String?,
        among sessions: [(session: AgentSession, exactTitle: String?)]
    ) -> Bool {
        let own = matchScore(
            windowTitle: windowTitle,
            candidates: titleCandidates(for: session, exactTitle: exactTitle)
        )
        guard own > 0 else { return false }
        for entry in sessions where entry.session.id != session.id {
            let other = matchScore(
                windowTitle: windowTitle,
                candidates: titleCandidates(for: entry.session, exactTitle: entry.exactTitle)
            )
            if other >= own { return false }
        }
        return true
    }

    /// Internal for tests.
    static func matchScore(
        windowTitle: String,
        candidates: [TitleCandidate]
    ) -> Int {
        let title = normalize(windowTitle)
        guard !title.isEmpty else { return 0 }
        var score = 0
        for candidate in candidates {
            let text = normalize(candidate.text)
            guard !text.isEmpty else { continue }
            if title == text {
                score = max(score, candidate.weight * 2)
            } else if !candidate.exactOnly, title.contains(text) || text.contains(title) {
                score = max(score, candidate.weight)
            }
        }
        return score
    }

    private static func normalize(_ text: String) -> String {
        // Strip leading status glyphs — ✳, braille spinner frames (⠂⠐…),
        // bullets, ellipsis — that terminals/CLIs prefix onto titles.
        var stripped = Substring(text.lowercased())
        while let first = stripped.first,
            !(first.isLetter || first.isNumber || first == "/" || first == "~" || first == ".")
        {
            stripped = stripped.dropFirst()
        }
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    static func openAccessibilitySettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func log(_ message: String) {
        print("[focus] \(message)")
    }
}
