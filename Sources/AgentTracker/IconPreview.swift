import AppKit

/// Debug-only composite for `--render-preview --view icons`: every icon mode
/// rendered by the real `StatusIconRenderer`, on a menu-bar-ish strip, so the
/// modes can be eyeballed in both appearances without relaunching the app
/// five times.
enum IconPreview {
    static func composite(darkMode: Bool) -> NSImage {
        var sample = SessionCounts()
        sample.needsYou = 1
        sample.running = 4
        sample.idle = 0
        var quiet = SessionCounts()
        quiet.running = 4
        quiet.idle = 2

        // Every mode in both colorings, paired, since monochrome crosses the
        // modes rather than being one of them.
        //
        // attention-only appears twice more: with a red session and without —
        // the placeholder variant is exactly what needs a human eye.
        var rows: [(String, NSImage)] = StatusIconRenderer.Mode.allCases.flatMap { mode in
            [
                (mode.label, StatusIconRenderer.render(for: sample, mode: mode).image),
                (
                    "\(mode.label) · monochrome",
                    StatusIconRenderer.render(for: sample, mode: mode, monochrome: true).image
                ),
            ]
        }
        rows.append(
            (
                "Needs-you only (nothing red)",
                StatusIconRenderer.render(for: quiet, mode: .attentionOnly).image
            ))
        rows.append(
            (
                "Pulse peak (emphasis 1)",
                StatusIconRenderer.render(for: sample, emphasis: 1).image
            ))

        let rowHeight: CGFloat = 30
        let labelX: CGFloat = 200
        let size = NSSize(width: 420, height: rowHeight * CGFloat(rows.count))
        let labelFont = NSFont.systemFont(ofSize: 10)

        return NSImage(size: size, flipped: true) { rect in
            (darkMode ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
            rect.fill()
            for (index, row) in rows.enumerated() {
                let rowY = CGFloat(index) * rowHeight
                let label = NSAttributedString(
                    string: row.0,
                    attributes: [
                        .font: labelFont,
                        .foregroundColor: darkMode ? NSColor.lightGray : NSColor.darkGray,
                    ])
                label.draw(at: NSPoint(x: 8, y: rowY + (rowHeight - label.size().height) / 2))
                // The real menu bar tints template images to fit the bar;
                // simulate that here or monochrome reads as invisible-on-dark.
                let icon =
                    row.1.isTemplate
                    ? tinted(row.1, with: darkMode ? .white : .black) : row.1
                let iconY = rowY + (rowHeight - icon.size.height) / 2
                icon.draw(
                    in: NSRect(
                        x: labelX, y: iconY, width: icon.size.width, height: icon.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: nil)
            }
            return true
        }
    }

    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
