import Foundation

/// One poll: how many process-table slots the current uid holds, how many of those are
/// zombies, what the limit is, and who is leaking.
public struct ZombieSnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let uid: uid_t
    /// Processes owned by `uid`, zombies included — zombies occupy slots and count
    /// against `kern.maxprocperuid` just like live processes do.
    public let totalProcesses: Int
    public let zombieCount: Int
    /// `kern.maxprocperuid`, read at runtime.
    public let limit: Int
    /// Parents owning at least one zombie, sorted by zombie count descending.
    public let offenders: [ZombieParent]
    /// PIDs that must never be signalled: this process and every ancestor of it.
    public let protectedPIDs: Set<pid_t>

    public init(
        timestamp: Date,
        uid: uid_t,
        totalProcesses: Int,
        zombieCount: Int,
        limit: Int,
        offenders: [ZombieParent],
        protectedPIDs: Set<pid_t> = []
    ) {
        self.timestamp = timestamp
        self.uid = uid
        self.totalProcesses = totalProcesses
        self.zombieCount = zombieCount
        self.limit = limit
        self.offenders = offenders
        self.protectedPIDs = protectedPIDs
    }

    /// Share of the per-uid limit currently in use. This, not the raw zombie count, is
    /// what determines severity: `fork()` fails at the limit regardless of how the slots
    /// are split between live processes and zombies.
    public var usageFraction: Double {
        guard limit > 0 else { return 0 }
        return Double(totalProcesses) / Double(limit)
    }

    public var freeSlots: Int {
        max(0, limit - totalProcesses)
    }

    public var liveProcesses: Int {
        max(0, totalProcesses - zombieCount)
    }

    /// Share of the limit occupied by zombies alone — the part that is pure waste.
    public var zombieFraction: Double {
        guard limit > 0 else { return 0 }
        return Double(zombieCount) / Double(limit)
    }

    public var topOffender: ZombieParent? { offenders.first }

    public func severity(thresholds: Thresholds) -> Severity {
        thresholds.severity(forUsageFraction: usageFraction)
    }
}

/// Turns a raw process table into a `ZombieSnapshot`.
public struct ZombieSampler: Sendable {
    private let enumerator: ProcessEnumerating
    private let limitReader: ProcessLimitReading
    private let currentUID: uid_t
    private let currentPID: pid_t
    private let logProbe: SessionLogProbing
    /// Resolving executable paths costs one syscall each, so it is limited to the
    /// parents that could plausibly be targeted.
    private let pathResolutionLimit: Int

    public init(
        enumerator: ProcessEnumerating = SysctlProcessEnumerator(),
        limitReader: ProcessLimitReading = SysctlProcessLimitReader(),
        currentUID: uid_t = getuid(),
        currentPID: pid_t = getpid(),
        pathResolutionLimit: Int = 20,
        logProbe: SessionLogProbing? = nil
    ) {
        self.logProbe = logProbe ?? SessionLogProbe(enumerator: enumerator)
        self.enumerator = enumerator
        self.limitReader = limitReader
        self.currentUID = currentUID
        self.currentPID = currentPID
        self.pathResolutionLimit = max(0, pathResolutionLimit)
    }

    public func sample(now: Date = Date(), idleTracker: IdleTracker? = nil) throws
        -> ZombieSnapshot
    {
        let entries = try enumerator.enumerateProcesses()
        let limit = try limitReader.maximumProcessesPerUID()
        let base = snapshot(from: entries, limit: limit, now: now)
        guard let idleTracker else { return base }
        return applyingIdle(to: base, entries: entries, tracker: idleTracker, now: now)
    }

