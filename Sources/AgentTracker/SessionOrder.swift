import Foundation

/// The order rows appear in: what needs you first, then most recently changed.
///
/// Lifted out of the store so the rule can be tested, because it is the one
/// ordering in the app that everything else inherits — the sections divide this
/// list, the row budget is spent along it, and the menu bar counts what it
/// holds.
enum SessionOrder {
    /// A **total** order, and the tie it breaks is not hypothetical.
    ///
    /// `stateChangedAt` is written by the hook with second precision, so two
    /// sessions that change state in the same second carry byte-identical
    /// timestamps — ordinary with a fan-out, or with several sessions finishing
    /// together. Swift's `sorted(by:)` is not stable either, so equal elements
    /// can swap on any pass with nothing behind it; and because `sessions` is
    /// published and compared before assignment, each swap is a republish and a
    /// visible jump rather than a redraw.
    ///
    /// The session id settles it. Arbitrary, but *fixed* — which is the only
    /// property a last-resort tiebreak needs.
    static func precedes(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.state != rhs.state {
            return lhs.state.sortRank < rhs.state.sortRank
        }
        let lhsChanged = lhs.stateChangedAt ?? .distantPast
        let rhsChanged = rhs.stateChangedAt ?? .distantPast
        if lhsChanged != rhsChanged { return lhsChanged > rhsChanged }
        return lhs.id < rhs.id
    }
}
