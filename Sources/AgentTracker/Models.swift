import Foundation
import SwiftUI

enum SessionState: String, Codable, CaseIterable {
    case needsYou
    case running
    case idle

    var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .running: return 1
        case .idle: return 2
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return .red
        case .running: return .green
        case .idle: return .gray
        }
    }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .idle: return "Idle"
        }
    }

    /// Shown when this state is filtered to and nothing is in it. Written per
    /// state because the labels do not survive a template — "Nothing is needs
    /// you" — and because an empty needs-you list is good news, not an error.
    var emptyListMessage: String {
        switch self {
        case .needsYou: return "Nothing needs you right now"
        case .running: return "Nothing is running"
        case .idle: return "No sessions are idle"
        }
    }
}

/// How a session's terminal pane can be recognized, captured by the hook from
/// the session's own environment.
///
/// Collected there because it is free at hook time and unrecoverable later: a
/// terminal cannot generally be asked "which pane holds pid N", and several of
/// these fields ARE the pane handle its own API takes. Whatever is absent stays
/// absent — the shape differs per terminal, and none of it is guaranteed.
struct TerminalIdentity: Codable, Equatable {
    /// The agent process's controlling terminal, e.g. `/dev/ttys003`. The
    /// bridge to every terminal that reports a per-pane tty.
    var tty: String?
    /// `TERM`. The only thing that identifies kitty, which sets no
    /// `TERM_PROGRAM` at all.
    var term: String?
    /// Set inside tmux. The decisive "this is a multiplexer pane" signal: it
    /// outranks `term` and `termProgram`, which a pane inherits from the tmux
    /// server and which can therefore name the wrong host, or a dead one.
    var tmux: String?
    var tmuxPane: String?
    var weztermPane: String?
    var kittyWindowId: String?
    var kittyListenOn: String?
    var itermSessionId: String?
    var termSessionId: String?
    var alacrittyWindowId: String?
}

struct AgentSession: Codable, Identifiable, Equatable {
    var schema: Int?
    var provider: String
    var sessionId: String
    var pid: Int?
    var cwd: String?
    var state: SessionState
    var reason: String?
    var lastEvent: String?
    var updatedAt: Date?
    var stateChangedAt: Date?
    var transcriptPath: String?
    var termProgram: String?
    var lastMessage: String?
    /// Which mechanism wrote this row: `"hook"` for a lifecycle hook, `"notify"`
    /// for Codex's legacy turn-complete callback. Only Codex has two, and only
    /// `CodexMerge` reads it — a hook watched the whole session, so its state
    /// outranks anything derived from a rollout file after the fact.
    var origin: String?
    /// The mode the agent is running in, as its hook reported it. For Codex
    /// this is the only source: it publishes no transcript for the app to read
    /// one out of, and `ContinueDelivery` treats an absent mode as permitted.
    var permissionMode: String?
    /// Which terminal pane the session occupies, as the hook found it. Every
    /// field is optional: it depends on the terminal, and sessions the Codex
    /// scanner discovers never had a hook run at all.
    var terminal: TerminalIdentity?

    // Set by the store when loading; not part of the on-disk schema.
    var fileURL: URL?
    /// Claude Code's own name for this session ("planner-e8") — the slug the
    /// user sees in their own terminal. Joined in from the session registry.
    var registryName: String?
    /// Where the session's terminal is, per the registry. Differs from `cwd`
    /// when the agent works in a subdirectory such as a worktree.
    var registryCwd: String?

    private enum CodingKeys: String, CodingKey {
        case schema, provider, sessionId, pid, cwd, state, reason, lastEvent
        case updatedAt, stateChangedAt, transcriptPath, termProgram, lastMessage
        case terminal, origin, permissionMode
    }

