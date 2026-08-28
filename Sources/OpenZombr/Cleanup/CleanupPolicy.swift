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

    public init(
        minimumZombiesPerParent: Int = CleanupPolicy.defaultMinimumZombies,
        allowedNamePatterns: [String] = CleanupPolicy.defaultAllowedPatterns,
        deniedNamePatterns: [String] = [],
        terminationGracePeriod: TimeInterval = 2,
        maximumTargetsPerRun: Int = 10
    ) {
        self.minimumZombiesPerParent = max(1, minimumZombiesPerParent)
        self.allowedNamePatterns = allowedNamePatterns.filter { !$0.isEmpty }
        self.deniedNamePatterns = deniedNamePatterns.filter { !$0.isEmpty }
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.maximumTargetsPerRun = max(1, maximumTargetsPerRun)
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

    public var germanDescription: String {
        switch self {
        case .belowZombieThreshold: return "unter der Zombie-Schwelle"
        case .protectedAncestor: return "geschützt (eigener Prozess oder Vorfahre)"
        case .initProcess: return "launchd (PID 1) wird nie beendet"
        case .foreignUID: return "gehört einem anderen Benutzer"
        case .notPermittedByPolicy: return "nicht in der Erlaubnisliste"
        case .parentIsZombie: return "Elternprozess ist selbst ein Zombie"
        case .runLimitReached: return "Limit pro Durchlauf erreicht"
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
