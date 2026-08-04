import AppKit

/// Works out which terminal application owns a session's window.
///
/// Separate from `TerminalFocuser` because it answers a different question:
/// the focuser finds a *window* inside an app, this finds the *app*. It is also
/// the layer a wrong answer is most expensive in — raising the wrong app merely
/// annoys, but anything that later writes into a pane inherits whatever this
/// concludes.
enum TerminalIdentification {
    /// Terminals that name themselves in `TERM_PROGRAM`.
    ///
    /// kitty is deliberately absent: it sets no `TERM_PROGRAM` at all, so the
    /// entry that used to live here could never be reached — it identifies
    /// itself through `TERM` instead (see `bundleIDsByTerm`). tmux is absent for
    /// the opposite reason: it DOES set `TERM_PROGRAM`, to `tmux`,
    /// unconditionally overwriting whatever the host terminal wrote, so the one
    /// thing it reliably tells us is that this variable is now useless.
    private static let bundleIDsByTermProgram: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "wezterm": "com.github.wez.wezterm",
    ]

    /// Terminals that identify themselves through `TERM` instead.
    private static let bundleIDsByTerm: [String: String] = [
        "xterm-kitty": "net.kovidgoyal.kitty"
    ]

    /// Every terminal app this knows, in a stable order.
    static let allTerminalBundleIDs: [String] =
        (Array(bundleIDsByTermProgram.values) + Array(bundleIDsByTerm.values)).sorted()

    /// Lowercased, for "is the frontmost app a terminal?" checks
    /// (`TerminalFocusObserver`).
    static let knownTerminalBundleIDs: Set<String> = Set(
        allTerminalBundleIDs.map { $0.lowercased() })

    /// What the environment a session was launched in says about its terminal.
    enum Hint: Equatable {
        case app(String)
        /// Running under tmux or screen: the multiplexer's server is reparented
        /// away from whichever terminal started it, so neither the environment
        /// nor the process tree leads back to the host window.
        case multiplexer
        case unknown
    }

    /// Pure, so the priority order is testable without a live process tree.
    static func hint(termProgram: String?, term: String?, tmux: String?) -> Hint {
        let program = termProgram?.lowercased()
        let terminalType = term?.lowercased()
        // `TMUX` outranks everything, including a `TERM`/`TERM_PROGRAM` that
        // names a real terminal. A pane inherits the tmux SERVER's environment,
        // snapshotted from whichever client happened to create it — so those
        // values can name a terminal that is not the one currently attached, or
        // one that has since quit. Being inside tmux is the fact; what the
        // inherited variables say about a host is not.
        if let tmux, !tmux.isEmpty { return .multiplexer }
        // Then tmux's own overwrite of TERM_PROGRAM, checked before the lookup
        // rather than after: a hit means the host is unknowable, not that we
        // should keep reading the value it replaced.
        if program == "tmux" || program == "screen" { return .multiplexer }
        if let program, let bundleID = bundleIDsByTermProgram[program] { return .app(bundleID) }
        if let terminalType, let bundleID = bundleIDsByTerm[terminalType] { return .app(bundleID) }
        if let terminalType, terminalType.hasPrefix("screen") || terminalType.hasPrefix("tmux") {
            return .multiplexer
        }
        return .unknown
    }

    /// The owning app, most trustworthy source first.
    ///
    /// The last resort deliberately stops at "exactly one candidate". It used to
    /// take the first known terminal sorted by bundle id, which is right by
    /// accident when one terminal is running and a coin flip when two are — and
    /// every tmux session landed there, because tmux overwrites the
    /// `TERM_PROGRAM` the lookup depends on.
    static func app(for session: AgentSession) -> NSRunningApplication? {
        // 1. The agent's own ancestry. Authoritative where it works: no
        //    environment variable to be overwritten, and a nested shell or an
        //    `ssh` inside the pane cannot fake it.
        if let pid = session.pid, pid > 0, let app = owningTerminalApp(ofPid: pid_t(pid)) {
            log("resolved from the process tree of pid \(pid)")
            return app
        }

        // 2. What the hook captured from the session's environment.
        switch hint(
            termProgram: session.termProgram, term: session.terminal?.term,
            tmux: session.terminal?.tmux)
        {
        case .app(let bundleID):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first
            {
                return app
            }
            log("session reports \(bundleID), which is not running")
        case .multiplexer:
            log("session runs under a terminal multiplexer — its host window is not derivable")
        case .unknown:
            break
        }

        // 3. No signal, so guess only when there is nothing to get wrong.
        let running = allTerminalBundleIDs.compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
        if running.count == 1 { return running.first }
        if running.count > 1 {
            log(
                "\(running.count) terminal apps are running and none is identifiable as this "
                    + "session's — refusing to guess")
        }
        return nil
    }

    /// Walks a process's ancestry for the GUI terminal that owns it, e.g.
    /// `claude → zsh → login → Ghostty`. nil under a multiplexer, whose server
    /// is not an ancestor of the pane's processes.
    static func owningTerminalApp(ofPid pid: pid_t) -> NSRunningApplication? {
        var current = pid
        // Deep enough for login → shell → wrapper → agent with room to spare,
        // and bounded so a reparented orphan cannot spin.
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current),
                let bundleID = app.bundleIdentifier?.lowercased(),
                knownTerminalBundleIDs.contains(bundleID)
            {
                return app
            }
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// One `sysctl` per level rather than forking `ps` per resolve.
    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    private static func log(_ message: String) {
        DebugLog.log("[terminal] \(message)")
    }
}
