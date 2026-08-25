import Foundation

/// A background shell Claude left running when its turn ended, as the hook
/// recorded it from the `Stop` payload's `background_tasks`.
struct BackgroundTask: Codable, Equatable {
    var id: String
    var type: String?
    var description: String?
    var command: String?
    /// The first `Stop` that listed it. Claude reports no start time, so this
    /// is the oldest age the row can honestly claim.
    var firstSeenAt: Date?

    func age(at now: Date) -> TimeInterval? {
        firstSeenAt.map { now.timeIntervalSince($0) }
    }
}

extension AgentSession {
    /// The shell that has been running longest, first-sighting order.
    var oldestBackgroundTask: BackgroundTask? {
        backgroundTasks?.min {
            ($0.firstSeenAt ?? .distantFuture) < ($1.firstSeenAt ?? .distantFuture)
        }
    }

    /// The oldest shell that has outlived `threshold` without the harness
    /// waking the session, skipping any the user already marked seen. Nil when
    /// the check is off (`threshold` 0), nothing is recorded, or every shell is
    /// younger than that.
    func staleBackgroundTask(after threshold: TimeInterval, now: Date) -> BackgroundTask? {
        guard threshold > 0, let backgroundTasks else { return nil }
        let seen = Set(seenBackgroundTaskIds ?? [])
        return
            backgroundTasks
            .filter { !seen.contains($0.id) && ($0.age(at: now) ?? 0) >= threshold }
            .max { ($0.age(at: now) ?? 0) < ($1.age(at: now) ?? 0) }
    }
}

enum DurationText {
    /// "3h 22m", "12m", "40s": a running time in the row's own compact style.
    static func describe(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }
}
