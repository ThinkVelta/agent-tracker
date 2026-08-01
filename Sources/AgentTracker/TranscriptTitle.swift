import Foundation

/// Extracts the task summary from a Claude Code transcript (JSONL). Claude Code
/// uses this summary as the terminal window title ("✳ <summary>"), which makes
/// it the strongest signal for window matching.
enum TranscriptTitle {
    /// Bounded window read: transcripts grow to many MB and this runs on the
    /// click path, so scan only the head (summaries cluster at the start of
    /// resumed transcripts) and the tail (for late additions), never the whole
    /// file. The last summary seen wins, preferring tail hits.
    static let defaultWindow = 256 * 1024

    static func latestSummary(atPath path: String?, window: Int = defaultWindow) -> String? {
        guard let path, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
            let size = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }

        var latest: String?
        for chunk in windowRanges(fileSize: size, window: window) {
            // A window starting exactly on a line boundary keeps its first
            // line; only a true mid-line start drops the fragment.
            let startsMidLine: Bool = {
                guard chunk.offset > 0,
                    (try? handle.seek(toOffset: chunk.offset - 1)) != nil,
                    let previous = try? handle.read(upToCount: 1),
                    let byte = previous.first
                else { return false }
                return byte != UInt8(ascii: "\n")
            }()
            guard (try? handle.seek(toOffset: chunk.offset)) != nil,
                let data = try? handle.read(upToCount: chunk.length)
            else { continue }
            // Trim to newline-bounded BYTES before any decoding: a window
            // boundary can split a multibyte scalar, and a whole-chunk decode
            // would then fail and drop every line in the window.
            let newline = UInt8(ascii: "\n")
            var bytes = data[data.startIndex...]
            if startsMidLine, let first = bytes.firstIndex(of: newline) {
                bytes = bytes[bytes.index(after: first)...]
            }
            if chunk.offset + UInt64(chunk.length) < size, let last = bytes.lastIndex(of: newline) {
                bytes = bytes[..<last]
            }
            for raw in bytes.split(separator: newline, omittingEmptySubsequences: true) {
                guard let line = String(data: Data(raw), encoding: .utf8),
                    line.contains("\"type\":\"summary\""),
                    let object = try? JSONSerialization.jsonObject(with: Data(raw))
                        as? [String: Any],
                    let summary = object["summary"] as? String, !summary.isEmpty
                else { continue }
                latest = summary
            }
        }
        return latest
    }

    private static func windowRanges(
        fileSize: UInt64, window: Int
    ) -> [(offset: UInt64, length: Int)] {
        if fileSize <= UInt64(window * 2) {
            return [(0, Int(fileSize))]
        }
        return [(0, window), (fileSize - UInt64(window), window)]
    }
}
