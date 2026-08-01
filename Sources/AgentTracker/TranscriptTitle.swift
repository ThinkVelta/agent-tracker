import Foundation

/// Extracts the task summary from a Claude Code transcript (JSONL). Claude Code
/// uses this summary as the terminal window title ("✳ <summary>"), which makes
/// it the strongest signal for window matching.
enum TranscriptTitle {
    static func latestSummary(atPath path: String?) -> String? {
        guard let path,
            let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        var latest: String?
        for line in text.split(separator: "\n") {
            guard line.contains("\"type\":\"summary\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let summary = object["summary"] as? String, !summary.isEmpty
            else { continue }
            latest = summary
        }
        return latest
    }
}
