import Foundation

/// Everything delivery refuses, decided without sending anything.
///
/// Pure by construction: no clock, no disk, no Apple events. The whole point is
/// that the reasons a "Continue" must NOT be typed are reviewable and testable
/// before any code exists that can type. A refusal here is a success — typing
/// into the wrong session is the only failure in this feature that cannot be
/// undone.
///
/// Deliberately no `now: Date = Date()` defaults, matching `ContinueScheduler`.
enum ContinueDelivery {
    /// Where a message could be written.
    ///
    /// Ghostty only, for now. Not an oversight: measured on this machine, tmux,
    /// kitty, WezTerm and iTerm2 are absent, so their write paths could not be
    /// executed even once — and untested delivery code is exactly the thing this
    /// design refuses to ship. Terminal.app is a permanent exclusion rather than
    /// a pending one: its entire scripting dictionary has a single text-injecting
    /// command, `do script`, which *runs* what it is given. There is no
    /// write-without-Return primitive to find.
    enum Channel: Equatable {
        case ghostty
        case unsupported(reason: String)

        var isSupported: Bool { self == .ghostty }

        /// What the row says when the clock is greyed out. Always present for an
        /// unsupported channel: a control the user can see and cannot use owes
        /// them the reason.
        var unsupportedReason: String? {
            guard case .unsupported(let reason) = self else { return nil }
            return reason
        }
    }

    static func channel(forTermProgram termProgram: String?) -> Channel {
        switch termProgram?.lowercased() {
        case "ghostty":
            return .ghostty
        case "apple_terminal":
            return .unsupported(
                reason: "Terminal.app can only run text, not type it — it has no way to put a "
                    + "message on the prompt without pressing Return")
        case "tmux", "screen":
            return .unsupported(
                reason: "Sending into a multiplexer pane isn't built yet")
        case let other?:
            return .unsupported(reason: "Sending into \(other) isn't built yet")
        case nil:
            return .unsupported(reason: "This session didn't report which terminal it's in")
        }
    }

    /// The pane a schedule was armed against, recorded at arming time and checked
    /// again before anything is written.
    ///
    /// `surfaceId` is Ghostty's own stable per-surface identifier, and it is what
    /// makes the *write* exact — verified on this machine: `perform action` honours
    /// its `on` target for a surface that is not focused, while five sibling
    /// windows shared one title.
    ///
    /// `terminalPid` is recorded alongside it because the id namespace does not
    /// outlive the app. A restarted Ghostty can mint the same id for a different
    /// surface, and "the id still resolves" would then be a stranger's pane.
    struct Target: Equatable, Codable, Sendable {
        var surfaceId: String
        /// The window title that identified this surface when it was armed.
        var title: String
        /// pid of the terminal application, not of the agent.
        var terminalPid: Int32
    }

    /// One terminal surface as the app can see it.
    struct Surface: Equatable {
        var id: String
        var title: String
        var workingDirectory: String
    }

    /// A pass-or-refuse with no target involved. Separate from `Resolution` so a
    /// permission check cannot be made to hand back a pane it knows nothing about.
    enum Verdict: Equatable {
        case allowed
        case refused(reason: String)

        var refusal: String? {
            guard case .refused(let reason) = self else { return nil }
            return reason
        }
    }

    enum Resolution: Equatable {
        case ready(Target)
        case refused(reason: String)

        var target: Target? {
            guard case .ready(let target) = self else { return nil }
            return target
        }

        var refusal: String? {
            guard case .refused(let reason) = self else { return nil }
            return reason
        }
    }

    // MARK: - Which pane

    /// Picks the one surface a session is in, or refuses and says why.
    ///
    /// Never a rotation, never a best guess. `TerminalFocuser.chooseAmbiguous`
    /// deliberately cycles through candidates so repeated clicks reach different
    /// windows — correct for focusing, catastrophic here, because the input that
    /// decides the winner is a click count held in memory.
    ///
    /// The title is the only discriminator Ghostty offers: its `terminal` class
    /// exposes `id`, `name` and `working directory` and nothing else, a pane's
    /// environment carries no surface handle, so a session cannot self-report
    /// where it is. Measured on one real machine: of nine windows, two carried a
    /// distinct Claude session title and seven collapsed to a path — five of them
    /// byte-identical. So refusing is the common case, not the edge case, and the
    /// reason has to say which window it could not tell apart from what.
    static func resolve(
        expectedTitle: String?,
        among surfaces: [Surface],
        terminalPid: Int32
    ) -> Resolution {
        guard let expectedTitle, !expectedTitle.isEmpty else {
            return .refused(
                reason: "Can't tell which window this session is in — it has no name to match")
        }
        let wanted = normalize(expectedTitle)
        guard !wanted.isEmpty else {
            return .refused(
                reason:
                    "Can't tell which window this session is in — its name is only a status mark")
        }
        let matches = surfaces.filter { normalize($0.title) == wanted }
        switch matches.count {
        case 1:
            guard let match = matches.first else {
                return .refused(reason: "Can't tell which window this session is in")
            }
            return .ready(
                Target(surfaceId: match.id, title: match.title, terminalPid: terminalPid))
        case 0:
            return .refused(reason: "No terminal window is showing this session any more")
        default:
            return .refused(
                reason:
                    "\(matches.count) windows look identical to this one, so there's no way to "
                    + "tell them apart. Running the session inside tmux would make it exact.")
        }
    }

