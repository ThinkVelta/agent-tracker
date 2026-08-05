import Foundation
import Testing

@testable import AgentTracker

/// Fixtures mirror the shape Claude Code puts on a statusline script's stdin,
/// with synthetic content.
final class ClaudeStatuslineTests {
    private let fiveHourReset = Date(timeIntervalSince1970: 1_785_787_741)
    private let weeklyReset = Date(timeIntervalSince1970: 1_786_300_000)

    private func payload(_ rateLimits: String?) -> Data {
        let field = rateLimits.map { ", \"rate_limits\": \($0)" } ?? ""
        return Data(
            """
            {"session_id": "abc-123", "session_name": "demo", "cwd": "/Users/dev/demo"\(field)}
            """.utf8)
    }

    private func window(_ limits: [UsageLimit], _ window: UsageLimit.Window) -> UsageLimit? {
        limits.first { $0.window == window }
    }

    /// The contract, as Claude documents and writes it: both windows, a
    /// percentage, and the reset as epoch **seconds**.
    @Test func readsBothWindowsWithTheirResets() throws {
        let limits = ClaudeStatusline.limits(
            in: payload(
                """
                {"five_hour": {"used_percentage": 96, "resets_at": 1785787741},
                 "seven_day": {"used_percentage": 41, "resets_at": 1786300000}}
                """))
        #expect(limits.count == 2)
        let fiveHour = try #require(window(limits, .fiveHour))
        #expect(fiveHour.usedPercent == 96)
        #expect(fiveHour.resetsAt == fiveHourReset)
        #expect(window(limits, .weekly)?.resetsAt == weeklyReset)
    }

    /// The whole point of the proactive source: it reports a reset while there is
    /// still room left, which is what a schedule can be armed against. A refusal
    /// only ever arrives after the work has already stopped.
    @Test func aWindowWithRoomLeftStillCarriesItsReset() throws {
        let limits = ClaudeStatusline.limits(
            in: payload(#"{"five_hour": {"used_percentage": 12, "resets_at": 1785787741}}"#))
        let fiveHour = try #require(window(limits, .fiveHour))
        #expect(fiveHour.isReached == false)
        #expect(fiveHour.resetsAt == fiveHourReset)
        #expect(fiveHour.isBlocking(now: fiveHourReset.addingTimeInterval(-60)) == false)
    }

    /// Percentages arrive as integers on every payload measured here, but the
    /// field is a percentage and a fraction of one is still a percentage.
    @Test func integerAndFractionalPercentagesBothRead() {
        for text in ["100", "100.0", "99.6"] {
            let limits = ClaudeStatusline.limits(
                in: payload("{\"five_hour\": {\"used_percentage\": \(text), \"resets_at\": 1}}"))
            #expect(limits.first?.usedPercent != nil, "percentage \(text)")
        }
        #expect(
            ClaudeStatusline.limits(
                in: payload(#"{"five_hour": {"used_percentage": 100, "resets_at": 1785787741}}"#)
            ).first?.isReached == true)
        #expect(
            ClaudeStatusline.limits(
                in: payload(#"{"five_hour": {"used_percentage": 99.6, "resets_at": 1785787741}}"#)
            ).first?.isReached == false)
    }

    /// Absent means "cannot verify", never "you have room left" — `rate_limits`
    /// is missing entirely for sessions Claude does not report it for, and each
    /// window may be independently absent.
    @Test func absentUsageIsNoReadingRatherThanAGoodOne() {
        #expect(ClaudeStatusline.limits(in: payload(nil)).isEmpty)
        #expect(ClaudeStatusline.limits(in: payload("{}")).isEmpty)
        #expect(ClaudeStatusline.limits(in: payload(#"{"five_hour": null}"#)).isEmpty)
        // One window present, the other not.
        let partial = ClaudeStatusline.limits(
            in: payload(#"{"seven_day": {"used_percentage": 41, "resets_at": 1786300000}}"#))
        #expect(partial.count == 1)
        #expect(partial.first?.window == .weekly)
    }

    /// A window whose object carries neither number says nothing, and a key
    /// nobody has seen before is not guessed at — the same allowlist rule the
    /// refusal parser follows, for the same reason: a wrong window means a wrong
    /// reset.
    @Test func emptyAndUnknownWindowsAreIgnored() {
        #expect(ClaudeStatusline.limits(in: payload(#"{"five_hour": {}}"#)).isEmpty)
        #expect(
            ClaudeStatusline.limits(in: payload(#"{"five_hour": {"other": 1}}"#)).isEmpty)
        #expect(
            ClaudeStatusline.limits(
                in: payload(#"{"thirty_day": {"used_percentage": 50, "resets_at": 1786300000}}"#)
            ).isEmpty)
    }

    /// A reset of zero is Claude saying it does not know, not the epoch.
    @Test func aMissingOrZeroResetIsNotATime() {
        for text in ["0", "-1", "null", "\"soon\""] {
            let limits = ClaudeStatusline.limits(
                in: payload("{\"five_hour\": {\"used_percentage\": 96, \"resets_at\": \(text)}}"))
            #expect(limits.first?.resetsAt == nil, "resets_at \(text)")
            // Still a usable reading: the percentage is real.
            #expect(limits.first?.usedPercent == 96, "resets_at \(text)")
        }
    }

    @Test func malformedPayloadsYieldNothing() {
        #expect(ClaudeStatusline.limits(in: Data("not json".utf8)).isEmpty)
        #expect(ClaudeStatusline.limits(in: Data("[1, 2]".utf8)).isEmpty)
        #expect(ClaudeStatusline.limits(in: Data()).isEmpty)
        #expect(ClaudeStatusline.limits(in: payload(#""a string""#)).isEmpty)
    }

    /// The polling caller runs every tick, long before the wrapper is installed
    /// and after it is removed, so a missing file has to be ordinary.
    @Test func aMissingCaptureFileIsSimplyNoReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-statusline.json")
        #expect(ClaudeStatusline.limits(at: url).isEmpty)

        try payload(#"{"five_hour": {"used_percentage": 96, "resets_at": 1785787741}}"#)
            .write(to: url)
        #expect(ClaudeStatusline.limits(at: url).count == 1)
    }
}
