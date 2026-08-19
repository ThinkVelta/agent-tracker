import Foundation
import Testing

@testable import AgentTracker

/// The planner is pure, so every one of these is a fixture rather than a
/// scenario someone has to reproduce by sleeping a real machine.
final class ContinueSchedulerTests {
    /// 2026-08-05T09:00:00Z. An absolute instant, never a wall-clock rule — the
    /// moment always comes from the provider's own epoch-seconds reset.
    private let reset = Date(timeIntervalSince1970: 1_785_927_600)
    private let launch = Date(timeIntervalSince1970: 1_785_920_000)

    private func session(
        _ id: String = "s1",
        lastEvent: String? = "Stop"
    ) -> AgentSession {
        var session = AgentSession(
            sessionId: id, cwd: "/Users/dev/demo", state: .needsYou)
        session.lastEvent = lastEvent
        return session
    }

    private func schedule(
        _ id: String = "s1",
        repeats: Bool = false,
        sendsOnWake: Bool = true,
        settledThrough: Date? = nil,
        resetsAt: Date? = nil
    ) -> ScheduledContinue {
        ScheduledContinue(
            sessionId: id, armedForResetAt: resetsAt ?? reset,
            repeats: repeats, sendsOnWake: sendsOnWake, settledThrough: settledThrough)
    }

    private func pass(
        now: Date,
        slept: TimeInterval = 0,
        launchedAt: Date? = nil,
        enabled: Bool = true,
        schedules: [ScheduledContinue],
        sessions: [AgentSession]? = nil,
        blockingReset: Date? = nil
    ) -> ContinueScheduler.Pass {
        ContinueScheduler.Pass(
            now: now,
            sleptSinceLastPass: slept,
            launchedAt: launchedAt ?? launch,
            enabled: enabled,
            schedules: schedules,
            sessions: sessions ?? [session()],
            blockingReset: blockingReset)
    }

    /// The safety pad is waited out, so "due" is the reset plus the pad.
    private var fireMoment: Date {
        reset.addingTimeInterval(ContinueScheduler.resetSafetyPad)
    }

    // MARK: - The property that makes everything else safe

    /// The executable form of "reads no clock": the same pass planned twice must
    /// give the same answer, byte for byte.
    @Test func planningIsAFunctionOfItsInputAlone() {
        let input = pass(now: fireMoment, schedules: [schedule()])
        #expect(ContinueScheduler.plan(input) == ContinueScheduler.plan(input))
    }

    /// Evaluate-twice-fire-once, and it is arithmetic rather than policy: the
    /// fire advances `settledThrough` past the moment, so the second pass has
    /// nothing owed.
    @Test func aFiredScheduleDoesNotFireAgain() throws {
        let first = ContinueScheduler.plan(
            pass(now: fireMoment, schedules: [schedule(repeats: true)]))
        #expect(first.fires.count == 1)

        let second = ContinueScheduler.plan(
            pass(now: fireMoment.addingTimeInterval(1), schedules: first.schedules))
        #expect(second.fires.isEmpty)

        // And again much later, still nothing.
        let third = ContinueScheduler.plan(
            pass(now: fireMoment.addingTimeInterval(3600), schedules: second.schedules))
        #expect(third.fires.isEmpty)
    }

    // MARK: - Waiting, then firing

    @Test func aMomentInTheFutureOnlySchedulesALook() throws {
        let plan = ContinueScheduler.plan(
            pass(now: reset.addingTimeInterval(-600), schedules: [schedule()]))
        #expect(plan.fires.isEmpty)
        #expect(plan.receipts.isEmpty)
        #expect(plan.nextWakeUp == fireMoment)
        #expect(plan.schedules.count == 1)
    }

    /// The pad is not decoration: `AccountLimits` keeps the later of two
    /// near-identical resets, so the stored instant can move within its own
    /// window and firing exactly on it risks firing before the reset happened.
    @Test func theSafetyPadIsWaitedOutBeforeFiring() {
        let justBefore = ContinueScheduler.plan(
            pass(now: fireMoment.addingTimeInterval(-1), schedules: [schedule()]))
        #expect(justBefore.fires.isEmpty)

        let atTheMoment = ContinueScheduler.plan(pass(now: fireMoment, schedules: [schedule()]))
        #expect(atTheMoment.fires.count == 1)
        #expect(atTheMoment.fires.first?.lateness == .onTime)
        #expect(atTheMoment.fires.first?.message == "Continue")
    }

