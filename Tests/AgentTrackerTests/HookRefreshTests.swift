import Foundation
import Testing

@testable import AgentTracker

/// The app and the hook script ship together and are installed separately, so
/// they drift. These cover the rule that decides whether to reconcile them.
@Suite("Hook refresh")
struct HookRefreshTests {
    private let current = Data("#!/usr/bin/env python3\n# v2\n".utf8)
    private let stale = Data("#!/usr/bin/env python3\n# v1\n".utf8)

    @Test("a stale installed script is refreshed")
    func staleIsRefreshed() {
        #expect(HookSetup.hookNeedsRefresh(installed: stale, bundled: current))
    }

    @Test("an up-to-date script is left alone")
    func currentIsLeftAlone() {
        #expect(!HookSetup.hookNeedsRefresh(installed: current, bundled: current))
    }

    /// The one that matters most. Writing the script is the integration
    /// installer's job because it also edits the user's `settings.json`, and a
    /// config edit is something somebody agrees to — not something an app does
    /// to them on launch. An absent script means "not set up", never "set up
    /// badly".
    @Test("a machine with no hook installed does not get one")
    func absentIsNotInstalled() {
        #expect(!HookSetup.hookNeedsRefresh(installed: nil, bundled: current))
    }

    /// A `swift run` build with no repo beside it has nothing to refresh from,
    /// and must not treat that as a reason to touch anything.
    @Test("no bundled copy means nothing to do")
    func absentBundleDoesNothing() {
        #expect(!HookSetup.hookNeedsRefresh(installed: stale, bundled: nil))
        #expect(!HookSetup.hookNeedsRefresh(installed: nil, bundled: nil))
    }

    /// End to end against a scratch directory: the bytes land, and the
    /// executable bit survives — an atomic write replaces the file, so the mode
    /// goes with the old one unless it is set again, and the agent runs this
    /// script directly.
    @Test("refreshing writes the bundled script and keeps it executable") func refreshWrites()
        throws
    {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let bin = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let installed = HookSetup.installedHookPath(base: base)
        try stale.write(to: installed)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: installed.path)

        let source = base.appendingPathComponent("bundled-agent-tracker-hook.py")
        try current.write(to: source)
        #expect(HookSetup.refreshInstalledHook(base: base, source: source))

        #expect(try Data(contentsOf: installed) == current)
        let mode =
            try FileManager.default.attributesOfItem(atPath: installed.path)[
                .posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o755)

        // Idempotent: a second launch has nothing left to do.
        #expect(!HookSetup.refreshInstalledHook(base: base, source: source))
    }

    @Test("a machine with no bin directory is untouched")
    func noInstalledScriptIsUntouched() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("bundled-agent-tracker-hook.py")
        try current.write(to: source)

        #expect(!HookSetup.refreshInstalledHook(base: base, source: source))
        #expect(
            !FileManager.default.fileExists(atPath: HookSetup.installedHookPath(base: base).path))
    }
}
