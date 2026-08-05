import CoreServices
import Darwin
import Foundation

/// Derives live Codex session state by watching rollout files under
/// `~/.codex/sessions` directly (Codex has no turn-start hook, so state files
/// alone can never show "running"). Read-only: never writes under ~/.codex.
@MainActor
final class CodexSessionScanner: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Maps session ids AND per-file thread ids to the stable session_id of the
    /// published session they belong to. The notify hook's "thread-id" may be a
    /// thread id rather than the stable session_id, so SessionStore resolves
    /// state-file rows through this map — both to dedupe them and to graft
    /// their enrichment (termProgram) onto the right scanner row. Only threads
    /// of groups that actually produced a session are listed, so a notify
    /// fallback row is never deduped without a replacement.
    @Published private(set) var threadIdToSession: [String: String] = [:]
    /// Every thread id ever identified as a subagent (sticky — see
    /// CodexSubagentLedger). SessionStore drops (and deletes) notify state
    /// files for these: they are internal fan-out, never user-facing sessions.
    @Published private(set) var subagentThreadIds: Set<String> = []
    /// Rate-limit readings seen across the tracked rollouts. Account-wide, so
    /// `SessionStore` folds them into one slot per provider.
    @Published private(set) var usageLimits: [UsageLimit] = []

    static var defaultRootDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_CODEX_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }

    private let worker: CodexScanWorker
    private var livenessTimer: Timer?

    /// Re-reads tracked rollouts. Driven by `SessionStore`'s refresh tick so
    /// Codex state tracks the same cadence the user picked in Settings.
    func refreshFiles() {
        worker.refreshFiles()
    }

    init(rootDirectory: URL? = nil) {
        let worker = CodexScanWorker(root: rootDirectory ?? Self.defaultRootDirectory)
        self.worker = worker
        worker.onUpdate = { [weak self] sessions, threadMap, subagentIds, limits in
            Task { @MainActor in
                guard let self else { return }
                if self.sessions != sessions { self.sessions = sessions }
                if self.threadIdToSession != threadMap { self.threadIdToSession = threadMap }
                if self.subagentThreadIds != subagentIds { self.subagentThreadIds = subagentIds }
                if self.usageLimits != limits { self.usageLimits = limits }
            }
        }
        worker.start()
        // Liveness re-check cadence; also retries startup if the root directory
        // appears later.
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            worker.refresh()
        }
    }

    deinit {
        livenessTimer?.invalidate()
        worker.stop()
    }
}

/// Off-main-thread engine: FSEvents watching, incremental parsing, and lsof
/// liveness. All mutable state is confined to `queue`.
final class CodexScanWorker: @unchecked Sendable {
    private struct FileTracker {
        var accumulator: CodexThreadAccumulator
        /// Byte offset up to which complete lines have been consumed.
        var offset: UInt64
        /// File mtime at last observation.
        var lastActivity: Date
    }

    /// mtime-keyed grace for files lsof has never reported as held — covers
    /// the create→open race; older un-held rollouts prune on the first pass.
    private static let newFileGrace: TimeInterval = 45

    private let root: URL
    private let queue = DispatchQueue(label: "agent-tracker.codex-scanner")
    private var started = false
    private var stream: FSEventStreamRef?
    private var trackers: [String: FileTracker] = [:]
    /// rolloutPath -> pid of the codex process holding it open (last lsof pass).
    private var holders: [String: Int] = [:]

    /// Called with fresh session rows + threadId→sessionId map + sticky
    /// subagent thread ids after every change.
    var onUpdate: (([AgentSession], [String: String], Set<String>, [UsageLimit]) -> Void)?
    private let subagentLedger = CodexSubagentLedger()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start() {
        queue.async { self.startLocked() }
    }

