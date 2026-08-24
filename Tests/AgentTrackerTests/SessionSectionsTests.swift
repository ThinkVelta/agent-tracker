import Testing

@testable import AgentTracker

final class SessionSectionsTests {
    private func sessions(
        _ state: SessionState, _ count: Int, project: String = "demo"
    ) -> [AgentSession] {
        (0..<count).map {
            AgentSession(
                sessionId: "\(state.rawValue)-\(project)-\($0)",
                cwd: "/Users/dev/\(project)", state: state)
        }
    }

    /// Sections are keyed by string now, so the collapse overrides are too.
    private func collapsed(_ state: SessionState) -> [String: Bool] {
        [state.rawValue: true]
    }

    @Test func sectionsFollowStateOrderAndSkipEmptyStates() {
        let built = SessionSections.build(
            from: sessions(.idle, 1) + sessions(.needsYou, 2))
        #expect(built.map(\.accent) == [.needsYou, .idle])
        #expect(built.map(\.id) == ["needsYou", "idle"])
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

    /// Nothing collapses on its own any more: the automatic idle folding was
    /// retired as complexity without value, so a long idle section stays
    /// listed unless the user folded it themselves.
    @Test func nothingCollapsesWithoutAnExplicitChoice() {
        let built = SessionSections.build(from: sessions(.idle, 40))
        #expect(built.first?.isCollapsed == false)
    }

    /// Hiding rows while the user is narrowing the list would be a lie about
    /// how many things matched: narrowing strips even an explicit idle fold.
    @Test func narrowingForcesAUserFoldedIdleOpen() {
        let overrides = SessionSections.overridesForNarrowing(
            [SessionState.idle.rawValue: true], narrowing: true)
        let built = SessionSections.build(from: sessions(.idle, 9), overrides: overrides)
        #expect(built.first?.isCollapsed == false)
        #expect(built.first?.rows.count == 9)
    }

    @Test func explicitChoicesDecideCollapse() {
        let forcedOpen = SessionSections.build(
            from: sessions(.idle, 9), overrides: [SessionState.idle.rawValue: false])
        #expect(forcedOpen.first?.isCollapsed == false)
        let forcedShut = SessionSections.build(
            from: sessions(.needsYou, 2), overrides: collapsed(.needsYou))
        #expect(forcedShut.first?.isCollapsed == true)
    }

    /// Narrowing (a filter or search) must surface matches even in a section
    /// the user collapsed by hand — and hand the choice back untouched once
    /// the narrowing clears.
    @Test func narrowingForcesACollapsedIdleSectionOpen() {
        let overrides: [String: Bool] = [
            SessionState.idle.rawValue: true, SessionState.running.rawValue: true,
        ]
        let narrowed = SessionSections.overridesForNarrowing(overrides, narrowing: true)
        #expect(narrowed[SessionState.idle.rawValue] == false)
        // Only idle is forced — a collapsed running section is the user's call.
        #expect(narrowed[SessionState.running.rawValue] == true)
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
            overrides: collapsed(.idle),
            budget: 4
        )
        #expect(built.map(\.rows.count) == [4, 0])
        #expect(built.reduce(0) { $0 + $1.hiddenByBudget } == 0)
    }

    // MARK: - Grouping by project

    /// The point of the mode: six sessions in one repo become one heading
    /// instead of being scattered across three state sections.
    @Test func projectGroupingGathersARepoIntoOneSection() {
        let built = SessionSections.build(
            from: sessions(.needsYou, 1, project: "planner")
                + sessions(.running, 2, project: "planner")
                + sessions(.idle, 1, project: "tracker"),
            grouping: .project)

        #expect(built.map(\.title) == ["planner", "tracker"])
        #expect(built.map(\.total) == [3, 1])
    }

    /// A repo with something waiting on you leads the list, exactly as that
    /// session would have under the state grouping — and its dot says so, so
    /// the section cannot read as calm while holding a red row.
    @Test func aProjectTakesTheMostUrgentStateInIt() {
        let built = SessionSections.build(
            from: sessions(.idle, 1, project: "quiet")
                + sessions(.running, 1, project: "busy")
                + sessions(.needsYou, 1, project: "waiting")
                + sessions(.idle, 3, project: "waiting"),
            grouping: .project)

        #expect(built.map(\.title) == ["waiting", "busy", "quiet"])
        #expect(built.map(\.accent) == [.needsYou, .running, .idle])
    }

