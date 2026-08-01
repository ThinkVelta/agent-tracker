import Darwin
import Foundation

/// Resolves a Claude Code session id to its exact terminal window title.
///
/// Claude Code hook payloads carry no session name (verified against
/// v2.1.220), but the statusline payload does: a statusline script that dumps
/// its stdin to `~/.claude/statusline-last.json` leaves behind
/// `{session_id, session_name, …}` where `session_name` is the window title
/// minus its leading status glyph. The file is last-writer-wins across
/// sessions — one session's payload at a time — so this directory watches it
/// and accumulates an id → name map; every active session's statusline
/// refreshes constantly, so the map fills within a minute of launch. Sessions
/// without statusline data simply stay absent and `TerminalFocuser` falls
/// back to its path-based candidates.
@MainActor
final class TitleDirectory {
    private(set) var titles: [String: String] = [:]
    private let directory: URL
    private let fileURL: URL
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

    init(directory: URL = defaultDirectory) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("statusline-last.json")
        refresh()
    }

    func title(for sessionId: String) -> String? {
        titles[sessionId]
    }

    /// Re-arms the watcher when needed, then absorbs the latest payload.
    /// Called from every SessionStore reload tick, not just init: the watcher
    /// alone is not enough — it can never arm (directory missing at launch),
    /// die silently (directory deleted and recreated; the vnode source tracks
    /// the original inode), or never fire (statusline scripts that rewrite
    /// the file in place instead of atomic-renaming into it). Polling bounds
    /// all three failure modes to one tick.
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
        guard let data = try? Data(contentsOf: fileURL),
            let entry = Self.parse(data)
        else { return }
        titles[entry.sessionId] = entry.name
    }

    /// Pure: extracts (session_id, session_name) from one statusline payload.
    /// Payloads without a name (unnamed sessions, foreign schemas) map to nil.
    nonisolated static func parse(_ data: Data) -> (sessionId: String, name: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = object["session_id"] as? String, !sessionId.isEmpty,
            let name = object["session_name"] as? String, !name.isEmpty
        else { return nil }
        return (sessionId, name)
    }
}