    /// Cheap pass: stat every tracked file and read any growth. Runs at the
    /// store's refresh cadence (1s by default) because **FSEvents does not
    /// reliably report appends to these rollouts** — measured: a `task_started`
    /// written to a held-open rollout was invisible until the next 30s
    /// liveness pass, 22s later. Rather than trust the stream, poll: a stat
    /// per tracked file costs nothing, and reads happen only when the size
    /// actually moved past our offset.
    func refreshFiles() {
        queue.async {
            guard self.started else {
                self.startLocked()  // root directory may have appeared since
                return
            }
            // Snapshot the keys — processFileLocked mutates trackers.
            for path in Array(self.trackers.keys) { self.processFileLocked(path) }
            self.publishLocked()
        }
    }

    /// Full pass: the file poll above plus the expensive `lsof` liveness
    /// check, which is what prunes dead sessions and adopts rollouts from
    /// older day-directories. Stays on its own slow timer.
    func refresh() {
        queue.async {
            if self.started {
                if self.stream == nil {
                    // FSEvents unavailable — degrade to rescanning on the timer.
                    self.scanDayDirectoriesLocked()
                }
                for path in Array(self.trackers.keys) { self.processFileLocked(path) }
                self.refreshLivenessLocked()
                self.publishLocked()
            } else {
                self.startLocked()  // root directory may have appeared since
            }
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    // MARK: - Lifecycle (on queue)

    private func startLocked() {
        guard !started else { return }
        var isDirectory: ObjCBool = false
        // Missing root -> inert: no errors, empty output. refresh() retries.
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return }
        started = true
        let startedAt = Date()
        // Liveness FIRST: lsof tells us which rollouts are actually held open
        // (live sessions, any day-directory), so the day scan afterwards only
        // has to cover just-created files — not bootstrap-and-discard hundreds
        // of dead rollouts from a busy day.
        refreshLivenessLocked()
        let held = "\(trackers.count) tracker(s), \(holders.count) held"
        debugLog("first liveness done: \(held), after \(Self.elapsed(since: startedAt))")
        scanDayDirectoriesLocked()
        debugLog(
            "day scan done: \(trackers.count) tracker(s) after \(Self.elapsed(since: startedAt))")
        harvestHistoryLocked()
        debugLog(
            "history harvest done: \(subagentLedger.threadIds.count) subagent id(s) "
                + "after \(Self.elapsed(since: startedAt))")
        startStreamLocked()
        publishLocked()
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(date))
    }

    private func debugLog(_ message: String) {
        DebugLog.log("[codex-scan] \(DebugLog.timestamp()) \(message)")
    }

