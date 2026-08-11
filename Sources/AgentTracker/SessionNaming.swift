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
/// **Only when ambiguous** — for the name Claude *derives*. A generated `-a5` on
/// every row would be noise on the majority of lists, which have no duplicate at
/// all.
///
/// A name the user *chose* is different and always shows. Claude marks the
/// difference itself: `nameSource: "derived"` for its own slug, and nothing at
/// all once someone runs `/rename` (or launched with `--name`). Suppressing a
/// name somebody typed, because the app judged the row unambiguous, would be
/// the app overruling them about their own session.
enum SessionNaming {
    /// Row titles keyed by session id.
    ///
    /// - Parameter sessions: the rows the current filter and search admit —
    ///   not every session, because a row cannot be confused with one the user
    ///   has filtered away.
    ///
    ///   Deliberately *not* narrowed further to the rows actually painted. A
    ///   collapsed section hides rows without removing them, and deriving names
    ///   from what is painted would mean folding the idle section silently
    ///   renames a running row. A title that changes when you fold something
    ///   else is worse than a suffix whose sibling is one fold away: the suffix
    ///   is never wrong, only occasionally unexplained until you look.
    static func titles(for sessions: [AgentSession]) -> [String: String] {
        var byLabel: [String: [AgentSession]] = [:]
        for session in sessions {
            byLabel[label(of: session), default: []].append(session)
        }

        var titles: [String: String] = [:]
        for (_, group) in byLabel {
            let ambiguous = group.count > 1
            for session in group {
                // A name the user typed always wins: `/rename` is someone
                // saying what this session is, and answering that with the
                // directory name would be ignoring them. A derived slug has to
                // earn its place by disambiguating.
                //
                // Falls back to the project name when the registry has nothing
                // for this session — an older Claude, or one whose registry
                // entry has not been written yet. Two such rows stay
                // indistinguishable, which is no worse than before.
                let registryName = session.registryName
                let earned = session.registryNameIsChosen || ambiguous
                titles[session.sessionId] =
                    (earned ? registryName : nil) ?? session.displayName
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
