import Foundation
import Testing

@testable import AgentTracker

@Suite("tmux pane parsing")
struct TmuxPaneParsingTests {
    @Test("a normal listing becomes panes")
    func parsesPanes() {
        let panes = TmuxScripting.parsePanes("%0\t/dev/ttys006\n%12\t/dev/ttys013\n")
        #expect(
            panes == [
                TmuxScripting.Pane(id: "%0", tty: "/dev/ttys006"),
                TmuxScripting.Pane(id: "%12", tty: "/dev/ttys013"),
            ])
    }

    /// tmux prints warnings and version notices on the same stream, and a future
    /// version may add fields. Neither may crash the app or invent a pane.
    @Test("junk lines are dropped rather than parsed into a pane")
    func ignoresJunk() {
        let panes = TmuxScripting.parsePanes(
            """
            no tabs here
            \tmissing id
            %3\t
            not-a-pane-id\t/dev/ttys001
            %4\t/dev/ttys002\textra-future-field
            """)
        #expect(panes == [TmuxScripting.Pane(id: "%4", tty: "/dev/ttys002")])
    }

    @Test("empty output is no panes, never a crash")
    func handlesEmpty() {
        #expect(TmuxScripting.parsePanes("").isEmpty)
        #expect(TmuxScripting.parsePanes("\n\n").isEmpty)
    }
}

@Suite("tmux pane resolution")
struct TmuxResolutionTests {
    private let armed = ContinueDelivery.TmuxTarget(paneId: "%3", tty: "/dev/ttys007")

    @Test("the pane it was armed in, unchanged, is allowed")
    func unchangedPaneIsAllowed() {
        let verdict = ContinueDelivery.resolveTmux(
            recorded: armed,
            among: [
                TmuxScripting.Pane(id: "%2", tty: "/dev/ttys006"),
                TmuxScripting.Pane(id: "%3", tty: "/dev/ttys007"),
            ])
        #expect(verdict == .allowed)
    }

    @Test("a closed pane refuses")
    func missingPaneRefuses() {
        let verdict = ContinueDelivery.resolveTmux(
            recorded: armed, among: [TmuxScripting.Pane(id: "%2", tty: "/dev/ttys006")])
        #expect(verdict.refusal?.contains("gone") == true)
    }

    /// The case the tty exists to catch: a tmux server restarted overnight mints
    /// ids from %0 again, so the id alone can resolve to a stranger's pane.
    @Test("a recycled pane id with a different terminal refuses")
    func recycledPaneIdRefuses() {
        let verdict = ContinueDelivery.resolveTmux(
            recorded: armed, among: [TmuxScripting.Pane(id: "%3", tty: "/dev/ttys099")])
        #expect(verdict.refusal?.contains("different terminal") == true)
    }

    /// Not "find the pane whose tty matches" — that would follow a session into a
    /// pane it was never armed against.
    @Test("the right tty under a different pane id is not accepted")
    func doesNotChaseTheTty() {
        let verdict = ContinueDelivery.resolveTmux(
            recorded: armed, among: [TmuxScripting.Pane(id: "%9", tty: "/dev/ttys007")])
        #expect(verdict.refusal != nil)
    }
}

@Suite("tmux delivery ordering")
struct TmuxSendTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func note(_ call: String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(call)
        }
        var sequence: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private let pane = ContinueDelivery.TmuxTarget(paneId: "%3", tty: "/dev/ttys007")

    private func agent(pgid: Int32 = 5150, tpgid: Int32 = 5150, comm: String = "claude")
        -> ProcessIdentity
    {
        ProcessIdentity(
            pid: 5150, startedAt: Date(timeIntervalSince1970: 1_785_900_000), comm: comm,
            pgid: pgid, tpgid: tpgid, tty: "ttys007")
    }

    private func fire() -> ContinueScheduler.Fire {
        ContinueScheduler.Fire(
            sessionId: "s1", provider: "claude-code", message: "Continue", delay: 0,
            lateness: .onTime, target: nil, tmuxTarget: pane, agent: agent())
    }

    private func context(lastEvent: String? = "Stop") -> SendContext {
        SendContext(
            enabled: true, lastEvent: lastEvent, permissionMode: nil, liveAgent: agent())
    }

    private func ops(
        _ recorder: Recorder, panes: [TmuxScripting.Pane]? = nil,
        writeSucceeds: Bool = true, returnSucceeds: Bool = true
    ) -> TmuxOps {
        let live = panes ?? [TmuxScripting.Pane(id: "%3", tty: "/dev/ttys007")]
        return TmuxOps(
            panes: {
                recorder.note("panes")
                return .success(live)
            },
            writeText: { _, addressed in
                recorder.note("writeText@\(addressed)")
                return writeSucceeds
            },
            pressReturn: { addressed in
                recorder.note("pressReturn@\(addressed)")
                return returnSucceeds
            })
    }

    /// No Ghostty call may happen for a tmux session: it needs no Automation
    /// grant, and asking for one at fire time is the thing that must never occur.
    @Test("the happy path writes then presses Return, addressing one pane")
    func happyPath() {
        let recorder = Recorder()
        let result = ContinueSender.send(
            fire(), context: context(), ops: .ghostty, tmux: ops(recorder))
        #expect(result.outcome == .sent)
        #expect(recorder.sequence == ["panes", "writeText@%3", "pressReturn@%3"])
    }

    @Test("Return is never pressed if the text did not land")
    func returnNeverFollowsAFailedWrite() {
        let recorder = Recorder()
        let result = ContinueSender.send(
            fire(), context: context(), ops: .ghostty,
            tmux: ops(recorder, writeSucceeds: false))
        #expect(result.outcome == .failed)
        #expect(recorder.sequence.contains { $0.hasPrefix("pressReturn") } == false)
    }

    @Test("a typed but unsubmitted message says where it is")
    func failedReturnIsItsOwnOutcome() {
        let result = ContinueSender.send(
            fire(), context: context(), ops: .ghostty,
            tmux: ops(Recorder(), returnSucceeds: false))
        #expect(result.outcome == .failed)
        #expect(result.detail.contains("waiting on"))
    }

    @Test("every refusal happens before anything is written")
    func refusalsPrecedeWrites() {
        let cases: [(String, SendContext, [TmuxScripting.Pane])] = [
            ("not at a finished turn", context(lastEvent: "Notification"), []),
            ("pane closed", context(), [TmuxScripting.Pane(id: "%8", tty: "/dev/ttys001")]),
            (
                "pane id recycled",
                context(), [TmuxScripting.Pane(id: "%3", tty: "/dev/ttys099")]
            ),
        ]
        for (label, sendContext, panes) in cases {
            let recorder = Recorder()
            let result = ContinueSender.send(
                fire(), context: sendContext, ops: .ghostty,
                tmux: ops(recorder, panes: panes))
            #expect(result.outcome == .refused, "\(label) should refuse")
            #expect(result.detail.isEmpty == false, "\(label) gave no reason")
            #expect(
                recorder.sequence.contains { $0.hasPrefix("writeText") } == false,
                "\(label) wrote anyway")
        }
    }
}
