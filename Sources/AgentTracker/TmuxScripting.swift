import Foundation

/// Talks to a tmux server through its CLI.
///
/// The reason this exists at all is identity. Ghostty exposes only `id`, `name`
/// and `working directory` per surface, and a session cannot report which
/// surface it is in — so delivery has to match on window title, and measured on
/// one real machine seven of nine windows collapsed to the same path. A tmux
/// pane reports its own id and tty, the hook records both at session start, and
/// nothing has to be guessed.
///
/// Every call is an argv array, never a shell string: the message is
/// user-editable text on its way to a terminal, and a shell between here and
/// there would be one interpretation too many.
enum TmuxScripting {
    /// Where tmux is looked for, in order. Explicit paths rather than a `which`
    /// through a shell: this app is launched by `open`, so its PATH is launchd's
    /// and not the user's shell's — the reason a lookup would have to invent a
    /// shell to be useful, which is exactly what the write path refuses to do.
    static let searchPaths = [
        "/opt/homebrew/bin/tmux",  // Homebrew, Apple silicon
        "/usr/local/bin/tmux",  // Homebrew, Intel
        "/opt/local/bin/tmux",  // MacPorts
        "/run/current-system/sw/bin/tmux",  // Nix, system profile
        "/usr/bin/tmux",
    ]

    /// tmux is fast and local; anything slower than this is a wedged server.
    static let timeout: TimeInterval = 5

    struct Pane: Equatable, Sendable {
        var id: String
        var tty: String
    }

    enum Failure: Error, Equatable {
        case notInstalled
        case noServer
        case unreadable

        var reason: String {
            switch self {
            case .notInstalled: return "tmux isn't installed where this app can find it"
            case .noServer: return "the tmux server isn't running any more"
            case .unreadable: return "tmux didn't say which panes it has"
            }
        }
    }

    static func toolPath() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The server socket named by `$TMUX`, whose format is
    /// `<socket-path>,<server-pid>,<session-id>`.
    ///
    /// Load-bearing rather than tidy. `tmux -L work` or `-S /path` runs a
    /// *separate server* with its own pane-id namespace, and a call with no
    /// `-S` reaches the default server instead — which is a different machine
    /// entirely as far as `%3` is concerned. It cannot mis-deliver, because the
    /// tty pinned alongside the id is unique system-wide, but it would refuse
    /// every write into a pane on a named socket and never say why.
    static func socketPath(fromTmuxVariable value: String?) -> String? {
        guard let value else { return nil }
        let path = value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// `-S` is a global option, so it precedes the command.
    private static func arguments(socketPath: String?, _ command: [String]) -> [String] {
        guard let socketPath else { return command }
        return ["-S", socketPath] + command
    }

    static func panes(socketPath: String?) -> Result<[Pane], Failure> {
        guard let tool = toolPath() else { return .failure(.notInstalled) }
        // -a: every pane on the server, not just the attached session's. A
        // schedule fires while nothing is attached at all.
        guard
            let output = ProcessProbe.run(
                tool, arguments(socketPath: socketPath, ["list-panes", "-a", "-F", paneFormat]),
                timeout: timeout)
        else { return .failure(.noServer) }
        let panes = parsePanes(output)
        return panes.isEmpty ? .failure(.unreadable) : .success(panes)
    }

    static let paneFormat = "#{pane_id}\t#{pane_tty}"

    /// Parses `list-panes -F "#{pane_id}\t#{pane_tty}"`. Never throws: a tmux
    /// that grows a field or prints a warning must not crash the app.
    static func parsePanes(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let id = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let tty = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard id.hasPrefix("%"), !tty.isEmpty else { return nil }
            return Pane(id: id, tty: tty)
        }
    }

    /// Types text without submitting it. `-l` is literal, so nothing in the
    /// message is read as a key name, and `--` stops a message beginning with a
    /// dash being read as a flag.
    static func writeText(_ text: String, toPane pane: String, socketPath: String?) -> Bool {
        guard let tool = toolPath() else { return false }
        return ProcessProbe.run(
            tool, arguments(socketPath: socketPath, ["send-keys", "-t", pane, "-l", "--", text]),
            timeout: timeout) != nil
    }

    static func pressReturn(inPane pane: String, socketPath: String?) -> Bool {
        guard let tool = toolPath() else { return false }
        return ProcessProbe.run(
            tool, arguments(socketPath: socketPath, ["send-keys", "-t", pane, "Enter"]),
            timeout: timeout) != nil
    }
}
