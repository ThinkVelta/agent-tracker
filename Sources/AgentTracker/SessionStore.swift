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
    /// What is known about each provider's account limits. Sticky across
    /// reloads: the evidence appears once, in whichever session hit the wall,
    /// and then that session goes quiet — so it has to be remembered rather
    /// than re-derived. Entries expire on their own reset time.
    private(set) var accountLimits = AccountLimits()
    /// The reset each row may be armed against, keyed by session id. Only rows
    /// a limit actually explains appear here, so the arming affordance and the
    /// row's own wording can never disagree.
    private(set) var armableResetBySession: [String: Date] = [:]
    private let usageWatcher = ClaudeUsageWatcher()
    private let continueSchedules: ContinueSchedules
    /// The shared instance, for the same reason the schedules use theirs: the
    /// dropdown observes it directly, and a second one here would mute rows the
    /// menu never sees.
    private let muted = SessionKeySet.muted
    private let pinned = SessionKeySet.pinned
    /// Dot/chip state filter for the dropdown. Set both by clicking a dot in
    /// the menu bar and by the in-popover chips, so the two stay in sync.
    @Published var selectedFilter: SessionState?

    nonisolated static let baseDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".agent-tracker")
    }()

    nonisolated static let sessionsDirectory = baseDirectory.appendingPathComponent("sessions")

    /// Whether a state file in `sessionsDirectory` is one this app owns.
    ///
    /// The hook names every file it writes `claude-code-<session id>.json`, and
    /// that prefix is the only thing separating our rows from another agent's
    /// leftovers. It matters during exactly one window — the upgrade to this
    /// Claude-only build, while a session from the version that also tracked
    /// Codex is still running, so its file is not pruned because its process is
    /// alive.
    ///
    /// A leftover would not merely show a phantom row. The provider field is no
    /// longer read, so it would be indistinguishable from a Claude session:
    /// Codex's hooks write `lastEvent: "Stop"` too, which is the event the
    /// arming gate reads, so the row could be armed and typed into. Scoping the
    /// read is what makes that impossible rather than unlikely.
    nonisolated static func isOwnStateFile(_ file: URL) -> Bool {
        file.pathExtension == "json"
            && file.lastPathComponent.hasPrefix("claude-code-")
    }

    /// Where the statusline wrapper leaves Claude's session payload. Outside
    /// `sessions/` deliberately: anything with a `.json` extension in there is
    /// decoded as a session state file.
    nonisolated static let claudeStatuslineURL = baseDirectory.appendingPathComponent(
        "claude-statusline.json")

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

    /// What the dropdown shows about remaining quota. Derived in `rebuild` and
    /// published, rather than exposing `AccountLimits` itself: that is mutated
    /// several times per pass as readings merge, and observing it directly would
    /// redraw the menu bar icon on each one.
    @Published private(set) var usage: [UsageReading] = []
    private var lastClockBucket = 0
    private let statuslineDirectory: StatuslineDirectory
    private let claudeRegistry: ClaudeSessionRegistry
    /// Sessions loaded from ~/.agent-tracker state files (hook-written). The
    /// only source there is: every row on screen was written by a hook.
    private var fileSessions: [AgentSession] = []
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var counts: SessionCounts { SessionCounts(of: sessions) }

    /// The session's live terminal window title, when known — the top-weight
    /// candidate for window matching.
    func exactWindowTitle(for session: AgentSession) -> String? {
        Self.coalescedWindowTitle(
            registryName: claudeRegistry.entry(forSessionId: session.sessionId)?.name,
            statuslineTitle: statuslineDirectory.title(for: session.sessionId))
    }

    /// Registry first, statusline second, and pure so the precedence stays
    /// tested now that one reader serves both: a rename lands in the registry
    /// immediately, while a stale statusline capture can keep replaying the
    /// old name for as long as that session stays the file's last writer.
    nonisolated static func coalescedWindowTitle(
        registryName: String?, statuslineTitle: String?
    ) -> String? {
        registryName ?? statuslineTitle
    }

    init() {
        statuslineDirectory = StatuslineDirectory()
        claudeRegistry = ClaudeSessionRegistry()
        // The shared instance rather than an injected one: the dropdown observes
        // it directly, so a second instance here would arm one set of schedules
        // and display another.
        continueSchedules = ContinueSchedules.shared
        try? FileManager.default.createDirectory(
            at: Self.sessionsDirectory, withIntermediateDirectories: true
        )
        // A pass always comes from here, never from the scheduler itself, so
        // there is exactly one place that reads the clock for both.
        continueSchedules.requestPass = { [weak self] in self?.reload() }
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
        statuslineDirectory.refresh()
        claudeRegistry.refresh()
        // The proactive half of Claude's usage picture, and the only one that
        // exists before a request is refused. Polled rather than watched: the
        // wrapper rewrites this file every few hundred milliseconds per live
        // session, so a watcher would fire far more often than the display can
        // use, and re-reading ~1.5 KB on the tick we already run is cheaper.
        for limit in ClaudeStatusline.limits(at: Self.claudeStatuslineURL) {
            accountLimits.record(limit)
        }
        var loaded: [AgentSession] = []
        for (loadedSession, file) in Self.loadStateFiles() {
            var session = loadedSession
            if let pid = session.pid, pid > 0, !Self.isProcessAlive(pid) {
                // Agent died without a clean SessionEnd (killed terminal, crash).
                try? FileManager.default.removeItem(at: file)
                continue
            }
            session.fileURL = file
            loaded.append(session)
        }
        fileSessions = loaded
        rebuild()
    }

    /// Turns the state files on disk into the rows the menu bar draws.
    private func rebuild() {
        // One clock read for the whole pass. Every decision below is time-based —
        // which sweep window this is, whether a usage limit has expired, whether
        // the row timestamps need republishing — and reading the clock separately
        // for each let them disagree about what "now" is.
        let now = Date()
        var merged = fileSessions.map { session -> AgentSession in
            var enriched = RegistryEnrichment.apply(
                to: session, entry: claudeRegistry.entry(forSessionId: session.sessionId))
            enriched.contextUsedPercent = statuslineDirectory.contextUsedPercent(
                for: session.sessionId)
            return enriched
        }
        // Claude reports a refusal only in the transcript of the session that hit
        // the wall, so the trigger is that session stopping. A row that is still
        // running cannot be blocked; the 30-second bucket sweeps the rest as a
        // fallback, for the case where a refusal produces no hook at all.
        let sweeping = lastClockBucket != Self.clockBucket(at: now)
        let candidates = merged.filter { sweeping || $0.state == .needsYou }
        for limit in usageWatcher.check(candidates) {
            accountLimits.record(limit)
        }

        // The limit is account-wide, so two rows must not straddle its reset and
        // disagree about whether it has passed.
        // Two maps, deliberately keyed differently, because they answer different
        // questions. The provider one is for the scheduler: a usage limit is
        // account-wide, so re-arming a repeating schedule looks up the account's
        // reset. The session one is for the UI: only a row the limit actually
        // explains may be armed, and a provider-keyed lookup would offer the
        // clock on every Claude row the moment any one of them was blocked.
        var blockingReset: Date?
        var armableBySession: [String: Date] = [:]
        merged = merged.map { session in
            let limit = accountLimits.blockingLimit(now: now)
            if let moment = limit?.resetsAt {
                blockingReset = moment
                if UsageLimitPresentation.explains(session, limit: limit, now: now) {
                    armableBySession[session.sessionId] = moment
                }
            }
            return UsageLimitPresentation.apply(limit, to: session, now: now)
        }
        armableResetBySession = armableBySession
        let readings = UsageSummary.readings(from: accountLimits, now: now)
        if usage != readings { usage = readings }

        // After every other rule has decided what a row is, and before sorting:
        // a muted row sorts as the idle row it now displays as, which is the
        // point. Applied here rather than at the source so nothing upstream has
        // to know about muting, and so the reason a session gave survives — the
        // row still says "Approve Bash?", it just does not turn red for it.
        merged = merged.map { session in
            var marked = session
            marked.isPinned = pinned.contains(session.id)
            guard muted.contains(session.id) else { return marked }
            marked.isMuted = true
            if marked.state == .needsYou { marked.state = .idle }
            return marked
        }

        let sorted = merged.sorted(by: SessionOrder.precedes)
        // Reloading every second, so publish only real changes: an unchanged
        // assignment would still redraw the icon and re-render the popover.
        if sessions != sorted { sessions = sorted }
        let liveKeys = Set(sorted.map(\.id))
        muted.reconcile(liveKeys: liveKeys, now: now)
        pinned.reconcile(liveKeys: liveKeys, now: now)
        usageWatcher.prune(liveSessionIds: Set(sorted.map(\.sessionId)))
        if !focusRotation.isEmpty {
            let live = Set(sorted.map(\.id))
            focusRotation = focusRotation.filter { live.contains($0.key) }
        }
        advanceClockIfNeeded(at: now)
        // The tail of the pass, sharing its single `now`. A scheduler that read
        // its own clock here would let the schedule pass and the session pass
        // disagree about the present, which is the bug class that bit this
        // feature's predecessors three times.
        continueSchedules.reconcile(
            sessions: sessions, blockingReset: blockingReset, now: now)
        // Change-only, and NOT DEBUG-gated: this is the line that makes a bug
        // report from the installed app useful, and rebuilds fire on every
        // hook event and timer tick so the change filter is what keeps the
        // log quiet.
        let counts = counts
        // Context and mute ride along because "why is my row not showing a
        // percentage" and "why has this stopped turning red" are the two
        // questions this line is now most likely to be read for, and neither is
        // answerable from the state alone — one is joined in from another
        // source, the other deliberately rewrites the state it prints.
        let rows = sessions.map { session -> String in
            let context = session.contextUsedPercent.map { " ctx=\(Int($0.rounded()))%" } ?? ""
            return "\(session.projectName)"
                + "(\(session.state.rawValue))\(session.isMuted ? " muted" : "")\(context)"
        }
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

    /// The 30-second boundary two things hang off: row timestamps read
    /// "now/3m/2h/1d" and so only change on it, and the usage-limit fallback
    /// sweep runs on it. Both must agree on which bucket a rebuild is in, or the
    /// sweep can be marked done for a window it never ran in.
    static func clockBucket(at instant: Date) -> Int {
        Int(instant.timeIntervalSince1970 / 30)
    }

    private func advanceClockIfNeeded(at now: Date) {
        let bucket = Self.clockBucket(at: now)
        guard bucket != lastClockBucket else { return }
        lastClockBucket = bucket
        clockTick &+= 1
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

    /// Raise this session's terminal window, and clear its red state if the
    /// window that came up could be this session's.
    ///
    /// Lives here rather than in the row that calls it because a notification
    /// banner is a second way in, and the two must not drift: a jump that
    /// raises the window but forgets to acknowledge leaves a red row standing
    /// over a terminal the user is already reading.
    @discardableResult
    func focus(_ session: AgentSession) -> TerminalFocuser.Outcome {
        let exactTitle = exactWindowTitle(for: session)
        let roster = sessions.map { ($0, exactWindowTitle(for: $0)) }
        let outcome = TerminalFocuser.focus(
            session, exactTitle: exactTitle, among: roster,
            rotation: nextFocusRotation(for: session))
        // Acknowledge when the raised window could be this session's. A wholly
        // unrelated window, or one that exactly names someone else, still
        // refuses — silencing on that guess would hide a red state the user
        // never saw.
        if case .focusedWindow(let title) = outcome,
            TerminalFocuser.isPlausibleMatch(
                windowTitle: title, for: session, exactTitle: exactTitle, among: roster)
        {
            acknowledge(session)
        }
        return outcome
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
        }
    }

    /// Reads one session's state file straight from disk, off any actor.
    ///
    /// Delivery needs the session as it is *now*, not as the pass that scheduled
    /// it saw it: fires in one fan-out are twenty seconds apart, so by the third
    /// one "the turn had finished" is a claim about the past. Reading the file
    /// rather than the published array is also what keeps this callable from the
    /// detached delivery task without hopping to the main actor.
    nonisolated static func loadSessionFromDisk(sessionId: String) -> AgentSession? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        for file in files where isOwnStateFile(file) {
            guard let data = try? Data(contentsOf: file),
                let session = try? decoder.decode(AgentSession.self, from: data),
                session.sessionId == sessionId
            else { continue }
            return session
        }
        return nil
    }

    /// Every state file this app owns, decoded, paired with where it came from.
    ///
    /// Deliberately does **not** prune. `reload` deletes the files whose process
    /// is gone, which is right for the store and wrong for anything that only
    /// wants to look — `--doctor` reports the stale count, and a reporter that
    /// changed what it was reporting on would be lying about the machine it was
    /// asked to describe.
    ///
    /// `nonisolated` so a one-shot command can call it without a main actor.
    nonisolated static func loadStateFiles() -> [(session: AgentSession, file: URL)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        var loaded: [(session: AgentSession, file: URL)] = []
        for file in files where isOwnStateFile(file) {
            guard let data = try? Data(contentsOf: file),
                let session = try? decoder.decode(AgentSession.self, from: data)
            else { continue }
            loaded.append((session, file))
        }
        return loaded
    }

    /// `nonisolated` because it is two lines of `kill(2)` over no state, and a
    /// one-shot command has no main actor to hop to.
    nonisolated static func isProcessAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
