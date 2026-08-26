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

    /// Presence means the CLI has left its home directory behind — the
    /// reliable signal from a GUI app, where PATH is not the user's shell's.
    static func claudePresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        directoryExists(home.appendingPathComponent(".claude"))
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

    /// Where the hook script the agent runs actually lives, once installed.
    static func installedHookPath(
        base: URL = SessionStore.baseDirectory
    ) -> URL {
        base.appendingPathComponent("bin/agent-tracker-hook.py")
    }

    /// Whether the installed hook script needs replacing with the one this app
    /// ships.
    ///
    /// Pure, so the rule is testable without touching a disk. Four cases and
    /// only one of them acts:
    ///
    /// - No bundled copy: nothing to refresh *from*. A `swift run` build with
    ///   no repo beside it is the honest example.
    /// - Not installed: **never install one here.** Putting the script in
    ///   place is the integration installer's job, because it also edits the
    ///   user's `settings.json`, and a config edit is a thing somebody agrees
    ///   to rather than something an app does on launch.
    /// - Identical: nothing to do, which is every launch after the first.
    /// - Different, **or present and unreadable**: refresh.
    ///
    /// Existence and readability are separate questions, and conflating them
    /// was the first version's bug: a script that is there but cannot be read —
    /// truncated by a full disk, half-written, mode-mangled — would have been
    /// treated as "not installed" and left exactly as it was. That is the case
    /// where replacing it matters most, and the one where the agent is running
    /// something broken right now.
    static func hookNeedsRefresh(isInstalled: Bool, installed: Data?, bundled: Data?) -> Bool {
        guard let bundled, isInstalled else { return false }
        // `installed` nil means unreadable, which is never equal to the bundle.
        return installed != bundled
    }

    /// Brings the installed hook script up to date with the one in this app.
    ///
    /// The two version independently and nothing used to reconcile them: the
    /// app is replaced by an upgrade or a download, while the script is written
    /// once by the installer and then left alone for ever. Measured on a real
    /// machine, an app several versions ahead of its hook wrote 27 state files
    /// the app had been taught to ignore — silently, because a hook and an app
    /// that disagree still both work, they just stop agreeing about what they
    /// are saying to each other.
    ///
    /// No backup. `~/.agent-tracker/bin` is this app's own directory and the
    /// file is byte-identical to one inside the bundle, so there is nothing
    /// here to lose that cannot be reproduced — unlike a user's `settings.json`,
    /// which the installers do back up.
    /// - Parameter source: where the current script is, defaulting to the copy
    ///   this app carries. Injectable because the test runner is neither an app
    ///   bundle nor the binary `installerDirectory()` walks up from, so without
    ///   it the end-to-end path could only be tested on a machine that happened
    ///   to look like a real install.
    @discardableResult
    static func refreshInstalledHook(
        base: URL = SessionStore.baseDirectory,
        source: URL? = installerDirectory()?.appendingPathComponent("agent-tracker-hook.py")
    ) -> Bool {
        let installedPath = installedHookPath(base: base)
        let installed = try? Data(contentsOf: installedPath)
        let bundled = source.flatMap { try? Data(contentsOf: $0) }
        let isInstalled = FileManager.default.fileExists(atPath: installedPath.path)
        guard hookNeedsRefresh(isInstalled: isInstalled, installed: installed, bundled: bundled),
            let bundled
        else {
            return false
        }
        do {
            try bundled.write(to: installedPath, options: .atomic)
            // An atomic write replaces the file, so the executable bit goes
            // with the old one. The agent runs this script directly.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: installedPath.path)
            DebugLog.log(
                "[hook] \(DebugLog.timestamp()) refreshed \(installedPath.path) from the bundle")
            return true
        } catch {
            // Never fatal: a stale hook still reports, it just reports what an
            // older app expected.
            DebugLog.log(
                "[hook] \(DebugLog.timestamp()) could not refresh \(installedPath.path): \(error)")
            return false
        }
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
        let succeeded: Bool
        /// Combined stdout+stderr, surfaced verbatim on failure — the
        /// installers print their own precise errors and manual fallbacks.
        let output: String
    }

    /// Runs the idempotent installer off the main thread. It backs up the
    /// config before editing and exits non-zero on refusal.
    static func runInstaller(arguments: [String] = []) async -> InstallOutcome {
        guard let directory = installerDirectory() else {
            return InstallOutcome(
                succeeded: false,
                output: "installer script not found; run ./install.sh from the repo instead")
        }
        let script = directory.appendingPathComponent(Onboarding.installerScript)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [script.path] + arguments
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
                            succeeded: process.terminationStatus == 0,
                            output: String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    continuation.resume(
                        returning: InstallOutcome(
                            succeeded: false,
                            output: "could not launch installer: \(error.localizedDescription)"))
                }
            }
        }
    }
}
