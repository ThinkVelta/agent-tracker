import Foundation
import Testing

@testable import AgentTracker

final class RegistryEnrichmentTests {
    private func entry(
        name: String? = "planner-e8",
        cwd: String? = "/Users/dev/Planner",
        status: ClaudeSessionRegistry.Status = .busy,
        statusUpdatedAt: Date? = Date()
    ) -> ClaudeSessionRegistry.Entry {
        ClaudeSessionRegistry.Entry(
            sessionId: "s1", pid: nil, cwd: cwd, name: name,
            status: status, statusUpdatedAt: statusUpdatedAt)
    }

    private func session(
        provider: String = "claude-code",
        state: SessionState = .running,
        cwd: String? = "/Users/dev/Planner/planner-backend/.claude/worktrees/pln-388",
        changedAt: Date? = Date(timeIntervalSince1970: 1000)
    ) -> AgentSession {
        AgentSession(
            provider: provider, sessionId: "s1", cwd: cwd, state: state, stateChangedAt: changedAt)
    }

    private func stopped(changedAt: Date = Date(timeIntervalSince1970: 1000)) -> AgentSession {
        var stopped = session(state: .needsYou, changedAt: changedAt)
        stopped.lastEvent = "Stop"
        stopped.reason = "Turn complete — ready for you"
        return stopped
    }

    /// The reported bug: Claude backgrounds a shell, its turn ends so `Stop`
    /// fires, and the row sits red for as long as the shell runs — 46 minutes,
    /// in the report — while the harness is going to resume the session by
    /// itself and nothing is wanted from the user. Claude's own registry says
    /// `busy` throughout.
    @Test func aTurnThatEndedWithWorkStillRunningIsNotWaitingOnYou() {
        let enriched = RegistryEnrichment.apply(
            to: stopped(), entry: entry(status: .busy, statusUpdatedAt: Date()))
        #expect(enriched.state == .running)
        #expect(enriched.reason == "Working…")
    }

    /// Nothing is written back — the state is re-derived every reload — so a
    /// session that really has finished returns to red on its own.
    @Test func theRedComesBackWhenClaudeActuallySettles() {
        let settled = RegistryEnrichment.apply(
            to: stopped(), entry: entry(status: .idle, statusUpdatedAt: Date()))
        #expect(settled.state == .needsYou)
        #expect(settled.reason == "Turn complete — ready for you")
    }

    /// A permission prompt is the one thing this app exists to show. It arrives
    /// as `Notification`, the registry knows nothing about it, and no amount of
    /// "busy" may clear it.
    @Test func aPermissionPromptIsNeverClearedByABusyRegistry() {
        var prompted = session(state: .needsYou)
        prompted.lastEvent = "Notification"
        prompted.reason = "Claude needs your permission to use Bash"
        let enriched = RegistryEnrichment.apply(
            to: prompted, entry: entry(status: .busy, statusUpdatedAt: Date()))
        #expect(enriched.state == .needsYou)
        #expect(enriched.reason == "Claude needs your permission to use Bash")
    }

