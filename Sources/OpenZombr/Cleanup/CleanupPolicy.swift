import Foundation

/// Constrains which processes the cleanup routine is allowed to touch.
///
/// The default allowlist matches only `agency` wrappers, because that is the one process
/// known to leak. An empty allowlist matches nothing: the policy is fail-closed on
/// purpose, so a user who clears the field disables cleanup rather than pointing it at
/// every process on the machine.
public struct CleanupPolicy: Sendable, Equatable {
    public static let defaultAllowedPatterns = ["agency"]
    public static let defaultMinimumZombies = 100
    /// Two hours. Long enough that a user thinking, reading, or at lunch is never
    /// mistaken for a finished session; short enough that a machine leaking 600 zombies
    /// an hour is rescued well before it reaches the fork limit.
    public static let defaultSessionIdleThreshold: TimeInterval = 2 * 3600
    /// Five percent of the effective limit. Below this the machine is at the wall, not
    /// approaching it.
    public static let defaultEmergencyFreeSlotFraction = 0.05

    /// A parent is only ever considered once it owns at least this many zombies.
    /// Reaping a handful of zombies is not worth killing a process over.
    public var minimumZombiesPerParent: Int
    /// Case-insensitive substring patterns matched against the parent's name and full
    /// executable path. At least one must match.
    public var allowedNamePatterns: [String]
    /// Patterns that veto a match even when the allowlist accepted it. The denylist
    /// always wins.
    public var deniedNamePatterns: [String]
    /// How long to wait for a SIGTERM to take effect before escalating to SIGKILL.
    public var terminationGracePeriod: TimeInterval
    /// Upper bound on how many parents a single cleanup run may signal, so a
    /// misconfigured allowlist cannot cascade across the machine.
    public var maximumTargetsPerRun: Int
    /// When true, a parent that still has a live child running a different executable is
    /// never signalled, however many zombies it owns.
    ///
    /// This is the guard that survives launch-at-login. Ancestor protection only works
    /// while the app is a descendant of the process it must not kill; started by launchd
    /// the ancestor set collapses to `{self, 1}` and protects nothing of the user's
    /// session tree. Liveness is independent of how the app itself was started.
    ///
    /// Disabling it is survivable but should be a deliberate choice: killing an `agency`
    /// wrapper was measured to leave its live `copilot` child running, reparented to
    /// launchd. It is off the default path all the same, because "the damage happened to
    /// be recoverable" is not a safety argument.
    public var spareParentsWithActiveSession: Bool
    /// How long a session child must have consumed no CPU before its parent stops being
    /// treated as busy.
    ///
    /// Deliberately hours, not minutes. Sampling over 20 s during the incident showed the
    /// user's own session child idle simply because they were between turns, so a short
    /// window would reap a live session that happens to be thinking. The wrappers that
    /// actually needed reaping had been idle for hours - one for five.
    public var sessionIdleThreshold: TimeInterval
    /// Whether the idle protection may be bypassed once free slots run out.
    ///
    /// The 2 h idle rule is correct while there is room to be patient, and wrong at the
    /// wall. Measured during the incident: the worst offender held 526 zombies for hours,
    /// but its idle clock kept restarting — `cpu_idle=1560; log_age=1607` at 22:42, back
    /// to `cpu_idle=0` at 23:01 — so it never once accumulated two idle hours and was
    /// protected the entire time. The manual cleanup at 22:42 logged `no-targets` against
    /// 2038 zombies because of it.
    ///
    /// The argument for overriding is not that the session is finished; it is that at
    /// zero free slots the protection has stopped protecting anything. A session that
    /// cannot `fork()` is already broken, and every other session on the machine is
    /// broken with it. Killing the wrapper was measured to leave its live `copilot` child
    /// running, reparented to launchd, so the bounded cost is one wrapper against a
    /// machine that otherwise has to be rebooted — which is what actually happened.
    public var emergencyOverrideEnabled: Bool
    /// Share of the effective limit that must still be free for the idle protection to
    /// hold unconditionally. At or below it, the override may fire.
    public var emergencyFreeSlotFraction: Double
    /// Usage the override tries to get back below before it stops taking targets.
    ///
    /// This replaces a fixed budget of one override per run, which was measured to lose
    /// the race. At 01:25 on 2026-08-30 the machine sat at 95 % with eight leaking
    /// wrappers; the single override freed 295 slots and dropped usage to 84 %, still
    /// critical. The leak was growing at 93,5 slots/min, so those 295 slots were spent
    /// again in about three minutes — against a two-minute cooldown, one kill per run
    /// barely broke even and would have taken sixteen minutes to work through the eight
    /// wrappers, at 95 % usage the whole time.
    ///
    /// Expressed as a target rather than a count because that is what makes it
    /// self-limiting: if reaping one parent is enough, exactly one is reaped. It is set
    /// from the user's critical threshold, so "enough" means the same thing here as it
    /// does everywhere else in the app.
    public var emergencyRecoveryUsageFraction: Double

