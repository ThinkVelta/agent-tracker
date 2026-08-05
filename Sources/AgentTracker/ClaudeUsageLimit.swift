import Foundation

/// Reads "this account is out of quota" out of a Claude Code transcript line.
///
/// Claude publishes no status for it — the session-registry vocabulary is
/// `busy/shell/idle/waiting` and no hook fires — so the only durable trace is a
/// synthetic assistant entry the harness writes when a request is refused:
///
/// ```json
/// {"type":"assistant","error":"rate_limit","isApiErrorMessage":true,
///  "apiErrorStatus":429,"message":{"content":[{"type":"text",
///    "text":"You've hit your session limit · resets 1:20am (Europe/Brussels)"}]}}
/// ```
///
/// Pure. The reset it reports is reconstructed rather than read: Claude formats
/// it as a **local wall-clock time with no date**, so the entry's own timestamp
/// is the anchor for "which 1:20am".
enum ClaudeUsageLimit {
    /// Claude's own label vocabulary, mapped to the window each one belongs to.
    /// "session limit" is the five-hour window; the Opus/Sonnet/model variants
    /// are all seven-day windows internally (`seven_day_opus` and friends).
    /// Anything unrecognized yields nil rather than a guessed window — a wrong
    /// reset time is worse than no reset time.
    private static let windowsByLabel: [(label: String, window: UsageLimit.Window)] = [
        ("session limit", .fiveHour),
        ("weekly limit", .weekly),
        ("opus limit", .weekly),
        ("sonnet limit", .weekly),
    ]

    /// A transcript line, or nil if it is not a refusal we understand.
    static func parse(line: String) -> UsageLimit? {
        // Cheap reject before paying for JSON: these lines are rare and
        // transcripts run to tens of MB.
        guard line.contains("rate_limit") else { return nil }
        guard let data = line.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return parse(entry: object)
    }

    static func parse(entry object: [String: Any]) -> UsageLimit? {
        // Both markers, because either alone could plausibly appear on something
        // else: `rate_limit` names the cause and 429 names the refusal.
        guard (object["error"] as? String) == "rate_limit",
            (object["apiErrorStatus"] as? Int) == 429,
            let text = messageText(object)
        else { return nil }

        let lowered = text.lowercased()
        guard let match = windowsByLabel.first(where: { lowered.contains($0.label) })
        else { return nil }

        // No anchor, no reset. Falling back to `Date()` would reconstruct "the
        // next 1:20am from now", which for an entry of unknown age is a
        // plausible-looking time on quite possibly the wrong day — worse than
        // admitting the reset is unknown, which `isBlocking` then treats as not
        // blocking at all.
        let anchor = (object["timestamp"] as? String).flatMap(timestamp)
        return UsageLimit(
            window: match.window,
            usedPercent: 100,
            resetsAt: anchor.flatMap { resetDate(from: text, anchor: $0, window: match.window) },
            isReached: true
        )
    }

    private static func messageText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return nil }
        return content.compactMap { $0["text"] as? String }.first
    }

    private static func timestamp(_ raw: String) -> Date? {
        CodexRolloutParser.parseDate(raw)
    }

    /// `resets 1:20am (Europe/Brussels)` → the next 1:20am at or after `anchor`,
    /// in the zone the message names.
    ///
    /// Reconstructed rather than parsed, because the message carries no date: for
    /// the five-hour window the reset is always within a day of the refusal, so
    /// "the next occurrence" is unambiguous. A form this cannot read yields nil,
    /// which reads as "blocked, reset unknown" rather than a wrong time.
    static func resetDate(
        from text: String, anchor: Date, window: UsageLimit.Window = .fiveHour
    ) -> Date? {
        // Reconstruction is only sound for a window that cannot span more than a
        // day: then "the next 1:20am" is unambiguously the reset. Claude does
        // render far-future resets as a date rather than a bare time, so the
        // unsafe case is currently unreachable — but that is the regex below
        // declining to match a format, which is accidental safety. This makes it
        // structural: a weekly limit is never located from a time alone, whatever
        // the wording turns out to be.
        guard window.isLocatableFromTimeAlone else { return nil }
        // No zone, no reset — the same rule as no anchor. A wall-clock time is
        // meaningless without one, and assuming local would put the reset hours
        // out for anyone whose session reports a zone they are not in, which is
        // exactly the case an unreadable zone signals.
        guard let zone = timeZone(from: text), let time = wallClock(from: text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // `.nextTime` moves a nonexistent local time (spring-forward) to the
        // next real instant instead of inventing one; `.first` picks the
        // earlier of an ambiguous repeated hour, which is the sooner reset.
        return calendar.nextDate(
            after: anchor,
            matching: DateComponents(hour: time.hour, minute: time.minute),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first
        )
    }

    private static func wallClock(from text: String) -> (hour: Int, minute: Int)? {
        // `resets 1:20am`, `resets 1am`, `resets 11:59 PM`.
        let pattern = #"resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let rawHour = group(1).flatMap(Int.init), rawHour >= 1, rawHour <= 12,
            let meridiem = group(3)?.lowercased()
        else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        guard minute >= 0, minute < 60 else { return nil }
        // 12am is midnight and 12pm is noon — the one pair the arithmetic gets
        // wrong if written naively.
        let hour = (rawHour % 12) + (meridiem == "p" ? 12 : 0)
        return (hour, minute)
    }

    /// The zone is what makes the wall-clock time meaningful; a user who
    /// travelled between the refusal and now would otherwise get an hour wrong.
    private static func timeZone(from text: String) -> TimeZone? {
        let pattern = #"\(([^)]+)\)\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let name = String(text[range]).trimmingCharacters(in: .whitespaces)
        return TimeZone(identifier: name) ?? TimeZone(abbreviation: name)
    }
}
