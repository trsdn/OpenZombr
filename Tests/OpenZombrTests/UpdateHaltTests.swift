import Darwin
import XCTest

@testable import OpenZombrKit

/// Installing an update quits the app. These tests pin down that it can never do so
/// between the SIGTERM and the SIGKILL of a cleanup, and that no cleanup starts once an
/// install has begun.
@MainActor
final class UpdateHaltTests: XCTestCase {
    private var logDirectory: URL!

    override func setUp() async throws {
        logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenZombrTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: logDirectory)
    }

    private func makeModel(signaller: FakeSignaller, graceSleeper: Sleeping) -> ZombrModel {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 600, ppid: 600, startingPID: 10_000)
        let sampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: entries),
            limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid,
            currentPID: 500
        )
        let preferences = Preferences(defaults: .makeTransient())
        preferences.allowedPatternsText = "agency"
        preferences.minimumZombiesPerParent = 100
        let reaper = ZombieReaper(
            signaller: signaller, sleeper: graceSleeper, currentUID: Fixture.uid)
        return ZombrModel(
            preferences: preferences,
            sampler: sampler,
            cleanupService: CleanupService(
                sampler: sampler, reaper: reaper, sleeper: FakeSleeper(),
                verificationDelay: 0),
            reaper: reaper,
            notifier: SpyNotifier(),
            log: EvidenceCSVLog(directory: logDirectory)
        )
    }

    func testHaltWaitsUntilTheEscalationHasFinished() async throws {
        let gate = GatedSleeper()
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(signaller: signaller, graceSleeper: gate)
        defer { model.stop() }

        await model.cleanupNow()
        XCTAssertTrue(model.isCleaning)
        // Parked inside the grace period: SIGTERM sent, SIGKILL not yet.
        await Task.detached { gate.waitUntilEntered() }.value
        XCTAssertEqual(signaller.signals(for: 600), [SIGTERM])

        var halted = false
        let halt = Task { @MainActor in
            await model.haltForUpdate()
            halted = true
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(halted, "the installer must not proceed mid-escalation")
        XCTAssertTrue(model.isHaltedForUpdate)

        gate.release()
        await halt.value

        XCTAssertTrue(halted)
        XCTAssertFalse(model.isCleaning)
        XCTAssertEqual(signaller.signals(for: 600), [SIGTERM, SIGKILL])
        XCTAssertNotNil(model.lastCleanup, "the run must reach the evidence log before quitting")
    }

    func testNoCleanupStartsWhileHaltedAndResumeRestoresIt() async {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(signaller: signaller, graceSleeper: FakeSleeper())
        defer { model.stop() }

        await model.haltForUpdate()
        await model.cleanupNow()
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)

        model.resumeAfterFailedUpdate()
        XCTAssertFalse(model.isHaltedForUpdate)
        await model.cleanupNow()
        XCTAssertTrue(model.isCleaning, "a failed install must not leave the watchdog halted")
    }
}

/// Blocks the first sleep — the SIGTERM grace period — until released, so a test can
/// observe the model while a termination is in flight. Later sleeps return at once.
private final class GatedSleeper: Sleeping, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    func sleep(for interval: TimeInterval) {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        guard first else { return }
        entered.signal()
        gate.wait()
    }

    func waitUntilEntered() { entered.wait() }
    func release() { gate.signal() }
}
