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
        provider: String = "claude-code",
        lastEvent: String? = "Stop",
        origin: String? = "hook"
    ) -> AgentSession {
        var session = AgentSession(
            provider: provider, sessionId: id, cwd: "/Users/dev/demo", state: .needsYou)
        session.lastEvent = lastEvent
        session.origin = origin
        return session
    }

    private func schedule(
        _ id: String = "s1",
        provider: String = "claude-code",
        repeats: Bool = false,
        sendsOnWake: Bool = true,
        settledThrough: Date? = nil,
        resetsAt: Date? = nil
    ) -> ScheduledContinue {
        ScheduledContinue(
            sessionId: id, provider: provider, armedForResetAt: resetsAt ?? reset,
            repeats: repeats, sendsOnWake: sendsOnWake, settledThrough: settledThrough)
    }

    private func pass(
        now: Date,
        slept: TimeInterval = 0,
        launchedAt: Date? = nil,
        enabled: Bool = true,
        schedules: [ScheduledContinue],
        sessions: [AgentSession]? = nil,
        blockingResets: [String: Date] = [:]
    ) -> ContinueScheduler.Pass {
        ContinueScheduler.Pass(
            now: now,
            sleptSinceLastPass: slept,
            launchedAt: launchedAt ?? launch,
            enabled: enabled,
            schedules: schedules,
            sessions: sessions ?? [session()],
            blockingResets: blockingResets)
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
                blockingResets: ["claude-code": reset.addingTimeInterval(90)]))
        #expect(sameWindow.fires.isEmpty)
        #expect(sameWindow.schedules.first?.armedForResetAt == reset)
        #expect(sameWindow.receipts.isEmpty)

        let nextWindow = reset.addingTimeInterval(5 * 3600)
        let rolled = ContinueScheduler.plan(
            pass(
                now: fireMoment.addingTimeInterval(60), schedules: [settled],
                blockingResets: ["claude-code": nextWindow]))
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
                blockingResets: ["claude-code": later]))
        #expect(refined.schedules.first?.armedForResetAt == later)

        let earlier = ContinueScheduler.plan(
            pass(
                now: reset.addingTimeInterval(-600), schedules: [schedule()],
                blockingResets: ["claude-code": reset.addingTimeInterval(-45)]))
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
                now: fireMoment, schedules: [schedule("c1", provider: "codex")],
                sessions: [session("c1", provider: "codex")]))
        #expect(plan.fires.count == 1)
        #expect(plan.fires.first?.sessionId == "c1")
    }

    /// A provider whose turn state the app cannot read is still refused, and the
    /// refusal still names it. The gate moved from one literal to a set; it did
    /// not go away.
    @Test func anUnknownProviderIsStillRefused() {
        let plan = ContinueScheduler.plan(
            pass(
                now: fireMoment, schedules: [schedule("k1", provider: "kimi")],
                sessions: [session("k1", provider: "kimi")]))
        #expect(plan.fires.isEmpty)
        #expect(plan.schedules.isEmpty)
        #expect(plan.receipts.first?.summary.contains("cannot be resumed automatically") == true)
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
                sessionId: "s", provider: "claude-code", message: "a\nb", armedForResetAt: reset
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
                blockingResets: ["claude-code": nextWindow]))
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

        let unknown = ContinueScheduler.availability(
            for: session("k", provider: "kimi"), armableResetBySession: ["k": reset], enabled: true
        )
        #expect(unknown.reason?.contains("cannot be resumed automatically") == true)

        let codex = ContinueScheduler.availability(
            for: session("c", provider: "codex"), armableResetBySession: ["c": reset], enabled: true
        )
        #expect(codex == .available(resetsAt: reset))

        // A Codex row the rollout scanner produced can never satisfy R1, so
        // offering the clock would promise a send that is held every pass and
        // then abandoned. Refused while there is still someone reading.
        let scannerOnly = ContinueScheduler.availability(
            for: session("c2", provider: "codex", lastEvent: "task_complete", origin: nil),
            armableResetBySession: ["c2": reset], enabled: true)
        #expect(scannerOnly.reason?.contains("hook review prompt") == true)

        // Claude has no hookless row to refuse — a Claude row exists because a
        // hook wrote it — so the same absence must not lock Claude out.
        let claudeWithoutOrigin = ContinueScheduler.availability(
            for: session(origin: nil), armableResetBySession: resets, enabled: true)
        #expect(claudeWithoutOrigin == .available(resetsAt: reset))

        let notBlocked = ContinueScheduler.availability(
            for: session(), armableResetBySession: [:], enabled: true)
        #expect(notBlocked.reason?.contains("waiting on a usage limit") == true)

        let ready = ContinueScheduler.availability(
            for: session(), armableResetBySession: resets, enabled: true)
        #expect(ready == .available(resetsAt: reset))
        #expect(ready.reason == nil)
    }

    /// Regression: availability used to be keyed by *provider*. A usage limit is
    /// account-wide, so one blocked row made every Claude row offer the clock —
    /// including rows that were running, or sitting at a permission prompt.
    @Test func onlyTheBlockedRowIsArmableNotEveryRowOnThatAccount() {
        let armable = ["blocked": reset]

        let blocked = ContinueScheduler.availability(
            for: session("blocked"), armableResetBySession: armable, enabled: true)
        #expect(blocked == .available(resetsAt: reset))

        // Same provider, same account, same reset — but this row is not the one
        // waiting on it.
        for other in ["running", "prompted", "idle"] {
            let unavailable = ContinueScheduler.availability(
                for: session(other), armableResetBySession: armable, enabled: true)
            #expect(unavailable.resetsAt == nil, "\(other) must not be armable")
            #expect(unavailable.reason?.contains("waiting on a usage limit") == true)
        }
    }
}
