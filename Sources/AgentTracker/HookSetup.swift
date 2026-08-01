import Foundation

/// Probes and drives the agent-hook installation that onboarding fronts.
/// All functions take a home directory so tests never touch the real one.
enum HookSetup {
    /// A hook is "installed" when the agent's config references the hook
    /// script. Detection is a plain substring probe: the installers do the
    /// structure-aware editing, and a boolean is all onboarding needs.
    static func claudeHookInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Bool
    {
        configReferencesHook(home.appendingPathComponent(".claude/settings.json"))
    }

    static func codexHookInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Bool
    {
        configReferencesHook(home.appendingPathComponent(".codex/config.toml"))
    }

    /// Presence means the CLI has left its home directory behind — the
    /// reliable signal from a GUI app, where PATH is not the user's shell's.
    static func claudePresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        directoryExists(home.appendingPathComponent(".claude"))
    }

    static func codexPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        directoryExists(home.appendingPathComponent(".codex"))
    }

    private static func configReferencesHook(_ file: URL) -> Bool {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return contents.contains("agent-tracker-hook")
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Where the installer scripts live. A bundled app carries them in its
    /// Resources (copied by scripts/make-app.sh) so onboarding works with no
    /// repo checked out; a `swift run` build reaches back into the repo the
    /// binary was built in.
    static func installerDirectory() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("integrations")
            if directoryExists(bundled) { return bundled }
        }
        // .build/{debug,release}/AgentTracker → repo root is two levels up
        // from the binary's directory (three with the arch triple in between).
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var probe = binary.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = probe.appendingPathComponent("integrations")
            if directoryExists(candidate) { return candidate }
            probe.deleteLastPathComponent()
        }
        return nil
    }

    struct InstallOutcome {
        let agent: Onboarding.Agent
        let succeeded: Bool
        /// Combined stdout+stderr, surfaced verbatim on failure — the
        /// installers print their own precise errors and manual fallbacks.
        let output: String
    }

    /// Runs one agent's idempotent installer off the main thread. The
    /// installers back up configs before editing and exit non-zero on refusal
    /// (e.g. an unrelated Codex notify setting they will not clobber).
    static func runInstaller(for agent: Onboarding.Agent) async -> InstallOutcome {
        guard let directory = installerDirectory() else {
            return InstallOutcome(
                agent: agent, succeeded: false,
                output: "installer scripts not found — run ./install.sh from the repo instead")
        }
        let script = directory.appendingPathComponent(agent.installerScript)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [script.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    // Drain the pipe BEFORE waiting for exit: a child that
                    // writes more than the pipe buffer (64KB) blocks on write
                    // while waitUntilExit blocks on it — a mutual deadlock
                    // that would leave onboarding stuck at "running" forever.
                    // readDataToEndOfFile returns at EOF, i.e. when the child
                    // exits and the write end closes.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: InstallOutcome(
                            agent: agent,
                            succeeded: process.terminationStatus == 0,
                            output: String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    continuation.resume(
                        returning: InstallOutcome(
                            agent: agent, succeeded: false,
                            output: "could not launch installer: \(error.localizedDescription)"))
                }
            }
        }
    }
}
