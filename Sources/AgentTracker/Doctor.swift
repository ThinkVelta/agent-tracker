import Foundation
import UserNotifications

/// `AgentTracker --doctor`: the mechanical half of `docs/troubleshooting.md`,
/// as a command.
///
/// **Read-only, and never prompts.** Both are load-bearing rather than tidy.
/// Read-only is what makes it safe to run on a machine that is already
/// misbehaving, and what stops it changing the thing it was asked to describe.
/// Never-prompts is what makes it safe for an agent to run unasked — a
/// diagnostic that puts a permission dialog on someone's screen has done harm
/// no report can repay. `DoctorSafetyTests` asserts this file calls none of the
/// prompting APIs, so the rule is checked rather than remembered.
///
/// One call is deliberately **not** made: Ghostty's Automation status. The
/// non-prompting query still blocks, measured at over 100 seconds against a
/// running-but-ungranted target, and a diagnostic that appears to hang is worse
/// than one that admits it skipped something. It is reported as not-checked,
/// with where to look instead.
enum Doctor {
    /// Runs every check and prints the report.
    ///
    /// - Returns: the process exit status — 0 when nothing failed, 1 when
    ///   something did. Warnings do not fail: "you have no statusline wrapper"
    ///   is worth knowing and is not a broken install.
    static func run() -> Int32 {
        let searched = FileManager.default.currentDirectoryPath
        let input = probe(searchingFrom: searched)
        let findings = Diagnosis.findings(input)

        print("agent-tracker doctor")
        print("  data:     \(SessionStore.baseDirectory.path)")
        print("  claude:   \(claudeDirectory().path)")
        // Printed because one check depends on it: a project-level statusLine is
        // found by walking up from here, so run from $HOME it can only ever
        // report nothing. Saying where it looked is the difference between "no
        // override" and "did not look where you meant".
        print("  searched: \(searched)")
        print("")

        // Width from the data, never a literal: a check name added later must
        // not be silently truncated out of someone's grep.
        let width = findings.map(\.check.count).max() ?? 0
        let indent = String(repeating: " ", count: width)
        for finding in findings {
            let name = finding.check.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(finding.level.label) \(name)  \(finding.detail)")
            if let anchor = finding.anchor {
                print("      \(indent)  -> docs/troubleshooting.md#\(anchor)")
            }
        }

        print("")
        print(
            "not checked: Ghostty Automation. The status query itself can block for "
                + "over a minute,\n             so it is left to Settings > General > "
                + "Permission to control Ghostty.")
        print("")
        print(Diagnosis.summary(findings))
        return Diagnosis.exitCode(findings)
    }

    // MARK: - Probes

    /// `~/.claude`, honouring the same override the rest of the app does, so a
    /// test run and a real run cannot silently describe different directories.
    private static func claudeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_CLAUDE_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func probe(searchingFrom searchRoot: String) -> Diagnosis.Input {
        var input = Diagnosis.Input()
        let claude = claudeDirectory()
        input.claudeDirectoryExists = directoryExists(claude)

        // Both user-scope files, merged. `settings.local.json` is where a
        // per-machine override lives, and a hook or statusLine placed there is
        // as real as one in `settings.json`.
        let (settings, state) = userSettings(in: claude)
        input.settingsState = state
        input.registeredHooks = Self.registeredHooks(in: settings)
        input.statusLineCommand = Self.statusLineCommand(in: settings)

        // The paths the registrations NAME, not the one this build would install
        // to. Every distinct command, because events can point at different ones
        // and checking a single command lets a healthy registration hide a
        // broken one.
        let installedPath = HookSetup.installedHookPath().path
        input.installedHookPath = installedPath
        input.hookScripts = resolveHookScripts(input.registeredHooks)

        // Freshness is about the script an upgrade would replace, so it prefers
        // the path this build installs to. A registration pointing elsewhere is
        // warned about separately rather than measured for staleness.
        let freshnessPath =
            input.hookScripts.compactMap(\.path).first { $0 == installedPath }
            ?? input.hookScripts.compactMap(\.path).first
            ?? installedPath
        input.hookFreshness = hookFreshness(
            at: freshnessPath,
            isPresent: FileManager.default.fileExists(atPath: freshnessPath))

        input.projectStatusLineOverride = projectStatusLineOverride(from: searchRoot)
        input.statuslinePayloadPresent = statuslinePayloadPresent(claude: claude)

        let sessions = SessionStore.loadStateFiles().map(\.session)
        input.sessionFileCount = sessions.count
        let live = sessions.filter { session in
            guard let pid = session.pid, pid > 0 else { return true }
            return SessionStore.isProcessAlive(pid)
        }
        input.staleSessionCount = sessions.count - live.count
        // Live only. Telling someone to /rename two sessions is absurd one line
        // after saying their processes are gone.
        input.largestSameProjectGroup = largestSameProjectGroup(live)

        input.accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
        input.notifications = notificationState()
        return input
    }

