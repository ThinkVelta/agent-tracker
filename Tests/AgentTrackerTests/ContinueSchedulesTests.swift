import Foundation
import Testing

@testable import AgentTracker

/// Storage only. The deciding is `ContinueSchedulerTests`; this covers the part
/// that has to survive a relaunch and a hand-edited defaults domain.
@MainActor
final class ContinueSchedulesTests {
    private var suiteNames: [String] = []

    deinit {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
    }

    /// Its own suite, like PreferencesTests: the real domain is never touched.
    private func defaults() -> UserDefaults {
        let name = "agent-tracker-schedules-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private let reset = Date(timeIntervalSince1970: 1_785_927_600)

    private func schedule(_ id: String, repeats: Bool = false) -> ScheduledContinue {
        ScheduledContinue(
            sessionId: id, provider: "claude-code", message: "Continue",
            armedForResetAt: reset, repeats: repeats)
    }

    @Test func armingRoundTripsThroughStorage() throws {
        let store = defaults()
        let first = ContinueSchedules(defaults: store)
        first.arm(schedule("a"))
        first.arm(schedule("b", repeats: true))

        let reloaded = ContinueSchedules(defaults: store)
        #expect(reloaded.schedules.count == 2)
        let repeating = try #require(reloaded.schedule(for: "b"))
        #expect(repeating.repeats)
        #expect(repeating.armedForResetAt == reset)
        #expect(repeating.message == "Continue")
    }

    /// Arming the same session twice replaces rather than duplicates, or one
    /// session would accumulate schedules and fire more than once.
    @Test func armingTheSameSessionTwiceReplacesIt() {
        let schedules = ContinueSchedules(defaults: defaults())
        schedules.arm(schedule("a"))
        var second = schedule("a")
        second.message = "carry on"
        schedules.arm(second)
        #expect(schedules.schedules.count == 1)
        #expect(schedules.schedule(for: "a")?.message == "carry on")
    }

    @Test func disarmingRemovesOnlyThatSession() {
        let schedules = ContinueSchedules(defaults: defaults())
        schedules.arm(schedule("a"))
        schedules.arm(schedule("b"))
        schedules.disarm(sessionId: "a")
        #expect(schedules.schedules.map(\.sessionId) == ["b"])
    }

    /// One corrupt record must lose one schedule, not all of them. An
    /// all-or-nothing decode of a single array would drop every armed session
    /// because of one bad entry, and "quietly lost the schedule" is the worst
    /// outcome this feature has.
    @Test func oneCorruptRecordDoesNotLoseTheOthers() throws {
        let store = defaults()
        let seeded = ContinueSchedules(defaults: store)
        seeded.arm(schedule("good-1"))
        seeded.arm(schedule("good-2"))

        var stored = try #require(store.object(forKey: ContinueSchedules.storageKey) as? [String])
        stored.insert("{ this is not json", at: 1)
        stored.append("{}")
        store.set(stored, forKey: ContinueSchedules.storageKey)

        let reloaded = ContinueSchedules(defaults: store)
        #expect(reloaded.schedules.map(\.sessionId).sorted() == ["good-1", "good-2"])
    }

    /// Anything stored under the key that is not a string array is not ours.
    @Test func aForeignStoredValueReadsAsNoSchedules() {
        let store = defaults()
        store.set("not an array", forKey: ContinueSchedules.storageKey)
        #expect(ContinueSchedules(defaults: store).schedules.isEmpty)

        store.set([1, 2, 3], forKey: ContinueSchedules.storageKey)
        #expect(ContinueSchedules(defaults: store).schedules.isEmpty)
    }

    /// Editing the text must not re-owe a moment already dealt with, or changing
    /// a message would make a fired schedule fire again.
    @Test func editingDoesNotDisturbWhatHasAlreadySettled() throws {
        let schedules = ContinueSchedules(defaults: defaults())
        var armed = schedule("a", repeats: true)
        armed.settledThrough = reset
        schedules.arm(armed)

        schedules.update(sessionId: "a") { $0.message = "next please" }
        let edited = try #require(schedules.schedule(for: "a"))
        #expect(edited.message == "next please")
        #expect(edited.settledThrough == reset)
        #expect(edited.isSettled)
    }

    /// The same one-line rule the record's own initializer applies, enforced on
    /// the edit path too: a newline would become a typed line plus a Return.
    @Test func anEditedMessageIsStillOneLine() throws {
        let schedules = ContinueSchedules(defaults: defaults())
        schedules.arm(schedule("a"))
        schedules.update(sessionId: "a") { $0.message = "go on\nrm -rf /" }
        #expect(schedules.schedule(for: "a")?.message == "go on")

        schedules.update(sessionId: "a") { $0.message = "   " }
        #expect(schedules.schedule(for: "a")?.message == "Continue")
    }

    /// Regression: the gate and the records both live in the same domain, and
    /// they were briefly given the same key. The records overwrote the Bool, so
    /// `object(forKey:) as? Bool` returned nil and the gate read as off — arming
    /// a schedule silently disabled the feature meant to run it. Caught by
    /// looking at a real domain rather than by either suite's own tests, because
    /// each only ever built one of the two objects.
    @Test func theGateAndTheRecordsDoNotShareAKey() throws {
        #expect(ContinueSchedules.storageKey != "scheduledContinues")

        let store = defaults()
        let preferences = Preferences(defaults: store)
        preferences.scheduledContinues = true
        let schedules = ContinueSchedules(defaults: store)
        schedules.arm(schedule("a"))

        // Both survive each other, in either construction order.
        #expect(Preferences(defaults: store).scheduledContinues)
        #expect(ContinueSchedules(defaults: store).schedules.count == 1)
    }

    /// Regression: delivery has to run OFF the main actor. An `async` closure
    /// type is not enough — a closure literal written inside a `@MainActor` type
    /// inherits that isolation, so the first version ran deliveries on the thread
    /// that draws the menu bar. PR C's permission preflight was measured taking
    /// over 100 seconds, which would have frozen the dropdown.
    @Test func deliveryRunsOffTheMainActor() async throws {
        let observed = ThreadObservation()
        let schedules = ContinueSchedules(defaults: defaults())
        schedules.deliver = { _ in
            observed.record(isMainThread: Thread.isMainThread)
            return "stubbed"
        }
        Preferences.shared.scheduledContinues = true
        defer { Preferences.shared.scheduledContinues = false }

        var due = schedule("a")
        due.armedForResetAt = Date().addingTimeInterval(-ContinueScheduler.resetSafetyPad - 1)
        schedules.arm(due)

        var session = AgentSession(
            provider: "claude-code", sessionId: "a", cwd: "/Users/dev/demo", state: .needsYou)
        session.lastEvent = "Stop"
        schedules.reconcile(sessions: [session], blockingResets: [:], now: Date())

        // Bounded wait rather than a continuation, so a seam that never delivers
        // fails the test instead of hanging CI.
        for _ in 0..<200 where observed.value == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.value == false, "delivery ran on the main thread")
    }

    /// Shared between a detached delivery task and the test body.
    private final class ThreadObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var observed: Bool?

        func record(isMainThread: Bool) {
            lock.lock()
            defer { lock.unlock() }
            observed = isMainThread
        }

        var value: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return observed
        }
    }

    @Test func updatingAnUnknownSessionIsANoOp() {
        let schedules = ContinueSchedules(defaults: defaults())
        schedules.arm(schedule("a"))
        schedules.update(sessionId: "nobody") { $0.message = "changed" }
        #expect(schedules.schedule(for: "a")?.message == "Continue")
        #expect(schedules.schedules.count == 1)
    }
}
