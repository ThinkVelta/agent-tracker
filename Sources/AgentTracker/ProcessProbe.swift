import Foundation

/// Short-lived subprocess probes (lsof, pgrep) used for Codex liveness checks.
enum ProcessProbe {
    /// Runs a short-lived tool with a hard timeout, off the main thread.
    /// Returns stdout on normal termination (any exit code), nil on launch
    /// failure or timeout (the process is killed on expiry).
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Drain stdout on a separate queue so a large output can't deadlock the
        // pipe while we wait for termination.
        let buffer = OutputBuffer()
        let reader = DispatchQueue(label: "agent-tracker.process-probe.read")
        reader.async { buffer.data = stdout.fileHandleForReading.readDataToEndOfFile() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                // Guard on OUR child still running: a raw-PID kill after the
                // child exited could hit an unrelated process that reused it.
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            return nil
        }
        reader.sync {}  // wait for the drain to finish
        return String(data: buffer.data, encoding: .utf8)
    }

    /// Parses `lsof -F pn` output ("p<pid>" then "n<path>" lines) into
    /// {rolloutPath: pid} for .jsonl files under the watched root.
    static func parseLsofOutput(_ output: String, rootPath: String) -> [String: Int] {
        var result: [String: Int] = [:]
        var currentPid: Int?
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                currentPid = Int(value)
            case "n":
                if value.hasSuffix(".jsonl"), value.hasPrefix(prefix), let pid = currentPid {
                    result[value] = pid
                }
            default:
                break
            }
        }
        return result
    }
}

private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}
