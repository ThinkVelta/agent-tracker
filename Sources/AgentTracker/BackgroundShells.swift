import Darwin
import Foundation

/// Finds and stops the process behind a background shell task.
///
/// Claude Code offers no way to end a task from outside, but the shell it
/// spawns is a direct child of the `claude` process, leads its own process
/// group, and carries the command verbatim in its arguments as `eval '…'`.
/// That is enough to pick it out without a TCC grant. Ending it is what
/// actually resolves a stuck loop: Claude sees the task exit and wakes up with
/// whatever the shell printed.
enum BackgroundShells {
    enum Outcome: Equatable {
        case stopped
        case notFound
        case ambiguous(Int)
        case notPermitted

        var summary: String {
            switch self {
            case .stopped: return "Stopped. Claude will pick up the output shortly."
            case .notFound: return "No shell running that command was found; it may have ended."
            case .ambiguous(let count):
                return "\(count) shells are running that command; not stopping any of them."
            case .notPermitted: return "Not permitted to stop that process."
            }
        }
    }

    struct Candidate: Equatable {
        var pid: pid_t
        var pgid: pid_t
        var arguments: String
    }

    /// Whether a child's argument string is the wrapper running `command`.
    /// The wrapper quotes the command with single quotes, escaping any inside
    /// it the shell way, so that is the form to look for. A whole command must
    /// be closed by the wrapper's own quote, or `sleep 27` would also claim
    /// `sleep 2700`; only an excerpt the hook cut short may match as a prefix.
    static func runs(_ command: String, arguments: String, truncated: Bool = false) -> Bool {
        guard !command.isEmpty else { return false }
        let quoted = "eval '" + command.replacingOccurrences(of: "'", with: #"'\''"#)
        return arguments.contains(truncated ? quoted : quoted + "'")
    }

    /// Off the main actor: it walks the process table.
    static func stop(_ task: BackgroundTask, ownerPid: Int) -> Outcome {
        guard let command = task.command else { return .notFound }
        let matches = children(of: pid_t(ownerPid)).filter {
            runs(command, arguments: $0.arguments, truncated: task.commandTruncated == true)
        }
        guard let shell = matches.first else { return .notFound }
        guard matches.count == 1 else { return .ambiguous(matches.count) }
        // The group, when the shell leads one, so its own children (the
        // `sleep` in a polling loop) go with it instead of being orphaned.
        let target = shell.pgid == shell.pid ? -shell.pid : shell.pid
        if kill(target, SIGTERM) == 0 { return .stopped }
        return errno == EPERM ? .notPermitted : .notFound
    }

    /// Direct children of `pid`, with their arguments. One `sysctl` for the
    /// table and one per child for its arguments; nothing forked.
    static func children(of pid: pid_t) -> [Candidate] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Slack for processes that appear between the two calls.
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = table.count * stride
        guard sysctl(&mib, u_int(mib.count), &table, &size, nil, 0) == 0 else { return [] }
        return table.prefix(size / stride)
            .filter { $0.kp_eproc.e_ppid == pid }
            .compactMap { info in
                let child = info.kp_proc.p_pid
                guard let arguments = arguments(of: child) else { return nil }
                return Candidate(pid: child, pgid: info.kp_eproc.e_pgid, arguments: arguments)
            }
    }

    /// The process's argument block from `KERN_PROCARGS2`, NUL separators
    /// turned into spaces. Only own-user processes answer; others read as nil.
    static func arguments(of pid: pid_t) -> String? {
        var limitMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var limit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        guard sysctl(&limitMib, u_int(limitMib.count), &limit, &limitSize, nil, 0) == 0,
            limit > 0
        else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        var size = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size
        else { return nil }
        // Layout: argc, then the executable path and each argument, NUL-terminated.
        let body = buffer[MemoryLayout<Int32>.size..<size].map { $0 == 0 ? UInt8(0x20) : $0 }
        return String(decoding: body, as: UTF8.self)
    }
}
