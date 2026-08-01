import Foundation
import Testing

@testable import AgentTracker

final class DebugLogTests {
    private func makeSink(maxBytes: Int = 2 * 1024 * 1024) -> (DebugLog.FileSink, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logs-\(UUID().uuidString)")
        return (DebugLog.FileSink(directory: directory, maxBytes: maxBytes), directory)
    }

    @Test func linesArePersistedWithADateStamp() throws {
        let (sink, directory) = makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        sink.append("[focus] 12:00:00 focusing something")
        sink.append("[ui] 12:00:01 dot=needsYou → open")
        sink.flush()

        let contents = try String(contentsOf: sink.fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[focus] 12:00:00 focusing something"))
        #expect(lines[1].hasSuffix("[ui] 12:00:01 dot=needsYou → open"))
        // Trace lines carry only HH:mm:ss; the file spans days, so each
        // persisted line leads with the date (yyyy-MM-dd = 10 characters).
        #expect(lines.allSatisfy { $0.count >= "yyyy-MM-dd ".count })
        #expect(lines[0].prefix(2) == "20")
    }

    /// The cap is what makes an always-on log safe: outgrow it and the file
    /// trims to its newest half, cut on a line boundary.
    @Test func oversizedLogsTrimToTheNewestHalfOnLineBoundaries() throws {
        let (sink, directory) = makeSink(maxBytes: 4096)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<200 {
            sink.append("[store] line \(index) padding padding padding padding")
        }
        sink.flush()

        let data = try Data(contentsOf: sink.fileURL)
        #expect(data.count <= 4096)
        let contents = try #require(String(data: data, encoding: .utf8))
        // Never opens mid-line…
        #expect(contents.hasPrefix("20"))
        // …and it kept the newest lines, dropping the oldest.
        #expect(contents.contains("line 199"))
        #expect(!contents.contains("line 0 "))
    }

    @Test func concurrentAppendsAllLand() throws {
        let (sink, directory) = makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            sink.append("[codex-scan] concurrent \(index)")
        }
        sink.flush()
        let contents = try String(contentsOf: sink.fileURL, encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 50)
    }

    @Test func aMissingDirectoryIsCreatedOnFirstAppend() throws {
        let (sink, directory) = makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        sink.append("[ui] first line")
        sink.flush()
        #expect(FileManager.default.fileExists(atPath: sink.fileURL.path))
    }
}