    /// Samples CPU time for the session children of every offending parent and folds the
    /// resulting idle durations back into the snapshot.
    ///
    /// Only session children are sampled — a handful of pids — because this is one
    /// syscall each and the app must stay cheap on a machine that is already struggling.
    public func applyingIdle(
        to snapshot: ZombieSnapshot,
        entries: [ProcessEntry],
        tracker: IdleTracker,
        now: Date
    ) -> ZombieSnapshot {
        let byPID = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var updated: [ZombieParent] = []
        updated.reserveCapacity(snapshot.offenders.count)
        for offender in snapshot.offenders {
            guard !offender.sessionChildPIDs.isEmpty else {
                updated.append(offender)
                continue
            }
            var minimumIdle: TimeInterval?
            var sawUnknown = false
            // The log age is taken as the *newest* write across the session children: any
            // one of them showing recent output means the session is alive.
            var newestLogAge: TimeInterval?
            var sawUnknownLog = false
            for child in offender.sessionChildPIDs {
                guard let entry = byPID[child], let cpu = enumerator.cpuSeconds(for: child) else {
                    sawUnknown = true
                    continue
                }
                guard
                    let idle = tracker.observe(
                        pid: child, startTime: entry.startTime, cpuSeconds: cpu, now: now)
                else {
                    sawUnknown = true
                    continue
                }
                minimumIdle = min(minimumIdle ?? idle, idle)
            }
            for child in offender.sessionChildPIDs {
                guard let age = logProbe.logAgeSeconds(for: child, now: now) else {
                    sawUnknownLog = true
                    continue
                }
                newestLogAge = min(newestLogAge ?? age, age)
            }
            // A wrapper counts as idle only when *every* session child is known to be
            // idle. One unreadable child is enough to keep the parent protected.
            updated.append(
                offender.withSessionIdle(
                    sawUnknown ? nil : minimumIdle,
                    logAge: sawUnknownLog ? nil : newestLogAge))
        }

        tracker.prune(keeping: Set(entries.map(\.pid)))

        return ZombieSnapshot(
            timestamp: snapshot.timestamp,
            uid: snapshot.uid,
            totalProcesses: snapshot.totalProcesses,
            zombieCount: snapshot.zombieCount,
            limit: snapshot.limit,
            offenders: updated,
            protectedPIDs: snapshot.protectedPIDs
        )
    }

    /// Pure transformation, exposed so tests can pin the aggregation rules.
    public func snapshot(from entries: [ProcessEntry], limit: Int, now: Date) -> ZombieSnapshot {
        let byPID = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = entries.filter { $0.uid == currentUID }
        let zombies = mine.filter(\.isZombie)

        var counts: [pid_t: Int] = [:]
        for zombie in zombies {
            counts[zombie.ppid, default: 0] += 1
        }

        // Live children per parent, split into self-spawns (same executable name as the
        // parent) and everything else. Built in one pass over the whole table.
        var liveChildren: [pid_t: Int] = [:]
        var sessionChildren: [pid_t: [pid_t]] = [:]
        for entry in entries where !entry.isZombie {
            let parentPID: pid_t = entry.ppid
            guard counts[parentPID] != nil else { continue }
            liveChildren[parentPID, default: 0] += 1
            let parentName: String = byPID[parentPID]?.name ?? ""
            if entry.name != parentName {
                sessionChildren[parentPID, default: []].append(entry.pid)
            }
        }

        var offenders: [ZombieParent] = []
        offenders.reserveCapacity(counts.count)
        for (pid, count) in counts {
            let parent: ProcessEntry? = byPID[pid]
            let name: String = parent?.name ?? "unbekannt"
            let ownerUID: uid_t = parent?.uid ?? currentUID
            let started: Date = parent?.startTime ?? now
            let parentIsZombie: Bool = parent?.isZombie ?? false
            let live: Int = liveChildren[pid] ?? 0
            let sessionPIDs: [pid_t] = sessionChildren[pid] ?? []
            offenders.append(
                ZombieParent(
                    pid: pid,
                    uid: ownerUID,
                    name: name,
                    executablePath: nil,
                    zombieCount: count,
                    startTime: started,
                    parentIsZombie: parentIsZombie,
                    liveChildCount: live,
                    sessionChildCount: sessionPIDs.count,
                    sessionChildPIDs: sessionPIDs.sorted()
                )
            )
        }
        // Deterministic order: zombie count first, then pid, so the menu does not
        // reshuffle rows that are tied.
        offenders.sort {
            $0.zombieCount == $1.zombieCount ? $0.pid < $1.pid : $0.zombieCount > $1.zombieCount
        }

        offenders = resolvePaths(for: offenders)

        return ZombieSnapshot(
            timestamp: now,
            uid: currentUID,
            totalProcesses: mine.count,
            zombieCount: zombies.count,
            limit: limit,
            offenders: offenders,
            protectedPIDs: ProcessProtection.protectedPIDs(of: currentPID, in: entries)
        )
    }

    private func resolvePaths(for offenders: [ZombieParent]) -> [ZombieParent] {
        offenders.enumerated().map { index, offender in
            guard index < pathResolutionLimit,
                let path = enumerator.executablePath(for: offender.pid)
            else { return offender }
            return ZombieParent(
                pid: offender.pid,
                uid: offender.uid,
                name: offender.name,
                executablePath: path,
                zombieCount: offender.zombieCount,
                startTime: offender.startTime,
                parentIsZombie: offender.parentIsZombie,
                liveChildCount: offender.liveChildCount,
                sessionChildCount: offender.sessionChildCount,
                sessionChildPIDs: offender.sessionChildPIDs,
                sessionIdleSeconds: offender.sessionIdleSeconds
            )
        }
    }
}
