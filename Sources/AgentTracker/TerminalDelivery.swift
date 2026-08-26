import Foundation

/// Everything delivery refuses, decided without sending anything.
///
/// Pure by construction: no clock, no disk, no Apple events. The whole point is
/// that the reasons a line must NOT be typed are reviewable and testable before
/// any code exists that can type. A refusal here is a success — typing into the
/// wrong session is the one failure in this path that cannot be undone.
///
/// Renaming from the app is the only feature that writes into a terminal; it
/// resolves through here (via `SessionTarget`) and refuses on the same grounds.
enum TerminalDelivery {
    /// The Ghostty surface a write is aimed at, recorded at resolution time.
    ///
    /// `surfaceId` is Ghostty's own stable per-surface identifier, and it is what
    /// makes the *write* exact — verified on this machine: `perform action` honours
    /// its `on` target for a surface that is not focused, while five sibling
    /// windows shared one title.
    ///
    /// `terminalPid` is recorded alongside it because the id namespace does not
    /// outlive the app. A restarted Ghostty can mint the same id for a different
    /// surface, and "the id still resolves" would then be a stranger's pane.
    struct Target: Equatable, Sendable {
        var surfaceId: String
        /// The window title that identified this surface when it was resolved.
        var title: String
        /// pid of the terminal application, not of the agent.
        var terminalPid: Int32
    }

    /// The tmux pane a write is aimed at.
    ///
    /// Both fields come from the session's own environment, captured by the hook
    /// at session start — no matching, no guessing. `tty` is what makes the id
    /// safe to reuse later: tmux mints pane ids monotonically per server, but a
    /// server restarted overnight starts again at `%0`, and "the id still
    /// resolves" would then be a stranger's pane. Two panes never share a tty.
    struct TmuxTarget: Equatable, Sendable {
        var paneId: String
        var tty: String
        /// The server socket this pane belongs to, from `$TMUX`. Absent means
        /// tmux's default socket.
        var socketPath: String?
    }

    /// Refuses unless the recorded pane is still exactly the pane it was.
    ///
    /// Deliberately not "find the pane whose tty matches": that would silently
    /// follow a session into a pane it was never recorded against. Both halves
    /// must still agree.
    static func resolveTmux(
        recorded: TmuxTarget,
        among panes: [TmuxScripting.Pane]
    ) -> Verdict {
        guard let pane = panes.first(where: { $0.id == recorded.paneId }) else {
            return .refused(reason: "The tmux pane this session was in is gone")
        }
        guard pane.tty == recorded.tty else {
            return .refused(
                reason: "The tmux pane this session was in now holds a different terminal")
        }
        return .allowed
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
                reason: "Can't tell which window this session is in; it has no name to match")
        }
        let wanted = normalize(expectedTitle)
        guard !wanted.isEmpty else {
            return .refused(
                reason:
                    "Can't tell which window this session is in; its name is only a status mark")
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

    /// Whether the agent is the process that would actually receive the keystrokes.
    ///
    /// `pgid == tpgid` means the agent's process group owns the terminal, so what
    /// is typed reaches the agent rather than something it launched. Without this,
    /// a session sitting in `vim` takes the line as editor commands, and one at a
    /// `sudo` prompt takes it as a password.
    ///
    /// This is the check that replaces reading the screen. The Accessibility route
    /// cannot do it: this repo's own measurements show the AX window list covers
    /// only the current Space, so it goes blind for any window the user is not
    /// looking at. One syscall, no permission, works on every Space.
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
