import Foundation
import Testing

@testable import AgentTracker

@MainActor
final class ClaudeUsageWatcherTests {
    private var directories: [URL] = []

    deinit {
        for url in directories { try? FileManager.default.removeItem(at: url) }
    }

    private func transcript(_ lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("transcript.jsonl")
        try lines.map { $0 + "\n" }.joined().data(using: .utf8)!.write(to: url)
        return url
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: (line + "\n").data(using: .utf8)!)
    }

    private var refusalLine: String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-08-03T20:09:01.055Z",
            "error": "rate_limit",
            "isApiErrorMessage": true,
            "apiErrorStatus": 429,
            "message": [
                "content": [
                    ["type": "text", "text": "You've hit your session limit · resets 1:20am (UTC)"]
                ]
            ],
        ]
        return jsonLine(object)
    }

    private func filler(_ index: Int) -> String {
        let object: [String: Any] = [
            "type": "assistant", "timestamp": "2026-08-03T10:00:00.000Z",
            "message": ["content": [["type": "text", "text": String(repeating: "x", count: 400)]]],
            "seq": index,
        ]
        return jsonLine(object)
    }

    /// Non-throwing fixture builder: a failed encode yields an empty line, which
    /// parses as nothing and fails the test visibly.
    private func jsonLine(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func session(_ url: URL, id: String = "s1") -> AgentSession {
        var session = AgentSession(
            provider: "claude-code", sessionId: id, cwd: "/Users/dev/demo", state: .needsYou)
        session.transcriptPath = url.path
        return session
    }

    /// A session that is blocked *right now* stopped writing the moment it was
    /// refused, which puts the marker at EOF — so the bounded first look finds
    /// exactly the case that matters.
    @Test func aRefusalAtTheEndIsFoundOnFirstSight() throws {
        let url = try transcript((0..<20).map(filler) + [refusalLine])
        let watcher = ClaudeUsageWatcher()
        let found = watcher.check([session(url)])
        #expect(found.count == 1)
        #expect(found.first?.window == .fiveHour)
    }

    /// The measured constraint, as a test: of 92 real transcripts holding a
    /// marker, only 13 had it within 64 KiB of EOF and the deepest was 36 MB in.
    /// Those belong to windows that reset days ago, so finding them would be a
    /// bug — the app would announce a block that ended long before.
    @Test func aHistoricalRefusalBuriedInTheFileIsIgnored() throws {
        // 64 KiB of filler after the refusal pushes it out of the first-sight
        // window; each filler line is ~500 bytes.
        let buried = [refusalLine] + (0..<400).map(filler)
        let url = try transcript(buried)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? 0) > ClaudeUsageWatcher.firstSightWindow)

        let watcher = ClaudeUsageWatcher()
        #expect(watcher.check([session(url)]).isEmpty)
    }

    /// The trigger case: the app is already watching when the wall is hit.
    @Test func aRefusalAppendedLaterIsFound() throws {
        let url = try transcript((0..<5).map(filler))
        let watcher = ClaudeUsageWatcher()
        #expect(watcher.check([session(url)]).isEmpty)

        try append(refusalLine, to: url)
        #expect(watcher.check([session(url)]).count == 1)
    }

    /// Reading the same refusal on every reload would re-announce a limit
    /// forever, and the offset is what stops it.
    @Test func nothingNewMeansNothingFound() throws {
        let url = try transcript((0..<5).map(filler) + [refusalLine])
        let watcher = ClaudeUsageWatcher()
        #expect(watcher.check([session(url)]).count == 1)
        #expect(watcher.check([session(url)]).isEmpty)
        #expect(watcher.check([session(url)]).isEmpty)
    }

    /// A resumed session can be written to a fresh file; seeking to a stale
    /// offset past its end would read nothing forever.
    @Test func aReplacedTranscriptStartsOver() throws {
        let first = try transcript((0..<40).map(filler) + [refusalLine])
        let watcher = ClaudeUsageWatcher()
        #expect(watcher.check([session(first)]).count == 1)

        let second = try transcript([refusalLine])
        #expect(watcher.check([session(second)]).count == 1)
    }

    @Test func sessionsWithoutATranscriptOrProviderAreSkipped() throws {
        let url = try transcript([refusalLine])
        let watcher = ClaudeUsageWatcher()

        var codex = session(url, id: "codex-1")
        codex.provider = "codex"
        #expect(watcher.check([codex]).isEmpty)

        var pathless = session(url, id: "s2")
        pathless.transcriptPath = nil
        #expect(watcher.check([pathless]).isEmpty)

        var missing = session(url, id: "s3")
        missing.transcriptPath = "/nonexistent/transcript.jsonl"
        #expect(watcher.check([missing]).isEmpty)
    }

    /// Offsets must not outlive their sessions, or a recycled id would resume at
    /// a stranger's byte position.
    @Test func pruningForgetsSessionsThatAreGone() throws {
        let url = try transcript((0..<40).map(filler) + [refusalLine])
        let watcher = ClaudeUsageWatcher()
        #expect(watcher.check([session(url)]).count == 1)
        #expect(watcher.check([session(url)]).isEmpty)

        watcher.prune(liveSessionIds: [])
        // Forgotten, so the same file reads as first sight again.
        #expect(watcher.check([session(url)]).count == 1)
    }
}
