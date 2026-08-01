import Foundation
import Testing

@testable import AgentTracker

/// Synthetic rollouts only — never real ~/.codex data.
final class CodexSubagentLedgerTests {
    private var tempFiles: [URL] = []

    deinit {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
    }

    private func makeRollout(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return url
    }

    private func metaLine(
        sessionId: String, threadId: String, source: String, padding: Int = 0
    ) -> String {
        let pad = String(repeating: "x", count: padding)
        return """
            {"timestamp":"2026-08-01T10:00:00.000Z","type":"session_meta","payload":\
            {"session_id":"\(sessionId)","id":"\(threadId)","cwd":"/tmp/planner",\
            "thread_source":"\(source)","base_instructions":{"text":"\(pad)"}}}
            """
    }

    // MARK: - firstSessionMeta

    @Test func firstSessionMetaParsesLargeLeadingLine() throws {
        // Real meta lines carry the full base instructions (tens of KB).
        let content =
            metaLine(sessionId: "root", threadId: "sub-1", source: "subagent", padding: 40_000)
            + "\n" + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        let url = try makeRollout(content)
        let meta = CodexRolloutParser.firstSessionMeta(atPath: url.path)
        #expect(meta?.sessionId == "root")
        #expect(meta?.threadId == "sub-1")
        #expect(meta?.isSubagent == true)
    }

    @Test func firstSessionMetaDegradesToNil() throws {
        let empty = try makeRollout("")
        #expect(CodexRolloutParser.firstSessionMeta(atPath: empty.path) == nil)

        // No trailing newline: the first line may still be mid-write.
        let unterminated = try makeRollout(
            metaLine(sessionId: "root", threadId: "t", source: "user"))
        #expect(CodexRolloutParser.firstSessionMeta(atPath: unterminated.path) == nil)

        let nonMeta = try makeRollout(
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n")
        #expect(CodexRolloutParser.firstSessionMeta(atPath: nonMeta.path) == nil)

        #expect(CodexRolloutParser.firstSessionMeta(atPath: "/nonexistent/rollout.jsonl") == nil)
    }

    // MARK: - Ledger

    @Test func recordKeepsOnlySubagentThreadIds() {
        let ledger = CodexSubagentLedger()
        ledger.record(
            CodexSessionMeta(sessionId: "root", threadId: "root", cwd: nil, isSubagent: false))
        ledger.record(
            CodexSessionMeta(sessionId: "root", threadId: "sub-1", cwd: nil, isSubagent: true))
        ledger.record(
            CodexSessionMeta(sessionId: "root", threadId: nil, cwd: nil, isSubagent: true))
        #expect(ledger.threadIds == ["sub-1"])
    }

    @Test func recordedIdsSurviveUnrelatedUpdates() {
        // The whole point of the ledger: the id must outlive the tracker that
        // discovered it (subagent rollouts close and get pruned quickly).
        let ledger = CodexSubagentLedger()
        ledger.record(
            CodexSessionMeta(sessionId: "root", threadId: "sub-1", cwd: nil, isSubagent: true))
        ledger.record(
            CodexSessionMeta(sessionId: "other", threadId: "other", cwd: nil, isSubagent: false))
        #expect(ledger.threadIds.contains("sub-1"))
    }

    @Test func harvestReadsEachPathOnce() throws {
        let url = try makeRollout(
            metaLine(sessionId: "root", threadId: "sub-dead", source: "subagent") + "\n")
        let ledger = CodexSubagentLedger()
        ledger.harvest(path: url.path)
        #expect(ledger.threadIds == ["sub-dead"])

        // Same path again — memoized, the rewritten content is not re-read.
        try (metaLine(sessionId: "root", threadId: "sub-new", source: "subagent") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        ledger.harvest(path: url.path)
        #expect(ledger.threadIds == ["sub-dead"])
    }

    @Test func harvestIgnoresUserThreads() throws {
        let url = try makeRollout(
            metaLine(sessionId: "root", threadId: "root", source: "user") + "\n")
        let ledger = CodexSubagentLedger()
        ledger.harvest(path: url.path)
        #expect(ledger.threadIds.isEmpty)
    }
}