    public init(
        minimumZombiesPerParent: Int = CleanupPolicy.defaultMinimumZombies,
        allowedNamePatterns: [String] = CleanupPolicy.defaultAllowedPatterns,
        deniedNamePatterns: [String] = [],
        terminationGracePeriod: TimeInterval = 2,
        maximumTargetsPerRun: Int = 10,
        spareParentsWithActiveSession: Bool = true,
        sessionIdleThreshold: TimeInterval = CleanupPolicy.defaultSessionIdleThreshold,
        emergencyOverrideEnabled: Bool = true,
        emergencyFreeSlotFraction: Double = CleanupPolicy.defaultEmergencyFreeSlotFraction,
        emergencyRecoveryUsageFraction: Double = Thresholds.defaultCriticalFraction
    ) {
        self.minimumZombiesPerParent = max(1, minimumZombiesPerParent)
        self.allowedNamePatterns = allowedNamePatterns.filter { !$0.isEmpty }
        self.deniedNamePatterns = deniedNamePatterns.filter { !$0.isEmpty }
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.maximumTargetsPerRun = max(1, maximumTargetsPerRun)
        self.spareParentsWithActiveSession = spareParentsWithActiveSession
        self.sessionIdleThreshold = max(60, sessionIdleThreshold)
        self.emergencyOverrideEnabled = emergencyOverrideEnabled
        // Clamped below 0.5: an override that fires at half-empty is not an emergency
        // measure, it is the normal path with the safety rule switched off.
        self.emergencyFreeSlotFraction = min(max(emergencyFreeSlotFraction, 0), 0.5)
        // Capped at the point where the pressure trigger releases, so the override always
        // climbs *out* of the emergency zone. A recovery target above `1 - free-slot
        // fraction` would be satisfied while the machine is still at the wall, and the
        // override would fire again on the very next poll — reaping in a loop rather than
        // reaching a stable state. Floored well below that so it stays a real target.
        self.emergencyRecoveryUsageFraction = min(
            max(emergencyRecoveryUsageFraction, 0.1), 1 - self.emergencyFreeSlotFraction)
    }

    /// Whether the machine is out of room, and the idle protection may therefore be
    /// bypassed for the parents that have been quiet longest.
    public func isUnderEmergencyPressure(_ snapshot: ZombieSnapshot) -> Bool {
        guard emergencyOverrideEnabled else { return false }
        return snapshot.freeSlotFraction <= emergencyFreeSlotFraction
    }

    /// Whether `projectedProcesses` is still above the recovery target, i.e. whether the
    /// override has more work to do after the targets already chosen.
    public func needsMoreRelief(projectedProcesses: Int, limit: Int) -> Bool {
        guard limit > 0 else { return false }
        return Double(projectedProcesses) / Double(limit) >= emergencyRecoveryUsageFraction
    }

    /// Substring matching, not regex: the patterns are typed by a user into a
    /// preferences field, and a malformed regex silently matching everything would be a
    /// dangerous failure mode for something that sends SIGKILL.
    public func permits(_ parent: ZombieParent) -> Bool {
        let haystack = parent.matchableText.lowercased()
        guard !allowedNamePatterns.isEmpty else { return false }
        if deniedNamePatterns.contains(where: { haystack.contains($0.lowercased()) }) {
            return false
        }
        return allowedNamePatterns.contains(where: { haystack.contains($0.lowercased()) })
    }
}

/// Why a parent that owns zombies was not signalled. Surfaced in the UI and the CSV log
/// so that "nothing happened" is always explainable.
public enum SkipReason: String, Sendable, Equatable {
    case belowZombieThreshold
    case protectedAncestor
    case initProcess
    case foreignUID
    case notPermittedByPolicy
    case parentIsZombie
    case runLimitReached
    case hasActiveSession
    /// Protected because at least one idle signal could not be read at all, so the app has
    /// no basis for a decision. Distinct from `hasActiveSession`, which means the signals
    /// were read and said the session is alive. Both prevent a kill, but only this one is
    /// a degraded state the user may want to act on.
    ///
    /// The emergency override deliberately does *not* apply here. Absence of evidence must
    /// never read as evidence of idleness, and least of all under pressure, when the
    /// temptation to act is greatest.
    case sessionSignalUnavailable
    /// The machine is out of slots and this parent has an active session, but the targets
    /// already chosen are projected to bring usage back under the recovery threshold.
    /// Recorded separately so a protected parent at 0 free slots never looks like an
    /// ordinary "session is busy".
    case emergencyReliefReached

    public var germanDescription: String {
        switch self {
        case .belowZombieThreshold: return "unter der Zombie-Schwelle"
        case .protectedAncestor: return "geschützt (eigener Prozess oder Vorfahre)"
        case .initProcess: return "launchd (PID 1) wird nie beendet"
        case .foreignUID: return "gehört einem anderen Benutzer"
        case .notPermittedByPolicy: return "nicht in der Erlaubnisliste"
        case .parentIsZombie: return "Elternprozess ist selbst ein Zombie"
        case .runLimitReached: return "Limit pro Durchlauf erreicht"
        case .hasActiveSession: return "hat eine aktive Sitzung (Kindprozess arbeitet)"
        case .sessionSignalUnavailable:
            return "Sitzungssignale nicht lesbar — keine Entscheidungsgrundlage"
        case .emergencyReliefReached:
            return "aktive Sitzung — Notfall-Entlastung bereits erreicht"
        }
    }
}

public struct SkippedParent: Sendable, Equatable {
    public let parent: ZombieParent
    public let reason: SkipReason

    public init(parent: ZombieParent, reason: SkipReason) {
        self.parent = parent
        self.reason = reason
    }
}
