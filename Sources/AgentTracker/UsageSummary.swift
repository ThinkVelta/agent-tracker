import Foundation

/// One provider's usage, as the dropdown shows it.
struct UsageReading: Equatable, Identifiable, Sendable {
    var provider: String
    var window: UsageLimit.Window
    /// 0-100. Absent readings are dropped rather than shown as zero, because
    /// "no data" and "none used" are the two things this must never confuse.
    var usedPercent: Double
    var resetsAt: Date?

    var id: String { "\(provider)-\(window)" }

    var providerLabel: String {
        switch provider {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return provider.capitalized
        }
    }

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
/// The app already reads all of this — Claude's from the statusline payload,
/// Codex's from the `token_count` lines in its rollouts — and until now threw it
/// away unless a limit was actually *reached*. That is the wrong moment to
/// start caring: by then the session has already stopped, and the number that
/// would have let someone pace their day went unread all day.
enum UsageSummary {
    /// One reading per provider: whichever of its windows is closest to its
    /// limit, since that is the one that will stop work first.
    ///
    /// Scoped to providers that actually have a session on screen. An account
    /// limit outlives the sessions that reported it — `AccountLimits` keeps a
    /// reading until its reset passes — so without this the footer would still
    /// be quoting Codex quota an hour after the last Codex session closed.
    static func readings(
        from limits: AccountLimits,
        providers: Set<String>,
        now: Date
    ) -> [UsageReading] {
        providers.compactMap { provider -> UsageReading? in
            let candidates = limits.limits(for: provider).compactMap { limit -> UsageReading? in
                guard let used = limit.usedPercent else { return nil }
                // A reading whose window has already reset describes a window
                // that no longer exists. Nothing writes a correction — the file
                // simply goes quiet — so staleness has to be read off the clock.
                if let resetsAt = limit.resetsAt, resetsAt <= now { return nil }
                return UsageReading(
                    provider: provider, window: limit.window, usedPercent: used,
                    resetsAt: limit.resetsAt)
            }
            return candidates.max { $0.usedPercent < $1.usedPercent }
        }
        // Stable order, so two providers do not swap places between passes.
        .sorted { $0.provider < $1.provider }
    }
}
