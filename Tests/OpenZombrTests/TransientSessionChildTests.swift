import Darwin
import XCTest

@testable import OpenZombrKit

/// A wrapper whose "session child" is not one persistent process but a rotating cast of
/// short-lived ones — `sh -c …`, `curl`, or similar helpers the leak itself spawns as part
/// of its own plumbing, each with a different name than the parent and each gone before the
/// next poll.
///
/// `IdleTracker.observe` can only report an idle duration once it has seen the *same* pid
/// twice; a child that never survives to a second poll never gets a second reading, so the
/// CPU signal for such a parent is unreadable forever, not just on the first poll. This is
/// audit finding 5. It was flagged as a possible flaw — an override that a churning cast of
/// helper children could permanently lock out — but AGENTS.md is explicit that "a parent
/// with unreadable idle signals is never overridden" is one of the boundaries the emergency
/// override may not cross, and that relaxing it needs the same kind of live measurement the
/// existing boundaries were built from, not reasoning about a hypothetical. No such
/// measurement exists for this scenario, so the behavior stays as designed: these tests pin
/// it down as intentional rather than changing it.
final class TransientSessionChildTests: XCTestCase {
    /// Builds one poll's entries: the parent, plus one session child whose pid is fresh
    /// every time `generation` changes — modelling a helper that has already exited by the
    /// time the next one is sampled.
    private func entries(parentPID: pid_t, generation: Int, now: Date) -> [ProcessEntry] {
        [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: parentPID, ppid: 1, name: "agency"),
            ProcessEntry(
                pid: 20_000 + pid_t(generation), ppid: parentPID, uid: Fixture.uid, name: "sh",
                isZombie: false, startTime: now),
        ]
    }

    /// Across many polls, none of which reuse a pid, the CPU idle signal never becomes
    /// readable: `sessionIdleSeconds` stays `nil`, which marks the signal unreadable rather
    /// than idle.
    func testARotatingCastOfHelpersNeverProducesAReadableCPUSignal() {
        let tracker = IdleTracker()
        var now = Fixture.epoch
        var last: ZombieParent?

        for generation in 0..<6 {
            let childPID = 20_000 + pid_t(generation)
            let table = entries(parentPID: 600, generation: generation, now: now)
            let enumerator = StubProcessEnumerator(entries: table, cpu: [childPID: 0.4])
            let sampler = ZombieSampler(
                enumerator: enumerator, limitReader: StubLimitReader(limit: 4000),
                currentUID: Fixture.uid, currentPID: 1)
            let offender = Fixture.parent(
                pid: 600, zombieCount: 500, sessionChildCount: 1, sessionChildPIDs: [childPID])
            let snapshot = Fixture.snapshot(offenders: [offender])

            let applied = sampler.applyingIdle(
                to: snapshot, entries: table, tracker: tracker, now: now)
            last = applied.offenders[0]
            now = now.addingTimeInterval(60)
        }

        XCTAssertNil(
            last?.sessionIdleSeconds,
            "a session child that is never sampled twice can never prove itself idle")
        XCTAssertTrue(last?.hasUnreadableSessionSignal ?? false)
    }

    /// Contrast case: the same tracker, the same cadence, but one child that persists across
    /// polls (e.g. `copilot`, hosting the user's actual session) does accumulate a readable
    /// idle duration. The rotating-helper case above is not a general defect in the idle
    /// mechanism — only a churning identity defeats it.
    func testAPersistentChildDoesProduceAReadableCPUSignal() {
        let tracker = IdleTracker()
        let start = Fixture.epoch
        var now = start
        let table = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 601, ppid: 1, name: "agency"),
            ProcessEntry(
                pid: 30_001, ppid: 601, uid: Fixture.uid, name: "copilot", isZombie: false,
                startTime: start),
        ]
        let enumerator = StubProcessEnumerator(entries: table, cpu: [30_001: 5.0])
        let sampler = ZombieSampler(
            enumerator: enumerator, limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid, currentPID: 1,
            // Isolates the CPU signal: the log signal has its own tests elsewhere, and an
            // unread one here would make `hasUnreadableSessionSignal` true regardless of
            // what this test is actually checking.
            logProbe: StubLogProbe(ages: [30_001: 30]))
        let offender = Fixture.parent(
            pid: 601, zombieCount: 500, sessionChildCount: 1, sessionChildPIDs: [30_001])
        let snapshot = Fixture.snapshot(offenders: [offender])

        var last: ZombieParent?
        for _ in 0..<3 {
            let applied = sampler.applyingIdle(
                to: snapshot, entries: table, tracker: tracker, now: now)
            last = applied.offenders[0]
            now = now.addingTimeInterval(3600)
        }

        XCTAssertNotNil(last?.sessionIdleSeconds)
        XCTAssertFalse(last?.hasUnreadableSessionSignal ?? true)
    }

    /// The override boundary this scenario exercises: even under pressure, a parent whose
    /// CPU signal is unreadable — churning children or otherwise — is never a candidate for
    /// the override, only for the ordinary idle path once it genuinely qualifies.
    func testTheEmergencyOverrideNeverReachesAParentWithAnUnreadableSignal() {
        let policy = CleanupPolicy(
            minimumZombiesPerParent: 100, allowedNamePatterns: ["agency"],
            emergencyOverrideEnabled: true, emergencyFreeSlotFraction: 0.5)
        let unreadable = Fixture.parent(
            pid: 600, zombieCount: 3000, sessionChildCount: 1, sessionChildPIDs: [20_000],
            sessionIdleSeconds: nil, sessionLogAgeSeconds: 9999)
        // 2 % free slots: well under pressure, so only the unreadable signal stands between
        // this parent and being taken.
        let snapshot = Fixture.snapshot(
            totalProcesses: 3920, zombieCount: 3000, limit: 4000, offenders: [unreadable])

        let selection = ZombieReaper().selectTargets(in: snapshot, policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(
            selection.skipped.first?.reason, SkipReason.sessionSignalUnavailable,
            "unreadable must never be overridden, however low free slots are")
    }
}
