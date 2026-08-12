import Foundation
import Testing

@testable import AgentTracker

/// The parsing half of `--doctor`: turning what is actually in
/// `~/.claude/settings.json` into the facts the rules reason about.
///
/// Separate from `DiagnosisTests` because these are about *Claude's* file
/// format rather than about our rules, and they are the half that gets a wrong
/// answer from a config nobody anticipated.
@Suite("Doctor parsing")
struct DoctorParsingTests {
    private func settings(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - Hook registration

    @Test("the installer's own shape is recognised, event and command")
    func installerShape() {
        let parsed = Doctor.registeredHooks(
            in: settings(
                """
                {"hooks": {
                  "Stop": [{"hooks": [
                    {"type": "command", "command": "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude", "timeout": 10}
                  ]}],
                  "PreToolUse": [{"matcher": "*", "hooks": [
                    {"type": "command", "command": "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude", "timeout": 10}
                  ]}]
                }}
                """))
        #expect(parsed.map(\.event) == ["PreToolUse", "Stop"])
        #expect(parsed.first?.command.contains("agent-tracker-hook.py") == true)
    }

    /// A third-party hook sharing the event must not make us claim it, and must
    /// not stop us seeing ours beside it.
    @Test("someone else's hook on the same event is not ours")
    func foreignHooksAreIgnored() {
        let parsed = Doctor.registeredHooks(
            in: settings(
                """
                {"hooks": {
                  "Stop": [
                    {"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]},
                    {"hooks": [{"type": "command", "command": "~/.agent-tracker/bin/agent-tracker-hook.py claude"}]}
                  ],
                  "SessionEnd": [{"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]}]
                }}
                """))
        #expect(parsed.map(\.event) == ["Stop"])
    }

    /// One malformed element must not take a correctly-registered event with
    /// it. An all-or-nothing cast reported the event as missing entirely, which
    /// sends someone reinstalling over a config that was fine.
    @Test("a stray element does not drop the event beside it")
    func strayElementDoesNotDropTheEvent() {
        let parsed = Doctor.registeredHooks(
            in: settings(
                """
                {"hooks": {"Stop": [
                  "unexpected",
                  {"hooks": [{"type": "command", "command": "~/.agent-tracker/bin/agent-tracker-hook.py claude"}]}
                ]}}
                """))
        #expect(parsed.map(\.event) == ["Stop"])
    }

    @Test("no hooks key, or an empty one, is no registration")
    func absentHooks() {
        #expect(Doctor.registeredHooks(in: settings("{}")).isEmpty)
        #expect(Doctor.registeredHooks(in: settings(#"{"hooks": {}}"#)).isEmpty)
        #expect(Doctor.registeredHooks(in: settings(#"{"hooks": []}"#)).isEmpty)
    }

    // MARK: - The registered path

    /// The installer shell-quotes the path, and `shlex.quote` only adds quotes
    /// when the path needs them — so the quoted form is exactly the case where
    /// taking the string literally yields a path that does not exist, and a
    /// false failure.
    @Test("the script path survives quoting and the trailing argument")
    func scriptPathParsing() {
        #expect(
            Doctor.scriptPath(
                fromCommand: "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude")
                == "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py")
        #expect(
            Doctor.scriptPath(fromCommand: "'/Users/dev/My Files/agent-tracker-hook.py' claude")
                == "/Users/dev/My Files/agent-tracker-hook.py")
        #expect(
            Doctor.scriptPath(fromCommand: "\"/Users/dev/x/agent-tracker-hook.py\" claude")
                == "/Users/dev/x/agent-tracker-hook.py")
    }

    /// A registration can legitimately run the hook through an interpreter.
    /// Treating the whole prefix as a path there produced a confident failure
    /// about an install that works — a false positive introduced by the fix for
    /// a false negative.
    @Test("an interpreter prefix does not become part of the path")
    func interpreterPrefixIsNotThePath() {
        #expect(
            Doctor.scriptPath(
                fromCommand: "python3 /Users/dev/.agent-tracker/bin/agent-tracker-hook.py claude")
                == "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py")
        #expect(
            Doctor.scriptPath(
                fromCommand:
                    "/usr/bin/env python3 '/Users/dev/My Files/agent-tracker-hook.py' claude")
                == "/Users/dev/My Files/agent-tracker-hook.py")
    }

    /// A backslash-escaped space is ordinary shell and a plausible hand edit.
    /// Splitting on it produced a path that does not exist, which the doctor
    /// would then report as a broken install — the same false-positive shape as
    /// the interpreter prefix above.
    @Test("a backslash-escaped space stays inside the path")
    func backslashEscapesSurvive() {
        #expect(
            Doctor.scriptPath(
                fromCommand: #"/Users/dev/My\ Files/agent-tracker-hook.py claude"#)
                == "/Users/dev/My Files/agent-tracker-hook.py")
        #expect(
            Doctor.tokenize(#"a\ b c"#) == ["a b", "c"])
    }

    /// POSIX single quotes are literal, so a backslash inside them belongs to
    /// the path. Treating it as an escape would silently delete a character
    /// from a Windows-style or oddly-named directory.
    @Test("a backslash inside single quotes is part of the path")
    func backslashInsideSingleQuotesIsLiteral() {
        #expect(Doctor.tokenize(#"'a\z' c"#) == [#"a\z"#, "c"])
    }

    /// Nothing that looks like the hook means the answer is "cannot tell",
    /// rather than a path to accuse of not existing.
    @Test("a command with no recognisable hook token resolves to nothing")
    func unrecognisableCommandIsNil() {
        #expect(Doctor.scriptPath(fromCommand: "/Users/dev/some-other-tool") == nil)
        #expect(Doctor.scriptPath(fromCommand: "") == nil)
    }

    // MARK: - Statusline

    @Test("both the object and string forms of statusLine are read")
    func statusLineForms() {
        #expect(
            Doctor.statusLineCommand(in: settings(#"{"statusLine": {"command": "a.sh"}}"#))
                == "a.sh")
        #expect(Doctor.statusLineCommand(in: settings(#"{"statusLine": "b.sh"}"#)) == "b.sh")
        #expect(Doctor.statusLineCommand(in: settings("{}")) == nil)
    }

    /// `JSONSerialization` maps JSON null to `NSNull`, which is not nil — so a
    /// config that explicitly clears the slot would otherwise read as one that
    /// sets it.
    @Test("an explicit null statusLine is not a statusLine")
    func nullStatusLineIsNotSet() {
        #expect(Doctor.statusLineCommand(in: settings(#"{"statusLine": null}"#)) == nil)
    }

    // MARK: - Where settings come from

    @Test("settings.local.json is read, and wins per key")
    func localSettingsMerge() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try #"{"statusLine": {"command": "base.sh"}}"#.write(
            to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        try #"{"statusLine": {"command": "local.sh"}}"#.write(
            to: directory.appendingPathComponent("settings.local.json"), atomically: true,
            encoding: .utf8)

        let (merged, state) = Doctor.userSettings(in: directory)
        #expect(state == .parsed)
        #expect(Doctor.statusLineCommand(in: merged) == "local.sh")
    }

    /// The bug this replaced was quiet and likely: any `hooks` key in the local
    /// file discarded every hook in the main one, so a user with one hook in
    /// `settings.local.json` was told the other six were missing.
    @Test("hooks from both files are unioned, not replaced")
    func hooksUnionAcrossUserFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = "~/.agent-tracker/bin/agent-tracker-hook.py claude"
        try #"{"hooks": {"Stop": [{"hooks": [{"command": "COMMAND"}]}]}}"#
            .replacingOccurrences(of: "COMMAND", with: command)
            .write(
                to: directory.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
        try #"{"hooks": {"SessionEnd": [{"hooks": [{"command": "COMMAND"}]}]}}"#
            .replacingOccurrences(of: "COMMAND", with: command)
            .write(
                to: directory.appendingPathComponent("settings.local.json"), atomically: true,
                encoding: .utf8)

        let (merged, _) = Doctor.userSettings(in: directory)
        let events = Set(Doctor.registeredHooks(in: merged).map(\.event))
        #expect(events == ["Stop", "SessionEnd"])
    }

    /// The same event registered in both files keeps both entries, rather than
    /// the local one silently replacing the other.
    @Test("the same event in both files keeps both registrations")
    func sameEventInBothFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try #"{"hooks": {"Stop": [{"hooks": [{"command": "/a/agent-tracker-hook.py claude"}]}]}}"#
            .write(
                to: directory.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
        try #"{"hooks": {"Stop": [{"hooks": [{"command": "/b/agent-tracker-hook.py claude"}]}]}}"#
            .write(
                to: directory.appendingPathComponent("settings.local.json"), atomically: true,
                encoding: .utf8)

        let (merged, _) = Doctor.userSettings(in: directory)
        let commands = Set(Doctor.registeredHooks(in: merged).map(\.command))
        #expect(commands.count == 2)
    }

    /// Absent and unparseable have opposite remedies, so they must not collapse
    /// into one answer.
    @Test("absent settings and unparseable settings are different states")
    func settingsStates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Doctor.userSettings(in: directory).1 == .absent)

        try "{ this is not json }".write(
            to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        #expect(
            Doctor.userSettings(in: directory).1
                == .unreadable([directory.appendingPathComponent("settings.json").path]))
    }

    /// Either file can be the broken one, and the report names it — so someone
    /// with a fine `settings.json` and a broken `settings.local.json` is not
    /// sent to the file that is fine.
    @Test("the unreadable state names the file that actually failed")
    func unreadableNamesTheRightFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try #"{"statusLine": {"command": "fine.sh"}}"#.write(
            to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        try "{ broken".write(
            to: directory.appendingPathComponent("settings.local.json"), atomically: true,
            encoding: .utf8)

        guard case .unreadable(let broken) = Doctor.userSettings(in: directory).1 else {
            Issue.record("expected an unreadable state")
            return
        }
        #expect(broken.count == 1)
        #expect(broken[0].hasSuffix("settings.local.json"))
    }

    // MARK: - Project overrides

    @Test("a project statusLine is found by walking up, and hooks are not")
    func projectOverrideWalksUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-project-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        // Hooks merge with the user-level ones, so a project defining them is
        // not an override and must not be reported as one.
        try #"{"hooks": {"Stop": []}}"#.write(
            to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(Doctor.projectStatusLineOverride(from: nested.path) == nil)

        try #"{"statusLine": {"command": "mine.sh"}}"#.write(
            to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(Doctor.projectStatusLineOverride(from: nested.path) != nil)
    }

    /// A project's `settings.local.json` displaces the wrapper exactly as its
    /// `settings.json` does, so checking only the latter reports a healthy
    /// statusline for a project that has none.
    @Test("a project settings.local.json statusLine is an override too")
    func projectLocalSettingsAreChecked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-project-local-\(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"statusLine": {"command": "local-only.sh"}}"#.write(
            to: claude.appendingPathComponent("settings.local.json"), atomically: true,
            encoding: .utf8)
        let found = Doctor.projectStatusLineOverride(from: root.path)
        #expect(found?.hasSuffix("settings.local.json") == true)
    }
}
