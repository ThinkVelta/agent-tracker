import Foundation

/// Renaming a session from the app, by asking Claude to do it.
///
/// The app does not keep a name of its own. It types `/rename <name>` into the
/// session's own pane and then reads the result back out of Claude's registry
/// like any other name — so Claude stays the single source of truth and the two
/// directions cannot disagree. A local nickname map would have meant two names
/// per session and a rule for what to do when they differ, which is a bug
/// waiting for a user who runs `/rename` in the terminal.
///
/// This is deliberately NOT `ContinueSender.send` with a different message.
/// That function is gated on the scheduled-continues kill switch and on the
/// session's permission mode, because it fires unattended on a timer. A rename
/// happens with the user's finger on it, so neither gate belongs — and widening
/// `ContinueSender` to express "sometimes these do not apply" would put a
/// feature that types into terminals unattended at risk to save twenty lines.
/// The primitives are shared; the policy is not.
enum SessionRename {
    /// What a rename can be turned down for, before anything is written.
    enum Refusal: Equatable {
        case emptyName
        case unchanged
        case unreachable(String)

        var reason: String {
            switch self {
            case .emptyName: return "A session name can't be empty"
            case .unchanged: return "That's already its name"
            case .unreachable(let detail): return detail
            }
        }
    }

    /// Collapses a typed name into the single line that will be sent.
    ///
    /// Newlines are the load-bearing part rather than tidiness: the channel
    /// writes the text and then presses Return, so an embedded newline would
    /// submit early and leave the remainder sitting in the user's session as a
    /// prompt. Anything a user can paste into the field has to come out of here
    /// as one line or as nil.
    ///
    /// - Returns: nil when nothing but whitespace was typed.
    static func sanitize(_ proposed: String) -> String? {
        let collapsed =
            proposed
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// The line to type. No length or character limit is imposed: Claude owns
    /// what a valid name is, and inventing a stricter rule here would refuse
    /// names it would have accepted.
    static func command(for name: String) -> String? {
        guard let clean = sanitize(name) else { return nil }
        return "/rename \(clean)"
    }

    /// Whether this rename is worth sending at all.
    static func check(proposed: String, current: String?) -> Refusal? {
        guard let clean = sanitize(proposed) else { return .emptyName }
        if let current, clean == current { return .unchanged }
        return nil
    }

    /// Writes the rename, or refuses and says why.
    ///
    /// Same order as every other write in this app: prove it, then write. The
    /// one gate carried over from scheduled continues is `lastEvent == "Stop"`,
    /// and it is not a nicety — pressing Return at an open permission prompt
    /// commits whichever option is focused, so a rename sent into a session
    /// sitting on a dialog would answer that dialog.
    static func deliver(
        command: String,
        resolved: SessionTarget.Resolved,
        lastEvent: String?,
        ops: ChannelOps,
        tmux: TmuxOps = .live
    ) -> ContinueDeliveryResult {
        guard lastEvent == "Stop" else {
            return .refused(
                "That session isn't sitting at a finished turn "
                    + "(\(lastEvent ?? "state unknown")), so typing into it could answer a prompt")
        }

        // The pane can be right while the process in it is not: an agent that
        // exited and had its pid reused would pass `kill(pid, 0)` and fail this.
        guard let live = resolved.agent else {
            return .refused("That session's process is gone")
        }
        if case .refused(let reason) = ContinueDelivery.foregroundAllows(
            pgid: live.pgid, tpgid: live.tpgid, comm: live.comm)
        {
            return .refused(reason)
        }

        if let pane = resolved.tmuxTarget {
            return sendToPane(command, recorded: pane, ops: tmux)
        }

        guard let target = resolved.target else {
            // The chicken-and-egg worth naming rather than hiding: outside tmux
            // a session is addressed by its window title, so the sessions the
            // app cannot reach are exactly the ones sharing a title with a
            // sibling — which is what renaming one of them would have fixed.
            // The in-terminal path has no such limit, so point at it.
            return .refused(
                (resolved.refusal ?? "Can't tell which window this session is in")
                    + ". Run /rename in that terminal instead")
        }

        guard ops.writeText(command, target.surfaceId, target.terminalPid) else {
            return ContinueDeliveryResult(
                outcome: .failed, detail: "Ghostty refused to write the rename")
        }
        guard ops.pressReturn(target.surfaceId, target.terminalPid) else {
            // Something IS in that window now, and the user needs to know it is
            // sitting there unsent rather than to be told this simply failed.
            return ContinueDeliveryResult(
                outcome: .failed,
                detail: "Typed \"\(command)\" but couldn't press Return — it's waiting on "
                    + "the prompt")
        }
        return ContinueDeliveryResult(outcome: .sent, detail: "Renaming…")
    }

    private static func sendToPane(
        _ command: String, recorded: ContinueDelivery.TmuxTarget, ops: TmuxOps
    ) -> ContinueDeliveryResult {
        let panes: [TmuxScripting.Pane]
        switch ops.panes(recorded.socketPath) {
        case .success(let live): panes = live
        case .failure(let failure): return .refused(failure.reason)
        }

        if case .refused(let reason) = ContinueDelivery.resolveTmux(
            recorded: recorded, among: panes)
        {
            return .refused(reason)
        }

        guard ops.writeText(command, recorded.paneId, recorded.socketPath) else {
            return ContinueDeliveryResult(
                outcome: .failed, detail: "tmux refused to write the rename")
        }
        guard ops.pressReturn(recorded.paneId, recorded.socketPath) else {
            return ContinueDeliveryResult(
                outcome: .failed,
                detail: "Typed \"\(command)\" but couldn't press Return — it's waiting on "
                    + "the prompt")
        }
        return ContinueDeliveryResult(outcome: .sent, detail: "Renaming…")
    }
}
