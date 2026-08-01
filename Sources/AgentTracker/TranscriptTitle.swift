import Foundation

/// Extracts the task summary from a Claude Code transcript (JSONL). Claude Code
/// uses this summary as the terminal window title ("✳ <summary>"), which makes
/// it the strongest signal for window matching.
enum TranscriptTitle {
    /// Bounded window read: transcripts grow to many MB and this runs on the
    /// click path, so scan only the head (summaries cluster at the start of
    /// resumed transcripts) and the tail (for late additions), never the whole
    /// file. The last summary seen wins, preferring tail hits.
    private static let window = 256 * 1024

    static func latestSummary(atPath path: String?) -> String? {
        guard let path, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
            let size = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }

        var latest: String?
        for chunk in windowRanges(fileSize: size) {
            guard (try? handle.seek(toOffset: chunk.offset)) != nil,
                let data = try? handle.read(upToCount: chunk.length),
                var text = String(data: data, encoding: .utf8)
            else { continue }
            // Drop partial lines cut at window boundaries — a fragment can't
            // parse and must not shadow a complete line in the other window.
            if chunk.offset > 0, let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if chunk.offset + UInt64(chunk.length) < size, let lastNewline = text.lastIndex(of: "\n")
            {
                text = String(text[..<lastNewline])
            }
            for line in text.split(separator: "\n") {
                guard line.contains("\"type\":\"summary\"") else { continue }
                guard let lineData = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: lineData)
                        as? [String: Any],
                    let summary = object["summary"] as? String, !summary.isEmpty
                else { continue }
                latest = summary
            }
        }
        return latest
    }

    private static func windowRanges(fileSize: UInt64) -> [(offset: UInt64, length: Int)] {
        if fileSize <= UInt64(window * 2) {
            return [(0, Int(fileSize))]
        }
        return [(0, window), (fileSize - UInt64(window), window)]
    }
}