    var id: String { "\(provider)-\(sessionId)" }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Session" }
        return (cwd as NSString).lastPathComponent
    }

    /// What the row is titled: the working directory, for every provider.
    ///
    /// This deliberately ignores `registryName`. Only Claude Code publishes
    /// one, so preferring it made the list inconsistent — Claude rows read
    /// "agent-tracker-13" while Codex rows beside them read "agent-tracker" —
    /// and the suffix Claude appends is disambiguation noise rather than
    /// information the user recognizes. One rule for both providers reads
    /// better than a better rule for one of them.
    ///
    /// The registry name stays searchable (it is what Claude shows in its own
    /// terminal), as does the full path.
    ///
    /// The *project*, not the leaf directory: a session in a worktree lives at
    /// `…/planner-backend/.claude/worktrees/ruben-pln-396-live-…-8419e2f7`, and
    /// titling it with that generated name made worktree rows read as noise
    /// beside plain ones. Same rule for both providers, wildly different
    /// results — which is what "Planner" sitting next to
    /// "ruben-pln-396-live-…" looked like.
    var displayName: String {
        Self.projectAndWorktree(of: primaryDirectory)?.project ?? "Session"
    }

    /// The project a path belongs to, plus the worktree beneath it when the
    /// path runs through tool scaffolding. The worktree directory distinguishes
    /// a session from its siblings; it is not what the session should be
    /// called.
    static func projectAndWorktree(of path: String?) -> (project: String, worktree: String?)? {
        guard let path, !path.isEmpty else { return nil }
        var parts = (path as NSString).pathComponents.filter { $0 != "/" }
        guard let leaf = parts.popLast() else { return nil }
        guard let enclosing = parts.last, namesNoProject(enclosing) else { return (leaf, nil) }
        while let last = parts.last, namesNoProject(last) {
            parts.removeLast()
        }
        guard let project = parts.last else { return (leaf, nil) }
        return (project, leaf)
    }

    /// The directory this session is presented as living in: the hook's, or
    /// the registry's when no hook event has carried one. Everything the user
    /// reads — title, location, tooltip, accessibility label, path search —
    /// resolves through here, so a row with only one of the two never loses
    /// half its context.
    var primaryDirectory: String? {
        if let cwd, !cwd.isEmpty { return cwd }
        guard let registryCwd, !registryCwd.isEmpty else { return nil }
        return registryCwd
    }

    /// Directories any of this session's terminal windows might report, most
    /// specific first. Both are needed: the hook records where the *agent* is
    /// working, the registry where its *terminal* is, and for a session driving
    /// a worktree those are different paths — matching only the first would
    /// miss the window entirely.
    var windowDirectories: [String] {
        [cwd, registryCwd].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// Short path context shown alongside the project name, e.g. "ProjectsVelta/Planner".
    var pathContext: String? {
        Self.pathContext(of: cwd)
    }

    static func pathContext(of path: String?) -> String? {
        guard let path else { return nil }
        let parts = (path as NSString).pathComponents
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }

    /// Where this session lives, for the row's metadata line. For a worktree
    /// session that is the worktree itself — now that the title names the
    /// project, the branch directory is what tells two sibling rows apart.
    /// Otherwise it is the enclosing directory, skipping containers that name
    /// no project ("worktrees", ".claude").
    var locationContext: String? {
        guard let directory = primaryDirectory,
            let split = Self.projectAndWorktree(of: directory)
        else { return nil }
        if let worktree = split.worktree { return Self.shortened(worktree) }
        var parts = (directory as NSString).pathComponents.filter { $0 != "/" }
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        while let last = parts.last, Self.namesNoProject(last) {
            parts.removeLast()
        }
        return parts.last
    }

    /// Worktree directories are generated: a ticket, a slug and a hash. Shown
    /// whole they push the session's status off the end of the metadata line,
    /// so keep the two ends that identify one and drop the slug between them.
    static func shortened(_ name: String, to limit: Int = 24) -> String {
        let tail = 8
        guard name.count > limit, limit > tail + 5 else { return name }
        var head = Substring(name.prefix(limit - tail - 1))
        // Cut back to a separator so the head does not end mid-word, unless
        // that would leave almost nothing.
        if let separator = head.lastIndex(of: "-"),
            head.distance(from: head.startIndex, to: separator) >= 4
        {
            head = head[..<separator]
        }
        return "\(head)…\(name.suffix(tail))"
    }

    /// Tool scaffolding rather than a project. An explicit list, not a rule:
    /// `hasPrefix(".")` would swallow legitimate project roots (a session in
    /// `~/.config/nvim` belongs to `.config`, not to the home directory), and
    /// generic names like `src` or `repos` are real context when nothing
    /// better encloses them.
    private static func namesNoProject(_ component: String) -> Bool {
        scaffoldingDirectoryNames.contains(component.lowercased())
    }

    private static let scaffoldingDirectoryNames: Set<String> = [
        "worktrees", ".worktrees", ".claude", ".git",
    ]

    var providerDisplayName: String {
        switch provider {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return provider.capitalized
        }
    }
}
