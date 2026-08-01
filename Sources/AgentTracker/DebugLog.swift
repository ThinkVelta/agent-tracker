import Foundation

/// Wall-clock stamp for debug traces: the cadence of `[store]`/`[codex-scan]`
/// lines is itself diagnostic (watcher storm vs the 30s heartbeat), which a
/// bare stream of lines can't show.
enum DebugLog {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
