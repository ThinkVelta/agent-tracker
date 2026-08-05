import Foundation

// Pure parsing/derivation logic for Codex rollout files
// (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`). No I/O beyond
// reading files explicitly given to it; fully unit-testable.

// MARK: - Parsed line model

/// Session metadata from a `session_meta` line. A rollout file can contain more
/// than one (e.g. on resume) — later ones win.
struct CodexSessionMeta: Equatable {
    /// Stable id of the whole user-facing session (shared across forked/spawned
    /// threads).
    var sessionId: String
    /// This rollout file's own thread id (== the filename uuid).
    var threadId: String?
    var cwd: String?
    /// True only when `thread_source` is exactly "subagent" — internal fan-out
    /// threads that never carry user-facing state.
    var isSubagent: Bool
    var timestamp: Date?
}

/// A state-relevant `event_msg` line.
struct CodexSignificantEvent: Equatable {
    enum Kind: Equatable {
        case taskStarted
        case taskComplete(lastAgentMessage: String?)
        case turnAborted
    }

    var kind: Kind
    var timestamp: Date?
}

enum CodexRolloutLine {
    case sessionMeta(CodexSessionMeta)
    case significantEvent(CodexSignificantEvent)
    /// Codex's account rate limits, which ride along on `token_count` events.
    /// Not a state change of its own — it explains one.
    case usageLimit(UsageLimit)
    /// Anything else — unknown line types, unparseable lines, ignorable events.
    /// Parsing never throws; unknown input degrades to this.
    case insignificant
}

// MARK: - Line parser

enum CodexRolloutParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Lenient ISO8601: rollout timestamps carry fractional seconds, but accept
    /// plain internet date-time too.
    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    static func parseLine(_ line: String) -> CodexRolloutLine {
        guard let data = line.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = object["type"] as? String
        else { return .insignificant }
        let timestamp = (object["timestamp"] as? String).flatMap(parseDate)

        switch type {
        case "session_meta":
            guard let payload = object["payload"] as? [String: Any],
                let sessionId = payload["session_id"] as? String
            else { return .insignificant }
            return .sessionMeta(
                CodexSessionMeta(
                    sessionId: sessionId,
                    threadId: payload["id"] as? String,
                    cwd: payload["cwd"] as? String,
                    isSubagent: (payload["thread_source"] as? String) == "subagent",
                    timestamp: timestamp
                ))
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any],
                let eventType = payload["type"] as? String
            else { return .insignificant }
            switch eventType {
            case "task_started":
                return .significantEvent(
                    CodexSignificantEvent(kind: .taskStarted, timestamp: timestamp))
            case "task_complete":
                let message = payload["last_agent_message"] as? String
                return .significantEvent(
                    CodexSignificantEvent(
                        kind: .taskComplete(lastAgentMessage: message), timestamp: timestamp
                    ))
            case "turn_aborted":
                return .significantEvent(
                    CodexSignificantEvent(kind: .turnAborted, timestamp: timestamp))
            case "token_count":
                // Roughly every third line carries one of these, so the state
                // is cheap to keep current and pointless to hunt for.
                guard let limits = payload["rate_limits"] as? [String: Any],
                    let limit = CodexUsageLimit.parse(limits)
                else { return .insignificant }
                return .usageLimit(limit)
            default:
                // agent_message, user_message, … — not state-relevant.
                return .insignificant
            }
        default:
            // world_state, turn_context, future line types — ignore gracefully.
            return .insignificant
        }
    }

    /// The thread id embedded in a rollout filename
    /// (`rollout-<timestamp>-<uuid>.jsonl`). This — not the meta payload's
    /// `id`, which resume metas repoint at fork ancestors — is the id the
    /// notify hook reports as `thread-id`, so it is the authoritative join
    /// key between a rollout file and its notify state file.
    static func threadId(fromRolloutFilename path: String) -> String? {
        let base = ((path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        guard base.hasPrefix("rollout-"), base.count > 36 else { return nil }
        let uuid = String(base.suffix(36))
        guard uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return uuid
    }

    /// Reads just the leading `session_meta` line of a rollout file, bounded so
    /// a malformed file can't stall the scanner (meta lines carry the full base
    /// instructions and run ~10-100KB). Used to identify subagent threads in
    /// dead rollouts that are never worth a full bootstrap.
    static func firstSessionMeta(
        atPath path: String, limit: Int = 512 * 1024
    ) -> CodexSessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        guard let end = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        guard let line = String(data: data[..<end], encoding: .utf8),
            case .sessionMeta(let meta) = parseLine(line)
        else { return nil }
        return meta
    }

    /// Cheap prefilter: a line can only parse to something state-relevant if it
    /// mentions one of these markers somewhere in its bytes. False positives
    /// just take the full-parse path; false negatives are impossible because
    /// the type string always appears verbatim in the line. This is what keeps
    /// a full-file bootstrap scan fast.
    static func mightBeSignificant(_ line: String) -> Bool {
        line.contains("session_meta")
            || line.contains("task_started")
            || line.contains("task_complete")
            || line.contains("turn_aborted")
            || line.contains("rate_limits")
    }

    /// Splits `data` into complete lines (up to and including the last newline)
    /// and reports how many bytes were consumed. Bytes after the last newline —
    /// a partially written trailing line — are NOT consumed, so callers can
    /// retry them once the rest arrives.
    static func completeLines(in data: Data) -> (lines: [String], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        let complete = data[data.startIndex..<lastNewline]
        let lines =
            complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { String(data: $0, encoding: .utf8) }
        return (lines, consumed)
    }
}

