import Darwin
import Foundation

/// What was done to one leaking parent.
public enum ReapOutcome: Sendable, Equatable {
    /// The parent exited after SIGTERM alone.
    case terminatedBySIGTERM
    /// SIGTERM was ignored and SIGKILL was required. This is the expected outcome for
    /// `agency` wrappers: SIGTERM was measured to be ignored by them.
    case terminatedBySIGKILL
    /// Both signals were sent and the process is still alive.
    case survived
    /// The process disappeared on its own before anything was sent.
    case alreadyGone
    /// A signal could not be delivered at all.
    case signalFailed(signal: Int32)

    public var germanDescription: String {
        switch self {
        case .terminatedBySIGTERM: return "durch SIGTERM beendet"
        case .terminatedBySIGKILL: return "durch SIGKILL beendet"
        case .survived: return "überlebt (nicht beendet)"
        case .alreadyGone: return "war bereits beendet"
        case .signalFailed(let signal): return "Signal \(signal) fehlgeschlagen"
        }
    }

    public var succeeded: Bool {
        switch self {
        case .terminatedBySIGTERM, .terminatedBySIGKILL, .alreadyGone: return true
        case .survived, .signalFailed: return false
        }
    }

    /// Short token for the CSV evidence log.
    public var logToken: String {
        switch self {
        case .terminatedBySIGTERM: return "sigterm"
        case .terminatedBySIGKILL: return "sigkill"
        case .survived: return "survived"
        case .alreadyGone: return "already-gone"
        case .signalFailed: return "signal-failed"
        }
    }
}

public struct ReapResult: Sendable, Equatable {
    public let parent: ZombieParent
    public let outcome: ReapOutcome
    /// Signals actually delivered, in the order they were sent. Asserted by tests so the
    /// escalation order can never silently regress into "SIGKILL first".
    public let signalsSent: [Int32]

    public init(parent: ZombieParent, outcome: ReapOutcome, signalsSent: [Int32]) {
        self.parent = parent
        self.outcome = outcome
        self.signalsSent = signalsSent
    }
}

/// The outcome of a whole cleanup run, before and after verification.
public struct CleanupReport: Sendable, Equatable {
    public let startedAt: Date
    public let results: [ReapResult]
    public let skipped: [SkippedParent]
    public let zombiesBefore: Int
    public let zombiesAfter: Int
    public let processesBefore: Int
    public let processesAfter: Int

    public init(
        startedAt: Date,
        results: [ReapResult],
        skipped: [SkippedParent],
        zombiesBefore: Int,
        zombiesAfter: Int,
        processesBefore: Int,
        processesAfter: Int
    ) {
        self.startedAt = startedAt
        self.results = results
        self.skipped = skipped
        self.zombiesBefore = zombiesBefore
        self.zombiesAfter = zombiesAfter
        self.processesBefore = processesBefore
        self.processesAfter = processesAfter
    }

    public var zombiesReaped: Int { max(0, zombiesBefore - zombiesAfter) }
    public var slotsFreed: Int { max(0, processesBefore - processesAfter) }
    public var didAnything: Bool { !results.isEmpty }
    /// A run that signalled something but did not actually reduce the zombie count is a
    /// failure, and is reported as such instead of being quietly counted as a success.
    public var verified: Bool { didAnything && zombiesReaped > 0 }

    public var germanSummary: String {
        guard didAnything else {
            return "Keine Kandidaten für die Bereinigung gefunden."
        }
        if verified {
            return "\(Formatting.count(zombiesReaped)) Zombies aufgeräumt, "
                + "\(Formatting.count(slotsFreed)) Slots frei."
        }
        return "Bereinigung ohne Wirkung: Zombie-Anzahl unverändert "
            + "(\(Formatting.count(zombiesAfter)))."
    }
}

/// Selects leaking parents and terminates them.
///
/// The domain facts this encodes, all measured on the affected machine:
///
/// * A zombie cannot be killed. `kill -9 <zombie>` is a no-op — the process is already
///   dead and only holds a process-table slot until its parent reaps it. Therefore the
///   *parent* is the only possible target, never the zombie.
/// * `kill -CHLD <parent>`, the polite nudge that should make a parent reap, was tested
///   against the leaking `agency` wrapper and had no effect.
/// * SIGTERM was tested and ignored by the wrapper.
/// * SIGKILL works: the zombies are reparented to launchd, which reaps them instantly.
///   Killing six wrappers took the machine from 3892 to 565 processes and 3350 to 29
///   zombies.
/// * The wrapper's *live* child survives the wrapper being killed — it is simply
///   reparented to PID 1 and keeps running. This was verified explicitly, and it is why
///   this cleanup is far less destructive than "SIGKILL a process tree" sounds.
public struct ZombieReaper: Sendable {
    private let signaller: ProcessSignalling
    private let sleeper: Sleeping
    private let currentUID: uid_t

    public init(
        signaller: ProcessSignalling = POSIXSignalSender(),
        sleeper: Sleeping = ThreadSleeper(),
        currentUID: uid_t = getuid()
    ) {
        self.signaller = signaller
        self.sleeper = sleeper
        self.currentUID = currentUID
    }

