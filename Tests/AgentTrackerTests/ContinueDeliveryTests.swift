import Foundation
import Testing

@testable import AgentTracker

/// Delivery's refusals, all decided without anything that can type.
///
/// The window fixtures are the real distribution from one machine: nine Ghostty
/// windows, of which two carried a distinct Claude session title and seven
/// collapsed to a path — five of those byte-identical. Five identical titles is a
/// far better test than a synthetic pair, because it is what the feature will
/// actually meet.
final class ContinueDeliveryTests {
    private let ghosttyPid: Int32 = 1419

    /// Titles exactly as Ghostty reported them, projects renamed.
    private var realWorldSurfaces: [ContinueDelivery.Surface] {
        [
            surface("A", "✳ Initial setup and access granted", "/Users/dev/acme/blog"),
            surface("B", "…/Documents/acme/scheduler", "/Users/dev/acme/scheduler"),
            surface(
                "C", "⠂ Continue tool development with menu interaction", "/Users/dev/oss/tracker"),
            surface("D", "scheduler", "/Users/dev/acme/scheduler"),
            surface("E", "scheduler", "/Users/dev/acme/scheduler"),
            surface("F", "…/Documents/acme/scheduler", "/Users/dev/acme/scheduler"),
            surface("G", "…/Documents/acme/scheduler", "/Users/dev/acme/scheduler"),
            surface("H", "…/Documents/acme/scheduler", "/Users/dev/acme/scheduler"),
            surface("I", "…/Documents/acme/scheduler", "/Users/dev/acme/scheduler"),
        ]
    }

    private func surface(_ id: String, _ title: String, _ cwd: String)
        -> ContinueDelivery.Surface
    {
        ContinueDelivery.Surface(id: id, title: title, workingDirectory: cwd)
    }

    // MARK: - Which terminal

