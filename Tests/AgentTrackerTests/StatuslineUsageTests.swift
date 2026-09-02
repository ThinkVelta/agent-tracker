import Foundation
import Testing

@testable import AgentTracker

/// The statusline's numbers can fall inside a window — an account-side reset,
/// a boosted limit — and the strip has to follow them down.
final class StatuslineUsageTests {
    private let reset = Date(timeIntervalSince1970: 1_788_361_200)

    private func reading(_ used: Double, window: UsageLimit.Window = .weekly) -> UsageLimit {
        UsageLimit(window: window, usedPercent: used, resetsAt: reset, isReached: used >= 100)
    }

    private func weekly(_ usage: StatuslineUsage, refusals: AccountLimits = AccountLimits())
        -> UsageLimit?
    {
        usage.merged(into: refusals).all.first { $0.window == .weekly }
    }

    /// The bug this exists for: the app ran across an account-side reset and
    /// showed the pre-reset 65% for the rest of the week, while every session
    /// was saying 5%.
    @Test func aSessionsNewerReadingReplacesItsOlderOneEvenWhenLower() {
        var usage = StatuslineUsage()
        usage.record([reading(65)], from: "s1")
        usage.record([reading(5)], from: "s1")
        #expect(weekly(usage)?.usedPercent == 5)
    }

    /// Between sessions the higher reading still wins: the capture alternates
    /// between writers, and an idle session re-renders the numbers its last
    /// response carried, so the lower of two live readings is the older view.
    /// Whichever wrote last must not matter, or the strip would flicker.
    @Test func theHigherOfTwoLiveSessionsReadingsWinsWhicheverWroteLast() {
        for order in [["idle", "busy"], ["busy", "idle"]] {
            var usage = StatuslineUsage()
            for session in order {
                usage.record([reading(session == "busy" ? 9 : 5)], from: session)
            }
            #expect(weekly(usage)?.usedPercent == 9, "order \(order)")
        }
    }

    @Test func aSessionThatIsGoneTakesItsReadingWithIt() {
        var usage = StatuslineUsage()
        usage.record([reading(65)], from: "old")
        usage.record([reading(5)], from: "new")
        #expect(weekly(usage)?.usedPercent == 65)

        usage.retain(sessions: ["new"])
        #expect(weekly(usage)?.usedPercent == 5)

        usage.retain(sessions: [])
        #expect(usage.merged(into: AccountLimits()).all.isEmpty)
    }

    /// A payload can carry one window and not the other; what the session said
    /// about the missing one still stands.
    @Test func aPayloadReportingOneWindowKeepsTheOther() {
        var usage = StatuslineUsage()
        usage.record([reading(40, window: .fiveHour), reading(65)], from: "s1")
        usage.record([reading(45, window: .fiveHour)], from: "s1")

        let all = usage.merged(into: AccountLimits()).all
        #expect(all.first { $0.window == .fiveHour }?.usedPercent == 45)
        #expect(all.first { $0.window == .weekly }?.usedPercent == 65)
    }

    /// A payload with no `rate_limits` at all is a session Claude reports
    /// nothing for, not a session at zero.
    @Test func anEmptyReportChangesNothing() {
        var usage = StatuslineUsage()
        usage.record([reading(65)], from: "s1")
        usage.record([], from: "s1")
        #expect(weekly(usage)?.usedPercent == 65)
    }

    /// A payload with no session id has nothing to be pruned against; it is
    /// kept, newest wins.
    @Test func anAnonymousPayloadSurvivesPruningAndReplacesItself() {
        var usage = StatuslineUsage()
        usage.record([reading(65)], from: nil)
        usage.record([reading(5)], from: nil)
        usage.retain(sessions: [])
        #expect(weekly(usage)?.usedPercent == 5)
    }

    /// The by-strength merge still applies across sources: a refusal says the
    /// account is blocked, and a lower percentage from the statusline does not
    /// argue with it.
    @Test func aRefusalStillOutranksALowerReading() {
        var refusals = AccountLimits()
        refusals.record(
            UsageLimit(window: .weekly, usedPercent: 100, resetsAt: reset, isReached: true))
        var usage = StatuslineUsage()
        usage.record([reading(5)], from: "s1")

        let merged = weekly(usage, refusals: refusals)
        #expect(merged?.isReached == true)
        #expect(merged?.usedPercent == 100)
    }
}
