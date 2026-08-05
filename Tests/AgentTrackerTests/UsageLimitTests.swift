import Foundation
import Testing

@testable import AgentTracker

final class UsageLimitTests {
    private let reset = Date(timeIntervalSince1970: 1_786_177_907)

    private func limit(
        _ window: UsageLimit.Window = .weekly,
        used: Double? = 100,
        resetsAt: Date?,
        reached: Bool = true
    ) -> UsageLimit {
        UsageLimit(window: window, usedPercent: used, resetsAt: resetsAt, isReached: reached)
    }

    private func session(
        provider: String = "codex",
        state: SessionState = .needsYou,
        lastEvent: String? = "task_complete",
        reason: String? = "Turn complete — ready for you"
    ) -> AgentSession {
        var session = AgentSession(
            provider: provider, sessionId: "s1", cwd: "/Users/dev/demo", state: state)
        session.lastEvent = lastEvent
        session.reason = reason
        return session
    }

    // MARK: - The account slot

    /// One slot per provider per window. The evidence arrives in whichever
    /// session hit the wall, but every session of that account is blocked, so
    /// the reading cannot live on a row.
    @Test func aReadingIsKeptPerProviderAndWindow() {
        var limits = AccountLimits()
        limits.record(limit(.weekly, resetsAt: reset), for: "codex")
        limits.record(limit(.fiveHour, used: 50, resetsAt: reset, reached: false), for: "codex")
        limits.record(limit(.fiveHour, resetsAt: reset), for: "claude-code")

        #expect(limits.limits(for: "codex").count == 2)
        #expect(limits.limits(for: "claude-code").count == 1)
        #expect(limits.limits(for: "unknown").isEmpty)
        // Providers do not bleed into each other.
        #expect(limits.blockingLimit(for: "claude-code", now: reset.addingTimeInterval(-60)) != nil)
        #expect(limits.blockingLimit(for: "gemini", now: reset.addingTimeInterval(-60)) == nil)
    }

    /// Readings carry no observation time, so "later reset wins" is the only
    /// order-free rule available — and a later reset can only come from a newer
    /// window.
    @Test func theLaterResetWinsForTheSameWindow() {
        var limits = AccountLimits()
        limits.record(limit(.weekly, resetsAt: reset), for: "codex")
        limits.record(
            limit(.weekly, used: 92, resetsAt: reset.addingTimeInterval(3600)), for: "codex")
        #expect(limits.limits(for: "codex").first?.usedPercent == 92)

        // An older reading arriving late does not overwrite the newer one.
        limits.record(limit(.weekly, used: 100, resetsAt: reset), for: "codex")
        #expect(limits.limits(for: "codex").first?.usedPercent == 92)
    }

    /// Equal resets are the COMMON case: every session on one account shares that
    /// account's reset instant, so two sessions routinely report the same window
    /// with different progress. Merging must therefore be commutative — the arrival
    /// order is whatever order a dictionary of trackers iterated in, which is not
    /// stable between runs.
    @Test func conflictingReadingsForOneWindowMergeByStrength() {
        let reached = limit(.weekly, used: 100, resetsAt: reset, reached: true)
        let plenty = limit(.weekly, used: 88, resetsAt: reset, reached: false)

        // Both orders must agree, and both must keep the block.
        for readings in [[reached, plenty], [plenty, reached]] {
            var limits = AccountLimits()
            for reading in readings { limits.record(reading, for: "codex") }
            let merged = limits.limits(for: "codex").first
            #expect(merged?.isReached == true, "a real block was dropped")
            #expect(merged?.usedPercent == 100)
            #expect(limits.blockingLimit(for: "codex", now: reset.addingTimeInterval(-60)) != nil)
        }
    }

    /// The two Claude sources do not agree to the second: a refusal prints
    /// "resets 1:20am", so reconstructing it truncates to the minute, while the
    /// statusline reports the exact epoch. Without a tolerance the proactive
    /// reading looks like a *newer* window and replaces the refusal, and the row
    /// falls silent at the one moment it has something to say.
    @Test func nearIdenticalResetsAreOneWindowSoTheBlockSurvives() {
        let truncated = limit(.fiveHour, used: 100, resetsAt: reset, reached: true)
        let exact = limit(
            .fiveHour, used: 61, resetsAt: reset.addingTimeInterval(37), reached: false)

        for readings in [[truncated, exact], [exact, truncated]] {
            var limits = AccountLimits()
            for reading in readings { limits.record(reading, for: "claude-code") }
            let merged = limits.limits(for: "claude-code").first
            #expect(merged?.isReached == true, "the refusal was outranked by a stale percentage")
            #expect(merged?.usedPercent == 100)
            // The unrounded instant is the one worth keeping.
            #expect(merged?.resetsAt == reset.addingTimeInterval(37))
            #expect(limits.limits(for: "claude-code").count == 1)
        }
    }

