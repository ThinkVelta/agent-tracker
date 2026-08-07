import Foundation

/// A "Continue" the user asked to have sent when a usage window resets.
///
/// The moment is stored as an **absolute instant**, not as a wall-clock rule.
/// That is only safe because the moment is never invented: it is the provider's
/// own `resets_at`, which arrives as an epoch second and is therefore already
/// timezone-independent. A recurring "every day at 01:20" rule would have to
/// persist a timezone identifier and re-derive through `Calendar`, with all the
/// DST arithmetic that implies — and it would also be wrong for this feature,
/// because a five-hour window walks around the clock, so the same wall time
/// tomorrow is not a reset at all.
struct ScheduledContinue: Equatable, Codable {
    var sessionId: String
    var provider: String
    /// What to send. "Continue" unless the user edited it.
    var message: String
    /// The reset this is armed against.
    var armedForResetAt: Date
    /// Stay armed after firing, re-arming when a later reset is observed. Until
    /// one is, a repeating schedule has no computable moment — the row says so
    /// rather than showing an invented time.
    var repeats: Bool
    /// Send anyway when the machine wakes to find the moment already past.
    var sendsOnWake: Bool
    /// No moment at or before this instant is owed anything any more.
    ///
    /// One field rather than a `(firedAt, dueAt, state)` trio that can disagree.
    /// It advances on a fire *and* on a deliberate skip, which makes "evaluate
    /// twice, fire once" a property of the arithmetic instead of a rule someone
    /// has to remember.
    var settledThrough: Date?

    /// The pane this was armed against, and the agent process that was in it.
    ///
    /// Optional so records written before delivery existed still decode — a
    /// non-optional field would silently drop every schedule armed by the version
    /// that shipped the scheduler. Absent simply means "resolve it at fire time",
    /// which then has no recorded pane to disagree with and refuses if the window
    /// is ambiguous, exactly as a fresh arming would.
    var target: ContinueDelivery.Target?
    var agent: ProcessIdentity?

    init(
        sessionId: String,
        provider: String,
        message: String = ContinueScheduler.defaultMessage,
        armedForResetAt: Date,
        repeats: Bool = false,
        sendsOnWake: Bool = true,
        settledThrough: Date? = nil,
        target: ContinueDelivery.Target? = nil,
        agent: ProcessIdentity? = nil
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.message = ContinueScheduler.sanitize(message)
        self.armedForResetAt = armedForResetAt
        self.repeats = repeats
        self.sendsOnWake = sendsOnWake
        self.settledThrough = settledThrough
        self.target = target
        self.agent = agent
    }

    /// Whether this schedule has already dealt with the moment it holds.
    var isSettled: Bool {
        guard let settledThrough else { return false }
        return settledThrough >= armedForResetAt
    }

    /// The moment this will fire at, if there is one at all.
    ///
    /// A settled repeating schedule has none: the next moment cannot be derived
    /// from a five-hour window that walks around the clock, so it has to be
    /// observed. `armedForResetAt` still holds the moment it *last* fired for,
    /// which is a time in the past — displaying that as "sends at" would be a
    /// promise about a moment that has already gone.
    var pendingMoment: Date? {
        isSettled ? nil : armedForResetAt
    }
}

/// Decides *when* a scheduled continue fires, and nothing else.
///
/// One pure function, `plan(_:)`, takes the whole world as a value and returns
/// what to do. It reads no clock, touches no disk, and sends nothing — so every
/// hard case (slept through the moment, relaunched mid-queue, a permission
/// prompt open at the reset instant) is a fixture rather than a scenario someone
/// has to reproduce on a real machine.
///
/// Deliberately no `now: Date = Date()` defaults anywhere in this file, unlike
/// `UsageLimit.isBlocking(now:)`. The entire bug class here is two clocks
/// disagreeing about the present, and a default lets a caller forget to pass the
/// pass's own reading.
enum ContinueScheduler {
    static let defaultMessage = "Continue"

    /// How far past its moment a fire still counts as on time. The same 120
    /// seconds as `AccountLimits.sameWindowTolerance`, for the same reason: the
    /// sources reporting a reset do not agree to the second.
    static let punctualTolerance: TimeInterval = 120

    /// Waited out before firing. A reset can move up to
    /// `AccountLimits.sameWindowTolerance` *later* while still being the same
    /// window (that merge keeps the later of two near-identical readings), so
    /// firing exactly on the stored instant risks firing before the reset
    /// actually happened.
    static let resetSafetyPad: TimeInterval = 120

