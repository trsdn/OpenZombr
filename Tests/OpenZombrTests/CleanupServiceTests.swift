import Darwin
import XCTest

@testable import OpenZombrKit

final class CleanupServiceTests: XCTestCase {
    private let policy = CleanupPolicy(
        minimumZombiesPerParent: 100,
        allowedNamePatterns: ["agency"],
        terminationGracePeriod: 1
    )

    /// Builds a table with a leaking wrapper and returns a service whose verification
    /// re-sample sees `afterEntries`.
    private func makeService(
        beforeEntries: [ProcessEntry],
        afterEntries: [ProcessEntry],
        signaller: FakeSignaller
    ) -> (CleanupService, ZombieSnapshot) {
        let beforeSampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: beforeEntries),
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid,
            currentPID: 500
        )
        let afterSampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: afterEntries),
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid,
            currentPID: 500
        )
        let service = CleanupService(
            sampler: afterSampler,
            reaper: ZombieReaper(
                signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid),
            sleeper: FakeSleeper(),
            verificationDelay: 0
        )
        return (service, try! beforeSampler.sample(now: Fixture.epoch))
    }

    private var leakingTable: [ProcessEntry] {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 600, ppid: 600, startingPID: 10_000)
        return entries
    }

    private var cleanedTable: [ProcessEntry] {
        [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
        ]
    }

    /// The measured behaviour: SIGKILL the wrapper, the zombies get reparented to
    /// launchd and reaped instantly, and the slots come back.
    func testSuccessfulCleanupIsVerifiedAgainstAFreshReading() {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let (service, snapshot) = makeService(
            beforeEntries: leakingTable, afterEntries: cleanedTable, signaller: signaller)

        let report = service.run(on: snapshot, policy: policy, now: Fixture.epoch)

        XCTAssertEqual(report.results.map(\.parent.pid), [600])
        XCTAssertEqual(report.results.first?.outcome, .terminatedBySIGKILL)
        XCTAssertEqual(report.zombiesBefore, 600)
        XCTAssertEqual(report.zombiesAfter, 0)
        XCTAssertEqual(report.zombiesReaped, 600)
        // The wrapper's own slot comes back too, hence 601 rather than 600.
        XCTAssertEqual(report.slotsFreed, 601)
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.germanSummary, "600 Zombies aufgeräumt, 601 Slots frei.")
    }

    /// A run that signalled something but changed nothing is a failure, and must be
    /// reported as one rather than counted as a success.
    func testCleanupThatChangedNothingIsReportedAsIneffective() {
        let signaller = FakeSignaller(alive: [600])
        let (service, snapshot) = makeService(
            beforeEntries: leakingTable, afterEntries: leakingTable, signaller: signaller)

        let report = service.run(on: snapshot, policy: policy, now: Fixture.epoch)

        XCTAssertTrue(report.didAnything)
        XCTAssertFalse(report.verified)
        XCTAssertEqual(report.zombiesReaped, 0)
        XCTAssertEqual(report.results.first?.outcome, .survived)
        XCTAssertTrue(report.germanSummary.contains("ohne Wirkung"))
    }

    /// Nothing to do must send no signals at all — not even a "harmless" SIGTERM.
    func testNoTargetsMeansNoSignals() {
        let quiet: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
        ] + Fixture.zombies(count: 5, ppid: 600, startingPID: 10_000)

        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let (service, snapshot) = makeService(
            beforeEntries: quiet, afterEntries: quiet, signaller: signaller)

        let report = service.run(on: snapshot, policy: policy, now: Fixture.epoch)

        XCTAssertFalse(report.didAnything)
        XCTAssertTrue(signaller.deliveries.isEmpty)
        XCTAssertEqual(report.zombiesBefore, report.zombiesAfter)
        XCTAssertEqual(report.germanSummary, "Keine Kandidaten für die Bereinigung gefunden.")
        XCTAssertEqual(report.skipped.first?.reason, .belowZombieThreshold)
    }

    /// The whole reason auto-cleanup is safe *when it is allowed to act*: the wrapper's
    /// live child is not touched, and survives as an orphan reparented to launchd.
    ///
    /// This wrapper hosts a session, so the default policy spares it entirely. Reaching
    /// it at all requires deliberately disabling that guard, which is the documented
    /// decision the survivability of the child is supposed to justify.
    func testLiveChildrenOfATargetAreNeverSignalled() {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
            Fixture.process(pid: 601, ppid: 600, name: "copilot"),
        ]
        entries += Fixture.zombies(count: 600, ppid: 600, startingPID: 10_000)

        let spared = FakeSignaller(alive: [600, 601], lethalSignal: [600: SIGKILL])
        let (guarded, guardedSnapshot) = makeService(
            beforeEntries: entries, afterEntries: cleanedTable, signaller: spared)
        let guardedReport = guarded.run(on: guardedSnapshot, policy: policy, now: Fixture.epoch)
        XCTAssertTrue(
            spared.deliveries.isEmpty, "by default a wrapper with a live session is untouched")
        XCTAssertEqual(guardedReport.skipped.first?.reason, .hasActiveSession)

        var permissive = policy
        permissive.spareParentsWithActiveSession = false

        let signaller = FakeSignaller(alive: [600, 601], lethalSignal: [600: SIGKILL])
        let (service, snapshot) = makeService(
            beforeEntries: entries, afterEntries: cleanedTable, signaller: signaller)

        _ = service.run(on: snapshot, policy: permissive, now: Fixture.epoch)

        XCTAssertEqual(signaller.signalledPIDs, [600])
        XCTAssertTrue(signaller.isAlive(pid: 601))
    }
}
