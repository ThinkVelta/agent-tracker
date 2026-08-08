import Foundation
import Testing

@testable import AgentTracker

@Suite("UsageSummary")
struct UsageSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_786_200_000)

    private func limits(_ entries: [(String, UsageLimit)]) -> AccountLimits {
        var limits = AccountLimits()
        for (provider, limit) in entries { limits.record(limit, for: provider) }
        return limits
    }

    private func limit(
        _ window: UsageLimit.Window, used: Double?, resetsIn: TimeInterval, reached: Bool = false
    ) -> UsageLimit {
        UsageLimit(
            window: window, usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn),
            isReached: reached)
    }

    @Test("a live reading is shown long before anything is blocked")
    func showsUnblockedUsage() {
        let readings = UsageSummary.readings(
            from: limits([("claude-code", limit(.fiveHour, used: 61, resetsIn: 3600))]),
            providers: ["claude-code"], now: now)

        #expect(readings.count == 1)
        #expect(readings[0].usedPercent == 61)
        #expect(readings[0].providerLabel == "Claude")
        #expect(readings[0].windowLabel == "5h")
    }

    /// The window that will stop work first is the one worth the space.
    @Test("the window closest to its limit wins")
    func picksTheTightestWindow() {
        let readings = UsageSummary.readings(
            from: limits([
                ("claude-code", limit(.fiveHour, used: 20, resetsIn: 3600)),
                ("claude-code", limit(.weekly, used: 88, resetsIn: 86_400)),
            ]),
            providers: ["claude-code"], now: now)

        #expect(readings.count == 1)
        #expect(readings[0].usedPercent == 88)
        #expect(readings[0].windowLabel == "7d")
    }

    /// "No data" and "none used" are the two states this must never merge, so a
    /// reading with no percentage is dropped rather than shown as zero.
    @Test("a window with no percentage is not reported as zero")
    func dropsUnknownPercentages() {
        let readings = UsageSummary.readings(
            from: limits([("claude-code", limit(.fiveHour, used: nil, resetsIn: 3600))]),
            providers: ["claude-code"], now: now)
        #expect(readings.isEmpty)
    }

    /// Nothing writes a correction when a window resets — the file just goes
    /// quiet — so a passed reset makes the reading describe a window that is gone.
    @Test("a reading whose window has already reset is dropped")
    func dropsExpiredReadings() {
        let readings = UsageSummary.readings(
            from: limits([("claude-code", limit(.fiveHour, used: 99, resetsIn: -60))]),
            providers: ["claude-code"], now: now)
        #expect(readings.isEmpty)
    }

    /// An account limit outlives the sessions that reported it, so without this
    /// the strip would still quote Codex quota after the last Codex session went.
    @Test("a provider with no session on screen is not quoted")
    func scopesToVisibleProviders() {
        let both = limits([
            ("claude-code", limit(.fiveHour, used: 61, resetsIn: 3600)),
            ("codex", limit(.weekly, used: 40, resetsIn: 86_400)),
        ])
        let readings = UsageSummary.readings(from: both, providers: ["claude-code"], now: now)
        #expect(readings.map(\.provider) == ["claude-code"])
    }

    @Test("two providers are ordered stably, not by dictionary chance")
    func stableOrder() {
        let both = limits([
            ("codex", limit(.weekly, used: 40, resetsIn: 86_400)),
            ("claude-code", limit(.fiveHour, used: 61, resetsIn: 3600)),
        ])
        for _ in 0..<20 {
            let readings = UsageSummary.readings(
                from: both, providers: ["codex", "claude-code"], now: now)
            #expect(readings.map(\.provider) == ["claude-code", "codex"])
        }
    }

    @Test("a reached limit still reads as usage, at the number it reached")
    func reachedLimitsAreStillReadings() {
        let readings = UsageSummary.readings(
            from: limits([
                ("claude-code", limit(.fiveHour, used: 100, resetsIn: 600, reached: true))
            ]),
            providers: ["claude-code"], now: now)
        #expect(readings.first?.usedPercent == 100)
    }
}
