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

    @Test func clickInGapBetweenDotsMapsToNoState() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        let gapX = (regions[0].range.upperBound + regions[1].range.lowerBound) / 2
        #expect(!regions.contains { $0.range.contains(gapX) })
    }

    @Test func clickInsideEachRegionMapsToItsState() {
        let regions = StatusIconRenderer.hitRegions(textWidths: widths)
        for region in regions {
            let middle = (region.range.lowerBound + region.range.upperBound) / 2
            #expect(regions.first { $0.range.contains(middle) }?.state == region.state)
        }
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
