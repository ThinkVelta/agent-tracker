import Foundation
import Testing

@testable import AgentTracker

/// The write path, with the writes faked so the **call sequence** is what gets
/// asserted. Nothing here can reach a terminal.
///
/// The property that matters most is an ordering property, not a value: Return
/// must be unreachable unless the text write already succeeded. That cannot be
/// tested by inspecting a result, only by watching what was called.
final class ContinueSenderTests {
    /// Records what delivery asked the channel to do, in order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []

        func note(_ call: String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(call)
        }

        var sequence: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private let surfaceId = "DA10160F-6992-4EDC-89F3-7084841E9C52"
    private let ghosttyPid: Int32 = 1419

    private var armedTarget: ContinueDelivery.Target {
        ContinueDelivery.Target(surfaceId: surfaceId, title: "✳ demo", terminalPid: ghosttyPid)
    }

    private var liveSurfaces: [ContinueDelivery.Surface] {
        [ContinueDelivery.Surface(id: surfaceId, title: "✳ demo", workingDirectory: "/Users/dev")]
    }

    private func agent(pgid: Int32 = 5150, tpgid: Int32 = 5150, comm: String = "claude")
        -> ProcessIdentity
    {
        ProcessIdentity(
            pid: 5150, startedAt: Date(timeIntervalSince1970: 1_785_900_000), comm: comm,
            pgid: pgid, tpgid: tpgid, tty: "ttys006")
    }

    private func fire(target: ContinueDelivery.Target? = nil, agent armed: ProcessIdentity? = nil)
        -> ContinueScheduler.Fire
    {
        ContinueScheduler.Fire(
            sessionId: "s1", message: "Continue", delay: 0, lateness: .onTime,
            target: target ?? armedTarget, agent: armed ?? agent())
    }

    private func context(
        enabled: Bool = true, lastEvent: String? = "Stop", mode: String? = nil,
        live: ProcessIdentity? = nil
    ) -> SendContext {
        SendContext(
            enabled: enabled, lastEvent: lastEvent, permissionMode: mode,
            liveAgent: live ?? agent())
    }

    private func ops(
        recorder: Recorder, writeSucceeds: Bool = true, returnSucceeds: Bool = true,
        surfaces: [ContinueDelivery.Surface]? = nil, pid: Int32? = nil
    ) -> ChannelOps {
        let live = surfaces ?? liveSurfaces
        let terminal = pid ?? ghosttyPid
        return ChannelOps(
            terminalPid: {
                recorder.note("terminalPid")
                return terminal
            },
            surfaces: { addressed in
                // Every step must address the SAME process the verification used,
                // so the fake records the pid it was handed.
                recorder.note("surfaces@\(addressed)")
                return .success(live)
            },
            writeText: { _, _, addressed in
                recorder.note("writeText@\(addressed)")
                return writeSucceeds
            },
            pressReturn: { _, addressed in
                recorder.note("pressReturn@\(addressed)")
                return returnSucceeds
            })
    }

    // MARK: - The ordering property

