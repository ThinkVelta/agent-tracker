import Foundation
import Testing

@testable import AgentTracker

@Suite("Session rename")
struct SessionRenameTests {
    // MARK: - The name that gets typed

    /// Newlines are the reason this function exists. The channel writes the text
    /// and then presses Return, so a newline in the middle submits early and
    /// leaves whatever followed it sitting in the user's session as a prompt.
    @Test("a pasted multi-line name becomes one line")
    func newlinesCannotSubmitEarly() {
        #expect(SessionRename.sanitize("payments\nrefactor") == "payments refactor")
        #expect(SessionRename.sanitize("a\r\nb") == "a b")
        #expect(SessionRename.sanitize("a\tb") == "a b")
        #expect(SessionRename.command(for: "payments\nrefactor") == "/rename payments refactor")
    }

    @Test("nothing but whitespace is not a name")
    func emptyIsNil() {
        #expect(SessionRename.sanitize("") == nil)
        #expect(SessionRename.sanitize("   ") == nil)
        #expect(SessionRename.sanitize("\n\t ") == nil)
        #expect(SessionRename.command(for: " ") == nil)
    }

    /// Surrounding whitespace goes; interior spacing is the user's business.
    @Test("trimmed at the edges, left alone in the middle")
    func trimsWithoutMangling() {
        #expect(SessionRename.sanitize("  api gateway  ") == "api gateway")
        #expect(SessionRename.sanitize("api  gateway") == "api  gateway")
    }

    /// Claude owns what a valid name is. Imposing a length cap or a character
    /// set here would refuse names it would have accepted, and the app has no
    /// way to know which those are.
    @Test("no rule beyond one non-empty line")
    func noInventedLimits() {
        let long = String(repeating: "x", count: 300)
        #expect(SessionRename.command(for: long) == "/rename \(long)")
        #expect(SessionRename.command(for: "🚀 ünïcode / slashes") == "/rename 🚀 ünïcode / slashes")
    }

    @Test("a rename to the name it already has is refused")
    func unchangedIsRefused() {
        #expect(SessionRename.check(proposed: "api", current: "api") == .unchanged)
        #expect(SessionRename.check(proposed: "  api  ", current: "api") == .unchanged)
        #expect(SessionRename.check(proposed: "", current: "api") == .emptyName)
        #expect(SessionRename.check(proposed: "api", current: "web") == nil)
        #expect(SessionRename.check(proposed: "api", current: nil) == nil)
    }

    // MARK: - Delivery

    private final class Recorder: @unchecked Sendable {
        private(set) var calls: [String] = []
        func note(_ call: String) { calls.append(call) }
    }

    private let surfaceId = "DA10160F-6992-4EDC-89F3-7084841E9C52"
    private let ghosttyPid: Int32 = 1419

    private func agent(pgid: Int32 = 5150, tpgid: Int32 = 5150, comm: String = "claude")
        -> ProcessIdentity
    {
        ProcessIdentity(
            pid: 5150, startedAt: Date(timeIntervalSince1970: 1_785_900_000), comm: comm,
            pgid: pgid, tpgid: tpgid, tty: "ttys006")
    }

    private func ghosttyResolved() -> SessionTarget.Resolved {
        SessionTarget.Resolved(
            target: TerminalDelivery.Target(
                surfaceId: surfaceId, title: "✳ demo", terminalPid: ghosttyPid))
    }

    private func tmuxResolved() -> SessionTarget.Resolved {
        SessionTarget.Resolved(
            tmuxTarget: TerminalDelivery.TmuxTarget(
                paneId: "%3", tty: "/dev/ttys007", socketPath: nil))
    }

    private func ops(
        _ recorder: Recorder, writeSucceeds: Bool = true, returnSucceeds: Bool = true
    ) -> ChannelOps {
        ChannelOps(
            terminalPid: {
                recorder.note("terminalPid")
                return self.ghosttyPid
            },
            surfaces: { _ in .success([]) },
            writeText: { _, _, addressed in
                recorder.note("writeText@\(addressed)")
                return writeSucceeds
            },
            pressReturn: { _, addressed in
                recorder.note("pressReturn@\(addressed)")
                return returnSucceeds
            })
    }

    private func tmuxOps(
        _ recorder: Recorder, writeSucceeds: Bool = true, returnSucceeds: Bool = true
    ) -> TmuxOps {
        TmuxOps(
            panes: { _ in .success([TmuxScripting.Pane(id: "%3", tty: "/dev/ttys007")]) },
            writeText: { _, addressed, _ in
                recorder.note("writeText@\(addressed)")
                return writeSucceeds
            },
            pressReturn: { addressed, _ in
                recorder.note("pressReturn@\(addressed)")
                return returnSucceeds
            })
    }

    /// The gate that is not a nicety. Return pressed at an open permission
    /// prompt commits whichever option is focused, so a rename sent into a
    /// session sitting on a dialog would answer that dialog.
    @Test("a session that is not at a finished turn is never written to")
    func midTurnIsRefused() {
        for event in ["Notification", "PreToolUse", nil] {
            let recorder = Recorder()
            let result = SessionRename.deliver(
                command: "/rename api", resolved: ghosttyResolved(), lastEvent: event,
                liveAgent: agent(), ops: ops(recorder), tmux: tmuxOps(recorder))
            #expect(result.outcome == .refused)
            #expect(recorder.calls.isEmpty, "refused, so nothing may have been written")
        }
    }

