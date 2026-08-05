import Foundation
import Testing

@testable import AgentTracker

/// Synthetic statusline payloads only — never real ~/.claude data.
final class TitleDirectoryTests {
    private var tempDirs: [URL] = []

    deinit {
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-directory-\(UUID().uuidString)")
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

    private func payload(id: String, name: String?) -> String {
        let nameField = name.map { ", \"session_name\": \"\($0)\"" } ?? ""
        return """
            {"session_id": "\(id)"\(nameField), "cwd": "/tmp", \
            "model": {"id": "claude-opus-5", "display_name": "Opus"}}
            """
    }

    @Test func parseExtractsIdAndName() {
        let data = Data(payload(id: "abc-123", name: "Fix the flaky scanner test").utf8)
        let entry = TitleDirectory.parse(data)
        #expect(entry?.sessionId == "abc-123")
        #expect(entry?.name == "Fix the flaky scanner test")
    }

    @Test func parseRejectsPayloadsWithoutName() {
        #expect(TitleDirectory.parse(Data(payload(id: "abc", name: nil).utf8)) == nil)
        #expect(TitleDirectory.parse(Data("{\"session_name\": \"x\"}".utf8)) == nil)
        #expect(TitleDirectory.parse(Data("not json".utf8)) == nil)
        #expect(TitleDirectory.parse(Data("[1, 2]".utf8)) == nil)
    }

    @Test @MainActor func accumulatesAcrossLastWriterWinsPayloads() throws {
        let directory = try makeDirectory()
        try writePayload(payload(id: "session-a", name: "Task A"), in: directory)
        let titles = TitleDirectory(directory: directory, capture: capture(in: directory))
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
        let titles = TitleDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "from-capture") == "Captured title")
    }

    /// Both files can exist at once, and a `statusline-last.json` outlives the tee
    /// that wrote it — so the capture, which is known current, decides.
    @Test @MainActor func theCaptureWinsWhenBothDescribeOneSession() throws {
        let directory = try makeDirectory()
        try writePayload(payload(id: "same", name: "Stale name"), in: directory)
        try writeCapture(payload(id: "same", name: "Current name"), in: directory)
        let titles = TitleDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "same") == "Current name")

        // A session only the user's own script has seen is still picked up.
        try writePayload(payload(id: "theirs", name: "Their title"), in: directory)
        titles.absorbLatest()
        #expect(titles.title(for: "theirs") == "Their title")
        #expect(titles.title(for: "same") == "Current name")
    }

    @Test @MainActor func missingFileLeavesDirectoryEmpty() throws {
        let directory = try makeDirectory()
        let titles = TitleDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "anything") == nil)
    }

    @Test @MainActor func recoversWhenDirectoryAppearsAfterInit() throws {
        // Regression: launching before ~/.claude exists must not leave the
        // directory permanently inert — refresh() (driven by the store's
        // reload tick) re-arms the watcher and absorbs.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-directory-\(UUID().uuidString)")
        tempDirs.append(directory)
        let titles = TitleDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "late") == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePayload(payload(id: "late", name: "Late title"), in: directory)
        titles.refresh()
        #expect(titles.title(for: "late") == "Late title")
    }

    @Test @MainActor func survivesDirectoryDeleteAndRecreate() throws {
        // Regression: rm -rf ~/.claude + recreation leaves the old watcher
        // bound to the unlinked inode; refresh() must keep absorbing (and the
        // accumulated map must survive).
        let directory = try makeDirectory()
        try writePayload(payload(id: "before", name: "Old title"), in: directory)
        let titles = TitleDirectory(directory: directory, capture: capture(in: directory))
        #expect(titles.title(for: "before") == "Old title")

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePayload(payload(id: "after", name: "New title"), in: directory)
        titles.refresh()
        #expect(titles.title(for: "before") == "Old title")
        #expect(titles.title(for: "after") == "New title")
    }
}
