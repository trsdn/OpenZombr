import Darwin
import XCTest

@testable import OpenZombrKit

/// "Jetzt aufräumen" when the fresh sample fails.
///
/// The reaper re-verifies a target's *identity* before every signal, which covers pid reuse.
/// It does not cover a session that became active, or an ancestry that changed, since the
/// snapshot was taken — and the stored snapshot can be as old as the longest poll interval,
/// an hour. So a snapshot may only stand in for a failed sample while it is still
/// essentially the current picture.
@MainActor
final class StaleSnapshotCleanupTests: XCTestCase {
    private var logDirectory: URL!

    override func setUp() async throws {
        logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenZombrTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: logDirectory)
    }

    private func makeModel(enumerator: FlakyEnumerator, signaller: FakeSignaller) -> ZombrModel {
        let sampler = ZombieSampler(
            enumerator: enumerator,
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid,
            currentPID: 500)
        let preferences = Preferences(defaults: .makeTransient())
        preferences.allowedPatternsText = "agency"
        preferences.minimumZombiesPerParent = 100
        let reaper = ZombieReaper(
            signaller: signaller, sleeper: FakeSleeper(), currentUID: Fixture.uid)
        return ZombrModel(
            preferences: preferences,
            sampler: sampler,
            cleanupService: CleanupService(
                sampler: sampler, reaper: reaper, sleeper: FakeSleeper(), verificationDelay: 0),
            reaper: reaper,
            notifier: SpyNotifier(),
            log: EvidenceCSVLog(directory: logDirectory)
        )
    }

    private func entries() -> [ProcessEntry] {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 600, ppid: 600, startingPID: 10_000)
        return entries
    }

    /// The snapshot is seconds old, so it is still the current picture and the button keeps
    /// working through a transient sampling failure.
    func testAFreshSnapshotStandsInForAFailedSample() {
        let enumerator = FlakyEnumerator(entries: entries())
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(enumerator: enumerator, signaller: signaller)
        defer { model.stop() }

        model.poll()
        enumerator.failing = true
        model.cleanupNow(now: Date().addingTimeInterval(5))

        XCTAssertTrue(model.isCleaning)
    }

    /// An hour-old snapshot says nothing about whether the session is busy *now*. Acting on
    /// it would sidestep the rule that ancestry and liveness are recomputed on every poll.
    func testAStaleSnapshotDoesNotStandInForAFailedSample() {
        let enumerator = FlakyEnumerator(entries: entries())
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(enumerator: enumerator, signaller: signaller)
        defer { model.stop() }

        model.poll()
        enumerator.failing = true
        model.cleanupNow(now: Date().addingTimeInterval(3600))

        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
        XCTAssertNotNil(model.lastError, "refusing must be visible, not silent")
    }

    func testNoSnapshotAndNoSampleDoesNothingVisibly() {
        let enumerator = FlakyEnumerator(entries: entries())
        enumerator.failing = true
        let signaller = FakeSignaller(alive: [600])
        let model = makeModel(enumerator: enumerator, signaller: signaller)
        defer { model.stop() }

        model.cleanupNow()

        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
        XCTAssertNotNil(model.lastError)
    }
}

/// A process table that can be made to fail, like a `sysctl` that returns `ENOMEM`.
private final class FlakyEnumerator: ProcessEnumerating, @unchecked Sendable {
    private let inner: StubProcessEnumerator
    var failing = false

    init(entries: [ProcessEntry]) { inner = StubProcessEnumerator(entries: entries) }

    func enumerateProcesses() throws -> [ProcessEntry] {
        if failing { throw ProcessTableError.sysctlFailed(name: "kern.proc.all", errno: ENOMEM) }
        return try inner.enumerateProcesses()
    }

    func executablePath(for pid: pid_t) -> String? { inner.executablePath(for: pid) }
    func cpuSeconds(for pid: pid_t) -> TimeInterval? { inner.cpuSeconds(for: pid) }
    func arguments(for pid: pid_t) -> [String]? { inner.arguments(for: pid) }
}
