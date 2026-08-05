import Darwin
import Foundation

/// Resolves a Claude Code session id to its exact terminal window title.
///
/// Claude Code hook payloads carry no session name (verified against
/// v2.1.220), but the statusline payload does: it holds
/// `{session_id, session_name, …}` where `session_name` is the window title
/// minus its leading status glyph. Two files can hold one, and both are read:
/// `~/.claude/statusline-last.json`, which appears only if the user's own
/// statusline script dumps its stdin there, and the payload agent-tracker's own
/// statusline wrapper saves, which needs no cooperation from anyone's script.
/// Either is last-writer-wins across sessions — one session's payload at a
/// time — so this directory accumulates an id → name map rather than reading a
/// snapshot; every active session's statusline refreshes constantly, so the map
/// fills within a minute of launch. Sessions with neither file simply stay
/// absent and `TerminalFocuser` falls back to its path-based candidates.
@MainActor
final class TitleDirectory {
    private(set) var titles: [String: String] = [:]
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
            titles[entry.sessionId] = entry.name
        }
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
