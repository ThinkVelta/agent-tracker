import Foundation
import Testing

@testable import AgentTracker

@MainActor
final class SessionKeySetTests {
    private var suiteNames: [String] = []

    deinit {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    /// Its own suite, like PreferencesTests: the real domain is never touched.
    private func defaults() -> UserDefaults {
        let name = "agent-tracker-keyset-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    @Test func markingRoundTripsThroughStorage() {
        let store = defaults()
        SessionKeySet(defaults: store, storageKey: "marks").toggle("s1")
        #expect(SessionKeySet(defaults: store, storageKey: "marks").contains("s1"))
    }

    @Test func togglingTwiceLeavesNothingBehind() {
        let marks = SessionKeySet(defaults: defaults(), storageKey: "marks")
        marks.toggle("s1")
        marks.toggle("s1")
        #expect(marks.contains("s1") == false)
        #expect(marks.keys.isEmpty)
    }

    /// A mark belongs to one session, not to a project.
    @Test func markingOneSessionLeavesItsNeighboursAlone() {
        let marks = SessionKeySet(defaults: defaults(), storageKey: "marks")
        marks.toggle("s1")
        #expect(marks.contains("s9") == false)
        #expect(marks.contains("s2") == false)
    }

    /// 2026-08-10T09:00:00Z. Absolute, so nothing here depends on a real clock.
    private let start = Date(timeIntervalSince1970: 1_786_705_200)

    private func later(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// A session id belongs to one run, so a mute cannot outlive it.
    @Test func aMarkIsDroppedOnceItsSessionEnds() {
        let store = defaults()
        let marks = SessionKeySet(defaults: store, storageKey: "marks")
        marks.toggle("s1")

        marks.reconcile(liveKeys: ["s1"], now: start)
        #expect(marks.contains("s1"))

        marks.reconcile(liveKeys: [], now: later(1))
        marks.reconcile(liveKeys: [], now: later(SessionKeySet.graceBeforeForgetting + 1))
        #expect(marks.contains("s1") == false)
        // Persisted, not just forgotten in memory.
        #expect(SessionKeySet(defaults: store, storageKey: "marks").contains("s1") == false)
    }

    /// The bug the grace exists for. The Codex scanner publishes its first rows
    /// a beat AFTER launch, so dropping a key the moment it is not in the live
    /// set would delete every mark in the gap — before the row it belongs
    /// to had ever appeared, and with nothing on screen to explain it.
    @Test func aMarkSurvivesASourceThatHasNotReportedYet() {
        let marks = SessionKeySet(defaults: defaults(), storageKey: "marks")
        marks.toggle("s9")

        // Passes before the scanner has published anything.
        for second in 0..<4 {
            marks.reconcile(liveKeys: ["s1"], now: later(Double(second)))
            #expect(marks.contains("s9"))
        }

        // It arrives well inside the grace, and is still marks.
        marks.reconcile(liveKeys: ["s1", "s9"], now: later(5))
        #expect(marks.contains("s9"))

        // Having come back, it starts counting again from scratch rather than
        // from when it was first missed — otherwise a session that appeared
        // late would be forgotten early.
        marks.reconcile(
            liveKeys: ["s1"], now: later(SessionKeySet.graceBeforeForgetting))
        #expect(marks.contains("s9"))
    }

    /// The one the reviewer found, and the version of it I had wrong: the old
    /// rule only dropped keys it had watched leave, so a session that ended
    /// while the app was closed was never seen leaving and its mark was kept
    /// for ever. A fresh process starts timing at its first pass, so an
    /// already-gone session is forgotten a grace later.
    @Test func aMarkWhoseSessionEndedWhileClosedIsForgottenToo() {
        let store = defaults()
        SessionKeySet(defaults: store, storageKey: "marks").toggle("s1")

        // A new process: nothing in memory, and the session never appears.
        let restarted = SessionKeySet(defaults: store, storageKey: "marks")
        #expect(restarted.contains("s1"))
        restarted.reconcile(liveKeys: [], now: start)
        #expect(restarted.contains("s1"))

        restarted.reconcile(liveKeys: [], now: later(SessionKeySet.graceBeforeForgetting))
        #expect(restarted.contains("s1") == false)
        #expect(SessionKeySet(defaults: store, storageKey: "marks").keys.isEmpty)
    }

    /// `reconcile` runs on every store pass, roughly once a second. Publishing
    /// an unchanged set would redraw the whole dropdown at that rate.
    @Test func aQuietPassChangesNothing() {
        let marks = SessionKeySet(defaults: defaults(), storageKey: "marks")
        marks.toggle("s1")
        var publishes = 0
        let subscription = marks.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        for second in 0..<10 {
            marks.reconcile(liveKeys: ["s1"], now: later(Double(second)))
        }
        #expect(publishes == 0)

        // Still nothing while it is merely absent.
        marks.reconcile(liveKeys: [], now: later(10))
        #expect(publishes == 0)

        marks.reconcile(liveKeys: [], now: later(SessionKeySet.graceBeforeForgetting + 10))
        #expect(publishes == 1)
    }

    /// Unmuting has to take the bookkeeping with it, or the map that records
    /// what is missing outgrows the set it describes.
    @Test func unmarkingForgetsItsAbsenceToo() {
        let marks = SessionKeySet(defaults: defaults(), storageKey: "marks")
        marks.toggle("s1")
        marks.reconcile(liveKeys: [], now: start)
        marks.toggle("s1")

        marks.toggle("s1")
        // Re-muted after the original grace would have expired: it must get a
        // fresh one rather than inherit the old absence.
        marks.reconcile(liveKeys: [], now: later(SessionKeySet.graceBeforeForgetting + 1))
        #expect(marks.contains("s1"))
    }

    /// Pasted into a shell, so a provider this version does not know gets

    /// The whole risk of sharing one implementation between mute and pin: two
    /// sets in one `UserDefaults` domain that shared a key would make pinning a
    /// session mute it. Storage keys are the only thing keeping them apart.
    @Test func twoSetsInOneDomainDoNotSeeEachOther() {
        let store = defaults()
        let muted = SessionKeySet(defaults: store, storageKey: "mutedSessions")
        let pinned = SessionKeySet(defaults: store, storageKey: "pinnedSessions")

        muted.toggle("s1")
        #expect(pinned.contains("s1") == false)

        pinned.toggle("s2")
        #expect(muted.contains("s2") == false)
        #expect(muted.keys == ["s1"])
        #expect(pinned.keys == ["s2"])

        // And they survive a relaunch still separate.
        #expect(SessionKeySet(defaults: store, storageKey: "mutedSessions").keys == ["s1"])
        #expect(SessionKeySet(defaults: store, storageKey: "pinnedSessions").keys == ["s2"])
    }

    /// The shipped keys, spelled out. Renaming one silently drops everything
    /// every user has marked, and nothing else in the suite would notice.
    @Test func theSharedSetsKeepTheirStoredNames() {
        #expect(SessionKeySet.muted !== SessionKeySet.pinned)
    }
}
