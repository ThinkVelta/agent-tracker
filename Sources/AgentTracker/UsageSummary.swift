import Foundation

/// One usage window, as the dropdown shows it.
struct UsageReading: Equatable, Identifiable, Sendable {
    var window: UsageLimit.Window
    /// 0-100. Absent readings are dropped rather than shown as zero, because
    /// "no data" and "none used" are the two things this must never confuse.
    var usedPercent: Double
    /// Always known. A reading with no reset can never be retired, so it is
    /// dropped before it becomes one of these rather than shown open-ended.
    var resetsAt: Date

    var id: String { "\(window)" }

    /// Short enough to sit beside another one in a 380pt popover.
    var windowLabel: String {
        switch window {
        case .fiveHour: return "5h"
        case .weekly: return "7d"
        case .other(let minutes): return minutes < 120 ? "\(minutes)m" : "\(minutes / 60)h"
        }
    }
}

/// Decides which usage numbers are worth a line in the dropdown.
///
/// The app already reads all of this from the statusline payload, and until now
/// threw it away unless a limit was actually *reached*. That is the wrong moment to
/// start caring: by then the session has already stopped, and the number that
/// would have let someone pace their day went unread all day.
enum UsageSummary {
    /// Every window that has something to say, shortest first.
    ///
    /// Both windows show rather than only the tightest. They answer different
    /// questions — the 5-hour one is "can I start this now", the weekly one is
    /// "how much of this week is left" — and showing only whichever happens to
    /// be closer to its limit answers one of them at random.
    ///
    /// Ordered by window length, never by pressure. A strip you read at a
    /// glance must keep its numbers in the same places; ordering by whichever
    /// is worse right now would have the two swap as the day went on, so
    /// finding the one you wanted would mean reading both labels first.
    static func readings(from limits: AccountLimits, now: Date) -> [UsageReading] {
        let candidates = limits.all.compactMap { limit -> UsageReading? in
            guard let used = limit.usedPercent else { return nil }
            // A known future reset is required, not merely respected.
            //
            // Nothing writes a correction when a window rolls over — the file
            // simply goes quiet — so the reset is the only thing that can ever
            // retire a reading. Without one there is no moment at which this
            // stops being displayed, and a refusal that names a limit without
            // saying when it lifts would pin "100%" to the strip for the life
            // of the process. `isBlocking` takes the same position for the same
            // reason.
            guard let resetsAt = limit.resetsAt, resetsAt > now else { return nil }
            return UsageReading(window: limit.window, usedPercent: used, resetsAt: resetsAt)
        }
        return candidates.sorted(by: shorterWindowFirst)
    }

    /// A total order, because `AccountLimits` stores windows in a dictionary
    /// and hands them back in whatever order it feels like. Length decides it;
    /// the label is the last resort and exists only so two windows of equal
    /// length cannot swap places between passes, republishing the strip each
    /// time for no reason anyone could see.
    private static func shorterWindowFirst(_ lhs: UsageReading, _ rhs: UsageReading) -> Bool {
        if lhs.window.minutes != rhs.window.minutes {
            return lhs.window.minutes < rhs.window.minutes
        }
        return lhs.windowLabel < rhs.windowLabel
    }
}
