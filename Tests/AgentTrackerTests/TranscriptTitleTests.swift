import Foundation
import Testing

@testable import AgentTracker

/// Synthetic transcripts only — never real ~/.claude data.
final class TranscriptTitleTests {
    private var tempFiles: [URL] = []

    deinit {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
    }

    private func makeTranscript(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return url
    }

    /// A JSONL line padded to exactly `length` bytes including its newline.
    private func fillerLine(length: Int) -> String {
        let skeleton = "{\"type\":\"filler\",\"pad\":\"\"}\n"
        let padding = String(repeating: "x", count: length - skeleton.utf8.count)
        return "{\"type\":\"filler\",\"pad\":\"\(padding)\"}\n"
    }

    @Test func tailWindowKeepsBoundaryAlignedFirstLine() throws {
        // Regression: a tail window whose offset lands exactly on a line start
        // must keep that first line — it used to be dropped as a "fragment".
        // Fixed-length lines make every offset a multiple of lineLength, so
        // with window = 2 lines the tail chunk starts on a boundary, and the
        // only summary is exactly that boundary-aligned first tail line.
        let lineLength = 64
        let window = 2 * lineLength
        let summary = "{\"type\":\"summary\",\"summary\":\"Boundary aligned\"}\n"
        let content =
            fillerLine(length: lineLength) + fillerLine(length: lineLength)
            + fillerLine(length: lineLength)
            + summary + fillerLine(length: window - summary.utf8.count)
        #expect(content.utf8.count > 2 * window, "fixture must exceed both windows")

        let url = try makeTranscript(content)
        let found = TranscriptTitle.latestSummary(atPath: url.path, window: window)
        #expect(found == "Boundary aligned")
    }

    @Test func midLineTailFragmentIsIgnored() throws {
        // A summary line STRADDLING the tail-window boundary is a fragment in
        // both windows and must be ignored rather than half-parsed.
        let lineLength = 64
        let window = 2 * lineLength
        let summary = "{\"type\":\"summary\",\"summary\":\"Straddles the boundary\"}\n"
        let content =
            fillerLine(length: lineLength) + fillerLine(length: lineLength)
            + fillerLine(length: lineLength - 8)
            + summary
            + fillerLine(length: window - summary.utf8.count + 8)
        #expect(content.utf8.count > 2 * window, "fixture must exceed both windows")

        let url = try makeTranscript(content)
        let found = TranscriptTitle.latestSummary(atPath: url.path, window: window)
        #expect(found == nil)
    }

    @Test func smallFileIsReadWhole() throws {
        let summary = "{\"type\":\"summary\",\"summary\":\"Small file\"}\n"
        let url = try makeTranscript(fillerLine(length: 64) + summary)
        #expect(TranscriptTitle.latestSummary(atPath: url.path) == "Small file")
    }
}
