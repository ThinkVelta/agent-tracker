import Foundation

/// Whether Codex has been told it may run *our* hooks.
///
/// Codex runs a hook only after the user accepts its review prompt, and records
/// that in `config.toml` as
/// `[hooks.state."<hooks.json path>:<snake_case event>:<group>:<index>"]`.
/// Registration and trust are therefore separate facts, and only the second one
/// means the hook will fire — `codex exec` skips untrusted hooks silently.
///
/// Resolved per hook entry rather than per file, because the coarse version is
/// wrong in the common case: a user who already had trusted hooks in that file
/// has `hooks.state` keys for it, so a file-level probe reports "trusted" the
/// moment ours are appended untrusted beside them.
enum CodexHookTrust {
    /// The trust-key spelling of a hook event name: Codex writes `PreToolUse`
    /// as `pre_tool_use`. Derived rather than looked up, so an event added to
    /// the installer later needs no change here.
    static func trustKeyEvent(_ event: String) -> String {
        var out = ""
        for character in event {
            if character.isUppercase, !out.isEmpty { out.append("_") }
            out.append(Character(character.lowercased()))
        }
        return out
    }

    /// True when at least one agent-tracker hook in `hooksJSON` has no matching
    /// trust record in `configTOML`.
    ///
    /// Unreadable or unexpected JSON returns false — quiet, not waiting. A file
    /// we cannot parse does not tell us our hooks are untrusted; it does not
    /// even tell us they are *there*, so speaking up would mean telling someone
    /// with no Codex hooks at all to go and trust them.
    static func awaitsTrust(hooksJSON: Data, configTOML: String, hooksPath: String) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: hooksJSON) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return false }

        for (event, groups) in hooks {
            guard let groups = groups as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                for (entryIndex, entry) in entries.enumerated() {
                    let command = entry["command"] as? String ?? ""
                    guard command.contains("agent-tracker-hook") else { continue }
                    let key =
                        "\(hooksPath):\(trustKeyEvent(event)):\(groupIndex):\(entryIndex)"
                    if !configTOML.contains("hooks.state.\"\(key)\"") { return true }
                }
            }
        }
        // Either every hook of ours is trusted, or we have none registered.
        return false
    }
}
