import Foundation

/// What to call a row when its project name is not enough.
///
/// Sessions are titled by project, which is right until two of them share one.
/// Then the list shows the same word twice with the same location under it, and
/// the only way to tell which is which is to click one and see where you land —
/// on a machine with three sessions in one repo, that is the list failing at
/// the one job it has.
///
/// Claude already solves this for itself: the session registry gives every
/// session a name of its own (`planner-a5`, `planner-ac`, `planner-5b` — a slug
/// and a short suffix), and it is the name Claude shows in that session's own
/// terminal. So an ambiguous row does not need a new idea, it needs to stop
/// ignoring the name the agent already gave it.
///
/// **Only when ambiguous.** A registry name on every row would put a meaningless
/// `-a5` on the majority of lists that have no duplicate at all — which is the
/// objection that kept this out originally, and it was right about that much.
enum SessionNaming {
    /// Row titles keyed by session id.
    ///
    /// - Parameter sessions: every row that will be on screen together. Rows
    ///   filtered out of the list cannot be confused with anything, so passing
    ///   the whole set would disambiguate against sessions the user cannot see.
    static func titles(for sessions: [AgentSession]) -> [String: String] {
        var byLabel: [String: [AgentSession]] = [:]
        for session in sessions {
            byLabel[label(of: session), default: []].append(session)
        }

        var titles: [String: String] = [:]
        for (_, group) in byLabel {
            let ambiguous = group.count > 1
            for session in group {
                // Falls back to the project name when the registry has nothing
                // for this session — an older Claude, or one whose registry
                // entry has not been written yet. Two such rows stay
                // indistinguishable, which is no worse than before.
                titles[session.sessionId] =
                    ambiguous ? (session.registryName ?? session.displayName) : session.displayName
            }
        }
        return titles
    }

    /// What the row shows today: the name, and the location under it. Both,
    /// because the location is already what separates a worktree row from its
    /// repo — this only steps in where that is not enough either.
    private static func label(of session: AgentSession) -> String {
        // A separator that cannot occur in either half, so "ab" + "c" and "a" +
        // "bc" are not one group.
        "\(session.displayName)\u{0}\(session.locationContext ?? "")"
    }
}