    // MARK: - Target selection

    public struct Selection: Sendable, Equatable {
        public let targets: [ZombieParent]
        public let skipped: [SkippedParent]

        public init(targets: [ZombieParent], skipped: [SkippedParent]) {
            self.targets = targets
            self.skipped = skipped
        }
    }

    /// Pure target selection. Every safety rule lives here and nowhere else, so the
    /// rules can be proven by unit tests without a single real signal being sent.
    ///
    /// The order of the checks matters: the unconditional protections (PID 1, ownership,
    /// own ancestry) are applied before the tunable ones (policy, threshold), so no
    /// preference value can ever unlock them.
    ///
    /// Candidates are considered in "idle first" order — a parent with no live session
    /// child before one that still has work attached, and only then by zombie count.
    /// Ancestry alone is not enough here: when the app is started by launchd at login,
    /// its ancestor set is just `{self, 1}` and protects nothing of the user's session
    /// tree, so liveness has to carry the weight instead.
    public func selectTargets(in snapshot: ZombieSnapshot, policy: CleanupPolicy) -> Selection {
        var targets: [ZombieParent] = []
        var skipped: [SkippedParent] = []

        let threshold = policy.sessionIdleThreshold
        let ordered = snapshot.offenders.sorted { lhs, rhs in
            let lhsBusy = lhs.isSessionActive(idleThreshold: threshold)
            let rhsBusy = rhs.isSessionActive(idleThreshold: threshold)
            if lhsBusy != rhsBusy { return !lhsBusy }
            if lhs.zombieCount != rhs.zombieCount {
                return lhs.zombieCount > rhs.zombieCount
            }
            return lhs.pid < rhs.pid
        }

        for parent in ordered {
            if parent.pid <= 1 {
                skipped.append(SkippedParent(parent: parent, reason: .initProcess))
                continue
            }
            if parent.uid != currentUID {
                skipped.append(SkippedParent(parent: parent, reason: .foreignUID))
                continue
            }
            if snapshot.protectedPIDs.contains(parent.pid) {
                skipped.append(SkippedParent(parent: parent, reason: .protectedAncestor))
                continue
            }
            if parent.parentIsZombie {
                skipped.append(SkippedParent(parent: parent, reason: .parentIsZombie))
                continue
            }
            if policy.spareParentsWithActiveSession
                && parent.isSessionActive(idleThreshold: threshold)
            {
                skipped.append(SkippedParent(parent: parent, reason: .hasActiveSession))
                continue
            }
            if !policy.permits(parent) {
                skipped.append(SkippedParent(parent: parent, reason: .notPermittedByPolicy))
                continue
            }
            if parent.zombieCount < policy.minimumZombiesPerParent {
                skipped.append(SkippedParent(parent: parent, reason: .belowZombieThreshold))
                continue
            }
            if targets.count >= policy.maximumTargetsPerRun {
                skipped.append(SkippedParent(parent: parent, reason: .runLimitReached))
                continue
            }
            targets.append(parent)
        }

        return Selection(targets: targets, skipped: skipped)
    }

    // MARK: - Termination

    /// Terminates one parent, escalating SIGTERM → SIGKILL.
    ///
    /// SIGTERM is attempted first even though the known offender ignores it: this app
    /// may well meet a better-behaved leaking parent, and a clean shutdown is always
    /// preferable. Escalation happens only after the grace period, and which signal
    /// actually worked is recorded.
    public func terminate(_ parent: ZombieParent, policy: CleanupPolicy) -> ReapResult {
        var sent: [Int32] = []

        guard signaller.isAlive(pid: parent.pid) else {
            return ReapResult(parent: parent, outcome: .alreadyGone, signalsSent: sent)
        }

        guard signaller.send(signal: SIGTERM, to: parent.pid) else {
            // Delivery failed outright. Do not escalate: something is wrong with the
            // assumption that this pid is ours to signal.
            return ReapResult(
                parent: parent, outcome: .signalFailed(signal: SIGTERM), signalsSent: sent)
        }
        sent.append(SIGTERM)

        sleeper.sleep(for: policy.terminationGracePeriod)
        if !signaller.isAlive(pid: parent.pid) {
            return ReapResult(parent: parent, outcome: .terminatedBySIGTERM, signalsSent: sent)
        }

        guard signaller.send(signal: SIGKILL, to: parent.pid) else {
            return ReapResult(
                parent: parent, outcome: .signalFailed(signal: SIGKILL), signalsSent: sent)
        }
        sent.append(SIGKILL)

        // SIGKILL cannot be caught, but the kernel still needs a moment to tear the
        // process down before liveness reflects it.
        sleeper.sleep(for: 0.3)
        let outcome: ReapOutcome =
            signaller.isAlive(pid: parent.pid) ? .survived : .terminatedBySIGKILL
        return ReapResult(parent: parent, outcome: outcome, signalsSent: sent)
    }

    public func terminate(_ parents: [ZombieParent], policy: CleanupPolicy) -> [ReapResult] {
        parents.map { terminate($0, policy: policy) }
    }
}
