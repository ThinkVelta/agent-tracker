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

    var providerDisplayName: String {
        switch provider {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return provider.capitalized
        }
    }
}
