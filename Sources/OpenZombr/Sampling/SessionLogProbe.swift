import Foundation

/// Reads how long ago a session last wrote to its log directory.
///
/// This exists because CPU time is a poor proxy for session activity. A session process
/// delegates its work to short-lived grandchildren, so it can be flat out busy while
/// consuming almost nothing itself. Measured on the affected machine: a session running
/// builds continuously registered 0.0000 % CPU across eight consecutive 15 s samples,
/// both for the process and for its subtree, because each build exited before the next
/// sample and took its accumulated CPU with it. Relying on CPU alone would therefore have
/// classified a maximally active session as idle.
///
/// The session log does not have that weakness: it is written on every turn, whichever
/// process actually burns the cycles. In the same measurement it reported an age of 0 s
/// for the busy session and 559 s for a finished one.
public protocol SessionLogProbing: Sendable {
    /// Seconds since the session behind `pid` last wrote to its log directory, or `nil`
    /// when there is no log directory or it cannot be read. `nil` is read as "active".
    func logAgeSeconds(for pid: pid_t, now: Date) -> TimeInterval?
}

/// Resolves `--log-dir` from a process's arguments and stats the directory contents.
public struct SessionLogProbe: SessionLogProbing {
    private let enumerator: ProcessEnumerating
    private let fileManager: FileManager

    /// Files whose names contain any of these are ignored when looking for the newest
    /// write.
    ///
    /// This matters more than it looks. The telemetry children that cause the leak write
    /// their queue files into the *same* directory, so the newest file in a dead session's
    /// log directory can be a `telemetry_queue…jsonl.delivered` written seconds ago. That
    /// was observed directly: session 44194 had been finished for over ten minutes, its
    /// process log untouched for 612 s, while a telemetry file in the same directory was
    /// only 559 s old. Counting those would let the leak itself keep the leaking wrapper
    /// permanently protected — precisely inverting the guard.
    public static let ignoredNameFragments = ["telemetry"]

    public init(
        enumerator: ProcessEnumerating = SysctlProcessEnumerator(),
        fileManager: FileManager = .default
    ) {
        self.enumerator = enumerator
        self.fileManager = fileManager
    }

    public func logAgeSeconds(for pid: pid_t, now: Date = Date()) -> TimeInterval? {
        guard let directory = Self.logDirectory(in: enumerator.arguments(for: pid) ?? []),
            let newest = newestWrite(in: directory)
        else { return nil }
        return max(0, now.timeIntervalSince(newest))
    }

    /// Extracts the value of `--log-dir`, accepting both `--log-dir X` and `--log-dir=X`.
    public static func logDirectory(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--log-dir", index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix("--log-dir=") {
                return String(argument.dropFirst("--log-dir=".count))
            }
        }
        return nil
    }

    private func newestWrite(in directory: String) -> Date? {
        guard
            let contents = try? fileManager.contentsOfDirectory(atPath: directory)
        else { return nil }

        var newest: Date?
        for name in contents {
            let lowercased = name.lowercased()
            if Self.ignoredNameFragments.contains(where: { lowercased.contains($0) }) {
                continue
            }
            let path = (directory as NSString).appendingPathComponent(name)
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: path),
                let modified = attributes[.modificationDate] as? Date
            else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }
}
