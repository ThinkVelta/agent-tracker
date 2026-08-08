import Foundation
import Testing

@testable import AgentTracker

private func row(
    _ sessionId: String,
    state: SessionState = .needsYou,
    reason: String? = nil,
    origin: String? = nil,
    termProgram: String? = nil,
    cwd: String? = nil,
    lastEvent: String? = nil,
    fileURL: URL? = nil
) -> AgentSession {
    var session = AgentSession(
        provider: "codex", sessionId: sessionId, state: state, reason: reason)
    session.origin = origin
    session.termProgram = termProgram
    session.cwd = cwd
    session.lastEvent = lastEvent
    session.fileURL = fileURL
    return session
}

private func scannerRow(
    _ sessionId: String,
    state: SessionState = .running,
    reason: String? = "Working…",
    cwd: String? = "/Users/dev/proj",
    pid: Int? = 4242
) -> AgentSession {
    var session = AgentSession(
        provider: "codex", sessionId: sessionId, state: state, reason: reason)
    session.cwd = cwd
    session.pid = pid
    return session
}

@Suite("CodexMerge")
struct CodexMergeTests {
    @Test("a hook's approval prompt survives the scanner calling the session busy")
    func hookApprovalOutranksScanner() {
        let hook = row(
            "s1", state: .needsYou, reason: "Approve Bash?", origin: "hook",
            lastEvent: "PermissionRequest")
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1", state: .running)],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows.count == 1)
        #expect(resolution.scannerRows[0].state == .needsYou)
        #expect(resolution.scannerRows[0].reason == "Approve Bash?")
        #expect(resolution.scannerRows[0].lastEvent == "PermissionRequest")
        #expect(resolution.fallbackRows.isEmpty)
    }

    @Test("a hook that says the session is working outranks the scanner too")
    func hookRunningOutranksScanner() {
        let hook = row("s1", state: .running, reason: "Using Bash", origin: "hook")
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1", state: .needsYou, reason: "Turn complete")],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows[0].state == .running)
        #expect(resolution.scannerRows[0].reason == "Using Bash")
    }

    @Test("a legacy notify row still only donates its terminal, never its state")
    func notifyRowDoesNotOverrideState() {
        let notify = row(
            "thread-a", state: .needsYou, reason: "Turn complete", origin: "notify",
            termProgram: "ghostty")
        let resolution = CodexMerge.resolve(
            fileRows: [notify],
            scanned: [scannerRow("s1", state: .running)],
            threadMap: ["thread-a": "s1", "s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows.count == 1)
        #expect(resolution.scannerRows[0].state == .running)
        #expect(resolution.scannerRows[0].termProgram == "ghostty")
        #expect(resolution.fallbackRows.isEmpty)
    }

    @Test("a row written before origin existed is treated as legacy, not as a hook")
    func rowWithoutOriginIsNotTrusted() {
        let legacy = row("thread-a", state: .needsYou, reason: "Turn complete", origin: nil)
        let resolution = CodexMerge.resolve(
            fileRows: [legacy],
            scanned: [scannerRow("s1", state: .running)],
            threadMap: ["thread-a": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows[0].state == .running)
    }

    @Test("a hook row for a session the scanner has not published stays visible")
    func unmatchedHookRowSurvives() {
        let hook = row("s9", state: .needsYou, reason: "Approve Bash?", origin: "hook")
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1")],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.fallbackRows.count == 1)
        #expect(resolution.fallbackRows[0].sessionId == "s9")
        #expect(resolution.scannerRows[0].state == .running)
    }

    @Test("with nothing scanned at all, every row is its own fallback")
    func nothingScannedKeepsEveryRow() {
        let resolution = CodexMerge.resolve(
            fileRows: [row("s1", origin: "hook"), row("s2", origin: "notify")],
            scanned: [],
            threadMap: [:],
            subagentThreads: [])

        #expect(resolution.fallbackRows.count == 2)
        #expect(resolution.scannerRows.isEmpty)
        #expect(resolution.filesToDelete.isEmpty)
    }

    @Test("a subagent's row is deleted, not merged and not shown")
    func subagentRowsAreDeleted() {
        let url = URL(fileURLWithPath: "/tmp/agent-tracker-test/codex-sub.json")
        let resolution = CodexMerge.resolve(
            fileRows: [row("sub-1", origin: "hook", fileURL: url), row("s1", origin: "hook")],
            scanned: [scannerRow("s1")],
            threadMap: ["s1": "s1"],
            subagentThreads: ["sub-1"])

        #expect(resolution.filesToDelete == [url])
        #expect(resolution.fallbackRows.isEmpty)
        #expect(resolution.scannerRows.count == 1)
    }

    @Test("the scanner keeps the pid it holds the rollout by")
    func scannerPidWins() {
        var hook = row("s1", origin: "hook")
        hook.pid = 999
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1", pid: 4242)],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows[0].pid == 4242)
    }

    @Test("a hook fills in the pid when the scanner has none")
    func hookPidFillsIn() {
        var hook = row("s1", origin: "hook")
        hook.pid = 999
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1", pid: nil)],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows[0].pid == 999)
    }

    /// The scanner has no permission mode to offer, and an absent one is treated
    /// as permitted — so losing the hook's would quietly disarm that gate.
    @Test("the hook's permission mode reaches the row the scheduler reads")
    func permissionModeIsCarried() {
        var hook = row("s1", origin: "hook")
        hook.permissionMode = "bypassPermissions"
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1")],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows[0].permissionMode == "bypassPermissions")
    }

    @Test("a hook without a working directory does not blank the scanner's")
    func hookDoesNotBlankScannerFields() {
        let hook = row("s1", origin: "hook", cwd: nil)
        let resolution = CodexMerge.resolve(
            fileRows: [hook],
            scanned: [scannerRow("s1", cwd: "/Users/dev/proj")],
            threadMap: ["s1": "s1"],
            subagentThreads: [])

        #expect(resolution.scannerRows[0].cwd == "/Users/dev/proj")
    }
}
