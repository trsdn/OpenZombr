import Darwin
import XCTest

@testable import OpenZombrKit

/// These tests exist to make the safety rules impossible to regress silently. Every one
/// of them corresponds to a way this app could damage a running system.
final class ReaperSafetyTests: XCTestCase {
    private let policy = CleanupPolicy(
        minimumZombiesPerParent: 100,
        allowedNamePatterns: ["agency"],
        terminationGracePeriod: 2
    )

    private func reaper(signaller: FakeSignaller = FakeSignaller(alive: []), sleeper: FakeSleeper = FakeSleeper())
        -> ZombieReaper
    {
        ZombieReaper(signaller: signaller, sleeper: sleeper, currentUID: Fixture.uid)
    }

    // MARK: - PID 1

    func testNeverTargetsPIDOne() {
        let snapshot = Fixture.snapshot(
            offenders: [Fixture.parent(pid: 1, name: "launchd", zombieCount: 5000)],
            protectedPIDs: [1, 99]
        )
        let selection = reaper().selectTargets(in: snapshot, policy: policy)
        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .initProcess)
    }

    /// Belt and braces: even if selection were bypassed, the signal sender itself
    /// refuses to signal PID 1 or below.
    func testSignalSenderRefusesPIDOne() {
        let sender = POSIXSignalSender()
        XCTAssertFalse(sender.send(signal: SIGKILL, to: 1))
        XCTAssertFalse(sender.send(signal: SIGKILL, to: 0))
        XCTAssertFalse(sender.send(signal: SIGKILL, to: -1))
    }

    // MARK: - Ownership

    func testNeverTargetsProcessesOwnedByAnotherUID() {
        let snapshot = Fixture.snapshot(
            offenders: [
                Fixture.parent(pid: 4242, zombieCount: 900, uid: Fixture.otherUID)
            ],
            protectedPIDs: [1]
        )
        let selection = reaper().selectTargets(in: snapshot, policy: policy)
        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .foreignUID)
    }

    // MARK: - Self and ancestors

    /// The real near-miss: the user's live chain was
    /// bash → copilot(87594) → agency copilot(87537) → GitHub Copilot.app(4264).
    /// PID 87537 is an `agency` wrapper holding 600 zombies — a perfect target by every
    /// other rule — and killing it would have severed the user's session.
    func testNeverTargetsOwnAncestorsEvenWhenTheyAreTheWorstOffender() {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 4264, ppid: 1, name: "github"),
            Fixture.process(pid: 87537, ppid: 4264, name: "agency"),
            Fixture.process(pid: 87594, ppid: 87537, name: "copilot"),
            Fixture.process(pid: 90000, ppid: 87594, name: "bash"),
            // An unrelated wrapper that is not an ancestor.
            Fixture.process(pid: 55555, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 600, ppid: 87537, startingPID: 200_000)
        entries += Fixture.zombies(count: 300, ppid: 55555, startingPID: 300_000)

        let sampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: entries),
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid,
            currentPID: 90000
        )
        let snapshot = try! sampler.sample(now: Fixture.epoch)

        XCTAssertEqual(snapshot.protectedPIDs, [90000, 87594, 87537, 4264, 1])
        // The ancestor is the biggest offender, so this proves ordering does not win
        // over protection.
        XCTAssertEqual(snapshot.topOffender?.pid, 87537)

        let selection = reaper().selectTargets(in: snapshot, policy: policy)
        XCTAssertEqual(selection.targets.map(\.pid), [55555])
        XCTAssertTrue(
            selection.skipped.contains { $0.parent.pid == 87537 && $0.reason == .protectedAncestor })
    }

    func testProtectionWalkSurvivesCyclicParentLinks() {
        let entries = [
            Fixture.process(pid: 10, ppid: 20),
            Fixture.process(pid: 20, ppid: 10),
        ]
        let protected = ProcessProtection.protectedPIDs(of: 10, in: entries)
        XCTAssertEqual(protected, [10, 20, 1])
    }

    func testProtectionAlwaysIncludesInitEvenIfAbsentFromTable() {
        let protected = ProcessProtection.protectedPIDs(of: 77, in: [])
        XCTAssertEqual(protected, [77, 1])
    }

    // MARK: - Zombies are never the target

    /// A zombie cannot be killed: `kill -9` on it is a no-op. Targeting one would be
    /// pure noise, and killing a *parent* that is itself a zombie is equally pointless.
    func testZombiesThemselvesAreNeverSignalled() {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 500, name: "agency"),
        ]
        let zombies = Fixture.zombies(count: 400, ppid: 600, startingPID: 10_000)
        entries += zombies

        let sampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: entries),
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid,
            currentPID: 500
        )
        let snapshot = try! sampler.sample(now: Fixture.epoch)

        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let reaper = self.reaper(signaller: signaller)
        let selection = reaper.selectTargets(in: snapshot, policy: policy)
        _ = reaper.terminate(selection.targets, policy: policy)

        let zombiePIDs = Set(zombies.map(\.pid))
        XCTAssertTrue(signaller.signalledPIDs.isDisjoint(with: zombiePIDs))
        XCTAssertEqual(signaller.signalledPIDs, [600])
    }

    func testParentThatIsItselfAZombieIsSkipped() {
        let snapshot = Fixture.snapshot(
            offenders: [Fixture.parent(pid: 700, zombieCount: 900, parentIsZombie: true)]
        )
        let selection = reaper().selectTargets(in: snapshot, policy: policy)
        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .parentIsZombie)
    }

    // MARK: - Zombie threshold

    func testOnlyParentsAboveTheZombieThresholdAreTargeted() {
        let snapshot = Fixture.snapshot(
            offenders: [
                Fixture.parent(pid: 10, zombieCount: 150),
                Fixture.parent(pid: 11, zombieCount: 100),
                Fixture.parent(pid: 12, zombieCount: 99),
                Fixture.parent(pid: 13, zombieCount: 1),
            ]
        )
        let selection = reaper().selectTargets(in: snapshot, policy: policy)
        // Boundary is inclusive: exactly 100 qualifies, 99 does not.
        XCTAssertEqual(selection.targets.map(\.pid), [10, 11])
        XCTAssertEqual(
            selection.skipped.filter { $0.reason == .belowZombieThreshold }.map(\.parent.pid),
            [12, 13])
    }

    // MARK: - Allow / deny lists

    func testDenylistOverridesAllowlist() {
        let denying = CleanupPolicy(
            minimumZombiesPerParent: 100,
            allowedNamePatterns: ["agency"],
            deniedNamePatterns: ["CurrentVersion"]
        )
        let snapshot = Fixture.snapshot(offenders: [Fixture.parent(pid: 20, zombieCount: 900)])
        let selection = reaper().selectTargets(in: snapshot, policy: denying)
        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .notPermittedByPolicy)
    }

    func testUnrelatedProcessesAreNotTargetedByTheDefaultAllowlist() {
        let snapshot = Fixture.snapshot(
            offenders: [
                Fixture.parent(pid: 30, name: "Xcode", path: "/Applications/Xcode.app", zombieCount: 3000)
            ]
        )
        let selection = reaper().selectTargets(in: snapshot, policy: policy)
        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .notPermittedByPolicy)
    }

    /// Fail-closed: clearing the allowlist disables cleanup rather than allowing
    /// everything.
    func testEmptyAllowlistMatchesNothing() {
        let empty = CleanupPolicy(minimumZombiesPerParent: 1, allowedNamePatterns: [])
        XCTAssertFalse(empty.permits(Fixture.parent(pid: 40, zombieCount: 500)))

        let snapshot = Fixture.snapshot(offenders: [Fixture.parent(pid: 40, zombieCount: 500)])
        XCTAssertTrue(reaper().selectTargets(in: snapshot, policy: empty).targets.isEmpty)
    }

    func testMatchingIsCaseInsensitiveAndCoversThePath() {
        let byPath = CleanupPolicy(
            minimumZombiesPerParent: 1, allowedNamePatterns: [".config/AGENCY"])
        XCTAssertTrue(byPath.permits(Fixture.parent(pid: 41, name: "wrapper", zombieCount: 5)))
    }

    func testRunLimitCapsTheNumberOfTargets() {
        let capped = CleanupPolicy(
            minimumZombiesPerParent: 10, allowedNamePatterns: ["agency"], maximumTargetsPerRun: 2)
        let snapshot = Fixture.snapshot(
            offenders: (1...5).map { Fixture.parent(pid: pid_t(50 + $0), zombieCount: 500) }
        )
        let selection = reaper().selectTargets(in: snapshot, policy: capped)
        XCTAssertEqual(selection.targets.count, 2)
        XCTAssertEqual(selection.skipped.filter { $0.reason == .runLimitReached }.count, 3)
    }

    // MARK: - Signal escalation

    /// SIGTERM must be attempted first. The known offender ignores it, but a
    /// better-behaved parent deserves a clean shutdown, and "SIGKILL first" would be a
    /// silent regression.
    func testSIGTERMIsSentBeforeSIGKILL() {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let sleeper = FakeSleeper()
        let result = reaper(signaller: signaller, sleeper: sleeper)
            .terminate(Fixture.parent(pid: 600, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.signalsSent, [SIGTERM, SIGKILL])
        XCTAssertEqual(signaller.signals(for: 600), [SIGTERM, SIGKILL])
        XCTAssertEqual(result.outcome, .terminatedBySIGKILL)
        // The grace period must actually elapse between the two signals.
        XCTAssertEqual(sleeper.intervals.first, policy.terminationGracePeriod)
    }

    func testSIGKILLIsNotSentWhenSIGTERMAlreadyWorked() {
        let signaller = FakeSignaller(alive: [601], lethalSignal: [601: SIGTERM])
        let result = reaper(signaller: signaller)
            .terminate(Fixture.parent(pid: 601, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.signalsSent, [SIGTERM])
        XCTAssertFalse(signaller.signals(for: 601).contains(SIGKILL))
        XCTAssertEqual(result.outcome, .terminatedBySIGTERM)
    }

    func testSurvivingBothSignalsIsReportedAsFailure() {
        let signaller = FakeSignaller(alive: [602])
        let result = reaper(signaller: signaller)
            .terminate(Fixture.parent(pid: 602, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.signalsSent, [SIGTERM, SIGKILL])
        XCTAssertEqual(result.outcome, .survived)
        XCTAssertFalse(result.outcome.succeeded)
    }

    func testProcessThatDisappearedBeforeSignallingIsNotSignalled() {
        let signaller = FakeSignaller(alive: [])
        let result = reaper(signaller: signaller)
            .terminate(Fixture.parent(pid: 603, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.outcome, .alreadyGone)
        XCTAssertTrue(result.signalsSent.isEmpty)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
    }

    /// If SIGTERM cannot even be delivered, the assumption that this pid is ours to
    /// signal is wrong, so escalation must not happen.
    func testFailedSIGTERMDeliveryDoesNotEscalate() {
        let signaller = FakeSignaller(alive: [604], undeliverable: [604])
        let result = reaper(signaller: signaller)
            .terminate(Fixture.parent(pid: 604, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.outcome, .signalFailed(signal: SIGTERM))
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
    }
    // MARK: - PID reuse

    /// A PID is not an identity. Selection runs against a snapshot that can be minutes
    /// old (`cleanupNow` may reuse one up to `maximumPollInterval` = 3600 s), and the
    /// machine hands out PIDs fast: 160 in 20 seconds measured while *idle*. If the
    /// target exited and its number was reissued, the replacement must not be signalled.
    func testDoesNotSignalAPIDThatNowBelongsToSomeoneElse() {
        let signaller = FakeSignaller(alive: [600], verifications: [600: .differs])
        let result = reaper(signaller: signaller).terminate(
            Fixture.parent(pid: 600, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.outcome, .identityChanged)
        XCTAssertTrue(result.signalsSent.isEmpty)
        XCTAssertTrue(signaller.deliveries.isEmpty)
    }

    /// Unreadable must never be read as unchanged. Refusing costs one poll interval;
    /// signalling an unverified process costs the user their work.
    func testDoesNotSignalWhenIdentityCannotBeRead() {
        let signaller = FakeSignaller(alive: [600], verifications: [600: .unreadable])
        let result = reaper(signaller: signaller).terminate(
            Fixture.parent(pid: 600, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.outcome, .identityChanged)
        XCTAssertTrue(signaller.deliveries.isEmpty)
    }

    /// The grace period is the widest reuse window in the routine, because the target was
    /// just asked to exit and is therefore more likely than usual to have done so. The
    /// SIGKILL escalation must re-verify rather than trust the check made before SIGTERM.
    func testDoesNotEscalateToSIGKILLAfterThePIDWasReused() {
        let signaller = FakeSignaller(
            alive: [600], verificationAfterFirstRead: [600: .differs])
        let result = reaper(signaller: signaller).terminate(
            Fixture.parent(pid: 600, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.outcome, .identityChanged)
        XCTAssertEqual(result.signalsSent, [SIGTERM])
        XCTAssertEqual(signaller.deliveries.map(\.signal), [SIGTERM])
    }

    /// The identity is re-read before *both* signals, not once per run.
    func testIdentityIsVerifiedBeforeEverySignal() {
        let signaller = FakeSignaller(alive: [600])
        _ = reaper(signaller: signaller).terminate(
            Fixture.parent(pid: 600, zombieCount: 500), policy: policy)

        XCTAssertEqual(signaller.verifiedPIDs, [600, 600])
    }

    /// Start times survive a round trip through `Date` as whole microseconds, so they are
    /// compared with a tolerance — but a tolerance wide enough to admit a different
    /// process would defeat the check.
    func testIdentityComparisonToleratesSubSecondSkewButNotMore() {
        let approved = ProcessIdentity(startTime: Fixture.epoch, uid: Fixture.uid)
        XCTAssertTrue(
            ProcessIdentity(startTime: Fixture.epoch.addingTimeInterval(0.5), uid: Fixture.uid)
                .matches(approved))
        XCTAssertFalse(
            ProcessIdentity(startTime: Fixture.epoch.addingTimeInterval(5), uid: Fixture.uid)
                .matches(approved))
        XCTAssertFalse(
            ProcessIdentity(startTime: Fixture.epoch, uid: Fixture.otherUID).matches(approved))
    }

    /// Runs against the live machine, because a check that only ever sees fixtures would
    /// not catch the `kinfo_proc` field being read from the wrong offset. Both directions
    /// are asserted: the real start time must pass, a wrong one must not.
    func testLiveIdentityCheckAgreesWithTheRunningProcess() throws {
        let sender = POSIXSignalSender()
        let table = try SysctlProcessEnumerator().enumerateProcesses()
        let me = try XCTUnwrap(table.first { $0.pid == getpid() })
        let truth = ProcessIdentity(startTime: me.startTime, uid: me.uid)

        XCTAssertEqual(sender.verifyIdentity(ofPID: getpid(), matches: truth), .matches)
        XCTAssertEqual(
            sender.verifyIdentity(
                ofPID: getpid(),
                matches: ProcessIdentity(
                    startTime: me.startTime.addingTimeInterval(-86400), uid: me.uid)),
            .differs)
        // PID 0 is the kernel and can never be a target, so it must not read as a match.
        XCTAssertNotEqual(sender.verifyIdentity(ofPID: 0, matches: truth), .matches)
    }

    /// A signal-specific delivery failure must not be papered over: SIGTERM succeeding
    /// and SIGKILL failing is a distinct, reportable outcome.
    func testFailedSIGKILLDeliveryIsReportedRatherThanTreatedAsSuccess() {
        let signaller = FakeSignaller(
            alive: [600], undeliverableSignals: [600: [SIGKILL]])
        let result = reaper(signaller: signaller).terminate(
            Fixture.parent(pid: 600, zombieCount: 500), policy: policy)

        XCTAssertEqual(result.outcome, .signalFailed(signal: SIGKILL))
        XCTAssertEqual(result.signalsSent, [SIGTERM])
        XCTAssertFalse(result.outcome.succeeded)
    }
    // MARK: - Coverage of rules that defaults would otherwise hide

    /// Every other test runs with the default idle threshold, which lets a mutant reading
    /// `CleanupPolicy.defaultSessionIdleThreshold` instead of `policy.sessionIdleThreshold`
    /// survive undetected. This pins the *configured* value: a session idle for 90 minutes
    /// protects its parent under the 2 h default but not under a 1 h setting.
    func testTheConfiguredIdleThresholdIsUsedRatherThanTheDefault() {
        let parent = Fixture.parent(
            pid: 600, zombieCount: 500,
            sessionChildCount: 1, sessionChildPIDs: [601],
            sessionIdleSeconds: 90 * 60, sessionLogAgeSeconds: 90 * 60)
        let snapshot = Fixture.snapshot(offenders: [parent])

        let underDefault = reaper().selectTargets(
            in: snapshot,
            policy: CleanupPolicy(
                minimumZombiesPerParent: 100, allowedNamePatterns: ["agency"],
                terminationGracePeriod: 2))
        XCTAssertTrue(underDefault.targets.isEmpty)

        let underShorterThreshold = reaper().selectTargets(
            in: snapshot,
            policy: CleanupPolicy(
                minimumZombiesPerParent: 100, allowedNamePatterns: ["agency"],
                terminationGracePeriod: 2, sessionIdleThreshold: 3600))
        XCTAssertEqual(underShorterThreshold.targets.map(\.pid), [600])
    }

    /// PID 0 is the kernel. Covered deterministically here rather than relying on the
    /// live process table, so that narrowing the guard to `pid == 1` fails the suite.
    func testNeverTargetsPIDZero() {
        let snapshot = Fixture.snapshot(
            offenders: [Fixture.parent(pid: 0, name: "kernel_task", zombieCount: 5000)])
        let selection = reaper().selectTargets(in: snapshot, policy: policy)

        XCTAssertTrue(selection.targets.isEmpty)
        XCTAssertEqual(selection.skipped.first?.reason, .initProcess)
    }
}