    /// Gap between two fires that came due together. Every session on one
    /// account shares that account's reset, so without a gap three agents race
    /// into a fresh window and burn it between them.
    static let deliveryStagger: TimeInterval = 20

    /// Past this, the window it was armed for is long gone and the session has
    /// probably been worked in since. Ruben's call (2026-08-05): twelve hours,
    /// so an overnight sleep still fires when the lid opens.
    static let maximumLateness: TimeInterval = 12 * 3600

    /// Providers whose lifecycle the app can read well enough to send blind
    /// into their terminal.
    ///
    /// The bar is R1: something that says "this turn is over" and is *not* said
    /// while a permission prompt is open, since a send at a prompt would answer
    /// it. Both providers now clear it through the same field — their hooks
    /// write `Stop` for a finished turn and a separate event for a waiting
    /// prompt (`Notification` for Claude, `PermissionRequest` for Codex).
    ///
    /// A Codex row the rollout scanner produced does *not* clear it, and that is
    /// the point: its `lastEvent` reads `task_complete`, because a rollout
    /// records no line meaning "waiting on you". So only a session the hooks
    /// actually cover can ever be armed, and one whose hooks are installed but
    /// untrusted refuses rather than firing into the dark.
    static let supportedProviders: Set<String> = ["claude-code", "codex"]

    /// Everything a decision depends on, as one value.
    struct Pass: Equatable {
        var now: Date
        /// Seconds the machine spent asleep since the previous pass. Zero after
        /// a relaunch, because the in-process clocks start over — which is why
        /// `launchedAt` exists rather than being derived from this.
        var sleptSinceLastPass: TimeInterval
        /// When this process started. A moment older than this passed while the
        /// app was not running, which is a different thing from sleeping.
        var launchedAt: Date
        /// The feature gate. Off means: change nothing, fire nothing.
        var enabled: Bool
        var schedules: [ScheduledContinue]
        var sessions: [AgentSession]
        /// The reset currently blocking each provider. Present only while the
        /// account is actually out of quota, which is why a fire uses the
        /// schedule's own stored instant instead: at the moment the window
        /// resets, this entry disappears.
        var blockingResets: [String: Date]
    }

    struct Plan: Equatable {
        /// What to send, in order, each after its own delay.
        var fires: [Fire]
        /// The record set to persist, replacing the one in the pass.
        var schedules: [ScheduledContinue]
        /// What happened, for the durable log. A feature that acts while nobody
        /// watches owes the user a receipt.
        var receipts: [Receipt]
        /// When to look again, if anything is pending.
        var nextWakeUp: Date?
    }

    struct Fire: Equatable, Sendable {
        var sessionId: String
        var message: String
        /// Waited before this one is sent, staggering a fan-out.
        var delay: TimeInterval
        var lateness: Lateness
        /// What arming recorded, carried through untouched. The planner decides
        /// nothing with either: they exist so delivery can re-verify against what
        /// was true when the user armed it, rather than re-deriving a pane and
        /// typing into whatever now looks closest.
        var target: ContinueDelivery.Target?
        var agent: ProcessIdentity?
    }

    /// Why a fire is late, which decides whether it happens at all.
    enum Lateness: Equatable, Sendable {
        case onTime
        /// The machine slept through the moment.
        case slept(seconds: TimeInterval)
        /// The app was not running when the moment passed.
        case appNotRunning(seconds: TimeInterval)
        /// Awake, running, and still late — so this scheduler misbehaved. Fires
        /// regardless of the send-on-wake preference, because that preference is
        /// about being away, and marks itself in the log as a defect.
        case defect(seconds: TimeInterval)

        var isLate: Bool { self != .onTime }

        var summary: String {
            switch self {
            case .onTime: return "on time"
            case .slept(let seconds): return "\(Int(seconds))s late, machine slept"
            case .appNotRunning(let seconds): return "\(Int(seconds))s late, app was not running"
            case .defect(let seconds): return "\(Int(seconds))s late while awake — scheduler defect"
            }
        }
    }

    enum Outcome: Equatable {
        case fired(message: String, lateness: Lateness)
        case held(reason: String)
        case skipped(reason: String)
        case cancelled(reason: String)
        case rearmed(moment: Date)
    }

    struct Receipt: Equatable {
        var sessionId: String
        var outcome: Outcome

        var summary: String {
            switch outcome {
            case .fired(let message, let lateness):
                return "fired \"\(message)\" (\(lateness.summary))"
            case .held(let reason): return "held — \(reason)"
            case .skipped(let reason): return "skipped — \(reason)"
            case .cancelled(let reason): return "cancelled — \(reason)"
            case .rearmed(let moment): return "re-armed for \(moment)"
            }
        }
    }

