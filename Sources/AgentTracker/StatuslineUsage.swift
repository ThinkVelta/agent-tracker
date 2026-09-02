import Foundation

/// The newest usage reading from each live session, as its statusline reports it.
///
/// Claude's numbers can go *down* inside a window: an account-side reset lands
/// mid-week, a limit is boosted, a plan changes and moves the denominator.
/// `AccountLimits` merges readings by strength — the higher percentage wins —
/// which is the right rule across sources, but applied across *time* it pinned
/// a pre-reset 65% to the strip for the rest of the week while every session
/// was reporting 5%.
///
/// So readings are not accumulated into the account picture. Each session's
/// latest reading replaces its own previous one — a session's own reports are
/// in time order, so its newest is its truest — and the account picture is
/// rebuilt from those on every pass. The cross-session merge stays a maximum,
/// deliberately: the capture alternates between writers, and an idle session
/// keeps re-rendering the numbers its last response carried, so "newest write
/// wins" would flicker between one session's current view and another's older
/// one on every tick. A session that is gone takes its reading with it.
struct StatuslineUsage {
    /// Payloads with no session id share one slot. There is nothing to tie
    /// them to, so they are never pruned; newest wins among them.
    static let anonymousSession = ""

    private var bySession: [String: [UsageLimit.Window: UsageLimit]] = [:]

    /// Absorbs one payload's readings. Per window, never wholesale: a payload
    /// that reports one window must not erase what that session said about the
    /// other, and a payload with none says nothing at all.
    mutating func record(_ limits: [UsageLimit], from sessionId: String?) {
        guard !limits.isEmpty else { return }
        let key = sessionId ?? Self.anonymousSession
        var windows = bySession[key] ?? [:]
        for limit in limits { windows[limit.window] = limit }
        bySession[key] = windows
    }

    /// Drops every session not in `live`, so a closed session cannot keep
    /// pinning a number nothing will ever update.
    mutating func retain(sessions live: Set<String>) {
        bySession = bySession.filter {
            $0.key == Self.anonymousSession || live.contains($0.key)
        }
    }

    /// The account picture: every session's latest reading merged on top of
    /// `limits`. A value, not a mutation — what this pass merged is not
    /// remembered by the next one, which is the whole point.
    func merged(into limits: AccountLimits) -> AccountLimits {
        var merged = limits
        for windows in bySession.values {
            for limit in windows.values { merged.record(limit) }
        }
        return merged
    }
}
