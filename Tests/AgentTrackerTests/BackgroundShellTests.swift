import Foundation
import Testing

@testable import AgentTracker

struct BackgroundShellTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func shell(_ id: String, ageSeconds: TimeInterval?, description: String? = nil)
        -> BackgroundTask
    {
        BackgroundTask(
            id: id, type: "shell", description: description, command: "sleep 15",
            firstSeenAt: ageSeconds.map { now.addingTimeInterval(-$0) })
    }

    private func session(_ tasks: [BackgroundTask], seen: [String]? = nil) -> AgentSession {
        var session = AgentSession(sessionId: "s1", state: .needsYou)
        session.backgroundTasks = tasks
        session.seenBackgroundTaskIds = seen
        return session
    }

    @Test func theOldestShellPastTheThresholdIsTheStaleOne() {
        let stale = session([
            shell("young", ageSeconds: 60), shell("old", ageSeconds: 7200),
            shell("older", ageSeconds: 9000),
        ])
        .staleBackgroundTask(after: 1800, now: now)
        #expect(stale?.id == "older")
    }

    @Test func nothingIsStaleBelowTheThresholdOrWithTheCheckOff() {
        let young = session([shell("a", ageSeconds: 1799)])
        #expect(young.staleBackgroundTask(after: 1800, now: now) == nil)
        let old = session([shell("a", ageSeconds: 9000)])
        #expect(old.staleBackgroundTask(after: 0, now: now) == nil)
    }

    /// A dev server is flagged once. Marking it seen must hold for as long
    /// as it runs, not just until the next turn ends.
    @Test func aShellMarkedSeenIsNotFlaggedAgain() {
        let session = session([shell("dev", ageSeconds: 9000)], seen: ["dev"])
        #expect(session.staleBackgroundTask(after: 1800, now: now) == nil)
    }

    /// A hook that recorded the task but not when: no age, so no claim.
    @Test func aShellWithoutAFirstSightingIsNeverStale() {
        let session = session([shell("a", ageSeconds: nil)])
        #expect(session.staleBackgroundTask(after: 1800, now: now) == nil)
    }

    @Test func durationsReadTheWayTheRowWritesThem() {
        #expect(DurationText.describe(40) == "40s")
        #expect(DurationText.describe(12 * 60) == "12m")
        #expect(DurationText.describe(3 * 3600 + 22 * 60) == "3h 22m")
        #expect(DurationText.describe(2 * 3600) == "2h")
        #expect(DurationText.describe(26 * 3600) == "1d 2h")
        #expect(DurationText.describe(-5) == "0s")
    }

    /// The wrapper Claude Code runs a background command through, as observed
    /// on 2.1.245: the command sits inside `eval '…'` with the shell's own
    /// single-quote escaping.
    private let wrapper =
        "/bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null "
        + "|| true && eval 'until [ -f done ]; do sleep 15; done' < /dev/null "
        + "&& pwd -P >| /tmp/claude-0a4c-cwd"

    @Test func theCommandIsRecognisedInsideTheWrapper() {
        #expect(BackgroundShells.runs("until [ -f done ]; do sleep 15; done", arguments: wrapper))
        #expect(!BackgroundShells.runs("sleep 15", arguments: wrapper))
        #expect(!BackgroundShells.runs("", arguments: wrapper))
    }

    /// The reviewer's case on #128: with prefix matching for every command,
    /// `sleep 27` would have claimed a shell running `sleep 2700` and, as the
    /// only match, had it killed. A whole command must end where the wrapper
    /// closes its quote; only an excerpt the hook cut short is a prefix.
    @Test func aWholeCommandNeverMatchesALongerOne() {
        let longer = "/bin/zsh -c eval 'sleep 2700' < /dev/null"
        #expect(!BackgroundShells.runs("sleep 27", arguments: longer))
        #expect(BackgroundShells.runs("sleep 27", arguments: longer, truncated: true))
        #expect(!BackgroundShells.runs("until [ -f done ]", arguments: wrapper))
        #expect(BackgroundShells.runs("until [ -f done ]", arguments: wrapper, truncated: true))
    }

    @Test func aQuoteInTheCommandMatchesItsEscapedForm() {
        let arguments = #"/bin/zsh -c eval 'echo '\''hi'\''' < /dev/null"#
        #expect(BackgroundShells.runs("echo 'hi'", arguments: arguments))
    }

    /// Against the live process table: a child this test spawns is found
    /// under this process with its arguments intact.
    @Test func aChildOfThisProcessIsListedWithItsArguments() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 23"]
        try child.run()
        defer { child.terminate() }
        let listed = Self.childrenOnceListing(child.processIdentifier)
        #expect(listed.contains { $0.pid == child.processIdentifier })
        #expect(
            listed.first { $0.pid == child.processIdentifier }?.arguments.contains("sleep 23")
                == true)
    }

    /// The whole path: the shell Claude would have spawned, found by its
    /// command and ended, and a command nobody runs left alone.
    @Test func stoppingEndsTheShellRunningTheCommand() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-c", "eval 'sleep 27' < /dev/null"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        Self.childrenOnceListing(child.processIdentifier)
        let task = BackgroundTask(id: "b1", type: "shell", command: "sleep 27")
        let absent = BackgroundTask(id: "b2", type: "shell", command: "sleep 9999")
        #expect(BackgroundShells.stop(absent, ownerPid: Int(getpid())) == .notFound)
        #expect(BackgroundShells.stop(task, ownerPid: Int(getpid())) == .stopped)
        child.waitUntilExit()
        #expect(!child.isRunning)
    }

    /// `Process.run()` returns when the spawn succeeded, which is a moment
    /// before the child is visible to the `sysctl` walk `children(of:)` does —
    /// reading the table right away failed roughly one run in three. Poll until
    /// it lands, and give up quietly so a genuine absence still fails on the
    /// expectation it was about rather than here.
    @discardableResult private static func childrenOnceListing(_ pid: pid_t)
        -> [BackgroundShells.Candidate]
    {
        var listed: [BackgroundShells.Candidate] = []
        for _ in 0..<100 {
            listed = BackgroundShells.children(of: getpid())
            if listed.contains(where: { $0.pid == pid }) { break }
            usleep(20_000)
        }
        return listed
    }
}
