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

    private enum CodingKeys: String, CodingKey {
        case schema, provider, sessionId, pid, cwd, state, reason, lastEvent
        case updatedAt, stateChangedAt, transcriptPath, termProgram, lastMessage
    }

    var id: String { "\(provider)-\(sessionId)" }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Session" }
        return (cwd as NSString).lastPathComponent
    }

    /// Short path context shown alongside the project name, e.g. "ProjectsVelta/Planner".
    var pathContext: String? {
        guard let cwd else { return nil }
        let parts = (cwd as NSString).pathComponents
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

    /// Tool scaffolding rather than a project: known container names, plus any
    /// dot-directory (`.claude`, `.worktrees`, …), which by convention belongs
    /// to whatever encloses it.
    private static func namesNoProject(_ component: String) -> Bool {
        component.hasPrefix(".") || containerDirectoryNames.contains(component.lowercased())
    }

    private static let containerDirectoryNames: Set<String> = ["worktrees", "repos", "src"]

    var providerDisplayName: String {
        switch provider {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return provider.capitalized
        }
    }
}
