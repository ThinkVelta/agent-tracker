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

    /// Whether the raised window could be this session's: it scores, and it is
    /// not a window that exactly names somebody else.
    ///
    /// This gates the row-click acknowledge, and is deliberately softer than
    /// `unambiguousMatch`. The bar used to be "strictly better than every
    /// sibling", which two sessions in one repo can never clear — their title
    /// candidates are byte-identical, so each scores exactly what the other
    /// does. Those rows could then never be cleared by clicking them, which is
    /// the reported "clicking a Codex needs-you row doesn't make it idle".
    ///
    /// The user chose the row and was taken to a window that could be its own;
    /// that is enough to call it seen. Passive acknowledgement
    /// (`TerminalFocusObserver`) keeps the strict bar, because there nobody
    /// chose anything and a wrong guess silences a session unprompted.
    /// Decorated titles ("… — zsh — 80x24") still clear the red state.
    static func isPlausibleMatch(
        windowTitle: String,
        for session: AgentSession,
        exactTitle: String?,
        among sessions: [(session: AgentSession, exactTitle: String?)]
    ) -> Bool {
        let own = titleCandidates(for: session, exactTitle: exactTitle)
        guard matchScore(windowTitle: windowTitle, candidates: own) > 0 else { return false }
        return !WindowIdentity.ownedByAnotherSession(
            windowTitle: windowTitle,
            ownCandidates: own,
            rivalCandidates:
                sessions
                .filter { $0.session.id != session.id }
                .map { titleCandidates(for: $0.session, exactTitle: $0.exactTitle) })
    }
}
