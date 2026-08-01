import AppKit

/// Draws the menu bar icon — by default three colored dots (red = needs you,
/// green = running, grey = idle), each followed by its session count — in the
/// user's chosen display mode. Zero-count groups are dimmed.
enum StatusIconRenderer {
    /// How the icon spends its menu bar real estate. Every mode keeps the
    /// click→dot mapping intact: what is drawn is clickable, what isn't drawn
    /// has no region and clicks there open the dropdown unfiltered.
    enum Mode: String, CaseIterable {
        /// Three dots with counts — the shipped default.
        case dotsAndCounts
        /// Dots always; a count only where it is non-zero.
        case countsWhenNonZero
        /// Three dots, no numerals.
        case dotsOnly
        /// Only the needs-you group, and only while it is non-zero; otherwise
        /// a single neutral placeholder. For users who only want to know when
        /// they are blocking something.
        case attentionOnly
        /// Template rendering that inherits the menu bar's tint. Hue is
        /// erased by tinting, so state is encoded by shape instead:
        /// needs-you filled, running half-filled, idle hollow.
        case monochrome

        var label: String {
            switch self {
            case .dotsAndCounts: return "Dots and counts"
            case .countsWhenNonZero: return "Hide zero counts"
            case .dotsOnly: return "Dots only"
            case .attentionOnly: return "Needs-you only"
            case .monochrome: return "Monochrome"
            }
        }
    }

    /// Monochrome's state encoding. Color modes draw everything `.filled`.
    enum DotShape: Equatable {
        case filled
        case half
        case hollow
    }

    /// One drawn group: a dot, optionally its count. The pure layout output
    /// that rendering and the click mapping both consume.
    struct Element: Equatable {
        let state: SessionState
        /// Not named `count`: SwiftLint's empty_count autofix rewrites
        /// `count == 0` into `isEmpty`, which an Int does not have.
        let total: Int
        let showsCount: Bool
        let shape: DotShape

        var dimmed: Bool { total == 0 }
    }

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
    /// Wide enough for the pulse: at peak emphasis the needs-you dot grows
    /// 1.4pt per side, and the first dot must not clip the image's left edge.
    private static let edgePad: CGFloat = 2

    /// Half the inter-item gap: snapping by this much lets neighboring regions
    /// claim the whole gap between them, and forgives edge misses by the same
    /// amount, while clicks far outside every dot stay "open unfiltered".
    static let snapTolerance: CGFloat = itemGap / 2

    // MARK: - Pure layout

    /// What a mode draws for these counts, in menu bar order. Pure so every
    /// mode's layout is testable without rendering. An empty array means the
    /// neutral placeholder (attention-only with nothing needing attention).
    static func elements(for counts: SessionCounts, mode: Mode) -> [Element] {
        switch mode {
        case .dotsAndCounts:
            return SessionState.allCases.map {
                Element(
                    state: $0, total: counts.count(for: $0), showsCount: true, shape: .filled)
            }
        case .countsWhenNonZero:
            return SessionState.allCases.map {
                let total = counts.count(for: $0)
                return Element(
                    state: $0, total: total, showsCount: total > 0, shape: .filled)
            }
        case .dotsOnly:
            return SessionState.allCases.map {
                Element(
                    state: $0, total: counts.count(for: $0), showsCount: false, shape: .filled)
            }
        case .attentionOnly:
            guard counts.needsYou > 0 else { return [] }
            return [
                Element(
                    state: .needsYou, total: counts.needsYou, showsCount: true, shape: .filled)
            ]
        case .monochrome:
            return SessionState.allCases.map {
                Element(
                    state: $0, total: counts.count(for: $0), showsCount: true,
                    shape: shape(for: $0))
            }
        }
    }

    /// Monochrome's shape vocabulary — must keep all three states
    /// distinguishable without hue.
    static func shape(for state: SessionState) -> DotShape {
        switch state {
        case .needsYou: return .filled
        case .running: return .half
        case .idle: return .hollow
        }
    }

