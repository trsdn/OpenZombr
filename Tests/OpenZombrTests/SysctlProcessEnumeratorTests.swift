import XCTest

@testable import OpenZombrKit

/// Smoke tests against the real machine. These verify that the sysctl reader agrees with
/// reality; they deliberately assert only invariants that hold on any Mac, because the
/// process table changes between every call.
final class SysctlProcessEnumeratorTests: XCTestCase {
    private let enumerator = SysctlProcessEnumerator()

    func testReadsAPlausibleProcessTable() throws {
        let entries = try enumerator.enumerateProcesses()
        XCTAssertGreaterThan(entries.count, 10)

        // launchd is always there, is pid 1, and is owned by root.
        let launchd = try XCTUnwrap(entries.first { $0.pid == 1 })
        XCTAssertEqual(launchd.name, "launchd")
        XCTAssertEqual(launchd.uid, 0)
        XCTAssertFalse(launchd.isZombie)

        // This test process must appear, owned by us, and must not be a zombie.
        let ourself = try XCTUnwrap(entries.first { $0.pid == getpid() })
        XCTAssertEqual(ourself.uid, getuid())
        XCTAssertFalse(ourself.isZombie)
        XCTAssertEqual(ourself.ppid, getppid())

        XCTAssertTrue(entries.allSatisfy { $0.pid >= 0 })
        XCTAssertTrue(entries.allSatisfy { $0.startTime.timeIntervalSince1970 > 0 })

        // macOS really does expose a pid 0 (the kernel task). It must never be a
        // cleanup target, which is why the reaper's guard is `pid <= 1`, not `pid == 1`.
        if let kernel = entries.first(where: { $0.pid == 0 }) {
            XCTAssertEqual(kernel.uid, 0)
            let snapshot = Fixture.snapshot(
                offenders: [
                    Fixture.parent(pid: 0, name: kernel.name, zombieCount: 9999, uid: getuid())
                ],
                protectedPIDs: [1]
            )
            let targets = ZombieReaper(currentUID: getuid())
                .selectTargets(
                    in: snapshot,
                    policy: CleanupPolicy(allowedNamePatterns: [kernel.name])
                )
                .targets
            XCTAssertTrue(targets.isEmpty)
        }
    }

    func testResolvesOurOwnExecutablePath() throws {
        let path = try XCTUnwrap(enumerator.executablePath(for: getpid()))
        XCTAssertTrue(path.hasPrefix("/"))
    }

    func testReturnsNoPathForAnImpossiblePID() {
        XCTAssertNil(enumerator.executablePath(for: pid_t.max))
    }

    func testReadsTheRealPerUIDLimit() throws {
        let reader = SysctlProcessLimitReader()
        let perUID = try reader.maximumProcessesPerUID()
        let systemWide = try reader.maximumProcesses()

        XCTAssertGreaterThan(perUID, 0)
        XCTAssertLessThanOrEqual(perUID, systemWide)
    }

    /// End-to-end against the live machine: the snapshot must be internally consistent
    /// and must classify without throwing.
    func testLiveSampleIsInternallyConsistent() throws {
        let snapshot = try ZombieSampler().sample()

        XCTAssertEqual(snapshot.uid, getuid())
        XCTAssertGreaterThan(snapshot.totalProcesses, 0)
        XCTAssertGreaterThan(snapshot.limit, 0)
        XCTAssertGreaterThanOrEqual(snapshot.zombieCount, 0)
        XCTAssertLessThanOrEqual(snapshot.zombieCount, snapshot.totalProcesses)
        XCTAssertEqual(
            snapshot.liveProcesses + snapshot.zombieCount, snapshot.totalProcesses)
        XCTAssertEqual(
            snapshot.offenders.reduce(0) { $0 + $1.zombieCount }, snapshot.zombieCount)

        // Our own process and its ancestors must always be protected.
        XCTAssertTrue(snapshot.protectedPIDs.contains(getpid()))
        XCTAssertTrue(snapshot.protectedPIDs.contains(getppid()))
        XCTAssertTrue(snapshot.protectedPIDs.contains(1))

        // And no protected pid may ever be selected as a cleanup target.
        let targets = ZombieReaper().selectTargets(in: snapshot, policy: CleanupPolicy()).targets
        XCTAssertTrue(Set(targets.map(\.pid)).isDisjoint(with: snapshot.protectedPIDs))
        XCTAssertTrue(targets.allSatisfy { $0.uid == getuid() })
        XCTAssertTrue(targets.allSatisfy { $0.pid > 1 })
    }
}
