import Foundation
import Testing

@testable import AgentTracker

final class NeedsYouAgingTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func session(
        state: SessionState = .needsYou, ageSeconds: TimeInterval? = 0
    ) -> AgentSession {
        AgentSession(
            provider: "codex", sessionId: "s1", cwd: "/Users/dev/planner", state: state,
            reason: "Turn complete — ready for you",
            stateChangedAt: ageSeconds.map { now.addingTimeInterval(-$0) })
    }

    @Test func aStaleNeedsYouFadesToIdle() {
        let aged = NeedsYouAging.apply(
            to: session(ageSeconds: 1801), now: now, fadeAfter: 1800)
        #expect(aged.state == .idle)
        // Says what happened — an aged row must not read as "nothing to report".
        #expect(aged.reason == "Waiting — no longer new")
    }

    @Test func theBoundaryFades() {
        #expect(
            NeedsYouAging.apply(to: session(ageSeconds: 1800), now: now, fadeAfter: 1800).state
                == .idle)
        #expect(
            NeedsYouAging.apply(to: session(ageSeconds: 1799), now: now, fadeAfter: 1800).state
                == .needsYou)
    }

    /// Never means never, no matter how long it has waited.
    @Test func zeroDisablesAging() {
        for fade in [0.0, -1] {
            let aged = NeedsYouAging.apply(
                to: session(ageSeconds: 86400), now: now, fadeAfter: fade)
            #expect(aged.state == .needsYou, "fade \(fade) must not age")
        }
    }

    /// Only the red state ages; running and idle are untouched, and a row
    /// whose reason the aging would overwrite keeps it.
    @Test func onlyNeedsYouAges() {
        for state in [SessionState.running, .idle] {
            let untouched = NeedsYouAging.apply(
                to: session(state: state, ageSeconds: 99999), now: now, fadeAfter: 1800)
            #expect(untouched.state == state)
            #expect(untouched.reason == "Turn complete — ready for you")
        }
    }

    /// No timestamp means no way to know how long it has waited — leave it red
    /// rather than fade a session that might have just arrived.
    @Test func anUndatedRowNeverFades() {
        let undated = NeedsYouAging.apply(
            to: session(ageSeconds: nil), now: now, fadeAfter: 1800)
        #expect(undated.state == .needsYou)
    }

    /// Aging is derived per rebuild, never persisted: a fresh event resets
    /// stateChangedAt and the row goes red again immediately.
    @Test func freshActivityUndoesTheFade() {
        let stale = session(ageSeconds: 7200)
        #expect(NeedsYouAging.apply(to: stale, now: now, fadeAfter: 1800).state == .idle)
        var revived = stale
        revived.stateChangedAt = now
        #expect(NeedsYouAging.apply(to: revived, now: now, fadeAfter: 1800).state == .needsYou)
    }
}
