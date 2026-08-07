import Darwin
import Foundation
import Testing

@testable import AgentTracker

/// Reads the real kernel, against this very process — no fixtures, because the
/// thing under test is whether the struct this build expects matches the one the
/// kernel fills in.
final class ProcessIdentityTests {
    @Test func readsThisProcess() throws {
        let identity = try #require(ProcessIdentity.read(pid: getpid()))
        #expect(identity.pid == getpid())
        #expect(identity.pgid == getpgrp())
        #expect(identity.comm.isEmpty == false)

        // Started in the past, and not absurdly so — a garbage struct read tends
        // to land in 1970 or the far future.
        let age = Date().timeIntervalSince(identity.startedAt)
        #expect(age > 0)
        #expect(age < 24 * 3600)
    }

    @Test func aDeadOrImpossiblePidReadsAsNothing() {
        #expect(ProcessIdentity.read(pid: 0) == nil)
        #expect(ProcessIdentity.read(pid: -1) == nil)
        // Above the pid ceiling, so it cannot be in use.
        #expect(ProcessIdentity.read(pid: 0x7FFF_FFFF) == nil)
    }

    /// Another user's process is unreadable, and reads as nothing rather than as
    /// a half-filled struct. Measured: `proc_pidinfo(1, …)` returns 0 bytes with
    /// EPERM, while this process and its parent return all 136. That boundary
    /// costs the feature nothing — the agents it schedules are the user's own —
    /// but it must not be mistaken for "no such process".
    @Test func aProcessOwnedBySomeoneElseIsSimplyUnreadable() {
        #expect(ProcessIdentity.read(pid: 1) == nil)
    }

    /// A sibling process, which is what delivery actually reads: the agent is
    /// never the app itself.
    @Test func aProcessOtherThanThisOneCanBeRead() throws {
        let parent = try #require(ProcessIdentity.read(pid: getppid()))
        #expect(parent.pid == getppid())
        #expect(parent.comm.isEmpty == false)
        #expect(parent.startedAt < Date())
    }

    /// pid alone is not identity: pids are recycled, and this feature can wait
    /// twelve hours between arming and firing. The start time is what makes the
    /// pair unique.
    @Test func samePidWithADifferentStartTimeIsADifferentProcess() throws {
        let original = try #require(ProcessIdentity.read(pid: getpid()))

        var recycled = original
        recycled.startedAt = original.startedAt.addingTimeInterval(60)
        #expect(original.isSameProcess(as: recycled) == false)

        var other = original
        other.pid = original.pid + 1
        #expect(original.isSameProcess(as: other) == false)

        // Re-reading the same live process must still match, or every fire would
        // abort on its own identity check.
        let again = try #require(ProcessIdentity.read(pid: getpid()))
        #expect(original.isSameProcess(as: again))
    }

    /// Sub-millisecond drift is a rounding artifact of converting the kernel's
    /// microseconds, not a different process.
    @Test func aRoundingDifferenceIsNotADifferentProcess() throws {
        let original = try #require(ProcessIdentity.read(pid: getpid()))
        var rounded = original
        rounded.startedAt = original.startedAt.addingTimeInterval(0.0001)
        #expect(original.isSameProcess(as: rounded))
    }

    /// The test runner is not in the foreground of a terminal, so this asserts the
    /// shape rather than a specific verdict — `ownsTerminal` must agree with the
    /// two numbers it is derived from, whatever they are here.
    @Test func owningTheTerminalIsExactlyPgidMatchingTpgid() throws {
        let identity = try #require(ProcessIdentity.read(pid: getpid()))
        #expect(identity.ownsTerminal == (identity.pgid > 0 && identity.pgid == identity.tpgid))
    }
}
