import Foundation
import Testing

@testable import AgentTracker

/// All fixtures are synthetic — shaped like Codex rollout lines but never
/// sourced from real ~/.codex data.
final class CodexRolloutTests {
    private var tempDirectories: [URL] = []

    deinit {
        for url in tempDirectories { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Fixture builders

    private func jsonLine(_ object: [String: Any]) -> String {
        // Non-throwing fixture builder: a failed encode yields an empty line,
        // which parses as insignificant and fails the test visibly.
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8)!
    }

    private func metaLine(
        sessionId: String = "sess-1",
        threadId: String = "thread-1",
        cwd: String? = "/tmp/project",
        subagent: Bool = false,
        timestamp: String = "2026-07-31T10:00:00.000Z"
    ) -> String {
        var payload: [String: Any] = [
            "session_id": sessionId,
            "id": threadId,
            "originator": "codex-tui",
        ]
        if let cwd { payload["cwd"] = cwd }
        if subagent {
            payload["thread_source"] = "subagent"
            payload["agent_nickname"] = "explorer"
        }
        return jsonLine(["timestamp": timestamp, "type": "session_meta", "payload": payload])
    }

    private func eventLine(
        _ eventType: String,
        timestamp: String = "2026-07-31T10:01:00.000Z",
        extra: [String: Any] = [:]
    ) -> String {
        var payload: [String: Any] = ["type": eventType, "turn_id": "turn-1"]
        payload.merge(extra) { _, new in new }
        return jsonLine(["timestamp": timestamp, "type": "event_msg", "payload": payload])
    }

    private func fillerLine(index: Int) -> String {
        eventLine(
            "agent_reasoning", extra: ["text": String(repeating: "x", count: 180) + "\(index)"])
    }

    private func date(_ string: String) -> Date {
        CodexRolloutParser.parseDate(string)!
    }

    private func makeTempFile(lines: [String], trailing: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let url = directory.appendingPathComponent("rollout-fixture.jsonl")
        var contents = lines.map { $0 + "\n" }.joined()
        if let trailing { contents += trailing }
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.size] as? NSNumber).uint64Value
    }

    private func snapshot(
        _ accumulator: CodexThreadAccumulator,
        fileActivityAt: Date? = nil,
        holderPid: Int? = nil
    ) -> CodexThreadSnapshot {
        CodexThreadSnapshot(
            accumulator: accumulator, fileActivityAt: fileActivityAt, holderPid: holderPid
        )
    }

    // MARK: - Meta parsing

    @Test func parsesSessionMeta() {
        let line = metaLine(sessionId: "S1", threadId: "T1", cwd: "/work/dir")
        guard case .sessionMeta(let meta) = CodexRolloutParser.parseLine(line) else {
            Issue.record("expected sessionMeta")
            return
        }
        #expect(meta.sessionId == "S1")
        #expect(meta.threadId == "T1")
        #expect(meta.cwd == "/work/dir")
        #expect(!meta.isSubagent)
        #expect(meta.timestamp == date("2026-07-31T10:00:00.000Z"))
    }

    @Test func parsesSubagentFlagOnlyForExactValue() {
        guard
            case .sessionMeta(let subagent) = CodexRolloutParser.parseLine(
                metaLine(subagent: true)
            )
        else {
            Issue.record("expected sessionMeta")
            return
        }
        #expect(subagent.isSubagent)

        // Any other thread_source value is NOT a subagent.
        let object: [String: Any] = [
            "timestamp": "2026-07-31T10:00:00.000Z",
            "type": "session_meta",
            "payload": ["session_id": "S1", "id": "T1", "thread_source": "resume"],
        ]
        guard case .sessionMeta(let other) = CodexRolloutParser.parseLine(jsonLine(object)) else {
            Issue.record("expected sessionMeta")
            return
        }
        #expect(!other.isSubagent)
    }

    @Test func multipleMetasLaterWins() {
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: metaLine(sessionId: "S1", threadId: "T1", cwd: "/old"))
        accumulator.consume(
            line: metaLine(
                sessionId: "S1", threadId: "T1", cwd: "/new", timestamp: "2026-07-31T11:00:00.000Z"
            ))
        #expect(accumulator.meta?.cwd == "/new")
        #expect(accumulator.meta?.timestamp == date("2026-07-31T11:00:00.000Z"))
    }

    // MARK: - State transitions

    @Test func noSignificantEventIsSessionOpen() {
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: metaLine())
        #expect(accumulator.derivedState.state == .idle)
        #expect(accumulator.derivedState.reason == "Session open")
    }

    @Test func taskStartedIsRunning() {
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: metaLine())
        accumulator.consume(line: eventLine("task_started"))
        #expect(accumulator.derivedState.state == .running)
        #expect(accumulator.derivedState.reason == "Working…")
        #expect(accumulator.lastSignificant?.timestamp == date("2026-07-31T10:01:00.000Z"))
    }

    @Test func taskCompleteIsNeedsYou() {
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: eventLine("task_started"))
        accumulator.consume(
            line: eventLine(
                "task_complete",
                timestamp: "2026-07-31T10:05:00.000Z",
                extra: ["last_agent_message": "All done"]
            ))
        #expect(accumulator.derivedState.state == .needsYou)
        #expect(accumulator.derivedState.reason == "Turn complete — ready for you")
        #expect(accumulator.lastAgentMessage == "All done")
    }

    @Test func turnAbortedIsInterrupted() {
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: eventLine("task_started"))
        accumulator.consume(
            line: eventLine(
                "turn_aborted", timestamp: "2026-07-31T10:02:00.000Z",
                extra: ["reason": "interrupted"]
            ))
        #expect(accumulator.derivedState.state == .needsYou)
        #expect(accumulator.derivedState.reason == "Interrupted — ready for you")
    }

    // MARK: - Unknown-input tolerance

    @Test func unknownInputIsInsignificant() {
        let lines = [
            "not json at all",
            "{\"broken\": ",
            jsonLine(["type": "world_state", "payload": ["anything": 1]]),
            jsonLine(["type": "inter_agent_communication_metadata", "payload": [String: Any]()]),
            jsonLine(["type": "some_future_type", "payload": ["x": true]]),
            jsonLine(["timestamp": "2026-07-31T10:00:00Z", "type": "event_msg"]),  // no payload
            eventLine("token_count"),
            eventLine("agent_message", extra: ["message": "hi", "phase": "final"]),
            eventLine("user_message", extra: ["message": "injected context"]),
            eventLine("sub_agent_activity"),
            eventLine("some_future_event"),
        ]
        var accumulator = CodexThreadAccumulator()
        for line in lines {
            guard case .insignificant = CodexRolloutParser.parseLine(line) else {
                Issue.record("expected insignificant for: \(line)")
                return
            }
            accumulator.consume(line: line)
        }
        #expect(accumulator.meta == nil)
        #expect(accumulator.lastSignificant == nil)
        #expect(accumulator.derivedState.reason == "Session open")
    }

    // MARK: - Timestamps

    @Test func parsesFractionalAndPlainTimestamps() throws {
        let fractional = try #require(CodexRolloutParser.parseDate("2026-07-31T21:17:35.830Z"))
        let plain = try #require(CodexRolloutParser.parseDate("2026-07-31T21:17:35Z"))
        #expect(abs(fractional.timeIntervalSince(plain) - 0.83) < 0.001)
        #expect(CodexRolloutParser.parseDate("yesterday-ish") == nil)

        guard
            case .significantEvent(let event) = CodexRolloutParser.parseLine(
                eventLine("task_started", timestamp: "2026-07-31T21:17:35Z")
            )
        else {
            Issue.record("expected significantEvent")
            return
        }
        #expect(event.timestamp == plain)
    }

    // MARK: - lastAgentMessage truncation

    @Test func lastAgentMessageIsTruncatedTo200Chars() {
        let long = String(repeating: "m", count: 500)
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: eventLine("task_complete", extra: ["last_agent_message": long]))
        #expect(accumulator.lastAgentMessage?.count == 200)
        #expect(accumulator.lastAgentMessage == String(repeating: "m", count: 200))
    }

    // MARK: - Partial-line buffering

    @Test func completeLinesConsumesOnlyThroughLastNewline() {
        let (noneLines, noneConsumed) = CodexRolloutParser.completeLines(
            in: Data("partial with no newline".utf8)
        )
        #expect(noneLines.isEmpty)
        #expect(noneConsumed == 0)

        let data = Data("line-one\nline-two\npartial".utf8)
        let (lines, consumed) = CodexRolloutParser.completeLines(in: data)
        #expect(lines == ["line-one", "line-two"])
        #expect(consumed == "line-one\nline-two\n".utf8.count)

        // Feeding the unconsumed remainder plus its completion yields the line.
        let remainder =
            data[data.index(data.startIndex, offsetBy: consumed)...]
            + Data(" done\n".utf8)
        let (rest, restConsumed) = CodexRolloutParser.completeLines(in: remainder)
        #expect(rest == ["partial done"])
        #expect(restConsumed == "partial done\n".utf8.count)
    }

    // MARK: - Bootstrap

    @Test func bootstrapSmallFileReadsEverything() throws {
        let url = try makeTempFile(lines: [
            metaLine(sessionId: "S1", threadId: "T1"),
            eventLine("task_started"),
        ])
        let result = try #require(CodexThreadAccumulator.bootstrap(url: url))
        #expect(result.accumulator.meta?.sessionId == "S1")
        #expect(result.accumulator.derivedState.state == .running)
        #expect(result.offset == (try fileSize(of: url)))
    }

    @Test func bootstrapLargeFileScansAcrossChunkBoundaries() throws {
        var lines = [metaLine(sessionId: "S-big", threadId: "T-big", cwd: "/big/project")]
        lines += (0..<200).map(fillerLine)  // ~50 KB of insignificant middle
        lines.append(eventLine("task_started", timestamp: "2026-07-31T11:00:00.000Z"))
        lines.append(
            eventLine(
                "task_complete",
                timestamp: "2026-07-31T11:05:00.000Z",
                extra: ["last_agent_message": "Big file done"]
            ))
        let url = try makeTempFile(lines: lines)
        let size = try fileSize(of: url)
        let chunkSize = 2048
        #expect(size > UInt64(chunkSize), "fixture must span many chunks")

        let result = try #require(CodexThreadAccumulator.bootstrap(url: url, chunkSize: chunkSize))
        #expect(result.accumulator.meta?.sessionId == "S-big")
        #expect(result.accumulator.meta?.cwd == "/big/project")
        #expect(result.accumulator.derivedState.state == .needsYou)
        #expect(result.accumulator.lastAgentMessage == "Big file done")
        #expect(result.accumulator.lastSignificant?.timestamp == date("2026-07-31T11:05:00.000Z"))
        #expect(result.offset == size)
    }

    @Test func bootstrapFindsSignificantEventBuriedMidFile() throws {
        // Regression: a windowed scan missed task_started when followed by a
        // long stretch of insignificant output (mid-turn app launch showed the
        // session as idle). The streaming scan must find it wherever it is.
        var lines = [metaLine(sessionId: "S-mid", threadId: "T-mid")]
        lines.append(eventLine("task_started", timestamp: "2026-07-31T11:00:00.000Z"))
        lines += (0..<800).map(fillerLine)  // ~200 KB of reasoning after the event
        let url = try makeTempFile(lines: lines)

        let result = try #require(CodexThreadAccumulator.bootstrap(url: url, chunkSize: 4096))
        #expect(result.accumulator.derivedState.state == .running)
        #expect(result.accumulator.lastSignificant?.timestamp == date("2026-07-31T11:00:00.000Z"))
    }

    @Test func bootstrapParsesMetaLineLargerThanAChunk() throws {
        // Regression: a fixed head window dropped session_meta lines longer
        // than the window, making the thread invisible. Real metas can embed
        // large instruction blobs; the line must parse regardless of length.
        let payload: [String: Any] = [
            "session_id": "S-huge",
            "id": "T-huge",
            "cwd": "/huge/project",
            "instructions": String(repeating: "i", count: 20_000),
        ]
        let object: [String: Any] = [
            "timestamp": "2026-07-31T10:00:00.000Z",
            "type": "session_meta",
            "payload": payload,
        ]
        let metaData = try JSONSerialization.data(withJSONObject: object)
        let hugeMeta = try #require(String(data: metaData, encoding: .utf8))
        let url = try makeTempFile(lines: [hugeMeta, eventLine("task_started")])

        let result = try #require(CodexThreadAccumulator.bootstrap(url: url, chunkSize: 4096))
        #expect(result.accumulator.meta?.sessionId == "S-huge")
        #expect(result.accumulator.meta?.cwd == "/huge/project")
        #expect(result.accumulator.derivedState.state == .running)
    }

    @Test func bootstrapLargeFileStopsBeforePartialTrailingLine() throws {
        var lines = [metaLine(sessionId: "S-partial", threadId: "T-partial")]
        lines += (0..<200).map(fillerLine)
        lines.append(eventLine("task_started", timestamp: "2026-07-31T11:00:00.000Z"))
        let partial = "{\"timestamp\":\"2026-07-31T11:06:00.000Z\",\"type\":\"event_ms"
        let url = try makeTempFile(lines: lines, trailing: partial)
        let size = try fileSize(of: url)

        let result = try #require(CodexThreadAccumulator.bootstrap(url: url, chunkSize: 2048))
        #expect(result.accumulator.derivedState.state == .running)
        // The unfinished trailing line stays unconsumed for the incremental reader.
        #expect(result.offset == size - UInt64(partial.utf8.count))
    }

    @Test func bootstrapLaterMetaInTailWins() throws {
        var lines = [metaLine(sessionId: "S-resume", threadId: "T-resume", cwd: "/original")]
        lines += (0..<200).map(fillerLine)
        lines.append(
            metaLine(
                sessionId: "S-resume", threadId: "T-resume", cwd: "/resumed",
                timestamp: "2026-07-31T12:00:00.000Z"
            ))
        let url = try makeTempFile(lines: lines)
        let result = try #require(CodexThreadAccumulator.bootstrap(url: url, chunkSize: 2048))
        #expect(result.accumulator.meta?.cwd == "/resumed")
    }

    // MARK: - Grouping

    @Test func groupingPicksLatestNonSubagentThread() {
        var older = CodexThreadAccumulator()
        older.consume(line: metaLine(sessionId: "S1", threadId: "T-old", cwd: "/old"))
        older.consume(line: eventLine("task_started", timestamp: "2026-07-31T10:00:00.000Z"))

        var newer = CodexThreadAccumulator()
        newer.consume(line: metaLine(sessionId: "S1", threadId: "T-new", cwd: "/new"))
        newer.consume(
            line: eventLine(
                "task_complete",
                timestamp: "2026-07-31T11:00:00.000Z",
                extra: ["last_agent_message": "Done here"]
            ))

        let sessions = CodexSessionGrouper.sessions(from: [
            snapshot(older, fileActivityAt: date("2026-07-31T10:00:00Z")),
            snapshot(newer, fileActivityAt: date("2026-07-31T11:00:00Z"), holderPid: 4242),
        ])
        #expect(sessions.count == 1)
        guard let session = sessions.first else { return }
        #expect(session.provider == "codex")
        #expect(session.sessionId == "S1")
        #expect(session.cwd == "/new")
        #expect(session.state == .needsYou)
        #expect(session.reason == "Turn complete — ready for you")
        #expect(session.lastMessage == "Done here")
        #expect(session.pid == 4242)
        #expect(session.stateChangedAt == date("2026-07-31T11:00:00.000Z"))
        #expect(session.fileURL == nil)
        #expect(session.termProgram == nil)
    }

    @Test func subagentThreadContributesLivenessButNotState() {
        var primary = CodexThreadAccumulator()
        primary.consume(line: metaLine(sessionId: "S1", threadId: "T-root", cwd: "/root"))
        primary.consume(line: eventLine("task_started", timestamp: "2026-07-31T10:00:00.000Z"))

        var subagent = CodexThreadAccumulator()
        subagent.consume(
            line: metaLine(
                sessionId: "S1", threadId: "T-sub", cwd: "/sub", subagent: true
            ))
        subagent.consume(
            line: eventLine(
                "task_complete",
                timestamp: "2026-07-31T12:00:00.000Z",  // newest event, but a subagent's
                extra: ["last_agent_message": "subagent chatter"]
            ))

        let sessions = CodexSessionGrouper.sessions(from: [
            snapshot(primary, fileActivityAt: date("2026-07-31T10:00:00Z")),
            snapshot(subagent, fileActivityAt: date("2026-07-31T12:00:00Z"), holderPid: 777),
        ])
        #expect(sessions.count == 1)
        guard let session = sessions.first else { return }
        // State comes from the non-subagent thread…
        #expect(session.state == .running)
        #expect(session.cwd == "/root")
        #expect(session.lastMessage == nil)
        #expect(session.stateChangedAt == date("2026-07-31T10:00:00.000Z"))
        // …while the subagent still contributes liveness.
        #expect(session.pid == 777)
        #expect(session.updatedAt == date("2026-07-31T12:00:00Z"))
    }

    @Test func subagentOnlyGroupProducesNoSession() {
        var subagent = CodexThreadAccumulator()
        subagent.consume(line: metaLine(sessionId: "S-sub", threadId: "T-sub", subagent: true))
        subagent.consume(line: eventLine("task_started"))

        let sessions = CodexSessionGrouper.sessions(from: [snapshot(subagent, holderPid: 99)])
        #expect(sessions.isEmpty)
    }

    @Test func groupingSplitsDistinctSessionIds() {
        var first = CodexThreadAccumulator()
        first.consume(line: metaLine(sessionId: "S-a", threadId: "T-a"))
        var second = CodexThreadAccumulator()
        second.consume(line: metaLine(sessionId: "S-b", threadId: "T-b"))
        second.consume(line: eventLine("task_started"))

        let sessions = CodexSessionGrouper.sessions(from: [snapshot(first), snapshot(second)])
        #expect(sessions.map(\.sessionId) == ["S-a", "S-b"])
        #expect(sessions.first?.state == .idle)
        #expect(sessions.first?.reason == "Session open")
        #expect(sessions.last?.state == .running)
    }

    // MARK: - Usage limits

    /// A `token_count` line exactly as Codex writes it, from a real rollout.
    private func tokenCountLine(
        usedPercent: Double, windowMinutes: Int, resetsAt: Int, reachedType: String = "null"
    ) -> String {
        """
        {"timestamp":"2026-08-02T05:53:07.123Z","type":"event_msg","payload":{
         "type":"token_count",
         "info":{"total_token_usage":{},"last_token_usage":{},"model_context_window":258400},
         "rate_limits":{"limit_id":"codex","limit_name":null,
           "primary":{"used_percent":\(usedPercent),"window_minutes":\(windowMinutes),
                      "resets_at":\(resetsAt)},
           "secondary":null,
           "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
           "individual_limit":null,"spend_control_reached":null,
           "plan_type":"pro","rate_limit_reached_type":\(reachedType)}}}
        """
    }

    /// The window is classified by its LENGTH, never by the slot it arrived in.
    /// Codex has reported only the weekly window since around February 2026 —
    /// and reports it as `primary` — so trusting the slot would announce a
    /// weekly reset as a five-hour one.
    @Test func theWindowIsClassifiedByItsLengthNotItsSlot() {
        var weekly = CodexThreadAccumulator()
        weekly.consume(
            line: tokenCountLine(usedPercent: 100, windowMinutes: 10080, resetsAt: 1_786_177_907))
        #expect(weekly.usageLimit?.window == .weekly)

        var fiveHour = CodexThreadAccumulator()
        fiveHour.consume(
            line: tokenCountLine(usedPercent: 42, windowMinutes: 300, resetsAt: 1_786_177_907))
        #expect(fiveHour.usageLimit?.window == .fiveHour)
        #expect(fiveHour.usageLimit?.usedPercent == 42)

        // Real corpora carry 299 and 10079 too, so classification tolerates
        // neighbours rather than demanding equality.
        var offByOne = CodexThreadAccumulator()
        offByOne.consume(
            line: tokenCountLine(usedPercent: 10, windowMinutes: 10079, resetsAt: 1_786_177_907))
        #expect(offByOne.usageLimit?.window == .weekly)
    }

    /// The explicit flag was never once non-null across the local corpus, so
    /// "100% used" has to count as reached on its own.
    @Test func exhaustionIsRecognizedFromEitherSignal() {
        var byPercent = CodexThreadAccumulator()
        byPercent.consume(
            line: tokenCountLine(usedPercent: 100, windowMinutes: 10080, resetsAt: 1_786_177_907))
        #expect(byPercent.usageLimit?.isReached == true)

        var byFlag = CodexThreadAccumulator()
        byFlag.consume(
            line: tokenCountLine(
                usedPercent: 87, windowMinutes: 10080, resetsAt: 1_786_177_907,
                reachedType: "\"rate_limit_reached\""))
        #expect(byFlag.usageLimit?.isReached == true)

        var plenty = CodexThreadAccumulator()
        plenty.consume(
            line: tokenCountLine(usedPercent: 40, windowMinutes: 10080, resetsAt: 1_786_177_907))
        #expect(plenty.usageLimit?.isReached == false)
    }

    /// "100% used, resets at 13:50" stops being true at 13:50, and nothing
    /// writes a correction — the file just goes quiet. So a reading is only
    /// evidence while its reset is still ahead.
    @Test func anExpiredReadingNoLongerBlocks() {
        let resetsAt = Date(timeIntervalSince1970: 1_786_177_907)
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(
            line: tokenCountLine(usedPercent: 100, windowMinutes: 10080, resetsAt: 1_786_177_907))
        let limit = try? #require(accumulator.usageLimit)

        #expect(limit?.isBlocking(now: resetsAt.addingTimeInterval(-60)) == true)
        #expect(limit?.isBlocking(now: resetsAt.addingTimeInterval(60)) == false)
        // No reset time is not evidence of blocking.
        #expect(
            UsageLimit(window: .weekly, usedPercent: 100, resetsAt: nil, isReached: true)
                .isBlocking(now: resetsAt) == false)
    }

    /// A thread reports its reading and does not interpret it. The limit belongs
    /// to the ACCOUNT, so what a row says about it is decided once, elsewhere
    /// (`UsageLimitPresentation`) — keeping it here made a blocked account explain
    /// only the row whose rollout happened to carry the reading.
    @Test func aThreadReportsItsReadingWithoutInterpretingIt() {
        var accumulator = CodexThreadAccumulator()
        accumulator.consume(line: eventLine("task_complete"))
        accumulator.consume(
            line: tokenCountLine(usedPercent: 100, windowMinutes: 10080, resetsAt: 1_786_177_907))

        #expect(accumulator.usageLimit?.isReached == true)
        #expect(accumulator.derivedState.state == .needsYou)
        #expect(accumulator.derivedState.reason == "Turn complete — ready for you")
    }
}
