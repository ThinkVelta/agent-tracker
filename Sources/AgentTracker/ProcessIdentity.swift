import Darwin
import Foundation

/// A live process's identity, as the kernel reports it.
///
/// One `proc_pidinfo` call, no fork. `SessionStore` proves a session is alive
/// with `kill(pid, 0)`, which is right for pruning a row and wrong for deciding
/// whether to type into a terminal: it passes for a *recycled* pid, and the
/// window between arming a scheduled continue and firing it is up to twelve
/// hours. Long enough for the agent to exit and its pid to come back around as
/// something else.
///
/// So identity here is pid **plus start time**, and the same call answers the
/// other question delivery needs — whether the agent still owns its terminal.
struct ProcessIdentity: Equatable, Codable {
    var pid: Int32
    /// Start time to the microsecond. This is what makes the pair unique: the
    /// kernel will reissue a pid, but not with the same start instant.
    var startedAt: Date
    /// Short process name, e.g. "claude". Used only to say what is in the way
    /// when a refusal needs to name it.
    var comm: String
    /// The process group this process belongs to.
    var pgid: Int32
    /// The process group that currently owns the controlling terminal.
    var tpgid: Int32
    /// Controlling terminal, e.g. "ttys006", or nil when it has none.
    var tty: String?

    /// Whether what gets typed into this terminal would actually reach this
    /// process, rather than something it launched. See
    /// `ContinueDelivery.foregroundAllows` for why this replaced reading the
    /// screen.
    var ownsTerminal: Bool { pgid > 0 && pgid == tpgid }

    /// Whether this is still the same process that was recorded, not merely the
    /// same number.
    func isSameProcess(as other: ProcessIdentity) -> Bool {
        // The kernel reports microseconds; comparing Dates exactly would make
        // this fail on a rounding difference that never existed in the kernel.
        pid == other.pid && abs(startedAt.timeIntervalSince(other.startedAt)) < 0.001
    }

    /// Reads a live process, or nil if it is gone or unreadable.
    ///
    /// Unreadable and gone are deliberately the same answer. Every caller here
    /// treats "cannot confirm" as a refusal, so distinguishing them would only
    /// invite someone to act on the difference. Measured: a process owned by
    /// another user returns 0 bytes with EPERM (pid 1 does), while this process
    /// and its parent return all 136 — a boundary that costs this feature nothing,
    /// since the agents it schedules are always the user's own.
    static func read(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        // A short read means the struct this build expects is not the struct the
        // kernel filled in, which makes every field below a guess.
        guard written == size else { return nil }

        let seconds = TimeInterval(info.pbi_start_tvsec)
        let micros = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return ProcessIdentity(
            pid: Int32(info.pbi_pid),
            startedAt: Date(timeIntervalSince1970: seconds + micros),
            comm: withUnsafePointer(to: info.pbi_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            },
            pgid: Int32(bitPattern: info.pbi_pgid),
            tpgid: Int32(bitPattern: info.e_tpgid),
            tty: ttyName(forDevice: info.e_tdev)
        )
    }

    /// `e_tdev` is a device number; `devname` turns it back into the name a
    /// terminal reports as its tty. `NODEV` means the process has no controlling
    /// terminal at all, which is a legitimate state and not an error.
    private static func ttyName(forDevice device: UInt32) -> String? {
        guard device != UInt32(bitPattern: -1) else { return nil }
        guard let name = devname(dev_t(device), S_IFCHR) else { return nil }
        return String(cString: name)
    }
}