// MARK: - Per-thread accumulator

/// Consumes rollout lines incrementally and keeps just enough state to derive a
/// session row: latest metadata, last significant event, last agent message.
struct CodexThreadAccumulator: Equatable {
    static let agentMessageLimit = 200

    private(set) var meta: CodexSessionMeta?
    private(set) var lastSignificant: CodexSignificantEvent?
    private(set) var lastAgentMessage: String?
    /// The newest rate-limit reading seen in this rollout. Account-wide, so any
    /// thread's reading is as good as another's — the newest simply wins.
    private(set) var usageLimit: UsageLimit?

    mutating func consume(line: String) {
        guard CodexRolloutParser.mightBeSignificant(line) else { return }
        apply(CodexRolloutParser.parseLine(line))
    }

    mutating func apply(_ parsed: CodexRolloutLine) {
        switch parsed {
        case .sessionMeta(var meta):
            // Later metas (resume) win, but merge monotonically: resume metas
            // can carry the PREDECESSOR thread's id (fork lineage) or none at
            // all, and can flip thread_source back to "user" — a thread born
            // as a subagent is internal fan-out forever, and its first
            // observed id must not be lost.
            if let current = self.meta {
                if meta.threadId == nil { meta.threadId = current.threadId }
                if current.isSubagent { meta.isSubagent = true }
            }
            self.meta = meta
        case .significantEvent(let event):
            lastSignificant = event
            if case .taskComplete(let message) = event.kind, let message, !message.isEmpty {
                lastAgentMessage = String(message.prefix(Self.agentMessageLimit))
            }
        case .usageLimit(let limit):
            usageLimit = limit
        case .insignificant:
            break
        }
    }

    /// What this thread's own events say. A usage limit is deliberately NOT
    /// consulted here: it belongs to the account, not the thread, so it is
    /// applied once for every provider in `UsageLimitPresentation`.
    var derivedState: (state: SessionState, reason: String) {
        switch lastSignificant?.kind {
        case .taskStarted: return (.running, "Working…")
        case .taskComplete: return (.needsYou, "Turn complete — ready for you")
        case .turnAborted: return (.needsYou, "Interrupted — ready for you")
        case nil: return (.idle, "Session open")
        }
    }
}

// MARK: - Bootstrap (streaming scan)

extension CodexThreadAccumulator {
    static let defaultChunkSize = 1 << 20  // 1 MB

