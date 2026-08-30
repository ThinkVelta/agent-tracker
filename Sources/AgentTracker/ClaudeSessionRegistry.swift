import Foundation

/// Reads Claude Code's own per-process session registry, `~/.claude/sessions/<pid>.json`.
///
/// One file per live session. It is the only place that carries a session's
/// *name* — the slug the user sees in their own terminal ("api-gateway-02") — and
/// Claude's own activity status, neither of which any hook payload provides.
/// Strictly read-only: the directory belongs to Claude Code, which owns the
/// format and may change it, so every field is optional and anything
/// unrecognized is ignored rather than guessed at.
///
/// **The file is written on change, not on a heartbeat**, which is what
/// `statusUpdatedAt` means: the status has held this value *since* then.
/// Measured on 2.1.220 — a session busy for 14 minutes had not been rewritten
/// once in that time. Two consequences the enrichment rules depend on:
///
/// - a status is current however old its timestamp is, so age is not staleness
/// - the write trails the hook by ~600ms at both ends of a turn, so right after
///   a hook event the file still describes the *previous* state
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
        /// Claude's name for the session, e.g. "api-gateway-02".
        let name: String?
        /// Whether the user picked that name rather than Claude inventing it.
        ///
        /// Read from `nameSource`: `user`, `peer`, `derived`, `collision`,
        /// `auto` or `hook`, anything else normalized away to absent. The
        /// distinction is a whole feature: a name someone typed is worth
        /// showing, a generated slug only when two rows would be identical.
        ///
        /// **Absence does not mean "chosen"** — it only used to. Through
        /// 2.1.227 the rename path wrote `nameSource: void 0`, so an omitted
        /// field was the one mark a chosen name carried; by 2.1.251 rename
        /// writes the source through, and inferring from absence had every
        /// renamed session reading as a derived slug.
        ///
        /// So match the values Claude itself prints a name for — absent,
        /// `user`, `peer` — which keeps this in step with the user's own
        /// terminal and right for both spellings of a rename.
        let nameIsChosen: Bool
        let status: Status
        let statusUpdatedAt: Date?
        /// Claude's own words for what a `waiting` session is blocked on:
        /// "input needed", "sandbox request", "dialog open", "worker request",
        /// or a dialog's own label. Absent for every other status.
        let waitingFor: String?
    }

    /// Claude's own activity signal. The vocabulary is closed and complete —
    /// `["busy","shell","idle","waiting"]`, per the validator in 2.1.220 — but
    /// it is Claude's to change, so an unrecognized value maps to `.unknown`
    /// and expresses no opinion rather than being forced into a state.
    enum Status: Equatable {
        /// The model is generating, or delegated agents are active. Claude
        /// derives it as `isLoading || delegatedActive`, so a lead session
        /// whose teammates and subagents are doing the work reads busy.
        case busy
        /// The turn is over, but a background shell it started is still
        /// running, and the harness resumes the turn when that finishes.
        /// Derived by Claude as "idle AND an unfinished local_bash task".
        case shell
        /// A dialog is up and blocking on a human — permission, a sandbox
        /// request, an elicitation. `Entry.waitingFor` says which.
        case waiting
        case idle
        case unknown

        init(raw: String?) {
            switch raw?.lowercased() {
            case "busy": self = .busy
            case "shell": self = .shell
            case "idle": self = .idle
            case "waiting": self = .waiting
            default: self = .unknown
            }
        }

        /// Whether work is still outstanding, whoever is doing it: the model,
        /// a delegated agent, or a background shell after the turn ended.
        /// Claude Code's own `/agents` JSON collapses `shell` into `busy` for
        /// exactly this reason. `.unknown` is not an answer, so callers must
        /// handle nil.
        var isWorking: Bool? {
            switch self {
            case .busy, .shell: return true
            case .idle, .waiting: return false
            case .unknown: return nil
            }
        }
    }

    private(set) var entries: [String: Entry] = [:]
    private let directory: URL
    private var watcher: DirectoryWatcher?
    private var watchedInode: UInt64?

    /// Lives under the same `~/.claude` root as `StatuslineDirectory`, and honors
    /// the same override so tests and previews stay hermetic.
    init(claudeDirectory: URL = StatuslineDirectory.defaultDirectory) {
        directory = claudeDirectory.appendingPathComponent("sessions")
        refresh()
    }

    func entry(forSessionId sessionId: String) -> Entry? {
        entries[sessionId]
    }

    /// Re-arms the watcher when needed, then reloads. Called from every
    /// SessionStore reload tick rather than relying on the watcher alone — for
    /// the same three reasons spelled out in `StatuslineDirectory.refresh()`: the
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
        // An unrecognized value is not chosen: this decides whether to put a
        // name on every row, and inventing a reason to do that from a string
        // nobody has seen is the wrong way to be wrong.
        let source = object["nameSource"]
        let nameIsChosen = name != nil && Self.sourceMeansChosen(source)
        let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Entry(
            sessionId: sessionId,
            pid: object["pid"] as? Int,
            cwd: cwd,
            name: name,
            nameIsChosen: nameIsChosen,
            status: Status(raw: object["status"] as? String),
            statusUpdatedAt: Self.date(from: object["statusUpdatedAt"]),
            waitingFor: (object["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Claude's own rule for a name worth printing, read off the binary rather
    /// than a parallel one invented here. See `Entry.nameIsChosen`.
    private nonisolated static func sourceMeansChosen(_ source: Any?) -> Bool {
        if source == nil || source is NSNull { return true }
        guard let source = source as? String else { return false }
        return source == "user" || source == "peer"
    }

    /// Timestamps are epoch milliseconds.
    private nonisolated static func date(from value: Any?) -> Date? {
        guard let milliseconds = value as? Double, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
