import Foundation

/// Tails Claude transcripts for a refusal, incrementally.
///
/// Why not simply scan for the marker: measured across the 92 transcripts on one
/// machine that contain one, only 13 sit within 64 KiB of EOF and the deepest is
/// 36 MB in. Those are historical — the session hit a wall, waited, and carried
/// on for megabytes afterwards — so a whole-file scan would resurrect windows
/// that reset days ago, and a plain tail read would miss 86% of them.
///
/// What matters is a refusal appearing **now**, so this reads only what has been
/// appended since it last looked. First sight is the one exception: it reads a
/// small tail, because a session that is *currently* blocked stopped writing the
/// moment it was refused, which puts its marker at EOF.
@MainActor
final class ClaudeUsageWatcher {
    /// Enough to hold the refusal plus the turn around it, at first sight.
    static let firstSightWindow = 64 * 1024
    /// A resumed session can append megabytes between looks. Reading only the
    /// newest slice of a large delta risks missing a refusal in the middle, but
    /// a session writing megabytes is by definition not blocked.
    static let maximumDelta = 2 * 1024 * 1024

    private struct Position {
        var path: String
        /// Byte offset up to which complete lines have been consumed.
        var offset: UInt64
    }

    private var positions: [String: Position] = [:]

    /// The newest refusal among these sessions, if any appeared since last time.
    ///
    /// Cheap by construction: a session whose transcript has not grown costs one
    /// `seekToEnd` and no read at all.
    func check(_ sessions: [AgentSession]) -> [UsageLimit] {
        var found: [UsageLimit] = []
        for session in sessions {
            guard session.provider == "claude-code", let path = session.transcriptPath else {
                continue
            }
            if let limit = check(sessionId: session.sessionId, path: path) {
                found.append(limit)
            }
        }
        return found
    }

    /// Forgets sessions that are gone, so the offsets cannot outlive their files.
    func prune(liveSessionIds: Set<String>) {
        positions = positions.filter { liveSessionIds.contains($0.key) }
    }

    private func check(sessionId: String, path: String) -> UsageLimit? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
            let size = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }

        let known = positions[sessionId]
        // A transcript that was replaced (resume writes a fresh file, or the path
        // changed) reads as a shrunken file; start over rather than seeking past
        // its end.
        let restart = known == nil || known!.path != path || known!.offset > size
        let start: UInt64 =
            restart
            ? size >= UInt64(Self.firstSightWindow) ? size - UInt64(Self.firstSightWindow) : 0
            : known!.offset

        guard size > start else {
            positions[sessionId] = Position(path: path, offset: size)
            return nil
        }

        var readFrom = start
        let available = size - start
        if available > UInt64(Self.maximumDelta) {
            readFrom = size - UInt64(Self.maximumDelta)
            DebugLog.log(
                "[usage] \(DebugLog.timestamp()) \(available / 1024) KiB appended to a transcript "
                    + "since the last look — reading the newest \(Self.maximumDelta / 1024) KiB")
        }

        guard (try? handle.seek(toOffset: readFrom)) != nil,
            let data = try? handle.read(upToCount: Int(size - readFrom)), !data.isEmpty
        else { return nil }

        // Shared with the Codex scanner: consuming only up to the last newline is
        // what makes the next read resume on a line boundary, and what stops a
        // half-written trailing line from being parsed as garbage.
        let (lines, consumed) = CodexRolloutParser.completeLines(in: data)
        positions[sessionId] = Position(path: path, offset: readFrom + UInt64(consumed))

        // Last one wins: a delta can hold a refusal and then a later resumption.
        var latest: UsageLimit?
        for line in lines {
            if let limit = ClaudeUsageLimit.parse(line: line) { latest = limit }
        }
        if let latest {
            DebugLog.log(
                "[usage] \(DebugLog.timestamp()) Claude reported \(latest.window.label) reached"
                    + (latest.resetsAt.map { ", resets \($0)" } ?? ", reset time unreadable"))
        }
        return latest
    }
}
