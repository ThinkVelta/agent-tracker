import Foundation
import Testing

@testable import AgentTracker

/// Fixtures mirror the shape Claude Code writes, with synthetic content.
final class ClaudeUsageLimitTests {
    private func refusal(
        text: String,
        timestamp: String = "2026-08-03T20:09:01.055Z",
        error: String = "rate_limit",
        status: Int = 429
    ) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "error": error,
            "isApiErrorMessage": true,
            "apiErrorStatus": status,
            "message": ["model": "<synthetic>", "content": [["type": "text", "text": text]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The verbatim wording from a real refusal, which is the whole contract.
    @Test func readsTheRefusalClaudeActuallyWrites() throws {
        let line = refusal(text: "You've hit your session limit · resets 1:20am (Europe/Brussels)")
        let limit = try #require(ClaudeUsageLimit.parse(line: line))
        #expect(limit.window == .fiveHour)
        #expect(limit.isReached)
        #expect(limit.usedPercent == 100)

        // 20:09 on the 3rd, resetting at 1:20am, means the 4th — reconstructed,
        // because the message carries no date.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Brussels"))
        let reset = try #require(limit.resetsAt)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reset)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 4)
        #expect(parts.hour == 1)
        #expect(parts.minute == 20)
    }

    /// "session limit" is the five-hour window; the model-specific ones are
    /// seven-day windows internally.
    @Test func labelsMapToTheWindowTheyBelongTo() {
        let cases: [(String, UsageLimit.Window)] = [
            ("You've hit your session limit · resets 3am (UTC)", .fiveHour),
            ("You've hit your weekly limit · resets 9:30pm (UTC)", .weekly),
            ("You've hit your Opus limit · resets 9:30pm (UTC)", .weekly),
            ("You've hit your Sonnet limit · resets 9:30pm (UTC)", .weekly),
        ]
        for (text, expected) in cases {
            #expect(
                ClaudeUsageLimit.parse(line: refusal(text: text))?.window == expected,
                "\(text)")
        }
    }

    /// An unrecognized label yields nothing rather than a guessed window: a wrong
    /// reset time is worse than no reset time.
    @Test func anUnknownLabelIsNotGuessedAt() {
        #expect(
            ClaudeUsageLimit.parse(
                line: refusal(text: "You're out of usage credits · add funds to continue")) == nil)
        #expect(ClaudeUsageLimit.parse(line: refusal(text: "Something new happened")) == nil)
    }

    /// Both markers are required: either alone could appear on something else.
    @Test func onlyARealRefusalCounts() {
        let text = "You've hit your session limit · resets 1:20am (UTC)"
        #expect(ClaudeUsageLimit.parse(line: refusal(text: text, error: "overloaded")) == nil)
        #expect(ClaudeUsageLimit.parse(line: refusal(text: text, status: 500)) == nil)
        #expect(ClaudeUsageLimit.parse(line: "not json") == nil)
        #expect(ClaudeUsageLimit.parse(line: "{}") == nil)
        // A line merely mentioning the phrase is not a refusal.
        #expect(ClaudeUsageLimit.parse(line: #"{"type":"user","text":"rate_limit"}"#) == nil)
    }

    /// Without a timestamp there is no anchor, and "the next 1:20am from now" for
    /// an entry of unknown age is a plausible-looking time on quite possibly the
    /// wrong day. Blocked-with-no-reset is the honest answer, and `isBlocking`
    /// then declines to block on it.
    @Test func aMissingTimestampYieldsNoResetRatherThanAGuess() throws {
        let object: [String: Any] = [
            "type": "assistant", "error": "rate_limit", "apiErrorStatus": 429,
            "message": [
                "content": [
                    ["type": "text", "text": "You've hit your session limit · resets 1:20am (UTC)"]
                ]
            ],
        ]
        let limit = try #require(ClaudeUsageLimit.parse(entry: object))
        #expect(limit.isReached)
        #expect(limit.resetsAt == nil)
        #expect(limit.isBlocking(now: Date()) == false)

        // An unparseable timestamp is the same situation.
        var broken = object
        broken["timestamp"] = "yesterday afternoon"
        #expect(ClaudeUsageLimit.parse(entry: broken)?.resetsAt == nil)
    }

    /// A bare wall-clock time locates a reset only for a window that cannot span
    /// more than a day. A weekly reset could be any of six days at "1:20am", and
    /// picking the nearest would clear the block days early.
    @Test func aWeeklyResetIsNeverLocatedFromATimeAlone() {
        let weekly = ClaudeUsageLimit.parse(
            line: refusal(text: "You've hit your weekly limit · resets 1:20am (UTC)"))
        #expect(weekly?.window == .weekly)
        #expect(weekly?.isReached == true)
        #expect(weekly?.resetsAt == nil)
        #expect(weekly?.isBlocking(now: anchor) == false)

        // The five-hour window is short enough for the next occurrence to be it.
        let session = ClaudeUsageLimit.parse(
            line: refusal(text: "You've hit your session limit · resets 1:20am (UTC)"))
        #expect(session?.resetsAt != nil)
    }

