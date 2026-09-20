import Darwin
import XCTest

@testable import OpenZombrKit

/// Ordering, matching and bounding rules that used to be looser than the documents claim.
final class MatchingAndOrderingTests: XCTestCase {
    // MARK: - Candidate ordering

    /// A busy parent with an unreadable log age used to compare equal to one with an age of
    /// exactly 0 *without* falling through to the zombie count, while two unreadable ones did
    /// fall through. "Neither precedes the other" was then not transitive, which `sort`
    /// requires, and the resulting order depended on how the table happened to be laid out.
    func testOrderingIsAStrictWeakOrdering() {
        let busy = CleanupPolicy.defaultSessionIdleThreshold
        let a = Fixture.parent(
            pid: 10, zombieCount: 10, sessionChildCount: 1, sessionIdleSeconds: 5,
            sessionLogAgeSeconds: nil)
        let b = Fixture.parent(
            pid: 11, zombieCount: 5, sessionChildCount: 1, sessionIdleSeconds: 5,
            sessionLogAgeSeconds: 0)
        let c = Fixture.parent(
            pid: 12, zombieCount: 1, sessionChildCount: 1, sessionIdleSeconds: 5,
            sessionLogAgeSeconds: nil)

        func before(_ x: ZombieParent, _ y: ZombieParent) -> Bool {
            ZombieReaper.precedes(x, y, idleThreshold: busy)
        }
        let all = [a, b, c]
        for x in all {
            XCTAssertFalse(before(x, x), "irreflexive")
            for y in all {
                XCTAssertFalse(before(x, y) && before(y, x), "asymmetric")
                for z in all {
                    let xy = !before(x, y) && !before(y, x)
                    let yz = !before(y, z) && !before(z, y)
                    if xy && yz {
                        XCTAssertTrue(
                            !before(x, z) && !before(z, x),
                            "incomparability must be transitive: \(x.pid) \(y.pid) \(z.pid)")
                    }
                }
            }
        }
    }

    /// The rule the comparator exists for is unchanged: among busy parents the stalest log
    /// goes first, never the one with the most zombies.
    func testTheStalestBusyParentStillComesFirst() {
        let busy = CleanupPolicy.defaultSessionIdleThreshold
        let stale = Fixture.parent(
            pid: 10, zombieCount: 13, sessionChildCount: 1, sessionIdleSeconds: 5,
            sessionLogAgeSeconds: 5206)
        let fresh = Fixture.parent(
            pid: 11, zombieCount: 262, sessionChildCount: 1, sessionIdleSeconds: 5,
            sessionLogAgeSeconds: 16)
        XCTAssertTrue(ZombieReaper.precedes(stale, fresh, idleThreshold: busy))
        XCTAssertFalse(ZombieReaper.precedes(fresh, stale, idleThreshold: busy))
    }

    // MARK: - Allowlist matching

    /// The default pattern `agency` used to match any executable *under a directory* whose
    /// name contained it. A pattern without a path separator names a program, so it is
    /// matched against the process name and the executable's file name only.
    func testAPlainPatternDoesNotMatchADirectoryInThePath() {
        let policy = CleanupPolicy(allowedNamePatterns: ["agency"])
        let unrelated = Fixture.parent(
            pid: 20, name: "mytool", path: "/Users/x/agency-tools/mytool", zombieCount: 900)
        XCTAssertFalse(policy.permits(unrelated))
    }

    func testAPlainPatternStillMatchesTheNameAndTheFileName() {
        let policy = CleanupPolicy(allowedNamePatterns: ["agency"])
        XCTAssertTrue(policy.permits(Fixture.parent(pid: 20, zombieCount: 900)))
        // `p_comm` truncated or renamed, but the binary on disk is still `agency`.
        XCTAssertTrue(
            policy.permits(
                Fixture.parent(
                    pid: 21, name: "node", path: "/Users/x/bin/agency-wrapper", zombieCount: 900)))
    }

