import XCTest

@testable import OpenZombrKit

/// The log signal read from file *content* rather than from `mtime`.
///
/// These tests exist because the `mtime` version of this signal silently neutralised the
/// whole cleanup feature. Measured on 2026-08-29 against `agency` wrapper 86183: 17 h old,
/// 1022 zombies, 39 % of `kern.maxprocperuid`, CPU idle for 7.6 h — and never once offered
/// as a candidate, because its log directory reported an age of 4 s. The 4 s came from the
/// leak's own heartbeat writing `telem flush: spawned detached child pid=…` into the log
/// every 30 s. Every zombie created refreshed the timestamp that was supposed to expose the
/// wrapper as dead.
final class SessionLogContentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openzombr-logcontent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private func line(_ offset: TimeInterval, _ message: String, from now: Date) -> String {
        Self.stamp.string(from: now.addingTimeInterval(-offset)) + " " + message
    }

    @discardableResult
    private func write(_ name: String, _ lines: [String]) throws -> String {
        let path = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        // Fresh `mtime` on purpose: it is exactly what the old design trusted, and every
        // one of these tests must reach its verdict without it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: path.path)
        return path.path
    }

    /// The two log lines the leaking wrapper wrote, verbatim from the incident file.
    private func heartbeat(_ offset: TimeInterval, from now: Date) -> [String] {
        [
            line(
                offset,
                "DEBUG tokio-runtime-worker ThreadId(09) agency::send_telemetry_events: "
                    + "client/agency/src/send_telemetry_events.rs:427: telem periodic flush: "
                    + "queue empty, nothing to commit", from: now),
            line(
                offset - 1,
                "DEBUG tokio-runtime-worker ThreadId(09) agency::send_telemetry_events: "
                    + "client/agency/src/send_telemetry_events.rs:282: telem flush: spawned "
                    + "detached child pid=32302", from: now),
            line(
                offset - 2,
                "DEBUG tokio-runtime-worker ThreadId(11) otel_receiver::server: "
                    + "client/otel_receiver/src/server.rs:136: accepted OTLP signal "
                    + "(not yet processed) signal=/v1/metrics", from: now),
        ]
    }

    private func age(now: Date = Date()) -> TimeInterval? {
        let enumerator = StubProcessEnumerator(entries: [])
        enumerator.args = [86242: ["copilot", "--log-dir", directory.path]]
        return SessionLogProbe(enumerator: enumerator).logAgeSeconds(for: 86242, now: now)
    }

    // MARK: - The incident

    /// Exactly the 86183 situation: hours-old real work, a heartbeat still ticking every
    /// 30 s, and a `mtime` of zero seconds. The old design read 4 s here; anything under
    /// the two hour threshold protects the wrapper forever.
    func testAHeartbeatOnlyTailIsIdleDespiteAFreshModificationTime() throws {
        let now = Date()
        var lines: [String] = []
        lines += [
            line(
                9 * 3600,
                "DEBUG Forwarding event for session 4da0d54f: assistant.turn_end", from: now)
        ]
        // 30 s apart, all the way up to "one second ago", just as on the machine.
        for offset in stride(from: 8.5 * 3600, through: 3, by: -30) {
            lines += heartbeat(offset, from: now)
        }
        try write("agency_copilot_20260828_181243_86183.log", lines)

        let measured = try XCTUnwrap(age(now: now))
        XCTAssertGreaterThan(
            measured, 2 * 3600,
            "a session whose log has carried nothing but the leak's own heartbeat for "
                + "hours must read as idle, not as one second old")
    }

    /// End to end: the same log, a session child idle on CPU, and the reaper must now
    /// actually offer the wrapper. This is the behaviour the incident proved was missing.
    func testTheLeakingWrapperBecomesACandidate() throws {
        let now = Date()
        var lines = [
            line(9 * 3600, "DEBUG Forwarding event for session 4da0d54f: assistant.turn_end",
                 from: now)
        ]
        for offset in stride(from: 8.5 * 3600, through: 3, by: -30) {
            lines += heartbeat(offset, from: now)
        }
        try write("agency_copilot_20260828_181243_86183.log", lines)

        let logAge = try XCTUnwrap(age(now: now))
        let parent = Fixture.parent(
            pid: 86183, zombieCount: 1019, sessionChildCount: 1, sessionChildPIDs: [86242],
            sessionIdleSeconds: 27_534, sessionLogAgeSeconds: logAge)
        let selection = ZombieReaper(currentUID: 501).selectTargets(
            in: Fixture.snapshot(offenders: [parent], protectedPIDs: [1]),
            policy: CleanupPolicy())

        XCTAssertEqual(selection.targets.map(\.pid), [86183])
    }

    // MARK: - Aggregation across the files of one directory

    /// The 86183 directory held two files: the wrapper's own log, which carried nothing but
    /// the leak's heartbeat, and the session child's `process-*.log`. At the moment the
    /// evidence row was written both were quiet, and the directory must read idle — a single
    /// silent-but-present wrapper log must not be able to hide a working child, and a quiet
    /// child must not be outvoted into activity by the heartbeat next to it.
    func testAQuietWrapperLogNextToAQuietChildLogReadsIdle() throws {
        let now = Date()
        var wrapper = [
            line(9 * 3600, "DEBUG Forwarding event for session 4da0d54f: assistant.turn_end",
                 from: now)
        ]
        for offset in stride(from: 8.5 * 3600, through: 3, by: -30) {
            wrapper += heartbeat(offset, from: now)
        }
        try write("agency_copilot_20260828_181243_86183.log", wrapper)

        var child = [
            line(7.7 * 3600, "DEBUG Forwarding event for session 4da0d54f: assistant.turn_end",
                 from: now)
        ]
        for offset in stride(from: 7.5 * 3600, through: 3, by: -30) {
            child += heartbeat(offset, from: now)
        }
        try write("process-1787933564248-86242.log", child)

        let measured = try XCTUnwrap(age(now: now))
        XCTAssertGreaterThan(measured, 2 * 3600)
    }

    /// The inverse, and the reason the aggregation is `max` rather than `min`: the log
    /// directory is the *session child's* `--log-dir`, so its `process-*.log` is the primary
    /// evidence of whether the session is doing anything. A child streaming real work keeps
    /// the wrapper protected even though the wrapper's own log has been heartbeat-only for
    /// hours — that quietness is normal, the wrapper never logs the session's work itself.
    func testAWorkingChildLogProtectsTheWrapperDespiteAHeartbeatOnlyWrapperLog() throws {
        let now = Date()
        var wrapper = [
            line(9 * 3600, "DEBUG Forwarding event for session 4da0d54f: assistant.turn_end",
                 from: now)
        ]
        for offset in stride(from: 8.5 * 3600, through: 3, by: -30) {
            wrapper += heartbeat(offset, from: now)
        }
        try write("agency_copilot_20260828_181243_86183.log", wrapper)
        try write(
            "process-1787933564248-86242.log",
            [
                line(20, "DEBUG Forwarding event for session 4da0d54f: "
                       + "assistant.streaming_delta", from: now)
            ])

        let measured = try XCTUnwrap(age(now: now))
        XCTAssertLessThan(
            measured, 60,
            "a session child still streaming work must keep its wrapper protected, however "
                + "quiet the wrapper's own log has become")
    }

    /// The hourly policy self-fetch, and the session event it emits downstream. Both tick
    /// without any user, and one line an hour is enough to hold the age below the two hour
    /// threshold forever. Between 02:00 and 09:25 on the day of the incident these eight
    /// lines were the only non-heartbeat content in a 253 MB log.
    func testTheHourlyPolicyFetchIsNotSessionWork() throws {
        let now = Date()
        var lines = [
            line(9 * 3600, "DEBUG Forwarding event for session 4da0d54f: assistant.turn_end",
                 from: now)
        ]
        for hour in stride(from: 8.0, through: 1.0, by: -1.0) {
            lines += [
                line(hour * 3600, "[INFO] [managedSettings] self-fetch starting for account",
                     from: now),
                line(hour * 3600 - 1, "[DEBUG] [MDM] Read 3 managed setting(s) from plist",
                     from: now),
                line(
                    hour * 3600 - 2,
                    "[DEBUG] Forwarding event for session 4da0d54f: "
                        + "session.managed_settings_resolved (ephemeral)", from: now),
            ]
        }
        lines += heartbeat(30, from: now)
        try write("process-1787933564248-86242.log", lines)

        XCTAssertGreaterThan(try XCTUnwrap(age(now: now)), 2 * 3600)
    }

    // MARK: - The protective direction

    func testRecentRealWorkKeepsTheSessionActive() throws {
        let now = Date()
        var lines: [String] = []
        for offset in stride(from: Double(8) * 3600, through: Double(120), by: -30) {
            lines += heartbeat(offset, from: now)
        }
        lines.append(
            line(
                45,
                "[DEBUG] Forwarding event for session 4da0d54f: tool.execution_start",
                from: now))
        lines += heartbeat(10, from: now)
        try write("process-1787933564248-86242.log", lines)

        XCTAssertLessThan(
            try XCTUnwrap(age(now: now)), 120,
            "one real work line under the heartbeat must still be found")
    }

    /// OTLP *trace* batches carry span names like `execute_tool bash` and only appear when
    /// work happens — the dead wrapper's log contained none. They must not be swept up with
    /// the periodic `/v1/metrics` push.
    func testOTLPTraceBatchesCountAsWorkWhileMetricPushesDoNot() throws {
        let now = Date()
        var lines: [String] = []
        for offset in stride(from: Double(6) * 3600, through: Double(60), by: -30) {
            lines += heartbeat(offset, from: now)
        }
        lines.append(
            line(
                40,
                "INFO tokio-runtime-worker ThreadId(12) otel_receiver::server: "
                    + "client/otel_receiver/src/server.rs:87: received Copilot trace batch "
                    + "span_count=2 sample=[\"execute_tool bash\", \"chat\"] truncated=false",
                from: now))
        try write("agency_copilot.log", lines)

        XCTAssertLessThan(try XCTUnwrap(age(now: now)), 120)
    }

    /// The formats come from foreign code and will change. A file this reader cannot parse
    /// must fall to the protective side, never to "idle".
    func testUnparseableContentYieldsNoSignal() throws {
        try write(
            "process-42.log",
            [
                "{\"ts\": 1787933564, \"msg\": \"a future format nobody told us about\"}",
                "{\"ts\": 1787933594, \"msg\": \"still not parseable\"}",
            ])
        XCTAssertNil(age(), "an unrecognised format must protect, not release")
    }

    /// A timestamp that parses but a message this reader has never seen counts as work,
    /// which is the same protective direction one level up.
    func testAnUnrecognisedMessageCountsAsWork() throws {
        let now = Date()
        var lines: [String] = []
        for offset in stride(from: Double(6) * 3600, through: Double(90), by: -30) {
            lines += heartbeat(offset, from: now)
        }
        lines.append(line(30, "DEBUG some::brand::new::module: something happened", from: now))
        try write("agency_copilot.log", lines)

        XCTAssertLessThan(try XCTUnwrap(age(now: now)), 90)
    }

    /// One unreadable file poisons the whole directory rather than being quietly skipped.
    /// Absence of evidence must never read as evidence of idleness.
    func testOneUnreadableFileMakesTheWholeDirectoryUnknown() throws {
        let now = Date()
        var lines: [String] = []
        for offset in stride(from: Double(8) * 3600, through: Double(30), by: -30) {
            lines += heartbeat(offset, from: now)
        }
        try write("agency_copilot.log", lines)
        try write("process-42.log", ["no timestamp here at all", "nor here"])

        XCTAssertNil(age(now: now))
    }

    /// A zero-byte file is not an unreadable one. Treating it as unknown would protect
    /// every session that ever opened a log file it did not write to.
    func testAnEmptyFileIsSkippedRatherThanTreatedAsUnreadable() throws {
        let now = Date()
        var lines: [String] = []
        for offset in stride(from: Double(8) * 3600, through: Double(30), by: -30) {
            lines += heartbeat(offset, from: now)
        }
        try write("agency_copilot.log", lines)
        try Data().write(to: directory.appendingPathComponent("empty.log"))

        XCTAssertGreaterThan(try XCTUnwrap(age(now: now)), 2 * 3600)
    }

    /// The telemetry children that cause the leak write their queue files into the same
    /// directory. Session 44194 was finished with its process log 612 s old while a
    /// `telemetry_queue….jsonl.delivered` beside it was 559 s old.
    func testTelemetryQueueFilesAreIgnoredEntirely() throws {
        let now = Date()
        var lines = [
            line(6 * 3600, "[DEBUG] Forwarding event for session 4da0d54f: assistant.turn_end",
                 from: now)
        ]
        lines += heartbeat(30, from: now)
        try write("process-1787938136833-44194.log", lines)
        // Unparseable *and* fresh: were it not skipped by name it would make the directory
        // unknown, which is how a name filter regression would show up here.
        try write(
            "telemetry_queue.44137.1787938165269.0.jsonl.delivered",
            ["{\"event\":\"x\"}"])

        XCTAssertEqual(try XCTUnwrap(age(now: now)), 6 * 3600, accuracy: 60)
    }

    // MARK: - Line handling

    /// Multi-line log entries — MCP request dumps, JSON bodies — have untimestamped
    /// continuation lines. They belong to the entry above them and must inherit its class,
    /// not be mistaken for an unknown format.
    func testUntimestampedContinuationLinesInheritTheirEntry() throws {
        let now = Date()
        var lines: [String] = []
        for offset in stride(from: Double(6) * 3600, through: Double(120), by: -30) {
            lines += heartbeat(offset, from: now)
        }
        lines += [
            line(60, "DEBUG tokio-runtime-worker ThreadId(02) mcp{bluebird}: request headers:",
                 from: now),
            "accept: application/json, text/event-stream",
            "content-type: application/json",
            "}",
        ]
        try write("agency_copilot.log", lines)

        XCTAssertLessThan(
            try XCTUnwrap(age(now: now)), 120,
            "a continuation line must not hide the work entry it belongs to")
    }

    func testTimestampParsingAcceptsBothObservedFormsAndRejectsEverythingElse() {
        func parsed(_ text: String) -> Date? {
            SessionLogReader.timestamp(in: ArraySlice(Array(text.utf8)))
        }
        // The agency wrapper writes microseconds, the copilot process log milliseconds.
        XCTAssertEqual(
            parsed("2026-08-29T09:23:13.499123Z DEBUG x")?.timeIntervalSince1970,
            1_787_995_393)
        XCTAssertEqual(
            parsed("2026-08-29T09:23:13.499Z [DEBUG] x")?.timeIntervalSince1970,
            1_787_995_393)
        XCTAssertEqual(parsed("2026-08-29T09:23:13Z x")?.timeIntervalSince1970, 1_787_995_393)

        XCTAssertNil(parsed("2026-08-29 09:23:13Z x"), "space instead of T is not our format")
        XCTAssertNil(parsed("2026-08-29T09:23:13+02:00 x"), "a non-UTC zone is not our format")
        XCTAssertNil(parsed("Aug 29 09:23:13 x"))
        XCTAssertNil(parsed("2026-13-29T09:23:13Z x"), "month 13")
        XCTAssertNil(parsed(""))
    }

    // MARK: - Cost

    /// The real `process-*.log` of the incident was 253 MB. A full scan is not affordable
    /// on a machine that is already out of process slots, so the reader works backwards
    /// from EOF and stops at the first non-heartbeat line.
    func testALargeFileIsNotScannedInFull() throws {
        let now = Date()
        let path = directory.appendingPathComponent("process-huge.log").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let filler = line(
            9 * 3600, "[DEBUG] Forwarding event for session 4da0d54f: assistant.streaming_delta",
            from: now) + "\n"
        var block = ""
        while block.utf8.count < 1024 * 1024 { block += filler }
        for _ in 0..<40 { try handle.write(contentsOf: Data(block.utf8)) }  // ~40 MB
        var tail = ""
        for offset in stride(from: 3600.0, through: 30, by: -30) {
            tail += heartbeat(offset, from: now).joined(separator: "\n") + "\n"
        }
        tail += line(20, "[DEBUG] Forwarding event for session 4da0d54f: hook.start", from: now)
            + "\n"
        try handle.write(contentsOf: Data(tail.utf8))
        try handle.close()

        let started = Date()
        let measured = try XCTUnwrap(age(now: now))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(measured, 60)
        XCTAssertLessThan(
            elapsed, 1.0,
            "the scan must stop at the newest work line, not read the whole file")
    }

    /// A tail that is nothing but heartbeat for longer than the reader is willing to look
    /// still reports an age, and that age is a lower bound — never "unknown", never fresh.
    func testExhaustingTheScanBudgetStillReportsAnAgeInTheProtectiveDirection() throws {
        let now = Date()
        let reader = SessionLogReader(horizon: 6 * 3600, chunkSize: 4096, byteBudget: 16 * 1024)
        var lines: [String] = []
        for offset in stride(from: 3600.0, through: 30, by: -30) {
            lines += heartbeat(offset, from: now)
        }
        let path = try write("agency_copilot.log", lines)

        let bound = reader.activityBound(ofFileAt: path, now: now)
        guard case .noActivitySince(let date) = bound else {
            return XCTFail("expected a bounded verdict, got \(bound)")
        }
        // Only the last 16 KiB were read, so the bound is recent — protective, and honest
        // about how far back the reader actually looked.
        XCTAssertLessThan(now.timeIntervalSince(date), 3600)
        XCTAssertGreaterThan(now.timeIntervalSince(date), 0)
    }
}
