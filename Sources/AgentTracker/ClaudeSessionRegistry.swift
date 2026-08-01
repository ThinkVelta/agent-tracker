import Foundation

/// Reads Claude Code's own per-process session registry, `~/.claude/sessions/<pid>.json`.
///
/// Claude Code rewrites one file per live session every few seconds. It is the
/// only place that carries a session's *name* — the slug the user sees in their
/// own terminal ("planner-e8") — and Claude's own busy/idle signal, neither of
/// which any hook payload provides. Strictly read-only: the directory belongs to
/// Claude Code, which owns the format and may change it, so every field is
/// optional and anything unrecognized is ignored rather than guessed at.
@MainActor
final class ClaudeSessionRegistry {
    struct Entry: Equatable {
        let sessionId: String
        let pid: Int?
        /// Where the session's *terminal* is. Deliberately kept separate from
        /// the hook's cwd, which reports where the agent is working — for a
        /// session driving a worktree the two genuinely differ, and each is
        /// right for a different job (see `AgentSession.windowDirectories`).
        let cwd: String?
        /// Claude's derived session slug, e.g. "planner-e8".
        let name: String?
        let status: Status
        let statusUpdatedAt: Date?
    }

    /// Claude's own activity signal. Values seen in the wild: busy, idle,
    /// waiting. Anything else maps to `.unknown` and expresses no opinion —
    /// this field is not ours and can grow new cases at any time.
    enum Status: Equatable {
        case busy
        case idle
        case waiting
        case unknown

        init(raw: String?) {
            switch raw?.lowercased() {
            case "busy": self = .busy
            case "idle": self = .idle
            case "waiting": self = .waiting
            default: self = .unknown
            }
        }

        /// Whether Claude considers the session to be working right now.
        /// `.unknown` is not an answer, so callers must handle nil.
        var isBusy: Bool? {
            switch self {
            case .busy: return true
            case .idle, .waiting: return false
            case .unknown: return nil
            }
        }
    }

    private(set) var entries: [String: Entry] = [:]
    private let directory: URL
    private var watcher: DirectoryWatcher?
    private var watchedInode: UInt64?

    /// Lives under the same `~/.claude` root as `TitleDirectory`, and honors
    /// the same override so tests and previews stay hermetic.
    init(claudeDirectory: URL = TitleDirectory.defaultDirectory) {
        directory = claudeDirectory.appendingPathComponent("sessions")
        refresh()
    }

    func entry(forSessionId sessionId: String) -> Entry? {
        entries[sessionId]
    }

    /// Re-arms the watcher when needed, then reloads. Called from every
    /// SessionStore reload tick rather than relying on the watcher alone — for
    /// the same three reasons spelled out in `TitleDirectory.refresh()`: the
    /// directory may not exist at launch, may be recreated under a new inode,
    /// or may be rewritten in place without a rename event.
    func refresh() {
        armWatcherIfNeeded()
        reload()
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
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watchedInode = watcher == nil ? nil : inode
    }

    private func reload() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else {
            entries = [:]
            return
        }
        var loaded: [String: Entry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = Self.parse(data) else {
                continue
            }
            // Claude Code leaves a file behind when a session dies without a
            // clean exit; a dead pid means the row is a ghost.
            if let pid = entry.pid, pid > 0, !SessionStore.isProcessAlive(pid) { continue }
            loaded[entry.sessionId] = entry
        }
        entries = loaded
    }

    /// Pure: one registry payload to an entry. Anything without a session id is
    /// unusable; every other field is optional.
    nonisolated static func parse(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = object["sessionId"] as? String, !sessionId.isEmpty
        else { return nil }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Entry(
            sessionId: sessionId,
            pid: object["pid"] as? Int,
            cwd: cwd,
            name: name,
            status: Status(raw: object["status"] as? String),
            statusUpdatedAt: Self.date(from: object["statusUpdatedAt"])
        )
    }

    /// Timestamps are epoch milliseconds.
    private nonisolated static func date(from value: Any?) -> Date? {
        guard let milliseconds = value as? Double, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
