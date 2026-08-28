import Darwin
import XCTest

@testable import OpenZombrKit

/// The idle override, and the incident that forced it.
///
/// Wrapper 60581 was one of six reaped during the incident. Its live children were:
///
/// ```
/// 60640 60581 S   .../copilot --no-auto-update --log-dir ...
/// 93295 60581 Ss  .../agency send-telemetry-events --queue-file ...
/// ```
///
/// It had a live `copilot` child — a different executable — so a rule based purely on the
/// existence of a session child protects it. Killing it was nonetheless correct: it freed
/// 308 slots and the `copilot` child survived by reparenting to launchd. The session was
/// finished; the child had simply not exited. Existence of a child is not the signal.
/// Idleness is.
final class SessionIdleTests: XCTestCase {

    private let uid = Fixture.uid
    private let app: pid_t = 18826

    /// Rebuilds the wrapper 60581 shape and runs `hours` of polling against it.
    ///
    /// `cpuBurn` is added to the `copilot` child's CPU total on every poll, so a value of
    /// zero reproduces a finished session and a positive value reproduces a working one.
    private func poll(
        hours: Double,
        cpuBurn: TimeInterval,
        zombies: Int = 308
    ) -> (snapshot: ZombieSnapshot, policy: CleanupPolicy) {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: app, ppid: 1, name: "OpenZombr"),
            Fixture.process(pid: 60581, ppid: 1, name: "agency"),
            Fixture.process(pid: 60640, ppid: 60581, name: "copilot"),
            Fixture.process(pid: 93295, ppid: 60581, name: "agency"),
        ]
        entries += Fixture.zombies(count: zombies, ppid: 60581, startingPID: 30_000)

        let enumerator = StubProcessEnumerator(entries: entries, cpu: [60640: 74.48])
        let sampler = ZombieSampler(
            enumerator: enumerator, limitReader: StubLimitReader(limit: 4000),
            currentUID: uid, currentPID: app)
        let tracker = IdleTracker()

        // One poll a minute, as the app really runs.
        let polls = max(2, Int(hours * 60))
        var snapshot = ZombieSnapshot(
            timestamp: Fixture.epoch, uid: uid, totalProcesses: 0, zombieCount: 0,
            limit: 4000, offenders: [], protectedPIDs: [])
        for index in 0..<polls {
            let now = Fixture.epoch.addingTimeInterval(Double(index) * 60)
            enumerator.cpu[60640, default: 0] += cpuBurn
            let base = sampler.snapshot(from: entries, limit: 4000, now: now)
            snapshot = sampler.applyingIdle(
                to: base, entries: entries, tracker: tracker, now: now)
        }
        return (snapshot, CleanupPolicy(minimumZombiesPerParent: 100))
    }

    private func targets(_ result: (snapshot: ZombieSnapshot, policy: CleanupPolicy)) -> [pid_t] {
        ZombieReaper(currentUID: uid)
            .selectTargets(in: result.snapshot, policy: result.policy).targets.map(\.pid)
    }

    // MARK: - The incident

    /// Three hours idle, past the two-hour default: 60581 becomes reapable again.
    func testWrapperWithASessionChildIdleBeyondTheThresholdIsACandidate() {
        let result = poll(hours: 3, cpuBurn: 0)
        let wrapper = try! XCTUnwrap(result.snapshot.offenders.first { $0.pid == 60581 })

        XCTAssertEqual(wrapper.sessionChildCount, 1, "the copilot child is still there")
        XCTAssertEqual(wrapper.sessionChildPIDs, [60640])
        XCTAssertEqual(try XCTUnwrap(wrapper.sessionIdleSeconds), 3 * 3600, accuracy: 120)
        XCTAssertFalse(
            wrapper.isSessionActive(idleThreshold: CleanupPolicy.defaultSessionIdleThreshold))

        XCTAssertEqual(
            targets(result), [60581],
            "this is the wrapper that had to die during the incident")
    }

    /// One hour idle, below the default: still protected.
    func testTheSameWrapperBelowTheThresholdIsNotACandidate() {
        let result = poll(hours: 1, cpuBurn: 0)
        let wrapper = try! XCTUnwrap(result.snapshot.offenders.first { $0.pid == 60581 })

        XCTAssertEqual(try XCTUnwrap(wrapper.sessionIdleSeconds), 3600, accuracy: 120)
        XCTAssertTrue(
            wrapper.isSessionActive(idleThreshold: CleanupPolicy.defaultSessionIdleThreshold))
        XCTAssertTrue(targets(result).isEmpty)
    }

    /// A user between turns must never be reaped.
    ///
    /// Measured during the incident: sampling CPU over 20 s showed the user's own session
    /// child as idle, purely because they were mid-thought. Minutes of idleness must mean
    /// nothing at all.
    func testASessionIdleForMinutesIsNeverReaped() {
        for minutes in [1.0, 5.0, 20.0, 45.0] {
            let result = poll(hours: minutes / 60, cpuBurn: 0)
            XCTAssertTrue(
                targets(result).isEmpty,
                "\(minutes) minutes of idleness must not be enough")
        }
    }

    /// A session that is actually working never accumulates idle time. The burn rate is
    /// the one measured on the affected machine for a child doing real work: 7.45 s of CPU
    /// per 180 s, i.e. 2.48 s per one-minute poll.
    func testAWorkingSessionIsNeverReapedHoweverLongItRuns() {
        let result = poll(hours: 12, cpuBurn: 2.48)
        let wrapper = try! XCTUnwrap(result.snapshot.offenders.first { $0.pid == 60581 })

        XCTAssertEqual(wrapper.sessionIdleSeconds, 0, "CPU time rose on every poll")
        XCTAssertTrue(targets(result).isEmpty)
    }

    /// The measured heartbeat of a session that is merely between turns — 0.40 s per 180 s,
    /// i.e. 0.13 s per poll — must not keep the wrapper alive forever. Before activity was
    /// treated as a rate this reset the idle clock on every single poll, which made the
    /// override unable to ever fire.
    func testAHeartbeatingButFinishedSessionStillBecomesReapable() {
        let result = poll(hours: 3, cpuBurn: 0.13)
        let wrapper = try! XCTUnwrap(result.snapshot.offenders.first { $0.pid == 60581 })

        XCTAssertEqual(try XCTUnwrap(wrapper.sessionIdleSeconds), 3 * 3600, accuracy: 120)
        XCTAssertEqual(targets(result), [60581])
    }

    /// The wrapper's own telemetry self-spawn must not keep it alive, and must not be
    /// mistaken for a session even though it is live.
    func testTheTelemetrySelfSpawnIsIgnoredEntirely() {
        let result = poll(hours: 3, cpuBurn: 0)
        let wrapper = try! XCTUnwrap(result.snapshot.offenders.first { $0.pid == 60581 })
        XCTAssertEqual(wrapper.liveChildCount, 2, "copilot + the agency self-spawn")
        XCTAssertEqual(wrapper.sessionChildPIDs, [60640], "only copilot counts")
    }

    // MARK: - Bootstrap

    /// With no history there is no evidence of idleness, and no evidence must mean busy.
    func testUnknownIdlenessIsTreatedAsActive() {
        let parent = Fixture.parent(
            pid: 60581, zombieCount: 900, liveChildCount: 2, sessionChildCount: 1,
            sessionChildPIDs: [60640], sessionIdleSeconds: nil)
        XCTAssertTrue(parent.isSessionActive(idleThreshold: 2 * 3600))

        let snapshot = Fixture.snapshot(offenders: [parent], protectedPIDs: [1])
        let selection = ZombieReaper(currentUID: uid)
            .selectTargets(in: snapshot, policy: CleanupPolicy())
        XCTAssertEqual(selection.skipped.first?.reason, .hasActiveSession)
    }

    /// One unreadable child is enough to keep the whole parent protected.
    func testAParentIsIdleOnlyWhenEveryChildIsKnownToBeIdle() {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: app, ppid: 1, name: "OpenZombr"),
            Fixture.process(pid: 60581, ppid: 1, name: "agency"),
            Fixture.process(pid: 60640, ppid: 60581, name: "copilot"),
            Fixture.process(pid: 60650, ppid: 60581, name: "node"),
        ]
        entries += Fixture.zombies(count: 400, ppid: 60581, startingPID: 30_000)

        // 60650's CPU time cannot be read.
        let enumerator = StubProcessEnumerator(entries: entries, cpu: [60640: 10])
        let sampler = ZombieSampler(
            enumerator: enumerator, limitReader: StubLimitReader(limit: 4000),
            currentUID: uid, currentPID: app)
        let tracker = IdleTracker()

        var snapshot = sampler.snapshot(from: entries, limit: 4000, now: Fixture.epoch)
        for index in 0..<300 {
            let now = Fixture.epoch.addingTimeInterval(Double(index) * 60)
            snapshot = sampler.applyingIdle(
                to: sampler.snapshot(from: entries, limit: 4000, now: now),
                entries: entries, tracker: tracker, now: now)
        }

        let wrapper = try! XCTUnwrap(snapshot.offenders.first { $0.pid == 60581 })
        XCTAssertNil(wrapper.sessionIdleSeconds, "one unreadable child poisons the verdict")
        XCTAssertTrue(wrapper.isSessionActive(idleThreshold: 2 * 3600))
    }

    // MARK: - The override cannot bypass anything else

    /// An idle session must not unlock PID 1, a foreign uid, or the app's own ancestry.
    func testIdleOverrideCannotBypassTheUnconditionalProtections() {
        let idle: TimeInterval = 10 * 3600
        let ancestor = Fixture.parent(
            pid: 1332, zombieCount: 900, sessionChildCount: 1, sessionChildPIDs: [1394],
            sessionIdleSeconds: idle)
        let foreign = Fixture.parent(
            pid: 700, zombieCount: 900, uid: 0, sessionChildCount: 1,
            sessionChildPIDs: [701], sessionIdleSeconds: idle)
        let launchd = Fixture.parent(
            pid: 1, zombieCount: 900, sessionChildCount: 1, sessionChildPIDs: [2],
            sessionIdleSeconds: idle)

        let snapshot = Fixture.snapshot(
            offenders: [ancestor, foreign, launchd], protectedPIDs: [1, 1332, 18826])
        let selection = ZombieReaper(currentUID: uid)
            .selectTargets(in: snapshot, policy: CleanupPolicy())

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(
            Set(selection.skipped.map(\.reason)),
            [.protectedAncestor, .foreignUID, .initProcess])
    }

    /// An idle session does not exempt a parent from the zombie threshold or the
    /// allowlist either.
    func testIdleOverrideStillRespectsTheThresholdAndAllowlist() {
        let idle: TimeInterval = 10 * 3600
        let tooFew = Fixture.parent(
            pid: 60581, zombieCount: 4, sessionChildCount: 1, sessionChildPIDs: [60640],
            sessionIdleSeconds: idle)
        let notAllowed = Fixture.parent(
            pid: 60590, name: "Safari", path: "/Applications/Safari.app/Safari",
            zombieCount: 900, sessionChildCount: 1, sessionChildPIDs: [60650],
            sessionIdleSeconds: idle)

        let snapshot = Fixture.snapshot(
            offenders: [tooFew, notAllowed], protectedPIDs: [1])
        let selection = ZombieReaper(currentUID: uid)
            .selectTargets(in: snapshot, policy: CleanupPolicy())

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(
            Set(selection.skipped.map(\.reason)),
            [.belowZombieThreshold, .notPermittedByPolicy])
    }

    // MARK: - Tracker mechanics

    /// CPU time rising resets the clock; pid reuse discards the history.
    func testTrackerResetsOnActivityAndOnPIDReuse() {
        let tracker = IdleTracker()
        let start = Fixture.epoch
        let birth = start.addingTimeInterval(-10_000)

        XCTAssertNil(
            tracker.observe(pid: 60640, startTime: birth, cpuSeconds: 10, now: start),
            "first sighting is not evidence of anything")
        XCTAssertEqual(
            tracker.observe(
                pid: 60640, startTime: birth, cpuSeconds: 10,
                now: start.addingTimeInterval(3600)), 3600)
        XCTAssertEqual(
            tracker.observe(
                pid: 60640, startTime: birth, cpuSeconds: 11,
                now: start.addingTimeInterval(3660)), 0, "it ran, so the clock restarts")
        XCTAssertEqual(
            tracker.observe(
                pid: 60640, startTime: birth, cpuSeconds: 11,
                now: start.addingTimeInterval(7260)), 3600)

        // Same pid, different process.
        XCTAssertNil(
            tracker.observe(
                pid: 60640, startTime: start.addingTimeInterval(7000), cpuSeconds: 0,
                now: start.addingTimeInterval(7300)),
            "a recycled pid must not inherit the old process's idleness")
    }

    /// The tracker must not grow without bound on a machine spawning hundreds of
    /// processes a minute.
    func testTrackerPrunesDeadProcesses() {
        let tracker = IdleTracker()
        for pid in pid_t(100)...pid_t(200) {
            tracker.observe(
                pid: pid, startTime: Fixture.epoch, cpuSeconds: 1, now: Fixture.epoch)
        }
        XCTAssertEqual(tracker.trackedCount, 101)
        tracker.prune(keeping: [100, 101])
        XCTAssertEqual(tracker.trackedCount, 2)
        XCTAssertNil(tracker.idleDuration(for: 150, now: Fixture.epoch))
    }
}

