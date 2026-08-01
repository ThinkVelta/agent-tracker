import Foundation

/// Sticky registry of Codex subagent thread ids.
///
/// Codex multi-agent runs give every subagent its own rollout file AND fire
/// the `notify` hook for every subagent turn — with no discriminator in the
/// notify payload (verified against codex 0.146: `thread-id`, `turn-id`,
/// `cwd`, `client`, `input-messages`, `last-assistant-message` and nothing
/// else). The scanner's live thread→session map dedupes those notify rows
/// only while the subagent's rollout is still tracked; subagents finish and
/// close their rollout quickly, the tracker gets pruned, and the notify row
/// would resurface as a phantom "needs you" session that lives as long as the
/// root codex process. This ledger keeps every thread id ever identified as a
/// subagent so the dedupe outlives the tracker.
///
/// Confined to the scan worker's serial queue — not thread-safe on its own.
final class CodexSubagentLedger {
    private(set) var threadIds: Set<String> = []
    private var harvestedPaths: Set<String> = []

    /// Records a parsed session meta; sticky — ids survive tracker pruning.
    /// `fileThreadId` (the rollout filename uuid) is the authoritative notify
    /// join key; the meta's own `threadId` is recorded too because resume
    /// metas repoint it at fork-ancestor threads, which are subagents as well.
    func record(_ meta: CodexSessionMeta, fileThreadId: String? = nil) {
        guard meta.isSubagent else { return }
        if let threadId = meta.threadId { threadIds.insert(threadId) }
        if let fileThreadId { threadIds.insert(fileThreadId) }
    }

    /// Identifies a rollout the scanner won't bootstrap (already dead at
    /// startup) from its leading session_meta line alone. Each path is read at
    /// most once per process lifetime.
    func harvest(path: String) {
        guard harvestedPaths.insert(path).inserted else { return }
        guard let meta = CodexRolloutParser.firstSessionMeta(atPath: path) else { return }
        record(meta, fileThreadId: CodexRolloutParser.threadId(fromRolloutFilename: path))
    }
}
