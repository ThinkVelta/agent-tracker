import Foundation
import Testing

@testable import AgentTracker

final class OnboardingTests {
    private func environment(
        accessibility: Bool = false,
        hook: Bool = false,
        claude: Bool = true,
        completed: Bool = false
    ) -> Onboarding.Environment {
        Onboarding.Environment(
            accessibilityGranted: accessibility,
            hookInstalled: hook,
            claudePresent: claude,
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
                environment(accessibility: false, hook: false, completed: true)))
    }

    /// Anything already set up means this user knows the app: the permission
    /// banner in the popover covers a missing grant, and a hook implies a past
    /// install. Showing "Welcome" to them would read as amnesia on upgrade.
    @Test func anyExistingSetupSuppressesOnboarding() {
        #expect(!Onboarding.shouldShow(environment(accessibility: true)))
        #expect(!Onboarding.shouldShow(environment(hook: true)))
    }

    /// The consent step names the exact file the installer edits. Never edit a
    /// config without saying which.
    @Test func theConsentStepNamesTheEditedConfig() {
        #expect(Onboarding.editedConfig == "~/.claude/settings.json")
        #expect(Onboarding.installerScript.hasSuffix(".sh"))
    }

    // MARK: - HookSetup probes (temp home, never the real one)

    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func hookDetectionReadsTheClaudeConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!HookSetup.claudeHookInstalled(home: home))

        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try
            #"{"hooks":{"Stop":[{"hooks":[{"command":"~/.agent-tracker/bin/agent-tracker-hook.py claude"}]}]}}"#
            .write(
                to: claude.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
        #expect(HookSetup.claudeHookInstalled(home: home))
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

    @Test func presenceMeansTheHomeDirectoryExists() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!HookSetup.claudePresent(home: home))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(HookSetup.claudePresent(home: home))
    }

    /// A stray *file* named .claude is not a CLI installation.
    @Test func aFileIsNotAnInstallation() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent(".claude"))
        #expect(!HookSetup.claudePresent(home: home))
    }
}