    /// Claude renders a reset more than a day out as a date rather than a bare
    /// time. Locking that in, because the window gate above and this parse both
    /// have to hold for a far-future reset to stay unguessed.
    @Test func aDateFormattedResetIsNotMistakenForATime() {
        #expect(
            ClaudeUsageLimit.resetDate(
                from: "resets Aug 10, 1:20 AM (UTC)", anchor: anchor, window: .fiveHour) == nil)
        #expect(
            ClaudeUsageLimit.resetDate(
                from: "resets Aug 10, 1 AM", anchor: anchor, window: .fiveHour) == nil)
    }

    // MARK: - Reconstructing the reset

    private let anchor = Date(timeIntervalSince1970: 1_785_787_741)  // 2026-08-03T20:09:01Z

    @Test func wallClockFormsAreRead() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        func hourMinute(_ text: String) -> (Int, Int)? {
            guard let date = ClaudeUsageLimit.resetDate(from: text, anchor: anchor) else {
                return nil
            }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? -1, parts.minute ?? -1)
        }

        #expect(hourMinute("resets 1:20am (UTC)").map { $0 == (1, 20) } == true)
        #expect(hourMinute("resets 1am (UTC)").map { $0 == (1, 0) } == true)
        #expect(hourMinute("resets 11:59 PM (UTC)").map { $0 == (23, 59) } == true)
        // Midnight and noon are the pair naive arithmetic gets wrong.
        #expect(hourMinute("resets 12am (UTC)").map { $0 == (0, 0) } == true)
        #expect(hourMinute("resets 12:30pm (UTC)").map { $0 == (12, 30) } == true)
    }

    @Test func anUnreadableResetIsNilRatherThanWrong() {
        #expect(ClaudeUsageLimit.resetDate(from: "resets soon", anchor: anchor) == nil)
        #expect(ClaudeUsageLimit.resetDate(from: "resets 25:00am", anchor: anchor) == nil)
        #expect(ClaudeUsageLimit.resetDate(from: "no reset here", anchor: anchor) == nil)
        // A blocked session with an unreadable reset still parses as blocked; it
        // just cannot claim when. `isBlocking` then declines to block on it,
        // which is the conservative end.
        let limit = ClaudeUsageLimit.parse(
            line: refusal(text: "You've hit your session limit · resets at dawn"))
        #expect(limit?.isReached == true)
        #expect(limit?.resetsAt == nil)
        #expect(limit?.isBlocking(now: anchor) == false)
    }

    /// The reset is always ahead of the refusal, so "the next occurrence" has to
    /// roll into the following day when the time has already passed.
    @Test func theResetRollsForwardPastTheRefusal() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // Anchor is 20:09 UTC; 1:20am is tomorrow, 6pm is today.
        let tomorrow = try #require(
            ClaudeUsageLimit.resetDate(from: "resets 1:20am (UTC)", anchor: anchor))
        #expect(calendar.dateComponents([.day], from: tomorrow).day == 4)
        #expect(tomorrow > anchor)

        let later = try #require(
            ClaudeUsageLimit.resetDate(from: "resets 10:30pm (UTC)", anchor: anchor))
        #expect(calendar.dateComponents([.day], from: later).day == 3)
        #expect(later > anchor)
    }

    /// The zone in the message is what makes the time meaningful — reading it as
    /// local would be an hour or more wrong for a user who travelled.
    @Test func theZoneInTheMessageIsHonoured() throws {
        let brussels = try #require(
            ClaudeUsageLimit.resetDate(from: "resets 1:20am (Europe/Brussels)", anchor: anchor))
        let tokyo = try #require(
            ClaudeUsageLimit.resetDate(from: "resets 1:20am (Asia/Tokyo)", anchor: anchor))
        #expect(brussels != tokyo)
        // An unreadable zone yields no reset, for the same reason a missing
        // anchor does: a wall-clock time without a zone is not a time, and
        // assuming local would be hours out for a session reporting a zone the
        // user is not in.
        #expect(ClaudeUsageLimit.resetDate(from: "resets 1:20am (Narnia)", anchor: anchor) == nil)
        #expect(ClaudeUsageLimit.resetDate(from: "resets 1:20am", anchor: anchor) == nil)
    }
}
