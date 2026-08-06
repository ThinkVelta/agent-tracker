import AppKit
import Combine
import Foundation

/// Owns the armed schedules: persists them, decides when to look again, and
/// performs whatever `ContinueScheduler` says to do.
///
/// Every trigger funnels into one place. `reconcile(sessions:blockingResets:now:)`
/// is called from the tail of `SessionStore.rebuild()` and is handed that pass's
/// already-taken `now`, so the schedule pass and the session pass can never
/// disagree about the present. The wall-clock timer does not decide anything; it
/// only asks for a pass to happen sooner than the reload tick would.
///
/// A singleton like `Preferences.shared`, and for the same reason: the dropdown
/// observes it directly, so no view gains a parameter — `MenuContentView` has two
/// construction sites (`AgentTrackerApp` and `RenderPreview`) and a new required
/// parameter would break the second. Deliberately NOT stored on `Preferences`,
/// whose `objectWillChange` re-renders the menu bar icon on every change: an
/// editable message would redraw the icon on each keystroke.
@MainActor
final class ContinueSchedules: ObservableObject {
    static let shared = ContinueSchedules()

    @Published private(set) var schedules: [ScheduledContinue] = []

    /// What happened on past deliveries, newest first.
    ///
    /// Stored separately from the schedules on purpose: a one-shot schedule is
    /// deleted the moment it fires, before its outcome exists, so an outcome kept
    /// on the record would only ever survive for repeating schedules.
    @Published private(set) var receipts: [ContinueReceipt] = []

    /// Enough to answer "did it fire last night, and what happened", not a
    /// history. This is a menu bar app.
    static let receiptsKept = 20

    /// Asks for a pass. Set by `SessionStore`, because a pass has to come from
    /// the place that reads the clock and the sessions together.
    var requestPass: () -> Void = {}

    /// Sends one message. A stored closure rather than a protocol: this repo
    /// injects behaviour with closures (`DirectoryWatcher(url:) { }`,
    /// `MenuContentView(dismiss:)`) and has no injection protocol anywhere, and
    /// there is exactly one implementation.
    ///
    /// `@Sendable` and `async`, and run from a detached task, all three on
    /// purpose. PR C's `AEDeterminePermissionToAutomateTarget` preflight was
    /// measured not returning within 100 seconds for a running-but-ungranted
    /// target, so this must not run on the main actor — and an `async` type alone
    /// does not achieve that: a plain closure literal written inside this
    /// `@MainActor` type inherits its isolation and would run there anyway.
    /// `@Sendable` makes it non-isolated, and the detached task keeps it that way.
    ///
    /// Its return value deliberately feeds only the receipt, never the schedule
    /// state, so a hung or refused delivery cannot make a settled schedule look
    /// owed again.
    var deliver: @Sendable (ContinueScheduler.Fire) async -> String

    /// A docs render builds a real `SessionStore` over synthetic sessions
    /// (`scripts/make-docs-images.sh` drives `--render-preview`). Nothing armed
    /// may act during one.
    private static let isPreviewProcess = CommandLine.arguments.contains("--render-preview")

