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
            enriched.reason = "Idle at prompt"
        }
        return enriched
    }

    /// The registry carries Claude's own busy/idle signal, refreshed every few
    /// seconds without any hook firing. That closes a real gap: Claude Code has
    /// no interrupt hook, so a session the user escaped out of stays green
    /// "running" until its next event, which may never come.
    ///
    /// It may only ever *demote* a stale `running` row, and only on evidence:
    ///
    /// - `needsYou` is untouchable. It is a user-facing state the registry
    ///   knows nothing about, and clearing it would hide a session that is
    ///   waiting on the user — the one thing this app exists to show.
    /// - A hook event newer than the registry's own timestamp wins. The hook
    ///   is the more precise signal when it is fresher; letting a lagging file
    ///   stomp a just-arrived event would make the list flicker.
    /// - An unrecognized status expresses no opinion.
    static func resolvedState(
        for session: AgentSession,
        entry: ClaudeSessionRegistry.Entry
    ) -> SessionState {
        guard session.state == .running,
            let isBusy = entry.status.isBusy, !isBusy,
            let registryUpdate = entry.statusUpdatedAt
        else { return session.state }
        let lastEvent = session.stateChangedAt ?? session.updatedAt ?? .distantPast
        guard registryUpdate > lastEvent else { return session.state }
        return .idle
    }
}
