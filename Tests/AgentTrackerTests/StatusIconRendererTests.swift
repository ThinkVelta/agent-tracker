import AppKit
import Testing

@testable import AgentTracker

final class StatusIconRendererTests {
    private func counts(needsYou: Int = 2, running: Int = 10, idle: Int = 1) -> SessionCounts {
        var counts = SessionCounts()
        counts.needsYou = needsYou
        counts.running = running
        counts.idle = idle
        return counts
    }

    private func regions(
        _ counts: SessionCounts, mode: StatusIconRenderer.Mode
    ) -> [StatusIconRenderer.HitRegion] {
        let elements = StatusIconRenderer.elements(for: counts, mode: mode)
        // Fixed 8pt stand-in per drawn count; layout invariants don't depend
        // on real text metrics.
        let widths = elements.map { $0.showsCount ? CGFloat(8) : 0 }
        return StatusIconRenderer.hitRegions(elements: elements, textWidths: widths)
    }

    // MARK: - Layout invariants, every mode

    @Test func regionsStayOrderedAndDisjointInEveryMode() {
        for mode in StatusIconRenderer.Mode.allCases {
            let regions = regions(counts(), mode: mode)
            for (previous, next) in zip(regions, regions.dropFirst()) {
                #expect(
                    previous.range.upperBound < next.range.lowerBound,
                    "mode \(mode) has overlapping regions")
            }
        }
    }

    @Test func clickMappingWithSnappingWorksInEveryMode() {
        for mode in StatusIconRenderer.Mode.allCases {
            let regions = regions(counts(), mode: mode)
            for region in regions {
                let middle = (region.range.lowerBound + region.range.upperBound) / 2
                #expect(
                    StatusIconRenderer.state(atImageX: middle, regions: regions) == region.state,
                    "mode \(mode): center click misses its own region")
            }
            // Every point between the first and last dot resolves somewhere:
            // the no-dead-zones invariant from the original click fix.
            if let first = regions.first, let last = regions.last {
                var probeX = first.range.lowerBound
                while probeX <= last.range.upperBound {
                    #expect(
                        StatusIconRenderer.state(atImageX: probeX, regions: regions) != nil,
                        "mode \(mode): dead zone at \(probeX)")
                    probeX += 0.5
                }
            }
        }
    }

    @Test func renderedImageEnclosesAllHitRegionsInEveryMode() {
        for mode in StatusIconRenderer.Mode.allCases {
            let rendering = StatusIconRenderer.render(for: counts(), mode: mode)
            let lastEnd = rendering.hitRegions.last?.range.upperBound ?? 0
            #expect(rendering.image.size.width >= lastEnd, "mode \(mode) clips its regions")
        }
    }

    // MARK: - Per-mode layout

    @Test func defaultModeShowsThreeDotsWithCounts() {
        let elements = StatusIconRenderer.elements(for: counts(), mode: .dotsAndCounts)
        #expect(elements.map(\.state) == SessionState.allCases)
        #expect(elements.allSatisfy { $0.showsCount })
        #expect(elements.allSatisfy { $0.shape == .filled })
    }

    @Test func zeroCountsDisappearOnlyInTheSparseMode() {
        let sparse = StatusIconRenderer.elements(
            for: counts(needsYou: 0, running: 3, idle: 0), mode: .countsWhenNonZero)
        #expect(sparse.map(\.showsCount) == [false, true, false])
        // The dots themselves never disappear — the at-a-glance signal stays.
        #expect(sparse.map(\.state) == SessionState.allCases)
    }

    @Test func modesDropWidthInOrder() {
        // Same counts, decreasing width: full > sparse (a zero count hides
        // its numeral) > dots-only ≥ attention-only.
        let tallies = counts(needsYou: 1, running: 4, idle: 0)
        func width(_ mode: StatusIconRenderer.Mode) -> CGFloat {
            StatusIconRenderer.render(for: tallies, mode: mode).image.size.width
        }
        #expect(width(.dotsAndCounts) > width(.countsWhenNonZero))
        #expect(width(.countsWhenNonZero) > width(.dotsOnly))
        #expect(width(.dotsOnly) > width(.attentionOnly))
        // Where nothing distinguishes two modes, they render identically.
        let allNonZero = counts(needsYou: 1, running: 2, idle: 3)
        #expect(
            StatusIconRenderer.render(for: allNonZero, mode: .dotsAndCounts).image.size.width
                == StatusIconRenderer.render(for: allNonZero, mode: .countsWhenNonZero)
                .image.size.width)
    }

    @Test func attentionOnlyShowsRedOrNothing() {
        let red = StatusIconRenderer.elements(
            for: counts(needsYou: 3, running: 9, idle: 4), mode: .attentionOnly)
        #expect(red.map(\.state) == [.needsYou])
        #expect(red.first?.total == 3)

        let quiet = StatusIconRenderer.elements(
            for: counts(needsYou: 0, running: 9, idle: 4), mode: .attentionOnly)
        #expect(quiet.isEmpty)
        // The placeholder still renders something findable, with no regions —
        // a click opens the dropdown unfiltered.
        let rendering = StatusIconRenderer.render(
            for: counts(needsYou: 0, running: 9, idle: 4), mode: .attentionOnly)
        #expect(rendering.hitRegions.isEmpty)
        #expect(rendering.image.size.width > 0)
        #expect(StatusIconRenderer.state(atImageX: 4, regions: rendering.hitRegions) == nil)
    }

    /// Template tinting erases hue, so monochrome must tell its three states
    /// apart by shape alone.
    @Test func monochromeEncodesEveryStateDistinctly() {
        let elements = StatusIconRenderer.elements(for: counts(), mode: .monochrome)
        let shapes = elements.map { String(describing: $0.shape) }
        #expect(Set(shapes).count == SessionState.allCases.count)
        #expect(StatusIconRenderer.render(for: counts(), mode: .monochrome).image.isTemplate)
        // Color modes must NOT be templates — tinting would erase the colors.
        #expect(!StatusIconRenderer.render(for: counts(), mode: .dotsAndCounts).image.isTemplate)
    }

    /// The pulse scales the red dot in place; layout and click mapping are
    /// emphasis-independent so a pulse can never move the click targets.
    @Test func emphasisNeverChangesLayout() {
        let calm = StatusIconRenderer.render(for: counts(), mode: .dotsAndCounts, emphasis: 0)
        let pulsing = StatusIconRenderer.render(for: counts(), mode: .dotsAndCounts, emphasis: 1)
        #expect(calm.hitRegions == pulsing.hitRegions)
        #expect(calm.image.size == pulsing.image.size)
    }

    @Test func sessionCountsTallyByState() {
        let sessions = [
            AgentSession(provider: "claude-code", sessionId: "a", state: .needsYou),
            AgentSession(provider: "claude-code", sessionId: "b", state: .running),
            AgentSession(provider: "codex", sessionId: "c", state: .running),
            AgentSession(provider: "codex", sessionId: "d", state: .idle),
        ]
        let tallies = SessionCounts(of: sessions)
        #expect(tallies.needsYou == 1)
        #expect(tallies.running == 2)
        #expect(tallies.idle == 1)
        #expect(tallies.total == 4)
        #expect(tallies.count(for: .running) == 2)
    }
}