    /// Every distinct command the registrations run, with what is true of the
    /// file each one names. Grouped by command so a config registering the same
    /// script for seven events produces one finding rather than seven.
    static func resolveHookScripts(_ hooks: [Diagnosis.RegisteredHook]) -> [Diagnosis.HookScript] {
        var byCommand: [String: [String]] = [:]
        for hook in hooks {
            byCommand[hook.command, default: []].append(hook.event)
        }
        return byCommand.keys.sorted().map { command in
            let path = scriptPath(fromCommand: command)
            return Diagnosis.HookScript(
                events: byCommand[command] ?? [],
                command: command,
                path: path,
                exists: path.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                isExecutable: path.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
            )
        }
    }

    /// `settings.json` plus `settings.local.json`, the latter winning per key.
    ///
    /// Unreadable beats absent: if either file exists and will not parse, the
    /// answer to "what is configured" is *unknown*, and saying "nothing" would
    /// send the user to an installer that fails on the same file.
    static func userSettings(in claude: URL) -> ([String: Any], Diagnosis.SettingsState) {
        var merged: [String: Any] = [:]
        var anyParsed = false
        var broken: [String] = []
        for name in ["settings.json", "settings.local.json"] {
            let url = claude.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let parsed = readJSON(url) else {
                broken.append(url.path)
                continue
            }
            anyParsed = true
            merged.merge(parsed) { _, newer in newer }
        }
        if !broken.isEmpty { return (merged, .unreadable(broken)) }
        return (merged, anyParsed ? .parsed : .absent)
    }

