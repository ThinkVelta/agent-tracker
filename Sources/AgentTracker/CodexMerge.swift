import Foundation

/// Reconciles the two things that describe a Codex session.
///
/// The app sees Codex twice. `CodexSessionScanner` derives state by reading
/// rollout files after the fact; the hook script pushes state as it happens.
/// They overlap, disagree, and key themselves differently, so who wins has to
/// be decided in one place rather than inline in `SessionStore.rebuild`.
///
/// The rule is that **a native hook outranks the scanner**. Not a preference:
/// the rollout carries no line meaning "an approval prompt is open", so the
/// scanner reads a waiting session as `.running` and would paint over the one
/// state the user most needs to see. A hook watches the whole lifecycle —
/// start, prompt, tool, approval, stop, end — so where it has spoken there is
/// nothing left for the scanner to add.
///
/// Deliberately *not* "whichever is newer". A rollout keeps growing while a
/// session sits at an approval prompt, so its file activity is always the more
/// recent of the two exactly when the hook is the one that is right.
///
/// The legacy `notify` callback does not get this treatment. It fires once, at
/// turn end, and reports a thread id that may not be the session's — which is
/// the whole reason `threadMap` exists.
enum CodexMerge {
    struct Resolution {
        /// Scanner-derived sessions, with hook state applied where a hook has
        /// spoken. The caller still overlays acknowledgement on these.
        var scannerRows: [AgentSession] = []
        /// State-file rows describing sessions the scanner does not know about.
        /// Shown as-is: the scanner may simply not have caught up, and hiding
        /// them would lose the session entirely.
        var fallbackRows: [AgentSession] = []
        /// State files that should not exist. Deleting rather than hiding them
        /// is deliberate — see `subagentThreads` below.
        var filesToDelete: [URL] = []
    }

    /// - Parameters:
    ///   - fileRows: every state-file row with provider `codex`.
    ///   - scanned: what the rollout scanner currently sees.
    ///   - threadMap: thread id *and* session id → the session the scanner
    ///     published, so a row keyed either way resolves to the same session.
    ///   - subagentThreads: threads known to be internal fan-out. Their rows are
    ///     deleted rather than hidden: the dedupe below only holds while the
    ///     subagent's rollout is still tracked, and afterwards the file
    ///     resurfaces as a phantom "needs you" row for as long as the root
    ///     codex process lives — one per completed subagent.
    static func resolve(
        fileRows: [AgentSession],
        scanned: [AgentSession],
        threadMap: [String: String],
        subagentThreads: Set<String>
    ) -> Resolution {
        var resolution = Resolution()
        var hookBySession: [String: AgentSession] = [:]
        var termProgramBySession: [String: String] = [:]

        for row in fileRows {
            if subagentThreads.contains(row.sessionId) {
                if let fileURL = row.fileURL { resolution.filesToDelete.append(fileURL) }
                continue
            }
            // No cwd-based fallback matching on purpose: two sessions sharing a
            // working directory are common, and guessing would hide one of them.
            guard !scanned.isEmpty, let target = threadMap[row.sessionId] else {
                resolution.fallbackRows.append(row)
                continue
            }
            if let termProgram = row.termProgram {
                termProgramBySession[target] = termProgram
            }
            // Last writer wins if a session somehow has two hook rows — it
            // cannot today, since the file is named for the session id.
            if row.origin == "hook" {
                hookBySession[target] = row
            }
        }

        resolution.scannerRows = scanned.map { session in
            var session = session
            if session.termProgram == nil {
                session.termProgram = termProgramBySession[session.sessionId]
            }
            guard let hook = hookBySession[session.sessionId] else { return session }
            session.state = hook.state
            session.reason = hook.reason
            session.lastEvent = hook.lastEvent
            session.stateChangedAt = hook.stateChangedAt
            session.updatedAt = hook.updatedAt ?? session.updatedAt
            session.transcriptPath = hook.transcriptPath ?? session.transcriptPath
            session.terminal = hook.terminal ?? session.terminal
            session.cwd = hook.cwd ?? session.cwd
            session.lastMessage = hook.lastMessage ?? session.lastMessage
            session.origin = hook.origin
            // pid stays the scanner's: it comes from whichever process holds the
            // rollout open, which is what the store's liveness prune asks about.
            session.pid = session.pid ?? hook.pid
            return session
        }
        return resolution
    }
}
