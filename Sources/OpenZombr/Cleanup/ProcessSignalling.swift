import Darwin
import Foundation

/// Enough of a process's identity to tell it apart from a later process that merely
/// inherited its PID.
///
/// A PID is not an identity. Darwin allocates PIDs sequentially and wraps, so a number
/// that named one process at selection time can name a completely different one by the
/// time a signal is delivered. Measured on the affected machine: 160 PIDs are handed out
/// every 20 seconds while it is *idle*, and auto-cleanup runs precisely when it is not.
public struct ProcessIdentity: Sendable, Equatable {
    public let startTime: Date
    public let uid: uid_t

    public init(startTime: Date, uid: uid_t) {
        self.startTime = startTime
        self.uid = uid
    }

    /// Start times come from the kernel as whole microseconds but travel through `Date`,
    /// so they are compared with a tolerance rather than for exact equality.
    public func matches(_ other: ProcessIdentity) -> Bool {
        uid == other.uid && abs(startTime.timeIntervalSince(other.startTime)) < 1
    }
}

/// The result of asking the kernel whether a PID still holds the process the safety rules
/// approved.
///
/// Three cases, not two: `unreadable` must never collapse into either of the others.
/// Reading it as `matches` would signal an unverified process; reading it as `differs`
/// would be honest but loses the distinction in the evidence log.
public enum IdentityVerification: Sendable, Equatable {
    case matches
    case differs
    case unreadable
}

/// Sends signals and checks liveness.
///
/// Behind a protocol so that target selection and the SIGTERM→SIGKILL escalation can be
/// unit tested exhaustively without any real process being signalled.
public protocol ProcessSignalling: Sendable {
    /// Returns `true` when the signal was delivered. `false` means the process was
    /// already gone or could not be signalled.
    func send(signal: Int32, to pid: pid_t) -> Bool
    func isAlive(pid: pid_t) -> Bool
    /// Re-reads whoever holds `pid` *right now* and compares them with `expected`.
    ///
    /// Called immediately before every signal, because selection happened against a
    /// snapshot that may be minutes old and a PID is not an identity.
    func verifyIdentity(ofPID pid: pid_t, matches expected: ProcessIdentity)
        -> IdentityVerification
}

/// Lets tests run the grace period instantly instead of really sleeping.
public protocol Sleeping: Sendable {
    func sleep(for interval: TimeInterval)
}

public struct ThreadSleeper: Sleeping {
    public init() {}
    public func sleep(for interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}

/// Real signal delivery via `kill(2)`.
public struct POSIXSignalSender: ProcessSignalling {
    public init() {}

    public func send(signal: Int32, to pid: pid_t) -> Bool {
        // Guards duplicated from the reaper on purpose: this is the last line of defence
        // before a signal reaches the kernel, and it must hold even if a caller is wrong.
        guard pid > 1 else { return false }
        return kill(pid, signal) == 0
    }

    /// `kill(pid, 0)` performs the permission and existence check without delivering a
    /// signal. `EPERM` means the process exists but belongs to someone else, which still
    /// counts as alive.
    public func isAlive(pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Reads the live identity with a single `KERN_PROC_PID` sysctl and compares it.
    ///
    /// Deliberately a per-PID read rather than a walk of the full table: it is cheap, and
    /// more importantly it is *current*, which is the entire point of asking again.
    public func verifyIdentity(ofPID pid: pid_t, matches expected: ProcessIdentity)
        -> IdentityVerification
    {
        guard pid > 1 else { return .differs }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
        // A zero-length answer means the pid is gone: the call succeeds but fills nothing.
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid
        else { return .unreadable }
        let started = info.kp_proc.p_un.__p_starttime
        let current = ProcessIdentity(
            startTime: Date(
                timeIntervalSince1970: TimeInterval(started.tv_sec)
                    + TimeInterval(started.tv_usec) / 1_000_000),
            uid: info.kp_eproc.e_ucred.cr_uid
        )
        return current.matches(expected) ? .matches : .differs
    }
}