    /// A pattern that contains a `/` is a path fragment and is matched against the path, so
    /// users who scoped their allowlist by directory keep working.
    func testAPatternWithASlashMatchesAgainstThePath() {
        let policy = CleanupPolicy(allowedNamePatterns: ["/.config/agency/"])
        XCTAssertTrue(policy.permits(Fixture.parent(pid: 20, name: "x", zombieCount: 900)))
        XCTAssertFalse(
            policy.permits(
                Fixture.parent(pid: 21, name: "x", path: "/opt/other/x", zombieCount: 900)))
    }

    /// The veto stays as wide as it was: a deny entry anywhere in the name or path wins.
    func testTheDenylistStillMatchesAnywhereInTheFullText() {
        let policy = CleanupPolicy(
            allowedNamePatterns: ["agency"], deniedNamePatterns: ["CurrentVersion"])
        XCTAssertFalse(policy.permits(Fixture.parent(pid: 20, zombieCount: 900)))
    }

    // MARK: - Idle across system sleep

    /// Wall-clock idle time includes hours the Mac spent asleep, during which no session
    /// could burn CPU. Waking a laptop that slept overnight must not make a session the
    /// user was working in at midnight look eight hours idle.
    func testTimeSpentAsleepDoesNotCountAsIdle() {
        var awake: TimeInterval = 1000
        let tracker = IdleTracker(awakeClock: { awake })
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(tracker.observe(pid: 7, startTime: start, cpuSeconds: 10, now: start))
        awake += 60
        // Working, so the idle clock restarts here.
        XCTAssertEqual(
            tracker.observe(
                pid: 7, startTime: start, cpuSeconds: 40, now: start.addingTimeInterval(60)),
            0)

        // Eight hours pass on the wall clock; the machine was awake for 30 s of them.
        awake += 30
        let wake = start.addingTimeInterval(60 + 8 * 3600)
        let idle = tracker.observe(pid: 7, startTime: start, cpuSeconds: 40, now: wake)

        XCTAssertNotNil(idle)
        XCTAssertLessThan(idle ?? .infinity, 120, "asleep is not idle")
    }

    /// Without a clock the tracker behaves exactly as before, so every existing rule and
    /// test that advances `now` by hand is untouched.
    func testWithoutAnAwakeClockWallTimeIsUsed() {
        let tracker = IdleTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = tracker.observe(pid: 7, startTime: start, cpuSeconds: 10, now: start)
        let idle = tracker.observe(
            pid: 7, startTime: start, cpuSeconds: 10, now: start.addingTimeInterval(7200))
        XCTAssertEqual(idle ?? 0, 7200, accuracy: 0.001)
    }

    // MARK: - Files read per directory

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openzombr-matching-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func age(now: Date) -> TimeInterval? {
        let enumerator = StubProcessEnumerator(entries: [])
        enumerator.args = [42: ["copilot", "--log-dir", directory.path]]
        return SessionLogProbe(enumerator: enumerator).logAgeSeconds(for: 42, now: now)
    }

    private func writeLog(_ name: String, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func stamped(_ message: String, ago: TimeInterval, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: now.addingTimeInterval(-ago)) + " " + message
    }

    /// More recently-written files than the probe is willing to read means the cost is no
    /// longer bounded, and a truncated read could miss the one file that shows work. It must
    /// not guess: the directory is unknown, which protects the session.
    func testTooManyFilesToReadMakesTheDirectoryUnknown() throws {
        let now = Date()
        for index in 0..<(SessionLogProbe.maximumFilesRead + 1) {
            try writeLog(
                "session-\(index).log", lines: [stamped("INFO work", ago: 30, now: now)])
        }
        XCTAssertNil(age(now: now))
    }

    func testAnOrdinaryNumberOfFilesIsStillRead() throws {
        let now = Date()
        for index in 0..<5 {
            try writeLog(
                "session-\(index).log", lines: [stamped("INFO work", ago: 30, now: now)])
        }
        let measured = try XCTUnwrap(age(now: now))
        XCTAssertEqual(measured, 30, accuracy: 2)
    }
}
