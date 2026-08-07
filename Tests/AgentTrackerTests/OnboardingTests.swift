import Foundation
import Testing

@testable import AgentTracker

final class OnboardingTests {
    private func environment(
        accessibility: Bool = false,
        claudeHook: Bool = false,
        codexHook: Bool = false,
        claude: Bool = true,
        codex: Bool = true,
        completed: Bool = false
    ) -> Onboarding.Environment {
        Onboarding.Environment(
            accessibilityGranted: accessibility,
            claudeHookInstalled: claudeHook,
            codexHookInstalled: codexHook,
            claudePresent: claude,
            codexPresent: codex,
            completedBefore: completed)
    }

    @Test func freshMachineGetsOnboarding() {
        #expect(Onboarding.shouldShow(environment()))
    }

    /// Any earlier dismissal counts as completed — never nag twice, even if
    /// the user set nothing up.
    @Test func completedBeforeAlwaysWins() {
        #expect(!Onboarding.shouldShow(environment(completed: true)))
        #expect(
            !Onboarding.shouldShow(
                environment(accessibility: false, claudeHook: false, completed: true)))
    }

    /// Anything already set up means this user knows the app: the permission
    /// banner in the popover covers a missing grant, and hooks imply a past
    /// install. Showing "Welcome" to them would read as amnesia on upgrade.
    @Test func anyExistingSetupSuppressesOnboarding() {
        #expect(!Onboarding.shouldShow(environment(accessibility: true)))
        #expect(!Onboarding.shouldShow(environment(claudeHook: true)))
        #expect(!Onboarding.shouldShow(environment(codexHook: true)))
    }

    /// Absent agents are dropped, not greyed out — one screen, no noise.
    @Test func onlyPresentAgentsAreOffered() {
        #expect(
            Onboarding.installableAgents(environment(claude: true, codex: true))
                == [.claude, .codex])
        #expect(Onboarding.installableAgents(environment(claude: true, codex: false)) == [.claude])
        #expect(Onboarding.installableAgents(environment(claude: false, codex: true)) == [.codex])
        #expect(Onboarding.installableAgents(environment(claude: false, codex: false)).isEmpty)
    }

    /// The consent step names the exact file each installer edits.
    @Test func everyAgentNamesItsEditedConfig() {
        #expect(Onboarding.Agent.claude.editedConfig == "~/.claude/settings.json")
        #expect(Onboarding.Agent.codex.editedConfig == "~/.codex/hooks.json and config.toml")
        for agent in Onboarding.Agent.allCases {
            #expect(agent.installerScript.hasSuffix(".sh"))
        }
    }

    /// A successful Codex install is not a finished Codex install.
    @Test func codexInstallLeavesTheTrustStepToSay() {
        #expect(Onboarding.Agent.claude.postInstallAction == nil)
        #expect(Onboarding.Agent.codex.postInstallAction?.contains("trusted") == true)
    }

    // MARK: - HookSetup probes (temp home, never the real one)

    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func hookDetectionReadsTheAgentConfigs() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!HookSetup.claudeHookInstalled(home: home))
        #expect(!HookSetup.codexHookInstalled(home: home))

        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try
            #"{"hooks":{"Stop":[{"hooks":[{"command":"~/.agent-tracker/bin/agent-tracker-hook.py claude"}]}]}}"#
            .write(
                to: claude.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
        #expect(HookSetup.claudeHookInstalled(home: home))

        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try
            "notify = [\"python3\", \"/Users/x/.agent-tracker/bin/agent-tracker-hook.py\", \"codex\"]\n"
            .write(
                to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(HookSetup.codexHookInstalled(home: home))
    }

    /// hooks.json alone is enough: the installer declines the `notify` line when
    /// the user already points it elsewhere, and the native hooks still run.
    @Test func codexHooksJsonAloneCountsAsInstalled() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "notify = [\"somebody-elses-tool\"]\n".write(
            to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(!HookSetup.codexHookInstalled(home: home))

        let command = "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py codex-hook"
        try #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"command":"\#(command)"}]}]}}"#
            .write(
                to: codex.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        #expect(HookSetup.codexHookInstalled(home: home))
    }

    /// The note is due when Codex's own trust records are empty for our hooks
    /// file — not when this particular run happened to change something.
    @Test func trustIsAwaitedUntilCodexRecordsIt() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let hooksFile = codex.appendingPathComponent("hooks.json")

        // Nothing installed: nothing to say.
        #expect(!HookSetup.codexHooksAwaitTrust(home: home))

        let command = "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py codex-hook"
        try #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"command":"\#(command)"}]}]}}"#
            .write(to: hooksFile, atomically: true, encoding: .utf8)
        // Registered, no config.toml at all — still waiting.
        #expect(HookSetup.codexHooksAwaitTrust(home: home))

        let config = codex.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(HookSetup.codexHooksAwaitTrust(home: home))

        try ("[hooks.state.\"\(hooksFile.path):stop:0:0\"]\ntrusted_hash = \"sha256:abc\"\n")
            .write(to: config, atomically: true, encoding: .utf8)
        #expect(!HookSetup.codexHooksAwaitTrust(home: home))
    }

    @Test func aConfigWithoutOurHookDoesNotCountAsInstalled() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"hooks":[{"command":"somebody-elses-hook.sh"}]}]}}"#
            .write(
                to: claude.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
        #expect(!HookSetup.claudeHookInstalled(home: home))
    }

    @Test func agentPresenceMeansTheHomeDirectoryExists() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!HookSetup.claudePresent(home: home))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(HookSetup.claudePresent(home: home))
        // A stray *file* named .codex is not a CLI installation.
        try Data().write(to: home.appendingPathComponent(".codex"))
        #expect(!HookSetup.codexPresent(home: home))
    }
}