    /// Whether a row can be armed, and if not, what to tell the user. The reason
    /// is the whole self-discoverability point, so there is always one.
    enum Availability: Equatable {
        case available(resetsAt: Date)
        case unavailable(reason: String)

        var resetsAt: Date? {
            guard case .available(let moment) = self else { return nil }
            return moment
        }

        var reason: String? {
            guard case .unavailable(let reason) = self else { return nil }
            return reason
        }
    }

    /// Gated on the same condition that makes a row say "Usage limit reached":
    /// `AccountLimits` is not published, so the only thing that redraws a row
    /// when a limit appears or expires is `sessions` republishing. Tying arming
    /// to that predicate makes the armable row and the redrawn row the same row.
    ///
    /// Keyed **per session**, not per provider. A usage limit is account-wide, so
    /// a provider-keyed lookup would offer the clock on every Claude row the
    /// moment any one of them was blocked — including rows that are running, or
    /// sitting at a permission prompt.
    static func availability(
        for session: AgentSession,
        armableResetBySession: [String: Date],
        enabled: Bool
    ) -> Availability {
        guard enabled else {
            return .unavailable(reason: "Turn on scheduled continues in Settings")
        }
        guard supportedProviders.contains(session.provider) else {
            return .unavailable(
                reason: "\(session.providerDisplayName) cannot be resumed automatically")
        }
        guard let moment = armableResetBySession[session.sessionId] else {
            return .unavailable(reason: "Available once this session is waiting on a usage limit")
        }
        return .available(resetsAt: moment)
    }