    /// A registry entry older than the hook event proves nothing: the hook is
    /// the more precise signal when it is fresher, both directions.
    @Test func aLaggingRegistryNeverOverridesAFreshHookEvent() {
        let now = Date()
        let stale = entry(status: .busy, statusUpdatedAt: now.addingTimeInterval(-60))
        #expect(
            RegistryEnrichment.apply(to: stopped(changedAt: now), entry: stale).state == .needsYou)
        // …and a status the registry cannot express stays out of it.
        #expect(
            RegistryEnrichment.apply(
                to: stopped(), entry: entry(status: .unknown, statusUpdatedAt: Date())
            ).state == .needsYou)
        #expect(
            RegistryEnrichment.apply(
                to: stopped(), entry: entry(status: .waiting, statusUpdatedAt: Date())
            ).state == .needsYou)
    }

    /// The registry name is joined in and stays searchable, but the row title
    /// is the directory for EVERY provider — only Claude publishes a registry
    /// name, and preferring it made Claude and Codex rows read differently.
    @Test func registryNameIsJoinedButDoesNotTitleTheRow() {
        let enriched = RegistryEnrichment.apply(to: session(), entry: entry())
        #expect(enriched.registryName == "planner-e8")
        #expect(enriched.displayName == "planner-backend")
        // Identical with or without a registry entry — that is the point.
        #expect(enriched.displayName == session().displayName)
    }

    /// A row with no hook cwd still has the registry's; falling through to the
    /// generic "Session" placeholder would throw away a real directory name.
    @Test func theRegistryDirectoryTitlesARowThatHasNoHookCwd() {
        let enriched = RegistryEnrichment.apply(
            to: session(cwd: nil), entry: entry(cwd: "/Users/dev/Planner"))
        #expect(enriched.displayName == "Planner")
        // Nothing anywhere: the placeholder is still the honest answer.
        let empty = RegistryEnrichment.apply(to: session(cwd: nil), entry: entry(cwd: nil))
        #expect(empty.displayName == "Session")
    }

    /// Without a registry entry nothing changes — Codex sessions and older
    /// Claude versions keep the directory name.
    @Test func rowsWithoutARegistryEntryAreUntouched() {
        let plain = session()
        #expect(RegistryEnrichment.apply(to: plain, entry: nil) == plain)
        #expect(plain.displayName == "planner-backend")
    }

    @Test func theRegistryIsClaudeOnly() {
        let codex = session(provider: "codex")
        #expect(RegistryEnrichment.apply(to: codex, entry: entry()) == codex)
    }

    /// The hook records where the agent works, the registry where its terminal
    /// sits. For a worktree session those differ, and a window may report
    /// either — so both have to be offered to the matcher.
    @Test func bothDirectoriesAreOfferedForWindowMatching() {
        let enriched = RegistryEnrichment.apply(to: session(), entry: entry())
        #expect(
            enriched.windowDirectories == [
                "/Users/dev/Planner/planner-backend/.claude/worktrees/pln-388",
                "/Users/dev/Planner",
            ])
        // A window reporting the terminal's directory still finds the session.
        #expect(
            WindowIdentity.matchingIndices(
                windowDirectories: ["/Users/dev/Planner"],
                sessionDirectories: enriched.windowDirectories) == [0])
    }

    /// AXDocument matching only sees the current Space, so the title path has
    /// to know about the terminal's directory too — otherwise a worktree
    /// session on another Space matches nothing.
    @Test func titleCandidatesCoverBothDirectories() {
        let enriched = RegistryEnrichment.apply(to: session(), entry: entry())
        let candidates = TerminalFocuser.titleCandidates(for: enriched)
        #expect(candidates.contains { $0.text == "/Users/dev/Planner" && $0.weight == 60 })
        #expect(
            candidates.contains {
                $0.text == "/Users/dev/Planner/planner-backend/.claude/worktrees/pln-388"
            })
        // The widest tier stays single: a second bare project name would let a
        // worktree session claim any window of the parent repo.
        #expect(candidates.filter { $0.weight == 40 }.count <= 1)
    }

    @Test func duplicateDirectoriesAreNotDoubledUp() {
        let same = "/Users/dev/Planner"
        let enriched = RegistryEnrichment.apply(
            to: session(cwd: same), entry: entry(cwd: same))
        let candidates = TerminalFocuser.titleCandidates(for: enriched)
        #expect(candidates.map(\.text).count == Set(candidates.map(\.text)).count)
    }

    // MARK: - State resolution

    /// Claude Code has no interrupt hook, so a session the user escaped out of
    /// stays green until its next event. The registry closes that gap.
    @Test func aStaleRunningRowIsDemotedByAFresherIdleStatus() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .running, changedAt: Date(timeIntervalSince1970: 1000)),
            entry: entry(status: .idle, statusUpdatedAt: Date(timeIntervalSince1970: 2000)))
        #expect(enriched.state == .idle)
        #expect(enriched.reason == "Idle at prompt")
    }

    @Test func waitingCountsAsNotRunning() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .running, changedAt: Date(timeIntervalSince1970: 1000)),
            entry: entry(status: .waiting, statusUpdatedAt: Date(timeIntervalSince1970: 2000)))
        #expect(enriched.state == .idle)
    }

    /// The hook is the more precise signal when it is fresher; a lagging
    /// registry file must not stomp a just-arrived event.
    @Test func aFresherHookEventBeatsTheRegistry() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .running, changedAt: Date(timeIntervalSince1970: 3000)),
            entry: entry(status: .idle, statusUpdatedAt: Date(timeIntervalSince1970: 2000)))
        #expect(enriched.state == .running)
        #expect(enriched.reason == nil)
    }

    /// The one state the registry knows nothing about, and the one the whole
    /// app exists to surface.
    @Test func needsYouIsNeverDemoted() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .needsYou, changedAt: Date(timeIntervalSince1970: 1000)),
            entry: entry(status: .idle, statusUpdatedAt: Date(timeIntervalSince1970: 9000)))
        #expect(enriched.state == .needsYou)
    }

    @Test func busyOrUnknownStatusLeavesTheStateAlone() {
        for status in [ClaudeSessionRegistry.Status.busy, .unknown] {
            let enriched = RegistryEnrichment.apply(
                to: session(state: .running, changedAt: Date(timeIntervalSince1970: 1000)),
                entry: entry(status: status, statusUpdatedAt: Date(timeIntervalSince1970: 9000)))
            #expect(enriched.state == .running, "status \(status) must not demote")
        }
    }

    /// No timestamp means no way to tell which signal is newer, so the
    /// registry does not get to overrule the hook.
    @Test func anUndatedStatusNeverDemotes() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .running),
            entry: entry(status: .idle, statusUpdatedAt: nil))
        #expect(enriched.state == .running)
    }
}
