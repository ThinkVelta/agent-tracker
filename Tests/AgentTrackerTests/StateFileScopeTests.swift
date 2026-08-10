import Foundation
import Testing

@testable import AgentTracker

/// Which files on disk this app will act on.
///
/// The window this guards is narrow and real: upgrading to the Claude-only
/// build while a session from the version that also tracked Codex is still
/// running. Its state file is not pruned — the process is alive — and the
/// provider field is no longer read, so nothing else tells the two apart.
@Suite("State file scope")
struct StateFileScopeTests {
    private func write(_ name: String, sessionId: String, lastEvent: String) throws -> URL {
        let directory = SessionStore.sessionsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try
            #"{"schema":1,"sessionId":"\#(sessionId)","state":"needsYou","lastEvent":"\#(lastEvent)"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("only files the hook wrote are ours")
    func prefixDecidesOwnership() {
        let directory = SessionStore.sessionsDirectory
        #expect(SessionStore.isOwnStateFile(directory.appendingPathComponent("claude-code-a.json")))
        #expect(!SessionStore.isOwnStateFile(directory.appendingPathComponent("codex-a.json")))
        #expect(!SessionStore.isOwnStateFile(directory.appendingPathComponent("claude-code-a.txt")))
        #expect(!SessionStore.isOwnStateFile(directory.appendingPathComponent("notes.json")))
    }

    /// The dangerous half. `loadSessionFromDisk` is what delivery re-reads
    /// immediately before typing into a terminal, and a leftover Codex row
    /// carries `lastEvent: "Stop"` — the exact event the arming gate reads — so
    /// without the scope it would be armable and sendable.
    @Test("delivery cannot re-read another agent's leftover")
    func deliveryIgnoresForeignFiles() throws {
        let id = "scope-\(UUID().uuidString)"
        let foreign = try write("codex-\(id).json", sessionId: id, lastEvent: "Stop")
        defer { try? FileManager.default.removeItem(at: foreign) }

        #expect(SessionStore.loadSessionFromDisk(sessionId: id) == nil)

        // Same session id, this time in a file the hook would have written.
        let ours = try write("claude-code-\(id).json", sessionId: id, lastEvent: "Stop")
        defer { try? FileManager.default.removeItem(at: ours) }
        #expect(SessionStore.loadSessionFromDisk(sessionId: id)?.sessionId == id)
    }
}
