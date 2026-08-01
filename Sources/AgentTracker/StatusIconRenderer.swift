import AppKit

/// Draws the menu bar icon: three colored dots (red = needs you, green = running,
/// grey = idle), each followed by its session count. Zero-count groups are dimmed.
enum StatusIconRenderer {
    static func image(for counts: SessionCounts) -> NSImage {
        let items: [(count: Int, color: NSColor)] = [
            (counts.needsYou, .systemRed),
            (counts.running, .systemGreen),
            (counts.idle, .systemGray),
        ]

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dotSize: CGFloat = 7
        let dotTextGap: CGFloat = 2.5
        let itemGap: CGFloat = 7
        let height: CGFloat = 18

        let strings = items.map {
            NSAttributedString(string: "\($0.count)", attributes: [.font: font])
        }
        let textWidths = strings.map { ceil($0.size().width) }
        let width =
            textWidths.reduce(0, +)
            + CGFloat(items.count) * (dotSize + dotTextGap)
            + CGFloat(items.count - 1) * itemGap
            + 2

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) {
            rect in
            var x: CGFloat = 1
            for (index, item) in items.enumerated() {
                let dimmed = item.count == 0
                let dotColor = dimmed ? item.color.withAlphaComponent(0.35) : item.color
                dotColor.setFill()
                let dotRect = NSRect(
                    x: x, y: (rect.height - dotSize) / 2, width: dotSize, height: dotSize
                )
                NSBezierPath(ovalIn: dotRect).fill()
                x += dotSize + dotTextGap

                let text = NSMutableAttributedString(attributedString: strings[index])
                text.addAttribute(
                    .foregroundColor,
                    value: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    range: NSRange(location: 0, length: text.length)
                )
                let textSize = text.size()
                text.draw(at: NSPoint(x: x, y: (rect.height - textSize.height) / 2))
                x += textWidths[index] + itemGap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription =
            "\(counts.needsYou) sessions need you, \(counts.running) running, \(counts.idle) idle"
        return image
    }
}
