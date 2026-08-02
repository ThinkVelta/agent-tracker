import Foundation

/// Structural identity for terminal windows.
///
/// Window titles are not identities. Claude Code titles its window with a task
/// summary, Codex with a bare project name, and plain shells with a path — so
/// several sessions in one repo produce several identical titles, and matching
/// on them is a coin flip between unrelated agents. macOS terminals expose the
/// window's live working directory through the Accessibility `AXDocument`
/// attribute, which is a fact rather than a label: comparing it to a session's
/// cwd rules out every window belonging to a different project outright.
///
/// It is not a complete identity — two sessions in one directory still share
/// one answer — so it narrows the field and the title/activity ranking picks
/// within it. Where even that ties, `FocusRotation` spreads the sessions over
/// the candidates so two rows at least reach two terminals.
///
/// ## Why there is nothing better to match on
///
/// A real identity would be `session pid → tty → window`. The first half is
/// trivial (`ps -o tty= -p <pid>`); the second has no implementation on the
/// terminal this was built against. Measured against Ghostty 1.3.1 and Codex
/// CLI on 2026-08-01/02, so it does not get re-derived:
///
/// - **No per-surface Accessibility data.** A window exposes `AXDocument` (the
///   cwd, which is what this type uses) and `AXIdentifier`, which is the string
///   `TerminalWindowRestoration` on *every* window. Children are generic
///   `AXGroup`/`AXScrollArea`. Nothing tty-, pid- or session-shaped at any
///   depth.
/// - **No per-surface environment variable.** A shell inside Ghostty gets
///   `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_SHELL_FEATURES`, `TERM_PROGRAM`,
///   `TERM_PROGRAM_VERSION`, `TERMINFO` — nothing unique. iTerm2 has
///   `ITERM_SESSION_ID`; Ghostty has no equivalent.
/// - **No process ancestry to walk.** Ghostty is a single process; every
///   surface's `/usr/bin/login` parents straight to it.
/// - **We cannot write an identity either.** The obvious workaround is to have
///   the hook emit an OSC 2 title naming the session. Codex repaints its own
///   title every animation frame — two reads a second apart returned
///   `⠋ Planner` then `⠙ Planner` — so anything written is overwritten
///   immediately.
/// - **`agent_nickname` in Codex rollouts is a subagent field**, not a session
///   name: every rollout carrying one also carries `parent_thread_id` and a
///   `session_id` pointing at the parent.
///
/// Ghostty *is* AppleScript-scriptable and its dictionary is richer than its AX
/// tree — `window`/`tab`/`terminal` with a stable per-surface `id`, plus
/// `focus`. It enumerates every Space, which the AX window list cannot, so it
/// would be a better *enumeration* backend. It still carries no tty or pid, so
/// it would not resolve a tie; and it costs a second TCC prompt.
enum WindowIdentity {
    /// Extracts a filesystem path from an `AXDocument` value, which terminals
    /// report as a `file://` URL. Returns nil for anything that isn't a local
    /// path (some apps report a document name, or nothing at all).
    static func directory(fromDocumentAttribute value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let path: String
        if value.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            path = url.path
        } else if value.hasPrefix("/") {
            path = value
        } else {
            return nil
        }
        return normalize(path)
    }

    /// Trailing separators and `/private` prefixes vary by reporter; compare
    /// the normalized forms so equal directories test equal.
    static func normalize(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        // macOS reports /tmp and /var under their real /private root in some
        // APIs and not others.
        if normalized.hasPrefix("/private/") {
            normalized = String(normalized.dropFirst("/private".count))
        }
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Whether a window's reported directory is the session's own. Unknown
    /// directories never match: absence of evidence must not raise a window.
    static func matches(windowDirectory: String?, sessionCwd: String?) -> Bool {
        guard let windowDirectory, let sessionCwd, !sessionCwd.isEmpty else { return false }
        return windowDirectory == normalize(sessionCwd)
    }

    /// Indices of the windows whose directory is the session's, in input order.
    static func matchingIndices(windowDirectories: [String?], sessionCwd: String?) -> [Int] {
        matchingIndices(
            windowDirectories: windowDirectories, sessionDirectories: [sessionCwd].compactMap { $0 }
        )
    }

    /// A session can legitimately answer to more than one directory: the hook
    /// records where the agent works, the registry where its terminal sits, and
    /// for a worktree session those differ. Matching any of them is correct —
    /// they all belong to the same session.
    static func matchingIndices(
        windowDirectories: [String?],
        sessionDirectories: [String]
    ) -> [Int] {
        let wanted = Set(sessionDirectories.filter { !$0.isEmpty }.map(normalize))
        guard !wanted.isEmpty else { return [] }
        return windowDirectories.enumerated()
            .filter { entry in
                guard let directory = entry.element else { return false }
                return wanted.contains(directory)
            }
            .map(\.offset)
    }

    /// Whether this window is demonstrably a *different* session's.
    ///
    /// Sharing a directory is not owning a window: six terminals sat in one
    /// repo, three of them Claude Code, and clicking a Codex row raised the
    /// Claude window whose directory happened to match — the reported
    /// "brought to a completely different terminal, not even the same AI
    /// agent". A window whose title exactly names another live session is
    /// that session's, and no directory agreement outranks that.
    ///
    /// Only an exact title match counts as ownership, and only when this
    /// session cannot claim the title too: siblings in one repo all answer to
    /// "Planner", and treating that as somebody else's would rule out every
    /// candidate. Those stay ambiguous, which the ranking already handles.
    /// Takes prebuilt candidates rather than sessions: this runs once per
    /// window per rival session on the click path, and deriving candidates
    /// reads the session's transcript from disk. Callers build each side once.
    static func ownedByAnotherSession(
        windowTitle: String,
        ownCandidates: [TerminalFocuser.TitleCandidate],
        rivalCandidates: [[TerminalFocuser.TitleCandidate]]
    ) -> Bool {
        guard !claims(windowTitle, ownCandidates) else { return false }
        return rivalCandidates.contains { claims(windowTitle, $0) }
    }

    private static func claims(
        _ windowTitle: String, _ candidates: [TerminalFocuser.TitleCandidate]
    ) -> Bool {
        TerminalFocuser.exactScore(windowTitle: windowTitle, candidates: candidates) > 0
    }

    /// Picks among windows that match equally well. Raising the window the
    /// user is already looking at does nothing visible — it reads as "the app
    /// ignored my click" — so when the focused window is one of the
    /// candidates, step past it. Repeated clicks then cycle through the
    /// candidates, which is the only sane behaviour when nothing can tell
    /// them apart. Pure so the wrap-around is testable.
    /// - Parameter offset: which candidate this session starts from — its rank
    ///   among the siblings it cannot be told apart from, plus how many times
    ///   its row has been clicked. Without the rank every sibling row starts at
    ///   0 and they all raise the same window, which is exactly what shipped
    ///   and did not work.
    static func chooseAmbiguous(hits: [Int], focused: Int?, offset: Int) -> Int? {
        let count = hits.count
        guard count > 0 else { return nil }
        let start = ((offset % count) + count) % count
        let pick = hits[start]
        guard let focused, pick == focused, count > 1 else { return pick }
        return hits[(start + 1) % count]
    }

    /// The sessions competing with this one for the same terminal windows.
    ///
    /// Competition runs over `windowDirectories`, the same basis window
    /// matching uses — not the single directory a row is titled with. A
    /// worktree session's terminal sits at the repo root, so it answers to both
    /// paths and can take a window a root session also wants, even though the
    /// two are titled differently.
    ///
    /// Transitively: sharing a directory is not an equivalence relation on its
    /// own, and if A meets B on the repo root while B meets C in a worktree,
    /// the three would compute three different groups and hand out ranks that
    /// no longer agree — the exact collision this ranking exists to prevent.
    /// Closing over reachable directories gives every member of a group the
    /// same group, so the ranks partition.
    static func competingGroup(
        for sessionId: String,
        among sessions: [(id: String, directories: [String])]
    ) -> [String] {
        let normalized = sessions.map { entry in
            (id: entry.id, dirs: Set(entry.directories.filter { !$0.isEmpty }.map(normalize)))
        }
        guard let start = normalized.first(where: { $0.id == sessionId }), !start.dirs.isEmpty
        else { return [sessionId] }

        var reachable = start.dirs
        var group: Set<String> = [sessionId]
        var grew = true
        while grew {
            grew = false
            for entry in normalized where !group.contains(entry.id) {
                guard !entry.dirs.isDisjoint(with: reachable) else { continue }
                group.insert(entry.id)
                reachable.formUnion(entry.dirs)
                grew = true
            }
        }
        return group.sorted()
    }

    /// Which of several indistinguishable sessions this one is, and how often
    /// its row has been clicked.
    ///
    /// Sibling sessions in one repo cannot be told apart, so the best the app
    /// can do is spread them: give each a different starting candidate, then
    /// let repeated clicks walk the alternatives. `clicks` alone is not enough
    /// — every row's first click is 0, so two rows would raise the same window,
    /// which is what the first attempt at this shipped.
    ///
    /// `siblingCount` also says how many windows a strategy must be able to see
    /// before it may answer: finding one window on the current Space when two
    /// sessions want one each cannot be right for both.
    struct FocusRotation: Equatable {
        let rank: Int
        let clicks: Int
        let siblingCount: Int

        var offset: Int { rank &+ clicks }

        /// A session with nobody to be confused with.
        static let alone = FocusRotation(rank: 0, clicks: 0, siblingCount: 1)

        /// - Parameter indistinguishable: the ids of every session competing
        ///   for the same windows as this one — same directory, and no name of
        ///   its own. Ranks are assigned in sorted id order so they hold still
        ///   across reloads; a rank that moved would send the same row
        ///   somewhere new on every refresh.
        ///
        ///   Sessions that *do* have a name must be left out even when they
        ///   share the directory. They match their window exactly through an
        ///   earlier strategy and never enter the tie, so counting them would
        ///   spread the rest over slots that do not exist — with one named and
        ///   two unnamed sessions, ranks 0 and 2 both land on candidate 0 of 2.
        static func among(
            _ indistinguishable: [String], sessionId: String, clicks: Int
        ) -> FocusRotation {
            let ranked = indistinguishable.sorted()
            guard let rank = ranked.firstIndex(of: sessionId) else {
                return FocusRotation(rank: 0, clicks: clicks, siblingCount: 1)
            }
            return FocusRotation(rank: rank, clicks: clicks, siblingCount: ranked.count)
        }
    }

    struct TitleRanking: Equatable {
        /// Every title indistinguishable from the winner (same score, same
        /// activity agreement), in input order — a raise could equally have
        /// landed on any of them. Never empty. Kept as indices rather than a
        /// count so a caller can walk them across repeated clicks instead of
        /// raising the same one forever.
        let tied: [Int]
        let score: Int
        let activityAgrees: Bool

        var tiedWithWinner: Int { tied.count - 1 }

        /// The candidate for the `rotation`-th attempt at this session,
        /// wrapping. Total over every `Int`: `rotation` comes from a caller,
        /// and `abs` traps on `Int.min`.
        func choice(rotation: Int) -> Int? {
            guard !tied.isEmpty else { return nil }
            let count = tied.count
            return tied[((rotation % count) + count) % count]
        }
    }

    /// Picks the window title a session should jump to, in menu order. Highest
    /// title score wins; equal scores are broken by whether the window's busy
    /// spinner agrees with the session's state. Pure, so the ranking (not just
    /// the scoring) is testable. Internal for tests.
    static func rankTitles(
        _ titles: [String],
        candidates: [TerminalFocuser.TitleCandidate],
        state: SessionState
    ) -> TitleRanking? {
        var best: TitleRanking?
        for (index, title) in titles.enumerated() {
            let score = TerminalFocuser.matchScore(windowTitle: title, candidates: candidates)
            guard score > 0 else { continue }
            let agrees = TerminalFocuser.activityAgrees(windowTitle: title, state: state)
            guard let current = best else {
                best = TitleRanking(tied: [index], score: score, activityAgrees: agrees)
                continue
            }
            if (score, agrees ? 1 : 0) > (current.score, current.activityAgrees ? 1 : 0) {
                best = TitleRanking(tied: [index], score: score, activityAgrees: agrees)
            } else if score == current.score && agrees == current.activityAgrees {
                best = TitleRanking(
                    tied: current.tied + [index], score: current.score,
                    activityAgrees: current.activityAgrees)
            }
        }
        return best
    }
}
