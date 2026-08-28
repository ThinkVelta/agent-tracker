import Foundation

/// The once-per-update "thank you" decision, kept pure so the show/don't-show
/// rules are testable — the sibling of `Onboarding`. The I/O that feeds it
/// (reading and recording the launched version) lives in the AppDelegate.
enum SupportThanks {
    /// The support channels, the same set `.github/FUNDING.yml` declares;
    /// keep the two in step.
    static let sponsorsURL = URL(string: "https://github.com/sponsors/ThinkVelta")!
    static let paypalURL = URL(string: "https://paypal.me/broekxruben")!
    static let repoURL = URL(string: "https://github.com/ThinkVelta/agent-tracker")!

    /// Show only on the first launch after an update: a recorded earlier
    /// version that differs from this one. Never on first run — that moment
    /// belongs to onboarding, and opening the relationship with a donation
    /// ask is a poor first impression. A nil record also keeps the release
    /// that introduces this window silent; the asks start with the update
    /// after it. Any version *change* qualifies, downgrades included — a
    /// rollback swapped the bundle just the same, and telling the two apart
    /// would re-implement `UpdateCheck.isNewer` for one edge nobody hits.
    static func shouldShow(
        previousVersion: String?,
        currentVersion: String,
        isBundled: Bool,
        enabled: Bool
    ) -> Bool {
        guard isBundled, enabled, let previous = previousVersion else { return false }
        return previous != currentVersion
    }
}