    @Test func theHappyPathWritesThenPressesReturn() {
        let recorder = Recorder()
        let result = ContinueSender.send(fire(), context: context(), ops: ops(recorder: recorder))
        #expect(result.outcome == .sent)
        #expect(
            recorder.sequence == [
                "terminalPid", "surfaces@\(ghosttyPid)", "writeText@\(ghosttyPid)",
                "pressReturn@\(ghosttyPid)",
            ])
    }

    /// The one that would be unrecoverable: Return submits whatever is on the
    /// prompt, so pressing it after a failed write would send someone else's
    /// half-typed line.
    @Test func returnIsNeverPressedIfTheTextDidNotLand() {
        let recorder = Recorder()
        let result = ContinueSender.send(
            fire(), context: context(), ops: ops(recorder: recorder, writeSucceeds: false))
        #expect(result.outcome == .failed)
        #expect(recorder.sequence.contains { $0.hasPrefix("writeText") })
        #expect(recorder.sequence.contains { $0.hasPrefix("pressReturn") } == false)
    }

    /// Typed but not submitted is its own outcome. Reporting it as a plain
    /// failure would be wrong in the other direction: something IS sitting on
    /// that prompt and the user needs to know.
    @Test func aFailedReturnSaysTheMessageIsWaitingOnThePrompt() {
        let result = ContinueSender.send(
            fire(), context: context(),
            ops: ops(recorder: Recorder(), returnSucceeds: false))
        #expect(result.outcome == .failed)
        #expect(result.detail.contains("waiting on"))
        #expect(result.detail.contains("Continue"))
    }

    /// Every refusal must happen before anything is written — proven by the
    /// channel never being asked to write at all.
    @Test func everyRefusalHappensBeforeAnythingIsWritten() {
        let cases: [(String, SendContext, ContinueScheduler.Fire)] = [
            ("kill switch off", context(enabled: false), fire()),
            ("not at a finished turn", context(lastEvent: "Notification"), fire()),
            ("state unknown", context(lastEvent: nil), fire()),
            ("unknown permission mode", context(mode: "yoloMode"), fire()),
            ("agent gone", context(live: agent(pgid: 0, tpgid: 0)), fire()),
            (
                "not the foreground program",
                context(live: agent(pgid: 5150, tpgid: 6001, comm: "vim")), fire()
            ),
        ]
        for (label, sendContext, request) in cases {
            let recorder = Recorder()
            let result = ContinueSender.send(
                request, context: sendContext, ops: ops(recorder: recorder))
            #expect(result.outcome == .refused, "\(label) should refuse")
            #expect(result.detail.isEmpty == false, "\(label) gave no reason")
            #expect(
                recorder.sequence.contains { $0.hasPrefix("writeText") } == false,
                "\(label) wrote anyway")
            #expect(
                recorder.sequence.contains { $0.hasPrefix("pressReturn") } == false,
                "\(label) pressed Return")
        }
    }

    /// Regression: each channel call used to rediscover Ghostty for itself, so
    /// verification could pass against one instance while the write landed in
    /// another — the type-into-a-stranger's-pane failure this design exists to
    /// prevent. One sample is taken per delivery and threaded through everything.
    @Test func everyCallAddressesTheSameProcessSample() {
        let recorder = Recorder()
        _ = ContinueSender.send(fire(), context: context(), ops: ops(recorder: recorder))
        let addressed = recorder.sequence.compactMap { call -> String? in
            guard let marker = call.range(of: "@") else { return nil }
            return String(call[marker.upperBound...])
        }
        #expect(addressed.isEmpty == false)
        #expect(Set(addressed).count == 1, "calls addressed different processes: \(addressed)")
        #expect(addressed.allSatisfy { $0 == "\(ghosttyPid)" })
    }

    // MARK: - Identity, re-checked at write time

    @Test func aScheduleWithNoRecordedPaneRefuses() {
        let recorder = Recorder()
        let bare = ContinueScheduler.Fire(
            sessionId: "s1", message: "Continue", delay: 0, lateness: .onTime, target: nil,
            agent: nil)
        let result = ContinueSender.send(bare, context: context(), ops: ops(recorder: recorder))
        #expect(result.outcome == .refused)
        #expect(recorder.sequence.contains { $0.hasPrefix("writeText") } == false)
    }

    @Test func aClosedOrReusedWindowRefuses() {
        // Closed: the recorded id is not among the live surfaces.
        let closed = ContinueSender.send(
            fire(), context: context(),
            ops: ops(recorder: Recorder(), surfaces: []))
        #expect(closed.outcome == .refused)

        // Reused: same id, different session showing in it.
        let reused = [
            ContinueDelivery.Surface(
                id: surfaceId, title: "✳ something else", workingDirectory: "/Users/dev")
        ]
        let taken = ContinueSender.send(
            fire(), context: context(), ops: ops(recorder: Recorder(), surfaces: reused))
        #expect(taken.outcome == .refused)
    }

    /// A restarted Ghostty reissues surface ids, so the recorded one can resolve
    /// to a stranger's pane.
    @Test func aRestartedTerminalRefuses() {
        let result = ContinueSender.send(
            fire(), context: context(),
            ops: ops(recorder: Recorder(), pid: ghosttyPid + 1))
        #expect(result.outcome == .refused)
        #expect(result.detail.contains("restarted"))
    }

    /// pid reuse over a twelve-hour window is real, and `kill(pid, 0)` cannot see
    /// it — the start time can.
    @Test func aRecycledPidRefuses() {
        var recycled = agent()
        recycled.startedAt = agent().startedAt.addingTimeInterval(3600)
        let result = ContinueSender.send(
            fire(), context: context(live: recycled), ops: ops(recorder: Recorder()))
        #expect(result.outcome == .refused)
        #expect(result.detail.contains("different process"))
    }

    /// Every known mode is allowed, bypass included — Ruben's call. Only an
    /// unrecognised one refuses.
    @Test func knownPermissionModesAllSend() {
        for mode in ["auto", "default", "acceptEdits", "plan", "bypassPermissions", "dontAsk"] {
            let result = ContinueSender.send(
                fire(), context: context(mode: mode), ops: ops(recorder: Recorder()))
            #expect(result.outcome == .sent, "\(mode) should send")
        }
    }

    // MARK: - Reading the mode back out of a transcript

    @Test func theLastPermissionModeInATranscriptWins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sender-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("t.jsonl")

        let lines = [
            #"{"type":"permission-mode","permissionMode":"default"}"#,
            #"{"type":"user","message":{"content":"hello"}}"#,
            #"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
            #"{"type":"assistant","message":{"content":"hi"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        #expect(
            ContinueSender.permissionMode(inTranscriptAt: transcript.path) == "bypassPermissions")

        // A transcript that never records one is "not set", not "unknown" — most
        // sessions never write the field at all.
        let quiet = directory.appendingPathComponent("quiet.jsonl")
        try #"{"type":"user"}"#.write(to: quiet, atomically: true, encoding: .utf8)
        #expect(ContinueSender.permissionMode(inTranscriptAt: quiet.path) == nil)
        #expect(ContinueSender.permissionMode(inTranscriptAt: "/nonexistent") == nil)
    }
}