    /// A one-shot leaves nothing behind; a repeating one stays, settled, with no
    /// computable moment until a later reset is seen.
    @Test func aOneShotIsGoneAfterwardsAndARepeatingOneWaits() {
        let once = ContinueScheduler.plan(pass(now: fireMoment, schedules: [schedule()]))
        #expect(once.schedules.isEmpty)

        let repeating = ContinueScheduler.plan(
            pass(now: fireMoment, schedules: [schedule(repeats: true)]))
        #expect(repeating.schedules.count == 1)
        #expect(repeating.schedules.first?.isSettled == true)
        #expect(repeating.nextWakeUp == nil)
    }

    // MARK: - Repeating, which is re-arming rather than recurring

    /// A five-hour window walks around the clock, so the next moment cannot be
    /// derived — it has to be observed. Anything inside the tolerance is the same
    /// reset we already fired for, and re-arming on it would fire twice.
    @Test func repeatingReArmsOnlyOnAGenuinelyLaterReset() {
        let settled = schedule(repeats: true, settledThrough: reset)

        let sameWindow = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(60), schedules: [settled],
                blockingReset: reset.addingTimeInterval(90)))
        #expect(sameWindow.fires.isEmpty)
        #expect(sameWindow.schedules.first?.armedForResetAt == reset)
        #expect(sameWindow.receipts.isEmpty)

        let nextWindow = reset.addingTimeInterval(5 * 3600)
        let rolled = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(60), schedules: [settled],
                blockingReset: nextWindow))
        #expect(rolled.fires.isEmpty)
        #expect(rolled.schedules.first?.armedForResetAt == nextWindow)
        #expect(rolled.schedules.first?.isSettled == false)
        #expect(
            rolled.nextWakeUp == nextWindow.addingTimeInterval(ContinueScheduler.resetSafetyPad))
        #expect(rolled.receipts.first?.outcome == .rearmed(moment: nextWindow))
    }

    /// A reading that refines the same window is adopted; one that would move the
    /// moment earlier is not, or a schedule could be dragged backwards into
    /// firing before its reset.
    @Test func aRefinedResetIsAdoptedButNeverAnEarlierOne() {
        let later = reset.addingTimeInterval(37)
        let refined = ContinueScheduler.plan(
            pass(
                now: reset.addingTimeInterval(-600), schedules: [schedule()],
                blockingReset: later))
        #expect(refined.schedules.first?.armedForResetAt == later)

        let earlier = ContinueScheduler.plan(
            pass(
                now: reset.addingTimeInterval(-600), schedules: [schedule()],
                blockingReset: reset.addingTimeInterval(-45)))
        #expect(earlier.schedules.first?.armedForResetAt == reset)
    }

    // MARK: - Lateness, and what it changes

    @Test func sleepingThroughTheMomentStillFiresByDefault() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(9 * 3600), slept: 9 * 3600,
                schedules: [schedule()]))
        let fire = try #require(plan.fires.first)
        #expect(fire.lateness == .slept(seconds: 9 * 3600))
    }

    @Test func sleepingThroughItSkipsWhenTheUserOptedOut() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(9 * 3600), slept: 9 * 3600,
                schedules: [schedule(sendsOnWake: false)]))
        #expect(plan.fires.isEmpty)
        // Settled, so it does not sit there re-deciding this every second.
        #expect(plan.schedules.isEmpty)
        #expect(plan.receipts.first?.summary.contains("auto-send on wake is off") == true)
    }

    /// A relaunch zeroes the in-process sleep measurement, so "we were not
    /// running" has to be ruled out before sleep can be blamed for lateness.
    @Test func aMomentOlderThanThisProcessIsNotBlamedOnSleep() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(3600), slept: 0,
                launchedAt: reset.addingTimeInterval(1800), schedules: [schedule()]))
        let fire = try #require(plan.fires.first)
        #expect(fire.lateness == .appNotRunning(seconds: 3600))
    }

    /// Awake, running, and late anyway means this scheduler misbehaved. It fires
    /// regardless of the send-on-wake preference, because that preference is
    /// about being away — suppressing this would hide the bug.
    @Test func anAwakeLateFireIsADefectAndSendsAnyway() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(600), slept: 0,
                schedules: [schedule(sendsOnWake: false)]))
        let fire = try #require(plan.fires.first)
        #expect(fire.lateness == .defect(seconds: 600))
        #expect(plan.receipts.first?.summary.contains("scheduler defect") == true)
    }

    /// A nap does not explain nine hours.
    @Test func sleepMustActuallyAccountForTheLateness() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(9 * 3600), slept: 60,
                schedules: [schedule()]))
        #expect(plan.fires.first?.lateness == .defect(seconds: 9 * 3600))
    }

    /// Ruben's call: twelve hours, so an overnight sleep fires but a fire into a
    /// window that rolled over long ago does not.
    @Test func pastTwelveHoursItIsAbandonedRatherThanSent() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(13 * 3600), slept: 13 * 3600,
                schedules: [schedule()]))
        #expect(plan.fires.isEmpty)
        #expect(plan.receipts.first?.summary.contains("beyond the 12h limit") == true)

        let justInside = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(11 * 3600), slept: 11 * 3600,
                schedules: [schedule()]))
        #expect(justInside.fires.count == 1)
    }

    // MARK: - R1, the critical gate

    /// Return at an open permission prompt approves the focused tool call, and a
    /// `Notification` red IS a permission prompt. Held rather than skipped: a
    /// dialog open at the reset instant is a reason to wait.
    @Test func aPermissionPromptHoldsTheFireWithoutLosingTheSchedule() throws {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment, schedules: [schedule()],
                sessions: [session(lastEvent: "Notification")]))
        #expect(plan.fires.isEmpty)
        #expect(plan.schedules.count == 1)
        // NOT settled — still owed, so it fires once the dialog is dealt with.
        #expect(plan.schedules.first?.isSettled == false)
        #expect(plan.receipts.first?.summary.contains("held") == true)
        #expect(plan.nextWakeUp != nil)

        // Same pass once the turn has genuinely ended.
        let after = ContinueScheduler.plan(
            pass(now: fireMoment.addingTimeInterval(20), schedules: plan.schedules))
        #expect(after.fires.count == 1)
    }

    @Test func anyStateOtherThanAFinishedTurnHolds() {
        for event in ["Notification", "UserPromptSubmit", "PreToolUse", "SessionStart", nil] {
            let plan = ContinueScheduler.plan(
                pass(
                    now: fireMoment, schedules: [schedule()],
                    sessions: [session(lastEvent: event)]))
            #expect(plan.fires.isEmpty, "event \(event ?? "nil") should not fire")
            #expect(plan.schedules.first?.isSettled == false)
        }
    }

    // MARK: - Fan-out

    /// Every session on one account shares that account's reset, so without a gap
    /// three agents race into a fresh window and burn it between them.
    @Test func schedulesDueTogetherFireInSequenceNotAtOnce() {
        let ids = ["a", "b", "c"]
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment,
                schedules: ids.map { schedule($0) },
                sessions: ids.map { session($0) }))
        #expect(plan.fires.count == 3)
        #expect(plan.fires.map(\.delay) == [0, 20, 40])
    }

    /// Lateness describes the missed moment, the delay describes the queue
    /// position, and they do not contaminate each other: four fires that missed
    /// the same moment report the same lateness however far down the queue they
    /// are. Anything else would give four identical situations four verdicts.
    @Test func oneFanOutReportsOneLatenessAndFourDifferentDelays() {
        let ids = ["a", "b", "c", "d"]
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(150),
                schedules: ids.map { schedule($0) },
                sessions: ids.map { session($0) }))
        #expect(plan.fires.count == 4)
        #expect(plan.fires.map(\.delay) == [0, 20, 40, 60])
        #expect(plan.fires.allSatisfy { $0.lateness == .defect(seconds: 150) })
    }

    // MARK: - Refusals

    @Test func aScheduleWhoseSessionEndedIsCancelled() {
        let plan = ContinueScheduler.plan(
            pass(now: fireMoment, schedules: [schedule("gone")], sessions: [session("other")]))
        #expect(plan.fires.isEmpty)
        #expect(plan.schedules.isEmpty)
        #expect(plan.receipts.first?.outcome == .cancelled(reason: "session ended"))
    }

    /// Codex is armable now that its hooks distinguish a finished turn from an
    /// open approval prompt — the same bar Claude clears.
    @Test func codexFiresLikeClaudeDoes() {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment, schedules: [schedule("c1")],
                sessions: [session("c1")]))
        #expect(plan.fires.count == 1)
        #expect(plan.fires.first?.sessionId == "c1")
    }

    /// The gate is checked before anything is derived, so turning the feature off
    /// and on again leaves the schedules exactly as they were.
    @Test func theFeatureGateChangesNothingAtAll() {
        let armed = [schedule("a"), schedule("b", repeats: true)]
        let plan = ContinueScheduler.plan(
            pass(now: fireMoment.addingTimeInterval(3600), enabled: false, schedules: armed))
        #expect(plan.fires.isEmpty)
        #expect(plan.receipts.isEmpty)
        #expect(plan.nextWakeUp == nil)
        #expect(plan.schedules == armed)
    }

    // MARK: - The message

    /// A newline would turn one typed line into a line plus a Return, and Return
    /// at an open permission prompt approves the focused tool call. Enforced at
    /// the record's boundary rather than at delivery.
    @Test func theMessageIsOneBoundedLine() {
        #expect(ContinueScheduler.sanitize("Continue\nrm -rf /") == "Continue")
        #expect(ContinueScheduler.sanitize("  keep going  ") == "keep going")
        #expect(ContinueScheduler.sanitize("") == "Continue")
        #expect(ContinueScheduler.sanitize("   ") == "Continue")
        #expect(ContinueScheduler.sanitize("\n\nafter blanks") == "after blanks")
        #expect(ContinueScheduler.sanitize(String(repeating: "x", count: 500)).count == 200)
        // Applied by the record too, not just available to be called.
        #expect(
            ScheduledContinue(
                sessionId: "s", message: "a\nb", armedForResetAt: reset
            )
            .message == "a")
    }

    /// What the row is allowed to promise. A settled repeating schedule still
    /// holds the moment it last fired for, so anything reading `armedForResetAt`
    /// to display a fire time would present a moment that has already gone as
    /// something about to happen.
    @Test func aSettledScheduleHasNoMomentToShow() {
        #expect(schedule().pendingMoment == reset)

        let settled = schedule(repeats: true, settledThrough: reset)
        #expect(settled.isSettled)
        #expect(settled.pendingMoment == nil)
        #expect(settled.armedForResetAt == reset, "the record keeps it; only the display drops it")

        // Re-armed onto a later window, so there is a moment again.
        let nextWindow = reset.addingTimeInterval(5 * 3600)
        let rolled = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(60), schedules: [settled],
                blockingReset: nextWindow))
        #expect(rolled.schedules.first?.pendingMoment == nextWindow)
    }

    // MARK: - What arming recorded travels to delivery untouched

    /// The pane and the agent process are pure passthrough. The planner must
    /// decide nothing with them — delivery re-verifies them, and a planner that
    /// started reasoning about panes would be deciding *where* as well as *when*,
    /// which is the split this whole design rests on.
    @Test func theArmedPaneReachesTheFireWithoutInfluencingIt() throws {
        let target = ContinueDelivery.Target(
            surfaceId: "SURFACE-1", title: "✳ demo", terminalPid: 1419)
        let agent = ProcessIdentity(
            pid: 5150, startedAt: reset.addingTimeInterval(-9000), comm: "claude",
            pgid: 5150, tpgid: 5150, tty: "ttys006")
        var armed = schedule()
        armed.target = target
        armed.agent = agent

        let plan = ContinueScheduler.plan(pass(now: fireMoment, schedules: [armed]))
        let fire = try #require(plan.fires.first)
        #expect(fire.target == target)
        #expect(fire.agent == agent)

        // And the same pass without them decides identically.
        let bare = ContinueScheduler.plan(pass(now: fireMoment, schedules: [schedule()]))
        #expect(bare.fires.count == plan.fires.count)
        #expect(bare.fires.first?.lateness == fire.lateness)
        #expect(bare.fires.first?.delay == fire.delay)
        #expect(bare.fires.first?.target == nil)
    }

    /// Records written by the version that shipped the scheduler have no pane at
    /// all. A non-optional field would have silently dropped every one of them on
    /// decode — losing a schedule quietly is the worst outcome this feature has.
    @Test func aRecordFromBeforeDeliveryExistedStillDecodes() throws {
        let legacy = """
            {"sessionId":"s1","provider":"claude-code","message":"Continue",\
            "armedForResetAt":"2026-08-05T09:00:00Z","repeats":false,"sendsOnWake":true}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ScheduledContinue.self, from: try #require(legacy.data(using: .utf8)))
        #expect(decoded.sessionId == "s1")
        #expect(decoded.target == nil)
        #expect(decoded.agent == nil)
        #expect(decoded.message == "Continue")
    }

    // MARK: - Availability, which is what the row explains

    @Test func availabilityAlwaysGivesAReasonWhenItRefuses() {
        let resets = ["s1": reset]

        let off = ContinueScheduler.availability(
            for: session(), armableResetBySession: resets, enabled: false)
        #expect(off.reason?.contains("Settings") == true)

        // Any row is armable while the feature is on; a row that is not the
        // one waiting on a limit simply has no reset to anchor to.
        let notBlocked = ContinueScheduler.availability(
            for: session(), armableResetBySession: [:], enabled: true)
        #expect(notBlocked == .available(resetsAt: nil))
        #expect(notBlocked.reason == nil)

        let ready = ContinueScheduler.availability(
            for: session(), armableResetBySession: resets, enabled: true)
        #expect(ready == .available(resetsAt: reset))
        #expect(ready.reason == nil)
    }

    /// Regression: availability used to be keyed by *provider*. A usage limit is
    /// account-wide, so one blocked row handed the reset anchor to every Claude
    /// row — including rows that were running, or sitting at a permission
    /// prompt. Those rows are armable (everything is), but only at a moment the
    /// user picks: the reset belongs to the blocked row alone.
    @Test func onlyTheBlockedRowAnchorsToTheReset() {
        let armable = ["blocked": reset]

        let blocked = ContinueScheduler.availability(
            for: session("blocked"), armableResetBySession: armable, enabled: true)
        #expect(blocked == .available(resetsAt: reset))

        for other in ["running", "prompted", "idle"] {
            let armableToo = ContinueScheduler.availability(
                for: session(other), armableResetBySession: armable, enabled: true)
            #expect(armableToo.resetsAt == nil, "\(other) must not inherit the reset")
            #expect(armableToo.reason == nil, "\(other) must still be armable")
        }
    }

    // MARK: - Clock anchors, the user's own moments

    private func clockSchedule(
        _ id: String = "s1",
        at moment: Date,
        settledThrough: Date? = nil
    ) -> ScheduledContinue {
        ScheduledContinue(
            sessionId: id, armedForResetAt: moment,
            anchor: .clock, settledThrough: settledThrough)
    }

    /// A clock moment fires at that instant exactly. The safety pad exists
    /// because a reset reading estimates the provider's clock; a user-picked
    /// moment is exact by definition and padding it would just be late.
    @Test func aClockScheduleFiresAtItsMomentWithoutThePad() {
        let moment = reset
        let early = ContinueScheduler.plan(
            pass(now: moment.addingTimeInterval(-1), schedules: [clockSchedule(at: moment)]))
        #expect(early.fires.isEmpty)
        #expect(early.nextWakeUp == moment)

        let due = ContinueScheduler.plan(
            pass(now: moment, schedules: [clockSchedule(at: moment)]))
        #expect(due.fires.count == 1)
    }

    /// A provider reading has no business moving a moment the user picked,
    /// however close the two happen to sit.
    @Test func aClockMomentIsNeverRefinedByAnObservedReset() {
        let moment = reset
        let nearby = moment.addingTimeInterval(30)
        let planned = ContinueScheduler.plan(
            pass(
                now: moment.addingTimeInterval(-60),
                schedules: [clockSchedule(at: moment)],
                blockingReset: nearby))
        #expect(planned.schedules.first?.armedForResetAt == moment)
    }

    /// Clock schedules are one-shots: there is no observable next occurrence
    /// to re-arm against, so even a repeat flag (hand-edited, or an older
    /// build) must not resurrect one.
    @Test func aSettledClockScheduleIsDroppedEvenWithARepeatFlag() {
        var record = clockSchedule(at: reset, settledThrough: reset)
        record.repeats = true
        let planned = ContinueScheduler.plan(
            pass(
                now: reset.addingTimeInterval(600),
                schedules: [record],
                blockingReset: reset.addingTimeInterval(18_000)))
        #expect(planned.fires.isEmpty)
        #expect(planned.schedules.isEmpty)
    }

    /// R1 holds for clock anchors exactly as for resets: scheduling a running
    /// session is the whole point of a picked time, and the fire waits until
    /// the session is sitting at a finished turn.
    @Test func aClockFireHoldsWhileTheSessionIsMidTurn() {
        let moment = reset
        let held = ContinueScheduler.plan(
            pass(
                now: moment,
                schedules: [clockSchedule(at: moment)],
                sessions: [session(lastEvent: "PreToolUse")]))
        #expect(held.fires.isEmpty)
        #expect(held.schedules.count == 1)
        #expect(held.receipts.first?.summary.contains("held") == true)

        let released = ContinueScheduler.plan(
            pass(
                now: moment.addingTimeInterval(60),
                schedules: held.schedules,
                sessions: [session(lastEvent: "Stop")]))
        #expect(released.fires.count == 1)
    }

    /// Old records decode as reset-anchored: the field is absent from every
    /// schedule written before clock anchors existed.
    @Test func aRecordWithoutAnAnchorIsResetAnchored() throws {
        let old = Data(
            """
            {"sessionId": "s1", "message": "Continue",
             "armedForResetAt": 776732400, "repeats": false, "sendsOnWake": true}
            """.utf8)
        let decoded = try JSONDecoder().decode(ScheduledContinue.self, from: old)
        #expect(decoded.anchor == nil)
        #expect(!decoded.isClockAnchored)
    }
}
