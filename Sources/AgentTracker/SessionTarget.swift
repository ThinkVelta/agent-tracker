import Foundation

/// Where a session's terminal is, resolved live when the user renames.
///
/// The ordering below is the subtle part — tmux is checked *before* Ghostty
/// rather than as a fallback after it, because a tmux pane needs no macOS
/// permission and nothing matched by title, so trying Ghostty first would raise
/// an Automation prompt for a session that never needed one.
enum SessionTarget {
    struct Resolved: Sendable {
        var target: TerminalDelivery.Target?
        var tmuxTarget: TerminalDelivery.TmuxTarget?
        var agent: ProcessIdentity?
        var refusal: String?

        /// Whether anything can be written to this session at all.
        var isAddressable: Bool { target != nil || tmuxTarget != nil }
    }

    /// Off the main actor: the Automation preflight was measured taking over 100
    /// seconds for a running-but-ungranted target.
    ///
    /// - Parameter promptIfNeeded: whether Ghostty may raise the Automation
    ///   permission dialog. True only where the user is present and has just
    ///   asked for this — never on a timer, where a prompt would sit unanswered
    ///   while the delivery it was meant to authorise waited on it.
    static func resolve(
        for sessionId: String, expectedTitle: String?, promptIfNeeded: Bool
    ) async -> Resolved {
        await Task.detached { () -> Resolved in
            let session = SessionStore.loadSessionFromDisk(sessionId: sessionId)
            let agent = session?.pid.map { ProcessIdentity.read(pid: Int32($0)) } ?? nil

            // A session inside tmux knows exactly where it is: the hook recorded
            // its pane id and tty from the session's own environment. Nothing to
            // resolve, nothing to match by title, and no macOS permission needed
            // — which is why this is checked before the Ghostty path rather than
            // as a fallback after it.
            if let terminal = session?.terminal, let paneId = terminal.tmuxPane,
                let tty = terminal.tty
            {
                return Resolved(
                    tmuxTarget: TerminalDelivery.TmuxTarget(
                        paneId: paneId, tty: tty,
                        socketPath: TmuxScripting.socketPath(fromTmuxVariable: terminal.tmux)),
                    agent: agent)
            }

            guard let terminalPid = GhosttyScripting.runningApplication()?.processIdentifier else {
                return Resolved(agent: agent, refusal: GhosttyScripting.Failure.notRunning.reason)
            }
            switch GhosttyScripting.surfaces(pid: terminalPid, promptIfNeeded: promptIfNeeded) {
            case .failure(let failure):
                return Resolved(agent: agent, refusal: failure.reason)
            case .success(let surfaces):
                let resolution = TerminalDelivery.resolve(
                    expectedTitle: expectedTitle, among: surfaces, terminalPid: terminalPid)
                return Resolved(
                    target: resolution.target, agent: agent, refusal: resolution.refusal)
            }
        }.value
    }
}
