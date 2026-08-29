import Foundation

/// Which ceiling `fork()` will hit first.
///
/// Recorded alongside every reading, because the incident of 2026-08-29 was not a case of
/// the app failing to measure — it measured diligently, against a limit that was not the
/// one that mattered.
public enum ProcessCeiling: String, Sendable, Equatable, CaseIterable {
    /// `kern.maxprocperuid`.
    case perUID = "per-uid"
    /// `RLIMIT_NPROC`, the soft limit this process inherited from launchd.
    case softNProc = "rlimit-nproc"
    /// `kern.maxproc` less the slots other uids already hold.
    case systemWide = "system-wide"

    /// German for the menu, and deliberately naming the knob the user would have to
    /// change: "per-uid" is not actionable, `kern.maxprocperuid` is.
    public var germanDescription: String {
        switch self {
        case .perUID: return "kern.maxprocperuid"
        case .softNProc: return "RLIMIT_NPROC (ulimit -u)"
        case .systemWide: return "kern.maxproc (systemweit)"
        }
    }
}

/// Every ceiling that can make `fork()` fail, read at runtime.
///
/// Reading `kern.maxprocperuid` on its own is not enough, and the incident of 2026-08-29
/// is the proof. Mid-incident `kern.maxprocperuid` was raised from 2666 to 4000 and the
/// app dutifully followed it. But `RLIMIT_NPROC` — which launchd hands to every process
/// at login, and which writing a sysctl does not change retroactively — stayed at 2666
/// (`launchctl limit maxproc` reported `2666 4000`). For the following nine hours the uid
/// held between 2666 and 2744 processes: `fork()` was already returning EAGAIN and no new
/// session could be started, while the app reported "67,5 % belegt, 1299 Slots frei",
/// never reached its 75 % critical threshold, and therefore never ran a cleanup. Its peak
/// reading for the whole day was 68,6 %.
///
/// So the effective ceiling is the *minimum* of all three, and which one binds is carried
/// with it. "You are at 103 % of a limit you did not know existed" is the single most
/// useful sentence this app can say, and it could not say it.
public struct ProcessLimits: Sendable, Equatable {
    /// `kern.maxprocperuid`.
    public let perUID: Int
    /// `getrlimit(RLIMIT_NPROC).rlim_cur`, or `nil` when unreadable or unlimited.
    public let softNProc: Int?
    /// `kern.maxproc`, or `nil` when unreadable. Shared with every other uid on the
    /// machine, so it only becomes a ceiling after the foreign slots are subtracted.
    public let systemWide: Int?

    public init(perUID: Int, softNProc: Int? = nil, systemWide: Int? = nil) {
        // Stored as read, not clamped into range. A non-positive or missing value means
        // "could not be read", and `binding` ignores it. Clamping it to 1 instead would
        // turn an unreadable limit into a permanent 100 % reading — fabricating maximum
        // pressure out of no information, which is the opposite of what a watchdog that
        // sends SIGKILL should do.
        self.perUID = perUID
        self.softNProc = softNProc
        self.systemWide = systemWide
    }

    /// The ceiling `fork()` reaches first, given how many slots other uids hold.
    ///
    /// Returns a limit of 0 when nothing could be read, which every consumer already
    /// treats as "unknown" rather than as "full".
    ///
    /// Ties resolve towards `perUID`, which is the one a user is most likely to recognise
    /// and the historical behaviour of this app; a tie means the number is the same
    /// anyway, so only the label is affected.
    public func binding(foreignProcesses: Int) -> (limit: Int, ceiling: ProcessCeiling) {
        var winner: (limit: Int, ceiling: ProcessCeiling)?

        func consider(_ value: Int?, _ ceiling: ProcessCeiling) {
            guard let value, value > 0 else { return }
            guard let current = winner else {
                winner = (value, ceiling)
                return
            }
            guard value < current.limit else { return }
            winner = (value, ceiling)
        }

        consider(perUID, .perUID)
        consider(softNProc, .softNProc)
        // The system-wide limit is shared, so what is actually available to this uid is
        // whatever the other uids have not already taken. Floored at 1: if they have taken
        // all of it there is no headroom, and that is a real reading, not a missing one.
        consider(
            systemWide.map { max(1, $0 - max(0, foreignProcesses)) },
            .systemWide)

        return winner ?? (0, .perUID)
    }
}
