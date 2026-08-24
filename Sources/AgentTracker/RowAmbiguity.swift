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
            let matchable = group.map { matchableName($0.name) }
            var uses: [String: Int] = [:]
            for name in matchable.compactMap({ $0 }) { uses[name, default: 0] += 1 }
            let collides = matchable.filter { name in
                guard let name else { return true }
                return uses[name, default: 0] > 1
            }
            count += collides.count
        }
        return count
    }

    /// A name as window matching sees it, through the rule the click path
    /// scores titles with. Case and the status glyphs a terminal prefixes onto
    /// a title are not what tells two rows apart, so `Review` and `✳ review`
    /// collide here exactly as they do on the click.
    ///
    /// A name that survives none of that matches no window at all, which leaves
    /// the row where an unnamed one is.
    private static func matchableName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = TerminalFocuser.normalize(name)
        return normalized.isEmpty ? nil : normalized
    }
}
