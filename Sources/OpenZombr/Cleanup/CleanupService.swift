import Foundation

/// Runs a complete cleanup: select, terminate, then re-sample and verify.
///
/// Verification is not optional decoration. The whole point of the app is that the user
/// should not have to check by hand whether anything improved, and a cleanup that
/// signalled processes without reducing the zombie count is a failure that must be
/// reported as one.
public struct CleanupService: Sendable {
    private let sampler: ZombieSampler
    private let reaper: ZombieReaper
    private let sleeper: Sleeping
    /// Time to let launchd reap the reparented zombies before re-sampling. Measured to
    /// be effectively instant, but a small settle time avoids reporting a stale count.
    private let verificationDelay: TimeInterval

    public init(
        sampler: ZombieSampler = ZombieSampler(),
        reaper: ZombieReaper = ZombieReaper(),
        sleeper: Sleeping = ThreadSleeper(),
        verificationDelay: TimeInterval = 1.0
    ) {
        self.sampler = sampler
        self.reaper = reaper
        self.sleeper = sleeper
        self.verificationDelay = max(0, verificationDelay)
    }

    public func run(
        on snapshot: ZombieSnapshot,
        policy: CleanupPolicy,
        now: Date = Date()
    ) -> CleanupReport {
        let selection = reaper.selectTargets(in: snapshot, policy: policy)

        guard !selection.targets.isEmpty else {
            return CleanupReport(
                startedAt: now,
                results: [],
                skipped: selection.skipped,
                zombiesBefore: snapshot.zombieCount,
                zombiesAfter: snapshot.zombieCount,
                processesBefore: snapshot.totalProcesses,
                processesAfter: snapshot.totalProcesses
            )
        }

        let results = reaper.terminate(
            selection.targets, policy: policy, emergencyOverrides: selection.emergencyOverrides)
        sleeper.sleep(for: verificationDelay)

        let after = try? sampler.sample(now: Date())
        return CleanupReport(
            startedAt: now,
            results: results,
            skipped: selection.skipped,
            zombiesBefore: snapshot.zombieCount,
            zombiesAfter: after?.zombieCount ?? snapshot.zombieCount,
            processesBefore: snapshot.totalProcesses,
            processesAfter: after?.totalProcesses ?? snapshot.totalProcesses
        )
    }
}
