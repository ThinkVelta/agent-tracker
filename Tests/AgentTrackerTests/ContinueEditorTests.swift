import Foundation
import Testing

@testable import AgentTracker

/// The two pieces of the arming panel that are not chrome: what the presets
/// resolve to, and the one line above the form that says when the message goes.
///
/// Every fixture sits around midday so "the same day" means the same day in
/// every timezone the suite might run in, and the preset arithmetic is pinned to
/// a UTC calendar rather than the machine's.
@Suite("Continue editor")
struct ContinueEditorTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func day(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))
            ?? .distantPast
    }

    // MARK: - Presets

    @Test("the hour presets are exactly that far out")
    func hourPresetsAreOffsets() {
        #expect(
            ContinuePreset.inAnHour.moment(from: day(5, hour: 12), calendar: utc)
                == day(5, hour: 13))
        #expect(
            ContinuePreset.inThreeHours.moment(from: day(5, hour: 12), calendar: utc)
                == day(5, hour: 15))
    }

    @Test("tomorrow morning is 9:00 on the next day")
    func tomorrowMorningIsNine() {
        #expect(
            ContinuePreset.tomorrowMorning.moment(from: day(5, hour: 12), calendar: utc)
                == day(6, hour: 9))
    }

    /// `date(bySettingHour:of:)` searches *forward*, so resolving from `now`
    /// rather than from midnight would put a preset clicked at 23:30 two days
    /// out — the one hour of the day where "tomorrow" would silently lie.
    @Test("tomorrow morning stays tomorrow when clicked late at night")
    func tomorrowMorningFromLateEvening() {
        #expect(
            ContinuePreset.tomorrowMorning.moment(from: day(5, hour: 23, minute: 30), calendar: utc)
                == day(6, hour: 9))
    }

    // MARK: - Headline

    /// The reason replaces the whole line, because a session that cannot be
    /// armed has no moment to promise.
    @Test("an unavailable reason is the whole headline")
    func reasonWins() {
        let headline = ContinueEditor.headline(
            unavailableReason: "Turn on scheduled continues in Settings", usesReset: true,
            resetsAt: day(5, hour: 13), fireAt: day(5, hour: 13), now: day(5, hour: 12))
        #expect(headline == "Turn on scheduled continues in Settings")
    }

    @Test("a clock schedule today reads as a bare time")
    func clockHeadlineToday() {
        let headline = ContinueEditor.headline(
            unavailableReason: nil, usesReset: false, resetsAt: nil,
            fireAt: day(5, hour: 13), now: day(5, hour: 12))
        #expect(headline.hasPrefix("Sends at "))
    }

    @Test("a clock schedule on a later day names the day too")
    func clockHeadlineLaterDay() {
        let headline = ContinueEditor.headline(
            unavailableReason: nil, usesReset: false, resetsAt: nil,
            fireAt: day(7, hour: 12), now: day(5, hour: 12))
        #expect(headline.hasPrefix("Sends "))
        #expect(!headline.hasPrefix("Sends at "))
        #expect(headline.contains(" at "))
    }

    @Test("a reset schedule names the reset it is waiting for")
    func resetHeadline() {
        let headline = ContinueEditor.headline(
            unavailableReason: nil, usesReset: true, resetsAt: day(5, hour: 13),
            fireAt: day(5, hour: 12), now: day(5, hour: 12))
        #expect(headline.hasPrefix("Sends when the limit resets at "))
    }

    /// A repeating schedule between firings has no computable moment, and
    /// inventing one would promise a send into a session that is still blocked.
    @Test("a repeating schedule with no known reset says so instead of inventing one")
    func resetHeadlineWithoutAMoment() {
        let headline = ContinueEditor.headline(
            unavailableReason: nil, usesReset: true, resetsAt: nil,
            fireAt: day(5, hour: 12), now: day(5, hour: 12))
        #expect(headline == "Sends when the limit next resets")
    }

    @Test("a described moment always reads as a phrase after \"Sends\"")
    func describedMomentsArePhrases() {
        #expect(
            ContinueEditor.describe(day(5, hour: 13), relativeTo: day(5, hour: 12))
                .hasPrefix("at "))
        let later = ContinueEditor.describe(day(7, hour: 12), relativeTo: day(5, hour: 12))
        #expect(!later.hasPrefix("at "))
        #expect(later.contains(" at "))
    }
}
