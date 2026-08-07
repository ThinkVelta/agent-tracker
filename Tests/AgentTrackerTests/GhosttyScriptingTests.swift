import AppKit
import Foundation
import Testing

@testable import AgentTracker

/// Reads a real Ghostty when one is running, and asserts the shape either way.
///
/// Deliberately not mocked. The whole risk in this file is whether the raw Apple
/// event plumbing matches what Ghostty actually accepts, and a mock would assert
/// my own assumptions back at me — which is precisely how the first version read
/// "zero windows, no error" against nine real ones.
///
/// Every one of these sends `count` or `get` only. Nothing here can write.
final class GhosttyScriptingTests {
    private var ghosttyIsRunning: Bool {
        GhosttyScripting.runningApplication() != nil
    }

    /// One sample, exactly as delivery takes one — every call is addressed to
    /// this process rather than each rediscovering the app for itself.
    private var ghosttyPid: pid_t? {
        GhosttyScripting.runningApplication()?.processIdentifier
    }

    /// With Ghostty absent, everything must refuse rather than hang or crash —
    /// which is also the CI path, where no terminal app exists at all.
    @Test func withoutGhosttyEverythingRefusesCleanly() {
        guard !ghosttyIsRunning else { return }
        // `Result<Void, _>` is not Equatable, so match the case rather than
        // making the production type conform for a test's convenience.
        if case .failure(let failure) = GhosttyScripting.automationPermission(pid: 1) {
            #expect(failure == .notRunning)
        } else {
            Issue.record("permission check succeeded with no Ghostty running")
        }
        switch GhosttyScripting.surfaces(pid: 1) {
        case .failure(let failure):
            #expect(failure == .notRunning)
            #expect(failure.reason.isEmpty == false)
        case .success:
            Issue.record("surfaces() succeeded with no Ghostty running")
        }
    }

    /// The read that delivery depends on. If this returns an empty list while
    /// windows are open, every schedule silently refuses — so an empty result is
    /// only acceptable when Ghostty genuinely has no windows.
    @Test func aRunningGhosttyReportsItsSurfaces() throws {
        guard ghosttyIsRunning else { return }
        guard let pid = ghosttyPid,
            case .success = GhosttyScripting.automationPermission(pid: pid)
        else {
            // Not granted on this machine, which is a legitimate state and not a
            // failure of this code.
            return
        }

        let surfaces = try GhosttyScripting.surfaces(pid: pid).get()
        // Ghostty is running, so there is at least one window.
        #expect(surfaces.isEmpty == false, "read no surfaces from a running Ghostty")
        for surface in surfaces {
            #expect(surface.id.isEmpty == false, "a surface came back with no id")
            // Ids are UUIDs, which is what makes them usable as a fire-time
            // equality check rather than a heuristic.
            #expect(UUID(uuidString: surface.id) != nil, "id was not a UUID: \(surface.id)")
        }
        // Ids must be unique, or "re-resolve the recorded id" resolves to two panes.
        #expect(Set(surfaces.map(\.id)).count == surfaces.count)
    }

    /// Reading twice must agree. A specifier form that Ghostty half-accepts would
    /// show up here as a list that changes shape between identical calls.
    @Test func readingTwiceGivesTheSameSurfaces() throws {
        guard let pid = ghosttyPid,
            case .success = GhosttyScripting.automationPermission(pid: pid)
        else { return }
        let first = try GhosttyScripting.surfaces(pid: pid).get()
        let second = try GhosttyScripting.surfaces(pid: pid).get()
        #expect(Set(first.map(\.id)) == Set(second.map(\.id)))
    }

    /// Every failure has to be sayable to a user, since the row shows the reason.
    @Test func everyFailureHasAReason() {
        for failure in [
            GhosttyScripting.Failure.notRunning,
            .notPermitted,
            .unreadable("something specific"),
        ] {
            #expect(failure.reason.isEmpty == false)
        }
        #expect(GhosttyScripting.Failure.notPermitted.reason.contains("Automation"))
        #expect(GhosttyScripting.Failure.unreadable("detail").reason.contains("detail"))
    }
}
