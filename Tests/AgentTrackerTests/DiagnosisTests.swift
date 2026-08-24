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
            hookScripts: [
                Diagnosis.HookScript(
                    events: Diagnosis.expectedHookEvents.sorted(),
                    command: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude",
                    path: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py",
                    exists: true, isExecutable: true)
            ],
            installedHookPath: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py",
            hookFreshness: .current,
            statusLineCommand: "~/.agent-tracker/bin/agent-tracker-statusline.py",
            projectStatusLineOverride: nil,
            sessionFileCount: 3,
            staleSessionCount: 0,
            liveSessions: [live("/Users/dev/code/api-gateway", "api-gateway-02")],
            statuslinePayloadPresent: true,
            accessibilityGranted: true,
            notifications: .authorized)
    }

    private func script(
        path: String? = "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py",
        exists: Bool = true, executable: Bool = true, events: [String] = ["Stop"]
    ) -> Diagnosis.HookScript {
        Diagnosis.HookScript(
            events: events, command: "\(path ?? "?") claude", path: path,
            exists: exists, isExecutable: executable)
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

    private func live(_ projectKey: String, _ name: String?) -> RowAmbiguity.LiveSession {
        RowAmbiguity.LiveSession(projectKey: projectKey, name: name)
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
        input.hookScripts = [script(executable: false)]
        let findings = Diagnosis.findings(input)
        #expect(findings.contains { $0.check == "hook script" && $0.level == .fail })
        #expect(Diagnosis.exitCode(findings) == 1)
    }

    @Test("a missing hook script stops before asking whether it is executable")
    func missingHookScriptIsOneFinding() {
        var input = healthy
        input.hookScripts = [script(exists: false, executable: false)]
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
        input.hookScripts = [script(path: "/nonexistent/agent-tracker-hook.py", exists: false)]
        let findings = Diagnosis.findings(input)
        let script = findings.first { $0.check == "hook script" }
        #expect(script?.level == .fail)
        #expect(script?.detail.contains("/nonexistent/agent-tracker-hook.py") == true)
        #expect(Diagnosis.exitCode(findings) == 1)
    }

    /// The finding this restructure exists for: checking only the first
    /// registration let a healthy one hide a broken one, which is precisely the
    /// state the check was added to catch. A half-reinstalled config, or one
    /// event edited by hand, produces exactly this.
    @Test("a broken registration is not hidden by a healthy one beside it")
    func oneBrokenRegistrationIsNotHidden() {
        var input = healthy
        input.hookScripts = [
            script(events: ["PreToolUse", "Stop"]),
            script(path: "/gone/agent-tracker-hook.py", exists: false, events: ["SessionEnd"]),
        ]
        let findings = Diagnosis.findings(input)
        let failure = findings.first { $0.check == "hook script" && $0.level == .fail }
        #expect(failure != nil)
        #expect(failure?.detail.contains("SessionEnd") == true)
        // And it does not claim the healthy events are broken.
        #expect(failure?.detail.contains("Stop") == false)
        #expect(Diagnosis.exitCode(findings) == 1)
    }

    /// A config where every event points somewhere dead should not print seven
    /// near-identical lines, nor list seven event names in one.
    @Test("many broken events collapse to a count")
    func manyEventsAreSummarised() {
        var input = healthy
        input.hookScripts = [
            script(
                path: "/gone/agent-tracker-hook.py", exists: false,
                events: Diagnosis.expectedHookEvents.sorted())
        ]
        let failures = Diagnosis.findings(input).filter {
            $0.check == "hook script" && $0.level == .fail
        }
        #expect(failures.count == 1)
        #expect(failures.first?.detail.contains("7 events") == true)
    }

    /// It exists, so it runs — but nothing will ever refresh it, which is worth
    /// saying and is not a failure.
    @Test("a registration somewhere unexpected but present is a warning")
    func mismatchedButPresentPathWarns() {
        var input = healthy
        input.hookScripts = [script(path: "/opt/custom/agent-tracker-hook.py")]
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

    /// The statusline finding reads the same merged settings the hook finding
    /// does, so a config that would not parse must not produce a definite claim
    /// about what is configured. Gating one and not the other was the gap.
    @Test("an unparseable config makes the statusline verdict unknown too")
    func unreadableSettingsGateStatuslineToo() {
        var input = healthy
        input.settingsState = .unreadable(["/Users/dev/.claude/settings.json"])
        input.statusLineCommand = nil
        let finding = find(Diagnosis.findings(input), "statusline")
        #expect(finding?.level == .unknown)
        #expect(finding?.detail.contains("could not parse") == true)
        // Never the definite claim, which is what an unparseable file would
        // otherwise have produced.
        #expect(finding?.detail.contains("no statusLine configured") == false)
        // The payload half is still reported: it comes from disk, not settings.
        #expect(finding?.detail.contains("A payload is arriving") == true)
    }

    /// The class-level guard, after two findings of the form "you gated one
    /// finding on unreadable settings and not its neighbour".
    ///
    /// Pins the whole report rather than one line: with a config we could not
    /// parse, every finding derived from it must be `unknown`. The check-name
    /// set is asserted exactly, so a *new* settings-derived finding added later
    /// fails this until someone decides how it degrades — which is the step
    /// that was skipped both times.
    @Test("nothing derived from an unparseable config states a verdict")
    func unreadableSettingsNeverProduceAVerdict() {
        var input = healthy
        input.settingsState = .unreadable(["/Users/dev/.claude/settings.json"])
        let findings = Diagnosis.findings(input)

        // Everything the settings feed. If this set changes, a finding was
        // added or removed and its degraded behaviour needs deciding.
        let fromSettings: Set<String> = ["hooks", "statusline"]
        let produced = Set(findings.map(\.check))
        #expect(
            produced.intersection(fromSettings) == fromSettings,
            "both settings-derived findings should still appear, as unknown")

        for finding in findings where fromSettings.contains(finding.check) {
            #expect(
                finding.level == .unknown,
                "\(finding.check) states a verdict from a config that could not be parsed")
        }
        // And the report as a whole does not fail on it: not knowing is not a
        // defect in the install.
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
    /// "No problems found." above a check that could not run is the report
    /// concluding where its own findings decline to. The same contradiction as
    /// claiming it above warnings, one level quieter — and the common case,
    /// since the notification check is unknown outside the app bundle.
    @Test("an unknown check is never summarised as no problems")
    func unknownIsNotAClearReport() {
        var input = healthy
        input.notifications = .unavailable
        let findings = Diagnosis.findings(input)
        #expect(findings.contains { $0.level == .unknown })
        #expect(!findings.contains { $0.level == .fail || $0.level == .warn })

        let summary = Diagnosis.summary(findings)
        #expect(summary != "No problems found.")
        #expect(summary.contains("couldn't run"))
        // Still not a failure: not knowing is not a defect in the install.
        #expect(Diagnosis.exitCode(findings) == 0)
    }

    @Test("the summary distinguishes nothing-wrong from nothing-failed")
    func summaryDoesNotOverclaim() {
        #expect(Diagnosis.summary(Diagnosis.findings(healthy)) == "No problems found.")

        var warned = healthy
        warned.staleSessionCount = 1
        #expect(Diagnosis.summary(Diagnosis.findings(warned)).hasPrefix("No failures"))
        #expect(Diagnosis.summary(Diagnosis.findings(warned)).contains("1 warning(s)"))

        var failed = healthy
        failed.hookScripts = [script(executable: false)]
        #expect(Diagnosis.summary(Diagnosis.findings(failed)).contains("problem(s) found"))
    }

    /// A missing script is one problem, not two. Reporting the failure and then
    /// "can't compare the version" is the same absence said twice, in a report
    /// whose discipline is one fact per line.
    @Test("no version line for a script that is not there")
    func noVersionLineWithoutAScript() {
        var input = healthy
        input.hookScripts = [script(exists: false, executable: false)]
        input.hookFreshness = .unknown
        let findings = Diagnosis.findings(input)
        #expect(findings.contains { $0.check == "hook script" && $0.level == .fail })
        #expect(!findings.contains { $0.check == "hook version" })
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

    @Test("sessions sharing a project and a name are reported with the fix that works")
    func ambiguityNamesTheFix() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "api-gateway"),
            live("/Users/dev/code/api-gateway", "api-gateway"),
        ]
        let finding = find(Diagnosis.findings(input), "ambiguous rows")
        #expect(finding?.level == .warn)
        #expect(finding?.detail.contains("2 live sessions") == true)
        #expect(finding?.detail.contains("/rename") == true)
    }

    @Test("one session per project is not ambiguity")
    func singleSessionIsNotAmbiguous() {
        #expect(!Diagnosis.findings(healthy).contains { $0.check == "ambiguous rows" })
    }

    /// The nag this check used to be. Window matching resolves a row by its
    /// name, so two sessions in one repo called different things are told
    /// apart — and warning about them anyway repeated the same line to
    /// somebody who had already run the `/rename` it asked for.
    @Test("two sessions in one project with distinct names are not ambiguous")
    func distinctNamesInOneProjectAreResolvable() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "api-gateway-02"),
            live("/Users/dev/code/api-gateway", "billing-spike"),
        ]
        #expect(!Diagnosis.findings(input).contains { $0.check == "ambiguous rows" })
    }

    /// A session nothing names has no title to match a window on, so it falls
    /// back to the directory its sibling shares.
    @Test("an unnamed session beside a named one still warns")
    func unnamedSessionIsAmbiguous() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "api-gateway-02"),
            live("/Users/dev/code/api-gateway", nil),
        ]
        let finding = find(Diagnosis.findings(input), "ambiguous rows")
        #expect(finding?.level == .warn)
        #expect(finding?.detail.contains("1 live session shares") == true)
    }

    /// The count is of rows that cannot be resolved, not of the group they sit
    /// in: the third session here is named something of its own and clicking it
    /// lands where it should.
    @Test("only the rows that collide are counted")
    func countExcludesTheDistinctlyNamedSibling() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "api-gateway"),
            live("/Users/dev/code/api-gateway", "api-gateway"),
            live("/Users/dev/code/api-gateway", "billing-spike"),
        ]
        let finding = find(Diagnosis.findings(input), "ambiguous rows")
        #expect(finding?.level == .warn)
        #expect(finding?.detail.contains("2 live sessions") == true)
    }

    /// Window matching lowercases a title and strips the status glyph a
    /// terminal puts in front of it, so names that differ only in those
    /// collide on the click and must collide here too.
    @Test("names that differ only in case or a leading glyph still collide")
    func namesAreComparedTheWayTitlesAreMatched() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "Review"),
            live("/Users/dev/code/api-gateway", "\u{2733} review"),
        ]
        let finding = find(Diagnosis.findings(input), "ambiguous rows")
        #expect(finding?.level == .warn)
        #expect(finding?.detail.contains("2 live sessions") == true)
    }

    /// A name that is nothing but a glyph normalizes away to nothing, which
    /// matches no window, so the row is no better off than an unnamed one.
    @Test("a name that normalizes to nothing counts as unnamed")
    func aGlyphOnlyNameIsNoName() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "api-gateway-02"),
            live("/Users/dev/code/api-gateway", "\u{2733}"),
        ]
        let finding = find(Diagnosis.findings(input), "ambiguous rows")
        #expect(finding?.detail.contains("1 live session shares") == true)
    }

    /// Names are only confusable inside one project. Two repos that happen to
    /// run a session of the same name never compete for a window, and grouping
    /// on the name alone would warn about every machine that reuses one.
    @Test("the same name in two projects is not ambiguity")
    func sameNameInDifferentProjectsIsFine() {
        var input = healthy
        input.liveSessions = [
            live("/Users/dev/code/api-gateway", "review"),
            live("/Users/dev/code/billing", "review"),
        ]
        #expect(!Diagnosis.findings(input).contains { $0.check == "ambiguous rows" })
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
        input.hookScripts = [script(exists: false, executable: false)]
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
            { (probe: inout Diagnosis.Input) in
                probe.hookScripts = [
                    Diagnosis.HookScript(
                        events: ["Stop"], command: "/nope claude", path: "/nope",
                        exists: false, isExecutable: false)
                ]
            },
            { (probe: inout Diagnosis.Input) in
                probe.hookScripts = [
                    Diagnosis.HookScript(
                        events: ["Stop"], command: "/x claude", path: "/x",
                        exists: true, isExecutable: false)
                ]
            },
            { (probe: inout Diagnosis.Input) in probe.statusLineCommand = nil },
            { (probe: inout Diagnosis.Input) in probe.statusLineCommand = "other" },
            { (probe: inout Diagnosis.Input) in probe.statuslinePayloadPresent = false },
            { (probe: inout Diagnosis.Input) in
                probe.projectStatusLineOverride = "/tmp/x/.claude/settings.json"
            },
            { (probe: inout Diagnosis.Input) in probe.sessionFileCount = 0 },
            { (probe: inout Diagnosis.Input) in probe.staleSessionCount = 2 },
            { (probe: inout Diagnosis.Input) in
                probe.liveSessions = [
                    self.live("/Users/dev/code/api-gateway", "api-gateway"),
                    self.live("/Users/dev/code/api-gateway", "api-gateway"),
                ]
            },
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
