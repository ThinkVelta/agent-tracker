import Foundation

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
    ///   all (a session that has not rendered its statusline yet) or low
    ///   enough to be
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
