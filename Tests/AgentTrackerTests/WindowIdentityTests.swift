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

    @Test func siblingSessionsInOneRepoAllMatch() {
        let directories: [String?] = Array(repeating: "/Users/dev/Planner", count: 3)
        #expect(
            WindowIdentity.matchingIndices(
                windowDirectories: directories, sessionCwd: "/Users/dev/Planner") == [0, 1, 2])
    }
}
