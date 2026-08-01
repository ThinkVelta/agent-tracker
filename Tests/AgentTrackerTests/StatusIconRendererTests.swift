import AppKit
import Testing

@testable import AgentTracker

final class StatusIconRendererTests {
    private let widths: [CGFloat] = [7, 13, 7]

    @Test func regionsFollowStateOrderAndStayDisjoint() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        #expect(regions.map(\.state) == SessionState.allCases)
        for (previous, next) in zip(regions, regions.dropFirst()) {
            #expect(previous.range.upperBound < next.range.lowerBound)
        }
    }

    @Test func regionWidthCoversDotAndCountText() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        for (region, textWidth) in zip(regions, widths) {
            #expect(region.range.upperBound - region.range.lowerBound > textWidth)
        }
    }

    @Test func clickInsideEachRegionMapsToItsState() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        for region in regions {
            let middle = (region.range.lowerBound + region.range.upperBound) / 2
            #expect(StatusIconRenderer.state(atImageX: middle, regions: regions) == region.state)
        }
    }

    @Test func gapClicksSnapToTheNearestDot() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        let gapStart = regions[0].range.upperBound
        let gapEnd = regions[1].range.lowerBound
        #expect(
            StatusIconRenderer.state(atImageX: gapStart + 0.5, regions: regions)
                == regions[0].state)
        #expect(
            StatusIconRenderer.state(atImageX: gapEnd - 0.5, regions: regions) == regions[1].state)
    }

    /// The user-reported failure mode: no dead zones anywhere inside the icon —
    /// every point from the first dot to the last resolves to some dot.
    @Test func everyPointBetweenFirstAndLastDotResolvesToADot() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        guard let first = regions.first, let last = regions.last else {
            Issue.record("no regions")
            return
        }
        var probeX = first.range.lowerBound
        while probeX <= last.range.upperBound {
            #expect(StatusIconRenderer.state(atImageX: probeX, regions: regions) != nil)
            probeX += 0.5
        }
    }

    @Test func edgeMissesWithinToleranceSnapToTheOuterDots() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        let tolerance = StatusIconRenderer.snapTolerance
        let beforeFirst = regions[0].range.lowerBound - tolerance
        let afterLast = regions[2].range.upperBound + tolerance
        #expect(
            StatusIconRenderer.state(atImageX: beforeFirst, regions: regions) == regions[0].state)
        #expect(StatusIconRenderer.state(atImageX: afterLast, regions: regions) == regions[2].state)
    }

    @Test func farOutsideClicksMapToNoState() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        let tolerance = StatusIconRenderer.snapTolerance
        #expect(
            StatusIconRenderer.state(
                atImageX: regions[0].range.lowerBound - tolerance - 1, regions: regions) == nil)
        #expect(
            StatusIconRenderer.state(
                atImageX: regions[2].range.upperBound + tolerance + 1, regions: regions) == nil)
        #expect(StatusIconRenderer.state(atImageX: 0, regions: []) == nil)
    }

    @Test func renderedImageEnclosesAllHitRegions() {
        var counts = SessionCounts()
        counts.needsYou = 2
        counts.running = 10
        counts.idle = 1
        let rendering = StatusIconRenderer.render(for: counts)
        #expect(rendering.hitRegions.count == SessionState.allCases.count)
        let lastEnd = rendering.hitRegions.last?.range.upperBound ?? 0
        #expect(rendering.image.size.width >= lastEnd)
        #expect(rendering.image.isTemplate == false)
    }

    @Test func sessionCountsTallyByState() {
        let sessions = [
            AgentSession(provider: "claude-code", sessionId: "a", state: .needsYou),
            AgentSession(provider: "claude-code", sessionId: "b", state: .running),
            AgentSession(provider: "codex", sessionId: "c", state: .running),
            AgentSession(provider: "codex", sessionId: "d", state: .idle),
        ]
        let counts = SessionCounts(of: sessions)
        #expect(counts.needsYou == 1)
        #expect(counts.running == 2)
        #expect(counts.idle == 1)
        #expect(counts.total == 4)
        #expect(counts.count(for: .running) == 2)
    }
}
