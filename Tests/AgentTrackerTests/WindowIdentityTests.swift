import Testing

@testable import AgentTracker

final class WindowIdentityTests {
    @Test func documentAttributeYieldsAPath() {
        #expect(
            WindowIdentity.directory(fromDocumentAttribute: "file:///Users/dev/Planner/")
                == "/Users/dev/Planner")
        #expect(
            WindowIdentity.directory(fromDocumentAttribute: "/Users/dev/Planner")
                == "/Users/dev/Planner")
    }

    /// Absence of evidence must never raise a window: anything that isn't a
    /// local path has to read as "unknown", not as a match for something.
    @Test func nonPathDocumentValuesAreUnknown() {
        #expect(WindowIdentity.directory(fromDocumentAttribute: nil) == nil)
        #expect(WindowIdentity.directory(fromDocumentAttribute: "") == nil)
        #expect(WindowIdentity.directory(fromDocumentAttribute: "Untitled") == nil)
        #expect(WindowIdentity.directory(fromDocumentAttribute: "https://example.com") == nil)
    }

    @Test func pathsAreComparedInNormalizedForm() {
        #expect(WindowIdentity.normalize("/Users/dev/Planner/") == "/Users/dev/Planner")
        #expect(WindowIdentity.normalize("/private/tmp/x") == "/tmp/x")
        #expect(WindowIdentity.normalize("/Users/dev/Planner/../Planner") == "/Users/dev/Planner")
        #expect(WindowIdentity.normalize("/") == "/")
    }

    @Test func matchingRequiresBothSides() {
        #expect(
            WindowIdentity.matches(windowDirectory: "/Users/dev/a", sessionCwd: "/Users/dev/a/"))
        #expect(!WindowIdentity.matches(windowDirectory: nil, sessionCwd: "/Users/dev/a"))
        #expect(!WindowIdentity.matches(windowDirectory: "/Users/dev/a", sessionCwd: nil))
        #expect(!WindowIdentity.matches(windowDirectory: "/Users/dev/a", sessionCwd: ""))
    }

    /// A parent directory is not the session's directory — the whole point is
    /// that ".../Planner" must not claim a ".../Planner/planner-backend"
    /// session's window, which substring title matching happily did.
    @Test func nearbyDirectoriesDoNotMatch() {
        #expect(
            !WindowIdentity.matches(
                windowDirectory: "/Users/dev/Planner", sessionCwd: "/Users/dev/Planner/backend"))
        #expect(
            !WindowIdentity.matches(
                windowDirectory: "/Users/dev/Planner/backend", sessionCwd: "/Users/dev/Planner"))
    }

    /// The reported failure: three windows across three projects, only the
    /// session's own directory may be selected.
    @Test func onlyTheSessionsOwnProjectWindowMatches() {
        let directories: [String?] = [
            "/Users/dev/ProjectsVelta/Planner",
            "/Users/dev/ProjectsVelta/Marrow/medium-blog-content",
            nil,
            "/Users/dev/ProjectsVelta/FunProjects/agent-tracker",
        ]
        #expect(
            WindowIdentity.matchingIndices(
                windowDirectories: directories,
                sessionCwd: "/Users/dev/ProjectsVelta/Marrow/medium-blog-content") == [1])
        #expect(
            WindowIdentity.matchingIndices(
                windowDirectories: directories, sessionCwd: "/Users/dev/elsewhere") == [])
    }

    /// The reported bug: sitting in one Planner terminal and clicking another
    /// Planner session did nothing, because the first candidate WAS the window
    /// already focused. Skipping it makes the click do something, and makes
    /// repeated clicks cycle through the candidates.
    @Test func ambiguousChoiceSkipsTheWindowAlreadyFocused() {
        let hits = [1, 3, 5]
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: 1, offset: 0) == 3)
        // Focused window isn't a candidate, or nothing is focused: the offset's
        // own candidate stands.
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: 9, offset: 0) == 1)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: 0) == 1)
        // One candidate is still returned even when it is the focused one —
        // there is nowhere else to go, and a click must never be a no-op.
        #expect(WindowIdentity.chooseAmbiguous(hits: [4], focused: 4, offset: 0) == 4)
        #expect(WindowIdentity.chooseAmbiguous(hits: [], focused: nil, offset: 0) == nil)
    }

    /// The reported failure: two Codex rows in one repo both landed on the same
    /// terminal. Each row's click count starts at 0, so a count alone sends
    /// every sibling to the same candidate — the offset has to carry which
    /// sibling is asking.
    @Test func siblingsStartFromDifferentCandidates() {
        let hits = [1, 3, 5]
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: 0) == 1)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: 1) == 3)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: 2) == 5)
        // Repeated clicks on one row keep walking, and wrap.
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: 3) == 1)
        // Total over every Int — offset is rank + clicks, both caller-supplied.
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: -1) == 5)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: .min) != nil)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: .max) != nil)
    }

    @Test func rotationOffsetCombinesRankAndClicks() {
        let first = WindowIdentity.FocusRotation(rank: 0, clicks: 0, siblingCount: 2)
        let second = WindowIdentity.FocusRotation(rank: 1, clicks: 0, siblingCount: 2)
        #expect(first.offset == 0)
        #expect(second.offset == 1)
        // Clicking the first row again reaches what the second row starts on.
        #expect(WindowIdentity.FocusRotation(rank: 0, clicks: 1, siblingCount: 2).offset == 1)
        #expect(WindowIdentity.FocusRotation.alone.offset == 0)
        #expect(WindowIdentity.FocusRotation.alone.siblingCount == 1)
    }

    /// Ranks must be dense over the sessions that actually compete, and stable
    /// across reloads. A named session sharing the directory does not compete —
    /// counting it would leave ranks 0 and 2 for two rivals, which collide on
    /// candidate 0 of a 2-window tie.
    @Test func ranksAreDenseStableAndExcludeNamedSessions() {
        let rivals = ["codex-b", "codex-a"]
        let first = WindowIdentity.FocusRotation.among(rivals, sessionId: "codex-a", clicks: 0)
        let second = WindowIdentity.FocusRotation.among(rivals, sessionId: "codex-b", clicks: 0)
        #expect(first.rank == 0)
        #expect(second.rank == 1)
        #expect(first.siblingCount == 2)
        // Input order does not move a rank: the same rivals listed the other
        // way round give the same answer.
        #expect(
            WindowIdentity.FocusRotation.among(rivals.reversed(), sessionId: "codex-a", clicks: 0)
                == first)
        // Two rivals, two windows, two different destinations.
        let hits = [0, 1]
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: first.offset) == 0)
        #expect(
            WindowIdentity.chooseAmbiguous(hits: hits, focused: nil, offset: second.offset) == 1)

        // A session absent from the list has nobody to be confused with.
        let named = WindowIdentity.FocusRotation.among(rivals, sessionId: "claude-x", clicks: 3)
        #expect(named.rank == 0)
        #expect(named.siblingCount == 1)
        #expect(named.clicks == 3)
    }

    /// The reported critical failure, straight from a `[focus]` trace: a Codex
    /// session in .../Planner raised the window titled "⠐ Reduce Pondria ToS
    /// visibility in Google search results" — a Claude Code session's window
    /// that merely shared the directory. Ownership by name has to beat a
    /// directory tie.
    @Test func aWindowNamingAnotherSessionIsNotOurs() {
        let codex = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let claude = AgentSession(
            provider: "claude-code", sessionId: "k1", cwd: "/Users/dev/Planner", state: .running)
        let summary = "Reduce Pondria ToS visibility in Google search results"
        let codexCandidates = TerminalFocuser.titleCandidates(for: codex, exactTitle: nil)
        let claudeCandidates = TerminalFocuser.titleCandidates(for: claude, exactTitle: summary)
        #expect(
            WindowIdentity.ownedByAnotherSession(
                windowTitle: "⠐ \(summary)", ownCandidates: codexCandidates,
                rivalCandidates: [claudeCandidates]))
        // …and the owner may still raise it herself.
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "⠐ \(summary)", ownCandidates: claudeCandidates,
                rivalCandidates: [codexCandidates]))
    }

    /// Two Codex sessions in one repo both title their window "Planner". That
    /// is a tie, not somebody else's property — excluding it would leave the
    /// click with nothing to raise at all.
    @Test func aTitleBothSessionsAnswerToIsNotOwnedByEither() {
        let first = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let second = AgentSession(
            provider: "codex", sessionId: "c2", cwd: "/Users/dev/Planner", state: .running)
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "⠸ Planner",
                ownCandidates: TerminalFocuser.titleCandidates(for: first, exactTitle: nil),
                rivalCandidates: [TerminalFocuser.titleCandidates(for: second, exactTitle: nil)]))
    }

    /// A plain shell titled with its path belongs to nobody, and a lone
    /// session (no rivals loaded yet) must exclude nothing.
    @Test func unclaimedTitlesAndEmptyRostersExcludeNothing() {
        let session = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let other = AgentSession(
            provider: "claude-code", sessionId: "k1", cwd: "/Users/dev/Marrow", state: .idle)
        let own = TerminalFocuser.titleCandidates(for: session, exactTitle: nil)
        let rival = TerminalFocuser.titleCandidates(
            for: other, exactTitle: "Initial setup and access granted")
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "…/Documents/dev/Planner", ownCandidates: own,
                rivalCandidates: [rival]))
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "✳ Initial setup and access granted", ownCandidates: own,
                rivalCandidates: []))
    }

    /// Two windows tie and nothing can separate them, so repeated clicks walk
    /// them: raising the same one every time makes the second click read as
    /// dead, and it is the only way to reach the sibling at all. Unlike the
    /// directory path this cannot skip "the focused window" — the menu offers
    /// titles only, and tied titles are identical by definition.
    @Test func tiedCandidatesAreWalkedAcrossRepeatedClicks() {
        let candidates = [TerminalFocuser.TitleCandidate("Planner", weight: 40)]
        let ranking = WindowIdentity.rankTitles(
            ["Planner", "Planner"], candidates: candidates, state: .needsYou)
        #expect(ranking?.tied == [0, 1])
        #expect(ranking?.choice(rotation: 0) == 0)
        #expect(ranking?.choice(rotation: 1) == 1)
        #expect(ranking?.choice(rotation: 2) == 0)

        // A lone winner is returned whatever the rotation — there is nowhere
        // else to go, and a click must never become a no-op.
        let single = WindowIdentity.rankTitles(
            ["Planner", "Mail"], candidates: candidates, state: .needsYou)
        #expect(single?.tied == [0])
        #expect(single?.choice(rotation: 0) == 0)
        #expect(single?.choice(rotation: 7) == 0)

        // Total over every Int: rotation is caller-supplied, and a trap here
        // would take down a click.
        #expect(ranking?.choice(rotation: -1) == 1)
        #expect(ranking?.choice(rotation: Int.min) == 0)
        #expect(ranking?.choice(rotation: Int.max) == 1)
    }

    @Test func siblingSessionsInOneRepoAllMatch() {
        let directories: [String?] = Array(repeating: "/Users/dev/Planner", count: 3)
        #expect(
            WindowIdentity.matchingIndices(
                windowDirectories: directories, sessionCwd: "/Users/dev/Planner") == [0, 1, 2])
    }
}
