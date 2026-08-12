import Foundation
import Testing

@testable import AgentTracker

@Suite("Diagnosis")
struct DiagnosisTests {
    /// A machine with nothing wrong, as the baseline every case below deviates
    /// from by exactly one field.
    private var healthy: Diagnosis.Input {
        Diagnosis.Input(
            claudeDirectoryExists: true,
            settingsState: .parsed,
            registeredHooks: Diagnosis.expectedHookEvents.sorted().map {
                Diagnosis.RegisteredHook(
                    event: $0, command: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude"
                )
            },
            registeredHookPath: .resolved("/Users/dev/.agent-tracker/bin/agent-tracker-hook.py"),
            installedHookPath: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py",
            registeredHookScriptPresent: true,
            registeredHookScriptExecutable: true,
            hookFreshness: .current,
            statusLineCommand: "~/.agent-tracker/bin/agent-tracker-statusline.py",
            projectStatusLineOverride: nil,
            sessionFileCount: 3,
            staleSessionCount: 0,
            largestSameProjectGroup: 1,
            statuslinePayloadPresent: true,
            accessibilityGranted: true,
            notifications: .authorized)
    }

    private func hooks(_ events: [String]) -> [Diagnosis.RegisteredHook] {
        events.map {
            Diagnosis.RegisteredHook(
                event: $0, command: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude")
        }
    }

    private func find(_ findings: [Diagnosis.Finding], _ check: String) -> Diagnosis.Finding? {
        findings.first { $0.check == check }
    }

    @Test("a healthy machine fails nothing and exits 0")
    func healthyIsSilent() {
        let findings = Diagnosis.findings(healthy)
        #expect(!findings.contains { $0.level == .fail })
        #expect(!findings.contains { $0.level == .warn })
        #expect(Diagnosis.exitCode(findings) == 0)
    }

    // MARK: - Hooks

    /// The case the whole command exists for. A partial registration is the one
    /// state that looks fine from every angle a human checks: the file mentions
    /// agent-tracker, sessions sometimes appear, and nothing is obviously wrong.
    @Test("a partial hook registration names the missing events")
    func partialRegistrationIsAFailure() {
        var input = healthy
        input.registeredHooks = hooks(["Stop", "SessionStart"])
        let finding = find(Diagnosis.findings(input), "hooks")
        #expect(finding?.level == .fail)
        #expect(finding?.detail.contains("PreToolUse") == true)
        #expect(finding?.detail.contains("SessionEnd") == true)
        // Not the ones that ARE registered.
        #expect(finding?.detail.contains("missing: Notification, PreCompact") == true)
    }

    @Test("no hooks at all says so, and points at the installer")
    func noHooksIsAFailure() {
        var input = healthy
        input.registeredHooks = []
        let finding = find(Diagnosis.findings(input), "hooks")
        #expect(finding?.level == .fail)
        #expect(finding?.detail.contains("install.sh") == true)
    }

    /// Registered, present, and silently doing nothing — every other check
    /// passes, which is what makes it worth its own failure.
    @Test("a non-executable hook script is a failure, not a warning")
    func nonExecutableHookIsAFailure() {
        var input = healthy
        input.registeredHookScriptExecutable = false
        let findings = Diagnosis.findings(input)
        #expect(findings.contains { $0.check == "hook script" && $0.level == .fail })
        #expect(Diagnosis.exitCode(findings) == 1)
    }

    @Test("a missing hook script stops before asking whether it is executable")
    func missingHookScriptIsOneFinding() {
        var input = healthy
        input.registeredHookScriptPresent = false
        input.registeredHookScriptExecutable = false
        let script = Diagnosis.findings(input).filter { $0.check == "hook script" }
        #expect(script.count == 1)
        #expect(script.first?.detail.contains("does not exist") == true)
    }

    /// The shape that used to report a healthy install: every event registered,
    /// a script present at the path this build *would* install to, and a
    /// registration pointing somewhere else entirely. Every other check passes,
    /// which is what makes it worth its own failure.
    @Test("a registration pointing at a path that does not exist fails")
    func deadRegisteredPathIsAFailure() {
        var input = healthy
        input.registeredHookScriptPresent = false
        input.registeredHookPath = .resolved("/nonexistent/agent-tracker-hook.py")
        let findings = Diagnosis.findings(input)
        let script = findings.first { $0.check == "hook script" }
        #expect(script?.level == .fail)
        #expect(script?.detail.contains("/nonexistent/agent-tracker-hook.py") == true)
        #expect(Diagnosis.exitCode(findings) == 1)
    }

    /// It exists, so it runs — but nothing will ever refresh it, which is worth
    /// saying and is not a failure.
    @Test("a registration somewhere unexpected but present is a warning")
    func mismatchedButPresentPathWarns() {
        var input = healthy
        input.registeredHookPath = .resolved("/opt/custom/agent-tracker-hook.py")
        let findings = Diagnosis.findings(input)
        #expect(findings.contains { $0.check == "hook script" && $0.level == .warn })
        #expect(Diagnosis.exitCode(findings) == 0)
    }

    /// The remedy for "none registered" is the installer, and the installer
    /// parses the same file with a bare `json.load`. Reporting a parse failure
    /// as an empty config would name a false cause and prescribe a crash.
    @Test("an unparseable settings file is unknown, not an empty one")
    func unreadableSettingsIsNotEmpty() {
        var input = healthy
        input.settingsState = .unreadable(["/Users/dev/.claude/settings.local.json"])
        input.registeredHooks = []
        let findings = Diagnosis.findings(input)
        let hooks = findings.first { $0.check == "hooks" }
        #expect(hooks?.level == .unknown)
        #expect(hooks?.detail.contains("could not parse") == true)
        // Names the file that is actually broken, not the one that is fine.
        #expect(hooks?.detail.contains("settings.local.json") == true)
        #expect(hooks?.detail.contains("install.sh") == false)
        #expect(Diagnosis.exitCode(findings) == 0)
    }

    /// Context readings arrive from either statusline source, so a payload
    /// without the wrapper means usage is missing and context is not.
    @Test("a payload without the wrapper narrows the claim to usage")
    func payloadWithoutWrapperStillHasContext() {
        var input = healthy
        input.statusLineCommand = "~/bin/my-own.sh"
        input.statuslinePayloadPresent = true
        let finding = find(Diagnosis.findings(input), "statusline")
        #expect(finding?.detail.contains("context works") == true)
        #expect(finding?.detail.contains("no usage readings") == true)
    }

    /// Banners are off by default, so a machine that has never been asked is a
    /// correct fresh install rather than something to warn about.
    @Test("never having been asked about notifications is not a warning")
    func notAskedIsNotAWarning() {
        var input = healthy
        input.notifications = .notAsked
        let finding = find(Diagnosis.findings(input), "notifications")
        #expect(finding?.level == .ok)
        #expect(finding?.detail.contains("off by default") == true)

        input.notifications = .denied
        #expect(find(Diagnosis.findings(input), "notifications")?.level == .warn)
    }

    /// Printing "No problems found." above warnings the reader is being asked
    /// to act on is the report contradicting itself.
    @Test("the summary distinguishes nothing-wrong from nothing-failed")
    func summaryDoesNotOverclaim() {
        #expect(Diagnosis.summary(Diagnosis.findings(healthy)) == "No problems found.")

        var warned = healthy
        warned.staleSessionCount = 1
        #expect(Diagnosis.summary(Diagnosis.findings(warned)).hasPrefix("No failures."))

        var failed = healthy
        failed.registeredHookScriptExecutable = false
        #expect(Diagnosis.summary(Diagnosis.findings(failed)).contains("problem(s) found"))
    }

    /// "Cannot compare" must not read as "up to date". A detached binary has no
    /// bundled copy to compare against, and that is the normal case rather than
    /// a fault.
    @Test("an uncomparable hook version is unknown, not ok and not a warning")
    func unknownFreshnessIsItsOwnLevel() {
        var input = healthy
        input.hookFreshness = .unknown
        let finding = find(Diagnosis.findings(input), "hook version")
        #expect(finding?.level == .unknown)

        input.hookFreshness = .stale
        #expect(find(Diagnosis.findings(input), "hook version")?.level == .warn)
    }

    // MARK: - Statusline

    @Test("someone else's statusline is distinguished from none at all")
    func statuslineVariants() {
        var input = healthy
        input.statusLineCommand = nil
        #expect(
            find(Diagnosis.findings(input), "statusline")?.detail.contains("no statusLine") == true)

        input.statusLineCommand = "~/bin/my-own-statusline.sh"
        #expect(
            find(Diagnosis.findings(input), "statusline")?.detail.contains("not the wrapper")
                == true)

