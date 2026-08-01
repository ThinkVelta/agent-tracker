import Foundation
import Testing

@testable import AgentTracker

@MainActor
final class PreferencesTests {
    /// A throwaway suite per test — the real defaults domain is never touched.
    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshStoreHasTheShippedDefaults() {
        let preferences = Preferences(defaults: makeDefaults())
        #expect(preferences.appearanceOverride == .system)
        #expect(preferences.idleFolding == .past(Theme.Metrics.idleAutoCollapseThreshold))
        #expect(preferences.autoAckDwell == TerminalFocusObserver.defaultDwell)
    }

    @Test func everyPreferenceRoundTrips() {
        let defaults = makeDefaults()
        let first = Preferences(defaults: defaults)
        first.appearanceOverride = .dark
        first.idleFolding = .always
        first.autoAckDwell = 10

        // A second instance over the same suite is "relaunch the app".
        let second = Preferences(defaults: defaults)
        #expect(second.appearanceOverride == .dark)
        #expect(second.idleFolding == .always)
        #expect(second.autoAckDwell == 10)
    }

    @Test func idleFoldingStorageCoversAllShapes() {
        for folding in Preferences.IdleFolding.options {
            #expect(Preferences.IdleFolding(stored: folding.stored) == folding)
        }
        #expect(Preferences.IdleFolding(stored: -1) == .never)
        #expect(Preferences.IdleFolding(stored: -99) == .never)
        #expect(Preferences.IdleFolding(stored: 0) == .always)
        #expect(Preferences.IdleFolding(stored: 7) == .past(7))
    }

    /// Whatever an old build or a defaults-write experiment left behind must
    /// read as the default, never crash or half-apply.
    @Test func corruptStoredValuesFallBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set("neon", forKey: "appearanceOverride")
        defaults.set(-5.0, forKey: "autoAckDwellSeconds")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.appearanceOverride == .system)
        #expect(preferences.autoAckDwell == TerminalFocusObserver.defaultDwell)

        defaults.set(9999.0, forKey: "autoAckDwellSeconds")
        #expect(
            Preferences(defaults: defaults).autoAckDwell == TerminalFocusObserver.defaultDwell)
    }

    /// A wrong-TYPE stored value must fall back to the default, not coerce:
    /// integer(forKey:) turns a stored "oops" into 0, and 0 is a real option
    /// here (.always / Off) — silent coercion would apply a preference the
    /// user never chose.
    @Test func wrongTypeStoredValuesFallBackInsteadOfCoercing() {
        let defaults = makeDefaults()
        defaults.set("oops", forKey: "idleFoldingThreshold")
        defaults.set("later", forKey: "autoAckDwellSeconds")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.idleFolding == .past(Theme.Metrics.idleAutoCollapseThreshold))
        #expect(preferences.autoAckDwell == TerminalFocusObserver.defaultDwell)
        // The genuine zero options still load as themselves.
        defaults.set(0, forKey: "idleFoldingThreshold")
        defaults.set(0.0, forKey: "autoAckDwellSeconds")
        let zeros = Preferences(defaults: defaults)
        #expect(zeros.idleFolding == .always)
        #expect(zeros.autoAckDwell == 0)
    }

    /// Numerically fine but not a selectable option: a picker with no matching
    /// tag renders blank, so these must snap to the default too.
    @Test func valuesOutsideTheOptionSetsSnapToDefaults() {
        let defaults = makeDefaults()
        defaults.set(7, forKey: "idleFoldingThreshold")
        defaults.set(2.0, forKey: "autoAckDwellSeconds")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.idleFolding == .past(Theme.Metrics.idleAutoCollapseThreshold))
        #expect(preferences.autoAckDwell == TerminalFocusObserver.defaultDwell)

        // Every offerable option survives the round trip unchanged.
        for folding in Preferences.IdleFolding.options {
            defaults.set(folding.stored, forKey: "idleFoldingThreshold")
            #expect(Preferences(defaults: defaults).idleFolding == folding)
        }
        for option in Preferences.dwellOptions {
            defaults.set(option.seconds, forKey: "autoAckDwellSeconds")
            #expect(Preferences(defaults: defaults).autoAckDwell == option.seconds)
        }
    }

    @Test func refreshIntervalRoundTripsAndSnapsToOptions() {
        let defaults = makeDefaults()
        #expect(
            Preferences(defaults: defaults).refreshInterval
                == SessionStore.defaultRefreshInterval)

        let first = Preferences(defaults: defaults)
        first.refreshInterval = 30
        #expect(Preferences(defaults: defaults).refreshInterval == 30)

        // Unofferable or corrupt values snap to the default — a 0 or negative
        // interval would break the timer, a "fast" string would coerce.
        for bad: Any in [0.0, -5.0, 2.0, "fast"] {
            defaults.set(bad, forKey: "refreshIntervalSeconds")
            #expect(
                Preferences(defaults: defaults).refreshInterval
                    == SessionStore.defaultRefreshInterval)
        }
        for option in Preferences.refreshOptions {
            defaults.set(option.seconds, forKey: "refreshIntervalSeconds")
            #expect(Preferences(defaults: defaults).refreshInterval == option.seconds)
        }
    }

    @Test func iconPreferencesRoundTripAndSnapToDefaults() {
        let defaults = makeDefaults()
        let first = Preferences(defaults: defaults)
        #expect(first.iconMode == .dotsAndCounts)
        #expect(first.attentionCue)

        first.iconMode = .monochrome
        first.attentionCue = false
        let second = Preferences(defaults: defaults)
        #expect(second.iconMode == .monochrome)
        #expect(!second.attentionCue)

        // Unknown mode string (a future build's mode, a typo): default, never
        // a blank picker.
        defaults.set("neonDots", forKey: "iconMode")
        defaults.set("maybe", forKey: "attentionCue")
        let corrupt = Preferences(defaults: defaults)
        #expect(corrupt.iconMode == .dotsAndCounts)
        #expect(corrupt.attentionCue)
    }

    // MARK: - Dwell decision (pure)

    @Test func dwellRequiresTheConfiguredStay() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(
            TerminalFocusObserver.dwellSatisfied(
                since: start, now: start.addingTimeInterval(3), dwell: 3))
        #expect(
            !TerminalFocusObserver.dwellSatisfied(
                since: start, now: start.addingTimeInterval(2.9), dwell: 3))
        #expect(!TerminalFocusObserver.dwellSatisfied(since: nil, now: start, dwell: 3))
    }

    /// Off means off: a zero dwell must never satisfy, not even for a window
    /// that has been focused all day.
    @Test func zeroDwellDisablesAutoAcknowledge() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(
            !TerminalFocusObserver.dwellSatisfied(
                since: start, now: start.addingTimeInterval(86400), dwell: 0))
        #expect(
            !TerminalFocusObserver.dwellSatisfied(
                since: start, now: start.addingTimeInterval(86400), dwell: -1))
    }
}
