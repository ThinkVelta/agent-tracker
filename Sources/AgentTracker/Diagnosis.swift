import Foundation

/// What `--doctor` concludes, kept pure so every rule is testable without a
/// filesystem. The I/O that feeds it lives in `Doctor`.
///
/// Same split as `Onboarding` (rules) and `HookSetup` (probes), for the same
/// reason: a diagnostic whose logic can only be exercised by arranging a real
/// machine into a broken state is a diagnostic nobody checks.
enum Diagnosis {
    /// The seven events the installer registers.
    ///
    /// Duplicated from `integrations/install-claude-code.sh`, because Swift
    /// cannot read a shell array at compile time. `DiagnosisTests` reads the
    /// installer and asserts these two lists agree, so the duplication is
    /// checked rather than hoped — without that test this constant would
    /// silently rot the first time the installer gained an event.
    static let expectedHookEvents: Set<String> = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PreCompact",
        "Stop",
        "Notification",
        "SessionEnd",
    ]

    /// How loudly a finding should read.
    ///
    /// `unknown` is deliberately not `warn`. A check that could not run is not
    /// evidence of a problem, and colouring it as one trains people to ignore
    /// the colour — which is the failure mode that makes a doctor worse than
    /// no doctor.
    enum Level: String, Equatable {
        case ok
        case warn
        case fail
        case unknown

        var label: String {
            switch self {
            case .ok: return "ok   "
            case .warn: return "WARN "
            case .fail: return "FAIL "
            case .unknown: return "?    "
            }
        }
    }

    struct Finding: Equatable {
        var level: Level
        /// Short, stable, greppable. Not a sentence. `Doctor` pads the column to
        /// the longest of these rather than to a fixed width, so a name added
        /// later cannot be silently truncated out of someone's `grep`.
        var check: String
        var detail: String
        /// The `docs/troubleshooting.md` section that explains this, where one
        /// exists. Many findings have none: the command says *what*, and only
        /// some of what it can say has a page behind it.
        var anchor: String?
    }

    /// Whether the installed hook script differs from the bundled one.
    ///
    /// `unknown` covers two different "cannot tell" cases — no bundled copy is
    /// reachable, or the installed script cannot be read — because reporting
    /// either as `stale` names a cause the user cannot act on.
    enum HookFreshness: Equatable {
        case current
        case stale
        case unknown
    }

    /// What `~/.claude/settings.json` turned out to be.
    ///
    /// "Absent" and "unreadable" have opposite remedies, and conflating them is
    /// actively harmful: the installer does a bare `json.load`, so telling
    /// someone with a malformed config to run it hands them a traceback.
    enum SettingsState: Equatable {
        case parsed
        case absent
        /// Carries the files that would not parse. Two are read, either can be
        /// the broken one, and naming the wrong one sends someone to a file
        /// that is fine.
        case unreadable([String])
    }

    /// What Claude Code is configured to run for a given hook event.
    struct RegisteredHook: Equatable {
        var event: String
        /// The command as written, so the path can be checked rather than
        /// assumed. The whole point of the hook checks is that a registration
        /// can point somewhere that does not exist.
        var command: String
    }

    /// What we could work out about the path the registration names.
    ///
    /// `unresolved` exists so a command shape nobody anticipated — the hook run
    /// through an interpreter, say — is reported as "cannot tell" rather than
    /// as a broken install. The check was added to catch a registration
    /// pointing at nothing; it must not invent one.
    enum RegisteredHookPath: Equatable {
        case none
        case resolved(String)
        case unresolved(String)
    }

    /// Whether notifications would actually arrive.
    ///
    /// `notAsked` is separate from `denied` because a fresh machine has never
    /// been asked — the feature is off by default — and warning about a refusal
    /// nobody made is how a diagnostic teaches people to ignore it.
    enum NotificationState: Equatable {
        case authorized
        case denied
        case notAsked
        /// No answer available: outside an app bundle the API reports on the
        /// process rather than on the user's settings.
        case unavailable
    }

    /// Everything the rules depend on, already read off disk.
    struct Input: Equatable {
        var claudeDirectoryExists = false
        var settingsState: SettingsState = .absent
        var registeredHooks: [RegisteredHook] = []
        /// What could be worked out about the path the registration names.
        var registeredHookPath: RegisteredHookPath = .none
        /// Where *this build* would install the hook. Compared against the
        /// registered path here rather than in the probe, so the rule about
        /// what a mismatch means is testable like every other rule.
        var installedHookPath = ""
        /// Whether the path the *registration* names exists and is executable —
        /// a different question from whether the path this build would install
        /// to exists.
        var registeredHookScriptPresent = false
        var registeredHookScriptExecutable = false
        var hookFreshness: HookFreshness = .unknown
        var statusLineCommand: String?
        /// Path of a project-level settings file that sets its own `statusLine`,
        /// if the directory searched is inside one. Hooks are not checked: they
        /// merge with the user-level ones rather than replacing them.
        var projectStatusLineOverride: String?
        var sessionFileCount = 0
        /// Sessions whose recorded pid is gone. They are pruned by the running
        /// app, so a non-zero count here is normal while it is not running.
        var staleSessionCount = 0
        /// The largest group of **live** sessions sharing a project. More than
        /// one is the case click-to-focus cannot always resolve.
        var largestSameProjectGroup = 0
        /// Whether any statusline source has a payload — the wrapper's capture
        /// or a user's own `statusline-last.json`.
        var statuslinePayloadPresent = false
        var accessibilityGranted = false
        var notifications: NotificationState = .unavailable
    }

    /// The whole report, in the order it prints.
    ///
    /// Ordered by what blocks what: a missing `~/.claude` makes every hook
    /// finding meaningless, so it comes first and nothing downstream is claimed.
    static func findings(_ input: Input) -> [Finding] {
        var findings: [Finding] = []

        guard input.claudeDirectoryExists else {
            findings.append(
                Finding(
                    level: .warn, check: "claude",
                    detail: "no ~/.claude — Claude Code has not run on this machine",
                    anchor: "no-sessions-appear-at-all"))
            return findings
        }
        findings.append(
            Finding(level: .ok, check: "claude", detail: "~/.claude present", anchor: nil))

        findings.append(contentsOf: hookFindings(input))
        if let override = input.projectStatusLineOverride {
            findings.append(
                Finding(
                    level: .warn, check: "project statusline",
                    detail:
                        "\(override) sets its own statusLine, so sessions in that project "
                        + "report no usage or context",
                    anchor: "usage-numbers-5h--7d-are-missing"))
        }
        findings.append(statuslineFinding(input))
        findings.append(contentsOf: sessionFindings(input))
        findings.append(contentsOf: permissionFindings(input))
        return findings
    }

    /// The exit status. Only a real failure is non-zero: a warning is something
    /// to know, and a script that treats "you have no statusline wrapper" as a
    /// build break would be reasonable to stop running.
    static func exitCode(_ findings: [Finding]) -> Int32 {
        findings.contains { $0.level == .fail } ? 1 : 0
    }

    /// The closing line. Distinguishes "nothing to do" from "nothing *failed*",
    /// because printing "No problems found." above warnings the user is being
    /// asked to act on is the report contradicting itself.
    static func summary(_ findings: [Finding]) -> String {
        let failures = findings.filter { $0.level == .fail }.count
        let warnings = findings.filter { $0.level == .warn }.count
        if failures > 0 {
            return "\(failures) problem(s) found, \(warnings) warning(s)."
        }
        return warnings == 0 ? "No problems found." : "No failures. \(warnings) warning(s)."
    }

    // MARK: - Rules

    private static func hookFindings(_ input: Input) -> [Finding] {
        // An unreadable config is not an uninstalled one, and the two have
        // opposite remedies. "None registered — run ./install.sh" would name a
        // false cause and prescribe a command that fails on the same file.
        if case .unreadable(let broken) = input.settingsState {
            return [
                Finding(
                    level: .unknown, check: "hooks",
                    detail:
                        "could not parse \(broken.joined(separator: ", ")) — fix the JSON first",
                    anchor: "no-sessions-appear-at-all")
            ]
        }

        let registered = Set(input.registeredHooks.map(\.event))
        let missing = expectedHookEvents.subtracting(registered).sorted()

        if registered.isEmpty {
            return [
                Finding(
                    level: .fail, check: "hooks",
                    detail: "none registered in ~/.claude/settings.json — run ./install.sh",
                    anchor: "no-sessions-appear-at-all")
            ]
        }

        var findings: [Finding] = []
        if missing.isEmpty {
            findings.append(
                Finding(
                    level: .ok, check: "hooks",
                    detail: "all \(expectedHookEvents.count) events registered", anchor: nil))
        } else {
            findings.append(
                Finding(
                    level: .fail, check: "hooks",
                    detail:
                        "\(registered.count)/\(expectedHookEvents.count) registered, missing: "
                        + missing.joined(separator: ", "),
                    anchor: "no-sessions-appear-at-all"))
        }
        findings.append(contentsOf: hookScriptFindings(input))
        return findings
    }

    /// Checks the script the *registration names*, not the one this build would
    /// install.
    ///
    /// They are usually the same path, and the case where they differ is the
    /// whole point: a `settings.json` carried between machines, or restored from
    /// dotfiles under a different username, registers a path that does not
    /// exist — while every other check still passes, so the report would say the
    /// install is healthy when no event has ever been delivered.
    private static func hookScriptFindings(_ input: Input) -> [Finding] {
        if case .unresolved(let command) = input.registeredHookPath {
            return [
                Finding(
                    level: .unknown, check: "hook script",
                    detail: "can't tell which file this runs: \(command)", anchor: nil)
            ]
        }
        // Only a path we actually resolved can be somewhere unexpected.
        var registeredElsewhere: String?
        if case .resolved(let path) = input.registeredHookPath, path != input.installedHookPath {
            registeredElsewhere = path
        }

        guard input.registeredHookScriptPresent else {
            return [
                Finding(
                    level: .fail, check: "hook script",
                    detail:
                        "the registered hooks point at a path that does not exist"
                        + (registeredElsewhere.map { " (\($0))" } ?? "")
                        + " — run ./install.sh",
                    anchor: "no-sessions-appear-at-all")
            ]
        }

        var findings = [
            Finding(level: .ok, check: "hook script", detail: "present", anchor: nil)
        ]
        if let elsewhere = registeredElsewhere {
            findings.append(
                Finding(
                    level: .warn, check: "hook script",
                    detail:
                        "registered at \(elsewhere), which is not where this build installs — "
                        + "it exists, so it runs, but upgrades will not refresh it",
                    anchor: nil))
        }
        if !input.registeredHookScriptExecutable {
            // Registered, present, and silently doing nothing: the worst shape,
            // because every other check passes.
            findings.append(
                Finding(
                    level: .fail, check: "hook script", detail: "not executable — chmod +x it",
                    anchor: "no-sessions-appear-at-all"))
        }
        switch input.hookFreshness {
        case .current:
            findings.append(
                Finding(
                    level: .ok, check: "hook version", detail: "matches this build", anchor: nil))
        case .stale:
            findings.append(
                Finding(
                    level: .warn, check: "hook version",
                    detail: "older than this build — launch the app, or run ./install.sh",
                    anchor: nil))
        case .unknown:
            findings.append(
                Finding(
                    level: .unknown, check: "hook version",
                    detail: "can't compare — no readable copy on both sides", anchor: nil))
        }
        return findings
    }

    /// A payload arriving from *anywhere* means context readings and exact
    /// window titles work; only the usage windows need the wrapper
    /// specifically. Saying "no usage or context" whenever the wrapper is
    /// absent would be wrong about half of it for anyone teeing the payload
    /// themselves, which the docs describe as a supported route.
    private static func statuslineFinding(_ input: Input) -> Finding {
        let usesWrapper = input.statusLineCommand?.contains("agent-tracker-statusline") == true

        guard let command = input.statusLineCommand, !command.isEmpty else {
            return Finding(
                level: .warn, check: "statusline",
                detail: input.statuslinePayloadPresent
                    ? "no statusLine configured, but a payload is being captured elsewhere — "
                        + "no usage readings"
                    : "no statusLine configured — no usage, context or exact window titles",
                anchor: "usage-numbers-5h--7d-are-missing")
        }
        _ = command
        guard usesWrapper else {
            return Finding(
                level: .warn, check: "statusline",
                detail: input.statuslinePayloadPresent
                    ? "a statusLine is set and something is writing a payload, so context works "
                        + "— but it is not the wrapper, so there are no usage readings"
                    : "a statusLine is set but it is not the wrapper — no usage or context "
                        + "readings",
                anchor: "usage-numbers-5h--7d-are-missing")
        }
        guard input.statuslinePayloadPresent else {
            return Finding(
                level: .warn, check: "statusline",
                detail: "wrapper installed but nothing captured yet — start a session",
                anchor: "a-session-shows-no-context-percentage")
        }
        return Finding(
            level: .ok, check: "statusline", detail: "wrapper installed, payload captured",
            anchor: nil)
    }

    private static func sessionFindings(_ input: Input) -> [Finding] {
        var findings: [Finding] = []
        if input.sessionFileCount == 0 {
            findings.append(
                Finding(
                    level: .warn, check: "sessions",
                    detail:
                        "none tracked — sessions running before install never report; restart them",
                    anchor: "no-sessions-appear-at-all"))
        } else {
            findings.append(
                Finding(
                    level: .ok, check: "sessions", detail: "\(input.sessionFileCount) tracked",
                    anchor: nil))
        }
        if input.staleSessionCount > 0 {
            findings.append(
                Finding(
                    level: .warn, check: "stale sessions",
                    detail:
                        "\(input.staleSessionCount) file(s) whose process is gone — the running "
                        + "app prunes these, so this is expected while it is not running",
                    anchor: nil))
        }
        if input.largestSameProjectGroup > 1 {
            findings.append(
                Finding(
                    level: .warn, check: "ambiguous rows",
                    detail:
                        "\(input.largestSameProjectGroup) live sessions share a project, so "
                        + "click-to-focus cannot always tell them apart — /rename one. This "
                        + "check groups by directory and cannot see names, so it keeps saying "
                        + "so afterwards",
                    anchor: "click-to-focus-opens-the-wrong-terminal"))
        }
        return findings
    }

    private static func permissionFindings(_ input: Input) -> [Finding] {
        var findings = [
            input.accessibilityGranted
                ? Finding(level: .ok, check: "accessibility", detail: "granted", anchor: nil)
                : Finding(
                    level: .warn, check: "accessibility",
                    detail: "not granted — click-to-focus will not raise windows",
                    anchor: "click-to-focus-does-nothing-at-all")
        ]
        switch input.notifications {
        case .authorized:
            findings.append(
                Finding(level: .ok, check: "notifications", detail: "authorized", anchor: nil))
        case .denied:
            findings.append(
                Finding(
                    level: .warn, check: "notifications",
                    detail: "denied — banners and continue receipts will not appear", anchor: nil))
        case .notAsked:
            // Not a warning. Banners are off by default, so never having been
            // asked is what a correct fresh install looks like.
            findings.append(
                Finding(
                    level: .ok, check: "notifications",
                    detail: "not asked yet — banners are off by default", anchor: nil))
        case .unavailable:
            findings.append(
                Finding(
                    level: .unknown, check: "notifications",
                    detail: "can't tell — not running from the installed app bundle", anchor: nil))
        }
        return findings
    }
}
