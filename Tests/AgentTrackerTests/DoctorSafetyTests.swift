import Foundation
import Testing

@testable import AgentTracker

/// Source-level guards on the diagnostic path, in the same spirit as
/// `DeliverySafetyTests` and for the same reason: the failure here is that
/// someone later adds a reasonable-looking call and every behavioural test
/// still passes.
///
/// A doctor that raises a permission dialog has done harm no report repays —
/// it is meant to be safe to run unprompted, including by an agent, on a
/// machine whose owner is not watching.
final class DoctorSafetyTests {
    private func code(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentTracker/\(file)"),
            encoding: .utf8)
        // Comments stripped: these files *name* the forbidden calls in order to
        // explain why they are forbidden, and that documentation must survive.
        return
            source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private var diagnosticFiles: [String] {
        ["Doctor.swift", "Diagnosis.swift", "RowAmbiguity.swift"]
    }

    /// Every call that can put a dialog on screen. Each was located in the
    /// source rather than recalled, and each has a non-prompting counterpart
    /// the doctor uses instead.
    @Test("the diagnostic never calls anything that can raise a permission dialog")
    func noPromptingCalls() throws {
        let forbidden = [
            "promptIfNeeded: true",
            "requestAuthorization",
            "AXIsProcessTrustedWithOptions",
            "TerminalFocuser.focus",
            "GhosttyScripting.surfaces",
            "GhosttyScripting.automationPermission",
            "SessionTarget.resolve",
            "UNUserNotificationCenter.current",
        ]
        for file in diagnosticFiles {
            let source = try code(file)
            for call in forbidden {
                #expect(!source.contains(call), "\(file) must not call \(call)")
            }
        }
    }

    /// A diagnostic that edits the machine it is describing is not a
    /// diagnostic. `.reload(` is included because `SessionStore.reload()`
    /// deletes state files, which would change the very stale-session count the
    /// doctor reports — and it is spelled as the call site rather than as
    /// `SessionStore.shared.reload`, which the first version forbade and which
    /// does not exist, so it could never have matched anything.
    @Test("the diagnostic never writes anything")
    func noWrites() throws {
        let forbidden = [
            "runInstaller",
            "refreshInstalledHook",
            "removeItem",
            "createFile",
            "createDirectory",
            ".write(to:",
            ".reload(",
        ]
        for file in diagnosticFiles {
            let source = try code(file)
            for call in forbidden {
                #expect(!source.contains(call), "\(file) must not call \(call)")
            }
        }
    }

    /// The guard above is only meaningful if the strings it forbids are the
    /// ones that actually appear in this codebase. If `GhosttyScripting` ever
    /// renames its permission call, the forbidden list silently stops matching
    /// anything and the test keeps passing — so anchor it to the real symbol.
    @Test("the forbidden calls are real symbols, so the guard cannot pass vacuously")
    func forbiddenCallsExistSomewhere() throws {
        let anchors = [
            ("GhosttyScripting.swift", "promptIfNeeded"),
            ("GhosttyScripting.swift", "automationPermission"),
            ("Notifications.swift", "requestAuthorization"),
            ("TerminalFocuser.swift", "AXIsProcessTrustedWithOptions"),
            ("HookSetup.swift", "refreshInstalledHook"),
        ]
        for (file, symbol) in anchors {
            let source = try code(file)
            #expect(
                source.contains(symbol), "\(symbol) no longer exists in \(file) — update the guard")
        }
    }
}
