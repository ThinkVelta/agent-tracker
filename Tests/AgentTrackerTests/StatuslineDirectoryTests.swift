import Foundation
import Testing

@testable import AgentTracker

/// Synthetic statusline payloads only — never real ~/.claude data.
final class StatuslineDirectoryTests {
    private var tempDirs: [URL] = []

    deinit {
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("statusline-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func writePayload(_ json: String, in directory: URL) throws {
        try json.write(
            to: directory.appendingPathComponent("statusline-last.json"),
            atomically: true, encoding: .utf8
        )
    }

    /// Every construction names its own capture file: the parameter's default is
    /// the real ~/.agent-tracker, and a test must never read the user's own.
    private func capture(in directory: URL) -> URL {
        directory.appendingPathComponent("claude-statusline.json")
    }

    private func writeCapture(_ json: String, in directory: URL) throws {
        try json.write(to: capture(in: directory), atomically: true, encoding: .utf8)
    }

    private func payload(id: String, name: String?, context: Int? = nil) -> String {
        let nameField = name.map { ", \"session_name\": \"\($0)\"" } ?? ""
        let contextField =
            context.map { ", \"context_window\": {\"used_percentage\": \($0)}" } ?? ""
        return """
            {"session_id": "\(id)"\(nameField)\(contextField), "cwd": "/tmp", \
            "model": {"id": "claude-opus-5", "display_name": "Opus"}}
            """
    }

    @Test func parseExtractsIdAndName() {
        let data = Data(payload(id: "abc-123", name: "Fix the flaky scanner test").utf8)
        let entry = StatuslineDirectory.parse(data)
        #expect(entry?.sessionId == "abc-123")
        #expect(entry?.name == "Fix the flaky scanner test")
    }

    @Test func parseExtractsContextPressure() {
        let entry = StatuslineDirectory.parse(Data(payload(id: "abc", name: nil, context: 84).utf8))
        #expect(entry?.contextUsedPercent == 84)
        #expect(entry?.name == nil)
    }

    /// A number outside 0-100 means this is not the field we think it is —
    /// dropped rather than clamped, which would invent a reading.
    @Test func parseIgnoresAnImpossiblePercentage() {
        for absurd in [-1, 101, 4200] {
            let data = Data(payload(id: "abc", name: nil, context: absurd).utf8)
            #expect(StatuslineDirectory.parse(data)?.contextUsedPercent == nil)
        }
    }

    @Test func parseRejectsPayloadsWithoutASessionId() {
        #expect(StatuslineDirectory.parse(Data("{\"session_name\": \"x\"}".utf8)) == nil)
        #expect(StatuslineDirectory.parse(Data("not json".utf8)) == nil)
        #expect(StatuslineDirectory.parse(Data("[1, 2]".utf8)) == nil)
    }

    /// An unnamed session used to be dropped outright, which was fine when a
    /// name was all this read. It now also carries context, so the payload is
    /// kept — but it must still contribute no title.
    @Test @MainActor func anUnnamedSessionContributesNoTitle() throws {
        let directory = try makeDirectory()
        try writePayload(payload(id: "unnamed", name: nil, context: 40), in: directory)
        let statusline = StatuslineDirectory(
            directory: directory, capture: capture(in: directory))
        #expect(statusline.title(for: "unnamed") == nil)
        #expect(statusline.contextUsedPercent(for: "unnamed") == 40)
    }

    /// The two facts arrive on the same payloads but not always together, and
    /// the map is accumulated — so a payload carrying one must not erase the
    /// other. Both are last-writer-wins across sessions, which is the whole
    /// reason this is a map and not a snapshot.
    @Test @MainActor func contextAccumulatesPerSessionAndSurvivesAQuietPayload() throws {
        let directory = try makeDirectory()
        try writePayload(payload(id: "a", name: "Task A", context: 30), in: directory)
        let statusline = StatuslineDirectory(
            directory: directory, capture: capture(in: directory))
        #expect(statusline.contextUsedPercent(for: "a") == 30)

        try writePayload(payload(id: "b", name: "Task B", context: 91), in: directory)
        statusline.absorbLatest()
        #expect(statusline.contextUsedPercent(for: "a") == 30)
        #expect(statusline.contextUsedPercent(for: "b") == 91)

        // A payload with no context at all leaves the last known reading alone
        // rather than blanking the row.
        try writePayload(payload(id: "a", name: "Task A"), in: directory)
        statusline.absorbLatest()
        #expect(statusline.contextUsedPercent(for: "a") == 30)

        try writePayload(payload(id: "a", name: "Task A", context: 55), in: directory)
        statusline.absorbLatest()
        #expect(statusline.contextUsedPercent(for: "a") == 55)
    }

    @Test @MainActor func accumulatesAcrossLastWriterWinsPayloads() throws {
        let directory = try makeDirectory()
        try writePayload(payload(id: "session-a", name: "Task A"), in: directory)
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "session-a") == "Task A")

