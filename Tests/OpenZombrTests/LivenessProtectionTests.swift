import Darwin
import XCTest

@testable import OpenZombrKit

/// Protection that does not depend on how OpenZombr itself was started.
///
/// Ancestor protection only works while the app is a descendant of the process it must
/// not kill. Started by launchd at login the ancestor set collapses to `{self, 1}`, and
/// every wrapper in the user's session tree becomes a plain candidate. These tests pin
/// the liveness rule that has to carry the weight in that deployment, and they pin the
/// fact that ancestry is derived from the live table rather than remembered.
final class LivenessProtectionTests: XCTestCase {

    // MARK: - Ancestry is recomputed, never remembered

    /// A process that *used to* be an ancestor must not stay protected.
    ///
    /// This is the stale-snapshot failure mode: OpenZombr is launched from a shell inside
    /// an `agency` wrapper, so at that moment the wrapper is a genuine ancestor. The
    /// wrapper then stops being one. If the protected set were captured at startup the
    /// wrapper would be exempt forever while continuing to leak.
    func testFormerAncestorIsNotProtectedOnceItIsNoLongerAnAncestor() {
        let app: pid_t = 18826
        let wrapper: pid_t = 1332

        let whileDescendant = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: wrapper, ppid: 1, name: "agency"),
            Fixture.process(pid: app, ppid: wrapper, name: "OpenZombr"),
        ]
        XCTAssertTrue(
            ProcessProtection.protectedPIDs(of: app, in: whileDescendant).contains(wrapper),
            "while it really is an ancestor the wrapper must be protected")

        // Same app pid, same wrapper still running — but the app is now reparented to
        // launchd, exactly as it is when relaunched from the bundle or by login.
        let afterReparenting = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: wrapper, ppid: 1, name: "agency"),
            Fixture.process(pid: app, ppid: 1, name: "OpenZombr"),
        ]
        let protectedNow = ProcessProtection.protectedPIDs(of: app, in: afterReparenting)
        XCTAssertEqual(
            protectedNow, [app, 1],
            "the set must be derived from the current table, so a former ancestor drops out")
        XCTAssertFalse(protectedNow.contains(wrapper))
    }

    // MARK: - The launched-at-login deployment

    /// Under launchd the ancestor set protects nothing, so liveness must.
    func testWrapperHostingALiveSessionIsSparedWhenAncestryProtectsNothing() {
        let app: pid_t = 18826
        let entries = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: app, ppid: 1, name: "OpenZombr"),
            Fixture.process(pid: 1332, ppid: 1, name: "agency"),
            // The session child: a different executable, still running.
            Fixture.process(pid: 1394, ppid: 1332, name: "copilot"),
        ] + Fixture.zombies(count: 400, ppid: 1332, startingPID: 5000)

        let snapshot = ZombieSampler(currentUID: Fixture.uid, currentPID: app)
            .snapshot(from: entries, limit: 4000, now: Fixture.epoch)

        XCTAssertEqual(
            snapshot.protectedPIDs, [app, 1],
            "precondition: started by launchd, so ancestry protects nothing else")

        let wrapper = try! XCTUnwrap(snapshot.offenders.first { $0.pid == 1332 })
        XCTAssertEqual(wrapper.zombieCount, 400)
        XCTAssertEqual(wrapper.sessionChildCount, 1, "the copilot child counts as a session")
        XCTAssertTrue(wrapper.hasActiveSession)

        let selection = ZombieReaper(currentUID: Fixture.uid)
            .selectTargets(in: snapshot, policy: CleanupPolicy())

        XCTAssertTrue(
            selection.targets.isEmpty,
            "a wrapper hosting a live session must not be killed even at 400 zombies")
        XCTAssertEqual(selection.skipped.first?.parent.pid, 1332)
        XCTAssertEqual(selection.skipped.first?.reason, .hasActiveSession)
    }

    /// The leak's own children must not be mistaken for a session.
    ///
    /// Measured on the affected machine: the wrapper spawns `agency` telemetry children
    /// constantly, so "has live children" is true for every wrapper and discriminates
    /// nothing. Only a child of a *different* executable indicates real work.
    func testSelfSpawnedTelemetryChildrenDoNotCountAsASession() {
        let app: pid_t = 18826
        var entries = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: app, ppid: 1, name: "OpenZombr"),
            Fixture.process(pid: 86183, ppid: 1, name: "agency"),
        ]
        // Three live self-spawns, same comm as the parent — this is the leak in flight.
        entries += (0..<3).map {
            Fixture.process(pid: 22600 + pid_t($0), ppid: 86183, name: "agency")
        }
        entries += Fixture.zombies(count: 250, ppid: 86183, startingPID: 5000)

        let snapshot = ZombieSampler(currentUID: Fixture.uid, currentPID: app)
            .snapshot(from: entries, limit: 4000, now: Fixture.epoch)
        let wrapper = try! XCTUnwrap(snapshot.offenders.first { $0.pid == 86183 })

        XCTAssertEqual(wrapper.liveChildCount, 3, "the telemetry spawns are live children")
        XCTAssertEqual(wrapper.sessionChildCount, 0, "but they are not a session")
        XCTAssertFalse(wrapper.hasActiveSession)

        let selection = ZombieReaper(currentUID: Fixture.uid)
            .selectTargets(in: snapshot, policy: CleanupPolicy())
        XCTAssertEqual(
            selection.targets.map(\.pid), [86183],
            "a wrapper that only leaks is exactly what cleanup is for")
    }

    /// Idle wrappers are reaped before busy ones, so pressure is relieved by touching
    /// the least valuable process first.
    func testIdleWrappersAreConsideredBeforeOnesWithASession() {
        let busy = Fixture.parent(
            pid: 1332, zombieCount: 900, liveChildCount: 4, sessionChildCount: 1)
        let idle = Fixture.parent(
            pid: 86183, zombieCount: 150, liveChildCount: 2, sessionChildCount: 0)

        // Offenders arrive sorted by zombie count, so the busy one is first in the input.
        let snapshot = Fixture.snapshot(offenders: [busy, idle], protectedPIDs: [1])
        var policy = CleanupPolicy()
        policy.spareParentsWithActiveSession = false

        let selection = ZombieReaper(currentUID: Fixture.uid)
            .selectTargets(in: snapshot, policy: policy)

        XCTAssertEqual(
            selection.targets.map(\.pid), [86183, 1332],
            "the idle wrapper is preferred despite owning far fewer zombies")
    }

    /// Turning the guard off must be the only way to reach a session-hosting wrapper.
    func testSparingIsTheDefaultAndDisablingItIsWhatUnlocksTheWrapper() {
        let busy = Fixture.parent(
            pid: 1332, zombieCount: 900, liveChildCount: 2, sessionChildCount: 1)
        let snapshot = Fixture.snapshot(offenders: [busy], protectedPIDs: [1])
        let reaper = ZombieReaper(currentUID: Fixture.uid)

        XCTAssertTrue(CleanupPolicy().spareParentsWithActiveSession, "default is to spare")
        XCTAssertTrue(reaper.selectTargets(in: snapshot, policy: CleanupPolicy()).targets.isEmpty)

        var permissive = CleanupPolicy()
        permissive.spareParentsWithActiveSession = false
        XCTAssertEqual(
            reaper.selectTargets(in: snapshot, policy: permissive).targets.map(\.pid), [1332])
    }

    /// The liveness guard must not become a way around the unconditional protections.
    func testUnconditionalProtectionsStillWinWhenTheGuardIsDisabled() {
        var permissive = CleanupPolicy()
        permissive.spareParentsWithActiveSession = false

        let ownAncestor = Fixture.parent(pid: 1332, zombieCount: 900, sessionChildCount: 0)
        let foreign = Fixture.parent(pid: 700, zombieCount: 900, uid: 0, sessionChildCount: 0)
        let launchd = Fixture.parent(pid: 1, zombieCount: 900, sessionChildCount: 0)

        let snapshot = Fixture.snapshot(
            offenders: [ownAncestor, foreign, launchd], protectedPIDs: [1, 1332, 18826])
        let selection = ZombieReaper(currentUID: Fixture.uid)
            .selectTargets(in: snapshot, policy: permissive)

        XCTAssertTrue(
            selection.targets.isEmpty,
            "disabling the session guard must not unlock ancestry, uid or PID 1")
        XCTAssertEqual(
            Set(selection.skipped.map(\.reason)),
            [.protectedAncestor, .foreignUID, .initProcess])
    }

    /// Sanity: the guard is reached only after the cheap unconditional checks, so a
    /// protected ancestor is reported as such rather than as a session.
    func testProtectedAncestorReasonTakesPrecedenceOverTheSessionReason() {
        let parent = Fixture.parent(pid: 1332, zombieCount: 900, sessionChildCount: 1)
        let snapshot = Fixture.snapshot(offenders: [parent], protectedPIDs: [1, 1332])
        let selection = ZombieReaper(currentUID: Fixture.uid)
            .selectTargets(in: snapshot, policy: CleanupPolicy())
        XCTAssertEqual(selection.skipped.first?.reason, .protectedAncestor)
    }
}
