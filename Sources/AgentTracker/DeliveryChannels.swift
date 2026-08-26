import Foundation

/// What a write into a terminal came to.
struct DeliveryResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The message was written into the pane.
        case sent
        /// A gate said no. The common case, and not a malfunction.
        case refused
        /// Everything agreed it should be sent, and sending failed anyway.
        case failed
    }

    var outcome: Outcome
    var detail: String

    static func refused(_ reason: String) -> DeliveryResult {
        DeliveryResult(outcome: .refused, detail: reason)
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
/// else (`DirectoryWatcher(url:) { }`).
struct ChannelOps: Sendable {
    /// Sampled ONCE per delivery. Everything below is addressed to this exact
    /// process: if each step rediscovered the app for itself, verification could
    /// pass against one instance and the write land in another — which is the
    /// type-into-a-stranger's-pane failure the whole design exists to prevent.
    var terminalPid: @Sendable () -> Int32?
    var surfaces:
        @Sendable (_ pid: Int32) -> Result<
            [TerminalDelivery.Surface], GhosttyScripting.Failure
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

/// The tmux channel's one read and two writes.
///
/// No `terminalPid` equivalent, and that absence is the point. Ghostty has to
/// sample one process and address every call to it, because each AppleScript
/// call would otherwise rediscover the app and could land in a different
/// instance. A tmux pane id is addressed to the server that owns it, and the
/// tty pinned alongside it says whether it is still the same pane.
struct TmuxOps: Sendable {
    var panes:
        @Sendable (_ socketPath: String?) -> Result<
            [TmuxScripting.Pane], TmuxScripting.Failure
        >
    var writeText: @Sendable (_ text: String, _ pane: String, _ socketPath: String?) -> Bool
    var pressReturn: @Sendable (_ pane: String, _ socketPath: String?) -> Bool

    static let live = TmuxOps(
        panes: { TmuxScripting.panes(socketPath: $0) },
        writeText: { TmuxScripting.writeText($0, toPane: $1, socketPath: $2) },
        pressReturn: { TmuxScripting.pressReturn(inPane: $0, socketPath: $1) }
    )
}
