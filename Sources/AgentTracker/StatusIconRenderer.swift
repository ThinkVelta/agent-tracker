import AppKit

/// Draws the menu bar icon: three colored dots (red = needs you, green = running,
/// grey = idle), each followed by its session count. Zero-count groups are dimmed.
enum StatusIconRenderer {
    /// One state's horizontal extent inside the rendered image (dot through
    /// count text), used to map a status-bar click back to the dot it hit.
    struct HitRegion: Equatable {
        let state: SessionState
        let range: Range<CGFloat>
    }

    struct Rendering {
        let image: NSImage
        let hitRegions: [HitRegion]
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let dotSize: CGFloat = 7
    private static let dotTextGap: CGFloat = 2.5
    private static let itemGap: CGFloat = 7
    private static let height: CGFloat = 18
    private static let edgePad: CGFloat = 1

    /// Half the inter-item gap: snapping by this much lets neighboring regions
    /// claim the whole gap between them, and forgives edge misses by the same
    /// amount, while clicks far outside every dot stay "open unfiltered".
    static let snapTolerance: CGFloat = itemGap / 2

    /// Pure layout: each state's x-extent given the measured count-text widths
    /// (in `SessionState.allCases` order). Split from drawing so the click→dot
    /// mapping is testable without rendering. Regions are the drawn extents;
    /// `state(atImageX:regions:)` adds the click forgiveness on top.
    static func hitRegions(textWidths: [CGFloat]) -> [HitRegion] {
        var regions: [HitRegion] = []
        var penX = edgePad
        for (state, textWidth) in zip(SessionState.allCases, textWidths) {
            let end = penX + dotSize + dotTextGap + textWidth
            regions.append(HitRegion(state: state, range: penX..<end))
            penX = end + itemGap
        }
        return regions
    }

    /// Maps a click's x-position (image coordinates) to the dot it hit. The
    /// dots are ~7pt targets in the menu bar, so near-misses — the gaps
    /// between dots, the image's edge padding — snap to the nearest dot
    /// within `snapTolerance` instead of going dead (user-reported: clicks
    /// had to land pixel-perfect on a dot to register as one).
    static func state(atImageX imageX: CGFloat, regions: [HitRegion]) -> SessionState? {
        let nearest = regions.min {
            distance(from: $0.range, to: imageX) < distance(from: $1.range, to: imageX)
        }
        guard let nearest, distance(from: nearest.range, to: imageX) <= snapTolerance else {
            return nil
        }
        return nearest.state
    }

    private static func distance(from range: Range<CGFloat>, to imageX: CGFloat) -> CGFloat {
        max(range.lowerBound - imageX, imageX - range.upperBound, 0)
    }

    static func render(for counts: SessionCounts) -> Rendering {
        let totals = SessionState.allCases.map { counts.count(for: $0) }
        let strings = totals.map {
            NSAttributedString(string: "\($0)", attributes: [.font: font])
        }
        let textWidths = strings.map { ceil($0.size().width) }
        let regions = hitRegions(textWidths: textWidths)
        let width = (regions.last?.range.upperBound ?? 0) + edgePad

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) {
            rect in
            for (index, state) in SessionState.allCases.enumerated() {
                let dimmed = totals[index] == 0
                let penX = regions[index].range.lowerBound
                let color = nsColor(for: state)
                let dotColor = dimmed ? color.withAlphaComponent(0.35) : color
                dotColor.setFill()
                let dotRect = NSRect(
                    x: penX, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize
                )
                NSBezierPath(ovalIn: dotRect).fill()

                let text = NSMutableAttributedString(attributedString: strings[index])
                text.addAttribute(
                    .foregroundColor,
                    value: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    range: NSRange(location: 0, length: text.length)
                )
                let textSize = text.size()
                text.draw(
                    at: NSPoint(
                        x: penX + dotSize + dotTextGap, y: (rect.height - textSize.height) / 2
                    ))
            }
            return true
        }
        // Not a template: the menu bar tints template images monochrome, which
        // would erase the state colors.
        image.isTemplate = false
        image.accessibilityDescription =
            "\(counts.needsYou) sessions need you, \(counts.running) running, \(counts.idle) idle"
        return Rendering(image: image, hitRegions: regions)
    }

    private static func nsColor(for state: SessionState) -> NSColor {
        switch state {
        case .needsYou: return .systemRed
        case .running: return .systemGreen
        case .idle: return .systemGray
        }
    }
}
