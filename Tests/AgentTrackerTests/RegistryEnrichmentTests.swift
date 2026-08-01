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

    @Test func registryNameBecomesTheRowTitle() {
        let enriched = RegistryEnrichment.apply(to: session(), entry: entry())
        #expect(enriched.registryName == "planner-e8")
        #expect(enriched.displayName == "planner-e8")
    }

    /// Without a registry entry nothing changes — Codex sessions and older
    /// Claude versions keep the directory name.
    @Test func rowsWithoutARegistryEntryAreUntouched() {
        let plain = session()
        #expect(RegistryEnrichment.apply(to: plain, entry: nil) == plain)
        #expect(plain.displayName == "pln-388")
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
