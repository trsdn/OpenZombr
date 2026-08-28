import Foundation

/// Reads the kernel process table.
///
/// Behind a protocol so that every consumer — in particular the cleanup safety logic —
/// can be tested against synthetic process tables instead of the real machine.
public protocol ProcessEnumerating: Sendable {
    func enumerateProcesses() throws -> [ProcessEntry]
    /// Full executable path for a pid, or `nil` when it cannot be resolved (the process
    /// exited, or it belongs to another user). Only called for a handful of candidate
    /// parents, never for the whole table.
    func executablePath(for pid: pid_t) -> String?
}

/// Reads `kern.maxprocperuid`.
///
/// Separate from enumeration because it is a different sysctl and because tests need to
/// pin the limit to a known value.
public protocol ProcessLimitReading: Sendable {
    func maximumProcessesPerUID() throws -> Int
}

public enum ProcessTableError: Error, CustomStringConvertible {
    case sysctlFailed(name: String, errno: Int32)
    case unexpectedSize

    public var description: String {
        switch self {
        case .sysctlFailed(let name, let code):
            return "sysctl(\(name)) failed: \(String(cString: strerror(code))) (\(code))"
        case .unexpectedSize:
            return "sysctl returned an unexpected buffer size"
        }
    }
}
