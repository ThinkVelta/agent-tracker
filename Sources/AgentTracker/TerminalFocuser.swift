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
        let activityAgrees: Bool
    }

    /// The session being focused, plus the other live sessions it competes
    /// with. Every strategy needs the roster: a window that exactly names a
    /// different session is that session's, whatever else agrees.
    private struct Target {
        let session: AgentSession
        let candidates: [TitleCandidate]
        /// Every other live session's candidates, derived once per click:
        /// ownership is tested per window per rival, and deriving candidates
        /// reads that session's transcript.
        let rivalCandidates: [[TitleCandidate]]
        /// How many times this row has been clicked, so an unresolvable tie
        /// walks its candidates instead of raising the same window forever.
        let rotation: Int

        func ownedByAnother(_ windowTitle: String) -> Bool {
            WindowIdentity.ownedByAnotherSession(
                windowTitle: windowTitle, ownCandidates: candidates,
                rivalCandidates: rivalCandidates)
        }
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

    /// - Parameter roster: every live session with its exact title. Required,
    ///   not defaulted: without it the focuser cannot tell "a window in the
    ///   right directory" from "another session's window that happens to sit
    ///   in the right directory", and omitting it would silently disable that
    ///   protection. Pass all sessions — the caller's own is filtered out.
    @discardableResult
    /// - Parameter rotation: how many times this row has already been clicked.
    ///   Sibling sessions in one repo title their windows identically, so a
    ///   tie cannot be resolved — this walks the tied windows across clicks so
    ///   the user can reach the other one.
    static func focus(
        _ session: AgentSession,
        exactTitle: String? = nil,
        among roster: [(session: AgentSession, exactTitle: String?)],
        rotation: Int = 0
    ) -> Outcome {
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
        let target = Target(
            session: session, candidates: candidates,
            rivalCandidates:
                roster
                .filter { $0.session.id != session.id }
                .map { titleCandidates(for: $0.session, exactTitle: $0.exactTitle) },
            rotation: rotation)

        // Strongest identity first. An exact-only candidate is a name for
        // THIS session (statusline-sourced), so the Window menu — which sees
        // every Space — gets first refusal. Everything else is per-project at
        // best, so the structural cwd match goes ahead of it: a title tie can
        // otherwise land on a different agent's session in another project.
        let hasSessionIdentity = candidates.contains(where: \.exactOnly)
        if hasSessionIdentity,
            let outcome = pressWindowMenuItem(in: app, target: target, exactOnly: true)
        {
            return outcome
        }
        if let outcome = raiseByWorkingDirectory(in: app, target: target) {
            return outcome
        }
        if let outcome = pressWindowMenuItem(in: app, target: target) {
            return outcome
        }
        if let outcome = raiseAXWindow(in: app, target: target) {
            return outcome
        }
        log("no title matched — activating \(app.localizedName ?? "the app") only")
        app.activate()
        return .activatedAppOnly
    }

    // MARK: - Focus strategies

    /// Primary: the window whose live working directory is the session's, read
    /// from the Accessibility `AXDocument` attribute. Only sees the current
    /// Space, like every AX window query, so a miss falls through to the
    /// title-based paths rather than being treated as "no such window".
    private static func raiseByWorkingDirectory(
        in app: NSRunningApplication,
        target: Target
    ) -> Outcome? {
        let session = target.session
        let wanted = session.windowDirectories
        guard !wanted.isEmpty else { return nil }
        guard let windows = AXAccess.windows(of: app) else { return nil }

        let directories = windows.map { AXAccess.documentPath(of: $0) }
        let matched = WindowIdentity.matchingIndices(
            windowDirectories: directories, sessionDirectories: wanted)
        guard !matched.isEmpty else {
            let known = directories.compactMap { $0 }.count
            let described = wanted.map(WindowIdentity.normalize).joined(separator: " or ")
            log(
                "no window on this Space reports cwd \(described) "
                    + "(\(known)/\(windows.count) window(s) reported one) — falling back to titles")
            return nil
        }

        // A shared directory is the weakest kind of agreement: several agents
        // routinely sit in one repo. Windows that exactly name another live
        // session are hers, not this session's — dropping them is what stops
        // a Codex row raising a Claude Code window.
        let hits = matched.filter { !target.ownedByAnother(AXAccess.title(of: windows[$0]) ?? "") }
        guard !hits.isEmpty else {
            log(
                "\(matched.count) window(s) here belong to other sessions by name "
                    + "— falling back to titles, which see every Space")
            return nil
        }

        // Several windows in one directory: sibling sessions in the same repo.
        // Their titles and activity are all that is left to separate them.
        let titles = hits.map { AXAccess.title(of: windows[$0]) ?? "" }
        let chosen: Int
        if hits.count == 1 {
            chosen = hits[0]
        } else if let ranking = WindowIdentity.rankTitles(
            titles, candidates: target.candidates, state: session.state),
            let single = ranking.tied.first, ranking.tiedWithWinner == 0
        {
            chosen = hits[single]
        } else {
            // Nothing separates these windows, so skip whichever one the user
            // is already looking at — raising that one reads as a dead click,
            // and repeated clicks then cycle through the candidates.
            let focused = AXAccess.focusedWindowIndex(in: windows, of: app)
            guard let pick = WindowIdentity.chooseAmbiguous(hits: hits, focused: focused)
            else { return nil }
            log(
                "ambiguous: \(hits.count) window(s) share this session's directory "
                    + "and nothing distinguishes them — cycling past the focused one")
            chosen = pick
        }

        let windowTitle = AXAccess.title(of: windows[chosen]) ?? ""
        log("raising window \"\(windowTitle)\" by working directory (exact)")
        AXAccess.raise(windows[chosen])
        app.activate()
        return .focusedWindow(title: windowTitle)
    }

    /// Primary: the app's Window menu. Unlike the AX window list (current Space
    /// only), it enumerates every window AND tab across all Spaces, and
    /// pressing an entry performs the exact jump the user would.
    /// - Parameter exactOnly: restrict to the session's own name, ignoring the
    ///   path fallbacks that several sessions can share.
    private static func pressWindowMenuItem(
        in app: NSRunningApplication,
        target: Target,
        exactOnly: Bool = false
    ) -> Outcome? {
        let candidates = exactOnly ? target.candidates.filter(\.exactOnly) : target.candidates
        guard !candidates.isEmpty else { return nil }
        let lookup = AXAccess.windowMenuItems(of: app)
        guard case .items(let items) = lookup else {
            log(
                "\(lookup.describedFailure ?? "Window menu unavailable") — trying the AX window list"
            )
            return nil
        }
        log("\(items.count) Window-menu item(s)\(exactOnly ? " (session name only)" : ""):")
        guard
            let hit = bestTitleMatch(
                in: items, candidates: candidates, target: target, logZeroScores: false)
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
        target: Target
    ) -> Outcome? {
        guard let windows = AXAccess.windows(of: app) else {
            log(
                "AXWindows query failed — permission granted but not yet effective? "
                    + "Try restarting AgentTracker."
            )
            return nil
        }
        log("\(windows.count) window(s) visible via Accessibility (current Space only):")
        guard
            let best = bestTitleMatch(
                in: windows, candidates: target.candidates, target: target, logZeroScores: true)
        else { return nil }
        log("raising window \"\(best.title)\" (score \(best.score))")
        AXAccess.raise(best.element)
        app.activate()
        return .focusedWindow(title: best.title)
    }

    // MARK: - AX plumbing

    private static func bestTitleMatch(
        in elements: [AXUIElement],
        candidates: [TitleCandidate],
        target: Target,
        logZeroScores: Bool
    ) -> AXMatch? {
        let state = target.session.state
        // Same rule as the directory path: a window that exactly names another
        // live session is never this one's, however well its path fragments
        // score. Without this a bare "Planner" candidate can outrank nothing
        // and still win a menu full of other sessions' windows.
        let titled = elements.compactMap { element -> (element: AXUIElement, title: String)? in
            guard let title = AXAccess.title(of: element), !title.isEmpty else { return nil }
            guard !target.ownedByAnother(title) else { return nil }
            return (element, title)
        }
        for entry in titled {
            let score = matchScore(windowTitle: entry.title, candidates: candidates)
            guard score > 0 || logZeroScores else { continue }
            let agrees = activityAgrees(windowTitle: entry.title, state: state)
            log("  \"\(entry.title)\" -> score \(score)\(agrees ? "" : ", activity mismatch")")
        }
        guard
            let ranking = WindowIdentity.rankTitles(
                titled.map(\.title), candidates: candidates, state: state),
            let pick = ranking.choice(rotation: target.rotation)
        else { return nil }
        let winner = titled[pick]
        if ranking.tiedWithWinner > 0 {
            // Sibling sessions in one repo title their windows identically, so
            // the raise is a coin flip. Walk the tied set across repeated
            // clicks: raising the same window every time makes the second
            // click read as dead, and this is the only way the user can reach
            // the sibling at all. Unlike the directory path, the focused
            // window cannot be identified here — the menu offers titles only,
            // and these titles are identical by definition.
            log(
                "ambiguous: \(ranking.tiedWithWinner + 1) window(s) tie at score \(ranking.score) "
                    + "— raising \"\(winner.title)\" (attempt \(target.rotation + 1)), "
                    + "which may not be this session's window")
        }
        return AXMatch(
            element: winner.element, title: winner.title, score: ranking.score,
            activityAgrees: ranking.activityAgrees)
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
        // Both of the session's directories, not just the hook's: a worktree
        // session's terminal sits at the repo root, so a title showing the
        // root is still this session's window. Needed whenever AXDocument
        // matching is unavailable — another Space, or a terminal that doesn't
        // report a directory.
        //
        // Deliberately no second bare project name at the w40 tier: that tier
        // is the widest and most collision-prone, and adding "Planner" for a
        // worktree session would let it claim any Planner window — the exact
        // class of misfocus PR #6 fixed.
        var seen: Set<String> = []
        for directory in session.windowDirectories where seen.insert(directory).inserted {
            // Full path — some terminals title with it.
            candidates.append(TitleCandidate(directory, weight: 60))
            if let context = AgentSession.pathContext(of: directory),
                seen.insert(context).inserted
            {
                candidates.append(TitleCandidate(context, weight: 50))
            }
        }
        if session.projectName != "Session" {
            candidates.append(TitleCandidate(session.projectName, weight: 40))
        }
        return candidates
    }

    /// True when the title carries a braille spinner frame (U+2800–U+28FF) —
    /// the animation agent TUIs paint into the title while a turn is in
    /// flight. Deliberately narrow: braille frames mean "working right now" in
    /// every CLI we track, whereas Claude Code's constant "✳" prefix says
    /// nothing about activity. `normalize` strips these before scoring, so the
    /// signal has to be read from the raw title.
    static func showsBusySpinner(_ windowTitle: String) -> Bool {
        windowTitle.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
    }

    /// Whether the window's live busy indicator agrees with the session's
    /// state. Used only to break ties between equally-titled windows: two
    /// Codex sessions in one repo both title their window "Planner", and the
    /// spinner is the only thing separating the one still working from the one
    /// waiting at its prompt (user-reported: clicking a needs-you row raised
    /// the sibling that was still running).
    ///
    /// Deliberately provider-agnostic. Review suggested gating this to Codex,
    /// but both tracked CLIs paint braille frames while a turn is in flight —
    /// verified against live windows, e.g. a running `claude-code` session
    /// titled "⠂ Generate alternative LinkedIn post options". Gating it would
    /// disable a working signal for the more common provider. Add a gate only
    /// for a provider actually observed not to spin.
    static func activityAgrees(windowTitle: String, state: SessionState) -> Bool {
        showsBusySpinner(windowTitle) == (state == .running)
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

    /// Internal, not private: the ownership predicates in SessionOwnership
    /// score titles with the same stripping rules.
    static func normalize(_ text: String) -> String {
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
        DebugLog.log("[focus] \(message)")
    }
}