    private let defaults: UserDefaults
    private let launchedAt: Date
    private var timer: DispatchSourceTimer?
    private var scheduledWakeUp: Date?
    /// The clock pair from the previous pass. `ContinuousClock` keeps running
    /// across sleep and `SuspendingClock` does not, so their difference over the
    /// same interval IS the time slept — measured on this machine as 12.4 of the
    /// last 22.2 days, which is why a plain `deadline:` timer is unusable.
    private var lastReading:
        (continuous: ContinuousClock.Instant, suspending: SuspendingClock.Instant)?
    /// Each token with the center that issued it. Two centers are in play —
    /// wake arrives on `NSWorkspace.shared.notificationCenter` and the clock
    /// notifications on `NotificationCenter.default` — and a token can only be
    /// removed from the one it came from.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(defaults: UserDefaults = .standard, launchedAt: Date = Date()) {
        self.defaults = defaults
        self.launchedAt = launchedAt
        deliver = { fire in
            // The PR B stub: the schedule machinery is exercised end to end and
            // nothing is typed anywhere. Real delivery replaces this closure.
            "would send \"\(fire.message)\" (delivery not implemented yet)"
        }
        schedules = Self.load(from: defaults)
        receipts = Self.loadReceipts(from: defaults)
        observeSystemChanges()
    }

    deinit {
        timer?.cancel()
        // Block observers are retained by the notification center, so leaving
        // them registered leaks a block per instance. Harmless for the shared
        // instance, which outlives the process; not harmless for tests, which
        // build a fresh store per case.
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    // MARK: - Arming

    func schedule(for sessionId: String) -> ScheduledContinue? {
        schedules.first { $0.sessionId == sessionId }
    }

    func arm(_ schedule: ScheduledContinue) {
        var updated = schedules.filter { $0.sessionId != schedule.sessionId }
        updated.append(schedule)
        persist(updated)
        log("armed \(schedule.sessionId) for \(schedule.armedForResetAt)")
        requestPass()
    }

    func disarm(sessionId: String) {
        let updated = schedules.filter { $0.sessionId != sessionId }
        guard updated.count != schedules.count else { return }
        persist(updated)
        log("disarmed \(sessionId)")
        requestPass()
    }

    /// Edits in place without disturbing `settledThrough`, so changing the text
    /// or a checkbox cannot accidentally re-owe a moment already dealt with.
    func update(sessionId: String, _ change: (inout ScheduledContinue) -> Void) {
        guard let index = schedules.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        var updated = schedules
        change(&updated[index])
        updated[index].message = ContinueScheduler.sanitize(updated[index].message)
        persist(updated)
    }

    // MARK: - The pass

    /// One pass. Called from `SessionStore.rebuild()` with that pass's `now`.
    func reconcile(sessions: [AgentSession], blockingResets: [String: Date], now: Date) {
        guard !Self.isPreviewProcess else { return }
        let enabled = Preferences.shared.scheduledContinues
        // Nothing armed and nothing to arm: the common case, and it must cost a
        // dictionary lookup rather than a clock reading or a persist.
        guard enabled || !schedules.isEmpty else { return }

        let slept = sleptSinceLastPass()
        let plan = ContinueScheduler.plan(
            ContinueScheduler.Pass(
                now: now,
                sleptSinceLastPass: slept,
                launchedAt: launchedAt,
                enabled: enabled,
                schedules: schedules,
                sessions: sessions,
                blockingResets: blockingResets))

        for receipt in plan.receipts {
            log("\(receipt.sessionId) — \(receipt.summary)")
        }
        if plan.schedules != schedules { persist(plan.schedules) }
        arrangeWakeUp(at: plan.nextWakeUp, now: now)

        // Detached, and the closure is read here on the main actor and then
        // captured by value. Anything inheriting this actor's isolation would put
        // a delivery — and PR C's 100-second permission preflight — on the thread
        // that draws the menu bar. Only the log line hops back.
        let deliver = deliver
        for fire in plan.fires {
            Task.detached { [weak self] in
                if fire.delay > 0 {
                    try? await Task.sleep(for: .seconds(fire.delay))
                }
                let outcome = await deliver(fire)
                await self?.record(fire: fire, outcome: outcome)
            }
        }
    }

    /// Files a receipt, logs it, and tells the user. Called after the send has
    /// already happened, so nothing here can undo or retry it — a notification
    /// that fails to post must not turn a delivered message into a pending one.
    private func record(fire: ContinueScheduler.Fire, outcome: String) {
        let receipt = ContinueReceipt(
            sessionId: fire.sessionId,
            project: projectName(for: fire.sessionId),
            message: fire.message,
            at: Date(),
            outcome: .sent,
            detail: outcome)
        file(receipt)
    }

    /// The public seam for a receipt, so delivery and its refusals file the same
    /// kind of record through one path.
    func file(_ receipt: ContinueReceipt) {
        var updated = [receipt] + receipts
        if updated.count > Self.receiptsKept { updated = Array(updated.prefix(Self.receiptsKept)) }
        receipts = updated
        persistReceipts(updated)
        log("\(receipt.sessionId) — \(receipt.summary)")
        Task { await ContinueNotifier.post(receipt) }
    }

    /// Best effort: a schedule can outlive the row it was armed from, and a
    /// receipt is more useful with a name than with an opaque id.
    private func projectName(for sessionId: String) -> String {
        schedules.first { $0.sessionId == sessionId }?.target?.title ?? sessionId
    }

    /// Seconds asleep since the previous pass, from the divergence between a
    /// clock that keeps counting through sleep and one that does not. Zero on the
    /// first pass of a process, which is why `launchedAt` exists: after a
    /// relaunch this measurement cannot explain anything.
    private func sleptSinceLastPass() -> TimeInterval {
        let continuous = ContinuousClock.now
        let suspending = SuspendingClock.now
        defer { lastReading = (continuous, suspending) }
        guard let last = lastReading else { return 0 }
        let continuousDelta = Self.seconds(last.continuous.duration(to: continuous))
        let suspendingDelta = Self.seconds(last.suspending.duration(to: suspending))
        return max(0, continuousDelta - suspendingDelta)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    // MARK: - Looking again

    /// A wall-clock timer, never `deadline:`. The uptime clock does not advance
    /// during sleep, so a `deadline:` timer set for tonight fires whenever the
    /// machine has been awake that long instead — measured here as a 12-day gap
    /// over three weeks.
    ///
    /// Punctuality only. The reload tick, the hook watcher and the Codex scanner
    /// all reach `reconcile` anyway, so a timer that never fires costs lateness
    /// bounded by the refresh interval, never a missed fire.
    private func arrangeWakeUp(at moment: Date?, now: Date) {
        guard let moment else {
            timer?.cancel()
            timer = nil
            scheduledWakeUp = nil
            return
        }
        guard scheduledWakeUp != moment else { return }
        timer?.cancel()
        scheduledWakeUp = moment
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            wallDeadline: .now() + max(0, moment.timeIntervalSince(now)), leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.requestPass() }
        }
        source.activate()
        timer = source
    }

    /// Waking, a clock step and a timezone change all invalidate what the timer
    /// was waiting for, so each asks for a fresh pass rather than trying to
    /// adjust the deadline in place.
    ///
    /// `didWakeNotification` is posted on `NSWorkspace.shared.notificationCenter`
    /// and NOT on `NotificationCenter.default`; registering on the wrong one
    /// silently never fires.
    private func observeSystemChanges() {
        guard !Self.isPreviewProcess else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            (
                workspace,
                workspace.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.log("woke — re-evaluating")
                        self?.timerNeedsRebuilding()
                    }
                }
            ))
        for name in [
            NSNotification.Name.NSSystemClockDidChange,
            NSNotification.Name.NSSystemTimeZoneDidChange,
        ] {
            observers.append(
                (
                    .default,
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main)
                    {
                        [weak self] _ in
                        Task { @MainActor in
                            self?.log("clock or timezone changed — re-evaluating")
                            self?.timerNeedsRebuilding()
                        }
                    }
                ))
        }
    }

    /// The pending deadline was computed against a clock that has since moved, so
    /// it is dropped and the next pass recomputes it from scratch.
    private func timerNeedsRebuilding() {
        timer?.cancel()
        timer = nil
        scheduledWakeUp = nil
        requestPass()
    }

    // MARK: - Storage

    /// One JSON string per record, so a single corrupt entry loses one schedule
    /// rather than all of them. Readable through `defaults read` on purpose: the
    /// alternative is an opaque blob nobody can inspect when a schedule
    /// misbehaves.
    /// Distinct from `Preferences`' `scheduledContinues` gate on purpose: both
    /// write to the same `UserDefaults` domain, so sharing a key would have the
    /// records overwrite the Bool and the gate then read as off — arming a
    /// schedule would silently disable the feature that runs it.
    static let storageKey = "scheduledContinueRecords"

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()

    /// Its own key, for the same reason the schedules have one: two values in
    /// one `UserDefaults` key overwrite each other, which is a bug this feature
    /// has already shipped once.
    static let receiptsKey = "continueReceipts"

    static func loadReceipts(from defaults: UserDefaults) -> [ContinueReceipt] {
        guard let stored = defaults.object(forKey: receiptsKey) as? [String] else { return [] }
        return stored.compactMap { entry in
            guard let data = entry.data(using: .utf8) else { return nil }
            return try? coder.decoder.decode(ContinueReceipt.self, from: data)
        }
    }

    private func persistReceipts(_ updated: [ContinueReceipt]) {
        let encoded = updated.compactMap { receipt -> String? in
            guard let data = try? Self.coder.encoder.encode(receipt) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        defaults.set(encoded, forKey: Self.receiptsKey)
    }

    static func load(from defaults: UserDefaults) -> [ScheduledContinue] {
        guard let stored = defaults.object(forKey: storageKey) as? [String] else { return [] }
        return stored.compactMap { entry in
            guard let data = entry.data(using: .utf8) else { return nil }
            return try? coder.decoder.decode(ScheduledContinue.self, from: data)
        }
    }

    private func persist(_ updated: [ScheduledContinue]) {
        schedules = updated
        let encoded = updated.compactMap { schedule -> String? in
            guard let data = try? Self.coder.encoder.encode(schedule) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        defaults.set(encoded, forKey: Self.storageKey)
    }

    private func log(_ message: String) {
        DebugLog.log("[schedule] \(DebugLog.timestamp()) \(message)")
    }
}
