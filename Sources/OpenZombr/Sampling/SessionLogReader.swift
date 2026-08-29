import Foundation

/// What the tail of one log file says about when the session last did real work.
public enum LogActivityBound: Sendable, Equatable {
    /// A line that is not a known heartbeat was found, written at this instant.
    case activity(Date)
    /// Nothing but heartbeat lines were seen down to this instant. Real activity, if any,
    /// happened at or before it — so the date is an *upper bound* on the last activity and
    /// therefore errs towards "recently active".
    case noActivitySince(Date)
    /// The file carries no usable information: no parseable timestamp at all, or a format
    /// this reader does not recognise. Never read as idleness.
    case unknown

    /// Upper bound on when the session behind this file last did real work, or `nil` when
    /// nothing can be concluded.
    public var lastActivityBound: Date? {
        switch self {
        case .activity(let date), .noActivitySince(let date): return date
        case .unknown: return nil
        }
    }
}

/// Reads the *content* of a session log tail to decide whether a session is still working.
///
/// ## Why content and not `mtime`
///
/// The file-level signal does not carry the information. Measured on 2026-08-29 against the
/// wrapper this app was built for — `agency` pid 86183, 17 h old, holding 1022 zombies at
/// 39 % of `kern.maxprocperuid` — the app never once offered it as a candidate. The CSV
/// evidence shows why:
///
/// ```
/// …,86183,agency,1019,cpu_idle=27534;log_age=4,poll,
/// ```
///
/// CPU said 7.6 h idle, far past the two hour threshold, but the log age said 4 s. Both
/// signals must agree, so the log signal alone kept the wrapper protected forever. That
/// fresh `mtime` came from the wrapper's own log file, and everything being written to it
/// was the leak's own heartbeat:
///
/// ```
/// 09:23:13.505Z DEBUG agency::send_telemetry_events: telem flush: spawned detached child pid=32302
/// 09:24:13.503Z DEBUG agency::send_telemetry_events: telem flush: spawned detached child pid=32512
/// ```
///
/// Every one of those lines *is* a zombie being created, once every 30 s, and each one
/// refreshed the very timestamp that was supposed to expose the wrapper as dead. The last
/// line of real work in that file was 17.2 h older than the newest line. Its last 400 lines
/// contained exactly three kinds of message — `telem periodic flush`, `telem flush: spawned
/// detached child`, and `accepted OTLP signal … signal=/v1/metrics` — and nothing else.
///
/// This is the same failure class as the CPU signal before it, but inverted and worse: CPU
/// made an active session look idle (unsafe but visible), while `mtime` makes a session
/// that died 17 h ago look permanently active, which neutralises the feature completely.
///
/// ## How this reader stays cheap
///
/// The sibling `process-*.log` of that same session was **253 MB**, so a full scan is out of
/// the question. The file is instead read backwards from EOF in chunks and the scan stops at
/// the first line that is not a heartbeat. Measured on the real files, 300 lines of a
/// heartbeat-only tail cover 75 minutes, so reaching past the two hour threshold costs tens
/// of kilobytes, not megabytes. A hard byte budget bounds the pathological case.
///
/// ## Which way the unknown cases fall
///
/// The log formats come from foreign code and will change. The classifier therefore works
/// as a *denylist of known heartbeats*: anything it does not recognise counts as real work
/// and protects the parent. A format change makes heartbeats stop matching, which protects;
/// it can never release. A file with no parseable timestamp at all yields `.unknown`, which
/// also protects.
public struct SessionLogReader: Sendable {
    /// Substrings which, when present in a line, mark it as background housekeeping rather
    /// than session work. Matched case-insensitively.
    ///
    /// Every entry here was read out of the real logs of the affected machine, and each one
    /// is periodic — it ticks whether or not anybody is using the session, which is exactly
    /// what makes it useless as an activity signal:
    ///
    /// * `send_telemetry_events` — the agency wrapper's own telemetry flush. This is the
    ///   leak: `telem flush: spawned detached child pid=…` every 30 s, each spawn becoming
    ///   an unreaped zombie. 300 of the last 400 lines of the 86183 log were these.
    /// * `signal=/v1/metrics` — the OTLP receiver accepting the periodic metrics push. The
    ///   other 100 lines. Note that *trace* batches are deliberately **not** listed: those
    ///   carry span names such as `execute_tool bash`, appear only when work happens, and
    ///   were entirely absent from the dead wrapper's log.
    /// * `[telemetry-queue]`, `github_telemetry` — the copilot runtime's telemetry queue
    ///   worker, which retries POSTs to the telemetry endpoint on a timer.
    /// * `hyper_util::client::legacy`, `reqwest::connect` — the HTTP connection churn those
    ///   retries produce. In the dead session's 253 MB process log these accounted for
    ///   ~99 % of the tail.
    /// * `[managedsettings]`, `[mdm]` — the hourly policy self-fetch. Left unlisted it
    ///   would cap the measurable log age at one hour, which is below the two hour
    ///   threshold and would have protected the dead wrapper just as effectively.
    /// * `managed_settings_resolved` — the session event that fetch emits downstream. It
    ///   is not written by the policy module and so does not carry `[managedSettings]`;
    ///   missing it was caught by measurement, not by reading the code. Between 02:00 and
    ///   09:25 on the day of the incident these eight hourly lines were the *only*
    ///   non-heartbeat content in the dead session's 253 MB log, and each one on its own
    ///   would have reset the age to under an hour.
    public static let heartbeatMarkers: [String] = [
        "send_telemetry_events",
        "signal=/v1/metrics",
        "[telemetry-queue]",
        "github_telemetry",
        "hyper_util::client::legacy",
        "reqwest::connect",
        "[managedsettings]",
        "[mdm]",
        "managed_settings_resolved",
    ]

