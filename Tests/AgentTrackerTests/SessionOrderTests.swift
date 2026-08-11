import Foundation
import Testing

@testable import AgentTracker

@Suite("Session order")
struct SessionOrderTests {
    private let moment = Date(timeIntervalSince1970: 1_786_705_200)

    private func session(
        _ id: String, _ state: SessionState = .running, changedAt: Date? = nil
    ) -> AgentSession {
        var session = AgentSession(sessionId: id, cwd: "/Users/dev/demo", state: state)
        session.stateChangedAt = changedAt
        return session
    }

    @Test("what needs you comes first, then what changed most recently")
    func stateThenRecency() {
        let rows = [
            session("a", .idle, changedAt: moment),
            session("b", .needsYou, changedAt: moment.addingTimeInterval(-60)),
            session("c", .running, changedAt: moment),
            session("d", .needsYou, changedAt: moment),
        ]
        #expect(rows.sorted(by: SessionOrder.precedes).map(\.sessionId) == ["d", "b", "c", "a"])
    }

    /// The tie this exists for, and it is not exotic: the hook writes
    /// `stateChangedAt` with SECOND precision, so two sessions changing state
    /// in the same second are byte-identical here. A fan-out does that.
    ///
    /// Shuffled inputs rather than one order, because `sorted(by:)` is not
    /// stable — a partial comparator does not fail every run, it fails the runs
    /// where the introsort happens to move things.
    @Test("sessions that changed in the same second keep a fixed order")
    func identicalTimestampsDoNotSwap() {
        let rows = (0..<8).map { session("s\($0)", .needsYou, changedAt: moment) }
        let expected = rows.map(\.sessionId).sorted()

        for _ in 0..<50 {
            #expect(rows.shuffled().sorted(by: SessionOrder.precedes).map(\.sessionId) == expected)
        }
    }

    /// A row with no timestamp at all is the same tie by another route — two of
    /// them are both `.distantPast`.
    @Test("rows with no timestamp are ordered, not left to chance")
    func missingTimestampsAreOrdered() {
        let rows = (0..<6).map { session("n\($0)", .running) }
        let expected = rows.map(\.sessionId).sorted()

        for _ in 0..<50 {
            #expect(rows.shuffled().sorted(by: SessionOrder.precedes).map(\.sessionId) == expected)
        }
    }

    /// A dated row still outranks an undated one — the tiebreak must not have
    /// swallowed the rule it backs up.
    @Test("a known change time still beats an unknown one")
    func recencyStillWinsOverAbsence() {
        let dated = session("dated", .running, changedAt: moment)
        let undated = session("aaa-undated", .running)
        #expect(SessionOrder.precedes(dated, undated))
        #expect(!SessionOrder.precedes(undated, dated))
    }
}
