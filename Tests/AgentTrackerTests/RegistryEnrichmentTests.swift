import Foundation
import Testing

@testable import AgentTracker

final class RegistryEnrichmentTests {
    private func entry(
        name: String? = "planner-e8",
        cwd: String? = "/Users/dev/Planner",
        status: ClaudeSessionRegistry.Status = .busy,
        statusUpdatedAt: Date? = Date(),
        waitingFor: String? = nil
    ) -> ClaudeSessionRegistry.Entry {
        ClaudeSessionRegistry.Entry(
            sessionId: "s1", pid: nil, cwd: cwd, name: name,
            status: status, statusUpdatedAt: statusUpdatedAt, waitingFor: waitingFor)
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
    /// itself and nothing is wanted from the user.
    ///
    /// Claude publishes exactly this situation as `shell`. Reading it is the
    /// whole fix: the earlier attempt looked for `busy`, which is only what a
    /// resumed turn briefly reports, so the row flapped green each time one of
    /// the background tasks came back and went red again in between.
    @Test func aTurnThatEndedWithABackgroundShellIsNotWaitingOnYou() {
        let enriched = RegistryEnrichment.apply(
            to: stopped(), entry: entry(status: .shell, statusUpdatedAt: Date()))
        #expect(enriched.state == .running)
        #expect(enriched.reason == "Background work still running")
    }

    /// Delegated work counts the same way. Claude derives `busy` as
    /// `isLoading || delegatedActive`, so a lead session whose subagents or
    /// teammates are doing the work reports busy even though its own main
    /// thread has nothing to do.
    @Test func aTurnThatDelegatedItsWorkIsNotWaitingOnYouEither() {
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

    /// The measured shape of the registry, which the promotion rule depends on:
    /// the file is written on change, so a status is current at any age, and the
    /// write trails the hook by ~600ms. A `Stop` therefore always lands while
    /// the freshest status on disk still describes the turn that just ended —
    /// so demanding a newer timestamp would reject the promotion at exactly the
    /// moment it is needed, and blink red at the end of every turn.
    @Test func aStatusOlderThanTheStopStillCounts() {
        let now = Date()
        let heldSince = entry(status: .busy, statusUpdatedAt: now.addingTimeInterval(-60))
        #expect(
            RegistryEnrichment.apply(to: stopped(changedAt: now), entry: heldSince).state
                == .running)
    }

    /// A status the registry cannot express, and one that says a human IS
    /// wanted, both leave a red alone.
    @Test func onlyAWorkingStatusClearsARed() {
        for status in [ClaudeSessionRegistry.Status.unknown, .idle, .waiting] {
            #expect(
                RegistryEnrichment.apply(
                    to: stopped(), entry: entry(status: status, statusUpdatedAt: Date())
                ).state == .needsYou,
                "status \(status) must not clear a red")
        }
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

    /// `waiting` is written only while a dialog is blocking on a human —
    /// permission, a sandbox request, an elicitation — so it belongs in red.
    /// Grey means "open, nothing pending", which is the opposite. Claude's own
    /// description of what it wants is quoted rather than paraphrased.
    @Test func aDialogBlockingOnYouIsRedAndSaysWhat() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .running, changedAt: Date(timeIntervalSince1970: 1000)),
            entry: entry(
                status: .waiting, statusUpdatedAt: Date(timeIntervalSince1970: 2000),
                waitingFor: "input needed"))
        #expect(enriched.state == .needsYou)
        #expect(enriched.reason == "Waiting on you — input needed")
        // Not every dialog names itself.
        let unnamed = RegistryEnrichment.apply(
            to: session(state: .running), entry: entry(status: .waiting))
        #expect(unnamed.reason == "Needs your attention")
    }

    /// A dialog that opens mid-turn is reported after the `PreToolUse` that
    /// triggered it, so this correction must not be gated on being newer than
    /// the hook event the way the demotion is.
    @Test func aDialogIsRedEvenWithNoTimestampAtAll() {
        let enriched = RegistryEnrichment.apply(
            to: session(state: .running, changedAt: Date()),
            entry: entry(status: .waiting, statusUpdatedAt: nil))
        #expect(enriched.state == .needsYou)
    }

    /// The user's own click has to win. Acknowledging a row writes idle, and
    /// re-deriving it from the registry would undo that on the next reload.
    @Test func anAcknowledgedRowIsNeverReRaisedByTheRegistry() {
        for status in [ClaudeSessionRegistry.Status.waiting, .busy, .shell, .idle] {
            var acknowledged = session(state: .idle)
            acknowledged.reason = "Seen"
            let enriched = RegistryEnrichment.apply(
                to: acknowledged, entry: entry(status: status, statusUpdatedAt: Date()))
            #expect(enriched.state == .idle, "status \(status) reopened an acknowledged row")
            #expect(enriched.reason == "Seen")
        }
    }

    /// The reported flapping, as the sequence that produced it: a turn ends
    /// with two background tasks outstanding, and the harness resumes the
    /// session as each one lands. Every step has to read as one continuous
    /// stretch of work, because that is what it is.
    @Test func aTurnWaitingOnBackgroundWorkNeverBlinksRed() {
        let sequence: [(ClaudeSessionRegistry.Status, String)] = [
            (.busy, "the turn is still going"),
            (.shell, "turn ended, two background tasks running"),
            (.busy, "the first task landed and resumed the turn"),
            (.shell, "that turn ended too, one task still running"),
            (.busy, "the second task landed"),
        ]
        for (status, step) in sequence {
            let enriched = RegistryEnrichment.apply(
                to: stopped(), entry: entry(status: status, statusUpdatedAt: Date()))
            #expect(enriched.state == .running, "flapped to \(enriched.state): \(step)")
        }
        // …and red once, when everything really is done.
        let settled = RegistryEnrichment.apply(to: stopped(), entry: entry(status: .idle))
        #expect(settled.state == .needsYou)
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

    @Test func aWorkingOrUnknownStatusLeavesTheStateAlone() {
        for status in [ClaudeSessionRegistry.Status.busy, .shell, .unknown] {
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
