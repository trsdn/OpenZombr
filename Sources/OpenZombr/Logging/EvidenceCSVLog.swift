import Foundation

/// Append-only CSV log of the leak and everything the app did about it, with size-based
/// rotation.
///
/// This file is the evidence for an upstream bug report against `agency`: one row per
/// poll and one row per cleanup action, plain CSV, no quoting games, directly loadable
/// into a spreadsheet.
public final class EvidenceCSVLog: @unchecked Sendable {
    public static let header =
        "timestamp,total_procs,zombies,limit,usage_pct,free_slots,"
        + "growth_per_min,eta_seconds,top_parent_pid,top_parent_name,top_parent_zombies,"
        + "session_signal,action,result"

    public let fileURL: URL
    private let maxBytes: UInt64
    private let keepRotations: Int
    private let queue = DispatchQueue(label: "com.openzombr.csvlog")
    private let formatter: ISO8601DateFormatter

    public init(
        directory: URL = EvidenceCSVLog.defaultDirectory(),
        fileName: String = "zombie-evidence.csv",
        maxBytes: UInt64 = 4 * 1024 * 1024,
        keepRotations: Int = 3
    ) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.maxBytes = maxBytes
        self.keepRotations = keepRotations
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.formatter = formatter

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfHeaderChanged()
    }

    /// `~/Library/Application Support/OpenZombr/`.
    public static func defaultDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("OpenZombr", isDirectory: true)
    }

    public func append(
        snapshot: ZombieSnapshot,
        forecast: ForkFailureForecast,
        action: String = "poll",
        result: String = ""
    ) {
        let line = Self.row(
            snapshot: snapshot, forecast: forecast, action: action, result: result,
            formatter: formatter)
        queue.sync {
            rotateIfNeeded()
            write(line: line)
        }
    }

    /// One row per terminated parent, so the log shows exactly which pid was signalled
    /// with what and whether it worked.
    public func append(report: CleanupReport, snapshot: ZombieSnapshot) {
        for result in report.results {
            let action = "kill:\(result.signalsSent.map(String.init).joined(separator: "+"))"
            let detail =
                "\(result.outcome.logToken);reaped=\(report.zombiesReaped);"
                + "freed=\(report.slotsFreed);verified=\(report.verified)"
            let line = Self.row(
                snapshot: snapshot,
                forecast: .unavailable,
                action: action,
                result: detail,
                overrideTopParent: result.parent,
                formatter: formatter
            )
            queue.sync {
                rotateIfNeeded()
                write(line: line)
            }
        }
        if report.results.isEmpty {
            append(snapshot: snapshot, forecast: .unavailable, action: "cleanup", result: "no-targets")
        }
    }

    /// Formats one CSV row. Pure, so the on-disk format is pinned by tests.
    public static func row(
        snapshot: ZombieSnapshot,
        forecast: ForkFailureForecast,
        action: String,
        result: String,
        overrideTopParent: ZombieParent? = nil,
        formatter: ISO8601DateFormatter
    ) -> String {
        let top = overrideTopParent ?? snapshot.topOffender
        let fields: [String] = [
            formatter.string(from: snapshot.timestamp),
            String(snapshot.totalProcesses),
            String(snapshot.zombieCount),
            String(snapshot.limit),
            String(format: "%.1f", snapshot.usageFraction * 100),
            String(snapshot.freeSlots),
            String(format: "%.2f", forecast.slotsPerMinute),
            forecast.secondsToExhaustion.map { String(format: "%.0f", $0) } ?? "",
            top.map { String($0.pid) } ?? "",
            sanitize(top?.name ?? ""),
            top.map { String($0.zombieCount) } ?? "",
            top.map(sessionSignal(for:)) ?? "",
            sanitize(action),
            sanitize(result),
        ]
        return fields.joined(separator: ",")
    }

    /// Whether the two idle signals could be read for the top offender, and what they say.
    ///
    /// Recorded per row because "no cleanup because everything is active" and "no cleanup
    /// because the app could not see" are different events, and the evidence log is the
    /// place where that difference has to survive.
    static func sessionSignal(for parent: ZombieParent) -> String {
        guard parent.hasActiveSession else { return "no-session" }
        let cpu = parent.sessionIdleSeconds.map { String(format: "%.0f", $0) } ?? "unknown"
        let log = parent.sessionLogAgeSeconds.map { String(format: "%.0f", $0) } ?? "unknown"
        return "cpu_idle=\(cpu);log_age=\(log)"
    }

    /// Commas and newlines would break the "no quoting games" promise, so they are
    /// replaced rather than escaped. Process names can contain almost anything.
    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func write(line: String) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            let contents = Self.header + "\n" + line + "\n"
            try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Rotates the log when its header no longer matches the columns being written.
    ///
    /// The header is only written when the file is created, so adding a column would
    /// otherwise leave an existing log with a stale header above rows that have one field
    /// more — silently shifting every column for anyone reading it afterwards. Since this
    /// file exists to be evidence, a mismatched schema is worse than a rotation.
    func rotateIfHeaderChanged() {
        let manager = FileManager.default
        guard
            manager.fileExists(atPath: fileURL.path),
            let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return }
        defer { try? handle.close() }

        let probe = (try? handle.read(upToCount: Self.header.utf8.count + 1)) ?? Data()
        let existing = String(decoding: probe, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
        guard let existing, existing != Self.header else { return }
        try? handle.close()
        rotate()
    }

    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard
            let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size >= maxBytes
        else { return }
        rotate()
    }

    private func rotate() {
        let manager = FileManager.default
        try? manager.removeItem(at: rotatedURL(index: keepRotations))
        for index in stride(from: keepRotations - 1, through: 1, by: -1) {
            let source = rotatedURL(index: index)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.moveItem(at: source, to: rotatedURL(index: index + 1))
        }
        try? manager.moveItem(at: fileURL, to: rotatedURL(index: 1))
    }

    private func rotatedURL(index: Int) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("\(index)")
            .appendingPathExtension(fileURL.pathExtension)
    }
}
