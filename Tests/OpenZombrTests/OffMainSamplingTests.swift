import Darwin
import XCTest

@testable import OpenZombrKit

/// Sampling reads the process table, `proc_pidinfo` per session child and the tails of log
/// files. On a machine that is already out of slots that can be slow, and while it runs on
/// the main actor the menu bar item and every open menu freeze with it. It runs off the
/// main actor, and everything it touches from there has to be safe to touch from there.
@MainActor
final class OffMainSamplingTests: XCTestCase {
    private var logDirectory: URL!

    override func setUp() async throws {
        logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenZombrTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: logDirectory)
    }

    private func makeModel(enumerator: ProcessEnumerating) -> ZombrModel {
        let sampler = ZombieSampler(
            enumerator: enumerator, limitReader: StubLimitReader(limit: 4000),
            currentUID: Fixture.uid, currentPID: 500)
        let reaper = ZombieReaper(
            signaller: FakeSignaller(alive: []), sleeper: FakeSleeper(), currentUID: Fixture.uid)
        return ZombrModel(
            preferences: Preferences(defaults: .makeTransient()),
            sampler: sampler,
            cleanupService: CleanupService(
                sampler: sampler, reaper: reaper, sleeper: FakeSleeper(), verificationDelay: 0),
            reaper: reaper,
            notifier: SpyNotifier(),
            log: EvidenceCSVLog(directory: logDirectory)
        )
    }

    /// While a sample is stuck the main actor must keep serving other work. The enumerator
    /// holds the sample for up to 1.5 s; if that happened on the main thread, the probe
    /// scheduled onto it could not run inside the one second the test allows.
    func testAStuckSampleDoesNotBlockTheMainActor() async {
        let enumerator = BlockingEnumerator(entries: [
            Fixture.process(pid: 1, ppid: 0, name: "launchd")
        ])
        let model = makeModel(enumerator: enumerator)
        defer { model.stop() }

        let responded = expectation(description: "main queue ran while the sample was stuck")
        Task { await model.poll() }
        DispatchQueue.global().async {
            enumerator.waitUntilEntered()
            DispatchQueue.main.async { responded.fulfill() }
        }
        await fulfillment(of: [responded], timeout: 1.0)

        enumerator.release()
    }

    /// A poll that finds another one still in flight is skipped, not queued behind it: with
    /// a slow sample and a short interval the timer would otherwise pile up work.
    func testOverlappingPollsAreSkippedNotStacked() async {
        let enumerator = BlockingEnumerator(entries: [
            Fixture.process(pid: 1, ppid: 0, name: "launchd")
        ])
        let model = makeModel(enumerator: enumerator)
        defer { model.stop() }

        let first = Task { await model.poll() }
        await Task.detached { enumerator.waitUntilEntered() }.value
        await model.poll()  // returns at once: the first is still sampling
        XCTAssertEqual(enumerator.calls, 1)

        enumerator.release()
        await first.value
        XCTAssertEqual(enumerator.calls, 1)
        XCTAssertNotNil(model.snapshot)
    }

    func testAFinishedPollPublishesItsSnapshot() async {
        let enumerator = BlockingEnumerator(entries: [
            Fixture.process(pid: 1, ppid: 0, name: "launchd")
        ])
        enumerator.release()
        let model = makeModel(enumerator: enumerator)
        defer { model.stop() }

        await model.poll()

        XCTAssertNotNil(model.snapshot)
        XCTAssertNotNil(model.lastSuccessfulPoll)
    }

    // MARK: - IdleTracker across threads

    /// Sampling runs on a background thread, and a manual cleanup can sample while a poll
    /// is winding down, so the tracker can no longer rely on being main-actor only.
    func testIdleTrackerSurvivesConcurrentUse() {
        let tracker = IdleTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<500 {
                let pid = pid_t(worker * 1000 + index)
                _ = tracker.observe(pid: pid, startTime: start, cpuSeconds: 1, now: start)
                _ = tracker.idleDuration(for: pid, now: start)
            }
        }
        XCTAssertEqual(tracker.trackedCount, 8 * 500)
    }
}

/// A process table that parks the sampling thread until released, like a `sysctl` that is
/// slow on a machine out of slots. Gives up after 1.5 s so a failing test cannot hang.
private final class BlockingEnumerator: ProcessEnumerating, @unchecked Sendable {
    private let inner: StubProcessEnumerator
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    init(entries: [ProcessEntry]) { inner = StubProcessEnumerator(entries: entries) }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func waitUntilEntered() { _ = entered.wait(timeout: .now() + 5) }
    func release() { gate.signal() }

    func enumerateProcesses() throws -> [ProcessEntry] {
        lock.lock()
        count += 1
        lock.unlock()
        entered.signal()
        _ = gate.wait(timeout: .now() + 1.5)
        gate.signal()  // stay open for any later call
        return try inner.enumerateProcesses()
    }

    func executablePath(for pid: pid_t) -> String? { inner.executablePath(for: pid) }
    func cpuSeconds(for pid: pid_t) -> TimeInterval? { inner.cpuSeconds(for: pid) }
    func arguments(for pid: pid_t) -> [String]? { inner.arguments(for: pid) }
}
