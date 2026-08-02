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

    nonisolated static let sessionsDirectory: URL = {
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

    /// Default cadence of the safety-net reload. Hook/rollout watchers already
    /// deliver state changes instantly; the tick bounds how stale a *derived*
    /// display can get (dead-process pruning, relative timestamps). The user
    /// picks the actual cadence in Settings (`Preferences.refreshInterval`).
    nonisolated static let defaultRefreshInterval: TimeInterval = 1

    private var watcher: DirectoryWatcher?
    private var refreshTimer: Timer?
    private var preferencesSubscription: AnyCancellable?
    /// Bumped when a displayed relative time would have changed, so rows
    /// re-render on a quiet machine without republishing identical sessions.
    @Published private(set) var clockTick = 0
    private var lastClockBucket = 0
    private var codexScanner: CodexSessionScanner?
    private let titleDirectory: TitleDirectory
    private let claudeRegistry: ClaudeSessionRegistry
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
        claudeRegistry = ClaudeSessionRegistry()
        try? FileManager.default.createDirectory(
            at: Self.sessionsDirectory, withIntermediateDirectories: true
        )
        reload()
        watcher = DirectoryWatcher(url: Self.sessionsDirectory) { [weak self] in
            self?.reload()
        }
        // Hook writes and rollout edits arrive by watcher, so this tick is the
        // safety net: it prunes sessions whose process died without a clean
        // SessionEnd and catches anything a watcher missed. At the default 1s
        // the menu bar is never meaningfully behind reality; the cost is one
        // directory listing plus a kill(0) per session, and `rebuild` only
        // republishes when something actually changed, so an idle machine
        // stays idle. The cadence is a preference; changing it reschedules
        // the timer live.
        // The publisher's initial emission performs the first schedule;
        // removeDuplicates keeps unrelated preference churn from restarting
        // the timer (a restart resets its phase).
        preferencesSubscription = Preferences.shared.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                Task { @MainActor in self?.scheduleRefreshTimer(interval: interval) }
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

    private func scheduleRefreshTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        // Piggybacked on every reload tick: recovers the title watcher when
        // ~/.claude appears late or is recreated, and absorbs payloads from
        // statusline scripts that rewrite the file in place (no rename, so no
        // directory event).
        titleDirectory.refresh()
        claudeRegistry.refresh()
        // Codex has no hook to write a state file, and FSEvents does not
        // reliably report appends to its rollouts — so the scanner's cheap
        // re-read rides this same tick. Without it, a Codex turn starting or
        // finishing stayed invisible until the scanner's 30s liveness pass.
        codexScanner?.refreshFiles()
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
        var merged = fileSessions.map {
            RegistryEnrichment.apply(
                to: $0, entry: claudeRegistry.entry(forSessionId: $0.sessionId))
        }
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

        let sorted = merged.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            return (lhs.stateChangedAt ?? .distantPast) > (rhs.stateChangedAt ?? .distantPast)
        }
        // Reloading every second, so publish only real changes: an unchanged
        // assignment would still redraw the icon and re-render the popover.
        if sessions != sorted { sessions = sorted }
        if !focusRotation.isEmpty {
            let live = Set(sorted.map(\.id))
            focusRotation = focusRotation.filter { live.contains($0.key) }
        }
        advanceClockIfNeeded()
        // Change-only, and NOT DEBUG-gated: this is the line that makes a bug
        // report from the installed app useful, and rebuilds fire on every
        // hook event and timer tick so the change filter is what keeps the
        // log quiet.
        let counts = counts
        let rows = sessions.map { "\($0.provider):\($0.projectName)(\($0.state.rawValue))" }
        let tallies =
            "\(counts.needsYou) needsYou, \(counts.running) running, \(counts.idle) idle"
        let summary =
            "\(sessions.count) sessions — \(tallies): \(rows.joined(separator: ", "))"
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            DebugLog.log("[store] \(DebugLog.timestamp()) \(summary)")
        }
    }

    private var lastLoggedSummary = ""

    /// Row timestamps read "now/3m/2h/1d", so they only ever change on a
    /// 30-second boundary — republish on that boundary rather than every tick.
    private func advanceClockIfNeeded() {
        let bucket = Int(Date().timeIntervalSince1970 / 30)
        guard bucket != lastClockBucket else { return }
        lastClockBucket = bucket
        clockTick &+= 1
    }

    private func applyAcknowledgement(_ session: AgentSession) -> AgentSession {
        guard session.state == .needsYou,
            let ackDate = codexAcknowledgedAt[session.sessionId],
            ackDate > (session.stateChangedAt ?? .distantPast)
        else { return session }
        var acknowledged = session
        acknowledged.state = .idle
        acknowledged.reason = "Seen"
        return acknowledged
    }

    /// How many times each row has been clicked. Keyed by session id and pruned
    /// with the sessions themselves.
    private var focusRotation: [String: Int] = [:]

    /// Where this row should start looking among windows it cannot be told
    /// apart from, and how many sessions are competing for them.
    ///
    /// The rank is what makes two sibling rows land on two different windows.
    /// A click count alone is not enough: every row's first click is 0, so all
    /// of them pick the same candidate — measured, after shipping exactly that.
    func nextFocusRotation(for session: AgentSession) -> WindowIdentity.FocusRotation {
        let previous = focusRotation[session.id] ?? -1
        let clicks = previous == .max ? 0 : previous + 1
        focusRotation[session.id] = clicks

        // A session with a name of its own is excluded from the grouping: it
        // matches its window exactly through a strategy that runs before any of
        // this, so it never competes for these windows and counting it would
        // leave the rivals holding sparse ranks that collide. It keeps its click
        // count all the same — the exact match can miss (a stale title, a window
        // since closed), and the fallback tie still has to advance on a second
        // click rather than raise the same window again.
        guard exactWindowTitle(for: session) == nil else {
            return WindowIdentity.FocusRotation(rank: 0, clicks: clicks, siblingCount: 1)
        }

        // Competition runs over every directory a session answers to, not just
        // the one its row is titled with: a worktree session's terminal sits at
        // the repo root, so it can take a window a root session also wants.
        let rivals =
            sessions
            .filter { exactWindowTitle(for: $0) == nil }
            .map { (id: $0.id, directories: $0.windowDirectories) }
        let group = WindowIdentity.competingGroup(for: session.id, among: rivals)
        return .among(group, sessionId: session.id, clicks: clicks)
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
            object["reason"] = "Seen"
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
