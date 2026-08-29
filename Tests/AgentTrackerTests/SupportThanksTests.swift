import Testing

@testable import AgentTracker

final class SupportThanksTests {
    private func shouldShow(
        previous: String? = "0.11.0",
        current: String = "0.12.0",
        bundled: Bool = true,
        enabled: Bool = true
    ) -> Bool {
        SupportThanks.shouldShow(
            previousVersion: previous, currentVersion: current,
            isBundled: bundled, enabled: enabled)
    }

    @Test func firstLaunchAfterAnUpdateShows() {
        #expect(shouldShow())
    }

    @Test func sameVersionStaysQuiet() {
        #expect(!shouldShow(previous: "0.12.0", current: "0.12.0"))
    }

    /// No record means first run — onboarding's moment — or the release that
    /// introduced the window; both stay silent.
    @Test func noRecordedVersionStaysQuiet() {
        #expect(!shouldShow(previous: nil))
    }

    @Test func optOutStaysQuiet() {
        #expect(!shouldShow(enabled: false))
    }

    @Test func developmentBuildsStayQuiet() {
        #expect(!shouldShow(bundled: false))
    }

    /// Any version change qualifies, downgrades included: a rollback swapped
    /// the bundle just the same.
    @Test func downgradeCountsAsAnUpdate() {
        #expect(shouldShow(previous: "0.12.0", current: "0.11.0"))
    }
}