        // The file only ever holds ONE session's payload; a refresh from a
        // second session must not evict the first.
        try writePayload(payload(id: "session-b", name: "Task B"), in: directory)
        titles.absorbLatest()
        #expect(titles.title(for: "session-a") == "Task A")
        #expect(titles.title(for: "session-b") == "Task B")

        // A renamed session updates in place.
        try writePayload(payload(id: "session-a", name: "Task A renamed"), in: directory)
        titles.absorbLatest()
        #expect(titles.title(for: "session-a") == "Task A renamed")
    }

    /// The wrapper's capture is a title source in its own right, so click-to-focus
    /// gets exact titles without the user teeing anything into ~/.claude.
    @Test @MainActor func absorbsNamesFromTheStatuslineCapture() throws {
        let directory = try makeDirectory()
        try writeCapture(payload(id: "from-capture", name: "Captured title"), in: directory)
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "from-capture") == "Captured title")
    }

    /// Both files can exist at once, and a `statusline-last.json` outlives the tee
    /// that wrote it — so the capture, which is known current, decides.
    @Test @MainActor func theCaptureWinsWhenBothDescribeOneSession() throws {
        let directory = try makeDirectory()
        try writePayload(payload(id: "same", name: "Stale name"), in: directory)
        try writeCapture(payload(id: "same", name: "Current name"), in: directory)
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "same") == "Current name")

        // A session only the user's own script has seen is still picked up.
        try writePayload(payload(id: "theirs", name: "Their title"), in: directory)
        titles.absorbLatest()
        #expect(titles.title(for: "theirs") == "Their title")
        #expect(titles.title(for: "same") == "Current name")
    }

    @Test @MainActor func missingFileLeavesDirectoryEmpty() throws {
        let directory = try makeDirectory()
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "anything") == nil)
    }

    @Test @MainActor func recoversWhenDirectoryAppearsAfterInit() throws {
        // Regression: launching before ~/.claude exists must not leave the
        // directory permanently inert — refresh() (driven by the store's
        // reload tick) re-arms the watcher and absorbs.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statusline-directory-\(UUID().uuidString)")
        tempDirs.append(directory)
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "late") == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePayload(payload(id: "late", name: "Late title"), in: directory)
        titles.refresh()
        #expect(titles.title(for: "late") == "Late title")
    }

    /// The replay directory exists for the docs fixture: it seeds the readings
    /// a live machine accumulates across repaints, which a one-shot render
    /// never sees happen. Live sources are absorbed after it, so a live payload
    /// for the same session always wins over the seeded value.
    @Test @MainActor func replaySeedsReadingsAndLiveSourcesWin() throws {
        let directory = try makeDirectory()
        let replay = directory.appendingPathComponent("statusline-replay")
        try FileManager.default.createDirectory(at: replay, withIntermediateDirectories: true)
        try payload(id: "seeded", name: nil, context: 18).write(
            to: replay.appendingPathComponent("01.json"), atomically: true, encoding: .utf8)
        try payload(id: "both", name: nil, context: 50).write(
            to: replay.appendingPathComponent("02.json"), atomically: true, encoding: .utf8)
        try writeCapture(payload(id: "both", name: nil, context: 92), in: directory)
        let titles = StatuslineDirectory(
            directory: directory, capture: capture(in: directory), replay: replay)
        #expect(titles.contextUsedPercent(for: "seeded") == 18)
        #expect(titles.contextUsedPercent(for: "both") == 92)
    }

    /// The gate itself (review on #87): replay is a fixture input, so a
    /// normally constructed directory must not read it even when files sit
    /// there, or stale local data could reseed a live row forever.
    @Test @MainActor func replayIsInertWithoutExplicitInjection() throws {
        let directory = try makeDirectory()
        let replay = directory.appendingPathComponent("statusline-replay")
        try FileManager.default.createDirectory(at: replay, withIntermediateDirectories: true)
        try payload(id: "seeded", name: nil, context: 18).write(
            to: replay.appendingPathComponent("01.json"), atomically: true, encoding: .utf8)
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.contextUsedPercent(for: "seeded") == nil)
    }

    @Test @MainActor func survivesDirectoryDeleteAndRecreate() throws {
        // Regression: rm -rf ~/.claude + recreation leaves the old watcher
        // bound to the unlinked inode; refresh() must keep absorbing (and the
        // accumulated map must survive).
        let directory = try makeDirectory()
        try writePayload(payload(id: "before", name: "Old title"), in: directory)
        let titles = StatuslineDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "before") == "Old title")

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePayload(payload(id: "after", name: "New title"), in: directory)
        titles.refresh()
        #expect(titles.title(for: "before") == "Old title")
        #expect(titles.title(for: "after") == "New title")
    }
}
