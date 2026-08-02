import Foundation

/// Folds Claude Code's session registry into the hook-written session rows.
/// Pure so the precedence rules — which source wins, and when a registry
/// status may override a state a hook reported — are testable without a store.
enum RegistryEnrichment {
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
            enriched.reason = enriched.state == .running ? "Working…" : "Idle at prompt"
        }
        return enriched
    }

    /// The registry carries Claude's own busy/idle signal, refreshed every few
    /// seconds without any hook firing. That closes a real gap: Claude Code has
    /// no interrupt hook, so a session the user escaped out of stays green
    /// "running" until its next event, which may never come.
    ///
    /// Two corrections, both only on evidence newer than the hook's:
    ///
    /// - A stale `running` row is demoted. Claude Code has no interrupt hook,
    ///   so a session the user escaped out of stays green until its next event,
    ///   which may never come.
    /// - A `Stop` that turned out not to end the work is promoted back to
    ///   running. `Stop` fires when the assistant's turn ends, but a turn that
    ///   left background shells running is resumed by the harness when they
    ///   finish — so the row sat red for as long as the shells took (46 minutes,
    ///   reported) while nothing was wanted from the user.
    ///
    /// Only a `Stop`-derived red is eligible. A `Notification` red is a
    /// permission prompt: the user genuinely is needed, the registry knows
    /// nothing about it, and clearing it would hide the one thing this app
    /// exists to show. An unrecognized status expresses no opinion.
    ///
    /// Nothing is written back — the display state is re-derived each reload —
    /// so when Claude does settle, the row returns to red by itself.
    static func resolvedState(
        for session: AgentSession,
        entry: ClaudeSessionRegistry.Entry
    ) -> SessionState {
        guard let registryUpdate = entry.statusUpdatedAt else { return session.state }
        let lastEvent = session.stateChangedAt ?? session.updatedAt ?? .distantPast
        // The hook is the more precise signal when it is fresher; letting a
        // lagging file stomp a just-arrived event would make the list flicker.
        guard registryUpdate > lastEvent else { return session.state }

        switch session.state {
        case .running:
            guard let isBusy = entry.status.isBusy, !isBusy else { return session.state }
            return .idle
        case .needsYou:
            guard session.lastEvent == "Stop", entry.status == .busy else { return session.state }
            return .running
        default:
            return session.state
        }
    }
}
