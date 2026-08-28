import Foundation

@testable import OpenZombrKit

// MARK: - Process table fixtures

enum Fixture {
    static let uid: uid_t = 501
    static let otherUID: uid_t = 502
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func process(
        pid: pid_t,
        ppid: pid_t,
        uid: uid_t = Fixture.uid,
        name: String = "worker",
        zombie: Bool = false,
        ageSeconds: TimeInterval = 60
    ) -> ProcessEntry {
        ProcessEntry(
            pid: pid,
            ppid: ppid,
            uid: uid,
            name: name,
            isZombie: zombie,
            startTime: epoch.addingTimeInterval(-ageSeconds)
        )
    }

    /// `count` zombie children of `ppid`, with pids starting at `startingPID`.
    static func zombies(
        count: Int,
        ppid: pid_t,
        startingPID: pid_t,
        uid: uid_t = Fixture.uid,
        name: String = "send-telemetry"
    ) -> [ProcessEntry] {
        (0..<count).map { index in
            process(
                pid: startingPID + pid_t(index), ppid: ppid, uid: uid, name: name, zombie: true)
        }
    }

    static func parent(
        pid: pid_t,
        name: String = "agency",
        path: String? = "/Users/x/.config/agency/CurrentVersion/agency",
        zombieCount: Int,
        uid: uid_t = Fixture.uid,
        parentIsZombie: Bool = false
    ) -> ZombieParent {
        ZombieParent(
            pid: pid,
            uid: uid,
            name: name,
            executablePath: path,
            zombieCount: zombieCount,
            startTime: epoch.addingTimeInterval(-3600),
            parentIsZombie: parentIsZombie
        )
    }

    static func snapshot(
        totalProcesses: Int = 1000,
        zombieCount: Int = 500,
        limit: Int = 4000,
        offenders: [ZombieParent] = [],
        protectedPIDs: Set<pid_t> = [1],
        timestamp: Date = Fixture.epoch
    ) -> ZombieSnapshot {
        ZombieSnapshot(
            timestamp: timestamp,
            uid: uid,
            totalProcesses: totalProcesses,
            zombieCount: zombieCount,
            limit: limit,
            offenders: offenders,
            protectedPIDs: protectedPIDs
        )
    }
}

// MARK: - Test doubles

/// A process enumerator backed by a fixed table.
final class StubProcessEnumerator: ProcessEnumerating, @unchecked Sendable {
    let entries: [ProcessEntry]
    let paths: [pid_t: String]
    private(set) var pathLookups: [pid_t] = []
    private let lock = NSLock()

    init(entries: [ProcessEntry], paths: [pid_t: String] = [:]) {
        self.entries = entries
        self.paths = paths
    }

    func enumerateProcesses() throws -> [ProcessEntry] { entries }

    func executablePath(for pid: pid_t) -> String? {
        lock.lock()
        pathLookups.append(pid)
        lock.unlock()
        return paths[pid]
    }
}

struct StubLimitReader: ProcessLimitReading {
    let limit: Int
    func maximumProcessesPerUID() throws -> Int { limit }
}

/// Records every signal instead of sending it, and models which signal a process
/// actually responds to. This is what makes the escalation order provable.
final class FakeSignaller: ProcessSignalling, @unchecked Sendable {
    struct Delivery: Equatable {
        let pid: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var alive: Set<pid_t>
    /// pid -> the signal that actually terminates it. `nil` entry means nothing does.
    private var lethalSignal: [pid_t: Int32]
    private var undeliverable: Set<pid_t>
    private(set) var deliveries: [Delivery] = []

    init(
        alive: Set<pid_t>,
        lethalSignal: [pid_t: Int32] = [:],
        undeliverable: Set<pid_t> = []
    ) {
        self.alive = alive
        self.lethalSignal = lethalSignal
        self.undeliverable = undeliverable
    }

    func send(signal: Int32, to pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !undeliverable.contains(pid) else { return false }
        deliveries.append(Delivery(pid: pid, signal: signal))
        if lethalSignal[pid] == signal { alive.remove(pid) }
        return true
    }

    func isAlive(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive.contains(pid)
    }

    var signalledPIDs: Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return Set(deliveries.map(\.pid))
    }

    func signals(for pid: pid_t) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return deliveries.filter { $0.pid == pid }.map(\.signal)
    }
}

/// Never actually sleeps, so the grace period costs nothing in tests.
final class FakeSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var intervals: [TimeInterval] = []

    func sleep(for interval: TimeInterval) {
        lock.lock()
        intervals.append(interval)
        lock.unlock()
    }
}

final class SpyNotifier: AlertNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var thresholdAlerts: [ThresholdAlert] = []
    private(set) var cleanupReports: [CleanupReport] = []

    func notifyThreshold(_ alert: ThresholdAlert, forecast: ForkFailureForecast) {
        lock.lock()
        thresholdAlerts.append(alert)
        lock.unlock()
    }

    func notifyCleanup(_ report: CleanupReport) {
        lock.lock()
        cleanupReports.append(report)
        lock.unlock()
    }
}

extension UserDefaults {
    /// Isolated defaults so preference tests cannot see or corrupt real settings.
    static func makeTransient(function: String = #function) -> UserDefaults {
        let name = "OpenZombrTests.\(function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
