import Foundation
import Testing

@testable import AgentTracker

@Suite("Context pressure")
struct ContextPressureTests {
    /// Absent and comfortable must not look the same. Hiding the number below
    /// the threshold — which this used to do — meant a glance could not tell
    /// "plenty of room" from "no reading at all", and keeping those two apart
    /// is a rule the rest of the app follows carefully.
    @Test("a reading always shows; only no reading at all is nothing")
    func onlyAbsenceIsSilent() {
        #expect(ContextPressure(usedPercent: nil) == nil)
        #expect(ContextPressure(usedPercent: 0)?.label == "0%")
        #expect(ContextPressure(usedPercent: 31)?.label == "31%")
    }

    /// The number is always there; what changes is how loudly it is set. Quiet
    /// is drawn like the timestamp beside it, so the row reads as one line
    /// until it has something to say.
    @Test("emphasis rises with the reading, at the stated thresholds")
    func emphasisFollowsTheThresholds() {
        #expect(ContextPressure(usedPercent: 0)?.emphasis == .quiet)
        #expect(ContextPressure(usedPercent: 69.4)?.emphasis == .quiet)
        #expect(ContextPressure(usedPercent: 70)?.emphasis == .warning)
        #expect(ContextPressure(usedPercent: 89.4)?.emphasis == .warning)
        #expect(ContextPressure(usedPercent: 90)?.emphasis == .critical)
        #expect(ContextPressure(usedPercent: 100)?.emphasis == .critical)
    }

    /// Rounding happens once, at construction, so the emphasis and the label
    /// are decided about the same number. Ranking on the raw value let 89.6
    /// render as "90%" in the warning colour, which reads as a broken colour
    /// rather than as a rounding rule.
    @Test("what is shown is what is ranked")
    func roundingIsDecidedOnce() {
        #expect(ContextPressure(usedPercent: 84.2)?.label == "84%")

        let borderline = ContextPressure(usedPercent: 89.6)
        #expect(borderline?.label == "90%")
        #expect(borderline?.emphasis == .critical)

        // Same rule at the quiet edge.
        let edge = ContextPressure(usedPercent: 69.6)
        #expect(edge?.label == "70%")
        #expect(edge?.emphasis == .warning)
    }

    @Test("the tooltip says what the number is, since the row cannot")
    func helpIsSelfExplanatory() {
        #expect(ContextPressure(usedPercent: 84)?.help == "84% of the context window used")
    }
}
