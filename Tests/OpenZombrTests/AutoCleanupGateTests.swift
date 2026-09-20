import Darwin
import XCTest

@testable import OpenZombrKit

/// The gate between a poll and the destructive path.
///
/// `ZombrModel.poll` may only start a cleanup once the hysteresis has confirmed critical
/// severity, never faster than the cooldown allows, never with auto-cleanup off and never
/// while an update install has halted the model. Each rule is the only thing standing
/// between one spurious reading and a SIGKILL, so each is pinned on its own.
@MainActor
final class AutoCleanupGateTests: XCTestCase {
    private var logDirectory: URL!

    override func setUp() async throws {
        logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenZombrTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: logDirectory)
    }

    /// 600 zombies against a limit of 700: 86 %, past the 75 % critical threshold, held by
    /// one idle `agency` wrapper that is an eligible target.
    private func makeModel(
        signaller: FakeSignaller, autoCleanup: Bool = true
    ) -> ZombrModel {
        var entries: [ProcessEntry] = [
            Fixture.process(pid: 1, ppid: 0, name: "launchd"),
            Fixture.process(pid: 500, ppid: 1, name: "shell"),
            Fixture.process(pid: 600, ppid: 1, name: "agency"),
        ]
        entries += Fixture.zombies(count: 600, ppid: 600, startingPID: 10_000)
        let sampler = ZombieSampler(
            enumerator: StubProcessEnumerator(entries: entries),
            limitReader: StubLimitReader(limit: 700),
            currentUID: Fixture.uid,
            currentPID: 500)
        let preferences = Preferences(defaults: .makeTransient())
        preferences.allowedPatternsText = "agency"
        preferences.minimumZombiesPerParent = 100
        preferences.autoCleanupEnabled = autoCleanup
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

    private func settle(_ model: ZombrModel) async throws {
        for _ in 0..<100 where model.isCleaning {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isCleaning, "the cleanup never finished")
    }

    /// One critical reading is not confirmation. This is the entire reason
    /// `ThresholdMonitor` requires consecutive samples.
    func testASingleCriticalSampleDoesNotStartACleanup() async {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(signaller: signaller)
        defer { model.stop() }

        await model.poll()

        XCTAssertEqual(model.severity, .critical, "the menu may react to one sample")
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
    }

    func testTwoConsecutiveCriticalSamplesStartACleanup() async throws {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(signaller: signaller)
        defer { model.stop() }

        await model.poll()
        await model.poll()
        XCTAssertTrue(model.isCleaning)
        try await settle(model)

        XCTAssertEqual(signaller.signals(for: 600), [SIGTERM, SIGKILL])
    }

    func testDisabledAutoCleanupNeverSignals() async throws {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(signaller: signaller, autoCleanup: false)
        defer { model.stop() }

        for _ in 0..<5 { await model.poll() }

        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
    }

    func testAHaltedModelNeverStartsACleanup() async {
        let signaller = FakeSignaller(alive: [600], lethalSignal: [600: SIGKILL])
        let model = makeModel(signaller: signaller)
        defer { model.stop() }

        await model.haltForUpdate()
        for _ in 0..<5 { await model.poll() }

        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(signaller.signalledPIDs.isEmpty)
    }

    /// The target survives, so it is still there for every later poll. Without the cooldown
    /// each poll would signal it again; with it, exactly one attempt happens.
    func testTheCooldownStopsARepeatedAttemptOnTheNextPolls() async throws {
        let signaller = FakeSignaller(alive: [600])
        let model = makeModel(signaller: signaller)
        defer { model.stop() }

        await model.poll()
        await model.poll()
        try await settle(model)
        XCTAssertEqual(signaller.signals(for: 600), [SIGTERM, SIGKILL])

        for _ in 0..<4 {
            await model.poll()
            try await settle(model)
        }
        XCTAssertEqual(
            signaller.signals(for: 600), [SIGTERM, SIGKILL],
            "a second attempt inside the cooldown would be a kill loop")
    }
}
