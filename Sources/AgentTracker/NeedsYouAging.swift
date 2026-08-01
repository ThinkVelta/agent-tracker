import Foundation

/// Ages a stale needs-you session down to idle.
///
/// Without this, nothing ever reaches idle on its own: a completed Codex turn
/// derives `needsYou` forever, and a Claude `Stop` hook does the same, so the
/// only exit was an acknowledgement — which the auto-acknowledger refuses to
/// give when two same-repo sessions share a window title. Sessions that had
/// been waiting for hours still showed red.
///
/// The red dot means "act on this now". After long enough untouched it is no
/// longer news, just an open session — which is exactly what idle means here.
/// Pure, so the boundary conditions are testable.
enum NeedsYouAging {
    /// - Parameter fadeAfter: seconds a session may sit in needs-you before it
    ///   reads as idle; 0 (or less) disables aging entirely.
    static func apply(
        to session: AgentSession, now: Date, fadeAfter: TimeInterval
    ) -> AgentSession {
        guard fadeAfter > 0, session.state == .needsYou,
            let since = session.stateChangedAt,
            now.timeIntervalSince(since) >= fadeAfter
        else { return session }
        var aged = session
        aged.state = .idle
        // Says what happened, so an aged row is never confused with a session
        // that genuinely has nothing to report.
        aged.reason = "Waiting — no longer new"
        return aged
    }
}
