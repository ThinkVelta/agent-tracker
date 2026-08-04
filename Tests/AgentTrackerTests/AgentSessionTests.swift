import Foundation
import Testing

@testable import AgentTracker

final class AgentSessionTests {
    private func session(cwd: String?) -> AgentSession {
        AgentSession(provider: "claude-code", sessionId: "s", cwd: cwd, state: .idle)
    }

    // MARK: - State file decoding

    /// A state file exactly as the hook writes it, pane identity included.
    @Test func terminalIdentityIsReadFromTheStateFile() throws {
        let written = """
            {"schema":1,"provider":"claude-code","sessionId":"s1","pid":84890,
             "cwd":"/Users/dev/demo","state":"needsYou","lastEvent":"Stop",
             "termProgram":"ghostty",
             "terminal":{"tty":"/dev/ttys003","term":"xterm-ghostty","tmuxPane":"%3",
                         "itermSessionId":"w0t0p0:ABC","kittyWindowId":"7"}}
            """
        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(written.utf8))
        #expect(decoded.terminal?.tty == "/dev/ttys003")
        #expect(decoded.terminal?.term == "xterm-ghostty")
        #expect(decoded.terminal?.tmuxPane == "%3")
        #expect(decoded.terminal?.itermSessionId == "w0t0p0:ABC")
        #expect(decoded.terminal?.kittyWindowId == "7")
        // Whatever the terminal did not report simply is not there.
        #expect(decoded.terminal?.weztermPane == nil)
    }

    /// Sessions written by an older hook, and every Codex row the scanner
    /// discovers, carry no `terminal` block at all. They must still load.
    @Test func aStateFileWithoutPaneIdentityStillLoads() throws {
        let written = """
            {"schema":1,"provider":"claude-code","sessionId":"s1","state":"idle",
             "cwd":"/Users/dev/demo","termProgram":"ghostty"}
            """
        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(written.utf8))
        #expect(decoded.terminal == nil)
        #expect(decoded.termProgram == "ghostty")
    }

    @Test func locationContextIsTheContainingDirectory() {
        #expect(
            session(cwd: "/Users/dev/Documents/ProjectsVelta/Planner").locationContext
                == "ProjectsVelta")
    }

    /// A worktree session is titled with its project and located by its
    /// worktree: "Planner" is what the user recognizes, and the branch
    /// directory is what separates it from a sibling in the same repo.
    /// "worktrees" and ".claude" are never the answer to either question.
    @Test func worktreeSessionsAreTitledByProjectAndLocatedByBranch() {
        let plain = session(cwd: "/Users/dev/ProjectsVelta/Planner/worktrees/pln-388")
        #expect(plain.displayName == "Planner")
        #expect(plain.locationContext == "pln-388")

        let hidden = session(cwd: "/Users/dev/ProjectsVelta/Planner/.worktrees/pln-388")
        #expect(hidden.displayName == "Planner")
        #expect(hidden.locationContext == "pln-388")

        // Nested scaffolding unwinds all the way.
        let nested = session(cwd: "/Users/dev/Planner/.claude/worktrees/pln-1")
        #expect(nested.displayName == "Planner")
        #expect(nested.locationContext == "pln-1")
    }

    /// The reported inconsistency: Codex rows read "Planner" while Claude rows
    /// beside them read "alice-app-123-fix-checkout-…-8419e2f7". Same
    /// rule, wildly different results — because only the Claude sessions were
    /// running in worktrees. Both now title by project, and the generated name
    /// moves to the metadata line, shortened so it cannot push the session's
    /// status off the end.
    @Test func generatedWorktreeNamesDoNotTitleTheRow() {
        let real =
            "/Users/dev/ProjectsVelta/Planner/planner-backend/.claude/worktrees/"
            + "alice-app-123-fix-checkout-redirect-loop-on-expired-session-8419e2f7"
        let worktree = session(cwd: real)
        #expect(worktree.displayName == "planner-backend")
        #expect(worktree.locationContext == "alice-app-123…8419e2f7")
        #expect((worktree.locationContext?.count ?? 0) <= 24)

        // A session in the repo root is unaffected — this is the row the
        // worktree ones now line up with.
        let root = session(cwd: "/Users/dev/ProjectsVelta/Planner")
        #expect(root.displayName == "Planner")
        #expect(root.locationContext == "ProjectsVelta")
    }

    /// Short worktree names are left alone; only generated ones are shortened.
    @Test func shorteningKeepsBothEndsAndLeavesShortNamesWhole() {
        #expect(AgentSession.shortened("pln-388") == "pln-388")
        #expect(
            AgentSession.shortened("alice-app-124-125-tidy-nav-and-footer-6b694566")
                == "alice-app-124…6b694566")
        // No separator to cut back to: the head is taken as-is.
        #expect(
            AgentSession.shortened(String(repeating: "x", count: 40)) == "xxxxxxxxxxxxxxx…xxxxxxxx")
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
        #expect(session(cwd: cwd).displayName == "planner-backend")
        #expect(session(cwd: cwd).locationContext == "pln-388-contracts")
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
