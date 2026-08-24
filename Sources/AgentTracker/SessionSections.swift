import Foundation

/// Groups the dropdown's sessions into sections and decides which rows actually
/// get drawn. Pure and I/O-free so the fiddly parts — the row budget and the
/// collapse precedence — are unit-testable without a view.
enum SessionSections {
    /// What the list is organised by.
    ///
    /// State is the default because the app's question is "which one needs me",
    /// and that is a state. Project answers a different one — "what is going on
    /// in this repo" — which is what you want when six of your sessions live in
    /// one codebase and the state grouping scatters them across three headings.
    enum Grouping: String, CaseIterable {
        case state
        case project

        var label: String {
            switch self {
            case .state: return "State"
            case .project: return "Project"
            }
        }
    }

    struct Section: Identifiable, Equatable {
        /// Stable across passes, and what a collapse choice is stored under.
        /// Namespaced by grouping so a project called "idle" cannot inherit the
        /// idle section's collapse state.
        let id: String
        let title: String
        /// The dot beside the title. For a state grouping it is that state; for
        /// a project it is the most urgent state inside, because a project
        /// holding a needs-you session must not read as calm.
        let accent: SessionState
        /// Everything in this section, before the row budget is applied.
        let total: Int
        /// The rows actually drawn — empty when the section is collapsed.
        let rows: [AgentSession]
        let isCollapsed: Bool

        /// Rows dropped by the budget. Collapsed sections report none: their
        /// header already states the count and the chevron says where they went.
        var hiddenByBudget: Int { isCollapsed ? 0 : total - rows.count }
    }

    /// While a filter or search narrows the list, the idle section must show
    /// its matches, even when the user folded it. Forcing the override open
    /// (rather than dropping it) means the manual choice returns intact once
    /// the narrowing clears.
    ///
    /// Only idle is force-opened, and only while narrowing. Collapses are
    /// manual everywhere now; this rule exists because a user-folded idle must
    /// still show its matches while the list narrows, and it returns intact
    /// once the narrowing clears.
    static func overridesForNarrowing(
        _ overrides: [String: Bool], narrowing: Bool
    ) -> [String: Bool] {
        guard narrowing else { return overrides }
        return overrides.merging([SessionState.idle.rawValue: false]) { _, forced in forced }
    }

    /// - Parameters:
    ///   - grouping: what the sections divide on.
    ///   - overrides: explicit per-section collapse choices. Nothing collapses
    ///     without one; the automatic idle folding this once had was retired
    ///     as complexity without value.
    ///   - budget: total rows to draw, spent in section order so a long tail
    ///     can never push a needs-you row off the list.
    static func build(
        from sessions: [AgentSession],
        grouping: Grouping = .state,
        overrides: [String: Bool] = [:],
        budget: Int = Theme.Metrics.maxVisibleRows
    ) -> [Section] {
        var remaining = max(0, budget)
        return candidates(from: sessions, grouping: grouping).compactMap { candidate in
            let collapsed = overrides[candidate.id] ?? false
            guard !collapsed else {
                return Section(
                    id: candidate.id, title: candidate.title, accent: candidate.accent,
                    total: candidate.members.count, rows: [], isCollapsed: true)
            }
            let rows = Array(candidate.members.prefix(remaining))
            remaining -= rows.count
            return Section(
                id: candidate.id, title: candidate.title, accent: candidate.accent,
                total: candidate.members.count, rows: rows, isCollapsed: false)
        }
    }

    private struct Candidate {
        let id: String
        let title: String
        let accent: SessionState
        let members: [AgentSession]
    }

    private static func candidates(
        from sessions: [AgentSession], grouping: Grouping
    ) -> [Candidate] {
        switch grouping {
        case .state:
            let grouped = Dictionary(grouping: sessions, by: \.state)
            // States with nothing in them are dropped: a "NEEDS YOU" heading
            // over empty space reads as a broken list, not as good news.
            return SessionState.allCases.compactMap { state in
                guard let members = grouped[state], !members.isEmpty else { return nil }
                return Candidate(
                    id: state.rawValue, title: state.label, accent: state,
                    members: members)
            }
        case .project:
            // Keyed by the project's path, not its name: two repos can share a
            // leaf name, and filing unrelated work under one heading is worse
            // than not offering the grouping at all.
            let grouped = Dictionary(grouping: sessions, by: \.projectKey)
            return
                grouped
                .map { key, members in
                    let name = members.first?.displayName ?? "Session"
                    // The most urgent state inside decides both the dot and
                    // where the section sits, so a repo with something waiting
                    // on you leads the list exactly as that session would have.
                    let accent =
                        members.map(\.state).min { $0.sortRank < $1.sortRank } ?? .idle
                    return Candidate(
                        id: "project:\(key)", title: name, accent: accent,
                        members: members)
                }
                .sorted { lhs, rhs in
                    if lhs.accent != rhs.accent {
                        return lhs.accent.sortRank < rhs.accent.sortRank
                    }
                    // Alphabetical within a tier, so a section does not move
                    // just because a row inside it did.
                    let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    if byTitle != .orderedSame { return byTitle == .orderedAscending }
                    // And the path last, because two projects CAN share a title
                    // now — that is the whole reason this groups on the path.
                    // With only the title, two equally urgent `api` repos would
                    // be ordered by whatever the dictionary yielded first and
                    // swap between passes.
                    return lhs.id < rhs.id
                }
        }
    }
}
