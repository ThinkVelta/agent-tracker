import Foundation
import Testing

@testable import AgentTracker

@Suite("Attention notifications")
struct AttentionNotifierTests {
    /// 2026-08-09T09:00:00Z, taken as the moment the app started watching.
    private let launch = Date(timeIntervalSince1970: 1_786_618_800)

    private func session(
        _ id: String = "s1",
        provider: String = "claude-code",
        state: SessionState = .needsYou,
        cwd: String = "/Users/dev/demo",
        reason: String? = nil,
        changedAt: TimeInterval = 60
    ) -> AgentSession {
        var session = AgentSession(
            provider: provider, sessionId: id, cwd: cwd, state: state)
        session.reason = reason
        session.stateChangedAt = launch.addingTimeInterval(changedAt)
        return session
    }

    /// The app starts with whatever is already on screen. Announcing that would
    /// be a burst of banners for sessions the user walked away from hours ago.
    @Test("sessions that were already red when the app started are not announced")
    func alreadyRedIsNotNews() {
        var tracker = AttentionTracker(since: launch)
        let changes = tracker.update(with: [
            session(changedAt: -3600), session("s2", changedAt: -30),
        ])
        #expect(changes.isEmpty)
    }

    /// Not the same rule as "skip the first pass": the Codex scanner publishes
    /// its first results a beat after launch, so an already-red Codex session
    /// arrives on the *second* pass and would slip a first-pass baseline.
    @Test("an already-red session arriving late is still not announced")
    func lateArrivalOfAnOldRedIsNotNews() {
        var tracker = AttentionTracker(since: launch)
        _ = tracker.update(with: [session(changedAt: -3600)])
        let changes = tracker.update(with: [
            session(changedAt: -3600), session("codex1", provider: "codex", changedAt: -900),
        ])
        #expect(changes.isEmpty)
    }

    @Test("a session turning needs-you is announced once, not once per pass")
    func announcedOnFlipOnly() {
        var tracker = AttentionTracker(since: launch)
        _ = tracker.update(with: [session(state: .running)])

        let flip = tracker.update(with: [session(reason: "Approve Bash?")])
        #expect(flip.began.map(\.sessionKey) == ["claude-code-s1"])

        // The store republishes on every hook event and every timer tick, and
        // the session stays red until someone acknowledges it.
        for _ in 0..<5 {
            #expect(tracker.update(with: [session(reason: "Approve Bash?")]).isEmpty)
        }
    }

    /// A needs-you row can change what it is asking for without ceasing to ask.
    /// Re-announcing on that would turn one approval prompt into a stream.
    @Test("a changed reason is not a new alert")
    func reasonChangesDoNotReannounce() {
        var tracker = AttentionTracker(since: launch)
        _ = tracker.update(with: [session(state: .running)])
        _ = tracker.update(with: [session(reason: "Approve Bash?")])
        let changes = tracker.update(with: [session(reason: "Approve Edit?", changedAt: 90)])
        #expect(changes.isEmpty)
    }

    @Test("acknowledging a session ends its alert, and it can ask again after")
    func acknowledgeEndsThenReopens() {
        var tracker = AttentionTracker(since: launch)
        _ = tracker.update(with: [session(state: .running)])
        _ = tracker.update(with: [session()])

        let acknowledged = tracker.update(with: [session(state: .idle)])
        #expect(acknowledged.began.isEmpty)
        #expect(acknowledged.ended == ["claude-code-s1"])

        let again = tracker.update(with: [session(changedAt: 300)])
        #expect(again.began.map(\.sessionKey) == ["claude-code-s1"])
    }

    /// A session whose terminal was closed vanishes from the list entirely. Its
    /// banner has to go with it, or Notification Center keeps a prompt for a
    /// session that no longer exists.
    @Test("a session that disappears ends its alert too")
    func vanishedSessionEnds() {
        var tracker = AttentionTracker(since: launch)
        _ = tracker.update(with: [session()])
        #expect(tracker.update(with: []).ended == ["claude-code-s1"])
    }

    /// The row identity everything else keys on is provider-qualified, so this
    /// must be too, or one provider's session would silence the other's.
    @Test("alerts are keyed by row identity, not by session id alone")
    func keyedByRowIdentity() {
        var tracker = AttentionTracker(since: launch)
        _ = tracker.update(with: [
            session(state: .running), session(provider: "codex", state: .running),
        ])
        let changes = tracker.update(with: [session(), session(provider: "codex")])
        #expect(changes.began.map(\.sessionKey) == ["claude-code-s1", "codex-s1"])
    }

    @Test("the banner says what the row says")
    func alertMirrorsTheRow() {
        let alert = AttentionAlert(
            session: session(cwd: "/Users/dev/work/demo", reason: "Approve Bash?"))
        #expect(alert.title == "demo")
        #expect(alert.subtitle == "Claude · work")
        #expect(alert.body == "Approve Bash?")
    }

    /// The hook always writes a reason, but a state file written by an older
    /// build might not, and an empty banner body reads as a bug.
    @Test("a session with no reason still says something")
    func bodyFallsBackToTheStateLabel() {
        #expect(AttentionAlert(session: session()).body == SessionState.needsYou.label)
    }

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle
    /// identifier, which is what this test runner is. Reaching it here would
    /// abort the whole run rather than fail a case.
    @Test("posting and withdrawing are safe where there is no bundle")
    func safeWithoutABundle() async {
        guard !Notifications.isAvailable else { return }
        await AttentionNotifier.post(AttentionAlert(session: session()))
        AttentionNotifier.withdraw(["claude-code-s1"])
        AttentionNotifier.withdraw([])
    }
}
