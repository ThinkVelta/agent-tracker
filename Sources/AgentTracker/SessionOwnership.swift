import Foundation

/// Which session a window title belongs to.
///
/// Separate from the raising strategies in `TerminalFocuser`: these are pure
/// comparisons over the whole roster of live sessions, and they gate the two
/// places where guessing wrong is expensive — silencing a red session the user
/// never saw, and raising a window that is somebody else's.
extension TerminalFocuser {
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
}
