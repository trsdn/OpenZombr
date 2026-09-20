import XCTest

@testable import OpenZombrKit

/// Rules that must hold when the evidence behind a decision is incomplete.
///
/// Each group pins one place where a fail-safe rule used to apply to only part of the data:
/// the denylist saw a path for only the 20 biggest offenders, a target that exited between
/// two checks was reported as a failed kill, and old log files were opened on every poll
/// although their `mtime` already proved they held nothing new.
final class PartialEvidenceTests: XCTestCase {
    // MARK: - Denylist on unresolved paths

    /// A path-based deny entry cannot be evaluated when the path is unknown. Reading that as
    /// "does not match" would make the denylist fail open exactly where it is blind, while
    /// the allowlist beside it fails closed.
    func testDenylistFailsClosedWhenThePathIsUnknown() {
        let policy = CleanupPolicy(
            allowedNamePatterns: ["agency"], deniedNamePatterns: ["/Applications/Foo.app"])
        let unresolved = Fixture.parent(pid: 20, path: nil, zombieCount: 900)
        XCTAssertFalse(policy.permits(unresolved))
    }

    /// Without a denylist there is nothing the missing path could have vetoed, so an
    /// unresolved path must not disable cleanup for everyone.
    func testUnknownPathStillPermitsWhenThereIsNoDenylist() {
        let policy = CleanupPolicy(allowedNamePatterns: ["agency"])
        XCTAssertTrue(policy.permits(Fixture.parent(pid: 20, path: nil, zombieCount: 900)))
    }

    /// The path used to be resolved for the first 20 offenders only, so the 21st was matched
    /// on its truncated 16-character `p_comm` alone.
    func testEveryOffenderGetsItsPathResolvedByDefault() {
        let parents = (0..<30).map {
            Fixture.process(pid: 1000 + pid_t($0), ppid: 1, name: "agency", zombie: false)
        }
        var entries = parents
        var paths: [pid_t: String] = [:]
        for parent in parents {
            entries += Fixture.zombies(count: 2, ppid: parent.pid, startingPID: 10_000 + parent.pid * 10)
            paths[parent.pid] = "/Users/x/agency"
        }
        let sampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: entries, paths: paths),
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid, currentPID: 1)
        let snapshot = sampler.snapshot(from: entries, limit: 4000, now: Fixture.epoch)

        XCTAssertEqual(snapshot.offenders.count, 30)
        XCTAssertTrue(snapshot.offenders.allSatisfy { $0.executablePath != nil })
    }

    // MARK: - A target that exits between two checks

    /// The target exits after `isAlive` but before the identity read. The kernel then has no
    /// entry, which reads as `.unreadable`. That is not a different process holding the pid;
    /// it is a process that is gone, and no signal may be sent to it either way.
    func testTargetThatExitsBeforeTheFirstSignalIsReportedAsGone() {
        let signaller = FakeSignaller(
            alive: [600], verifications: [600: .unreadable], exitsOnVerification: [600])
        let result = ZombieReaper(
            signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid
        ).terminate(Fixture.parent(pid: 600, zombieCount: 500), policy: CleanupPolicy())

        XCTAssertEqual(result.outcome, .alreadyGone)
        XCTAssertTrue(result.outcome.succeeded)
        XCTAssertTrue(signaller.deliveries.isEmpty)
    }

    /// Same window after the grace period: SIGTERM worked, and the process exited just before
    /// the escalation's identity read. That is a successful SIGTERM, not a failure.
    func testTargetThatExitsDuringTheGracePeriodCountsAsTerminated() {
        let signaller = FakeSignaller(
            alive: [600], verificationAfterFirstRead: [600: .unreadable],
            exitsOnSecondVerification: [600])
        let result = ZombieReaper(
            signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid
        ).terminate(Fixture.parent(pid: 600, zombieCount: 500), policy: CleanupPolicy())

        XCTAssertEqual(result.outcome, .terminatedBySIGTERM)
        XCTAssertEqual(result.signalsSent, [SIGTERM])
    }

    /// The fix must not weaken the guard: a process that is still alive and unreadable is
    /// not signalled.
    func testUnreadableIdentityOfALiveProcessStillBlocksTheSignal() {
        let signaller = FakeSignaller(alive: [600], verifications: [600: .unreadable])
        let result = ZombieReaper(
            signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid
        ).terminate(Fixture.parent(pid: 600, zombieCount: 500), policy: CleanupPolicy())

        XCTAssertEqual(result.outcome, .identityChanged)
        XCTAssertTrue(signaller.deliveries.isEmpty)
    }

    // MARK: - Old log files

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openzombr-partial-\(UUID().uuidString)")
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

    /// `mtime` can be wrong in the direction of "too recent" — the heartbeat refreshes it —
    /// but never in the direction of "too old": nothing can have been written after it. A
    /// file untouched for longer than the horizon therefore needs no read at all, which is
    /// what keeps the per-poll cost bounded on a directory that accumulates logs. Content
    /// that cannot be parsed proves the file was not opened.
    func testAFileUntouchedBeyondTheHorizonIsNotOpened() throws {
        let now = Date()
        let path = directory.appendingPathComponent("old.log")
        try "no timestamp anywhere\n".write(to: path, atomically: true, encoding: .utf8)
        let old = now.addingTimeInterval(-SessionLogReader.defaultHorizon - 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)

        let measured = try XCTUnwrap(age(now: now))
        XCTAssertGreaterThanOrEqual(measured, SessionLogReader.defaultHorizon)
    }

    /// The shortcut must not become a way to hide recent work: a fresh file with the same
    /// unreadable content still makes the whole directory unknown, which protects.
    func testAFreshUnreadableFileStillMakesTheDirectoryUnknown() throws {
        let path = directory.appendingPathComponent("fresh.log")
        try "no timestamp anywhere\n".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertNil(age(now: Date()))
    }

    /// An old file must not drag a directory that also holds a recent one towards idle.
    func testARecentFileStillDominatesOldOnes() throws {
        let now = Date()
        let old = directory.appendingPathComponent("old.log")
        try "x\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 3600)], ofItemAtPath: old.path)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        let recent = directory.appendingPathComponent("recent.log")
        try (stamp.string(from: now.addingTimeInterval(-30)) + " INFO tool call\n")
            .write(to: recent, atomically: true, encoding: .utf8)

        let measured = try XCTUnwrap(age(now: now))
        XCTAssertLessThan(measured, 120)
    }
}
