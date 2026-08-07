import Foundation

/// First-run decisions, kept pure so the show/don't-show rules are testable.
/// The I/O that feeds them lives in `HookSetup`.
enum Onboarding {
    /// Everything the first-run decision depends on, probed at launch.
    struct Environment: Equatable {
        var accessibilityGranted = false
        var claudeHookInstalled = false
        var codexHookInstalled = false
        var claudePresent = false
        var codexPresent = false
        var completedBefore = false
    }

    /// Show only when there is genuinely nothing set up — no hooks *and* no
    /// permission — and never twice: any earlier dismissal counts as
    /// completed, so an upgrade or a decline can never re-nag. A partially
    /// set-up install (hooks but no permission, or vice versa) is a user who
    /// already knows the app; the popover's permission banner covers them.
    static func shouldShow(_ environment: Environment) -> Bool {
        guard !environment.completedBefore else { return false }
        return !environment.accessibilityGranted
            && !environment.claudeHookInstalled
            && !environment.codexHookInstalled
    }

    /// Agents whose hooks the install step would set up, in display order.
    /// Absent agents are skipped rather than shown greyed out: onboarding is
    /// one screen, and a row for a CLI the user doesn't have is noise.
    static func installableAgents(_ environment: Environment) -> [Agent] {
        var agents: [Agent] = []
        if environment.claudePresent { agents.append(.claude) }
        if environment.codexPresent { agents.append(.codex) }
        return agents
    }

    enum Agent: String, CaseIterable {
        case claude
        case codex

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        var installerScript: String {
            switch self {
            case .claude: return "install-claude-code.sh"
            case .codex: return "install-codex.sh"
            }
        }

        /// The exact file the installer will edit — shown to the user before
        /// anything runs. Never edit a config without saying which.
        var editedConfig: String {
            switch self {
            case .claude: return "~/.claude/settings.json"
            case .codex: return "~/.codex/hooks.json and config.toml"
            }
        }
    }
}
