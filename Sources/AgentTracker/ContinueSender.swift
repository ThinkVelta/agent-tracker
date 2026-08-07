import Foundation

struct ContinueDeliveryResult: Equatable, Sendable {
    var outcome: ContinueReceipt.Outcome
    var detail: String

    static func refused(_ reason: String) -> ContinueDeliveryResult {
        ContinueDeliveryResult(outcome: .refused, detail: reason)
    }
}

/// The channel's two writes and two reads, as closures.
///
/// Injectable so the call **sequence** can be tested with nothing that can reach
/// a terminal — the property that matters most here is that Return is never sent
/// unless the text write already succeeded, and that is a property of the order,
/// not of either call.
///
/// Closures rather than a protocol, matching how this repo injects everywhere
/// else (`DirectoryWatcher(url:) { }`, `ContinueSchedules.deliver`).
struct ChannelOps: Sendable {
    /// Sampled ONCE per delivery. Everything below is addressed to this exact
    /// process: if each step rediscovered the app for itself, verification could
    /// pass against one instance and the write land in another — which is the
    /// type-into-a-stranger's-pane failure the whole design exists to prevent.
    var terminalPid: @Sendable () -> Int32?
    var surfaces:
        @Sendable (_ pid: Int32) -> Result<
            [ContinueDelivery.Surface], GhosttyScripting.Failure
        >
    var writeText: @Sendable (_ text: String, _ surfaceId: String, _ pid: Int32) -> Bool
    var pressReturn: @Sendable (_ surfaceId: String, _ pid: Int32) -> Bool

    static let ghostty = ChannelOps(
        terminalPid: { GhosttyScripting.runningApplication()?.processIdentifier },
        surfaces: { GhosttyScripting.surfaces(pid: $0) },
        writeText: { GhosttyScripting.writeText($0, toSurface: $1, pid: $2) },
        pressReturn: { GhosttyScripting.pressReturn(inSurface: $0, pid: $1) }
    )
}

/// Everything delivery re-reads at fire time instead of trusting the plan.
///
/// The plan was made when the schedule came due, and the fires in one fan-out are
/// twenty seconds apart — so by the time the third one runs, "the session had
/// finished its turn" is a claim about the past. Each of these is read again
/// immediately before writing.
struct SendContext: Sendable {
    /// The kill switch, re-read rather than taken from the pass that planned this.
    var enabled: Bool
    /// From the session's state file on disk, not from the planner's copy.
    var lastEvent: String?
    var permissionMode: String?
    /// The agent as it is right now.
    var liveAgent: ProcessIdentity?
}

/// Performs a delivery, or refuses and says why.
///
/// Every refusal is a success. The one unrecoverable outcome in this feature is
/// typing into a session that is not the one the user armed, so the order below
/// is deliberately "prove it, then write" and never "write, then check".
enum ContinueSender {
    static func send(
        _ fire: ContinueScheduler.Fire, context: SendContext, ops: ChannelOps
    ) -> ContinueDeliveryResult {
        guard context.enabled else {
            return .refused("Scheduled continues were turned off before this could send")
        }

        if case .refused(let reason) = ContinueDelivery.permissionModeAllows(context.permissionMode)
        {
            return .refused(reason)
        }

        // R1, re-checked against disk. Return at an open permission prompt commits
        // the focused option, and a dialog can have opened in the seconds since
        // the plan was made.
        guard context.lastEvent == "Stop" else {
            return .refused(
                "The session isn't sitting at a finished turn any more "
                    + "(\(context.lastEvent ?? "state unknown"))")
        }

        guard let recorded = fire.target else {
            return .refused("No terminal window was recorded when this was scheduled")
        }
        guard let terminalPid = ops.terminalPid() else {
            return .refused(GhosttyScripting.Failure.notRunning.reason)
        }

        let surfaces: [ContinueDelivery.Surface]
        switch ops.surfaces(terminalPid) {
        case .success(let live): surfaces = live
        case .failure(let failure): return .refused(failure.reason)
        }

        let resolution = ContinueDelivery.verify(
            recorded: recorded, among: surfaces, terminalPid: terminalPid)
        guard case .ready(let target) = resolution else {
            return .refused(resolution.refusal ?? "The recorded window no longer matches")
        }

        // The pane can be right while the process in it is not: an agent that
        // exited and had its pid reused would pass `kill(pid, 0)` and fail this.
        guard let live = context.liveAgent else {
            return .refused("That session's process is gone")
        }
        if let armed = fire.agent, !armed.isSameProcess(as: live) {
            return .refused("A different process is in that window now")
        }
        if case .refused(let reason) = ContinueDelivery.foregroundAllows(
            pgid: live.pgid, tpgid: live.tpgid, comm: live.comm)
        {
            return .refused(reason)
        }

        // Everything has agreed. Write the text, and ONLY on success press Return.
        guard ops.writeText(fire.message, target.surfaceId, terminalPid) else {
            return ContinueDeliveryResult(
                outcome: .failed, detail: "Ghostty refused to write the message")
        }
        guard ops.pressReturn(target.surfaceId, terminalPid) else {
            // The message is sitting on the prompt, unsent. Saying "failed" here
            // would be wrong in the other direction: something IS in that window
            // and the user needs to know it is there.
            return ContinueDeliveryResult(
                outcome: .failed,
                detail: "Typed \"\(fire.message)\" but couldn't press Return — it's waiting on "
                    + "the prompt")
        }
        return ContinueDeliveryResult(outcome: .sent, detail: "Sent \"\(fire.message)\"")
    }

    /// The last permission mode a session recorded.
    ///
    /// Claude writes `permissionMode` into its transcript when the mode is set or
    /// changed, so most sessions have none and absent means "not set", never
    /// "unknown". Bounded tail read: a transcript can be tens of megabytes, and
    /// only the newest value matters.
    static func permissionMode(inTranscriptAt path: String, tail: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd(),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        var mode: String?
        for line in text.split(separator: "\n") {
            guard line.contains("permissionMode") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let entry = object as? [String: Any],
                let value = entry["permissionMode"] as? String, !value.isEmpty
            else { continue }
            mode = value
        }
        return mode
    }
}
