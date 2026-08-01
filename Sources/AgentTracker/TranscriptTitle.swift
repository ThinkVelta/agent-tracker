import Foundation

/// Extracts the task title from a Claude Code transcript (JSONL). Claude Code
/// paints this string into the terminal window title, which makes it the
/// strongest per-session signal for window matching — and unlike the statusline
/// payload it is available for every session, including idle ones.
///
/// Two line shapes are recognized, because the format changed and old
/// transcripts are still on disk:
///
///     {"type":"ai-title","aiTitle":"Continue tool development…"}   // current
///     {"type":"summary","summary":"…"}                             // older
///
/// The older shape produced nothing on any live transcript when this was last
/// checked (2026-08-01, Claude Code 2.1.210) — every session had switched to
/// `ai-title` — so reading only it silently disabled window matching.
enum TranscriptTitle {
    /// Bounded window read: transcripts grow to many MB and this runs on the
    /// click path, so scan only the head (summaries cluster at the start of
    /// resumed transcripts) and the tail (for late additions), never the whole
    /// file. The last summary seen wins, preferring tail hits.
    static let defaultWindow = 256 * 1024

    /// Transcript line `type` → the field carrying the title.
    static let titleKeys: [String: String] = ["ai-title": "aiTitle", "summary": "summary"]

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
                // Cheap substring reject before paying for a JSON parse: these
                // transcripts run to thousands of lines and only a handful
                // carry a title.
                guard let line = String(data: Data(raw), encoding: .utf8),
                    Self.titleKeys.keys.contains(where: { line.contains("\"type\":\"\($0)\"") }),
                    let object = try? JSONSerialization.jsonObject(with: Data(raw))
                        as? [String: Any],
                    let type = object["type"] as? String,
                    let key = Self.titleKeys[type],
                    let title = object[key] as? String, !title.isEmpty
                else { continue }
                latest = title
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