/// Activity is a rate, not any change at all. The numbers here are the ones measured on
/// the affected machine over a 3 minute window.
final class IdleRateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    func testHeartbeatOfAnIdleSessionDoesNotResetTheIdleClock() {
        let tracker = IdleTracker()
        var now = start
        var cpu: TimeInterval = 87.20
        tracker.observe(pid: 1394, startTime: start, cpuSeconds: cpu, now: now)

        // 0.40 s per 180 s, the measured heartbeat of a session between turns.
        var idle: TimeInterval? = nil
        for _ in 0..<40 {
            now = now.addingTimeInterval(180)
            cpu += 0.40
            idle = tracker.observe(pid: 1394, startTime: start, cpuSeconds: cpu, now: now)
        }

        XCTAssertEqual(idle ?? 0, 7200, accuracy: 1,
                       "a heartbeat must accumulate idle time, not reset it")
    }

    func testWorkingSessionKeepsResettingTheIdleClock() {
        let tracker = IdleTracker()
        var now = start
        var cpu: TimeInterval = 44.94
        tracker.observe(pid: 17890, startTime: start, cpuSeconds: cpu, now: now)

        var idle: TimeInterval? = nil
        for _ in 0..<40 {
            now = now.addingTimeInterval(180)
            cpu += 7.45  // measured rate of a child doing real work
            idle = tracker.observe(pid: 17890, startTime: start, cpuSeconds: cpu, now: now)
        }

        XCTAssertEqual(idle, 0, "a working session must never look idle")
    }

    func testTrickleCannotCreepPastTheThresholdOnePollAtATime() {
        let tracker = IdleTracker()
        var now = start
        var cpu: TimeInterval = 10

        tracker.observe(pid: 42, startTime: start, cpuSeconds: cpu, now: now)
        // Each single poll is below the rate threshold, and the baseline must stay pinned
        // to the last real activity so the sum of them stays below it too.
        for _ in 0..<100 {
            now = now.addingTimeInterval(60)
            cpu += 0.5
            tracker.observe(pid: 42, startTime: start, cpuSeconds: cpu, now: now)
        }

        XCTAssertEqual(tracker.idleDuration(for: 42, now: now) ?? 0, 6000, accuracy: 1)
    }

    func testABurstOfRealWorkClearsAccumulatedIdle() {
        let tracker = IdleTracker()
        var now = start
        tracker.observe(pid: 7, startTime: start, cpuSeconds: 5, now: now)

        now = now.addingTimeInterval(10_000)
        XCTAssertEqual(tracker.observe(pid: 7, startTime: start, cpuSeconds: 5, now: now), 10_000)

        now = now.addingTimeInterval(60)
        XCTAssertEqual(tracker.observe(pid: 7, startTime: start, cpuSeconds: 45, now: now), 0,
                       "sustained CPU must count as work and clear the idle clock")
    }
}
