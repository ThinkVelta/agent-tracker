import AppKit
import Testing

@testable import AgentTracker

/// The warning colours are resolved per draw from the current appearance, so
/// the thing worth testing is that the resolution picks the right side.
@Suite("Theme palette")
struct ThemePaletteTests {
    /// Every appearance the panel can be drawn in, and which half of a dynamic
    /// colour it must resolve to.
    private static let appearances: [(NSAppearance.Name, isDark: Bool)] = [
        (.aqua, false),
        (.darkAqua, true),
        (.vibrantLight, false),
        (.vibrantDark, true),
        (.accessibilityHighContrastAqua, false),
        (.accessibilityHighContrastDarkAqua, true),
        (.accessibilityHighContrastVibrantLight, false),
        (.accessibilityHighContrastVibrantDark, true),
    ]

    /// `bestMatch(from:)` is a *match*, not an equality check — a high-contrast
    /// or vibrant appearance is meant to resolve to its plain counterpart. This
    /// asserts that rather than trusting it, because getting it wrong would
    /// paint the light colour on a dark panel for exactly the users who asked
    /// the system for more contrast, and nothing in the suite would notice.
    @Test("every appearance resolves to the right side of a dynamic colour")
    func dynamicColoursFollowTheAppearance() throws {
        for (name, isDark) in Self.appearances {
            let appearance = try #require(NSAppearance(named: name), "\(name.rawValue)")
            let matched = appearance.bestMatch(from: [.aqua, .darkAqua])
            #expect(matched == (isDark ? .darkAqua : .aqua), "\(name.rawValue)")
        }
    }

    /// The colours must actually differ per side, or the resolution above is
    /// correct and pointless.
    @Test("warning and critical are not the same colour in both appearances")
    func theTwoSidesDiffer() throws {
        for palette in [Theme.Palette.warning, Theme.Palette.critical] {
            let color = NSColor(palette)
            let light = try #require(
                color.resolved(for: .aqua)?.usingColorSpace(.sRGB))
            let dark = try #require(
                color.resolved(for: .darkAqua)?.usingColorSpace(.sRGB))
            #expect(light.brightnessComponent < dark.brightnessComponent)
        }
    }
}

extension NSColor {
    /// Resolves a dynamic colour as a given appearance would draw it.
    fileprivate func resolved(for name: NSAppearance.Name) -> NSColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB)
        }
        return resolved
    }
}
