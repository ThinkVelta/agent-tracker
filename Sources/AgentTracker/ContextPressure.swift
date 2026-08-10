import Foundation

/// Codex's context occupancy, derived from a rollout `token_count` event.
///
/// Codex reports tokens where Claude reports a percentage, so this is the one
/// place the app computes the number rather than reading it. *Which* token count
/// is the whole question, and it is measured rather than assumed:
///
/// - `total_token_usage` **accumulates across turns**. On one real session it
///   reached 153,694% of the window: it answers "what has this session cost",
///   not "how full is it".
/// - `last_token_usage.total_tokens` is the size of the most recent request, so
///   it climbs through a session and drops when Codex compacts. Across 132,097
///   readings on this machine it never once exceeded the window, and the top of
///   the range crowds just under 95% — which is where Codex compacts.
///
/// Reasoning output is not retained between turns, so subtracting it is
/// arguably the more correct model. It is deliberately not subtracted: measured,
/// that changes the displayed whole-number percentage in 5.1% of readings, and
/// the raw figure is the one whose ceiling lands nearest Codex's own limit. This
/// is Codex's accounting rather than ours, so a rule that matches the observed
/// ceiling beats one that matches a guess about the internals.
enum CodexContextWindow {
    /// - Parameter info: the value of `payload.info` on a `token_count` line.
    static func usedPercent(_ info: [String: Any]) -> Double? {
        guard let window = info["model_context_window"] as? Double, window > 0,
            let last = info["last_token_usage"] as? [String: Any],
            let used = last["total_tokens"] as? Double, used >= 0
        else { return nil }
        // Clamped rather than dropped, unlike the Claude reading this sits
        // beside. That one is a number Claude computed, so out of range means
        // the field is not what we think it is; this one is ours, and the way
        // to exceed the window legitimately is to switch to a model with a
        // smaller one mid-session. "Full" is the honest answer to that.
        return min(100, used / window * 100)
    }
}

/// How full a session's context window is — but only once that is worth saying.
///
/// Every session starts near zero and climbs all day, so a figure on every row
/// would be one more thing to read past on the rows where it means nothing.
/// Below the threshold this is `nil` and the row is unchanged; above it, it is
/// usually the number you actually wanted before deciding whether to start
/// something big in that session.
struct ContextPressure: Equatable {
    /// Quiet below this. Chosen to leave room to act: far enough along that the
    /// window is genuinely filling, early enough that finishing a thought and
    /// starting fresh is still a choice rather than an interruption.
    static let quietBelow: Double = 70
    /// Past this, a long turn is unlikely to fit.
    static let urgentFrom: Double = 90

    /// Rounded at construction, not at display, so every decision downstream is
    /// made about the number on screen. Ranking on the raw value instead let
    /// 89.6 render as "90%" in the not-yet-urgent colour, which reads as a bug
    /// in the colour rather than as a rounding rule.
    var usedPercent: Int
    var isUrgent: Bool

    var label: String { "\(usedPercent)%" }
    var help: String { "\(label) of the context window used" }

    /// - Returns: nil when there is nothing worth saying — either no reading at
    ///   all (a Claude session that has not rendered its statusline yet, or a
    ///   Codex one whose rollout has not reported tokens) or low enough to be
    ///   noise. "No reading" and "plenty left" stay distinct everywhere else in
    ///   this app; here they deliberately look the same, because both mean the
    ///   row has nothing to add.
    init?(usedPercent: Double?) {
        guard let usedPercent else { return nil }
        let rounded = Int(usedPercent.rounded())
        guard Double(rounded) >= Self.quietBelow else { return nil }
        self.usedPercent = rounded
        isUrgent = Double(rounded) >= Self.urgentFrom
    }
}