    /// Which hook events run our script, and what command each runs.
    ///
    /// Structure-aware on purpose. A substring search for `agent-tracker` over
    /// the whole file also matches the `statusLine` entry, so it reports
    /// "installed" for a config with every hook removed — the failure this
    /// check exists to catch, and the trap `docs/troubleshooting.md` warns
    /// readers about.
    static func registeredHooks(in settings: [String: Any]) -> [Diagnosis.RegisteredHook] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var registered: [Diagnosis.RegisteredHook] = []
        for (event, value) in hooks {
            // `compactMap`, not a whole-array cast: one stray element must not
            // drop an event that is correctly registered beside it.
            let entries = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            for entry in entries {
                let commands = (entry["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
                for command in commands {
                    guard let text = command["command"] as? String,
                        text.contains("agent-tracker-hook")
                    else { continue }
                    registered.append(Diagnosis.RegisteredHook(event: event, command: text))
                }
            }
        }
        return registered.sorted { $0.event < $1.event }
    }

    /// The script path out of a hook command line, or nil when it cannot be
    /// told.
    ///
    /// Finds the *token* that names the hook rather than assuming the command
    /// begins with it, because a perfectly valid registration can run it through
    /// an interpreter — `python3 …/agent-tracker-hook.py claude`. Treating the
    /// whole prefix as a path there yields something that does not exist, and a
    /// confident failure about a working install.
    ///
    /// Returns nil rather than guessing when no token looks like the hook. A
    /// diagnostic that cannot locate the script should say so, not accuse.
    static func scriptPath(fromCommand command: String) -> String? {
        let hookToken = tokenize(command).first {
            $0.hasSuffix("agent-tracker-hook.py") || $0.hasSuffix("agent-tracker-hook")
        }
        guard let hookToken else { return nil }
        return (hookToken as NSString).expandingTildeInPath
    }

    /// Splits a command the way a shell would, for the two quoting styles
    /// `shlex.quote` produces. Not a general shell parser: it exists to undo
    /// exactly what the installer wrote.
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var iterator = command.makeIterator()
        while let character = iterator.next() {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Claude's single statusline slot, whatever is in it.
    static func statusLineCommand(in settings: [String: Any]) -> String? {
        guard let statusLine = settings["statusLine"], !(statusLine is NSNull) else { return nil }
        if let command = statusLine as? String { return command }
        return (statusLine as? [String: Any])?["command"] as? String
    }

    /// A `.claude/settings.json` at or above `start` that sets its own
    /// `statusLine`, displacing the wrapper for sessions there.
    ///
    /// **Only `statusLine`, deliberately.** Hooks merge: a project can add its
    /// own and ours still run, measured against this very repo, which defines
    /// two hook events of its own and whose sessions are tracked normally.
    /// `statusLine` is a single command and cannot merge, so a project-level one
    /// wins and the usage and context readings stop arriving.
    static func projectStatusLineOverride(from start: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var directory = URL(fileURLWithPath: start).standardizedFileURL
        for _ in 0..<32 {
            if directory == home || directory.path == "/" { return nil }
            // Both project-scope files, for the same reason the user-scope probe
            // reads both: a `statusLine` in `settings.local.json` displaces the
            // wrapper exactly as one in `settings.json` does.
            for name in ["settings.json", "settings.local.json"] {
                let candidate = directory.appendingPathComponent(".claude/\(name)")
                if let settings = readJSON(candidate), let value = settings["statusLine"],
                    !(value is NSNull)
                {
                    return candidate.path
                }
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory { return nil }
            directory = parent
        }
        return nil
    }

    /// Both sources the app actually reads. Ignoring the second would warn that
    /// context is missing for someone whose own script tees the payload, which
    /// the docs describe as a supported setup.
    private static func statuslinePayloadPresent(claude: URL) -> Bool {
        let sources = [
            claude.appendingPathComponent("statusline-last.json"),
            SessionStore.claudeStatuslineURL,
        ]
        return sources.contains { url in
            (try? Data(contentsOf: url)).flatMap { StatuslineDirectory.parse($0) } != nil
        }
    }

    private static func hookFreshness(at path: String, isPresent: Bool) -> Diagnosis.HookFreshness {
        // No reachable bundled copy means no comparison — "cannot tell", never
        // "up to date". A detached binary is the normal case for that.
        guard isPresent, let integrations = HookSetup.installerDirectory(),
            let bundled = try? Data(
                contentsOf: integrations.appendingPathComponent("agent-tracker-hook.py"))
        else { return .unknown }
        // `hookNeedsRefresh` folds "unreadable" into "needs replacing", which is
        // right for the installer and wrong for a report: unreadable is not
        // something the user fixes by updating.
        guard let onDisk = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .unknown
        }
        return HookSetup.hookNeedsRefresh(isInstalled: true, installed: onDisk, bundled: bundled)
            ? .stale : .current
    }

    /// How many live sessions share the directory that titles their row.
    private static func largestSameProjectGroup(_ sessions: [AgentSession]) -> Int {
        var counts: [String: Int] = [:]
        for session in sessions {
            counts[session.projectKey, default: 0] += 1
        }
        return counts.values.max() ?? 0
    }

    /// Bounded, because this file's whole argument for skipping the Automation
    /// check is that a diagnostic must not appear to hang — and this is an XPC
    /// round trip before the first line of output. Measured at ~0.01s; the
    /// timeout is for the day that stops being true.
    private static func notificationState() -> Diagnosis.NotificationState {
        guard Notifications.isAvailable else { return .unavailable }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: UNAuthorizationStatus = .notDetermined
        Task {
            status = await Notifications.authorizationStatus()
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else { return .unavailable }
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    // MARK: - Small helpers

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
