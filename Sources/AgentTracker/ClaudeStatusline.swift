import Foundation

/// Reads Claude's usage windows out of the payload the statusline wrapper saves.
///
/// This is the only *proactive* source for Claude. The transcript watcher learns
/// a limit from a refusal, which by definition arrives after the work stopped —
/// and measured across one machine's history, only 2 of 33 real refusals even
/// carried a reset time. The statusline payload carries `used_percentage` and an
/// epoch-seconds `resets_at` for both windows on every render, before anything
/// is refused.
///
/// Pure and tolerant: this is Claude's format, not ours,
/// each window may be independently absent, and `rate_limits` is missing
/// entirely for sessions Claude does not report it for. Absent means unknown,
/// never "you have room left".
enum ClaudeStatusline {
    /// Claude's own key for each window. Named windows only, so a key nobody has
    /// seen before is ignored rather than guessed at — the same allowlist rule
    /// the refusal parser follows.
    private static let windowsByKey: KeyValuePairs<String, UsageLimit.Window> = [
        "five_hour": .fiveHour,
        "seven_day": .weekly,
    ]

    /// One payload's readings, and which session rendered it. The capture is
    /// last-writer-wins across sessions, and each session reports the numbers
    /// *its* last response carried, so a reading is only meaningful together
    /// with who said it.
    struct Report: Equatable {
        /// Nil on a payload with no `session_id` (a foreign schema).
        var sessionId: String?
        var limits: [UsageLimit]
    }

    /// Nil only for something that is not a JSON object at all; a payload with
    /// no `rate_limits` is a report with nothing in it.
    static func report(in data: Data) -> Report? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let sessionId = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let rateLimits = object["rate_limits"] as? [String: Any] else {
            return Report(sessionId: sessionId, limits: [])
        }
        let limits = windowsByKey.compactMap { key, window -> UsageLimit? in
            guard let reported = rateLimits[key] as? [String: Any] else { return nil }
            return limit(from: reported, window: window)
        }
        return Report(sessionId: sessionId, limits: limits)
    }

    static func limits(in data: Data) -> [UsageLimit] {
        report(in: data)?.limits ?? []
    }

    /// Convenience for the polling caller: a missing or unreadable file is
    /// simply no reading.
    static func report(at url: URL) -> Report? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return report(in: data)
    }

    static func limits(at url: URL) -> [UsageLimit] {
        report(at: url)?.limits ?? []
    }

    private static func limit(from object: [String: Any], window: UsageLimit.Window) -> UsageLimit?
    {
        // Integers on the payloads measured here, but a percentage is a
        // percentage — `as? Double` reads either form.
        let used = object["used_percentage"] as? Double
        let resetsAt = (object["resets_at"] as? Double).flatMap { seconds -> Date? in
            // Epoch seconds. Zero or negative is absent, not 1970.
            seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        // A window that reports neither number tells us nothing at all.
        guard used != nil || resetsAt != nil else { return nil }
        return UsageLimit(
            window: window,
            usedPercent: used,
            resetsAt: resetsAt,
            // No explicit flag: 100% used is the only thing the
            // statusline says about being blocked.
            isReached: (used ?? 0) >= 100
        )
    }
}
