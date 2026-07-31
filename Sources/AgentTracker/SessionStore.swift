import Foundation
import Darwin

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
    }

    func reload() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: Self.sessionsDirectory, includingPropertiesForKeys: nil
        ) else {
            sessions = []
            return
        }

        var loaded: [AgentSession] = []
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

        sessions = loaded.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            return (lhs.stateChangedAt ?? .distantPast) > (rhs.stateChangedAt ?? .distantPast)
        }
    }

    /// Downgrade a needs-you session to idle once the user has jumped to it —
    /// it no longer needs to pull attention.
    func acknowledge(_ session: AgentSession) {
        guard session.state == .needsYou, let fileURL = session.fileURL else { return }
        guard let data = try? Data(contentsOf: fileURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        object["state"] = SessionState.idle.rawValue
        object["reason"] = "Acknowledged"
        object["stateChangedAt"] = ISO8601DateFormatter().string(from: Date())
        if let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: fileURL, options: .atomic)
        }
        reload()
    }

    static func isProcessAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
