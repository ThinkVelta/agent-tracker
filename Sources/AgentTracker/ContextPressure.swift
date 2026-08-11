import Foundation

/// How full a session's context window is, and how loudly to say it.
///
/// Every session that has reported a reading shows one. The number is always
/// worth having — it is what you check before starting something big — but most
/// of the time it is worth having *quietly*, so below the threshold it is set
/// like the timestamp beside it and recedes into the row. Past the threshold it
/// takes weight and colour and stops being furniture.
///
/// That is a change of emphasis rather than of presence. An earlier version hid
/// the number entirely below 70%, which meant a glance could not tell "plenty of
/// room" from "no reading at all" — and those are the two states this app is
/// careful to keep apart everywhere else.
struct ContextPressure: Equatable {
    /// How much of the row's attention this number gets.
    enum Emphasis: Equatable {
        /// Filling, but not worth interrupting anyone over. Drawn like the
        /// timestamp: same size, same weight, same grey.
        case quiet
        /// Far enough along that finishing a thought and starting fresh is
        /// still a choice rather than an interruption.
        case warning
        /// Past this, a long turn is unlikely to fit.
        case critical
    }

    static let warningFrom: Double = 70
    static let criticalFrom: Double = 90

    /// Rounded at construction, not at display, so every decision downstream is
    /// made about the number on screen. Ranking on the raw value instead let
    /// 89.6 render as "90%" in the not-yet-urgent colour, which reads as a bug
    /// in the colour rather than as a rounding rule.
    var usedPercent: Int
    var emphasis: Emphasis

    var label: String { "\(usedPercent)%" }
    var help: String { "\(label) of the context window used" }

    /// - Returns: nil only when there is no reading at all — a session whose
    ///   statusline has not rendered yet. "No data" and "none used" stay
    ///   distinct, which is the rule the previous version broke.
    init?(usedPercent: Double?) {
        guard let usedPercent else { return nil }
        let rounded = Int(usedPercent.rounded())
        self.usedPercent = rounded
        switch Double(rounded) {
        case ..<Self.warningFrom: emphasis = .quiet
        case ..<Self.criticalFrom: emphasis = .warning
        default: emphasis = .critical
        }
    }
}
