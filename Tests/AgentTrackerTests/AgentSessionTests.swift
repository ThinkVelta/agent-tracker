import Testing

@testable import AgentTracker

final class AgentSessionTests {
    private func session(cwd: String?) -> AgentSession {
        AgentSession(provider: "claude-code", sessionId: "s", cwd: cwd, state: .idle)
    }

    @Test func locationContextIsTheContainingDirectory() {
        #expect(
            session(cwd: "/Users/dev/Documents/ProjectsVelta/Planner").locationContext
                == "ProjectsVelta")
    }

    /// A worktree's parent names no project — "Planner" is the answer the user
    /// needs, "worktrees" tells them nothing.
    @Test func locationContextSkipsContainerDirectories() {
        #expect(
            session(cwd: "/Users/dev/ProjectsVelta/Planner/worktrees/pln-388").locationContext
                == "Planner")
        #expect(
            session(cwd: "/Users/dev/ProjectsVelta/Planner/.worktrees/pln-388").locationContext
                == "Planner")
        // Nested containers unwind all the way.
        #expect(
            session(cwd: "/Users/dev/Planner/repos/src/thing").locationContext == "Planner")
    }

    @Test func locationContextHandlesShallowAndMissingPaths() {
        #expect(session(cwd: nil).locationContext == nil)
        #expect(session(cwd: "/").locationContext == nil)
        #expect(session(cwd: "/Users").locationContext == nil)
        #expect(session(cwd: "/Users/dev").locationContext == "Users")
    }

    @Test func projectNameFallsBackWhenThereIsNoDirectory() {
        #expect(session(cwd: nil).projectName == "Session")
        #expect(session(cwd: "").projectName == "Session")
        #expect(session(cwd: "/Users/dev/planner").projectName == "planner")
    }
}
