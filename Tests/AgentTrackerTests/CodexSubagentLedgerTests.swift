import Foundation
import Testing

@testable import AgentTracker

/// Synthetic rollouts only — never real ~/.codex data.
final class CodexSubagentLedgerTests {
    private var tempFiles: [URL] = []

    deinit {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
    }

    /// Mirrors the real naming scheme (`rollout-<timestamp>-<uuid>.jsonl`);
    /// a unique directory keeps the fixed-uuid filenames collision-free.
    private func makeRollout(
        _ content: String, uuid: String = "019f0000-0000-7000-8000-000000000001"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-08-01T10-00-00-\(uuid).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(directory)
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
        let fileUuid = "019f0000-0000-7000-8000-00000000dead"
        let url = try makeRollout(
            metaLine(sessionId: "root", threadId: "sub-dead", source: "subagent") + "\n",
            uuid: fileUuid)
        let ledger = CodexSubagentLedger()
        ledger.harvest(path: url.path)
        // Both the meta's own id and the filename uuid (the notify join key).
        #expect(ledger.threadIds == ["sub-dead", fileUuid])

        // Same path again — memoized, the rewritten content is not re-read.
        try (metaLine(sessionId: "root", threadId: "sub-new", source: "subagent") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        ledger.harvest(path: url.path)
        #expect(ledger.threadIds == ["sub-dead", fileUuid])
    }

    @Test func harvestIgnoresUserThreads() throws {
        let url = try makeRollout(
            metaLine(sessionId: "root", threadId: "root", source: "user") + "\n")
        let ledger = CodexSubagentLedger()
        ledger.harvest(path: url.path)
        #expect(ledger.threadIds.isEmpty)
    }

    // MARK: - Real-world resume shapes (observed against codex 0.146)

    @Test func recordPrefersFileThreadIdOverLineageId() {
        // Resume metas repoint payload "id" at the fork-ancestor thread; the
        // filename uuid is the id the notify hook joins on. Both belong in
        // the ledger (the ancestor is a subagent too).
        let ledger = CodexSubagentLedger()
        let meta = CodexSessionMeta(
            sessionId: "root", threadId: "ancestor-thread", cwd: nil, isSubagent: true)
        ledger.record(meta, fileThreadId: "own-file-uuid")
        #expect(ledger.threadIds == ["ancestor-thread", "own-file-uuid"])
    }

    @Test func accumulatorKeepsSubagentMarkAcrossUserResumeMeta() {
        // Observed: a subagent thread's resume meta flips thread_source back
        // to "user". The thread is internal fan-out forever — a later meta
        // must not promote it into a session-producing primary.
        var accumulator = CodexThreadAccumulator()
        accumulator.apply(
            .sessionMeta(
                CodexSessionMeta(
                    sessionId: "root", threadId: "sub-1", cwd: nil, isSubagent: true)))
        accumulator.apply(
            .sessionMeta(
                CodexSessionMeta(sessionId: "root", threadId: nil, cwd: nil, isSubagent: false)))
        #expect(accumulator.meta?.isSubagent == true)
        #expect(accumulator.meta?.threadId == "sub-1")
    }

    @Test func accumulatorLetsLaterMetaOverrideThreadIdWhenPresent() {
        var accumulator = CodexThreadAccumulator()
        accumulator.apply(
            .sessionMeta(
                CodexSessionMeta(
                    sessionId: "root", threadId: "sub-1", cwd: nil, isSubagent: true)))
        accumulator.apply(
            .sessionMeta(
                CodexSessionMeta(
                    sessionId: "root", threadId: "ancestor", cwd: nil, isSubagent: true)))
        #expect(accumulator.meta?.threadId == "ancestor")
    }

    @Test func threadIdFromRolloutFilename() {
        let path =
            "/x/2026/08/01/rollout-2026-08-01T13-20-44-"
            + "019fbd06-faee-7002-bf14-a3c88d29921d.jsonl"
        #expect(
            CodexRolloutParser.threadId(fromRolloutFilename: path)
                == "019fbd06-faee-7002-bf14-a3c88d29921d")
        #expect(CodexRolloutParser.threadId(fromRolloutFilename: "/x/notes.jsonl") == nil)
        #expect(CodexRolloutParser.threadId(fromRolloutFilename: "rollout-short.jsonl") == nil)
    }
}
