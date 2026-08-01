import Foundation
import Testing

@testable import AgentTracker

final class ClaudeSessionRegistryTests {
    /// A payload shaped like the real thing (Claude Code 2.1.210), including
    /// fields we do not read, which must be ignored rather than tripped over.
    private let realistic = """
        {"pid":64972,"sessionId":"f79dfa41-faaf-4d44-a629-e3a87f96757c",
         "cwd":"/Users/dev/Marrow/medium-blog-content","startedAt":1784133881341,
         "procStart":"Wed Jul 15 16:44:39 2026","version":"2.1.210","peerProtocol":1,
         "kind":"interactive","entrypoint":"cli","name":"medium-blog-content-aa",
         "nameSource":"derived","status":"idle","updatedAt":1784138440311,
         "statusUpdatedAt":1784138440311}
        """

    @Test func parsesARealisticPayload() {
        let entry = ClaudeSessionRegistry.parse(Data(realistic.utf8))
        #expect(entry?.sessionId == "f79dfa41-faaf-4d44-a629-e3a87f96757c")
        #expect(entry?.pid == 64972)
        #expect(entry?.name == "medium-blog-content-aa")
        #expect(entry?.cwd == "/Users/dev/Marrow/medium-blog-content")
        #expect(entry?.status == .idle)
        #expect(entry?.statusUpdatedAt == Date(timeIntervalSince1970: 1_784_138_440.311))
    }

    /// Claude Code owns this format and can change it; malformed input must
    /// never crash the app, and a payload with no session id is unusable.
    @Test func unusableInputIsRejectedRatherThanGuessedAt() {
        #expect(ClaudeSessionRegistry.parse(Data()) == nil)
        #expect(ClaudeSessionRegistry.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(Data("[1,2,3]".utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(Data(#"{"pid":1}"#.utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(Data(#"{"sessionId":""}"#.utf8)) == nil)
    }

    @Test func everyFieldBesideTheSessionIdIsOptional() {
        let entry = ClaudeSessionRegistry.parse(Data(#"{"sessionId":"abc"}"#.utf8))
        #expect(entry?.sessionId == "abc")
        #expect(entry?.pid == nil)
        #expect(entry?.name == nil)
        #expect(entry?.cwd == nil)
        #expect(entry?.status == .unknown)
        #expect(entry?.statusUpdatedAt == nil)
    }

    @Test func emptyStringsReadAsAbsent() {
        let entry = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","name":"","cwd":""}"#.utf8))
        #expect(entry?.name == nil)
        #expect(entry?.cwd == nil)
    }

    /// The status vocabulary is Claude's, not ours: an unrecognized value has
    /// to express no opinion rather than being forced into a state.
    @Test func statusVocabularyIsOpenEnded() {
        #expect(ClaudeSessionRegistry.Status(raw: "busy").isBusy == true)
        #expect(ClaudeSessionRegistry.Status(raw: "BUSY").isBusy == true)
        #expect(ClaudeSessionRegistry.Status(raw: "idle").isBusy == false)
        #expect(ClaudeSessionRegistry.Status(raw: "waiting").isBusy == false)
        #expect(ClaudeSessionRegistry.Status(raw: "compacting").isBusy == nil)
        #expect(ClaudeSessionRegistry.Status(raw: nil).isBusy == nil)
    }

    @Test func nonsenseTimestampsAreDropped() {
        let entry = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","statusUpdatedAt":0}"#.utf8))
        #expect(entry?.statusUpdatedAt == nil)
        let text = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","statusUpdatedAt":"yesterday"}"#.utf8))
        #expect(text?.statusUpdatedAt == nil)
    }

    // MARK: - Directory loading

    @MainActor
    @Test func loadsLiveSessionsAndSkipsDeadOnes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registry-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alive = ProcessInfo.processInfo.processIdentifier
        try #"{"sessionId":"live","pid":\#(alive),"name":"planner-e8","status":"busy"}"#
            .write(
                to: sessions.appendingPathComponent("\(alive).json"), atomically: true,
                encoding: .utf8)
        // A session that died without a clean exit leaves its file behind.
        try #"{"sessionId":"ghost","pid":999999,"name":"gone"}"#
            .write(
                to: sessions.appendingPathComponent("999999.json"), atomically: true,
                encoding: .utf8)
        try "not json".write(
            to: sessions.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        try "ignored".write(
            to: sessions.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let registry = ClaudeSessionRegistry(claudeDirectory: root)
        #expect(registry.entry(forSessionId: "live")?.name == "planner-e8")
        #expect(registry.entry(forSessionId: "ghost") == nil)
        #expect(registry.entries.count == 1)
    }

    @MainActor
    @Test func aMissingDirectoryIsSimplyEmpty() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("absent-\(UUID().uuidString)")
        let registry = ClaudeSessionRegistry(claudeDirectory: missing)
        #expect(registry.entries.isEmpty)
        #expect(registry.entry(forSessionId: "anything") == nil)
    }
}
