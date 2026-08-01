import Combine
import Darwin
import Foundation

struct SessionCounts: Equatable {
    var needsYou = 0
    var running = 0
    var idle = 0

    var total: Int { needsYou + running + idle }

    init() {}

    init(of sessions: [AgentSession]) {
        for session in sessions {
            switch session.state {
            case .needsYou: needsYou += 1
            case .running: running += 1
            case .idle: idle += 1
            }
        }
    }

    func count(for state: SessionState) -> Int {
        switch state {
        case .needsYou: return needsYou
        case .running: return running
        case .idle: return idle
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Dot/chip state filter for the dropdown. Set both by clicking a dot in
    /// the menu bar and by the in-popover chips, so the two stay in sync.
    @Published var selectedFilter: SessionState?

    static let sessionsDirectory: URL = {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_DIR"],
            !override.isEmpty
        {
            base = URL(fileURLWithPath: override)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".agent-tracker")
        }
        return base.appendingPathComponent("sessions")
    }()

    private var watcher: DirectoryWatcher?
    private var refreshTimer: Timer?
    private var codexScanner: CodexSessionScanner?
    private let titleDirectory: TitleDirectory
    private var scannerSubscription: AnyCancellable?
    /// Sessions loaded from ~/.agent-tracker state files (hook-written).
    private var fileSessions: [AgentSession] = []
    /// In-memory acknowledgements for scanner-derived codex rows — they have no
    /// state file to rewrite. A session displays idle while ackDate is newer
    /// than its stateChangedAt.
    private var codexAcknowledgedAt: [String: Date] = [:]
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var counts: SessionCounts { SessionCounts(of: sessions) }

    /// The session's live terminal window title, when known — the top-weight
    /// candidate for window matching. Claude-only: Codex tab titles are bare
    /// project names that already exact-match via the path candidates.
    func exactWindowTitle(for session: AgentSession) -> String? {
        guard session.provider == "claude-code" else { return nil }
        return titleDirectory.title(for: session.sessionId)
    }

    init() {
        titleDirectory = TitleDirectory()
        try? FileManager.default.createDirectory(
            at: Self.sessionsDirectory, withIntermediateDirectories: true
        )
        reload()
        watcher = DirectoryWatcher(url: Self.sessionsDirectory) { [weak self] in
            self?.reload()
        }
        // Periodic reload keeps relative timestamps fresh and prunes dead sessions
        // even when no new events arrive.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }

        // Codex has no turn-start hook; live state comes from watching rollout
        // files directly.
        let scanner = CodexSessionScanner()
        codexScanner = scanner
        scannerSubscription = scanner.$sessions
            .combineLatest(scanner.$threadIdToSession, scanner.$subagentThreadIds)
            .sink { [weak self] _, _, _ in
                // Hop a tick so the scanner's published properties are set.
                Task { @MainActor in self?.rebuild() }
            }
    }

    func reload() {
        // Piggybacked on every reload tick: recovers the title watcher when
        // ~/.claude appears late or is recreated, and absorbs payloads from
        // statusline scripts that rewrite the file in place (no rename, so no
        // directory event).
        titleDirectory.refresh()
        let fileManager = FileManager.default
        var loaded: [AgentSession] = []
        if let files = try? fileManager.contentsOfDirectory(
            at: Self.sessionsDirectory, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                    var session = try? decoder.decode(AgentSession.self, from: data)
                else { continue }
                if let pid = session.pid, pid > 0, !Self.isProcessAlive(pid) {
                    // Agent died without a clean SessionEnd (killed terminal, crash).
                    try? fileManager.removeItem(at: file)
                    continue
                }
                session.fileURL = file
                loaded.append(session)
            }
        }
        fileSessions = loaded
        rebuild()
    }