        input.statusLineCommand = "~/.agent-tracker/bin/agent-tracker-statusline.py"
        input.statuslinePayloadPresent = false
        #expect(
            find(Diagnosis.findings(input), "statusline")?.detail.contains("nothing captured")
                == true)
    }

    /// Every statusline shortfall is a warning: the app works without one, it
    /// just knows less. Failing here would make the exit code useless for the
    /// majority of installs, which never opt into the wrapper.
    @Test("no statusline is never a failure")
    func statuslineNeverFails() {
        var input = healthy
        input.statusLineCommand = nil
        #expect(Diagnosis.exitCode(Diagnosis.findings(input)) == 0)
    }

    // MARK: - Sessions

    @Test("no sessions points at the restart, which is the usual cause")
    func noSessionsExplainsItself() {
        var input = healthy
        input.sessionFileCount = 0
        let finding = find(Diagnosis.findings(input), "sessions")
        #expect(finding?.level == .warn)
        #expect(finding?.detail.contains("restart") == true)
    }

    /// Stale files are the running app's job to prune, so their presence is
    /// information rather than a fault — and saying so stops someone "fixing"
    /// a machine that is behaving correctly.
    @Test("stale session files warn without failing")
    func staleSessionsAreInformational() {
        var input = healthy
        input.staleSessionCount = 4
        let findings = Diagnosis.findings(input)
        #expect(findings.contains { $0.check == "stale sessions" && $0.level == .warn })
        #expect(Diagnosis.exitCode(findings) == 0)
    }

    @Test("sessions sharing a project are reported with the fix that works")
    func ambiguityNamesTheFix() {
        var input = healthy
        input.largestSameProjectGroup = 3
        let finding = find(Diagnosis.findings(input), "ambiguous rows")
        #expect(finding?.level == .warn)
        #expect(finding?.detail.contains("/rename") == true)
    }

    @Test("one session per project is not ambiguity")
    func singleSessionIsNotAmbiguous() {
        #expect(!Diagnosis.findings(healthy).contains { $0.check == "ambiguous rows" })
    }

    // MARK: - Permissions

    /// Outside an app bundle the notification API answers about the process
    /// rather than the user, so "denied" there would be a lie about a setting
    /// nobody touched.
    @Test("an unanswerable notification state is unknown, not denied")
    func notificationsUnknownIsNotDenied() {
        var input = healthy
        input.notifications = .unavailable
        let finding = find(Diagnosis.findings(input), "notifications")
        #expect(finding?.level == .unknown)
        #expect(finding?.detail.contains("can't tell") == true)

        input.notifications = .denied
        #expect(find(Diagnosis.findings(input), "notifications")?.level == .warn)
    }

    // MARK: - Short-circuiting

    /// With no `~/.claude` every hook finding would be a confident statement
    /// about a machine where Claude has never run. One finding, and stop.
    @Test("no ~/.claude reports once rather than failing everything downstream")
    func missingClaudeShortCircuits() {
        var input = healthy
        input.claudeDirectoryExists = false
        input.registeredHooks = []
        input.registeredHookScriptPresent = false
        let findings = Diagnosis.findings(input)
        #expect(findings.count == 1)
        #expect(findings.first?.level == .warn)
        #expect(Diagnosis.exitCode(findings) == 0)
    }

    // MARK: - Drift guards

    /// The event list exists in Swift and in the installer, and nothing but
    /// this test stops them diverging. Without it, adding an event to the
    /// installer would make the doctor quietly report a healthy machine as
    /// missing nothing while a hook it never registered goes unnoticed.
    @Test("the expected events match what the installer actually registers")
    func eventListMatchesTheInstaller() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installer = try String(
            contentsOf: root.appendingPathComponent("integrations/install-claude-code.sh"),
            encoding: .utf8)

        // The `EVENTS = [ ... ]` literal inside the embedded Python.
        guard let start = installer.range(of: "EVENTS = ["),
            let end = installer.range(of: "]", range: start.upperBound..<installer.endIndex)
        else {
            Issue.record("could not find the EVENTS list in install-claude-code.sh")
            return
        }
        let names = installer[start.upperBound..<end.lowerBound]
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }

        #expect(Set(names) == Diagnosis.expectedHookEvents)
    }

    /// Each finding cites a section of the troubleshooting page. A citation
    /// that does not resolve is worse than none: it sends someone to a page
    /// that appears not to cover their problem.
    @Test("every anchor a finding can cite exists in the troubleshooting page")
    func everyAnchorResolves() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let page = try String(
            contentsOf: root.appendingPathComponent("docs/troubleshooting.md"), encoding: .utf8)

        let slugs = Set(
            page.split(separator: "\n")
                .filter { $0.hasPrefix("## ") }
                .map { heading -> String in
                    heading.dropFirst(3)
                        .lowercased()
                        .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
                        .replacingOccurrences(of: " ", with: "-")
                })

        // Every input shape this suite can produce, so the cited set is the
        // real one rather than a list someone remembered to update.
        var inputs: [Diagnosis.Input] = [healthy]
        for mutate in [
            { (probe: inout Diagnosis.Input) in probe.claudeDirectoryExists = false },
            { (probe: inout Diagnosis.Input) in probe.registeredHooks = [] },
            { (probe: inout Diagnosis.Input) in probe.registeredHooks = hooks(["Stop"]) },
            { (probe: inout Diagnosis.Input) in probe.registeredHookScriptPresent = false },
            { (probe: inout Diagnosis.Input) in probe.registeredHookScriptExecutable = false },
            { (probe: inout Diagnosis.Input) in probe.statusLineCommand = nil },
            { (probe: inout Diagnosis.Input) in probe.statusLineCommand = "other" },
            { (probe: inout Diagnosis.Input) in probe.statuslinePayloadPresent = false },
            { (probe: inout Diagnosis.Input) in
                probe.projectStatusLineOverride = "/tmp/x/.claude/settings.json"
            },
            { (probe: inout Diagnosis.Input) in probe.sessionFileCount = 0 },
            { (probe: inout Diagnosis.Input) in probe.staleSessionCount = 2 },
            { (probe: inout Diagnosis.Input) in probe.largestSameProjectGroup = 2 },
            { (probe: inout Diagnosis.Input) in probe.accessibilityGranted = false },
            { (probe: inout Diagnosis.Input) in probe.notifications = .unavailable },
        ] {
            var input = healthy
            mutate(&input)
            inputs.append(input)
        }

        let cited = Set(inputs.flatMap { Diagnosis.findings($0).compactMap(\.anchor) })
        #expect(!cited.isEmpty, "the cited set is empty — this test would pass vacuously")
        for anchor in cited.sorted() {
            #expect(
                slugs.contains(anchor), "no `## ` heading in troubleshooting.md yields #\(anchor)")
        }
    }
}