    /// Pure layout: each element's x-extent given its measured count-text
    /// width (0 where no count is drawn). Regions are the drawn extents;
    /// `state(atImageX:regions:)` adds the click forgiveness on top.
    static func hitRegions(elements: [Element], textWidths: [CGFloat]) -> [HitRegion] {
        var regions: [HitRegion] = []
        var penX = edgePad
        for (element, textWidth) in zip(elements, textWidths) {
            let end = penX + dotSize + (element.showsCount ? dotTextGap + textWidth : 0)
            regions.append(HitRegion(state: element.state, range: penX..<end))
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

    // MARK: - Rendering

    /// - Parameter emphasis: 0…1 attention-pulse phase; scales the needs-you
    ///   dot up to ~1.4× so a session flipping red registers in the corner of
    ///   the eye. Always passed as 0 outside the brief one-shot pulse.
    static func render(
        for counts: SessionCounts, mode: Mode = .dotsAndCounts, emphasis: CGFloat = 0
    ) -> Rendering {
        let elements = elements(for: counts, mode: mode)
        guard !elements.isEmpty else { return renderPlaceholder(counts: counts) }

        let strings = elements.map { element in
            NSAttributedString(string: "\(element.total)", attributes: [.font: font])
        }
        let textWidths = zip(elements, strings).map { element, string in
            element.showsCount ? ceil(string.size().width) : 0
        }
        let regions = hitRegions(elements: elements, textWidths: textWidths)
        let width = (regions.last?.range.upperBound ?? 0) + edgePad
        let monochrome = mode == .monochrome

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) {
            rect in
            for (index, element) in elements.enumerated() {
                let penX = regions[index].range.lowerBound
                let baseColor = monochrome ? NSColor.black : nsColor(for: element.state)
                let color =
                    element.dimmed ? baseColor.withAlphaComponent(0.35) : baseColor

                var dotRect = NSRect(
                    x: penX, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize)
                if element.state == .needsYou, emphasis > 0 {
                    let growth = dotSize * 0.4 * min(max(emphasis, 0), 1)
                    dotRect = dotRect.insetBy(dx: -growth / 2, dy: -growth / 2)
                }
                draw(shape: element.shape, in: dotRect, color: color)

                if element.showsCount {
                    let text = NSMutableAttributedString(attributedString: strings[index])
                    let textColor =
                        monochrome
                        ? color
                        : (element.dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor)
                    text.addAttribute(
                        .foregroundColor, value: textColor,
                        range: NSRange(location: 0, length: text.length))
                    let textSize = text.size()
                    text.draw(
                        at: NSPoint(
                            x: penX + dotSize + dotTextGap,
                            y: (rect.height - textSize.height) / 2
                        ))
                }
            }
            return true
        }
        // Template only in monochrome — the menu bar tints template images,
        // which is the point there and would erase the state colors elsewhere.
        image.isTemplate = monochrome
        image.accessibilityDescription =
            "\(counts.needsYou) sessions need you, \(counts.running) running, \(counts.idle) idle"
        return Rendering(image: image, hitRegions: regions)
    }

    /// Attention-only with nothing needing attention: a single hollow
    /// placeholder so the menu bar item stays findable. No regions — a click
    /// opens the dropdown unfiltered.
    private static func renderPlaceholder(counts: SessionCounts) -> Rendering {
        let width = dotSize + edgePad * 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let dotRect = NSRect(
                x: edgePad, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize)
            draw(shape: .hollow, in: dotRect, color: NSColor.black.withAlphaComponent(0.8))
            return true
        }
        // Template: the placeholder is deliberately stateless, so it should
        // take the menu bar's tint like any system icon.
        image.isTemplate = true
        image.accessibilityDescription =
            "no sessions need you; \(counts.running) running, \(counts.idle) idle"
        return Rendering(image: image, hitRegions: [])
    }

    private static func draw(shape: DotShape, in rect: NSRect, color: NSColor) {
        switch shape {
        case .filled:
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .hollow:
            color.setStroke()
            let inset = rect.insetBy(dx: 0.6, dy: 0.6)
            let path = NSBezierPath(ovalIn: inset)
            path.lineWidth = 1.2
            path.stroke()
        case .half:
            // Bottom half filled inside a full ring: reads at 7pt where a
            // vertical split would smear.
            color.setStroke()
            let inset = rect.insetBy(dx: 0.6, dy: 0.6)
            let ring = NSBezierPath(ovalIn: inset)
            ring.lineWidth = 1.2
            ring.stroke()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = inset.width / 2 - 0.8
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(
                withCenter: center, radius: radius, startAngle: 180, endAngle: 360)
            wedge.close()
            color.setFill()
            wedge.fill()
        }
    }

    private static func nsColor(for state: SessionState) -> NSColor {
        switch state {
        case .needsYou: return .systemRed
        case .running: return .systemGreen
        case .idle: return .systemGray
        }
    }
}