    /// Re-resolves a recorded target immediately before writing, and aborts on any
    /// disagreement.
    ///
    /// Arming and firing can be twelve hours apart. In between, Ghostty may have
    /// restarted, the surface may have closed, and the window may have been reused
    /// for something else. Every one of those reads as "the id is gone or means
    /// something different now", and each is a refusal rather than a re-derivation:
    /// re-deriving is how you end up typing into whatever happens to look closest.
    static func verify(
        recorded: Target,
        among surfaces: [Surface],
        terminalPid: Int32
    ) -> Resolution {
        guard recorded.terminalPid == terminalPid else {
            return .refused(
                reason: "The terminal app has restarted since this was scheduled, so its window "
                    + "ids no longer mean the same thing")
        }
        guard let live = surfaces.first(where: { $0.id == recorded.surfaceId }) else {
            return .refused(reason: "The window this was scheduled for has closed")
        }
        guard normalize(live.title) == normalize(recorded.title) else {
            return .refused(
                reason: "That window is showing something else now, so it may not be this session")
        }
        return .ready(recorded)
    }

    /// Claude Code titles a window with its session name behind a status glyph,
    /// and the glyph changes as the session works — so comparing raw titles would
    /// make a match come and go. Mirrors what `TerminalFocuser` already strips.
    static func normalize(_ title: String) -> String {
        let stripped = title.unicodeScalars.drop { scalar in
            // Leading status marks and whitespace only. Anything alphanumeric ends
            // the prefix, so a title that IS a glyph normalizes to empty and is
            // refused rather than matching every other glyph-only title.
            !CharacterSet.alphanumerics.contains(scalar) && !titleBodyStart.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A path-derived title is a legitimate name, so these end the glyph prefix
    /// just as an alphanumeric does.
    private static let titleBodyStart = CharacterSet(charactersIn: "/~.")

    // MARK: - Whether to write at all

    /// Permission modes Claude Code is known to run in.
    ///
    /// An allowlist, and every known value is allowed — including the unattended
    /// ones. Ruben's call (2026-08-05), and the reasoning is that auto-resume adds
    /// no capability a bypass-mode session did not already have: typing "Continue"
    /// by hand has exactly the same effect, so the only difference is that nobody
    /// is watching when it starts. What the app owes that decision is a plain
    /// statement at arming time, not a refusal.
    ///
    /// An unrecognized string still refuses, because a mode nobody has seen cannot
    /// be reasoned about.
    static let knownPermissionModes: Set<String> = [
        "acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan",
    ]

    /// Modes where a resumed session can act without stopping to ask. Not blocked
    /// — surfaced, so arming one is an informed choice.
    static let unattendedPermissionModes: Set<String> = ["bypassPermissions", "dontAsk"]

    static func permissionModeAllows(_ mode: String?) -> Verdict {
        guard let mode, !mode.isEmpty else {
            // Absent is not the same as unknown: a session writes its mode into the
            // transcript only when it is set or changed, so most have none to read
            // and refusing those would disable the feature by default.
            return .allowed
        }
        guard knownPermissionModes.contains(mode) else {
            return .refused(
                reason: "This session is in a permission mode this version doesn't recognise "
                    + "(\(mode)), so it won't be resumed automatically")
        }
        return .allowed
    }

    /// What the arming UI must say out loud when a mode acts without asking.
    static func unattendedWarning(for mode: String?) -> String? {
        guard let mode, unattendedPermissionModes.contains(mode) else { return nil }
        return "This session runs without asking permission (\(mode)). Once resumed it can keep "
            + "working, including running commands, while nobody is watching."
    }

    /// Whether the agent is the process that would actually receive the keystrokes.
    ///
    /// `pgid == tpgid` means the agent's process group owns the terminal, so what
    /// is typed reaches the agent rather than something it launched. Without this,
    /// a session sitting in `vim` takes "Continue" as editor commands, and one at a
    /// `sudo` prompt takes it as a password.
    ///
    /// This is the check that replaces reading the screen. The Accessibility route
    /// the plan originally called for cannot do it: this repo's own measurements
    /// show the AX window list covers only the current Space, so it goes blind
    /// exactly when a scheduled continue fires — when the user is elsewhere.
    /// One syscall, no permission, works on every Space.
    static func foregroundAllows(pgid: Int32, tpgid: Int32, comm: String?) -> Verdict {
        guard pgid > 0, tpgid > 0 else {
            return .refused(reason: "Can't tell what's in the foreground of that terminal")
        }
        guard pgid == tpgid else {
            let running = comm.map { " (\($0) is)" } ?? ""
            return .refused(
                reason: "The agent isn't the foreground program in that window\(running), so the "
                    + "message would go somewhere else")
        }
        return .allowed
    }
}
