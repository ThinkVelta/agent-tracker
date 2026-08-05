import Foundation

/// An account usage window and when it resets.
///
/// Account-wide rather than per-session: both providers report limits per
/// account, so the newest reading from any session describes all of them. It is
/// carried on the session it was observed from because that is the session the
/// user will be looking at when they wonder why nothing is happening.
struct UsageLimit: Equatable {
    /// Which window, derived from its length rather than from the slot it
    /// arrived in. Codex has reported only the weekly window since around
    /// February 2026, and reports it in the slot named `primary` — so trusting
    /// the slot would label a weekly reset as a five-hour one.
    enum Window: Equatable, Hashable {
        case fiveHour
        case weekly
        case other(minutes: Int)

        /// Real values seen in the wild are 300/299 and 10080/10079, so this
        /// classifies by proximity rather than equality.
        init(minutes: Int) {
            switch minutes {
            case 240...360: self = .fiveHour
            case 9000...11520: self = .weekly
            default: self = .other(minutes: minutes)
            }
        }

        var label: String {
            switch self {
            case .fiveHour: return "5-hour limit"
            case .weekly: return "weekly limit"
            case .other(let minutes): return "\(minutes)-minute limit"
            }
        }
    }

    var window: Window
    var usedPercent: Double?
    var resetsAt: Date?
    /// True only when the provider says the limit is actually reached. "Close
    /// to" is not reached, and acting on the difference is the whole point.
    var isReached: Bool

    /// Whether this reading still describes the present.
    ///
    /// A rollout's newest reading can be hours old, and "100% used, resets at
    /// 13:50" stops being true at 13:50 — nothing writes a correction, the file
    /// simply goes quiet. So a reset time that has passed means the limit is no
    /// longer blocking, and a reading with no reset time is not evidence of
    /// blocking at all.
    func isBlocking(now: Date = Date()) -> Bool {
        guard isReached, let resetsAt else { return false }
        return resetsAt > now
    }

    /// What to put on a blocked session's row.
    func reason(now: Date = Date()) -> String {
        guard let resetsAt, resetsAt > now else {
            return "Usage limit reached (\(window.label))"
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(resetsAt) ? .none : .medium
        return "Usage limit reached — resets \(formatter.string(from: resetsAt))"
    }
}

/// What is known about each provider's account limits.
///
/// One slot per provider per window, because a usage limit is a property of the
/// **account**, not of a session: whichever session happened to hit the wall is
/// the only one that recorded it, but every session of that provider is equally
/// blocked. Keeping it per-session meant a blocked account explained one row and
/// left the rest claiming to be ready.
struct AccountLimits: Equatable {
    private var byProvider: [String: [UsageLimit.Window: UsageLimit]] = [:]

    /// Merges a reading in. Later reset wins for the same window: readings carry
    /// no observation time, but a later reset can only come from a newer window,
    /// and anything stale expires on its own through `isBlocking(now:)`.
    mutating func record(_ limit: UsageLimit, for provider: String) {
        let existing = byProvider[provider]?[limit.window]
        guard let existing else {
            byProvider[provider, default: [:]][limit.window] = limit
            return
        }
        let new = limit.resetsAt ?? .distantPast
        let old = existing.resetsAt ?? .distantPast
        if new > old { byProvider[provider, default: [:]][limit.window] = limit }
    }

    /// The window standing between this provider and progress, soonest reset
    /// first — that is the one the user is waiting on.
    func blockingLimit(for provider: String, now: Date = Date()) -> UsageLimit? {
        byProvider[provider]?.values
            .filter { $0.isBlocking(now: now) }
            .min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    func limits(for provider: String) -> [UsageLimit] {
        Array(byProvider[provider]?.values ?? [:].values)
    }
}

/// Decides when an account limit is what a row should say, in one place for
/// every provider.
enum UsageLimitPresentation {
    /// Turn-end events, i.e. the reds that mean "your turn, nothing is wrong".
    /// A `Notification` red is a permission prompt: the user genuinely is
    /// needed, and overwriting that with a quota message would hide the one
    /// thing this app exists to surface.
    private static let turnEndedEvents: Set<String> = ["Stop", "task_complete", "turn_aborted"]

    static func apply(_ limit: UsageLimit?, to session: AgentSession, now: Date = Date())
        -> AgentSession
    {
        guard let limit, limit.isBlocking(now: now),
            session.state == .needsYou,
            let event = session.lastEvent, turnEndedEvents.contains(event)
        else { return session }
        var explained = session
        explained.reason = limit.reason(now: now)
        return explained
    }
}

/// Reads Codex's own rate-limit reporting out of a rollout `token_count` event.
///
/// Pure, and deliberately tolerant: this is Codex's format, not ours, and the
/// shape has already changed once (a `secondary` window that stopped being
/// populated). Anything unrecognized yields nil rather than a guess.
enum CodexUsageLimit {
    /// The `rate_limits` object as it appears inside a `token_count` payload.
    ///
    /// - Parameter object: the value of `payload.rate_limits`.
    static func parse(_ object: [String: Any]) -> UsageLimit? {
        // `rate_limit_reached_type` is the explicit "you are blocked" flag;
        // 100% used is the same thing said arithmetically. Either counts, since
        // the flag was never non-null across 1258 local rollouts and cannot be
        // relied on alone.
        let reachedFlag = object["rate_limit_reached_type"] as? String
        let windows = ["primary", "secondary"].compactMap { key -> UsageLimit? in
            guard let window = object[key] as? [String: Any] else { return nil }
            return parseWindow(window, reachedFlag: reachedFlag != nil)
        }
        // The window closest to its limit is the one that will block work, and
        // the one worth reporting when both are known.
        return windows.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    private static func parseWindow(_ object: [String: Any], reachedFlag: Bool) -> UsageLimit? {
        guard let minutes = object["window_minutes"] as? Int else { return nil }
        let used = object["used_percent"] as? Double
        let resetsAt = (object["resets_at"] as? Double).flatMap { seconds -> Date? in
            // Epoch seconds. A zero or negative value is absent, not 1970.
            seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        return UsageLimit(
            window: UsageLimit.Window(minutes: minutes),
            usedPercent: used,
            resetsAt: resetsAt,
            isReached: reachedFlag || (used ?? 0) >= 100
        )
    }
}