    private func stopLocked() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        started = false
    }

    // MARK: - FSEvents

    private func startStreamLocked() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        // The stream callback holds an unretained reference to self; safe
        // because stopLocked() invalidates the stream before self can go away
        // (stop() retains self until it runs).
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                codexScanEventCallback,
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3,
                flags
            )
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Called on `queue` (the stream's dispatch queue).
    fileprivate func handleEvents(paths: [String]) {
        var changed = false
        var sawNonRollout = false
        for path in paths {
            if path.hasSuffix(".jsonl") {
                processFileLocked(path)
                changed = true
            } else {
                // Directory paths arrive when the kernel coalesces events
                // (kFSEventStreamEventFlagMustScanSubDirs) — rescan rather
                // than drop them.
                sawNonRollout = true
            }
        }
        if sawNonRollout {
            scanDayDirectoriesLocked()
            changed = true
        }
        if changed { publishLocked() }
    }

    // MARK: - Scanning and incremental reads (on queue)

    /// Scans today's and yesterday's day-directories for rollouts worth
    /// tracking. Only RECENTLY MODIFIED files are bootstrapped here — they
    /// cover the create→open race before lsof sees a new session. Everything
    /// older is either held open (bootstrapped via refreshLivenessLocked) or
    /// dead (would be bootstrapped then immediately pruned; a busy day leaves
    /// hundreds of those, and parsing them cost ~8s of startup).
    private func scanDayDirectoriesLocked() {
        let now = Date()
        for directory in Self.dayDirectories(under: root, endingAt: now, count: 2) {
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
                )
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let path = file.standardizedFileURL.path
                guard trackers[path] == nil, holders[path] == nil else { continue }
                let mtime =
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(mtime) <= Self.newFileGrace {
                    bootstrapLocked(path: path)
                } else {
                    // Dead rollout, never bootstrapped — but if it was a
                    // subagent thread, its notify state file may outlive it.
                    subagentLedger.harvest(path: path)
                }
            }
        }
    }

    /// One-time first-line harvest of subagent ids from day-directories older
    /// than the two the regular scan covers: a notify state file survives as
    /// long as its ROOT codex process, and root sessions can live for weeks —
    /// after an app restart, their older subagents' phantom rows would
    /// otherwise be unidentifiable. Harvest-only (no bootstrap), walking
    /// however many day-directories exist newest-first under a work budget
    /// (not a calendar window, which a long-lived root can always outlive);
    /// the ledger memoizes per-path so this cannot re-read.
    private static let historicalHarvestFileCap = 5000

    private func harvestHistoryLocked() {
        let recent = Set(Self.dayDirectories(under: root, endingAt: Date(), count: 2).map(\.path))
        var remaining = Self.historicalHarvestFileCap
        for directory in Self.existingDayDirectories(under: root)
        where !recent.contains(directory.path) {
            guard remaining > 0 else { break }
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard remaining > 0 else { break }
                remaining -= 1
                subagentLedger.harvest(path: file.standardizedFileURL.path)
            }
        }
    }

    /// Every `root/YYYY/MM/DD` directory that exists, newest first; non-numeric
    /// entries are ignored. Internal for tests.
    static func existingDayDirectories(under root: URL) -> [URL] {
        func numericChildren(of url: URL) -> [URL] {
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? []
            return
                children
                .compactMap { child in Int(child.lastPathComponent).map { ($0, child) } }
                .sorted { $0.0 > $1.0 }
                .map(\.1)
        }
        var days: [URL] = []
        for year in numericChildren(of: root) {
            for month in numericChildren(of: year) {
                days.append(contentsOf: numericChildren(of: month))
            }
        }
        return days
    }

    /// The `root/YYYY/MM/DD` directories for `count` days, newest first.
    /// Internal for tests.
    static func dayDirectories(
        under root: URL, endingAt end: Date, count: Int, calendar: Calendar = .current
    ) -> [URL] {
        (0..<count).compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: end) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            return
                root
                .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                .appendingPathComponent(String(format: "%02d", components.day ?? 0))
        }
    }

    private func bootstrapLocked(path: String) {
        guard let result = CodexThreadAccumulator.bootstrap(url: URL(fileURLWithPath: path)) else {
            trackers.removeValue(forKey: path)
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attributes?[.modificationDate] as? Date ?? Date()
        trackers[path] = FileTracker(
            accumulator: result.accumulator, offset: result.offset, lastActivity: mtime
        )
    }

    private func processFileLocked(_ path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            trackers.removeValue(forKey: path)  // deleted
            return
        }
        let mtime = attributes[.modificationDate] as? Date ?? Date()

        guard var tracker = trackers[path] else {
            bootstrapLocked(path: path)
            return
        }
        if tracker.offset > size {
            // Truncation — shouldn't happen for append-only rollouts; recover.
            bootstrapLocked(path: path)
            return
        }
        if size > tracker.offset {
            if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
                (try? handle.seek(toOffset: tracker.offset)) != nil
            {
                let data = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                // Only complete lines; a partially written trailing line stays
                // unconsumed until its newline arrives.
                let (lines, consumed) = CodexRolloutParser.completeLines(in: data)
                for line in lines { tracker.accumulator.consume(line: line) }
                tracker.offset += UInt64(consumed)
            }
        }
        tracker.lastActivity = mtime
        trackers[path] = tracker
    }

    // MARK: - Liveness (on queue)

    private func refreshLivenessLocked() {
        // "-c codex" prefix-matches both the vendor binary and
        // codex-code-mode-host. A pass counts as authoritative only when it
        // reported at least one process record — lsof exits nonzero with empty
        // output for transient reasons, and trusting that would wrongly prune
        // every live session at once.
        if let output = ProcessProbe.run(
            "/usr/sbin/lsof", ["-c", "codex", "-F", "pn"], timeout: 5),
            output.hasPrefix("p") || output.contains("\np")
        {
            let previouslyHeld = Set(holders.keys)
            holders = ProcessProbe.parseLsofOutput(output, rootPath: root.path)
            debugLog("lsof pass: \(holders.count) held rollout(s)")
            // Held files we aren't tracking yet: live sessions whose rollout
            // lives in an older day-directory.
            for path in holders.keys where trackers[path] == nil {
                bootstrapLocked(path: path)
            }
            let pruneCountBefore = trackers.count
            pruneDeadLocked(previouslyHeld: previouslyHeld)
            if trackers.count != pruneCountBefore {
                debugLog("pruned \(pruneCountBefore - trackers.count) dead tracker(s)")
            }
        } else {
            debugLog("lsof pass unusable — degraded mode (pgrep gate)")
            // lsof errored or timed out. Degraded mode: pgrep tells us whether
            // ANY codex process is alive — if none, drop all codex sessions;
            // otherwise keep the current set unchanged (possibly stale until
            // lsof recovers on a later refresh).
            // Prefix regex mirrors lsof's "-c codex": matches the vendor
            // binary and auxiliaries like codex-code-mode-host.
            if let output = ProcessProbe.run("/usr/bin/pgrep", ["^codex"], timeout: 5),
                output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                trackers.removeAll()
                holders.removeAll()
            }
        }
    }

    /// Previously-held files that are un-held now mean their codex process
    /// exited — dropped immediately. Never-held files get a short mtime-keyed
    /// grace for the create→open race.
    private func pruneDeadLocked(previouslyHeld: Set<String>) {
        let now = Date()
        var dead: [String] = []
        for path in trackers.keys where holders[path] == nil {
            if previouslyHeld.contains(path) {
                dead.append(path)
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let mtime = attributes[.modificationDate] as? Date
            else {
                dead.append(path)  // file gone
                continue
            }
            if now.timeIntervalSince(mtime) > Self.newFileGrace {
                dead.append(path)
            }
        }
        for path in dead { trackers.removeValue(forKey: path) }
    }

    // MARK: - Publishing (on queue)

    private func publishLocked() {
        var snapshots: [CodexThreadSnapshot] = []
        for (path, tracker) in trackers {
            snapshots.append(
                CodexThreadSnapshot(
                    accumulator: tracker.accumulator,
                    fileActivityAt: tracker.lastActivity,
                    holderPid: holders[path]
                ))
        }
        let sessions = CodexSessionGrouper.sessions(from: snapshots)

        // Map thread ids only for groups that produced a session — a group
        // that emitted nothing (e.g. subagent-only) must not cause dedupe of
        // its notify fallback row.
        let produced = Set(sessions.map(\.sessionId))
        var threadIdToSession: [String: String] = [:]
        for (path, tracker) in trackers {
            guard let meta = tracker.accumulator.meta else { continue }
            let fileThreadId = CodexRolloutParser.threadId(fromRolloutFilename: path)
            subagentLedger.record(meta, fileThreadId: fileThreadId)
            guard produced.contains(meta.sessionId) else { continue }
            threadIdToSession[meta.sessionId] = meta.sessionId
            if let threadId = meta.threadId { threadIdToSession[threadId] = meta.sessionId }
            if let fileThreadId { threadIdToSession[fileThreadId] = meta.sessionId }
        }
        // Every thread's newest reading. Account-wide, so the store merges
        // them into one slot per provider rather than attaching them to rows.
        let usageLimits = snapshots.compactMap(\.accumulator.usageLimit)
        onUpdate?(sessions, threadIdToSession, subagentLedger.threadIds, usageLimits)
    }

}

/// C callback for the FSEvent stream; runs on the worker's dispatch queue.
private let codexScanEventCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let worker = Unmanaged<CodexScanWorker>.fromOpaque(info).takeUnretainedValue()
    guard
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            as? [String]
    else { return }
    worker.handleEvents(paths: paths)
}
