import Combine
import Darwin
import Foundation

struct SessionCounts: Equatable {
    var needsYou = 0
    var running = 0
    var idle = 0

    var total: Int { needsYou + running + idle }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    static let sessionsDirectory: URL = {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-tracker")
        }
        return base.appendingPathComponent("sessions")
    }()

    private var watcher: DirectoryWatcher?
    private var refreshTimer: Timer?
    private var codexScanner: CodexSessionScanner?
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

    var counts: SessionCounts {
        var counts = SessionCounts()
        for session in sessions {
            switch session.state {
            case .needsYou: counts.needsYou += 1
            case .running: counts.running += 1
            case .idle: counts.idle += 1
            }
        }
        return counts
    }

    init() {
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
            .combineLatest(scanner.$knownThreadIds)
            .sink { [weak self] _, _ in
                // Hop a tick so the scanner's published properties are set.
                Task { @MainActor in self?.rebuild() }
            }
    }

    func reload() {
        let fileManager = FileManager.default
        var loaded: [AgentSession] = []
        if let files = try? fileManager.contentsOfDirectory(
            at: Self.sessionsDirectory, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      var session = try? decoder.decode(AgentSession.self, from: data) else { continue }
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
            if !scanned.isEmpty {
                let scannerSessionIds = Set(scanned.map(\.sessionId))
                let scannerThreadIds = scanner.knownThreadIds
                let scannerCwds = Set(scanned.compactMap(\.cwd))
                // The notify hook's sessionId may be a thread id rather than the
                // stable session_id, so match against both — plus cwd as a last
                // resort. Unmatched codex file rows stay visible as fallback.
                merged.removeAll { row in
                    guard row.provider == "codex" else { return false }
                    if scannerSessionIds.contains(row.sessionId) { return true }
                    if scannerThreadIds.contains(row.sessionId) { return true }
                    if let cwd = row.cwd, scannerCwds.contains(cwd) { return true }
                    return false
                }
            }
            if !codexAcknowledgedAt.isEmpty {
                let liveIds = Set(scanned.map(\.sessionId))
                codexAcknowledgedAt = codexAcknowledgedAt.filter { liveIds.contains($0.key) }
            }
            merged.append(contentsOf: scanned.map(applyAcknowledgement))
        }

        sessions = merged.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            return (lhs.stateChangedAt ?? .distantPast) > (rhs.stateChangedAt ?? .distantPast)
        }
    }

    private func applyAcknowledgement(_ session: AgentSession) -> AgentSession {
        guard session.state == .needsYou,
              let ackDate = codexAcknowledgedAt[session.sessionId],
              ackDate > (session.stateChangedAt ?? .distantPast) else { return session }
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
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            object["state"] = SessionState.idle.rawValue
            object["reason"] = "Acknowledged"
            object["stateChangedAt"] = ISO8601DateFormatter().string(from: Date())
            if let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
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
