import Foundation

/// Which live rows click-to-focus cannot resolve on its own, for `--doctor` to
/// report.
///
/// Kept out of `Diagnosis` for the reason every derivation in this app is kept
/// out of the thing that consumes it: the rule is the part worth testing, and
/// it needs neither a filesystem nor a report to exercise.
enum RowAmbiguity {
    /// One live session, reduced to what the rule needs.
    struct LiveSession: Equatable {
        /// The project this session belongs to, as `AgentSession.projectKey`
        /// derives it, so a worktree groups with the repo it came from.
        var projectKey: String
        /// The name click-to-focus matches this session's window by, coalesced
        /// through `SessionStore.coalescedWindowTitle` exactly as the running
        /// app coalesces it. nil when neither the registry nor a statusline
        /// payload names the session.
        var name: String?
    }

    /// How many rows are left with nothing to tell them apart.
    ///
    /// Sharing a project is not on its own enough to be confusable, because a
    /// window is matched by name: two sessions in one repo called different
    /// things resolve exactly. Counting by directory alone went on warning
    /// after a `/rename` had fixed it, and a report that names a solved problem
    /// teaches its reader to skip the line.
    ///
    /// A session nothing names counts, because there is no title to match its
    /// window on and it falls back to the directory its siblings share.
    static func unresolvedCount(_ sessions: [LiveSession]) -> Int {
        var count = 0
        for (_, group) in Dictionary(grouping: sessions, by: \.projectKey) where group.count > 1 {
            var uses: [String: Int] = [:]
            for name in group.compactMap(\.name) { uses[name, default: 0] += 1 }
            let collides = group.filter { session in
                guard let name = session.name else { return true }
                return uses[name, default: 0] > 1
            }
            count += collides.count
        }
        return count
    }
}
