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
        #expect(entry?.waitingFor == nil)
    }

    @Test func emptyStringsReadAsAbsent() {
        let entry = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","name":"","cwd":""}"#.utf8))
        #expect(entry?.name == nil)
        #expect(entry?.cwd == nil)
    }

    /// The whole vocabulary Claude validates against, `["busy","shell","idle",
    /// "waiting"]`, and the guarantee for anything outside it: an unrecognized
    /// value expresses no opinion rather than being forced into a state.
    @Test func theWholeStatusVocabularyIsCovered() {
        #expect(ClaudeSessionRegistry.Status(raw: "busy").isWorking == true)
        #expect(ClaudeSessionRegistry.Status(raw: "BUSY").isWorking == true)
        // Background work after the turn ended is still work — the case whose
        // absence left a session red for as long as its shell ran.
        #expect(ClaudeSessionRegistry.Status(raw: "shell") == .shell)
        #expect(ClaudeSessionRegistry.Status(raw: "shell").isWorking == true)
        #expect(ClaudeSessionRegistry.Status(raw: "idle").isWorking == false)
        #expect(ClaudeSessionRegistry.Status(raw: "waiting").isWorking == false)
        #expect(ClaudeSessionRegistry.Status(raw: "compacting").isWorking == nil)
        #expect(ClaudeSessionRegistry.Status(raw: nil).isWorking == nil)
    }

    /// `waitingFor` is Claude's own description of what it is blocked on, and
    /// the row's reason quotes it verbatim.
    @Test func waitingForIsReadAlongsideTheStatus() {
        let entry = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","status":"waiting","waitingFor":"input needed"}"#.utf8))
        #expect(entry?.status == .waiting)
        #expect(entry?.waitingFor == "input needed")
        // Absent for every other status, and an empty string is not a reason.
        let busy = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","status":"busy","waitingFor":""}"#.utf8))
        #expect(busy?.waitingFor == nil)
    }

    @Test func nonsenseTimestampsAreDropped() {
        let entry = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","statusUpdatedAt":0}"#.utf8))
        #expect(entry?.statusUpdatedAt == nil)
        let text = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"abc","statusUpdatedAt":"yesterday"}"#.utf8))
        #expect(text?.statusUpdatedAt == nil)
    }

    // MARK: - Name precedence at the store seam

    /// The precedence the click-to-focus fix established, kept testable after
    /// the two registry readers became one: a rename lands in the registry
    /// immediately, while a stale statusline capture can keep replaying the
    /// old name for as long as that session stays the file's last writer.
    @Test func theRegistryNameBeatsAStaleStatuslineTitle() {
        #expect(
            SessionStore.coalescedWindowTitle(
                registryName: "renamed", statuslineTitle: "stale") == "renamed")
        #expect(
            SessionStore.coalescedWindowTitle(
                registryName: nil, statuslineTitle: "older claude") == "older claude")
        #expect(
            SessionStore.coalescedWindowTitle(registryName: nil, statuslineTitle: nil) == nil)
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

    /// `nameSource` names where a session's name came from, and the whole
    /// "show it always or only when ambiguous" rule hangs on reading it right.
    /// Claude prints a name beside a session for exactly three cases — absent,
    /// `user`, `peer` — and that is the rule mirrored here.
    @Test func aChosenNameIsToldApartFromADerivedOne() {
        let derived = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s1","name":"planner-a5","nameSource":"derived"}"#.utf8))
        #expect(derived?.nameIsChosen == false)

        // `/rename` and `--name`. Spelled out since 2.1.251; before that the
        // same act wrote no source at all, which is why absence still counts.
        let renamed = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s2","name":"the migration","nameSource":"user"}"#.utf8))
        #expect(renamed?.nameIsChosen == true)

        let chosen = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s3","name":"the migration"}"#.utf8))
        #expect(chosen?.nameIsChosen == true)

        // A peer naming a session is still somebody naming it, and Claude
        // prints it for that reason.
        let peer = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s4","name":"reviewer","nameSource":"peer"}"#.utf8))
        #expect(peer?.nameIsChosen == true)

        // The rest of the vocabulary is Claude naming its own session, however
        // it got there — a clash it settled, a slug it generated, a hook.
        for source in ["collision", "auto", "hook"] {
            let generated = ClaudeSessionRegistry.parse(
                Data(#"{"sessionId":"s5","name":"planner-b7","nameSource":"\#(source)"}"#.utf8))
            #expect(generated?.nameIsChosen == false, "\(source) is not a chosen name")
        }

        // Case is folded, as it is for `status`. A differently-spelled `user`
        // is the token we already know, not one of the unknown values below.
        let shouted = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s5b","name":"the migration","nameSource":"User"}"#.utf8))
        #expect(shouted?.nameIsChosen == true)

        // A value nobody has seen counts as derived. This decides whether to
        // put a name on every row, and guessing "chosen" is the wrong way to be
        // wrong about that.
        let unknown = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s6","name":"planner-b7","nameSource":"something-new"}"#.utf8))
        #expect(unknown?.nameIsChosen == false)

        // JSON has two spellings for "no source"; they must agree.
        let explicitNull = ClaudeSessionRegistry.parse(
            Data(#"{"sessionId":"s7","name":"the migration","nameSource":null}"#.utf8))
        #expect(explicitNull?.nameIsChosen == true)

        // No name at all is not a chosen name.
        let unnamed = ClaudeSessionRegistry.parse(Data(#"{"sessionId":"s8"}"#.utf8))
        #expect(unnamed?.nameIsChosen == false)
    }

    // MARK: - Directory lifecycle, same rules as the payload watcher

    @MainActor private func makeClaudeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor private func writeEntry(_ id: String, pid: Int, in claudeRoot: URL) throws {
        let sessions = claudeRoot.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"{"sessionId":"\#(id)","pid":\#(pid),"name":"\#(id)-name"}"#.write(
            to: sessions.appendingPathComponent("\(pid).json"),
            atomically: true, encoding: .utf8)
    }

    /// Regression, ported from the retired second reader: the registry is
    /// created by Claude's first session, which can start after the app, and
    /// refresh() (driven by the store's reload tick) must pick it up.
    @Test @MainActor func recoversWhenTheRegistryAppearsAfterInit() throws {
        let root = try makeClaudeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ClaudeSessionRegistry(claudeDirectory: root)
        #expect(registry.entry(forSessionId: "late") == nil)

        try writeEntry("late", pid: Int(ProcessInfo.processInfo.processIdentifier), in: root)
        registry.refresh()
        #expect(registry.entry(forSessionId: "late")?.name == "late-name")
    }

    /// Regression, same origin: deleting and recreating the directory leaves
    /// a watcher bound to the dead inode, and refresh() must re-arm and read.
    @Test @MainActor func survivesRegistryDeleteAndRecreate() throws {
        let root = try makeClaudeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEntry(
            "before", pid: Int(ProcessInfo.processInfo.processIdentifier), in: root)
        let registry = ClaudeSessionRegistry(claudeDirectory: root)
        #expect(registry.entry(forSessionId: "before") != nil)

        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions"))
        registry.refresh()
        try writeEntry("after", pid: Int(ProcessInfo.processInfo.processIdentifier), in: root)
        registry.refresh()
        #expect(registry.entry(forSessionId: "after")?.name == "after-name")
    }
}
