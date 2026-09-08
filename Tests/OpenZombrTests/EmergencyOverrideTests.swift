import Darwin
import XCTest

@testable import OpenZombrKit

/// The emergency override is the only thing in this app that can relax a protection, so
/// every boundary of it is pinned here. Each test corresponds to a way the override could
/// turn from a rescue into damage.
final class EmergencyOverrideTests: XCTestCase {
    private let policy = CleanupPolicy(
        minimumZombiesPerParent: 100,
        allowedNamePatterns: ["agency"],
        terminationGracePeriod: 2
    )

    private func reaper() -> ZombieReaper {
        ZombieReaper(
            signaller: FakeSignaller(alive: []), sleeper: FakeSleeper(), currentUID: Fixture.uid)
    }

    /// A parent whose session looks busy by both signals, holding a lot of zombies. This
    /// is pid 28979 from the incident: 526 zombies, `cpu_idle=1560`, `log_age=1607`.
    private func busyOffender(pid: pid_t = 28979, zombies: Int = 526) -> ZombieParent {
        Fixture.parent(
            pid: pid,
            zombieCount: zombies,
            liveChildCount: 1,
            sessionChildCount: 1,
            sessionChildPIDs: [pid + 1],
            sessionIdleSeconds: 1560,
            sessionLogAgeSeconds: 1607
        )
    }

    /// Free slots at or below the emergency fraction.
    private func atTheWall(offenders: [ZombieParent], protectedPIDs: Set<pid_t> = [1])
        -> ZombieSnapshot
    {
        Fixture.snapshot(
            totalProcesses: 2666, zombieCount: 2038, limit: 2666,
            offenders: offenders, protectedPIDs: protectedPIDs)
    }

    /// Plenty of room: the ordinary path.
    private func withRoom(offenders: [ZombieParent], protectedPIDs: Set<pid_t> = [1])
        -> ZombieSnapshot
    {
        Fixture.snapshot(
            totalProcesses: 1000, zombieCount: 500, limit: 4000,
            offenders: offenders, protectedPIDs: protectedPIDs)
    }

    // MARK: - The regression this exists for

