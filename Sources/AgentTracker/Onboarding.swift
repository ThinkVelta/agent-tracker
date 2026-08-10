import Foundation

/// First-run decisions, kept pure so the show/don't-show rules are testable.
/// The I/O that feeds them lives in `HookSetup`.
enum Onboarding {
    /// Everything the first-run decision depends on, probed at launch.
    struct Environment: Equatable {
        var accessibilityGranted = false
        var hookInstalled = false
        var claudePresent = false
        var completedBefore = false
    }

    /// Show only when there is genuinely nothing set up — no hook *and* no
    /// permission — and never twice: any earlier dismissal counts as
    /// completed, so an upgrade or a decline can never re-nag. A partially
    /// set-up install (hook but no permission, or vice versa) is a user who
    /// already knows the app; the popover's permission banner covers them.
    static func shouldShow(_ environment: Environment) -> Bool {
        guard !environment.completedBefore else { return false }
        return !environment.accessibilityGranted && !environment.hookInstalled
    }

    /// The installer the install step runs.
    static let installerScript = "install-claude-code.sh"

    /// The exact file it will edit — shown to the user before anything runs.
    /// Never edit a config without saying which.
    static let editedConfig = "~/.claude/settings.json"
}
