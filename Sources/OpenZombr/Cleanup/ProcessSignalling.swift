import Darwin
import Foundation

/// Sends signals and checks liveness.
///
/// Behind a protocol so that target selection and the SIGTERM→SIGKILL escalation can be
/// unit tested exhaustively without any real process being signalled.
public protocol ProcessSignalling: Sendable {
    /// Returns `true` when the signal was delivered. `false` means the process was
    /// already gone or could not be signalled.
    func send(signal: Int32, to pid: pid_t) -> Bool
    func isAlive(pid: pid_t) -> Bool
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
}
