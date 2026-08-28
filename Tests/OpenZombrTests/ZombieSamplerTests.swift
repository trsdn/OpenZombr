import XCTest

@testable import OpenZombrKit

final class ZombieSamplerTests: XCTestCase {
    private func sampler(
        entries: [ProcessEntry],
        paths: [pid_t: String] = [:],
        limit: Int = 4000,
        currentPID: pid_t = 500
    ) -> ZombieSampler {
        ZombieSampler(
            enumerator: StubProcessEnumerator(entries: entries, paths: paths),
            limitReader: StubLimitReader(limit: limit),
            currentUID: Fixture.uid,
            currentPID: currentPID
        )
    }

    func testCountsOnlyProcessesOwnedByTheCurrentUID() {
        var entries = [
            Fixture.process(pid: 500, ppid: 1),
            Fixture.process(pid: 501, ppid: 1, uid: Fixture.otherUID),
        ]
        entries += Fixture.zombies(count: 10, ppid: 500, startingPID: 1000)
        entries += Fixture.zombies(count: 7, ppid: 501, startingPID: 2000, uid: Fixture.otherUID)

        let snapshot = try! sampler(entries: entries).sample(now: Fixture.epoch)
        XCTAssertEqual(snapshot.totalProcesses, 11)
        XCTAssertEqual(snapshot.zombieCount, 10)
        XCTAssertEqual(snapshot.liveProcesses, 1)
    }

    /// Zombies occupy process-table slots, so they must be part of the total that is
    /// compared against the limit — not subtracted from it.
    func testZombiesCountTowardsTheLimit() {
        var entries = [Fixture.process(pid: 500, ppid: 1)]
        entries += Fixture.zombies(count: 999, ppid: 500, startingPID: 1000)

        let snapshot = try! sampler(entries: entries, limit: 4000).sample(now: Fixture.epoch)
        XCTAssertEqual(snapshot.totalProcesses, 1000)
        XCTAssertEqual(snapshot.usageFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.freeSlots, 3000)
        XCTAssertEqual(snapshot.zombieFraction, 999.0 / 4000.0, accuracy: 0.0001)
    }

    func testOffendersAreSortedByZombieCountThenPID() {
        var entries = [
            Fixture.process(pid: 500, ppid: 1),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
            Fixture.process(pid: 700, ppid: 1, name: "agency"),
            Fixture.process(pid: 800, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 5, ppid: 600, startingPID: 10_000)
        entries += Fixture.zombies(count: 20, ppid: 700, startingPID: 20_000)
        entries += Fixture.zombies(count: 20, ppid: 800, startingPID: 30_000)

        let snapshot = try! sampler(entries: entries).sample(now: Fixture.epoch)
        XCTAssertEqual(snapshot.offenders.map(\.pid), [700, 800, 600])
        XCTAssertEqual(snapshot.offenders.map(\.zombieCount), [20, 20, 5])
        XCTAssertEqual(snapshot.topOffender?.pid, 700)
    }

    func testResolvesExecutablePathsForOffenders() {
        var entries = [
            Fixture.process(pid: 500, ppid: 1),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 3, ppid: 600, startingPID: 10_000)

        let snapshot = try! sampler(
            entries: entries, paths: [600: "/Users/x/.config/agency/CurrentVersion/agency"]
        ).sample(now: Fixture.epoch)

        XCTAssertEqual(
            snapshot.topOffender?.executablePath,
            "/Users/x/.config/agency/CurrentVersion/agency")
    }

    /// A parent that has already exited leaves its zombies behind with a ppid that is no
    /// longer in the table. That must not crash or be dropped.
    func testHandlesZombiesWhoseParentIsMissingFromTheTable() {
        let entries =
            [Fixture.process(pid: 500, ppid: 1)]
            + Fixture.zombies(count: 4, ppid: 9999, startingPID: 10_000)

        let snapshot = try! sampler(entries: entries).sample(now: Fixture.epoch)
        XCTAssertEqual(snapshot.zombieCount, 4)
        XCTAssertEqual(snapshot.topOffender?.pid, 9999)
        XCTAssertEqual(snapshot.topOffender?.name, "unbekannt")
    }

    func testSnapshotCarriesTheProtectedAncestorChain() {
        let entries = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 100, ppid: 1),
            Fixture.process(pid: 200, ppid: 100),
            Fixture.process(pid: 300, ppid: 200),
            Fixture.process(pid: 400, ppid: 1),
        ]
        let snapshot = try! sampler(entries: entries, currentPID: 300).sample(now: Fixture.epoch)
        XCTAssertEqual(snapshot.protectedPIDs, [300, 200, 100, 1])
        XCTAssertFalse(snapshot.protectedPIDs.contains(400))
    }

    func testUsageFractionIsSafeWhenLimitIsZero() {
        let snapshot = Fixture.snapshot(totalProcesses: 100, limit: 0)
        XCTAssertEqual(snapshot.usageFraction, 0)
        XCTAssertEqual(snapshot.freeSlots, 0)
    }
}
