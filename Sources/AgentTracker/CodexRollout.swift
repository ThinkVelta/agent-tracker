import Foundation

/// Pure parsing/derivation logic for Codex rollout files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`). No I/O beyond
/// reading files explicitly given to it; fully unit-testable.

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
              let type = object["type"] as? String else { return .insignificant }
        let timestamp = (object["timestamp"] as? String).flatMap(parseDate)

        switch type {
        case "session_meta":
            guard let payload = object["payload"] as? [String: Any],
                  let sessionId = payload["session_id"] as? String else { return .insignificant }
            return .sessionMeta(CodexSessionMeta(
                sessionId: sessionId,
                threadId: payload["id"] as? String,
                cwd: payload["cwd"] as? String,
                isSubagent: (payload["thread_source"] as? String) == "subagent",
                timestamp: timestamp
            ))
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { return .insignificant }
            switch eventType {
            case "task_started":
                return .significantEvent(CodexSignificantEvent(kind: .taskStarted, timestamp: timestamp))
            case "task_complete":
                let message = payload["last_agent_message"] as? String
                return .significantEvent(CodexSignificantEvent(
                    kind: .taskComplete(lastAgentMessage: message), timestamp: timestamp
                ))
            case "turn_aborted":
                return .significantEvent(CodexSignificantEvent(kind: .turnAborted, timestamp: timestamp))
            default:
                // agent_message, user_message, token_count, … — not state-relevant.
                return .insignificant
            }
        default:
            // world_state, turn_context, future line types — ignore gracefully.
            return .insignificant
        }
    }

    /// Splits `data` into complete lines (up to and including the last newline)
    /// and reports how many bytes were consumed. Bytes after the last newline —
    /// a partially written trailing line — are NOT consumed, so callers can
    /// retry them once the rest arrives.
    static func completeLines(in data: Data) -> (lines: [String], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        let complete = data[data.startIndex..<lastNewline]
        let lines = complete
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

    mutating func consume(line: String) {
        apply(CodexRolloutParser.parseLine(line))
    }

    mutating func apply(_ parsed: CodexRolloutLine) {
        switch parsed {
        case .sessionMeta(let meta):
            self.meta = meta // later metas (resume) win
        case .significantEvent(let event):
            lastSignificant = event
            if case .taskComplete(let message) = event.kind, let message, !message.isEmpty {
                lastAgentMessage = String(message.prefix(Self.agentMessageLimit))
            }
        case .insignificant:
            break
        }
    }

    var derivedState: (state: SessionState, reason: String) {
        switch lastSignificant?.kind {
        case .taskStarted: return (.running, "Working…")
        case .taskComplete: return (.needsYou, "Turn complete — ready for you")
        case .turnAborted: return (.idle, "Interrupted")
        case nil: return (.idle, "Session open")
        }
    }
}

// MARK: - Bootstrap (head + tail windows)

extension CodexThreadAccumulator {
    static let defaultHeadWindow = 16 * 1024
    static let defaultTailWindow = 128 * 1024

    /// Bootstraps an accumulator from an existing (possibly 10+ MB) rollout file
    /// without reading it whole: the head window yields the first session_meta,
    /// the tail window (aligned to its first newline) yields the last
    /// significant event. Returns the accumulator plus the byte offset up to
    /// which complete lines were consumed — incremental reads continue there.
    static func bootstrap(
        url: URL,
        headWindow: Int = defaultHeadWindow,
        tailWindow: Int = defaultTailWindow
    ) -> (accumulator: CodexThreadAccumulator, offset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var accumulator = CodexThreadAccumulator()
        guard size > 0 else { return (accumulator, 0) }

        // Small file: read it whole.
        if size <= UInt64(headWindow + tailWindow) {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let data = try? handle.readToEnd() else { return (accumulator, 0) }
            let (lines, consumed) = CodexRolloutParser.completeLines(in: data)
            for line in lines { accumulator.consume(line: line) }
            return (accumulator, UInt64(consumed))
        }

        // Head window: metadata only — any events here are stale by definition.
        if (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: headWindow) {
            let (lines, _) = CodexRolloutParser.completeLines(in: head)
            for line in lines {
                let parsed = CodexRolloutParser.parseLine(line)
                if case .sessionMeta = parsed { accumulator.apply(parsed) }
            }
        }

        // Tail window: skip the partial first line, then consume everything —
        // later session_metas (resume) override the head's, and the last
        // significant event determines state.
        let tailStart = size - UInt64(tailWindow)
        guard (try? handle.seek(toOffset: tailStart)) != nil,
              let tail = try? handle.read(upToCount: tailWindow),
              let firstNewline = tail.firstIndex(of: UInt8(ascii: "\n")) else {
            // No line boundary inside the window (one giant line) — resume from
            // the window start so incremental reads can complete it.
            return (accumulator, tailStart)
        }
        let alignedStart = tail.index(after: firstNewline)
        let aligned = tail[alignedStart...]
        let (lines, consumed) = CodexRolloutParser.completeLines(in: aligned)
        for line in lines { accumulator.consume(line: line) }
        let alignedOffset = tailStart + UInt64(tail.distance(from: tail.startIndex, to: alignedStart))
        return (accumulator, alignedOffset + UInt64(consumed))
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
            let stateChangedAt = accumulator.lastSignificant?.timestamp
                ?? accumulator.meta?.timestamp
                ?? primary.fileActivityAt

            sessions.append(AgentSession(
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
