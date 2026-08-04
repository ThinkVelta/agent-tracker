import SwiftUI

/// The dropdown's design tokens. One place to change a radius or a type size,
/// so the popover, its rows and anything added later stay one visual system.
/// Values only — no view code.
enum Theme {
    enum Metrics {
        static let popoverWidth: CGFloat = 360
        /// The dropdown panel's frame radius. Ours to choose because the
        /// dropdown is a borderless panel, not an NSPopover — the system
        /// popover's much rounder chrome is not configurable (user feedback:
        /// too round).
        static let panelCornerRadius: CGFloat = 10
        /// Gap between the menu bar's bottom edge and the panel.
        static let panelTopGap: CGFloat = 5
        /// Outer horizontal inset for chrome (header, search, footer).
        static let gutter: CGFloat = 10
        static let rowHorizontalPadding: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 6
        static let rowCornerRadius: CGFloat = 6
        static let tileCornerRadius: CGFloat = 7
        /// Width of the state-colored bar down a row's leading edge.
        static let accentBarWidth: CGFloat = 2.5
        static let sectionHeaderHeight: CGFloat = 24
        static let searchFieldHeight: CGFloat = 24
        static let searchCornerRadius: CGFloat = 6
        /// Rows past this are summarized rather than drawn; the filter tiles,
        /// search field and collapsible sections are how you get under it.
        static let maxVisibleRows = 14
        /// Idle sessions start folded away once there are more than this many —
        /// they are the least likely to be what the popover was opened for.
        /// Five rather than three: at three the fold triggered while the list
        /// was still short enough to read at a glance, so it hid sessions
        /// instead of the noise it exists to hide.
        static let idleAutoCollapseThreshold = 5
        /// Search appears at this many sessions. Deliberately well below the
        /// row cap: waiting until the list overflows surprised the user, who
        /// had no idea the field existed.
        static let searchVisibleFromRows = 8
    }

    enum Typography {
        static let sessionName = Font.system(size: 13, weight: .semibold)
        static let sessionMeta = Font.system(size: 11)
        static let timestamp = Font.system(size: 11).monospacedDigit()
        static let sectionHeader = Font.system(size: 10, weight: .semibold)
        static let tileCount = Font.system(size: 13, weight: .semibold).monospacedDigit()
        static let tileLabel = Font.system(size: 10, weight: .medium)
        static let footer = Font.system(size: 11)
        static let search = Font.system(size: 12)
    }

    enum Palette {
        /// Hover wash on an interactive row.
        static let rowHover = Color.primary.opacity(0.07)
        /// Resting fill of a filter tile.
        static let tileRest = Color.primary.opacity(0.05)
        /// Selected filter tile — reads as pressed without a hard border.
        static let tileSelected = Color.primary.opacity(0.13)
        static let tileHover = Color.primary.opacity(0.09)
        static let hairline = Color.primary.opacity(0.09)
        /// Dimming for a state with nothing in it.
        static let emptyStateOpacity: Double = 0.35
        /// Idle rows' accent rail, held back so red and green lead.
        static let idleAccentOpacity: Double = 0.45
        /// Settings grouped-card surface and its internal hairlines — the
        /// System Settings look: barely-there fill, quieter separators.
        static let cardFill = Color.primary.opacity(0.04)
        static let cardSeparator = Color.primary.opacity(0.06)
    }

    enum Motion {
        /// Matches the system's short-transition feel; every use must degrade
        /// to nothing under Reduce Motion.
        static let quick = Animation.easeInOut(duration: 0.16)
    }
}
