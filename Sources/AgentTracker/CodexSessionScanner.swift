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

    init(rootDirectory: URL? = nil) {
        let worker = CodexScanWorker(root: rootDirectory ?? Self.defaultRootDirectory)
        self.worker = worker
        worker.onUpdate = { [weak self] sessions, threadMap in
            Task { @MainActor in
                guard let self else { return }
                if self.sessions != sessions { self.sessions = sessions }
                if self.threadIdToSession != threadMap { self.threadIdToSession = threadMap }
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

    /// Called with fresh session rows + threadId→sessionId map after every change.
    var onUpdate: (([AgentSession], [String: String]) -> Void)?

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start() {
        queue.async { self.startLocked() }
    }

    func refresh() {
        queue.async {
            if self.started {
                if self.stream == nil {
                    // FSEvents unavailable — degrade to rescanning on the timer.
                    self.scanDayDirectoriesLocked()
                }
                // Heal missed/coalesced FSEvents even with a live stream: stat
                // every tracked file and read any growth (reads happen only
                // when the size actually moved past our offset). Snapshot the
                // keys — processFileLocked mutates trackers.
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
        startStreamLocked()
        publishLocked()
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(date))
    }

    private func debugLog(_ message: String) {
        #if DEBUG
            print("[codex-scan] \(message)")
        #endif
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
        let calendar = Calendar.current
        let now = Date()
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now) ?? now]
        for day in days {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let directory =
                root
                .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                .appendingPathComponent(String(format: "%02d", components.day ?? 0))
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
                }
            }
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
        for tracker in trackers.values {
            guard let meta = tracker.accumulator.meta,
                produced.contains(meta.sessionId)
            else { continue }
            threadIdToSession[meta.sessionId] = meta.sessionId
            if let threadId = meta.threadId { threadIdToSession[threadId] = meta.sessionId }
        }
        onUpdate?(sessions, threadIdToSession)
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