    /// Merges hook-written state-file sessions with scanner-derived codex
    /// sessions, deduping the codex state-file rows the scanner supersedes.
    private func rebuild() {
        var merged = fileSessions
        if let scanner = codexScanner {
            let scanned = scanner.sessions
            let threadMap = scanner.threadIdToSession
            // Notify rows for subagent threads are internal fan-out, never
            // user-facing sessions — Codex multi-agent fires the notify hook
            // per subagent turn. Delete their state files (not just hide):
            // the live threadMap dedupe below only lasts while the subagent's
            // rollout is tracked, and these files otherwise resurface as
            // phantom "needs you" rows for as long as the root codex process
            // lives, one per completed subagent.
            let subagentThreads = scanner.subagentThreadIds
            if !subagentThreads.isEmpty {
                merged.removeAll { row in
                    guard row.provider == "codex",
                        subagentThreads.contains(row.sessionId)
                    else { return false }
                    if let fileURL = row.fileURL {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    return true
                }
            }
            // The notify hook's sessionId may be a thread id rather than the
            // stable session_id — the scanner's map resolves both. A matched
            // notify row is superseded, but still carries enrichment rollouts
            // can't provide (TERM_PROGRAM from the session's shell), so graft
            // that onto the scanner row. Unmatched rows stay visible as
            // fallback — deliberately no cwd-based matching, which could hide
            // a distinct session sharing a working directory.
            var termProgramBySession: [String: String] = [:]
            if !scanned.isEmpty {
                merged.removeAll { row in
                    guard row.provider == "codex",
                        let target = threadMap[row.sessionId]
                    else { return false }
                    if let termProgram = row.termProgram {
                        termProgramBySession[target] = termProgram
                    }
                    return true
                }
            }
            if !codexAcknowledgedAt.isEmpty {
                let liveIds = Set(scanned.map(\.sessionId))
                codexAcknowledgedAt = codexAcknowledgedAt.filter { liveIds.contains($0.key) }
            }
            merged.append(
                contentsOf: scanned.map { session in
                    var session = session
                    if session.termProgram == nil {
                        session.termProgram = termProgramBySession[session.sessionId]
                    }
                    return applyAcknowledgement(session)
                })
        }

        sessions = merged.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            return (lhs.stateChangedAt ?? .distantPast) > (rhs.stateChangedAt ?? .distantPast)
        }
        #if DEBUG
            // Change-only: rebuilds fire on every hook event and timer tick; the
            // periodic "[codex-scan] lsof pass" line remains as the heartbeat.
            let counts = counts
            let rows = sessions.map { "\($0.provider):\($0.projectName)(\($0.state.rawValue))" }
            let tallies =
                "\(counts.needsYou) needsYou, \(counts.running) running, \(counts.idle) idle"
            let summary =
                "\(sessions.count) sessions — \(tallies): \(rows.joined(separator: ", "))"
            if summary != lastLoggedSummary {
                lastLoggedSummary = summary
                print("[store] \(DebugLog.timestamp()) \(summary)")
            }
        #endif
    }

    #if DEBUG
        private var lastLoggedSummary = ""
    #endif

    private func applyAcknowledgement(_ session: AgentSession) -> AgentSession {
        guard session.state == .needsYou,
            let ackDate = codexAcknowledgedAt[session.sessionId],
            ackDate > (session.stateChangedAt ?? .distantPast)
        else { return session }
        var acknowledged = session
        acknowledged.state = .idle
        acknowledged.reason = "Acknowledged"
        return acknowledged
    }

    /// Downgrade a needs-you session to idle once the user has jumped to it —
    /// it no longer needs to pull attention.
    func acknowledge(_ session: AgentSession) {
        guard session.state == .needsYou else { return }
        if let fileURL = session.fileURL {
            guard let data = try? Data(contentsOf: fileURL),
                var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            object["state"] = SessionState.idle.rawValue
            object["reason"] = "Acknowledged"
            object["stateChangedAt"] = ISO8601DateFormatter().string(from: Date())
            if let updated = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            {
                try? updated.write(to: fileURL, options: .atomic)
            }
            reload()
        } else if session.provider == "codex" {
            // Scanner-derived row: no file to edit, overlay in memory instead.
            codexAcknowledgedAt[session.sessionId] = Date()
            rebuild()
        }
    }

    static func isProcessAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
