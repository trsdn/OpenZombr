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

    /// A candidate rejected by a later gate must not consume the run's single override,
    /// or one unrelated process would shield the real offender.
    func testARejectedCandidateDoesNotSpendTheOverrideBudget() {
        let stranger = Fixture.parent(
            pid: 5150, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            zombieCount: 5000, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [5151], sessionIdleSeconds: 10, sessionLogAgeSeconds: 10)

        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [stranger, busyOffender()]), policy: policy)

        XCTAssertEqual(selection.targets.map(\.pid), [28979])
        XCTAssertEqual(selection.emergencyOverrides, [28979])
    }

    // MARK: - Budget and ordering

    /// One per run. The next poll can take the next one, with fresh evidence.
    func testOnlyOneActiveParentIsOverriddenPerRun() {
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [
                busyOffender(pid: 28979, zombies: 526),
                busyOffender(pid: 31261, zombies: 402),
                busyOffender(pid: 29027, zombies: 203),
            ]),
            policy: policy
        )

        XCTAssertEqual(selection.targets.map(\.pid), [28979])
        XCTAssertEqual(selection.emergencyOverrides, [28979])
        XCTAssertEqual(
            selection.skipped.map(\.reason), [.emergencyBudgetSpent, .emergencyBudgetSpent])
    }

    /// "Protected because busy" and "protected because the one override was already spent"
    /// are different situations at zero free slots, and are reported as such.
    func testBudgetSpentIsItsOwnSkipReason() {
        let selection = reaper().selectTargets(
            in: atTheWall(offenders: [busyOffender(pid: 1), busyOffender(pid: 2)]),
            policy: policy
        )
        XCTAssertNotEqual(selection.skipped.map(\.reason), [.hasActiveSession, .hasActiveSession])
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

        XCTAssertEqual(selection.targets.map(\.pid), [18251])
        XCTAssertEqual(selection.emergencyOverrides, [18251])
    }

    /// The freshest session is only ever reached when it is the sole offender, because one
    /// override is spent per run and the stalest candidate always goes first.
    func testTheLiveSessionIsPickedLast() {
        let live = Fixture.parent(
            pid: 9126, zombieCount: 900, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [9127], sessionIdleSeconds: 0, sessionLogAgeSeconds: 16)
        let stale = Fixture.parent(
            pid: 18251, zombieCount: 101, liveChildCount: 1, sessionChildCount: 1,
            sessionChildPIDs: [18252], sessionIdleSeconds: 0, sessionLogAgeSeconds: 5206)

        XCTAssertEqual(
            reaper().selectTargets(in: atTheWall(offenders: [live, stale]), policy: policy)
                .targets.map(\.pid),
            [18251])

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

    // MARK: - Reporting

    /// An override must remain visible all the way out to the report and the menu, so a
    /// kill that broke the normal rules is never indistinguishable from an ordinary one.
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
