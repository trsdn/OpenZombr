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
    /// The process at that PID is no longer the one the safety rules approved, so it is
    /// not signalled. Distinct from `alreadyGone`, which is the benign case of a target
    /// that simply exited: this one means a *different* process now holds the number.
    case identityChanged
    /// A signal could not be delivered at all.
    case signalFailed(signal: Int32)

    public var germanDescription: String {
        switch self {
        case .terminatedBySIGTERM: return "durch SIGTERM beendet"
        case .terminatedBySIGKILL: return "durch SIGKILL beendet"
        case .survived: return "überlebt (nicht beendet)"
        case .alreadyGone: return "war bereits beendet"
        case .identityChanged: return "PID gehört inzwischen einem anderen Prozess"
        case .signalFailed(let signal): return "Signal \(signal) fehlgeschlagen"
        }
    }

    public var succeeded: Bool {
        switch self {
        case .terminatedBySIGTERM, .terminatedBySIGKILL, .alreadyGone: return true
        case .survived, .signalFailed, .identityChanged: return false
        }
    }

    /// Short token for the CSV evidence log.
    public var logToken: String {
        switch self {
        case .terminatedBySIGTERM: return "sigterm"
        case .terminatedBySIGKILL: return "sigkill"
        case .survived: return "survived"
        case .alreadyGone: return "already-gone"
        case .identityChanged: return "identity-changed"
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
    /// True when this parent only became a target because the machine was out of slots
    /// and the idle protection was bypassed for it.
    public let wasEmergencyOverride: Bool

    public init(
        parent: ZombieParent,
        outcome: ReapOutcome,
        signalsSent: [Int32],
        wasEmergencyOverride: Bool = false
    ) {
        self.parent = parent
        self.outcome = outcome
        self.signalsSent = signalsSent
        self.wasEmergencyOverride = wasEmergencyOverride
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
    /// True when at least one target only qualified because the machine was out of slots.
    public var usedEmergencyOverride: Bool { results.contains(where: \.wasEmergencyOverride) }
    /// A run that signalled something but did not actually reduce the zombie count is a
    /// failure, and is reported as such instead of being quietly counted as a success.
    public var verified: Bool { didAnything && zombiesReaped > 0 }

    public var germanSummary: String {
        guard didAnything else {
            let blind = skipped.filter { $0.reason == .sessionSignalUnavailable }.count
            guard blind > 0 else {
                return "Keine Kandidaten für die Bereinigung gefunden."
            }
            // Saying only "no candidates" here would hide the fact that the app could not
            // see well enough to have candidates.
            return "Keine Kandidaten — bei \(Formatting.count(blind)) Prozessen sind die "
                + "Sitzungssignale nicht lesbar."
        }
        // An override killed something the normal rules would have spared, so it is named
        // rather than folded into the ordinary success line.
        let prefix = usedEmergencyOverride ? "Notfall-Bereinigung: " : ""
        if verified {
            return prefix + "\(Formatting.count(zombiesReaped)) Zombies aufgeräumt, "
                + "\(Formatting.count(slotsFreed)) Slots frei."
        }
        return prefix + "Bereinigung ohne Wirkung: Zombie-Anzahl unverändert "
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
        /// Targets that only qualified because the machine was out of slots. Carried
        /// through to the report and the evidence log, so an override is never silently
        /// indistinguishable from an ordinary reap.
        public let emergencyOverrides: Set<pid_t>

        public init(
            targets: [ZombieParent],
            skipped: [SkippedParent],
            emergencyOverrides: Set<pid_t> = []
        ) {
            self.targets = targets
            self.skipped = skipped
            self.emergencyOverrides = emergencyOverrides
        }
    }

    /// Pure target selection. Every safety rule lives here and nowhere else, so the
    /// rules can be proven by unit tests without a single real signal being sent.
    ///
    /// The order of the checks matters: the unconditional protections (PID 1, ownership,
    /// own ancestry) are applied before the tunable ones (policy, threshold), so no
    /// preference value can ever unlock them. The emergency override below is deliberately
    /// placed after all of them, and can only ever relax `spareParentsWithActiveSession`,
    /// which is a tunable.
    ///
    /// Candidates are considered in "idle first" order — a parent with no live session
    /// child before one that still has work attached, and only then by zombie count.
    /// Ancestry alone is not enough here: when the app is started by launchd at login,
    /// its ancestor set is just `{self, 1}` and protects nothing of the user's session
    /// tree, so liveness has to carry the weight instead.
    ///
    /// That ordering is also what makes the emergency override safe to express as a
    /// budget: every genuinely idle candidate is considered before any active one, so the
    /// override is only ever spent after the harmless targets are exhausted, and then on
    /// the largest offender.
    public func selectTargets(in snapshot: ZombieSnapshot, policy: CleanupPolicy) -> Selection {
        var targets: [ZombieParent] = []
        var skipped: [SkippedParent] = []
        var overrides: Set<pid_t> = []

        let threshold = policy.sessionIdleThreshold
        let underPressure = policy.isUnderEmergencyPressure(snapshot)
        let ordered = snapshot.offenders.sorted { lhs, rhs in
            let lhsBusy = lhs.isSessionActive(idleThreshold: threshold)
            let rhsBusy = rhs.isSessionActive(idleThreshold: threshold)
            if lhsBusy != rhsBusy { return !lhsBusy }

            // Among parents that all still count as busy, the one to sacrifice first is
            // the one with the oldest sign of life — never the one holding the most
            // zombies. This only matters because the emergency override can now reach a
            // busy parent, and getting it wrong is expensive: measured live at 93 % usage,
            // three wrappers all read "active" holding 262 / 257 / 249 zombies with log
            // ages of 16 s, 4736 s and 5206 s. Ranking by zombie count picked the
            // 16-second-old one — the session the user was sitting in — to gain 13 zombies
            // over one that had been silent for 87 minutes.
            //
            // The log age leads because it is the stronger of the two signals: a session
            // delegates its work, so CPU time reads 0 for wrappers that are busy and for
            // wrappers that are finished alike. An unreadable signal sorts as "just alive",
            // so it is picked last — and such a parent is barred from the override anyway.
            if lhsBusy {
                if lhs.sessionLogAgeSeconds != rhs.sessionLogAgeSeconds {
                    return (lhs.sessionLogAgeSeconds ?? 0) > (rhs.sessionLogAgeSeconds ?? 0)
                }
                if lhs.sessionIdleSeconds != rhs.sessionIdleSeconds {
                    return (lhs.sessionIdleSeconds ?? 0) > (rhs.sessionIdleSeconds ?? 0)
                }
            }

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

            // Whether this candidate is only eligible because the machine is at the wall.
            // Decided here but not spent here: the remaining gates (allowlist, zombie
            // threshold, run limit) still have to accept it, and a candidate they reject
            // must not consume the run's single override.
            var needsOverride = false
            if policy.spareParentsWithActiveSession
                && parent.isSessionActive(idleThreshold: threshold)
            {
                if parent.hasUnreadableSessionSignal {
                    // Never overridden. The app cannot see, and pressure does not turn
                    // "unknown" into "idle".
                    skipped.append(
                        SkippedParent(parent: parent, reason: .sessionSignalUnavailable))
                    continue
                }
                guard underPressure, overrides.count < policy.maximumEmergencyOverrides else {
                    skipped.append(
                        SkippedParent(
                            parent: parent,
                            reason: underPressure ? .emergencyBudgetSpent : .hasActiveSession))
                    continue
                }
                needsOverride = true
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
            if needsOverride { overrides.insert(parent.pid) }
            targets.append(parent)
        }

        return Selection(targets: targets, skipped: skipped, emergencyOverrides: overrides)
    }

    // MARK: - Termination

    /// Terminates one parent, escalating SIGTERM → SIGKILL.
    ///
    /// SIGTERM is attempted first even though the known offender ignores it: this app
    /// may well meet a better-behaved leaking parent, and a clean shutdown is always
    /// preferable. Escalation happens only after the grace period, and which signal
    /// actually worked is recorded.
    ///
    /// Every safety rule was evaluated against a `ZombieParent` captured in a *past*
    /// snapshot, and a PID is not an identity — Darwin hands them out sequentially and
    /// wraps. So the identity is re-read from the kernel immediately before each signal,
    /// including before the escalation, because the grace period is itself a window in
    /// which the target can exit and its number be reissued. Selection may be minutes old;
    /// this check is microseconds old.
    public func terminate(
        _ parent: ZombieParent,
        policy: CleanupPolicy,
        wasEmergencyOverride: Bool = false
    ) -> ReapResult {
        var sent: [Int32] = []
        let approved = ProcessIdentity(startTime: parent.startTime, uid: parent.uid)

        func result(_ outcome: ReapOutcome) -> ReapResult {
            ReapResult(
                parent: parent, outcome: outcome, signalsSent: sent,
                wasEmergencyOverride: wasEmergencyOverride)
        }

        guard signaller.isAlive(pid: parent.pid) else {
            return result(.alreadyGone)
        }
        // Unreadable is not "unchanged". Refusing to signal costs one poll interval;
        // signalling the wrong process costs the user their work.
        guard signaller.verifyIdentity(ofPID: parent.pid, matches: approved) == .matches else {
            return result(.identityChanged)
        }

        guard signaller.send(signal: SIGTERM, to: parent.pid) else {
            // Delivery failed outright. Do not escalate: something is wrong with the
            // assumption that this pid is ours to signal.
            return result(.signalFailed(signal: SIGTERM))
        }
        sent.append(SIGTERM)

        sleeper.sleep(for: policy.terminationGracePeriod)
        if !signaller.isAlive(pid: parent.pid) {
            return result(.terminatedBySIGTERM)
        }

        // The grace period is the widest reuse window in the whole routine: the target was
        // just asked to exit, so it is more likely than usual to have done so.
        guard signaller.verifyIdentity(ofPID: parent.pid, matches: approved) == .matches else {
            return result(.identityChanged)
        }

        guard signaller.send(signal: SIGKILL, to: parent.pid) else {
            return result(.signalFailed(signal: SIGKILL))
        }
        sent.append(SIGKILL)

        // SIGKILL cannot be caught, but the kernel still needs a moment to tear the
        // process down before liveness reflects it.
        sleeper.sleep(for: 0.3)
        return result(signaller.isAlive(pid: parent.pid) ? .survived : .terminatedBySIGKILL)
    }

    public func terminate(
        _ parents: [ZombieParent],
        policy: CleanupPolicy,
        emergencyOverrides: Set<pid_t> = []
    ) -> [ReapResult] {
        parents.map {
            terminate(
                $0, policy: policy, wasEmergencyOverride: emergencyOverrides.contains($0.pid))
        }
    }
}
