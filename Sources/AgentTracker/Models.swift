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
    /// terminal), and long worktree directories truncate in the middle with
    /// the full path on hover.
    var displayName: String {
        projectName
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

    /// Where this session lives, for the row's metadata line: the directory
    /// containing `projectName`. Container directories that name no project
    /// are skipped — a worktree at `…/planner-backend/.claude/worktrees/pln-388`
    /// belongs to "planner-backend", and answering "worktrees" or ".claude"
    /// would tell the user nothing.
    var locationContext: String? {
        guard let cwd else { return nil }
        var parts = (cwd as NSString).pathComponents.filter { $0 != "/" }
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        while let last = parts.last, Self.namesNoProject(last) {
            parts.removeLast()
        }
        return parts.last
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
