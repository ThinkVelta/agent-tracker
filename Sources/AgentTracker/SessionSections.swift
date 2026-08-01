import Foundation

/// Groups the dropdown's sessions into per-state sections and decides which
/// rows actually get drawn. Pure and I/O-free so the fiddly parts — the row
/// budget and the collapse precedence — are unit-testable without a view.
enum SessionSections {
    struct Section: Identifiable, Equatable {
        let state: SessionState
        /// Everything in this state, before the row budget is applied.
        let total: Int
        /// The rows actually drawn — empty when the section is collapsed.
        let rows: [AgentSession]
        let isCollapsed: Bool

        var id: SessionState { state }
        /// Rows dropped by the budget. Collapsed sections report none: their
        /// header already states the count and the chevron says where they went.
        var hiddenByBudget: Int { isCollapsed ? 0 : total - rows.count }
    }

    /// - Parameters:
    ///   - overrides: explicit per-state collapse choices, which always win.
    ///   - autoCollapseIdle: whether idle *may* fold itself away. False while a
    ///     filter or search is narrowing the list, when hiding matches would
    ///     be a lie.
    ///   - budget: total rows to draw, spent in state order so a long idle
    ///     tail can never push a needs-you row off the list.
    static func build(
        from sessions: [AgentSession],
        overrides: [SessionState: Bool] = [:],
        autoCollapseIdle: Bool = true,
        budget: Int = Theme.Metrics.maxVisibleRows,
        idleAutoCollapseThreshold: Int = Theme.Metrics.idleAutoCollapseThreshold
    ) -> [Section] {
        let grouped = Dictionary(grouping: sessions, by: \.state)
        var remaining = max(0, budget)
        return SessionState.allCases.compactMap { state in
            // States with nothing in them are dropped: a "NEEDS YOU" heading
            // over empty space reads as a broken list, not as good news.
            guard let all = grouped[state], !all.isEmpty else { return nil }
            let collapsed =
                overrides[state]
                ?? (state == .idle && autoCollapseIdle
                    && all.count > idleAutoCollapseThreshold)
            guard !collapsed else {
                return Section(state: state, total: all.count, rows: [], isCollapsed: true)
            }
            let rows = Array(all.prefix(remaining))
            remaining -= rows.count
            return Section(state: state, total: all.count, rows: rows, isCollapsed: false)
        }
    }
}
