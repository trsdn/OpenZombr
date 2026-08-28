import Darwin
import XCTest

@testable import OpenZombrKit

final class EvidenceCSVLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenZombrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(maxBytes: UInt64 = 4 * 1024 * 1024) -> EvidenceCSVLog {
        EvidenceCSVLog(directory: directory, maxBytes: maxBytes, keepRotations: 2)
    }

    private func contents(of log: EvidenceCSVLog) throws -> [String] {
        try String(contentsOf: log.fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testWritesHeaderThenRows() throws {
        let log = makeLog()
        let snapshot = Fixture.snapshot(
            totalProcesses: 3869, zombieCount: 3326, limit: 4000,
            offenders: [Fixture.parent(pid: 87537, zombieCount: 600)])

        log.append(snapshot: snapshot, forecast: .unavailable)
        log.append(snapshot: snapshot, forecast: .unavailable)

        let lines = try contents(of: log)
        XCTAssertEqual(lines.first, EvidenceCSVLog.header)
        XCTAssertEqual(lines.count, 3)
    }

    func testRowCarriesTheEvidenceFields() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let snapshot = Fixture.snapshot(
            totalProcesses: 3869, zombieCount: 3326, limit: 4000,
            offenders: [Fixture.parent(pid: 87537, zombieCount: 600)])
        let forecast = ForkFailureForecast(
            slotsPerSecond: 10.0 / 60.0, secondsToExhaustion: 786, sampleCount: 5)

        let row = EvidenceCSVLog.row(
            snapshot: snapshot, forecast: forecast, action: "poll", result: "",
            formatter: formatter)
        let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(fields.count, EvidenceCSVLog.header.split(separator: ",").count)
        XCTAssertEqual(fields[1], "3869")
        XCTAssertEqual(fields[2], "3326")
        XCTAssertEqual(fields[3], "4000")
        XCTAssertEqual(fields[4], "96.7")
        XCTAssertEqual(fields[5], "131")
        XCTAssertEqual(fields[6], "10.00")
        XCTAssertEqual(fields[7], "786")
        XCTAssertEqual(fields[8], "87537")
        XCTAssertEqual(fields[9], "agency")
        XCTAssertEqual(fields[10], "600")
        XCTAssertEqual(fields[11], "no-session")
        XCTAssertEqual(fields[12], "poll")
    }

    /// A process name containing a comma would otherwise shift every following column.
    func testCommasInProcessNamesDoNotBreakTheColumns() {
        let formatter = ISO8601DateFormatter()
        let snapshot = Fixture.snapshot(
            offenders: [Fixture.parent(pid: 5, name: "we,ird\nname", zombieCount: 200)])
        let row = EvidenceCSVLog.row(
            snapshot: snapshot, forecast: .unavailable, action: "poll", result: "",
            formatter: formatter)

        XCTAssertEqual(
            row.split(separator: ",", omittingEmptySubsequences: false).count,
            EvidenceCSVLog.header.split(separator: ",").count)
        XCTAssertFalse(row.contains("\n"))
        XCTAssertTrue(row.contains("we;ird name"))
    }

    func testCleanupWritesOneRowPerTerminatedParent() throws {
        let log = makeLog()
        let snapshot = Fixture.snapshot(totalProcesses: 3869, zombieCount: 3326)
        let report = CleanupReport(
            startedAt: Fixture.epoch,
            results: [
                ReapResult(
                    parent: Fixture.parent(pid: 87537, zombieCount: 600),
                    outcome: .terminatedBySIGKILL, signalsSent: [SIGTERM, SIGKILL]),
                ReapResult(
                    parent: Fixture.parent(pid: 86183, zombieCount: 500),
                    outcome: .terminatedBySIGTERM, signalsSent: [SIGTERM]),
            ],
            skipped: [],
            zombiesBefore: 3326,
            zombiesAfter: 29,
            processesBefore: 3892,
            processesAfter: 565
        )

        log.append(report: report, snapshot: snapshot)

        let lines = try contents(of: log)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains("kill:15+9"))
        XCTAssertTrue(lines[1].contains("sigkill"))
        XCTAssertTrue(lines[1].contains("87537"))
        XCTAssertTrue(lines[1].contains("reaped=3297"))
        XCTAssertTrue(lines[1].contains("verified=true"))
        XCTAssertTrue(lines[2].contains("kill:15"))
        XCTAssertTrue(lines[2].contains("sigterm"))
    }

    func testRotatesWhenTheFileGrowsTooLarge() throws {
        let log = makeLog(maxBytes: 512)
        let snapshot = Fixture.snapshot(
            offenders: [Fixture.parent(pid: 1234, zombieCount: 300)])
        for _ in 0..<40 {
            log.append(snapshot: snapshot, forecast: .unavailable)
        }

        let rotated = log.fileURL.deletingPathExtension()
            .appendingPathExtension("1").appendingPathExtension("csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        // Rotation triggers on the write *after* the limit is passed, so the live file
        // is bounded rather than exactly under the limit.
        let size = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size]
        XCTAssertLessThan(size as! UInt64, 1024)
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        XCTAssertTrue(
            EvidenceCSVLog.defaultDirectory().path.hasSuffix("Application Support/OpenZombr"))
    }
}

extension EvidenceCSVLogTests {
    /// A log whose header predates a new column would otherwise put every following field
    /// under the wrong heading, which is fatal for something meant to be evidence.
    func testALogWrittenWithAnOlderHeaderIsRotatedAway() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openzombr-csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("zombie-evidence.csv")
        try "timestamp,total_procs,action,result\n2026-01-01T00:00:00Z,1,poll,\n"
            .write(to: url, atomically: true, encoding: .utf8)

        _ = EvidenceCSVLog(directory: directory)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the stale-schema log must be moved aside")
        let rotated = directory.appendingPathComponent("zombie-evidence.1.csv")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "and kept, not deleted — it is still evidence")
    }

    func testAMatchingHeaderIsLeftAlone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openzombr-csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("zombie-evidence.csv")
        try (EvidenceCSVLog.header + "\nrow\n").write(to: url, atomically: true, encoding: .utf8)

        _ = EvidenceCSVLog(directory: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("zombie-evidence.1.csv").path))
    }
}
