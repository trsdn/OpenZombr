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
    /// One. The override exists to buy slots back, not to clear the table.
    public static let defaultMaximumEmergencyOverrides = 1

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
    /// How many parents one run may reap through the override. Deliberately one: the
    /// worst offender alone freed 526 slots, and if that is not enough the next poll can
    /// take the next one, with fresh evidence.
    public var maximumEmergencyOverrides: Int

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
        maximumEmergencyOverrides: Int = CleanupPolicy.defaultMaximumEmergencyOverrides
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
        self.maximumEmergencyOverrides = max(0, maximumEmergencyOverrides)
    }

    /// Whether the machine is out of room, and the idle protection may therefore be
    /// bypassed for the single worst offender.
    public func isUnderEmergencyPressure(_ snapshot: ZombieSnapshot) -> Bool {
        guard emergencyOverrideEnabled, maximumEmergencyOverrides > 0 else { return false }
        return snapshot.freeSlotFraction <= emergencyFreeSlotFraction
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
    /// The machine is out of slots and this parent has an active session, but the run's
    /// emergency override was already spent on a worse offender. Recorded separately so a
    /// protected parent at 0 free slots never looks like an ordinary "session is busy".
    case emergencyBudgetSpent

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
        case .emergencyBudgetSpent:
            return "aktive Sitzung — Notfall-Kontingent bereits verbraucht"
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
