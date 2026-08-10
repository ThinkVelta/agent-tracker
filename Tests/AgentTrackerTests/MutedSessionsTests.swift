import Foundation
import Testing

@testable import AgentTracker

@MainActor
final class MutedSessionsTests {
    private var suiteNames: [String] = []

    deinit {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    /// Its own suite, like PreferencesTests: the real domain is never touched.
    private func defaults() -> UserDefaults {
        let name = "agent-tracker-muted-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    @Test func mutingRoundTripsThroughStorage() {
        let store = defaults()
        MutedSessions(defaults: store).toggle("claude-code-s1")
        #expect(MutedSessions(defaults: store).isMuted("claude-code-s1"))
    }

    @Test func togglingTwiceLeavesNothingBehind() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("claude-code-s1")
        muted.toggle("claude-code-s1")
        #expect(muted.isMuted("claude-code-s1") == false)
        #expect(muted.muted.isEmpty)
    }

    /// A mute belongs to one session, not to a project or a provider.
    @Test func mutingOneSessionLeavesItsNeighboursAlone() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("claude-code-s1")
        #expect(muted.isMuted("codex-s1") == false)
        #expect(muted.isMuted("claude-code-s2") == false)
    }

    /// 2026-08-10T09:00:00Z. Absolute, so nothing here depends on a real clock.
    private let start = Date(timeIntervalSince1970: 1_786_705_200)

    private func later(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// A session id belongs to one run, so a mute cannot outlive it.
    @Test func aMuteIsDroppedOnceItsSessionEnds() {
        let store = defaults()
        let muted = MutedSessions(defaults: store)
        muted.toggle("claude-code-s1")

        muted.reconcile(liveKeys: ["claude-code-s1"], now: start)
        #expect(muted.isMuted("claude-code-s1"))

        muted.reconcile(liveKeys: [], now: later(1))
        muted.reconcile(liveKeys: [], now: later(MutedSessions.graceBeforeForgetting + 1))
        #expect(muted.isMuted("claude-code-s1") == false)
        // Persisted, not just forgotten in memory.
        #expect(MutedSessions(defaults: store).isMuted("claude-code-s1") == false)
    }

    /// The bug the grace exists for. The Codex scanner publishes its first rows
    /// a beat AFTER launch, so dropping a key the moment it is not in the live
    /// set would delete every Codex mute in the gap — before the row it belongs
    /// to had ever appeared, and with nothing on screen to explain it.
    @Test func aMuteSurvivesASourceThatHasNotReportedYet() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("codex-s1")

        // Passes before the scanner has published anything.
        for second in 0..<4 {
            muted.reconcile(liveKeys: ["claude-code-s1"], now: later(Double(second)))
            #expect(muted.isMuted("codex-s1"))
        }

        // It arrives well inside the grace, and is still muted.
        muted.reconcile(liveKeys: ["claude-code-s1", "codex-s1"], now: later(5))
        #expect(muted.isMuted("codex-s1"))

        // Having come back, it starts counting again from scratch rather than
        // from when it was first missed — otherwise a session that appeared
        // late would be forgotten early.
        muted.reconcile(
            liveKeys: ["claude-code-s1"], now: later(MutedSessions.graceBeforeForgetting))
        #expect(muted.isMuted("codex-s1"))
    }

    /// The one the reviewer found, and the version of it I had wrong: the old
    /// rule only dropped keys it had watched leave, so a session that ended
    /// while the app was closed was never seen leaving and its mute was kept
    /// for ever. A fresh process starts timing at its first pass, so an
    /// already-gone session is forgotten a grace later.
    @Test func aMuteWhoseSessionEndedWhileClosedIsForgottenToo() {
        let store = defaults()
        MutedSessions(defaults: store).toggle("claude-code-s1")

        // A new process: nothing in memory, and the session never appears.
        let restarted = MutedSessions(defaults: store)
        #expect(restarted.isMuted("claude-code-s1"))
        restarted.reconcile(liveKeys: [], now: start)
        #expect(restarted.isMuted("claude-code-s1"))

        restarted.reconcile(liveKeys: [], now: later(MutedSessions.graceBeforeForgetting))
        #expect(restarted.isMuted("claude-code-s1") == false)
        #expect(MutedSessions(defaults: store).muted.isEmpty)
    }

    /// `reconcile` runs on every store pass, roughly once a second. Publishing
    /// an unchanged set would redraw the whole dropdown at that rate.
    @Test func aQuietPassChangesNothing() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("claude-code-s1")
        var publishes = 0
        let subscription = muted.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        for second in 0..<10 {
            muted.reconcile(liveKeys: ["claude-code-s1"], now: later(Double(second)))
        }
        #expect(publishes == 0)

        // Still nothing while it is merely absent.
        muted.reconcile(liveKeys: [], now: later(10))
        #expect(publishes == 0)

        muted.reconcile(liveKeys: [], now: later(MutedSessions.graceBeforeForgetting + 10))
        #expect(publishes == 1)
    }

    /// Unmuting has to take the bookkeeping with it, or the map that records
    /// what is missing outgrows the set it describes.
    @Test func unmutingForgetsItsAbsenceToo() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("claude-code-s1")
        muted.reconcile(liveKeys: [], now: start)
        muted.toggle("claude-code-s1")

        muted.toggle("claude-code-s1")
        // Re-muted after the original grace would have expired: it must get a
        // fresh one rather than inherit the old absence.
        muted.reconcile(liveKeys: [], now: later(MutedSessions.graceBeforeForgetting + 1))
        #expect(muted.isMuted("claude-code-s1"))
    }

    /// Pasted into a shell, so a provider this version does not know gets
    /// nothing rather than a guessed incantation. Both of these were read off
    /// the shipping CLIs rather than remembered.
    @Test func resumeCommandsMatchTheCLIs() {
        var session = AgentSession(
            provider: "claude-code", sessionId: "6b1f2c30-77aa-4d1e-9c55-2f0e8a1b4d77",
            state: .idle)
        #expect(session.resumeCommand == "claude --resume 6b1f2c30-77aa-4d1e-9c55-2f0e8a1b4d77")
        session.provider = "codex"
        #expect(session.resumeCommand == "codex resume 6b1f2c30-77aa-4d1e-9c55-2f0e8a1b4d77")
        session.provider = "kimi"
        #expect(session.resumeCommand == nil)
    }

    /// This lands on the clipboard and is pasted into a shell. Both providers
    /// issue UUIDs today, so quoting is defence against someone else's format
    /// changing rather than against anything observed — which is exactly the
    /// kind of assumption worth not betting a command injection on.
    @Test func anIdIsQuotedOnlyWhenItHasToBe() {
        // The real case stays clean, which is the point of offering a command
        // someone is meant to read before running.
        #expect(AgentSession.shellArgument("6b1f2c30-77aa-4d1e") == "6b1f2c30-77aa-4d1e")
        #expect(AgentSession.shellArgument("a.b_c/d") == "a.b_c/d")

        #expect(AgentSession.shellArgument("two words") == "'two words'")
        #expect(AgentSession.shellArgument("") == "''")
        #expect(AgentSession.shellArgument("a;rm -rf /") == "'a;rm -rf /'")
        #expect(AgentSession.shellArgument("$(whoami)") == "'$(whoami)'")
        // The one thing single quotes cannot hold: close, escape, reopen.
        #expect(AgentSession.shellArgument("it's") == #"'it'\''s'"#)
    }

    @Test func aResumeCommandCarriesTheQuotingThrough() {
        let session = AgentSession(
            provider: "claude-code", sessionId: "a b; echo hi", state: .idle)
        #expect(session.resumeCommand == "claude --resume 'a b; echo hi'")
    }
}
