import Foundation
import Testing

@testable import AgentTracker

@Suite("Context pressure")
struct ContextPressureTests {
    /// The point of the threshold: a number on every row is a number nobody
    /// reads. Absent and comfortable deliberately look the same here, unlike
    /// everywhere else in this app.
    @Test("a comfortable window says nothing, and neither does no reading")
    func quietUntilItMatters() {
        #expect(ContextPressure(usedPercent: nil) == nil)
        #expect(ContextPressure(usedPercent: 0) == nil)
        #expect(ContextPressure(usedPercent: 69.4) == nil)
    }

    @Test("the threshold itself already counts")
    func inclusiveAtTheEdges() {
        #expect(ContextPressure(usedPercent: 70)?.isUrgent == false)
        #expect(ContextPressure(usedPercent: 89.4)?.isUrgent == false)
        #expect(ContextPressure(usedPercent: 90)?.isUrgent == true)
        #expect(ContextPressure(usedPercent: 100)?.isUrgent == true)
    }

    /// Rounding happens once, at construction, so the colour and the threshold
    /// are decided about the number the user is looking at. Ranking on the raw
    /// value let 89.6 render as "90%" in the not-yet-urgent colour, which reads
    /// as a broken colour rather than as a rounding rule.
    @Test("what is shown is what is ranked")
    func roundingIsDecidedOnce() {
        #expect(ContextPressure(usedPercent: 84.2)?.label == "84%")

        let borderline = ContextPressure(usedPercent: 89.6)
        #expect(borderline?.label == "90%")
        #expect(borderline?.isUrgent == true)

        // Same rule at the quiet end: a reading that displays as the threshold
        // is shown, rather than hidden for being a fraction under it.
        #expect(ContextPressure(usedPercent: 69.6)?.label == "70%")
    }

    @Test("the tooltip says what the number is, since the row cannot")
    func helpIsSelfExplanatory() {
        #expect(ContextPressure(usedPercent: 84)?.help == "84% of the context window used")
    }
}
