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

    /// A session id belongs to one run, so a mute cannot outlive it.
    @Test func aMuteIsDroppedOnceItsSessionEnds() {
        let store = defaults()
        let muted = MutedSessions(defaults: store)
        muted.toggle("claude-code-s1")

        muted.reconcile(liveKeys: ["claude-code-s1"])
        #expect(muted.isMuted("claude-code-s1"))

        muted.reconcile(liveKeys: [])
        #expect(muted.isMuted("claude-code-s1") == false)
        // Persisted, not just forgotten in memory.
        #expect(MutedSessions(defaults: store).isMuted("claude-code-s1") == false)
    }

    /// The bug this rule exists for. The Codex scanner publishes its first rows
    /// a beat AFTER launch, so a plain intersection with the live set would
    /// delete every Codex mute in the gap — before the row it belongs to had
    /// ever appeared, and with nothing on screen to explain it.
    @Test func aMuteSurvivesUntilItsSessionHasBeenSeen() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("codex-s1")

        // Several passes before the scanner has published anything.
        for _ in 0..<3 {
            muted.reconcile(liveKeys: ["claude-code-s1"])
            #expect(muted.isMuted("codex-s1"))
        }

        // It arrives, and is still muted.
        muted.reconcile(liveKeys: ["claude-code-s1", "codex-s1"])
        #expect(muted.isMuted("codex-s1"))

        // Now that it has been seen, leaving means ended.
        muted.reconcile(liveKeys: ["claude-code-s1"])
        #expect(muted.isMuted("codex-s1") == false)
    }

    /// `reconcile` runs on every store pass, roughly once a second. Publishing
    /// an unchanged set would redraw the whole dropdown at that rate.
    @Test func aQuietPassChangesNothing() {
        let muted = MutedSessions(defaults: defaults())
        muted.toggle("claude-code-s1")
        var publishes = 0
        let subscription = muted.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        for _ in 0..<10 { muted.reconcile(liveKeys: ["claude-code-s1"]) }
        #expect(publishes == 0)

        muted.reconcile(liveKeys: [])
        #expect(publishes == 1)
    }

    /// Pasted into a shell, so a provider this version does not know gets
    /// nothing rather than a guessed incantation. Both of these were read off
    /// the shipping CLIs rather than remembered.
    @Test func resumeCommandsMatchTheCLIs() {
        var claude = AgentSession(provider: "claude-code", sessionId: "abc", state: .idle)
        #expect(claude.resumeCommand == "claude --resume abc")
        claude.provider = "codex"
        #expect(claude.resumeCommand == "codex resume abc")
        claude.provider = "kimi"
        #expect(claude.resumeCommand == nil)
    }
}