    /// 22:42 on 2026-08-29: 2038 zombies, one wrapper holding 526 of them, and the manual
    /// cleanup logged `no-targets` because the wrapper's idle clock kept restarting and it
    /// never accumulated the required two hours.
    func testAtTheWallTheWorstActiveOffenderIsReaped() {
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [busyOffender()]), policy: policy)

        XCTAssertEqual(selection.targets.map(\.pid), [28979])
        XCTAssertEqual(selection.emergencyOverrides, [28979])
    }

    /// The same snapshot with room to spare must still spare it. The override is an
    /// emergency measure, not a quiet removal of the idle rule.
    func testWithRoomToSpareTheSameOffenderIsProtected() {
        let selection = reaper().selectTargets(
            in: withRoom(offenders: [busyOffender()]), policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertTrue(selection.emergencyOverrides.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .hasActiveSession)
    }

    func testOverrideCanBeSwitchedOffEntirely() {
        var disabled = policy
        disabled.emergencyOverrideEnabled = false

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [busyOffender()]), policy: disabled)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .hasActiveSession)
    }

    // MARK: - What the override may never do

    /// Absence of evidence must never read as evidence of idleness, and least of all under
    /// pressure. A parent whose idle signals could not be read stays protected at zero
    /// free slots, and keeps its own skip reason.
    func testBlindSignalsAreNeverOverridden() {
        let unreadable = Fixture.parent(
            pid: 31261,
            zombieCount: 900,
            liveChildCount: 1,
            sessionChildCount: 1,
            sessionChildPIDs: [31262],
            sessionIdleSeconds: nil,
            sessionLogAgeSeconds: nil
        )

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [unreadable]), policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertTrue(selection.emergencyOverrides.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .sessionSignalUnavailable)
    }

    /// The unconditional protections are applied before the override is even considered,
    /// so pressure cannot reach PID 1, another user's processes, or our own ancestry.
    func testUnconditionalProtectionsSurvivePressure() {
        let snapshot = atTheWall(
            offenders: [
                Fixture.parent(
                    pid: 1, name: "launchd", zombieCount: 5000, liveChildCount: 1,
                    sessionChildCount: 1, sessionChildPIDs: [2], sessionIdleSeconds: 10,
                    sessionLogAgeSeconds: 10),
                Fixture.parent(
                    pid: 4242, zombieCount: 900, uid: Fixture.otherUID, liveChildCount: 1,
                    sessionChildCount: 1, sessionChildPIDs: [4243], sessionIdleSeconds: 10,
                    sessionLogAgeSeconds: 10),
                busyOffender(pid: 87537, zombies: 600),
            ],
            protectedPIDs: [1, 87537]
        )

        let selection = reaper().selectTargets(in: snapshot, policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertTrue(selection.emergencyOverrides.isEmpty)
        XCTAssertEqual(
            Set(selection.skipped.map(\.reason)),
            [.initProcess, .foreignUID, .protectedAncestor])
    }

    /// The allowlist is not an idle rule and the override does not touch it.
    func testAllowlistStillAppliesUnderPressure() {
        let stranger = Fixture.parent(
            pid: 5150, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            zombieCount: 900, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [5151], sessionIdleSeconds: 10, sessionLogAgeSeconds: 10)

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [stranger]), policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .notPermittedByPolicy)
    }

    func testZombieThresholdStillAppliesUnderPressure() {
        let small = busyOffender(pid: 6000, zombies: 3)

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [small]), policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .belowZombieThreshold)
    }

    /// A candidate rejected by a later gate must not count towards the relief the override
    /// is trying to reach, or one unrelated process would shield the real offenders.
    func testARejectedCandidateDoesNotCountAsRelief() {
        // Stalest of the three, and huge, but not on the allowlist. If its zombies were
        // counted as relief the projection would be satisfied immediately and both real
        // offenders would be spared.
        let stranger = Fixture.parent(
            pid: 5150, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            zombieCount: 5000, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [5151], sessionIdleSeconds: 9000, sessionLogAgeSeconds: 9000)

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                stranger,
                busyOffender(pid: 28979, zombies: 526),
                busyOffender(pid: 31261, zombies: 402),
            ]),
            policy: policy
        )

        XCTAssertEqual(selection.targets.map(\.pid), [28979, 31261])
        XCTAssertEqual(selection.emergencyOverrides, [28979, 31261])
        XCTAssertEqual(selection.skipped.first?.reason, .notPermittedByPolicy)
    }

    // MARK: - How far the override goes

    /// Reaps until the machine is projected to be healthy again, rather than a fixed one
    /// per run.
    ///
    /// One per run was measured to lose the race. At 01:25 on 2026-08-30 the machine sat
    /// at 95 % with eight leaking wrappers; the single override freed 295 slots, leaving
    /// 84 % — still critical — while the leak grew at 93,5 slots/min, spending that relief
    /// again in about three minutes against a two-minute cooldown.
    func testTheOverrideReapsUntilTheProjectionIsHealthy() {
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                busyOffender(pid: 28979, zombies: 526),
                busyOffender(pid: 31261, zombies: 402),
                busyOffender(pid: 29027, zombies: 203),
            ]),
            policy: policy
        )

        // 2666 - 527 = 2139 (80 %, still critical) - 403 = 1736 (65 %), so the third is
        // no longer needed.
        XCTAssertEqual(selection.targets.map(\.pid), [28979, 31261])
        XCTAssertEqual(selection.emergencyOverrides, [28979, 31261])
        XCTAssertEqual(selection.skipped.map(\.reason), [.emergencyReliefReached])
    }

    /// Self-limiting in the other direction: when one parent is enough, exactly one is
    /// taken. This is the property that makes "reap until healthy" acceptable at all.
    func testWhenOneParentIsEnoughOnlyOneIsTaken() {
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                busyOffender(pid: 28979, zombies: 800),
                busyOffender(pid: 31261, zombies: 402),
            ]),
            policy: policy
        )

        // 2666 - 801 = 1865, which is 70 % — under the 75 % recovery target.
        XCTAssertEqual(selection.targets.map(\.pid), [28979])
        XCTAssertEqual(selection.skipped.map(\.reason), [.emergencyReliefReached])
    }

    /// The relief from ordinary idle reaps counts too, so an active session is never
    /// touched when the harmless targets already fix the problem.
    func testIdleReapsAloneCanMakeTheOverrideUnnecessary() {
        let idle = Fixture.parent(
            pid: 15428, zombieCount: 800, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [15429], sessionIdleSeconds: 20000, sessionLogAgeSeconds: 9000)

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [idle, busyOffender()]), policy: policy)

        XCTAssertEqual(selection.targets.map(\.pid), [15428])
        XCTAssertTrue(selection.emergencyOverrides.isEmpty)
        XCTAssertEqual(selection.skipped.map(\.reason), [.emergencyReliefReached])
    }

    /// The hard ceiling still applies: however far the machine is from healthy, one run
    /// may not exceed `maximumTargetsPerRun`.
    func testTheRunLimitStillCapsTheOverride() {
        var narrow = policy
        narrow.maximumTargetsPerRun = 2

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                busyOffender(pid: 1001, zombies: 200),
                busyOffender(pid: 1002, zombies: 190),
                busyOffender(pid: 1003, zombies: 180),
                busyOffender(pid: 1004, zombies: 170),
            ]),
            policy: narrow
        )

        XCTAssertEqual(selection.targets.count, 2)
        XCTAssertTrue(selection.skipped.allSatisfy { $0.reason == .runLimitReached })
    }

    /// "Protected because busy" and "protected because the machine is already projected to
    /// recover" are different situations at zero free slots, and are reported as such.
    func testReliefReachedIsItsOwnSkipReason() {
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                busyOffender(pid: 28979, zombies: 900),
                busyOffender(pid: 31261, zombies: 402),
            ]),
            policy: policy
        )

        XCTAssertEqual(selection.skipped.map(\.reason), [.emergencyReliefReached])
        XCTAssertFalse(selection.skipped.contains { $0.reason == .hasActiveSession })
    }

    /// Genuinely idle candidates are taken first, so the override is only ever spent once
    /// the harmless targets are exhausted.
    func testIdleCandidatesAreReapedBeforeTheOverrideIsSpent() {
        let idle = Fixture.parent(
            pid: 15428, zombieCount: 318, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [15429], sessionIdleSeconds: 9480, sessionLogAgeSeconds: 9515)

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [busyOffender(), idle]), policy: policy)

        XCTAssertEqual(selection.targets.map(\.pid), [15428, 28979])
        XCTAssertEqual(selection.emergencyOverrides, [28979])
    }

    /// The override picks the *least recently active* parent, not the biggest one.
    ///
    /// Measured live at 93 % usage while verifying this feature: three wrappers all read
    /// "active", holding 262 / 257 / 249 zombies, with session log ages of 16 s, 4736 s and
    /// 5206 s. Ranking by zombie count selected the 16-second-old one — the session the
    /// user was working in — to gain 13 zombies over one silent for 87 minutes.
    func testTheOverrideSacrificesTheStalestSessionNotTheBiggest() {
        func wrapper(pid: pid_t, zombies: Int, logAge: TimeInterval, cpuIdle: TimeInterval)
            -> ZombieParent
        {
            Fixture.parent(
                pid: pid, zombieCount: zombies, liveChildCount: 1, sessionChildCount: 1,
                sessionChildPIDs: [pid + 1], sessionIdleSeconds: cpuIdle,
                sessionLogAgeSeconds: logAge)
        }

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                wrapper(pid: 9126, zombies: 262, logAge: 16, cpuIdle: 0),
                wrapper(pid: 14515, zombies: 257, logAge: 4736, cpuIdle: 6),
                wrapper(pid: 18251, zombies: 249, logAge: 5206, cpuIdle: 0),
            ]),
            policy: policy
        )

        // Stalest first, and the session that spoke 16 seconds ago is reached last —
        // never first, however many zombies it holds.
        XCTAssertEqual(selection.targets.map(\.pid), [18251, 14515, 9126])
    }

    /// The freshest session is always considered last, so it survives whenever the staler
    /// ones provide enough relief on their own.
    func testTheLiveSessionIsPickedLast() {
        let live = Fixture.parent(
            pid: 9126, zombieCount: 900, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [9127], sessionIdleSeconds: 0, sessionLogAgeSeconds: 16)
        let stale = Fixture.parent(
            pid: 18251, zombieCount: 900, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [18252], sessionIdleSeconds: 0, sessionLogAgeSeconds: 5206)

        // The stale one alone is enough, so the live session is never signalled despite
        // holding just as many zombies.
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [live, stale]), policy: policy)
        XCTAssertEqual(selection.targets.map(\.pid), [18251])
        XCTAssertEqual(selection.skipped.map(\.reason), [.emergencyReliefReached])

        // Sole offender: then it is the live one's turn, because the alternative is a
        // machine that cannot fork at all.
        XCTAssertEqual(
            reaper().selectTargets(in: atTheWall(offenders: [live]), policy: policy)
                .targets.map(\.pid),
            [9126])
    }

    /// Ordering among *idle* candidates is unchanged: they are all safe to reap, so the
    /// one holding the most zombies still goes first.
    func testIdleCandidatesAreStillOrderedByZombieCount() {
        func finished(pid: pid_t, zombies: Int) -> ZombieParent {
            Fixture.parent(
                pid: pid, zombieCount: zombies, liveChildCount: 1, sessionChildCount: 1,
                sessionChildPIDs: [pid + 1], sessionIdleSeconds: 20000,
                sessionLogAgeSeconds: 9000)
        }

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [finished(pid: 100, zombies: 150), finished(pid: 200, zombies: 400)]),
            policy: policy
        )

        XCTAssertEqual(selection.targets.map(\.pid), [200, 100])
        XCTAssertTrue(selection.emergencyOverrides.isEmpty)
    }

    // MARK: - Recovery target

    /// The recovery target must sit below the point where the pressure trigger releases,
    /// or the override would declare success while still at the wall and fire again on the
    /// very next poll — reaping in a loop instead of reaching a stable state.
    func testTheRecoveryTargetIsCappedBelowThePressureTrigger() {
        let greedy = CleanupPolicy(
            emergencyFreeSlotFraction: 0.05, emergencyRecoveryUsageFraction: 0.99)
        XCTAssertEqual(greedy.emergencyRecoveryUsageFraction, 0.95, accuracy: 0.0001)

        // A sane target is left alone.
        let normal = CleanupPolicy(
            emergencyFreeSlotFraction: 0.05, emergencyRecoveryUsageFraction: 0.75)
        XCTAssertEqual(normal.emergencyRecoveryUsageFraction, 0.75, accuracy: 0.0001)
    }

    /// Replays the machine as it stood at 01:25:38 on 2026-08-30, when the user pressed
    /// "Jetzt aufräumen" and reported that little had been freed.
    ///
    /// 2534 processes against an effective limit of 2666 — 95 % — with eight leaking
    /// wrappers. The old one-per-run budget freed 295 slots and left the machine at 84 %,
    /// still critical, while the leak grew at 93,5 slots/min.
    func testTheIncidentIsResolvedInASingleRun() {
        let wrappers: [(pid_t, Int, TimeInterval)] = [
            (9126, 265, 7), (14515, 262, 4891), (18251, 254, 5206),
            (35106, 232, 4), (48751, 221, 60), (3679, 142, 3600),
            (3363, 142, 3500), (19414, 131, 120),
        ]
        let offenders = wrappers.map { pid, zombies, logAge in
            Fixture.parent(
                pid: pid, zombieCount: zombies, liveChildCount: 1, sessionChildCount: 1,
                sessionChildPIDs: [pid + 1], sessionIdleSeconds: 0,
                sessionLogAgeSeconds: logAge)
        }
        let snapshot = Fixture.snapshot(
            totalProcesses: 2534, zombieCount: 1642, limit: 2666,
            offenders: offenders, protectedPIDs: [1])

        let selection = reaper().selectTargets(in: snapshot, policy: policy)

        let freed = selection.targets.reduce(0) { $0 + $1.estimatedSlotsFreed }
        let projected = Double(snapshot.totalProcesses - freed) / Double(snapshot.limit)

        XCTAssertGreaterThan(selection.targets.count, 1, "one per run was not enough")
        XCTAssertLessThan(projected, 0.75, "the run must reach the recovery target")
        // Stalest first: the wrappers silent for over an hour go before the ones that
        // wrote seconds ago.
        XCTAssertEqual(selection.targets.prefix(3).map(\.pid), [18251, 14515, 3679])
        // And it stops there rather than clearing the table.
        XCTAssertLessThan(selection.targets.count, offenders.count)
    }

    // MARK: - Reporting
    func testOverrideIsCarriedIntoTheReport() {
        let target = busyOffender()
        let signaller = FakeSignaller(
            alive: [target.pid], lethalSignal: [target.pid: SIGKILL])
        let reaper = ZombieReaper(
            signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid)

        let results = reaper.terminate(
            [target], policy: policy, emergencyOverrides: [target.pid])
        let report = CleanupReport(
            startedAt: Fixture.epoch, results: results, skipped: [],
            zombiesBefore: 2038, zombiesAfter: 1512,
            processesBefore: 2666, processesAfter: 2139)

        XCTAssertTrue(results[0].wasEmergencyOverride)
        XCTAssertTrue(report.usedEmergencyOverride)
        XCTAssertTrue(report.germanSummary.hasPrefix("Notfall-Bereinigung: "))
    }

    func testOrdinaryReapIsNotLabelledAsAnOverride() {
        let target = Fixture.parent(pid: 15428, zombieCount: 318)
        let signaller = FakeSignaller(
            alive: [target.pid], lethalSignal: [target.pid: SIGKILL])
        let reaper = ZombieReaper(
            signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid)

        let results = reaper.terminate([target], policy: policy)
        let report = CleanupReport(
            startedAt: Fixture.epoch, results: results, skipped: [],
            zombiesBefore: 500, zombiesAfter: 182,
            processesBefore: 1000, processesAfter: 681)

        XCTAssertFalse(results[0].wasEmergencyOverride)
        XCTAssertFalse(report.usedEmergencyOverride)
        XCTAssertFalse(report.germanSummary.contains("Notfall"))
    }
}
