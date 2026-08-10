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
    /// One reading per provider: whichever of its windows is closest to its
    /// limit, since that is the one that will stop work first.
    ///
    /// Scoped to providers that actually have a session on screen. An account
    /// limit outlives the sessions that reported it — `AccountLimits` keeps a
    /// reading until its reset passes — so without this the footer would still
    /// be quoting quota an hour after the last session closed.
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
        return candidates.min(by: mostPressing).map { [$0] } ?? []
    }

    /// A total order, not just a comparison on percentage.
    ///
    /// `AccountLimits` stores windows in a dictionary, so `limits(for:)` hands
    /// them back in whatever order it feels like. Ranking on percentage alone
    /// leaves ties to that order — and ties are not exotic: two windows both
    /// sitting at 0% early in a week is the ordinary morning case. The chip
    /// would then flip between "5h" and "7d" between passes with no data
    /// behind it, and because the readings are published, each flip is a
    /// republish.
    ///
    /// Earlier reset breaks a percentage tie, since that window bites first.
    /// The id is the last resort and exists only to make the result total.
    private static func mostPressing(_ lhs: UsageReading, _ rhs: UsageReading) -> Bool {
        if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent > rhs.usedPercent }
        if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
        return lhs.id < rhs.id
    }
}
