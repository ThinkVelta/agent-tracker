import Foundation
import Testing

@testable import AgentTracker

@Suite("Session naming")
struct SessionNamingTests {
    private func session(
        _ id: String,
        cwd: String,
        registryName: String? = nil,
        chosen: Bool = false
    ) -> AgentSession {
        var session = AgentSession(sessionId: id, cwd: cwd, state: .running)
        session.registryName = registryName
        session.registryNameIsChosen = chosen
        return session
    }

    /// The common list has no duplicates at all, and putting `-a5` on every row
    /// there is the objection that kept the registry name out originally. It
    /// was right about that much.
    @Test("a row that is already unique keeps its project name")
    func uniqueRowsAreUntouched() {
        let titles = SessionNaming.titles(for: [
            session("s1", cwd: "/Users/dev/acme/planner", registryName: "planner-a5"),
            session("s2", cwd: "/Users/dev/acme/checkout", registryName: "checkout-b2"),
        ])
        #expect(titles["s1"] == "planner")
        #expect(titles["s2"] == "checkout")
    }

    /// The whole point. Three sessions in one repo rendered as three identical
    /// rows, and the only way to tell them apart was to click one and see where
    /// you landed.
    @Test("sessions sharing a project take the name Claude gave them")
    func ambiguousRowsUseTheRegistryName() {
        let titles = SessionNaming.titles(for: [
            session("s1", cwd: "/Users/dev/acme/planner", registryName: "planner-a5"),
            session("s2", cwd: "/Users/dev/acme/planner", registryName: "planner-ac"),
            session("s3", cwd: "/Users/dev/acme/planner", registryName: "planner-5b"),
        ])
        #expect(titles["s1"] == "planner-a5")
        #expect(titles["s2"] == "planner-ac")
        #expect(titles["s3"] == "planner-5b")
    }

    /// The location line already separates a worktree row from its repo, so
    /// those are not ambiguous and must not be renamed — this steps in only
    /// where that is not enough either.
    @Test("a worktree row is already distinct and keeps its project name")
    func locationAlreadyDisambiguates() {
        let titles = SessionNaming.titles(for: [
            session("s1", cwd: "/Users/dev/acme/planner", registryName: "planner-a5"),
            session(
                "s2", cwd: "/Users/dev/acme/planner/.claude/worktrees/pln-388",
                registryName: "planner-ac"),
        ])
        #expect(titles["s1"] == "planner")
        #expect(titles["s2"] == "planner")
    }

    /// An older Claude, or a session whose registry entry has not landed yet.
    /// Two such rows stay indistinguishable, which is exactly as bad as before
    /// and no worse — the row must not go blank or say "nil".
    @Test("a session with no registry name falls back rather than disappearing")
    func missingRegistryNameFallsBack() {
        let titles = SessionNaming.titles(for: [
            session("s1", cwd: "/Users/dev/acme/planner"),
            session("s2", cwd: "/Users/dev/acme/planner", registryName: "planner-ac"),
        ])
        #expect(titles["s1"] == "planner")
        #expect(titles["s2"] == "planner-ac")
    }

    /// Grouping joins two fields, so the separator has to be one that cannot
    /// appear in either — otherwise "ab" + "c" and "a" + "bc" collide and two
    /// unrelated rows would rename each other.
    @Test("the grouping key cannot be forged out of its two halves")
    func groupingIsNotConfusedBySplits() {
        let titles = SessionNaming.titles(for: [
            session("s1", cwd: "/Users/dev/ab/c", registryName: "c-a5"),
            session("s2", cwd: "/Users/dev/a/bc", registryName: "bc-ac"),
        ])
        #expect(titles["s1"] == "c")
        #expect(titles["s2"] == "bc")
    }

    @Test("every session gets a title, and none is empty")
    func everySessionIsNamed() {
        let sessions = [
            session("s1", cwd: "/Users/dev/acme/planner", registryName: "planner-a5"),
            session("s2", cwd: "/Users/dev/acme/planner", registryName: "planner-ac"),
            session("s3", cwd: "/Users/dev/oss/docs"),
        ]
        let titles = SessionNaming.titles(for: sessions)
        #expect(titles.count == sessions.count)
        #expect(titles.values.allSatisfy { !$0.isEmpty })
    }

    /// `/rename` is somebody saying what this session is. Answering that with
    /// the directory name, on the grounds that the app judged the row
    /// unambiguous, would be overruling them about their own session.
    @Test("a name the user chose shows even when nothing is ambiguous")
    func aChosenNameAlwaysShows() {
        let titles = SessionNaming.titles(for: [
            session(
                "s1", cwd: "/Users/dev/acme/planner", registryName: "billing spike",
                chosen: true),
            session("s2", cwd: "/Users/dev/acme/checkout", registryName: "checkout-b2"),
        ])
        #expect(titles["s1"] == "billing spike")
        #expect(titles["s2"] == "checkout")
    }

    /// The two rules coexist: a chosen name wins on its own, and a derived slug
    /// beside it still earns its place by disambiguating.
    @Test("chosen and derived names can sit in the same group")
    func chosenAndDerivedTogether() {
        let titles = SessionNaming.titles(for: [
            session(
                "s1", cwd: "/Users/dev/acme/planner", registryName: "the migration",
                chosen: true),
            session("s2", cwd: "/Users/dev/acme/planner", registryName: "planner-ac"),
            session("s3", cwd: "/Users/dev/acme/planner", registryName: "planner-5b"),
        ])
        #expect(titles["s1"] == "the migration")
        #expect(titles["s2"] == "planner-ac")
        #expect(titles["s3"] == "planner-5b")
    }
}
