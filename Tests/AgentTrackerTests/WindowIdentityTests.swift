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
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: 1) == 3)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: 3) == 5)
        // Wraps, so a third click returns to the start rather than sticking.
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: 5) == 1)
        // Focused window isn't a candidate, or nothing is focused: first wins.
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: 9) == 1)
        #expect(WindowIdentity.chooseAmbiguous(hits: hits, focused: nil) == 1)
        // One candidate is still returned even when it is the focused one —
        // there is nowhere else to go.
        #expect(WindowIdentity.chooseAmbiguous(hits: [4], focused: 4) == 4)
        #expect(WindowIdentity.chooseAmbiguous(hits: [], focused: nil) == nil)
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
        let roster: [(session: AgentSession, exactTitle: String?)] = [
            (codex, nil), (claude, "Reduce Pondria ToS visibility in Google search results"),
        ]
        #expect(
            WindowIdentity.ownedByAnotherSession(
                windowTitle: "⠐ Reduce Pondria ToS visibility in Google search results",
                session: codex, exactTitle: nil, among: roster))
        // …and the owner may still raise it herself.
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "⠐ Reduce Pondria ToS visibility in Google search results",
                session: claude,
                exactTitle: "Reduce Pondria ToS visibility in Google search results",
                among: roster))
    }

    /// Two Codex sessions in one repo both title their window "Planner". That
    /// is a tie, not somebody else's property — excluding it would leave the
    /// click with nothing to raise at all.
    @Test func aTitleBothSessionsAnswerToIsNotOwnedByEither() {
        let first = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let second = AgentSession(
            provider: "codex", sessionId: "c2", cwd: "/Users/dev/Planner", state: .running)
        let roster: [(session: AgentSession, exactTitle: String?)] = [(first, nil), (second, nil)]
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "⠸ Planner", session: first, exactTitle: nil, among: roster))
    }

    /// A plain shell titled with its path belongs to nobody, and an empty
    /// roster (tests, or a store that hasn't loaded) must exclude nothing.
    @Test func unclaimedTitlesAndEmptyRostersExcludeNothing() {
        let session = AgentSession(
            provider: "codex", sessionId: "c1", cwd: "/Users/dev/Planner", state: .needsYou)
        let other = AgentSession(
            provider: "claude-code", sessionId: "k1", cwd: "/Users/dev/Marrow", state: .idle)
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "…/Documents/dev/Planner", session: session, exactTitle: nil,
                among: [(session, nil), (other, "Initial setup and access granted")]))
        #expect(
            !WindowIdentity.ownedByAnotherSession(
                windowTitle: "✳ Initial setup and access granted", session: session,
                exactTitle: nil, among: []))
    }

    @Test func siblingSessionsInOneRepoAllMatch() {
        let directories: [String?] = Array(repeating: "/Users/dev/Planner", count: 3)
        #expect(
            WindowIdentity.matchingIndices(
                windowDirectories: directories, sessionCwd: "/Users/dev/Planner") == [0, 1, 2])
    }
}
