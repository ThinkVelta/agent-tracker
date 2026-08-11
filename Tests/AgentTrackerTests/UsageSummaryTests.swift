import Foundation
import Testing

@testable import AgentTracker

@Suite("UsageSummary")
struct UsageSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_786_200_000)

    private func limitsOf(_ entries: [UsageLimit]) -> AccountLimits {
        var limits = AccountLimits()
        for limit in entries { limits.record(limit) }
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
            from: limitsOf([limit(.fiveHour, used: 61, resetsIn: 3600)]), now: now)

        #expect(readings.count == 1)
        #expect(readings[0].usedPercent == 61)
        #expect(readings[0].windowLabel == "5h")
    }

    /// The window that will stop work first is the one worth the space.
    /// Both windows, because they answer different questions — "can I start
    /// this now" and "how much of this week is left" — and showing only
    /// whichever happens to be closer to its limit answers one of them at
    /// random.
    @Test("both windows are shown, shortest first")
    func showsEveryWindowShortestFirst() {
        let readings = UsageSummary.readings(
            from: limitsOf([
                limit(.weekly, used: 88, resetsIn: 86_400),
                limit(.fiveHour, used: 20, resetsIn: 3600),
            ]), now: now)

        #expect(readings.map(\.windowLabel) == ["5h", "7d"])
        #expect(readings.map(\.usedPercent) == [20, 88])
    }

    /// An unfamiliar window still gets a place, and sorts by its length rather
    /// than being appended wherever it was found.
    @Test("an unnamed window sorts by how long it is")
    func unknownWindowsSortByLength() {
        let readings = UsageSummary.readings(
            from: limitsOf([
                limit(.weekly, used: 10, resetsIn: 86_400),
                limit(.other(minutes: 60), used: 30, resetsIn: 1800),
                limit(.fiveHour, used: 20, resetsIn: 3600),
            ]), now: now)
        #expect(readings.map(\.windowLabel) == ["60m", "5h", "7d"])
    }

    /// "No data" and "none used" are the two states this must never merge, so a
    /// reading with no percentage is dropped rather than shown as zero.
    @Test("a window with no percentage is not reported as zero")
    func dropsUnknownPercentages() {
        let readings = UsageSummary.readings(
            from: limitsOf([limit(.fiveHour, used: nil, resetsIn: 3600)]), now: now)
        #expect(readings.isEmpty)
    }

    /// Nothing writes a correction when a window resets — the file just goes
    /// quiet — so a passed reset makes the reading describe a window that is gone.
    @Test("a reading whose window has already reset is dropped")
    func dropsExpiredReadings() {
        let readings = UsageSummary.readings(
            from: limitsOf([limit(.fiveHour, used: 99, resetsIn: -60)]), now: now)
        #expect(readings.isEmpty)
    }

    /// Two windows at the same percentage is the ordinary morning case, not an
    /// exotic one — both sit at 0% early in a week. Ranking on percentage alone
    /// The order is fixed by length, never by pressure. A strip read at a
    /// glance must keep its numbers in the same places — ordering by whichever
    /// is worse right now would have the two swap as the day went on, and
    /// because the readings are published, each swap is a republish rather than
    /// a redraw.
    @Test("the order does not move when the pressure does")
    func orderIsFixedByLengthNotByPressure() {
        let weeklyWorse = limitsOf([
            limit(.weekly, used: 91, resetsIn: 86_400),
            limit(.fiveHour, used: 3, resetsIn: 3600),
        ])
        let fiveHourWorse = limitsOf([
            limit(.weekly, used: 3, resetsIn: 86_400),
            limit(.fiveHour, used: 91, resetsIn: 3600),
        ])
        // Repeated because the source is a dictionary, so a missing tiebreak
        // shows up as an intermittent swap rather than a failure every run.
        for _ in 0..<50 {
            #expect(
                UsageSummary.readings(from: weeklyWorse, now: now).map(\.windowLabel)
                    == ["5h", "7d"])
            #expect(
                UsageSummary.readings(from: fiveHourWorse, now: now).map(\.windowLabel)
                    == ["5h", "7d"])
        }
    }

    /// The one the reviewer found, and it is worse than a wrong ranking: a
    /// reading with no reset has no moment at which it stops being shown, so a
    /// refusal that names a limit without saying when it lifts would pin its
    /// number to the strip for the life of the process.
    @Test("a reading with no reset is dropped, however high it is")
    func dropsResetLessReadings() {
        var limits = AccountLimits()
        limits.record(
            UsageLimit(window: .weekly, usedPercent: 95, resetsAt: nil, isReached: true))
        limits.record(limit(.fiveHour, used: 40, resetsIn: 3600))

        let readings = UsageSummary.readings(
            from: limits, now: now)

        // Not merely outranked by the dated one — gone.
        #expect(readings.count == 1)
        #expect(readings[0].usedPercent == 40)
        #expect(readings[0].windowLabel == "5h")
    }

    @Test("a provider whose only reading has no reset shows nothing at all")
    func silentRatherThanOpenEnded() {
        var limits = AccountLimits()
        limits.record(
            UsageLimit(window: .fiveHour, usedPercent: 100, resetsAt: nil, isReached: true))
        #expect(
            UsageSummary.readings(from: limits, now: now).isEmpty)
    }

    @Test("a reached limit still reads as usage, at the number it reached")
    func reachedLimitsAreStillReadings() {
        let readings = UsageSummary.readings(
            from: limitsOf([
                limit(.fiveHour, used: 100, resetsIn: 600, reached: true)
            ]), now: now)
        #expect(readings.first?.usedPercent == 100)
    }
}
