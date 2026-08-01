import Testing

@testable import AgentTracker

final class SessionSectionsTests {
    private func sessions(_ state: SessionState, _ count: Int) -> [AgentSession] {
        (0..<count).map {
            AgentSession(
                provider: "claude-code", sessionId: "\(state.rawValue)-\($0)", state: state)
        }
    }

    @Test func sectionsFollowStateOrderAndSkipEmptyStates() {
        let built = SessionSections.build(
            from: sessions(.idle, 1) + sessions(.needsYou, 2), autoCollapseIdle: false)
        #expect(built.map(\.state) == [.needsYou, .idle])
        #expect(built.map(\.total) == [2, 1])
    }

    @Test func noSessionsProduceNoSections() {
        #expect(SessionSections.build(from: []).isEmpty)
    }

    /// The budget is spent in state order, so a long idle tail can never push
    /// a needs-you row out of the list.
    @Test func rowBudgetIsSpentNeedsYouFirst() {
        let built = SessionSections.build(
            from: sessions(.needsYou, 3) + sessions(.running, 4) + sessions(.idle, 20),
            autoCollapseIdle: false,
            budget: 5
        )
        #expect(built.map(\.rows.count) == [3, 2, 0])
        #expect(built.map(\.total) == [3, 4, 20])
        #expect(built.reduce(0) { $0 + $1.hiddenByBudget } == 22)
    }

    @Test func budgetOfZeroDrawsNothingButStillReportsTotals() {
        let built = SessionSections.build(from: sessions(.running, 3), budget: 0)
        #expect(built.map(\.rows.count) == [0])
        #expect(built.first?.total == 3)
        #expect(built.first?.hiddenByBudget == 3)
    }

    @Test func idleCollapsesItselfOnlyOnceItIsLongEnough() {
        let atThreshold = SessionSections.build(from: sessions(.idle, 3))
        #expect(atThreshold.first?.isCollapsed == false)
        let overThreshold = SessionSections.build(from: sessions(.idle, 4))
        #expect(overThreshold.first?.isCollapsed == true)
        #expect(overThreshold.first?.rows.isEmpty == true)
        #expect(overThreshold.first?.total == 4)
    }

    /// Hiding rows while the user is narrowing the list would be a lie about
    /// how many things matched.
    @Test func idleStaysExpandedWhileFilteringOrSearching() {
        let built = SessionSections.build(from: sessions(.idle, 9), autoCollapseIdle: false)
        #expect(built.first?.isCollapsed == false)
        #expect(built.first?.rows.count == 9)
    }

    @Test func explicitChoiceBeatsAutomaticCollapse() {
        let forcedOpen = SessionSections.build(from: sessions(.idle, 9), overrides: [.idle: false])
        #expect(forcedOpen.first?.isCollapsed == false)
        let forcedShut = SessionSections.build(
            from: sessions(.needsYou, 2), overrides: [.needsYou: true])
        #expect(forcedShut.first?.isCollapsed == true)
    }

    /// Narrowing (a filter or search) must surface matches even in a section
    /// the user collapsed by hand — and hand the choice back untouched once
    /// the narrowing clears.
    @Test func narrowingForcesACollapsedIdleSectionOpen() {
        let overrides: [SessionState: Bool] = [.idle: true, .running: true]
        let narrowed = SessionSections.overridesForNarrowing(overrides, narrowing: true)
        #expect(narrowed[.idle] == false)
        // Only idle is forced — a collapsed running section is the user's call.
        #expect(narrowed[.running] == true)
        // Not narrowing: the original choices pass through untouched.
        #expect(SessionSections.overridesForNarrowing(overrides, narrowing: false) == overrides)

        let built = SessionSections.build(from: sessions(.idle, 9), overrides: narrowed)
        #expect(built.first?.isCollapsed == false)
        #expect(built.first?.rows.count == 9)
    }

    /// A collapsed section's rows aren't "hidden by the budget" — its own
    /// header states the count, so counting them again would double-report.
    @Test func collapsedSectionsFreeTheirBudgetForOtherStates() {
        let built = SessionSections.build(
            from: sessions(.needsYou, 4) + sessions(.idle, 10),
            overrides: [.idle: true],
            budget: 4
        )
        #expect(built.map(\.rows.count) == [4, 0])
        #expect(built.reduce(0) { $0 + $1.hiddenByBudget } == 0)
    }
}
