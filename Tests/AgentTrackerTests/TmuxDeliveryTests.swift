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

    /// `$TMUX` is `<socket-path>,<server-pid>,<session-id>`. The socket is what
    /// says *which server*, and a named one (`tmux -L work`) has its own pane-id
    /// namespace — so getting this wrong means addressing a different server.
    @Test("the server socket is read out of the TMUX variable")
    func readsSocketPath() {
        #expect(
            TmuxScripting.socketPath(fromTmuxVariable: "/private/tmp/tmux-501/default,91694,0")
                == "/private/tmp/tmux-501/default")
        #expect(
            TmuxScripting.socketPath(fromTmuxVariable: "/private/tmp/tmux-501/work,4,2")
                == "/private/tmp/tmux-501/work")
    }

    /// Absent means "tmux's default socket", which is what a call with no `-S`
    /// already does — so anything unparseable must read as nil, not as a path.
    @Test("a TMUX value that is not a socket path reads as absent")
    func rejectsNonPaths() {
        #expect(TmuxScripting.socketPath(fromTmuxVariable: nil) == nil)
        #expect(TmuxScripting.socketPath(fromTmuxVariable: "") == nil)
        #expect(TmuxScripting.socketPath(fromTmuxVariable: ",91694,0") == nil)
        #expect(TmuxScripting.socketPath(fromTmuxVariable: "relative/path,1,0") == nil)
    }

    /// Documented, not defended: `$TMUX` is comma-separated with no escaping, so
    /// a socket path containing a comma is ambiguous in the variable itself and
    /// this reads the first field. Recorded so the truncation is a known shape
    /// rather than a surprise — and the pane resolution behind it refuses on a
    /// mismatch, so the outcome is a refusal, never a misdirected send.
    @Test("a comma inside the socket path truncates, and that is the format's fault")
    func commaInPathTruncates() {
        #expect(
            TmuxScripting.socketPath(fromTmuxVariable: "/tmp/odd,name/sock,91694,0")
                == "/tmp/odd")
    }
}

@Suite("tmux pane resolution")
struct TmuxResolutionTests {
    private let armed = ContinueDelivery.TmuxTarget(
        paneId: "%3", tty: "/dev/ttys007", socketPath: nil)

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

    private let socket = "/private/tmp/tmux-501/work"
    private var pane: ContinueDelivery.TmuxTarget {
        ContinueDelivery.TmuxTarget(paneId: "%3", tty: "/dev/ttys007", socketPath: socket)
    }

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
            panes: { socket in
                recorder.note("panes@\(socket ?? "default")")
                return .success(live)
            },
            writeText: { _, addressed, socket in
                recorder.note("writeText@\(addressed)@\(socket ?? "default")")
                return writeSucceeds
            },
            pressReturn: { addressed, socket in
                recorder.note("pressReturn@\(addressed)@\(socket ?? "default")")
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
        // Every call carries the same socket. A tmux server started with -L or
        // -S has its own pane-id namespace, so a call without it would address
        // the default server — a different machine entirely, as far as %3 goes.
        #expect(
            recorder.sequence == [
                "panes@\(socket)", "writeText@%3@\(socket)", "pressReturn@%3@\(socket)",
            ])
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
