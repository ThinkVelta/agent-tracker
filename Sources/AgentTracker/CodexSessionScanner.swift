import CoreServices
import Darwin
import Foundation

/// Derives live Codex session state by watching rollout files under
/// `~/.codex/sessions` directly (Codex has no turn-start hook, so state files
/// alone can never show "running"). Read-only: never writes under ~/.codex.
@MainActor
final class CodexSessionScanner: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Session ids AND per-file thread ids of every tracked thread. The notify
    /// hook's "thread-id" may be a thread id rather than the stable session_id,
    /// so SessionStore dedupes state-file rows against this whole set.
    @Published private(set) var knownThreadIds: Set<String> = []

    static var defaultRootDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_CODEX_DIR"],
           !override.isEmpty {
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
        worker.onUpdate = { [weak self] sessions, threadIds in
            Task { @MainActor in
                guard let self else { return }
                if self.sessions != sessions { self.sessions = sessions }
                if self.knownThreadIds != threadIds { self.knownThreadIds = threadIds }
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
        /// File mtime at last observation — grace-period input and updatedAt.
        var lastActivity: Date
    }

    /// Grace period before an un-held, quiet file's thread is considered dead —
    /// covers lsof staleness between 30s refreshes.
    private static let deadFileGrace: TimeInterval = 5 * 60

    private let root: URL
    private let queue = DispatchQueue(label: "agent-tracker.codex-scanner")
    private var started = false
    private var stream: FSEventStreamRef?
    private var trackers: [String: FileTracker] = [:]
    /// rolloutPath -> pid of the codex process holding it open (last lsof pass).
    private var holders: [String: Int] = [:]

    /// Called with fresh session rows + known thread ids after every change.
    var onUpdate: (([AgentSession], Set<String>) -> Void)?

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
                    for path in self.trackers.keys { self.processFileLocked(path) }
                }
                self.refreshLivenessLocked()
                self.publishLocked()
            } else {
                self.startLocked() // root directory may have appeared since
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
              isDirectory.boolValue else { return }
        started = true
        scanDayDirectoriesLocked()
        refreshLivenessLocked() // also bootstraps lsof-held files (multi-day sessions)
        startStreamLocked()
        publishLocked()
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
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            codexScanEventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Called on `queue` (the stream's dispatch queue).
    fileprivate func handleEvents(paths: [String]) {
        var changed = false
        for path in paths where path.hasSuffix(".jsonl") {
            processFileLocked(path)
            changed = true
        }
        if changed { publishLocked() }
    }

    // MARK: - Scanning and incremental reads (on queue)

    /// Initial scan: today's and yesterday's day-directories. Multi-day live
    /// sessions are picked up via lsof-held files in refreshLivenessLocked().
    private func scanDayDirectoriesLocked() {
        let calendar = Calendar.current
        let now = Date()
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now) ?? now]
        for day in days {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = root
                .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                .appendingPathComponent(String(format: "%02d", components.day ?? 0))
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let path = file.standardizedFileURL.path
                if trackers[path] == nil { bootstrapLocked(path: path) }
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
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            trackers.removeValue(forKey: path) // deleted
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
               (try? handle.seek(toOffset: tracker.offset)) != nil {
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
        // lsof matches process names by prefix, so "-c codex" covers both the
        // "codex" vendor binary and "codex-code-mode-host".
        if let output = Self.runProcess("/usr/sbin/lsof", ["-c", "codex", "-F", "pn"], timeout: 5) {
            holders = Self.parseLsofOutput(output, rootPath: root.path)
            // Held files we aren't tracking yet: live sessions whose rollout
            // lives in an older day-directory.
            for path in holders.keys where trackers[path] == nil {
                bootstrapLocked(path: path)
            }
            pruneDeadLocked()
        } else {
            // lsof errored or timed out. Degraded mode: pgrep tells us whether
            // ANY codex process is alive — if none, drop all codex sessions;
            // otherwise keep the current set unchanged (possibly stale until
            // lsof recovers on a later refresh).
            if let output = Self.runProcess("/usr/bin/pgrep", ["-x", "codex"], timeout: 5),
               output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trackers.removeAll()
                holders.removeAll()
            }
        }
    }

    private func pruneDeadLocked() {
        let now = Date()
        for (path, tracker) in trackers where holders[path] == nil {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                trackers.removeValue(forKey: path) // file gone
                continue
            }
            let mtime = attributes[.modificationDate] as? Date ?? tracker.lastActivity
            let lastActivity = max(mtime, tracker.lastActivity)
            if now.timeIntervalSince(lastActivity) > Self.deadFileGrace {
                trackers.removeValue(forKey: path)
            }
        }
    }

    /// Parses `lsof -F pn` output ("p<pid>" then "n<path>" lines) into
    /// {rolloutPath: pid} for .jsonl files under the watched root.
    static func parseLsofOutput(_ output: String, rootPath: String) -> [String: Int] {
        var result: [String: Int] = [:]
        var currentPid: Int?
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                currentPid = Int(value)
            case "n":
                if value.hasSuffix(".jsonl"), value.hasPrefix(prefix), let pid = currentPid {
                    result[value] = pid
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Publishing (on queue)

    private func publishLocked() {
        var snapshots: [CodexThreadSnapshot] = []
        var threadIds = Set<String>()
        for (path, tracker) in trackers {
            if let meta = tracker.accumulator.meta {
                threadIds.insert(meta.sessionId)
                if let threadId = meta.threadId { threadIds.insert(threadId) }
            }
            snapshots.append(CodexThreadSnapshot(
                accumulator: tracker.accumulator,
                fileActivityAt: tracker.lastActivity,
                holderPid: holders[path]
            ))
        }
        let sessions = CodexSessionGrouper.sessions(from: snapshots)
        onUpdate?(sessions, threadIds)
    }

    // MARK: - Process helper

    /// Runs a short-lived tool with a hard timeout, off the main thread.
    /// Returns stdout on normal termination (any exit code), nil on launch
    /// failure or timeout (the process is killed on expiry).
    private static func runProcess(
        _ launchPath: String, _ arguments: [String], timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Drain stdout on a separate queue so a large output can't deadlock the
        // pipe while we wait for termination.
        let buffer = ProcessOutputBuffer()
        let reader = DispatchQueue(label: "agent-tracker.codex-scanner.read")
        reader.async { buffer.data = stdout.fileHandleForReading.readDataToEndOfFile() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                kill(pid, SIGKILL) // hard kill if SIGTERM was ignored
            }
            return nil
        }
        reader.sync {} // wait for the drain to finish
        return String(data: buffer.data, encoding: .utf8)
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    var data = Data()
}

/// C callback for the FSEvent stream; runs on the worker's dispatch queue.
private let codexScanEventCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let worker = Unmanaged<CodexScanWorker>.fromOpaque(info).takeUnretainedValue()
    guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        as? [String] else { return }
    worker.handleEvents(paths: paths)
}
