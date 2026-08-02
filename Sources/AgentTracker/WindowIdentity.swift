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
/// within it.
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
    static func chooseAmbiguous(hits: [Int], focused: Int?) -> Int? {
        guard let first = hits.first else { return nil }
        guard let focused, let position = hits.firstIndex(of: focused) else { return first }
        return hits[(position + 1) % hits.count]
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

        /// The candidate for the `rotation`-th attempt at this session, wrapping.
        func choice(rotation: Int) -> Int? {
            guard !tied.isEmpty else { return nil }
            return tied[abs(rotation) % tied.count]
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
