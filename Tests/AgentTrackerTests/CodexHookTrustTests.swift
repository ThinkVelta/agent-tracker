import Foundation
import Testing

@testable import AgentTracker

private let hooksPath = "/Users/dev/.codex/hooks.json"
private let ours = "/Users/dev/.agent-tracker/bin/agent-tracker-hook.py codex-hook"
private let theirs = "/usr/bin/env python3 /Users/dev/.codex/hooks/their-guard.py"

private func hooksDocument(_ events: [(String, [[String]])]) -> Data {
    var hooks: [String: Any] = [:]
    for (event, groups) in events {
        hooks[event] = groups.map { commands in
            ["matcher": "*", "hooks": commands.map { ["type": "command", "command": $0] }]
        }
    }
    // swiftlint:disable:next force_try — a literal built two lines above
    return try! JSONSerialization.data(withJSONObject: ["hooks": hooks])
}

private func trust(_ keys: [String]) -> String {
    keys.map { "[hooks.state.\"\($0)\"]\ntrusted_hash = \"sha256:abc\"\n" }.joined()
}

@Suite("CodexHookTrust")
struct CodexHookTrustTests {
    @Test("event names become the snake_case Codex writes into its trust keys")
    func eventNamesAreConverted() {
        #expect(CodexHookTrust.trustKeyEvent("Stop") == "stop")
        #expect(CodexHookTrust.trustKeyEvent("PreToolUse") == "pre_tool_use")
        #expect(CodexHookTrust.trustKeyEvent("PermissionRequest") == "permission_request")
        #expect(CodexHookTrust.trustKeyEvent("UserPromptSubmit") == "user_prompt_submit")
        #expect(CodexHookTrust.trustKeyEvent("SessionEnd") == "session_end")
    }

    @Test("a freshly registered hook with no trust at all is waiting")
    func freshInstallAwaitsTrust() {
        #expect(
            CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("Stop", [[ours]])]),
                configTOML: "model = \"gpt-5\"\n",
                hooksPath: hooksPath))
    }

    @Test("a hook with its own trust record is not waiting")
    func trustedHookIsSettled() {
        #expect(
            !CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("Stop", [[ours]])]),
                configTOML: trust(["\(hooksPath):stop:0:0"]),
                hooksPath: hooksPath))
    }

    /// The case a file-level probe gets wrong, and the one that occurs in real
    /// life: hooks already trusted in the same file, ours appended beside them.
    @Test("somebody else's trusted hook does not vouch for ours")
    func otherTrustedHooksDoNotCount() {
        #expect(
            CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("PreToolUse", [[theirs], [ours]])]),
                configTOML: trust(["\(hooksPath):pre_tool_use:0:0"]),
                hooksPath: hooksPath))
    }

    @Test("every one of ours has to be trusted, not just the first")
    func oneUntrustedHookIsEnough() {
        let document = hooksDocument([("Stop", [[ours]]), ("PermissionRequest", [[ours]])])
        #expect(
            CodexHookTrust.awaitsTrust(
                hooksJSON: document,
                configTOML: trust(["\(hooksPath):stop:0:0"]),
                hooksPath: hooksPath))
        #expect(
            !CodexHookTrust.awaitsTrust(
                hooksJSON: document,
                configTOML: trust([
                    "\(hooksPath):stop:0:0", "\(hooksPath):permission_request:0:0",
                ]),
                hooksPath: hooksPath))
    }

    @Test("a trust record for a different hooks file vouches for nothing")
    func trustIsScopedToItsFile() {
        #expect(
            CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("Stop", [[ours]])]),
                configTOML: trust(["/Users/dev/proj/.codex/hooks.json:stop:0:0"]),
                hooksPath: hooksPath))
    }

    @Test("the index within a group is part of the key")
    func indexWithinAGroupMatters() {
        #expect(
            CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("Stop", [[theirs, ours]])]),
                configTOML: trust(["\(hooksPath):stop:0:0"]),
                hooksPath: hooksPath))
        #expect(
            !CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("Stop", [[theirs, ours]])]),
                configTOML: trust(["\(hooksPath):stop:0:1"]),
                hooksPath: hooksPath))
    }

    @Test("a file with none of our hooks is not waiting on us")
    func noHooksOfOursIsNotWaiting() {
        #expect(
            !CodexHookTrust.awaitsTrust(
                hooksJSON: hooksDocument([("Stop", [[theirs]])]),
                configTOML: "",
                hooksPath: hooksPath))
    }

    @Test("unreadable JSON stays silent rather than nagging about nothing")
    func malformedJSONIsNotAnAlarm() {
        #expect(
            !CodexHookTrust.awaitsTrust(
                hooksJSON: Data("not json".utf8), configTOML: "", hooksPath: hooksPath))
    }
}
