import Foundation
import Testing

@testable import AgentTracker

final class TerminalFocuserTests {
    private func claudeSession(id: String, cwd: String) -> AgentSession {
        AgentSession(provider: "claude-code", sessionId: id, cwd: cwd, state: .needsYou)
    }

    // MARK: - Which terminal owns a session

    @Test func termProgramNamesMostTerminals() {
        #expect(
            TerminalIdentification.hint(termProgram: "ghostty", term: "xterm-ghostty")
                == .app("com.mitchellh.ghostty"))
        #expect(
            TerminalIdentification.hint(termProgram: "iTerm.app", term: nil)
                == .app("com.googlecode.iterm2"))
        #expect(
            TerminalIdentification.hint(termProgram: "Apple_Terminal", term: nil)
                == .app("com.apple.Terminal"))
        #expect(
            TerminalIdentification.hint(termProgram: "WezTerm", term: nil)
                == .app("com.github.wez.wezterm"))
    }

    /// kitty sets no `TERM_PROGRAM` whatsoever, so the entry that used to sit in
    /// the `TERM_PROGRAM` table could never be reached. `TERM` is the only thing
    /// that names it.
    @Test func kittyIsFoundThroughTermBecauseItSetsNoTermProgram() {
        #expect(
            TerminalIdentification.hint(termProgram: nil, term: "xterm-kitty")
                == .app("net.kovidgoyal.kitty"))
        // And it stays reachable when something else has claimed TERM_PROGRAM.
        #expect(
            TerminalIdentification.hint(termProgram: "", term: "xterm-kitty")
                == .app("net.kovidgoyal.kitty"))
    }

    /// tmux overwrites `TERM_PROGRAM` with its own name, so the host terminal is
    /// not recoverable from the environment. Saying so beats reading the
    /// overwritten value as if it named an app.
    @Test func aMultiplexerIsReportedRatherThanGuessedAt() {
        #expect(
            TerminalIdentification.hint(termProgram: "tmux", term: "screen-256color")
                == .multiplexer)
        #expect(TerminalIdentification.hint(termProgram: "screen", term: nil) == .multiplexer)
        // Even with the host's own value still in TERM, tmux wins: it is the
        // layer the window actually belongs to.
        #expect(
            TerminalIdentification.hint(termProgram: "tmux", term: "xterm-ghostty") == .multiplexer)
        // And TERM alone is enough when TERM_PROGRAM never survived.
        #expect(
            TerminalIdentification.hint(termProgram: nil, term: "tmux-256color") == .multiplexer)
    }

    @Test func anUnrecognizedTerminalIsUnknownRatherThanAGuess() {
        #expect(TerminalIdentification.hint(termProgram: nil, term: nil) == .unknown)
        #expect(TerminalIdentification.hint(termProgram: "WarpTerminal", term: nil) == .unknown)
        #expect(
            TerminalIdentification.hint(termProgram: "vscode", term: "xterm-256color") == .unknown)
    }

    /// The process walk is what makes the environment a fallback rather than the
    /// only source. This checks the `sysctl` plumbing it rides on, against a
    /// parent the test already knows.
    @Test func parentPidReadsTheRealProcessTree() {
        #expect(TerminalIdentification.parentPid(of: getpid()) == getppid())
        // pid 1 is its own root; nothing above it to report.
        #expect(TerminalIdentification.parentPid(of: 1) == nil)
        // A pid that cannot exist yields nothing rather than a wrong answer.
        #expect(TerminalIdentification.parentPid(of: -1) == nil)
    }

    @Test func exactTitleLeadsCandidatesAtTopWeight() {
        let session = claudeSession(id: "s1", cwd: "/Users/dev/planner")
        let candidates = TerminalFocuser.titleCandidates(
            for: session, exactTitle: "Fix the flaky scanner test")
        #expect(candidates.first?.text == "Fix the flaky scanner test")
        #expect(candidates.first?.weight == 150)
        #expect(candidates.first?.exactOnly == true)
        // Every fallback stays behind it and keeps substring matching.
        #expect(candidates.dropFirst().allSatisfy { $0.weight < 150 && !$0.exactOnly })
    }

    @Test func candidatesWithoutExactTitleKeepPathFallbacks() {
        let session = claudeSession(id: "s1", cwd: "/Users/dev/planner")
        let candidates = TerminalFocuser.titleCandidates(for: session, exactTitle: nil)
        #expect(candidates.map(\.text) == ["/Users/dev/planner", "dev/planner", "planner"])
        #expect(candidates.map(\.weight) == [60, 50, 40])
    }

    @Test func exactMatchOutscoresGlyphPrefixAndDoublesWeight() {
        let candidates = [
            TerminalFocuser.TitleCandidate(
                "Verify Planner secret redaction payload field", weight: 150, exactOnly: true)
        ]
        let exact = TerminalFocuser.matchScore(
            windowTitle: "⠐ Verify Planner secret redaction payload field",
            candidates: candidates
        )
        #expect(exact == 300)
        let unrelated = TerminalFocuser.matchScore(
            windowTitle: "✳ Port planner tooling", candidates: candidates)
        #expect(unrelated == 0)
    }

    @Test func exactOnlyCandidateNeverMatchesBySubstring() {
        // Regression: sessions "api refactor" and "api refactor tests" share a
        // prefix; a substring hit would confidently raise the sibling's
        // window. The exact-title candidate must score all-or-nothing.
        let candidates = [
            TerminalFocuser.TitleCandidate("api refactor", weight: 150, exactOnly: true)
        ]
        #expect(
            TerminalFocuser.matchScore(windowTitle: "⠐ api refactor tests", candidates: candidates)
                == 0)
        #expect(
            TerminalFocuser.matchScore(windowTitle: "⠐ api refactor", candidates: candidates)
                == 300)
        // Fallback candidates keep substring behavior.
        let fallback = [TerminalFocuser.TitleCandidate("planner", weight: 40)]
        #expect(
            TerminalFocuser.matchScore(windowTitle: "dev/planner — zsh", candidates: fallback)
                == 40)
    }

    // MARK: - Auto-acknowledge matching (exact tier, unambiguous winner only)

    @Test func exactScoreIgnoresSubstringHits() {
        let candidates = [
            TerminalFocuser.TitleCandidate("api refactor", weight: 150, exactOnly: true),
            TerminalFocuser.TitleCandidate("/Users/dev/planner", weight: 60),
        ]
        #expect(
            TerminalFocuser.exactScore(windowTitle: "⠐ api refactor", candidates: candidates)
                == 300)
        // Substring-only relationships score zero — not confident enough to
        // change session state.
        #expect(
            TerminalFocuser.exactScore(
                windowTitle: "⠐ api refactor tests", candidates: candidates) == 0)
        #expect(
            TerminalFocuser.exactScore(
                windowTitle: "dev/planner — zsh", candidates: candidates) == 0)
    }

    @Test func unambiguousMatchPicksTheSingleExactWinner() {
        let sessionA = claudeSession(id: "a", cwd: "/Users/dev/planner")
        let sessionB = claudeSession(id: "b", cwd: "/Users/dev/planner")
        let winner = TerminalFocuser.unambiguousMatch(
            windowTitle: "⠐ Fix the flaky scanner test",
            among: [
                (sessionA, "Fix the flaky scanner test"),
                (sessionB, "Port planner tooling"),
            ]
        )
        #expect(winner?.sessionId == "a")
    }

    @Test func unambiguousMatchRefusesTiesAndFuzz() {
        // Two same-directory sessions without distinct titles: the bare
        // project-name window ties (both exact-match "planner" at equal
        // weight) — never guess.
        let sessionA = claudeSession(id: "a", cwd: "/Users/dev/planner")
        let sessionB = claudeSession(id: "b", cwd: "/Users/dev/planner")
        let tied = TerminalFocuser.unambiguousMatch(
            windowTitle: "planner", among: [(sessionA, nil), (sessionB, nil)])
        #expect(tied == nil)

        // A title that only substring-relates to a session must not match.
        let fuzzy = TerminalFocuser.unambiguousMatch(
            windowTitle: "planner — zsh — 80x24", among: [(sessionA, nil)])
        #expect(fuzzy == nil)

        // No sessions at all.
        #expect(TerminalFocuser.unambiguousMatch(windowTitle: "planner", among: []) == nil)
    }

    @Test func unambiguousMatchTreatsDifferentWeightExactMatchesAsTie() {
        // One session exact-matches "planner" via its statusline title (x300),
        // the other via its project name (x80). Both windows could bear this
        // title — weight cannot tell which physical window the user sees.
        let named = claudeSession(id: "named", cwd: "/Users/dev/other")
        let bare = claudeSession(id: "bare", cwd: "/Users/dev/planner")
        let winner = TerminalFocuser.unambiguousMatch(
            windowTitle: "planner", among: [(named, "planner"), (bare, nil)])
        #expect(winner == nil)
    }

    @Test func plausibleMatchAcceptsDecoratedTitlesAndRefusesUnrelatedOnes() {
        // Decorated title (Terminal.app style): substring match, no exact.
        let backend = claudeSession(id: "b", cwd: "/Users/dev/planner/planner-backend")
        let worktree = claudeSession(
            id: "w", cwd: "/Users/dev/planner/planner-backend/.claude/worktrees/pln-1-abc")
        let all = [(backend, String?.none), (worktree, String?.none)]
        #expect(
            TerminalFocuser.isPlausibleMatch(
                windowTitle: "planner-backend — zsh — 80x24", for: backend, exactTitle: nil,
                among: all))

        // Unrelated window: no score at all.
        #expect(
            !TerminalFocuser.isPlausibleMatch(
                windowTitle: "totally-unrelated", for: backend, exactTitle: nil, among: all))
    }

    /// The reported bug: clicking a Codex needs-you row left it red. Two Codex
    /// sessions in one repo have byte-identical candidates, so neither can
    /// ever score strictly better than the other — the old "preferred match"
    /// bar was unsatisfiable and those rows could only be cleared by hand.
    /// Landing on a window that could be this session's is enough.
    @Test func siblingSessionsInOneRepoCanStillBeAcknowledgedByClicking() {
        let first = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let second = AgentSession(
            provider: "codex", sessionId: "c2", cwd: "/Users/dev/Planner", state: .needsYou)
        let all = [(first, String?.none), (second, String?.none)]
        #expect(
            TerminalFocuser.isPlausibleMatch(
                windowTitle: "⠸ Planner", for: first, exactTitle: nil, among: all))
    }

    /// Softer, but not blind: a window that exactly names a different session
    /// is still that session's, and clicking must not silence this one on it.
    @Test func plausibleMatchStillRefusesAnotherSessionsWindow() {
        let codex = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let claude = AgentSession(
            provider: "claude-code", sessionId: "k1", cwd: "/Users/dev/Planner", state: .running)
        let summary = "Fix the checkout redirect loop on expired sessions"
        #expect(
            !TerminalFocuser.isPlausibleMatch(
                windowTitle: "⠐ \(summary)", for: codex, exactTitle: nil,
                among: [(codex, nil), (claude, summary)]))
    }

    /// The real repro: two Claude sessions plus a Codex session sharing one
    /// repo directory — every session's best-scoring window must be its own.
    @Test func threeSessionsOneRepoEachMatchTheirOwnWindow() {
        let cwd = "/Users/dev/planner"
        let windowTitles = [
            "⠐ Fix the flaky scanner test",
            "✳ Port planner tooling",
            "planner",
        ]
        let exactTitles: [String?] = [
            "Fix the flaky scanner test",  // claude, named via statusline
            "Port planner tooling",  // claude, named via statusline
            nil,  // codex — bare project-name tab title
        ]
        for (sessionIndex, exactTitle) in exactTitles.enumerated() {
            let session = AgentSession(
                provider: exactTitle == nil ? "codex" : "claude-code",
                sessionId: "s\(sessionIndex)", cwd: cwd, state: .running
            )
            let candidates = TerminalFocuser.titleCandidates(for: session, exactTitle: exactTitle)
            let scores = windowTitles.map {
                TerminalFocuser.matchScore(windowTitle: $0, candidates: candidates)
            }
            let best = scores.enumerated().max { $0.element < $1.element }?.offset
            #expect(best == sessionIndex, "session \(sessionIndex) matched window \(best ?? -1)")
        }
    }

    // MARK: - Activity tie-break

    @Test func braillleSpinnersAreTheOnlyBusySignal() {
        #expect(TerminalFocuser.showsBusySpinner("⠋ Planner"))
        #expect(TerminalFocuser.showsBusySpinner("⠸ Planner"))
        #expect(!TerminalFocuser.showsBusySpinner("Planner"))
        // Claude Code's "✳" prefix is permanent, not an activity indicator.
        #expect(!TerminalFocuser.showsBusySpinner("✳ Port planner tooling"))
        #expect(!TerminalFocuser.showsBusySpinner(""))
    }

    /// Claude Code spins too — verified against a live window titled
    /// "⠂ Generate alternative LinkedIn post options" belonging to a running
    /// claude-code session. This locks in why the tie-break is not gated to
    /// Codex: gating it would blind the more common provider.
    @Test func claudeSessionsAlsoSpinWhileWorking() {
        let claudeBusy = "⠂ Generate alternative LinkedIn post options"
        #expect(TerminalFocuser.showsBusySpinner(claudeBusy))
        #expect(TerminalFocuser.activityAgrees(windowTitle: claudeBusy, state: .running))
        #expect(!TerminalFocuser.activityAgrees(windowTitle: claudeBusy, state: .needsYou))

        // Two Claude sessions in one repo, one working and one waiting: the
        // tie-break has to separate them exactly as it does for Codex.
        let session = AgentSession(
            provider: "claude-code", sessionId: "c1", cwd: "/Users/dev/planner", state: .needsYou)
        let candidates = TerminalFocuser.titleCandidates(for: session)
        let ranking = WindowIdentity.rankTitles(
            ["⠂ planner", "planner"], candidates: candidates, state: .needsYou)
        #expect(ranking?.tied.first == 1)
    }

    @Test func activityAgreementFollowsSessionState() {
        #expect(TerminalFocuser.activityAgrees(windowTitle: "⠋ Planner", state: .running))
        #expect(!TerminalFocuser.activityAgrees(windowTitle: "⠋ Planner", state: .needsYou))
        #expect(!TerminalFocuser.activityAgrees(windowTitle: "⠋ Planner", state: .idle))
        #expect(TerminalFocuser.activityAgrees(windowTitle: "Planner", state: .needsYou))
        #expect(TerminalFocuser.activityAgrees(windowTitle: "Planner", state: .idle))
        #expect(!TerminalFocuser.activityAgrees(windowTitle: "Planner", state: .running))
    }

    /// The user-reported repro, straight from a `[focus]` trace: two Codex
    /// sessions in one repo, both windows titled "Planner" and both scoring
    /// 80. The spinner is all that separates the session still working from
    /// the one waiting at its prompt, and the menu lists the busy one first.
    @Test func needsYouSessionSkipsTheStillSpinningSiblingWindow() {
        let session = AgentSession(
            provider: "codex", sessionId: "c1",
            cwd: "/Users/dev/Documents/ProjectsVelta/Planner", state: .needsYou
        )
        let candidates = TerminalFocuser.titleCandidates(for: session)
        let titles = ["…/Documents/ProjectsVelta/Planner", "⠋ Planner", "Planner"]
        let ranking = WindowIdentity.rankTitles(titles, candidates: candidates, state: .needsYou)
        #expect(ranking?.tied.first == 2)
        #expect(ranking?.score == 80)
        #expect(ranking?.tiedWithWinner == 0)
    }

    @Test func runningSessionPrefersTheSpinningWindow() {
        let session = AgentSession(
            provider: "codex", sessionId: "c2", cwd: "/Users/dev/planner", state: .running)
        let candidates = TerminalFocuser.titleCandidates(for: session)
        let ranking = WindowIdentity.rankTitles(
            ["planner", "⠸ planner"], candidates: candidates, state: .running)
        #expect(ranking?.tied.first == 1)
        #expect(ranking?.tiedWithWinner == 0)
    }

    @Test func activityNeverOutranksAStrongerTitleMatch() {
        let session = AgentSession(
            provider: "claude-code", sessionId: "c3", cwd: "/Users/dev/planner", state: .needsYou)
        let candidates = TerminalFocuser.titleCandidates(
            for: session, exactTitle: "Fix the flaky scanner test")
        // The exact-title window is spinning (stale title paint) and the bare
        // project window is not: the far stronger title match must still win.
        let ranking = WindowIdentity.rankTitles(
            ["planner", "⠋ Fix the flaky scanner test"], candidates: candidates, state: .needsYou)
        #expect(ranking?.tied.first == 1)
        #expect(ranking?.activityAgrees == false)
    }

    @Test func trulyIdenticalWindowsReportTheTie() {
        let session = AgentSession(
            provider: "codex", sessionId: "c4", cwd: "/Users/dev/planner", state: .needsYou)
        let candidates = TerminalFocuser.titleCandidates(for: session)
        let ranking = WindowIdentity.rankTitles(
            ["planner", "planner"], candidates: candidates, state: .needsYou)
        #expect(ranking?.tied.first == 0)
        #expect(ranking?.tiedWithWinner == 1)
    }

    @Test func rankingIgnoresNonMatchingTitlesEntirely() {
        let session = AgentSession(
            provider: "codex", sessionId: "c5", cwd: "/Users/dev/planner", state: .needsYou)
        let candidates = TerminalFocuser.titleCandidates(for: session)
        #expect(
            WindowIdentity.rankTitles(["Mail", "Slack"], candidates: candidates, state: .needsYou)
                == nil)
        #expect(WindowIdentity.rankTitles([], candidates: candidates, state: .needsYou) == nil)
    }
}