    @Test func onlyGhosttyIsASupportedChannel() {
        #expect(ContinueDelivery.channel(forTermProgram: "ghostty") == .ghostty)
        #expect(ContinueDelivery.channel(forTermProgram: "Ghostty").isSupported)

        // Terminal.app is a permanent exclusion, not a pending one: `do script`
        // runs what it is given, so there is no way to type without Return.
        let terminal = ContinueDelivery.channel(forTermProgram: "Apple_Terminal")
        #expect(terminal.isSupported == false)
        #expect(terminal.unsupportedReason?.contains("only run text") == true)

        for other in ["tmux", "iTerm.app", "WezTerm", "vscode"] {
            #expect(
                ContinueDelivery.channel(forTermProgram: other).isSupported == false, "\(other)")
        }
        #expect(ContinueDelivery.channel(forTermProgram: nil).isSupported == false)
    }

    /// Every refusal carries a reason, because a greyed control that will not say
    /// why is not self-explaining.
    @Test func everyUnsupportedChannelExplainsItself() {
        for program in ["Apple_Terminal", "tmux", "screen", "warp", nil] {
            let channel = ContinueDelivery.channel(forTermProgram: program)
            let reason = channel.unsupportedReason
            #expect(reason?.isEmpty == false, "\(program ?? "nil") gave no reason")
        }
    }

    // MARK: - Which pane

    @Test func aUniquelyTitledWindowResolves() throws {
        let resolution = ContinueDelivery.resolve(
            expectedTitle: "Initial setup and access granted",
            among: realWorldSurfaces, terminalPid: ghosttyPid)
        let target = try #require(resolution.target)
        #expect(target.surfaceId == "A")
        #expect(target.terminalPid == ghosttyPid)
    }

    /// The status glyph changes as a session works, so a raw comparison would make
    /// the match come and go while the window never moved.
    @Test func theStatusGlyphIsStrippedBeforeComparing() throws {
        for title in [
            "✳ Initial setup and access granted",
            "⠂ Initial setup and access granted",
            "  ✳   Initial setup and access granted  ",
        ] {
            let surfaces = [surface("only", title, "/Users/dev/acme/blog")]
            let resolution = ContinueDelivery.resolve(
                expectedTitle: "Initial setup and access granted", among: surfaces,
                terminalPid: ghosttyPid)
            #expect(resolution.target?.surfaceId == "only", "\(title)")
        }
    }

    /// The case that actually dominates. Five windows share one path-derived
    /// title, so there is no way to tell them apart and picking one would be a
    /// coin flip into someone's live session.
    @Test func identicalTitlesRefuseAndSayHowManyTheyCouldNotTellApart() throws {
        let resolution = ContinueDelivery.resolve(
            expectedTitle: "…/Documents/acme/scheduler",
            among: realWorldSurfaces, terminalPid: ghosttyPid)
        #expect(resolution.target == nil)
        let reason = try #require(resolution.refusal)
        #expect(reason.contains("5 windows"))
        // The escape hatch is named, because "no" without a route forward is not
        // much use: a session inside tmux has an exact pane handle.
        #expect(reason.contains("tmux"))
    }

    @Test func aTitleNoWindowShowsRefuses() throws {
        let resolution = ContinueDelivery.resolve(
            expectedTitle: "Some session that has since closed",
            among: realWorldSurfaces, terminalPid: ghosttyPid)
        #expect(resolution.target == nil)
        #expect(resolution.refusal?.contains("No terminal window") == true)
    }

    /// A session with no name has nothing to match on, and a title that is only a
    /// glyph normalizes to nothing — which must refuse rather than match every
    /// other glyph-only title.
    @Test func aSessionWithNothingToMatchOnRefuses() {
        for title in [nil, "", "✳", "⠂  "] {
            let resolution = ContinueDelivery.resolve(
                expectedTitle: title, among: realWorldSurfaces, terminalPid: ghosttyPid)
            #expect(resolution.target == nil, "\(title ?? "nil") should not resolve")
            #expect(resolution.refusal?.isEmpty == false)
        }
    }

    @Test func noWindowsAtAllRefuses() {
        let resolution = ContinueDelivery.resolve(
            expectedTitle: "anything", among: [], terminalPid: ghosttyPid)
        #expect(resolution.refusal != nil)
    }

    // MARK: - Re-resolving before writing

    /// Arming and firing can be twelve hours apart, so the recorded pane is
    /// checked again rather than trusted.
    @Test func anUnchangedTargetVerifies() throws {
        let armed = try #require(
            ContinueDelivery.resolve(
                expectedTitle: "Initial setup and access granted",
                among: realWorldSurfaces, terminalPid: ghosttyPid
            ).target)
        let verified = ContinueDelivery.verify(
            recorded: armed, among: realWorldSurfaces, terminalPid: ghosttyPid)
        #expect(verified.target == armed)
    }

    /// Surface ids are only meaningful within one run of the terminal app. A
    /// restarted Ghostty can mint the same id for a different surface, so "the id
    /// still resolves" would be a stranger's pane.
    @Test func aRestartedTerminalRefusesEvenWhenTheIdStillResolves() throws {
        let armed = ContinueDelivery.Target(
            surfaceId: "A", title: "✳ Initial setup and access granted", terminalPid: ghosttyPid)
        let verified = ContinueDelivery.verify(
            recorded: armed, among: realWorldSurfaces, terminalPid: ghosttyPid + 1)
        #expect(verified.target == nil)
        #expect(verified.refusal?.contains("restarted") == true)
    }

    @Test func aClosedWindowRefuses() throws {
        let armed = ContinueDelivery.Target(
            surfaceId: "gone", title: "Initial setup", terminalPid: ghosttyPid)
        let verified = ContinueDelivery.verify(
            recorded: armed, among: realWorldSurfaces, terminalPid: ghosttyPid)
        #expect(verified.refusal?.contains("has closed") == true)
    }

    /// Same id, different session in it now. The window was reused, so writing
    /// would land in whatever took it over.
    @Test func aReusedWindowRefuses() throws {
        let armed = ContinueDelivery.Target(
            surfaceId: "A", title: "✳ Initial setup and access granted", terminalPid: ghosttyPid)
        let reused = [surface("A", "✳ Something else entirely", "/Users/dev/acme/blog")]
        let verified = ContinueDelivery.verify(
            recorded: armed, among: reused, terminalPid: ghosttyPid)
        #expect(verified.target == nil)
        #expect(verified.refusal?.contains("showing something else") == true)
    }

    /// A glyph change is not a session change, so it must not abort a fire.
    @Test func onlyTheGlyphChangingStillVerifies() throws {
        let armed = ContinueDelivery.Target(
            surfaceId: "A", title: "✳ Initial setup and access granted", terminalPid: ghosttyPid)
        let working = [surface("A", "⠂ Initial setup and access granted", "/Users/dev/acme/blog")]
        #expect(
            ContinueDelivery.verify(recorded: armed, among: working, terminalPid: ghosttyPid).target
                != nil)
    }

    // MARK: - Permission modes

    /// Every known mode is allowed, the unattended ones included. Ruben's call
    /// (2026-08-05): auto-resume adds no capability a bypass-mode session did not
    /// already have, so what the app owes is a plain statement, not a refusal.
    @Test func everyKnownPermissionModeIsAllowed() {
        for mode in ["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"] {
            #expect(ContinueDelivery.permissionModeAllows(mode) == .allowed, "\(mode)")
        }
        // Absent is not unknown: a session records its mode only when it is set or
        // changed, so most have none and refusing those would disable the feature.
        #expect(ContinueDelivery.permissionModeAllows(nil) == .allowed)
        #expect(ContinueDelivery.permissionModeAllows("") == .allowed)
    }

    /// A mode nobody has seen cannot be reasoned about, so it refuses — the one
    /// direction the allowlist exists for.
    @Test func anUnknownPermissionModeRefuses() throws {
        let verdict = ContinueDelivery.permissionModeAllows("yoloMode")
        #expect(verdict != .allowed)
        #expect(try #require(verdict.refusal).contains("yoloMode"))
    }

    /// The two modes that act without asking are surfaced, not blocked.
    @Test func unattendedModesAreStatedPlainlyRatherThanRefused() throws {
        for mode in ["bypassPermissions", "dontAsk"] {
            let warning = try #require(ContinueDelivery.unattendedWarning(for: mode))
            #expect(warning.contains("without asking"))
            #expect(warning.contains("nobody is watching"))
            // Allowed as well as warned — the point is informed consent.
            #expect(ContinueDelivery.permissionModeAllows(mode) == .allowed, "\(mode)")
        }
        for mode in ["auto", "default", "acceptEdits", "plan"] {
            #expect(ContinueDelivery.unattendedWarning(for: mode) == nil, "\(mode)")
        }
        #expect(ContinueDelivery.unattendedWarning(for: nil) == nil)
    }

    // MARK: - Is the agent even listening

    /// `pgid == tpgid` is what replaced reading the screen: this repo's own
    /// measurements show the Accessibility window list covers only the current
    /// Space, so it goes blind exactly when a scheduled continue fires.
    @Test func theAgentMustOwnTheTerminalBeforeAnythingIsWritten() throws {
        #expect(
            ContinueDelivery.foregroundAllows(pgid: 5150, tpgid: 5150, comm: "claude") == .allowed)

        // In vim, "Continue" is change-to-end-of-line; at a sudo prompt it is
        // submitted as a password.
        let busy = ContinueDelivery.foregroundAllows(pgid: 5150, tpgid: 6001, comm: "vim")
        #expect(busy != .allowed)
        #expect(try #require(busy.refusal).contains("vim"))

        // No comm to name still refuses, just less specifically.
        #expect(ContinueDelivery.foregroundAllows(pgid: 5150, tpgid: 6001, comm: nil) != .allowed)

        // Unreadable ids are a refusal, never an assumption.
        for (pgid, tpgid) in [(Int32(0), Int32(0)), (5150, 0), (0, 5150), (-1, -1)] {
            #expect(
                ContinueDelivery.foregroundAllows(pgid: pgid, tpgid: tpgid, comm: "claude")
                    != .allowed, "\(pgid)/\(tpgid)")
        }
    }
}