    /// The tolerance must not swallow a real rollover — a five-hour window is
    /// hours away from the next one, so nothing legitimate lands inside it.
    @Test func aGenuineNewWindowStillReplacesTheOldOne() {
        var limits = AccountLimits()
        limits.record(
            limit(.fiveHour, used: 100, resetsAt: reset, reached: true), for: "claude-code")
        limits.record(
            limit(
                .fiveHour, used: 3, resetsAt: reset.addingTimeInterval(5 * 3600), reached: false),
            for: "claude-code")
        let current = limits.limits(for: "claude-code").first
        #expect(current?.isReached == false)
        #expect(current?.usedPercent == 3)
        #expect(limits.blockingLimit(for: "claude-code", now: reset.addingTimeInterval(60)) == nil)
    }

    /// Two windows can both be exhausted; the one the user is actually waiting
    /// on is the one that frees up first.
    @Test func theSoonestResetIsWhatTheUserIsWaitingOn() {
        var limits = AccountLimits()
        limits.record(limit(.weekly, resetsAt: reset.addingTimeInterval(86400)), for: "codex")
        limits.record(limit(.fiveHour, resetsAt: reset), for: "codex")
        let blocking = limits.blockingLimit(for: "codex", now: reset.addingTimeInterval(-60))
        #expect(blocking?.window == .fiveHour)
    }

    @Test func anExpiredReadingStopsBlockingWithoutBeingRemoved() {
        var limits = AccountLimits()
        limits.record(limit(.weekly, resetsAt: reset), for: "codex")
        #expect(limits.blockingLimit(for: "codex", now: reset.addingTimeInterval(-1)) != nil)
        #expect(limits.blockingLimit(for: "codex", now: reset.addingTimeInterval(1)) == nil)
        // Still remembered — it simply no longer applies.
        #expect(limits.limits(for: "codex").count == 1)
    }

    // MARK: - What a row says

    @Test func aQuotaBlockedTurnSaysSoInsteadOfClaimingItIsReady() {
        let explained = UsageLimitPresentation.apply(
            limit(.weekly, resetsAt: reset), to: session(), now: reset.addingTimeInterval(-3600))
        #expect(explained.reason?.hasPrefix("Usage limit reached") == true)

        // Once the window rolls over the ordinary wording returns, with nothing
        // new having been observed.
        let after = UsageLimitPresentation.apply(
            limit(.weekly, resetsAt: reset), to: session(), now: reset.addingTimeInterval(1))
        #expect(after.reason == "Turn complete — ready for you")
    }

    /// The critical exclusion. A `Notification` red is a permission prompt: the
    /// user genuinely is needed, and replacing that with a quota message would
    /// hide the one thing this app exists to surface.
    @Test func aPermissionPromptIsNeverOverwrittenByAQuotaMessage() {
        let prompted = session(
            lastEvent: "Notification", reason: "Claude needs your permission to use Bash")
        let explained = UsageLimitPresentation.apply(
            limit(.weekly, resetsAt: reset), to: prompted, now: reset.addingTimeInterval(-3600))
        #expect(explained.reason == "Claude needs your permission to use Bash")
    }

    /// Only a stopped session is waiting on quota. A running row is either
    /// working or about to fail on its own, and a grey row has been dealt with.
    @Test func onlyStoppedRowsAreExplained() {
        let now = reset.addingTimeInterval(-3600)
        for state in [SessionState.running, .idle] {
            let untouched = UsageLimitPresentation.apply(
                limit(.weekly, resetsAt: reset), to: session(state: state), now: now)
            #expect(untouched.reason == "Turn complete — ready for you", "state \(state)")
        }
        // An acknowledged row keeps its own wording too.
        let acknowledged = session(state: .idle, lastEvent: "Stop", reason: "Seen")
        #expect(
            UsageLimitPresentation.apply(
                limit(.weekly, resetsAt: reset), to: acknowledged, now: now
            )
            .reason == "Seen")
    }

    @Test func noLimitLeavesTheRowExactlyAsItWas() {
        let original = session()
        #expect(UsageLimitPresentation.apply(nil, to: original, now: reset) == original)
        // A reading that is not reached is not a block.
        let plenty = limit(.weekly, used: 40, resetsAt: reset, reached: false)
        #expect(UsageLimitPresentation.apply(plenty, to: original, now: reset) == original)
    }

    // MARK: - Window classification

    @Test func windowsAreClassifiedByLengthWithTolerance() {
        #expect(UsageLimit.Window(minutes: 300) == .fiveHour)
        #expect(UsageLimit.Window(minutes: 299) == .fiveHour)
        #expect(UsageLimit.Window(minutes: 10080) == .weekly)
        #expect(UsageLimit.Window(minutes: 10079) == .weekly)
        // Anything else keeps its real length rather than being forced into a
        // bucket that would mislabel the reset.
        #expect(UsageLimit.Window(minutes: 60) == .other(minutes: 60))
        #expect(UsageLimit.Window(minutes: 60).label == "60-minute limit")
    }
}
