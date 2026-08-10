import Darwin
import Foundation

/// What Claude Code's statusline payload says about each live session.
///
/// Claude Code hook payloads carry neither a session name nor a context
/// reading (verified against v2.1.220), but the statusline payload carries
/// both: `{session_id, session_name, context_window: {used_percentage, …}, …}`.
/// Two files can hold one, and both are read: `~/.claude/statusline-last.json`,
/// which appears only if the user's own statusline script dumps its stdin
/// there, and the payload agent-tracker's own statusline wrapper saves, which
/// needs no cooperation from anyone's script.
///
/// Either is last-writer-wins **across sessions** — one session's payload at a
/// time — so this accumulates a per-session map rather than reading a snapshot.
/// That distinction is the whole reason this type exists: the file describes
/// whichever session rendered last, and reading it as if it described the row
/// in front of you would attribute one session's context to all of them. Every
/// active session's statusline refreshes constantly, so the map fills within a
/// minute of launch; sessions with neither file simply stay absent.
@MainActor
final class StatuslineDirectory {
    /// One session's facts, each independently optional: a payload carries what
    /// it carries, and an unnamed session is still a session with a context
    /// reading worth keeping.
    struct Entry: Equatable {
        var sessionId: String
        var name: String?
        /// 0-100, how full this session's context window is.
        var contextUsedPercent: Double?
    }

    private(set) var titles: [String: String] = [:]
    private(set) var contextUsedPercent: [String: Double] = [:]
    private let directory: URL
    private let sources: [URL]
    private var watcher: DirectoryWatcher?
    private var watchedInode: UInt64?

    nonisolated static let defaultDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_CLAUDE_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()

    init(directory: URL = defaultDirectory, capture: URL = SessionStore.claudeStatuslineURL) {
        self.directory = directory
        // Read in order, so the last one wins for a session both describe. The
        // capture goes last because it is the one we know is current: a
        // `statusline-last.json` can be a leftover from a tee the user has since
        // removed, and it would then hold a name that never updates again.
        sources = [directory.appendingPathComponent("statusline-last.json"), capture]
        refresh()
    }

    func title(for sessionId: String) -> String? {
        titles[sessionId]
    }

    /// How full this session's context window is, 0-100, when it has ever been
    /// reported.
    func contextUsedPercent(for sessionId: String) -> Double? {
        contextUsedPercent[sessionId]
    }

    /// Re-arms the watcher when needed, then absorbs the latest payload.
    /// Called from every SessionStore reload tick, not just init: the watcher
    /// alone is not enough — it can never arm (directory missing at launch),
    /// die silently (directory deleted and recreated; the vnode source tracks
    /// the original inode), or never fire (statusline scripts that rewrite
    /// the file in place instead of atomic-renaming into it). Polling bounds
    /// all three failure modes to one tick, and it is the only thing covering
    /// the wrapper's capture, which lives outside the watched directory.
    func refresh() {
        armWatcherIfNeeded()
        absorbLatest()
    }

    private func armWatcherIfNeeded() {
        var status = stat()
        guard stat(directory.path, &status) == 0 else {
            watcher = nil
            watchedInode = nil
            return
        }
        let inode = UInt64(status.st_ino)
        guard watcher == nil || inode != watchedInode else { return }
        // Watch the directory, not the file: the payload is usually replaced
        // atomically (write-to-tmp + rename), so a descriptor on the file
        // itself would go stale after the first swap.
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            self?.absorbLatest()
        }
        watchedInode = watcher == nil ? nil : inode
    }

    func absorbLatest() {
        for url in sources {
            guard let data = try? Data(contentsOf: url), let entry = Self.parse(data) else {
                continue
            }
            // Field by field, never wholesale: a payload that reports a name
            // and no context must not erase a context reading the previous one
            // carried for that same session.
            if let name = entry.name { titles[entry.sessionId] = name }
            if let used = entry.contextUsedPercent {
                contextUsedPercent[entry.sessionId] = used
            }
        }
    }

    /// Pure: extracts what one statusline payload says about its session.
    /// Payloads with no session id at all (foreign schemas) map to nil.
    nonisolated static func parse(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = object["session_id"] as? String, !sessionId.isEmpty
        else { return nil }
        let name = object["session_name"] as? String
        let context = object["context_window"] as? [String: Any]
        // Integers on every payload measured here, but a percentage is a
        // percentage — `as? Double` reads either form. Out-of-range values are
        // dropped rather than clamped: a number outside 0-100 means this is not
        // the field we think it is.
        let used = (context?["used_percentage"] as? Double).flatMap {
            (0...100).contains($0) ? $0 : nil
        }
        return Entry(
            sessionId: sessionId,
            name: (name?.isEmpty == false) ? name : nil,
            contextUsedPercent: used)
    }
}
