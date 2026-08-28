import Foundation

/// One row of the kernel process table, reduced to the fields this app reasons about.
///
/// Deliberately a plain value type: every safety decision in `ZombieReaper` is made
/// against these structs, so the whole decision path can be unit tested without
/// touching a real process.
public struct ProcessEntry: Sendable, Equatable, Hashable, Identifiable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    /// `p_comm` from the kernel: the executable name, truncated to 16 characters.
    public let name: String
    /// `true` when `kp_proc.p_stat == SZOMB`, i.e. the process is dead and only
    /// occupies a slot in the process table until its parent calls `wait()`.
    public let isZombie: Bool
    public let startTime: Date

    public var id: pid_t { pid }

    public init(
        pid: pid_t,
        ppid: pid_t,
        uid: uid_t,
        name: String,
        isZombie: Bool,
        startTime: Date
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.isZombie = isZombie
        self.startTime = startTime
    }

    public func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startTime))
    }
}

/// A parent process together with the number of zombie children it is failing to reap.
///
/// This is the unit the cleanup routine operates on. Note that the *zombies* are never
/// the target: a zombie cannot be killed, only its parent can be made to release it.
public struct ZombieParent: Sendable, Equatable, Hashable, Identifiable {
    public let pid: pid_t
    public let uid: uid_t
    public let name: String
    /// Full executable path, when it could be resolved. Used for allow/deny matching so
    /// that `agency` wrappers can be distinguished from unrelated binaries of the same
    /// short name.
    public let executablePath: String?
    public let zombieCount: Int
    public let startTime: Date
    /// A parent can itself be a zombie. Signalling it is pointless, so this is tracked
    /// and used as a skip reason.
    public let parentIsZombie: Bool

    public var id: pid_t { pid }

    public init(
        pid: pid_t,
        uid: uid_t,
        name: String,
        executablePath: String? = nil,
        zombieCount: Int,
        startTime: Date,
        parentIsZombie: Bool = false
    ) {
        self.pid = pid
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.zombieCount = zombieCount
        self.startTime = startTime
        self.parentIsZombie = parentIsZombie
    }

    public func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startTime))
    }

    /// Text the allow/deny patterns are matched against: short name plus full path.
    public var matchableText: String {
        [name, executablePath ?? ""].joined(separator: " ")
    }
}