    /// Alphabetical inside a tier, so a section does not jump because a row
    /// inside it changed.
    @Test func projectsOfEqualUrgencyAreOrderedByName() {
        let built = SessionSections.build(
            from: sessions(.running, 1, project: "zulu") + sessions(.running, 1, project: "alpha"),
            grouping: .project)
        #expect(built.map(\.title) == ["alpha", "zulu"])
    }

    /// A project is never collapsed unless somebody collapsed it, however
    /// many idle rows it holds.
    @Test func nothingAutoCollapsesUnderProjectGrouping() {
        let built = SessionSections.build(
            from: sessions(.idle, 20, project: "planner"), grouping: .project)
        #expect(built.first?.isCollapsed == false)
    }

    /// Section ids are namespaced, so a project called "idle" cannot inherit
    /// the idle state section's collapse choice.
    @Test func aProjectCannotInheritAStateSectionsCollapse() {
        let built = SessionSections.build(
            from: sessions(.running, 2, project: "idle"),
            grouping: .project, overrides: collapsed(.idle))
        #expect(built.first?.id == "project:/Users/dev/idle")
        #expect(built.first?.isCollapsed == false)
    }

    /// Two repos sharing a leaf name is an ordinary thing to have — an `api`
    /// at work and an `api` in your own account. Grouping on the NAME filed
    /// them under one heading with nothing on screen to say the rows came from
    /// different places, which is worse than not offering the mode.
    @Test func repositoriesSharingANameAreNotOneProject() {
        var work = AgentSession(sessionId: "w", cwd: "/Users/dev/work/acme/api", state: .running)
        var personal = AgentSession(sessionId: "p", cwd: "/Users/dev/oss/api", state: .running)
        work.registryName = nil
        personal.registryName = nil

        let built = SessionSections.build(from: [work, personal], grouping: .project)

        #expect(built.count == 2)
        // Both are still *called* api — the name is a label, the path is the
        // identity.
        #expect(built.map(\.title) == ["api", "api"])
        #expect(Set(built.map(\.id)).count == 2)
    }

    /// The order has to be total, and the case that makes it so is the one the
    /// path-keying introduced: two projects CAN share a title now. Sorting on
    /// urgency and title alone left those to the dictionary's whim.
    @Test func sectionsSharingATitleAndAStateKeepTheirOrder() {
        let work = AgentSession(sessionId: "w", cwd: "/Users/dev/work/acme/api", state: .running)
        let personal = AgentSession(sessionId: "p", cwd: "/Users/dev/oss/api", state: .running)

        // Repeated because the source is a dictionary: a missing tiebreak shows
        // up as an intermittent swap, not as a failure every run.
        for _ in 0..<50 {
            let built = SessionSections.build(from: [work, personal], grouping: .project)
            #expect(
                built.map(\.id) == [
                    "project:/Users/dev/oss/api", "project:/Users/dev/work/acme/api",
                ])
        }
    }

    /// The other half of the same rule: worktrees of one repo are one project,
    /// which is exactly what somebody with three branches checked out wants.
    @Test func worktreesOfOneRepositoryStayTogether() {
        let root = AgentSession(
            sessionId: "root", cwd: "/Users/dev/acme/planner", state: .running)
        let branch = AgentSession(
            sessionId: "branch",
            cwd: "/Users/dev/acme/planner/.claude/worktrees/pln-388", state: .needsYou)

        let built = SessionSections.build(from: [root, branch], grouping: .project)

        #expect(built.count == 1)
        #expect(built.first?.title == "planner")
        #expect(built.first?.total == 2)
        // And the section wears the state of the row that needs somebody.
        #expect(built.first?.accent == .needsYou)
    }

    /// The budget is one allowance across the whole list either way.
    @Test func theRowBudgetStillAppliesAcrossProjects() {
        let built = SessionSections.build(
            from: sessions(.needsYou, 3, project: "first")
                + sessions(.running, 4, project: "second"),
            grouping: .project, budget: 5)
        #expect(built.map(\.rows.count) == [3, 2])
        #expect(built.reduce(0) { $0 + $1.hiddenByBudget } == 2)
    }
}
