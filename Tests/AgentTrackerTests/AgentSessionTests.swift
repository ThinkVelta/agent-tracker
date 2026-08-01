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
        // Nested scaffolding unwinds all the way.
        #expect(
            session(cwd: "/Users/dev/Planner/.claude/worktrees/pln-1").locationContext
                == "Planner")
    }

    /// Only known scaffolding is skipped. Generic-sounding directories are
    /// real context when nothing better encloses them, and a hidden directory
    /// can be a project root in its own right.
    @Test func locationContextKeepsDirectoriesThatCarryMeaning() {
        #expect(session(cwd: "/Users/dev/src/agent-tracker").locationContext == "src")
        #expect(session(cwd: "/Users/dev/repos/agent-tracker").locationContext == "repos")
        #expect(session(cwd: "/Users/dev/.config/nvim").locationContext == ".config")
        #expect(session(cwd: "/Users/dev/.dotfiles/zsh").locationContext == ".dotfiles")
    }

    /// The shape this repo's own worktrees actually take — reported ".claude"
    /// before dot-directories were treated as scaffolding.
    @Test func locationContextSkipsDotDirectories() {
        let cwd = "/Users/dev/Planner/planner-backend/.claude/worktrees/pln-388-contracts"
        #expect(session(cwd: cwd).locationContext == "planner-backend")
        // Only contiguous trailing scaffolding is unwound: a real directory
        // name stops the walk even when scaffolding sits above it.
        #expect(session(cwd: "/Users/dev/thing/.git/modules/x").locationContext == "modules")
    }

    /// A path that is nothing but scaffolding has no honest answer.
    @Test func locationContextGivesUpWhenEverythingIsScaffolding() {
        #expect(session(cwd: "/worktrees/pln-388").locationContext == nil)
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
