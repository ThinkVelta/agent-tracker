import Foundation

/// The app's trace channel (`[ui]`, `[focus]`, `[store]`, `[codex-scan]`,
/// `[auto-ack]`). Every line goes to stdout — visible under `swift run` — AND
/// to `~/.agent-tracker/logs/agent-tracker.log`, because the installed app is
/// launched by `open` and its stdout goes nowhere: without the file, "paste
/// your `[focus]` trace" is advice only developers can follow.
///
/// Thread-safe: the scanner worker logs from its own queue. Appends are
/// funneled through one serial queue; the file is trimmed in place when it
/// outgrows its cap, keeping the newest half.
enum DebugLog {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned: on a non-POSIX locale or non-Gregorian calendar the stamps
        // drift from the ASCII yyyy-MM-dd/HH:mm:ss shape tooling greps for.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func timestamp() -> String {
        formatter.string(from: Date())
    }

    static let shared = FileSink()

    /// Print + persist. The one call every trace site routes through.
    static func log(_ message: String) {
        print(message)
        shared.append(message)
    }

    final class FileSink: @unchecked Sendable {
        /// Trim when the log outgrows this; keep the newest `keepBytes`.
        /// Sized so months of normal traces fit while one runaway loop can't
        /// eat a disk.
        let maxBytes: Int
        let keepBytes: Int
        let fileURL: URL

        private let queue = DispatchQueue(label: "agent-tracker.debug-log")
        private let dateStamp: DateFormatter

        /// The default sink lives beside the session state so
        /// `AGENT_TRACKER_DIR` keeps tests and previews hermetic.
        convenience init() {
            self.init(
                directory: SessionStore.sessionsDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("logs"))
        }

        init(directory: URL, maxBytes: Int = 2 * 1024 * 1024) {
            self.fileURL = directory.appendingPathComponent("agent-tracker.log")
            self.maxBytes = maxBytes
            self.keepBytes = maxBytes / 2
            dateStamp = DateFormatter()
            // Same pinning as the time stamp: the file format is a contract.
            dateStamp.locale = Locale(identifier: "en_US_POSIX")
            dateStamp.calendar = Calendar(identifier: .gregorian)
            dateStamp.dateFormat = "yyyy-MM-dd"
        }

        func append(_ message: String) {
            queue.async { [self] in appendLocked(message) }
        }

        /// Blocks until every queued line is on disk — for tests.
        func flush() {
            queue.sync {}
        }

        private func appendLocked(_ message: String) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Trace lines carry HH:mm:ss; the file spans days, so each
                // persisted line gets the date too.
                let line = "\(dateStamp.string(from: Date())) \(message)\n"
                if !fileManager.fileExists(atPath: fileURL.path) {
                    try Data(line.utf8).write(to: fileURL)
                } else {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                }
                // Both paths trim: the first-ever write can itself be the
                // oversized one, and the cap is a promise, not a tendency.
                trimLocked(fileManager: fileManager)
            } catch {
                // Tracing must never break the app; stdout still has the line.
            }
        }

        private func trimLocked(fileManager: FileManager) {
            guard
                let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size]
                    as? Int, size > maxBytes,
                let data = try? Data(contentsOf: fileURL)
            else { return }
            var kept = data.suffix(keepBytes)
            // Cut on a line boundary so the file never opens mid-line. A
            // window with no newline at all is one pathological oversized
            // line — drop it entirely rather than keep a fragment; the next
            // append starts the file clean.
            if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) {
                kept = kept[kept.index(after: newline)...]
            } else {
                kept = Data()
            }
            try? kept.write(to: fileURL, options: .atomic)
        }
    }
}
