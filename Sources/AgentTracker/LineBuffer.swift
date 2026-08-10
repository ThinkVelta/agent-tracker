import Foundation

/// Splitting an append-only file into whole lines, for readers that come back
/// for more later.
///
/// The agent files this app tails are written a line at a time by another
/// process, so a read can land mid-line. Returning the byte count consumed —
/// rather than just the lines — is what lets a caller resume exactly where the
/// last complete line ended and pick the partial one up once the rest arrives.
enum LineBuffer {
    /// - Returns: the complete lines in `data`, and how many bytes they
    ///   occupied. Bytes after the last newline are a partially written line and
    ///   are deliberately **not** consumed.
    static func completeLines(in data: Data) -> (lines: [String], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        let complete = data[data.startIndex..<lastNewline]
        let lines =
            complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { String(data: $0, encoding: .utf8) }
        return (lines, consumed)
    }
}
