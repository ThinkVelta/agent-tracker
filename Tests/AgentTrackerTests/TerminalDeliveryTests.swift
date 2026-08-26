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
final class TerminalDeliveryTests {
    private let ghosttyPid: Int32 = 1419

    /// Titles exactly as Ghostty reported them, projects renamed.
    private var realWorldSurfaces: [TerminalDelivery.Surface] {
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
        -> TerminalDelivery.Surface
    {
        TerminalDelivery.Surface(id: id, title: title, workingDirectory: cwd)
    }

    // MARK: - Which pane

    @Test func aUniquelyTitledWindowResolves() throws {
        let resolution = TerminalDelivery.resolve(
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
            let resolution = TerminalDelivery.resolve(
                expectedTitle: "Initial setup and access granted", among: surfaces,
                terminalPid: ghosttyPid)
            #expect(resolution.target?.surfaceId == "only", "\(title)")
        }
    }

    /// The case that actually dominates. Five windows share one path-derived
    /// title, so there is no way to tell them apart and picking one would be a
    /// coin flip into someone's live session.
    @Test func identicalTitlesRefuseAndSayHowManyTheyCouldNotTellApart() throws {
        let resolution = TerminalDelivery.resolve(
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
        let resolution = TerminalDelivery.resolve(
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
            let resolution = TerminalDelivery.resolve(
                expectedTitle: title, among: realWorldSurfaces, terminalPid: ghosttyPid)
            #expect(resolution.target == nil, "\(title ?? "nil") should not resolve")
            #expect(resolution.refusal?.isEmpty == false)
        }
    }

    @Test func noWindowsAtAllRefuses() {
        let resolution = TerminalDelivery.resolve(
            expectedTitle: "anything", among: [], terminalPid: ghosttyPid)
        #expect(resolution.refusal != nil)
    }

    // MARK: - Is the agent even listening

    /// `pgid == tpgid` is what replaced reading the screen: this repo's own
    /// measurements show the Accessibility window list covers only the current
    /// Space, so it goes blind for any window the user is not looking at.
    @Test func theAgentMustOwnTheTerminalBeforeAnythingIsWritten() throws {
        #expect(
            TerminalDelivery.foregroundAllows(pgid: 5150, tpgid: 5150, comm: "claude") == .allowed)

        // In vim, a typed line is editor commands; at a sudo prompt it is
        // submitted as a password.
        let busy = TerminalDelivery.foregroundAllows(pgid: 5150, tpgid: 6001, comm: "vim")
        #expect(busy != .allowed)
        #expect(try #require(busy.refusal).contains("vim"))

        // No comm to name still refuses, just less specifically.
        #expect(TerminalDelivery.foregroundAllows(pgid: 5150, tpgid: 6001, comm: nil) != .allowed)

        // Unreadable ids are a refusal, never an assumption.
        for (pgid, tpgid) in [(Int32(0), Int32(0)), (5150, 0), (0, 5150), (-1, -1)] {
            #expect(
                TerminalDelivery.foregroundAllows(pgid: pgid, tpgid: tpgid, comm: "claude")
                    != .allowed, "\(pgid)/\(tpgid)")
        }
    }
}
