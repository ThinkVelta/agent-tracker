import Foundation

/// One place to run a tool and collect its output, shared by the updater and
/// the uninstaller. Detached from the main actor: codesign over a bundle or a
/// brew upgrade takes real time.
enum ProcessRunner {
    struct Result {
        let ok: Bool
        let output: String
    }

    static func run(
        _ tool: String, _ arguments: [String],
        environment: [String: String]? = nil
    ) async -> Result {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = arguments
            if let environment {
                task.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, override in override }
            }
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return Result(
                    ok: task.terminationStatus == 0,
                    output: String(bytes: data, encoding: .utf8) ?? "")
            } catch {
                return Result(ok: false, output: error.localizedDescription)
            }
        }.value
    }
}
