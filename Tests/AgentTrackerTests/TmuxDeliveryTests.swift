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
    private let armed = TerminalDelivery.TmuxTarget(
        paneId: "%3", tty: "/dev/ttys007", socketPath: nil)

    @Test("the pane it was armed in, unchanged, is allowed")
    func unchangedPaneIsAllowed() {
        let verdict = TerminalDelivery.resolveTmux(
            recorded: armed,
            among: [
                TmuxScripting.Pane(id: "%2", tty: "/dev/ttys006"),
                TmuxScripting.Pane(id: "%3", tty: "/dev/ttys007"),
            ])
        #expect(verdict == .allowed)
    }

    @Test("a closed pane refuses")
    func missingPaneRefuses() {
        let verdict = TerminalDelivery.resolveTmux(
            recorded: armed, among: [TmuxScripting.Pane(id: "%2", tty: "/dev/ttys006")])
        #expect(verdict.refusal?.contains("gone") == true)
    }

    /// The case the tty exists to catch: a tmux server restarted overnight mints
    /// ids from %0 again, so the id alone can resolve to a stranger's pane.
    @Test("a recycled pane id with a different terminal refuses")
    func recycledPaneIdRefuses() {
        let verdict = TerminalDelivery.resolveTmux(
            recorded: armed, among: [TmuxScripting.Pane(id: "%3", tty: "/dev/ttys099")])
        #expect(verdict.refusal?.contains("different terminal") == true)
    }

    /// Not "find the pane whose tty matches" — that would follow a session into a
    /// pane it was never armed against.
    @Test("the right tty under a different pane id is not accepted")
    func doesNotChaseTheTty() {
        let verdict = TerminalDelivery.resolveTmux(
            recorded: armed, among: [TmuxScripting.Pane(id: "%9", tty: "/dev/ttys007")])
        #expect(verdict.refusal != nil)
    }
}
