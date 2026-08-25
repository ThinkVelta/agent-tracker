import Foundation
import Testing

@testable import AgentTracker

/// The hook script itself, run the way Claude runs it, against a scratch
/// state directory. Only the parts this app reads back are asserted.
struct HookScriptTests {
    private let script =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("integrations/agent-tracker-hook.py").path

    private func run(_ payload: [String: Any], in directory: URL) throws {
        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        hook.arguments = ["python3", script, "claude"]
        hook.environment = ProcessInfo.processInfo.environment.merging(
            ["AGENT_TRACKER_DIR": directory.path], uniquingKeysWith: { $1 })
        let input = Pipe()
        hook.standardInput = input
        hook.standardOutput = FileHandle.nullDevice
        try hook.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        hook.waitUntilExit()
        #expect(hook.terminationStatus == 0)
    }

    private func stateFile(in directory: URL) -> URL {
        directory.appendingPathComponent("sessions/claude-code-s1.json")
    }

    private func load(_ directory: URL) throws -> AgentSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            AgentSession.self, from: Data(contentsOf: stateFile(in: directory)))
    }

    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return directory
    }

    private func stop(tasks: Any?) -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1"]
        if let tasks { payload["background_tasks"] = tasks }
        return payload
    }

    @Test func aStopRecordsTheShellsStillRunning() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(
            stop(tasks: [
                [
                    "id": "b1", "type": "shell", "status": "running",
                    "description": "Wait for CI", "command": "until gh run view; do sleep 15; done",
                ],
                ["id": "a1", "type": "subagent", "status": "running"],
            ]), in: directory)
        let session = try load(directory)
        #expect(session.state == .needsYou)
        #expect(session.backgroundTasks?.map(\.id) == ["b1"])
        #expect(session.backgroundTasks?.first?.description == "Wait for CI")
        #expect(session.backgroundTasks?.first?.firstSeenAt != nil)
    }

    /// The age of a shell is the age of its first sighting. A later Stop that
    /// still lists it must keep that moment, and one that no longer lists it
    /// must drop it.
    @Test func aFirstSightingSurvivesLaterStops() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier: [String: Any] = [
            "sessionId": "s1", "state": "running",
            "backgroundTasks": [
                ["id": "b1", "type": "shell", "firstSeenAt": "2026-08-25T15:03:00Z"]
            ],
        ]
        try JSONSerialization.data(withJSONObject: earlier).write(to: stateFile(in: directory))
        try run(
            stop(tasks: [
                ["id": "b1", "type": "shell"], ["id": "b2", "type": "monitor"],
            ]), in: directory)
        let kept = try load(directory)
        #expect(
            kept.backgroundTasks?.first { $0.id == "b1" }?.firstSeenAt
                == Timestamps.iso8601("2026-08-25T15:03:00Z"))
        #expect(kept.backgroundTasks?.map(\.id) == ["b1", "b2"])

        try run(stop(tasks: [["id": "b2", "type": "monitor"]]), in: directory)
        #expect(try load(directory).backgroundTasks?.map(\.id) == ["b2"])
        try run(stop(tasks: []), in: directory)
        #expect(try load(directory).backgroundTasks == [])
    }

    /// An older Claude sends no such field, and other events never do. Both
    /// must read as "unknown" and leave the recorded shells alone.
    @Test func eventsWithoutTheFieldLeaveTheRecordAlone() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(stop(tasks: [["id": "b1", "type": "shell"]]), in: directory)
        try run(
            ["hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash"],
            in: directory)
        #expect(try load(directory).backgroundTasks?.map(\.id) == ["b1"])
        try run(stop(tasks: nil), in: directory)
        #expect(try load(directory).backgroundTasks?.map(\.id) == ["b1"])
        try run(stop(tasks: "garbage"), in: directory)
        #expect(try load(directory).backgroundTasks?.map(\.id) == ["b1"])
    }
}