    /// How far back the scan is willing to look. Beyond this the exact age stops mattering:
    /// anything older than the idle threshold reads as idle either way. Kept comfortably
    /// above the two hour default so a user who raises the threshold is not silently
    /// capped.
    public let horizon: TimeInterval
    /// Size of one backwards read.
    public let chunkSize: Int
    /// Hard ceiling on bytes read per file per poll. Reaching it does not release anything:
    /// the scan then reports `.noActivitySince(oldest line it saw)`, which is an upper
    /// bound and therefore still errs towards "active".
    public let byteBudget: Int

    public init(
        horizon: TimeInterval = 6 * 3600,
        chunkSize: Int = 64 * 1024,
        byteBudget: Int = 4 * 1024 * 1024
    ) {
        self.horizon = horizon
        self.chunkSize = max(1024, chunkSize)
        self.byteBudget = max(self.chunkSize, byteBudget)
    }

    // MARK: - File scanning

    public func activityBound(ofFileAt path: String, now: Date) -> LogActivityBound {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }

        guard let size = (try? handle.seekToEnd()).map(Int.init), size > 0 else {
            // An empty file carries no evidence in either direction. The caller skips it.
            return .unknown
        }

        var offset = size
        var budget = byteBudget
        var carry: [UInt8] = []
        var oldestSeen: Date?
        let cutoff = now.addingTimeInterval(-horizon)

        while offset > 0 && budget > 0 {
            let length = min(min(chunkSize, budget), offset)
            offset -= length
            budget -= length
            guard
                (try? handle.seek(toOffset: UInt64(offset))) != nil,
                let data = try? handle.read(upToCount: length), data.count == length
            else {
                return oldestSeen.map(LogActivityBound.noActivitySince) ?? .unknown
            }

            var bytes = [UInt8](data)
            bytes.append(contentsOf: carry)
            // The first line of a chunk is only whole once the start of the file is
            // reached; until then it is carried into the next (earlier) read.
            var lines = Self.split(bytes)
            if offset > 0, !lines.isEmpty {
                carry = Array(lines.removeFirst())
            } else {
                carry = []
            }

            // Newest first: the scan wants the most recent non-heartbeat line.
            for line in lines.reversed() {
                guard let timestamp = Self.timestamp(in: line) else {
                    // Untimestamped lines are continuations of the timestamped line above
                    // them, so they inherit its classification and need no handling of
                    // their own. Only a file with *no* timestamp anywhere is unusable.
                    continue
                }
                oldestSeen = timestamp
                if !Self.isHeartbeat(line) { return .activity(timestamp) }
                if timestamp <= cutoff { return .noActivitySince(timestamp) }
            }
        }

        guard let oldest = oldestSeen else { return .unknown }
        return .noActivitySince(oldest)
    }

    /// Splits on `\n`, keeping empty segments so the chunk-boundary carry stays exact.
    static func split(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            result.append(bytes[start..<index])
            start = index + 1
        }
        result.append(bytes[start...])
        return result
    }

    // MARK: - Line classification

    static func isHeartbeat(_ line: ArraySlice<UInt8>) -> Bool {
        let lowercased = String(decoding: line, as: UTF8.self).lowercased()
        return heartbeatMarkers.contains { lowercased.contains($0) }
    }

    /// Parses a leading `YYYY-MM-DDTHH:MM:SS[.frac]Z` timestamp.
    ///
    /// Hand-rolled rather than `ISO8601DateFormatter` because this runs over tens of
    /// thousands of lines per poll on a machine that is by definition already out of
    /// process slots. Anything that does not match this exact shape — including any
    /// non-`Z` zone — returns `nil` and is treated as unparseable, which protects.
    static func timestamp(in line: ArraySlice<UInt8>) -> Date? {
        guard line.count >= 20 else { return nil }
        let bytes = Array(line.prefix(40))

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
            bytes[13] == 0x3A, bytes[16] == 0x3A,
            let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16),
            let second = number(17..<19)
        else { return nil }

        var index = 19
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let start = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            guard index > start else { return nil }
        }
        guard index < bytes.count, bytes[index] == 0x5A else { return nil }

        guard month >= 1, month <= 12, day >= 1, day <= 31, hour < 24, minute < 60,
            second <= 60
        else { return nil }

        return Date(timeIntervalSince1970: Double(
            Self.daysFromCivil(year: year, month: month, day: day) * 86_400
                + hour * 3600 + minute * 60 + second))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    /// Avoids `Calendar`, which is far too expensive per line.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
