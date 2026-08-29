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
///
/// What counts as "written", however, cannot be the file's `mtime`. See `SessionLogReader`:
/// the leak's own heartbeat writes into the session log every 30 s, so `mtime` reports a
/// wrapper that has been dead for 17 h as active forever. The age is derived from the log
/// *content* instead.
public protocol SessionLogProbing: Sendable {
    /// Seconds since the session behind `pid` last wrote something that is not a known
    /// heartbeat, or `nil` when there is no log directory or it cannot be interpreted.
    /// `nil` is read as "active".
    func logAgeSeconds(for pid: pid_t, now: Date) -> TimeInterval?
}

/// Resolves `--log-dir` from a process's arguments and reads the tail of its log files.
///
/// The age reported is **not** the newest write to the directory. That was the original
/// design and it was measured to be worthless: see `SessionLogReader` for the wrapper that
/// sat 17 h dead with 1022 zombies while reporting a log age of 4 s, because its own
/// zombie-spawning heartbeat kept refreshing the file every 30 s. What is reported here is
/// how long ago the session last wrote something that is *not* a known heartbeat.
public struct SessionLogProbe: SessionLogProbing {
    private let enumerator: ProcessEnumerating
    private let fileManager: FileManager
    private let reader: SessionLogReader

    /// Files whose names contain any of these are ignored entirely.
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
        fileManager: FileManager = .default,
        reader: SessionLogReader = SessionLogReader()
    ) {
        self.enumerator = enumerator
        self.fileManager = fileManager
        self.reader = reader
    }

    public func logAgeSeconds(for pid: pid_t, now: Date = Date()) -> TimeInterval? {
        guard let directory = Self.logDirectory(in: enumerator.arguments(for: pid) ?? []),
            let newest = lastActivity(in: directory, now: now)
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

    /// Upper bound on when the session last did real work, across every log file in the
    /// directory, or `nil` when no conclusion can be drawn.
    ///
    /// Combining with `max` is the protective choice: one file still showing work keeps the
    /// whole session active. A file the reader cannot interpret at all makes the *whole*
    /// directory unknown rather than being quietly skipped — absence of evidence must never
    /// read as evidence of idleness.
    private func lastActivity(in directory: String, now: Date) -> Date? {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        var newest: Date?
        var sawAnyFile = false
        for name in contents.sorted() {
            let lowercased = name.lowercased()
            if Self.ignoredNameFragments.contains(where: { lowercased.contains($0) }) {
                continue
            }
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            // A zero-byte file says nothing in either direction and must not be mistaken
            // for an unreadable one, which would protect forever.
            if (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int == 0 {
                continue
            }

            sawAnyFile = true
            guard let bound = reader.activityBound(ofFileAt: path, now: now).lastActivityBound
            else { return nil }
            newest = max(newest ?? bound, bound)
        }

        return sawAnyFile ? newest : nil
    }
}
