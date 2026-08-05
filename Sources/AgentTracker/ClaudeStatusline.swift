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
/// Pure and tolerant, like the Codex parser: this is Claude's format, not ours,
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

    static func limits(in data: Data) -> [UsageLimit] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rateLimits = object["rate_limits"] as? [String: Any]
        else { return [] }
        return windowsByKey.compactMap { key, window in
            guard let reported = rateLimits[key] as? [String: Any] else { return nil }
            return limit(from: reported, window: window)
        }
    }

    /// Convenience for the polling caller: a missing or unreadable file is
    /// simply no reading.
    static func limits(at url: URL) -> [UsageLimit] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return limits(in: data)
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
            // No flag here, unlike Codex: 100% used is the only thing the
            // statusline says about being blocked.
            isReached: (used ?? 0) >= 100
        )
    }
}
