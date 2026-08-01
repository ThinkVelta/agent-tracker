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