    @Test("a dead process is refused before anything is written")
    func deadProcessIsRefused() {
        let recorder = Recorder()
        let result = SessionRename.deliver(
            command: "/rename api", resolved: ghosttyResolved(), lastEvent: "Stop",
            liveAgent: nil, ops: ops(recorder), tmux: tmuxOps(recorder))
        #expect(result.outcome == .refused)
        #expect(recorder.calls.isEmpty)
    }

    /// Regression: the process identity must come from the fresh read, not from
    /// the copy `SessionTarget.resolve` sampled at its start. Resolution runs an
    /// Automation preflight measured at over 100 seconds, so that copy can
    /// describe a process that has since exited. Here `resolved` carries a
    /// perfectly good agent and the live read says it is gone — the refusal
    /// proves which one is consulted.
    @Test("the agent that is checked is the freshly read one")
    func staleAgentIsNotTrusted() {
        let recorder = Recorder()
        var stale = ghosttyResolved()
        stale.agent = agent()
        let result = SessionRename.deliver(
            command: "/rename api", resolved: stale, lastEvent: "Stop",
            liveAgent: nil, ops: ops(recorder), tmux: tmuxOps(recorder))
        #expect(result.outcome == .refused)
        #expect(recorder.calls.isEmpty)
    }

    /// A session whose terminal is busy with something else is not at a prompt,
    /// whatever its last hook event said.
    @Test("a foreground process that is not the agent is refused")
    func foregroundMismatchIsRefused() {
        let recorder = Recorder()
        let result = SessionRename.deliver(
            command: "/rename api",
            resolved: ghosttyResolved(), lastEvent: "Stop",
            liveAgent: agent(pgid: 5150, tpgid: 9999), ops: ops(recorder),
            tmux: tmuxOps(recorder))
        #expect(result.outcome == .refused)
        #expect(recorder.calls.isEmpty)
    }

    /// The chicken-and-egg, stated in the refusal rather than hidden: outside
    /// tmux a session is addressed by its window title, so the ones the app
    /// cannot reach are exactly the ones sharing a title — which is what
    /// renaming would have fixed. The in-terminal path has no such limit.
    @Test("an unaddressable session is told what does work")
    func unreachableNamesTheWayOut() {
        let recorder = Recorder()
        let resolved = SessionTarget.Resolved(
            refusal: "Can't tell which window this session is in")
        let result = SessionRename.deliver(
            command: "/rename api", resolved: resolved, lastEvent: "Stop",
            liveAgent: agent(), ops: ops(recorder), tmux: tmuxOps(recorder))
        #expect(result.outcome == .refused)
        #expect(result.detail.contains("/rename in that terminal"))
        #expect(recorder.calls.isEmpty)
    }

    @Test("the happy path writes, then presses Return")
    func happyPathOrdering() {
        let recorder = Recorder()
        let result = SessionRename.deliver(
            command: "/rename api", resolved: ghosttyResolved(), lastEvent: "Stop",
            liveAgent: agent(), ops: ops(recorder), tmux: tmuxOps(recorder))
        #expect(result.outcome == .sent)
        #expect(recorder.calls == ["writeText@\(ghosttyPid)", "pressReturn@\(ghosttyPid)"])
    }

    /// A tmux session needs no Automation grant, so no Ghostty call may happen
    /// for one — the resolver checks tmux first for exactly this reason.
    @Test("a tmux session is written through tmux and nothing else")
    func tmuxPath() {
        let recorder = Recorder()
        let result = SessionRename.deliver(
            command: "/rename api", resolved: tmuxResolved(), lastEvent: "Stop",
            liveAgent: agent(), ops: ops(recorder), tmux: tmuxOps(recorder))
        #expect(result.outcome == .sent)
        #expect(recorder.calls == ["writeText@%3", "pressReturn@%3"])
        #expect(!recorder.calls.contains("terminalPid"))
    }

    /// The property that matters most: Return is never pressed on a write that
    /// did not land, in either channel.
    @Test("a failed write never presses Return")
    func returnFollowsTheWrite() {
        for tmux in [false, true] {
            let recorder = Recorder()
            let result = SessionRename.deliver(
                command: "/rename api", resolved: tmux ? tmuxResolved() : ghosttyResolved(),
                lastEvent: "Stop", liveAgent: agent(),
                ops: ops(recorder, writeSucceeds: false),
                tmux: tmuxOps(recorder, writeSucceeds: false))
            #expect(result.outcome == .failed)
            #expect(!recorder.calls.contains { $0.hasPrefix("pressReturn") })
        }
    }

    /// Written but not submitted is its own outcome. Reporting a plain failure
    /// would be wrong in the other direction: something IS sitting in that
    /// window and the user needs to know it is there.
    @Test("text left on the prompt says so")
    func unsentTextIsReported() {
        let recorder = Recorder()
        let result = SessionRename.deliver(
            command: "/rename api", resolved: ghosttyResolved(), lastEvent: "Stop",
            liveAgent: agent(), ops: ops(recorder, returnSucceeds: false),
            tmux: tmuxOps(recorder))
        #expect(result.outcome == .failed)
        #expect(result.detail.contains("waiting on the prompt"))
    }
}