    /// Bootstraps an accumulator from an existing (possibly 10+ MB) rollout
    /// file by streaming it whole in bounded chunks. The `mightBeSignificant`
    /// prefilter skips JSON parsing for the overwhelmingly common insignificant
    /// lines, so the full scan stays cheap while never missing a significant
    /// event — a windowed scan can, whenever the last significant event is
    /// buried under a long stretch of reasoning/tool output. Returns the
    /// accumulator plus the byte offset up to which complete lines were
    /// consumed — incremental reads continue there (a partially written
    /// trailing line stays unconsumed until its newline arrives).
    static func bootstrap(
        url: URL,
        chunkSize: Int = defaultChunkSize
    ) -> (accumulator: CodexThreadAccumulator, offset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var accumulator = CodexThreadAccumulator()
        var offset: UInt64 = 0
        var pending = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            let (lines, consumed) = CodexRolloutParser.completeLines(in: pending)
            for line in lines { accumulator.consume(line: line) }
            offset += UInt64(consumed)
            pending.removeFirst(consumed)
        }
        return (accumulator, offset)
    }
}

// MARK: - Grouping threads into sessions

/// One tracked rollout file, ready for grouping.
struct CodexThreadSnapshot {
    var accumulator: CodexThreadAccumulator
    /// Last observed file activity (mtime) — feeds `updatedAt`.
    var fileActivityAt: Date?
    /// Pid of the codex process holding the file open, if any.
    var holderPid: Int?
}

enum CodexSessionGrouper {
    /// Groups thread snapshots by stable session_id into one AgentSession each.
    /// State/reason/stateChangedAt/cwd come from the non-subagent thread with
    /// the newest significant event; subagent threads contribute liveness (pid,
    /// updatedAt) only. Groups with only subagent threads produce no session.
    static func sessions(from threads: [CodexThreadSnapshot]) -> [AgentSession] {
        var groups: [String: [CodexThreadSnapshot]] = [:]
        for thread in threads {
            guard let meta = thread.accumulator.meta else { continue }
            groups[meta.sessionId, default: []].append(thread)
        }

        var sessions: [AgentSession] = []
        for (sessionId, group) in groups {
            let primaries = group.filter { $0.accumulator.meta?.isSubagent == false }
            guard let primary = primaries.max(by: { rank($0) < rank($1) }) else { continue }

            let accumulator = primary.accumulator
            let (state, reason) = accumulator.derivedState
            let pid = primary.holderPid ?? group.compactMap(\.holderPid).first
            let updatedAt = group.compactMap(\.fileActivityAt).max()
            let stateChangedAt =
                accumulator.lastSignificant?.timestamp
                ?? accumulator.meta?.timestamp
                ?? primary.fileActivityAt

            sessions.append(
                AgentSession(
                    schema: nil,
                    provider: "codex",
                    sessionId: sessionId,
                    pid: pid,
                    cwd: accumulator.meta?.cwd,
                    state: state,
                    reason: reason,
                    lastEvent: lastEventName(accumulator.lastSignificant?.kind),
                    updatedAt: updatedAt,
                    stateChangedAt: stateChangedAt,
                    transcriptPath: nil,
                    termProgram: nil,
                    lastMessage: accumulator.lastAgentMessage,
                    fileURL: nil
                ))
        }
        return sessions.sorted { $0.sessionId < $1.sessionId }
    }

    private static func rank(_ thread: CodexThreadSnapshot) -> (Date, Date) {
        (
            thread.accumulator.lastSignificant?.timestamp ?? .distantPast,
            thread.fileActivityAt ?? thread.accumulator.meta?.timestamp ?? .distantPast
        )
    }

    private static func lastEventName(_ kind: CodexSignificantEvent.Kind?) -> String? {
        switch kind {
        case .taskStarted: return "task_started"
        case .taskComplete: return "task_complete"
        case .turnAborted: return "turn_aborted"
        case nil: return nil
        }
    }
}