    /// A message safe to hand to a terminal later: one line, trimmed, bounded.
    ///
    /// Enforced at the record's own boundary rather than at delivery, because a
    /// newline is what would turn one typed line into a typed line plus a
    /// Return — and Return at an open permission prompt approves the tool call.
    static func sanitize(_ message: String) -> String {
        let single = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = single.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return defaultMessage }
        return String(trimmed.prefix(200))
    }

    // MARK: - The decision

    static func plan(_ pass: Pass) -> Plan {
        // The gate is checked before anything is derived, so a disabled feature
        // cannot advance a single record. Turning it off and on again must leave
        // the schedules exactly as they were.
        guard pass.enabled else {
            return Plan(fires: [], schedules: pass.schedules, receipts: [], nextWakeUp: nil)
        }

        var live: [String: AgentSession] = [:]
        for session in pass.sessions { live[session.sessionId] = session }

        var kept: [ScheduledContinue] = []
        var fires: [Fire] = []
        var receipts: [Receipt] = []
        var nextWakeUp: Date?
        func note(_ sessionId: String, _ outcome: Outcome) {
            receipts.append(Receipt(sessionId: sessionId, outcome: outcome))
        }
        // Counts fires decided in THIS pass, so the stagger and the punctuality
        // allowance agree: the seventh of nine is not a defect for being late by
        // exactly the delay this scheduler gave it.
        var dueCount = 0

        func considerWakeUp(_ moment: Date) {
            nextWakeUp = min(nextWakeUp ?? moment, moment)
        }

        for schedule in pass.schedules {
            var schedule = schedule

            // The session is gone. "Continue" is meaningless once the agent has
            // exited, and the terminal window may since have been reused, so the
            // record goes rather than waiting for a session id that will not
            // come back.
            guard let session = live[schedule.sessionId] else {
                note(schedule.sessionId, .cancelled(reason: "session ended"))
                continue
            }

            // Defence in depth: arming already refuses an unsupported provider,
            // but a record could arrive from an older build or a hand-edited
            // domain, and a provider whose turn state we cannot read is exactly
            // the case R1 has no gate for.
            guard supportedProviders.contains(schedule.provider) else {
                note(
                    schedule.sessionId,
                    .cancelled(reason: "\(schedule.provider) cannot be resumed automatically"))
                continue
            }

            let observed = pass.blockingResets[schedule.provider]

            if schedule.isSettled {
                // A one-shot is done; the record goes.
                guard schedule.repeats else { continue }
                // Repeating: re-arm only when a genuinely later window is
                // observed. Within the tolerance it is the same reset we already
                // fired for, which would otherwise fire again immediately.
                if let observed,
                    observed > schedule.armedForResetAt.addingTimeInterval(punctualTolerance)
                {
                    schedule.armedForResetAt = observed
                    note(schedule.sessionId, .rearmed(moment: observed))
                    considerWakeUp(observed.addingTimeInterval(resetSafetyPad))
                }
                kept.append(schedule)
                continue
            }

            // Adopt a reading that refines the same window. `AccountLimits`
            // keeps the later of two near-identical resets, so the stored
            // instant can legitimately move a little after arming, and a
            // schedule frozen at arm time would fire before the reset happened.
            if let observed,
                abs(observed.timeIntervalSince(schedule.armedForResetAt)) <= punctualTolerance,
                observed > schedule.armedForResetAt
            {
                schedule.armedForResetAt = observed
            }

            let fireAt = schedule.armedForResetAt.addingTimeInterval(resetSafetyPad)
            guard pass.now >= fireAt else {
                considerWakeUp(fireAt)
                kept.append(schedule)
                continue
            }

            let late = pass.now.timeIntervalSince(fireAt)
            let lateness = classify(late: late, moment: schedule.armedForResetAt, pass: pass)

            // Too late to be a continuation of the work that stopped: the window
            // has rolled over and the session has probably been used since.
            if late > maximumLateness {
                schedule.settledThrough = schedule.armedForResetAt
                note(
                    schedule.sessionId,
                    .skipped(
                        reason: "\(Int(late / 3600))h past the reset — beyond the "
                            + "\(Int(maximumLateness / 3600))h limit"))
                if schedule.repeats { kept.append(schedule) }
                continue
            }

            // The user asked not to be resumed after being away. A defect is
            // exempt: that preference is about absence, and suppressing a fire
            // the scheduler itself delayed would hide the bug rather than
            // respect a choice.
            if lateness.isLate, !schedule.sendsOnWake, !isDefect(lateness) {
                schedule.settledThrough = schedule.armedForResetAt
                note(
                    schedule.sessionId,
                    .skipped(reason: "\(lateness.summary); auto-send on wake is off"))
                if schedule.repeats { kept.append(schedule) }
                continue
            }

            // R1, the critical gate, checked at FIRE time and not only at arming
            // time. A `Notification` red is a permission prompt, and Return at
            // one approves the focused tool call. Held rather than skipped: a
            // dialog open at the reset instant is a reason to wait, not a reason
            // to throw the schedule away.
            guard session.lastEvent == "Stop" else {
                note(
                    schedule.sessionId,
                    .held(reason: "session is \(session.lastEvent ?? "in an unknown state")"))
                considerWakeUp(pass.now.addingTimeInterval(deliveryStagger))
                kept.append(schedule)
                continue
            }

            fires.append(
                Fire(
                    sessionId: schedule.sessionId,
                    message: schedule.message,
                    delay: Double(dueCount) * deliveryStagger,
                    lateness: lateness,
                    target: schedule.target,
                    agent: schedule.agent
                ))
            note(schedule.sessionId, .fired(message: schedule.message, lateness: lateness))
            dueCount += 1
            // Settled before the send is attempted, never after. A delivery that
            // fails, hangs or is refused must not leave the record looking owed,
            // or the next pass sends it again.
            schedule.settledThrough = schedule.armedForResetAt
            if schedule.repeats { kept.append(schedule) }
        }

        return Plan(fires: fires, schedules: kept, receipts: receipts, nextWakeUp: nextWakeUp)
    }

    private static func isDefect(_ lateness: Lateness) -> Bool {
        if case .defect = lateness { return true }
        return false
    }

    /// Why the *moment* was missed. Deliberately not adjusted for the stagger a
    /// fire is about to wait out: lateness is measured once, when the pass
    /// decides, so every fire in one fan-out reports the same missed moment and
    /// its queue position travels separately as `Fire.delay`. Two orthogonal
    /// facts, both on the receipt.
    ///
    /// (The design this was grafted from grew the tolerance by the queue position
    /// so a late member of a fan-out would not be filed as a defect. That guards
    /// against a *later* pass re-observing the same schedule as late, which
    /// cannot happen here: settlement lands in the same pass as the decision, so
    /// growing the tolerance would only make four fires of identical lateness
    /// report four different verdicts.)
    ///
    /// Order matters: a relaunch resets the in-process sleep measurement to zero,
    /// so "we were not running" has to be ruled out before sleep can be blamed.
    private static func classify(late: TimeInterval, moment: Date, pass: Pass) -> Lateness {
        guard late > punctualTolerance else { return .onTime }
        if moment < pass.launchedAt { return .appNotRunning(seconds: late) }
        // The sleep has to actually account for the lateness. A machine that
        // napped for a minute does not explain a fire nine hours late.
        if pass.sleptSinceLastPass >= late - punctualTolerance { return .slept(seconds: late) }
        return .defect(seconds: late)
    }
}
