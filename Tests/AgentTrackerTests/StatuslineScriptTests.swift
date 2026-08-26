import Foundation
import Testing

@testable import AgentTracker

/// The statusline scripts themselves, run the way Claude runs them, against a
/// scratch state directory. The renderer's output is asserted with its ANSI
/// stripped: the colours are cosmetic, the segments are the contract.
struct StatuslineScriptTests {
    private let integrations =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("integrations")

    private struct Run {
        var status: Int32
        var output: String
        var plain: String
    }

    private func run(
        script: URL, payload: Data, environment: [String: String] = [:]
    ) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { $1 })
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Run(status: process.terminationStatus, output: text, plain: stripANSI(text))
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statusline-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func payload(rateLimits: Bool = true, directory: String? = nil) -> Data {
        var object: [String: Any] = [
            "model": ["display_name": "Fable 5"],
            "effort": ["level": "high"],
            "session_id": "abc-123",
            "context_window": ["used_percentage": 42.4],
            "cost": ["total_lines_added": 12, "total_lines_removed": 3],
        ]
        if rateLimits {
            object["rate_limits"] = [
                "five_hour": ["used_percentage": 67, "resets_at": 1_787_745_600],
                "seven_day": ["used_percentage": 13, "resets_at": 1_787_918_400],
            ]
        }
        if let directory {
            object["workspace"] = ["current_dir": directory]
        }
        // swiftlint:disable:next force_try — fixture construction, not code under test
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - The renderer

    @Test func rendersEverySegmentOfAFullPayload() throws {
        let render = integrations.appendingPathComponent("agent-tracker-statusline-render.py")
        let result = try run(script: render, payload: payload())
        #expect(result.status == 0)
        let line1 = result.plain.split(separator: "\n").first.map(String.init) ?? ""
        #expect(line1.contains("Fable 5"))
        #expect(line1.contains("effort: high"))
        #expect(line1.contains("ctx: 42%"))
        #expect(line1.contains("5h: 67%"))
        #expect(line1.contains("7d: 13%"))
        #expect(line1.contains("abc-123"))
        #expect(result.plain.contains("+12 -3"))
    }

    /// Absent windows are absent segments — never zeros, for the same reason
    /// the app drops them from the dropdown strip.
    @Test func missingRateLimitsRenderNoUsageSegments() throws {
        let render = integrations.appendingPathComponent("agent-tracker-statusline-render.py")
        let result = try run(script: render, payload: payload(rateLimits: false))
        #expect(result.status == 0)
        #expect(result.plain.contains("5h:") == false)
        #expect(result.plain.contains("7d:") == false)
        #expect(result.plain.contains("ctx: 42%"))
    }

    @Test func malformedPayloadRendersNothingAndStillExitsZero() throws {
        let render = integrations.appendingPathComponent("agent-tracker-statusline-render.py")
        let result = try run(script: render, payload: Data("not json".utf8))
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test func aGitDirectoryShowsItsBranchAndDirtyMark() throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-c", "init.defaultBranch=main", "init", "-q", repo.path]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        try Data("wip".utf8).write(to: repo.appendingPathComponent("file.txt"))

        let render = integrations.appendingPathComponent("agent-tracker-statusline-render.py")
        let result = try run(script: render, payload: payload(directory: repo.path))
        #expect(result.plain.contains("main"))
        #expect(result.plain.contains("✱"))
    }

    // MARK: - The wrapper's display choice

    private func record(_ object: [String: Any], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent("claude-statusline-wrapped.json"))
    }

    @Test func builtinDisplayBecomesTheRenderer() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }
        try record(["schema": 1, "wrapped": NSNull(), "display": "builtin"], in: state)

        let wrapper = integrations.appendingPathComponent("agent-tracker-statusline.py")
        let result = try run(
            script: wrapper, payload: payload(),
            environment: ["AGENT_TRACKER_DIR": state.path])
        #expect(result.status == 0)
        #expect(result.plain.contains("Fable 5"))
        #expect(result.plain.contains("5h: 67%"))
        // Capturing must happen before any display does.
        let capture = state.appendingPathComponent("claude-statusline.json")
        #expect(FileManager.default.fileExists(atPath: capture.path))
    }

    @Test func withoutTheDisplayKeyTheWrappedCommandStillRuns() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }
        try record(
            ["schema": 1, "wrapped": ["type": "command", "command": "echo their-own-line"]],
            in: state)

        let wrapper = integrations.appendingPathComponent("agent-tracker-statusline.py")
        let result = try run(
            script: wrapper, payload: payload(),
            environment: ["AGENT_TRACKER_DIR": state.path])
        #expect(result.status == 0)
        #expect(result.plain.contains("their-own-line"))
    }

    /// A wrapper copied without its renderer (a partial or older install)
    /// falls back to the displaced command rather than to a blank line.
    @Test func aMissingRendererFallsBackToTheWrappedCommand() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }
        // The wrapper resolves the renderer beside itself, so run a lone copy.
        let loneWrapper = state.appendingPathComponent("agent-tracker-statusline.py")
        try FileManager.default.copyItem(
            at: integrations.appendingPathComponent("agent-tracker-statusline.py"),
            to: loneWrapper)
        try record(
            [
                "schema": 1, "display": "builtin",
                "wrapped": ["type": "command", "command": "echo fallback-line"],
            ],
            in: state)

        let result = try run(
            script: loneWrapper, payload: payload(),
            environment: ["AGENT_TRACKER_DIR": state.path])
        #expect(result.status == 0)
        #expect(result.plain.contains("fallback-line"))
    }
}
