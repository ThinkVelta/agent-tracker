import Foundation

/// Folds Claude Code's session registry into the hook-written session rows.
/// Pure so the precedence rules — which source wins, and when a registry
/// status may override a state a hook reported — are testable without a store.
enum RegistryEnrichment {
    /// Claude's "the assistant's turn ended" event, as `lastEvent` records it.
    ///
    /// Named because the string is a contract with
    /// `integrations/agent-tracker-hook.py`, which writes it verbatim from
    /// `hook_event_name` and is the only reason a row is red here at all.
    /// Nothing but this pairing links the two files.
    static let turnEndedEvent = "Stop"

    /// - Parameters:
    ///   - session: a row loaded from `~/.agent-tracker/sessions`.
    ///   - entry: the registry entry with the same `sessionId`, if any.
    static func apply(
        to session: AgentSession,
        entry: ClaudeSessionRegistry.Entry?
    ) -> AgentSession {
        // Provider-scoped: the registry only knows about Claude Code.
        guard session.provider == "claude-code", let entry else { return session }
        var enriched = session
        enriched.registryName = entry.name
        enriched.registryCwd = entry.cwd
        enriched.state = resolvedState(for: session, entry: entry)
        if enriched.state != session.state {
            enriched.reason = reason(for: enriched.state, entry: entry)
        }
        return enriched
    }

    /// Why the row disagrees with its hook event. A corrected row that kept the
    /// hook's wording would read "Turn complete" while showing green.
    private static func reason(
        for state: SessionState,
        entry: ClaudeSessionRegistry.Entry
    ) -> String {
        switch state {
        case .running:
            return entry.status == .shell ? "Background work still running" : "Working…"
        case .needsYou:
            // Claude's own phrasing, which is more specific than anything that
            // could be inferred here ("input needed", "sandbox request", …).
            return entry.waitingFor.map { "Waiting on you — \($0)" } ?? "Needs your attention"
        case .idle:
            return "Idle at prompt"
        }
    }

    /// The hooks report events; the registry reports what Claude is *doing*.
    /// Three corrections come out of the difference.
    ///
    /// - **A `Stop` that did not end the work is promoted back to running.**
    ///   `Stop` fires when the assistant's turn ends, but a turn that left a
    ///   background shell running is resumed by the harness when it finishes,
    ///   and one that delegated to subagents or teammates is not over either.
    ///   Claude says so itself: `shell` for the first, `busy` for the second.
    /// - **A dialog makes a row red.** `waiting` is only ever written while
    ///   something is blocking on a human, so a green row becomes red rather
    ///   than being demoted to a grey "nothing pending".
    /// - **A stale `running` row is demoted.** Claude Code has no interrupt
    ///   hook, so a session the user escaped out of stays green until its next
    ///   event, which may never come.
    ///
    /// Only a `Stop`-derived red may be promoted. A `Notification` red is a
    /// permission prompt: the user genuinely is needed, and clearing it would
    /// hide the one thing this app exists to show. An unrecognized status
    /// expresses no opinion, and an acknowledged (idle) row is left alone so
    /// the registry can never undo a click.
    ///
    /// Nothing is written back — the display state is re-derived each reload —
    /// so when Claude does settle, the row returns to red by itself.
    static func resolvedState(
        for session: AgentSession,
        entry: ClaudeSessionRegistry.Entry
    ) -> SessionState {
        switch session.state {
        case .needsYou:
            // Deliberately NOT gated on the timestamp being newer than the
            // hook's. The file is written on change, so its status is current
            // at any age, and the write trails the hook by ~600ms — meaning at
            // every turn end the freshest thing on disk still describes the
            // turn that just ended. Requiring a newer timestamp here would
            // therefore reject exactly the moment this correction exists for,
            // and show a red blink at the end of every turn. Erring toward
            // "still working" costs a red that arrives ~600ms late; erring the
            // other way is the false red the whole rule is here to prevent.
            guard session.lastEvent == turnEndedEvent, entry.status.isWorking == true
            else { return session.state }
            return .running
        case .running:
            // Both corrections here compare against the row's own event, but
            // they treat a missing timestamp oppositely, which is the whole
            // difference between them.
            let hookEvent = session.stateChangedAt ?? session.updatedAt ?? .distantPast
            if entry.status == .waiting {
                // A dialog is written AFTER the event that triggered it, so an
                // undated `waiting` is still evidence. An OLDER one has been
                // overtaken: tool calls cannot run while something blocks on a
                // human, so a hook event that postdates it means the dialog is
                // gone. `waiting` also covers any local dialog — `/config` over
                // a session whose background work resumes behind it.
                guard let registryUpdate = entry.statusUpdatedAt, registryUpdate <= hookEvent
                else { return .needsYou }
                return session.state
            }
            // A demotion DOES need the newer timestamp: "idle" is only evidence
            // of an abandoned turn if it was written after the event that made
            // the row green, or every tool call would race its own idle.
            guard let registryUpdate = entry.statusUpdatedAt, registryUpdate > hookEvent,
                let isWorking = entry.status.isWorking, !isWorking
            else { return session.state }
            return .idle
        default:
            return session.state
        }
    }
}
