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
    /// Live (non-zombie) children of this parent.
    ///
    /// On its own this does *not* distinguish a leaking wrapper from one hosting real
    /// work: measured on the affected machine, every `agency` wrapper had live children,
    /// because the leak itself is a stream of short-lived children.
    public let liveChildCount: Int
    /// Live children running a *different* executable than the parent.
    ///
    /// This is the signal that actually discriminates. The leak is `agency` spawning
    /// `agency` telemetry children, so those self-spawns share the parent's name. A
    /// wrapper that is hosting real work additionally has a `copilot` child, which does
    /// not. Measured: wrapper 1332 held 41 zombies and dozens of `agency` self-spawns
    /// while hosting the user's live session as a single `copilot` child.
    public let sessionChildCount: Int
    /// The pids behind `sessionChildCount`, so their CPU time can be sampled.
    public let sessionChildPIDs: [pid_t]
    /// How long the *least* idle session child has gone without consuming CPU, or `nil`
    /// when there is no history for it yet.
    ///
    /// `nil` means "no evidence", which is read as active. A wrapper is only idle if
    /// every one of its session children is idle, hence the minimum.
    public let sessionIdleSeconds: TimeInterval?

    /// True when the parent still has a live child that is not one of its own
    /// short-lived self-spawns, i.e. it is plausibly hosting real work.
    public var hasActiveSession: Bool { sessionChildCount > 0 }

    /// Whether the session should be treated as live, given how long a child must be
    /// idle before it stops counting.
    ///
    /// A session child that exists but has burned no CPU for hours is a finished session
    /// that simply has not exited. That describes every wrapper reaped during the
    /// incident, so without this the guard would protect exactly the processes that need
    /// reaping.
    public func isSessionActive(idleThreshold: TimeInterval) -> Bool {
        guard hasActiveSession else { return false }
        guard let idle = sessionIdleSeconds else { return true }
        return idle < idleThreshold
    }

    public var id: pid_t { pid }

    public init(
        pid: pid_t,
        uid: uid_t,
        name: String,
        executablePath: String? = nil,
        zombieCount: Int,
        startTime: Date,
        parentIsZombie: Bool = false,
        liveChildCount: Int = 0,
        sessionChildCount: Int = 0,
        sessionChildPIDs: [pid_t] = [],
        sessionIdleSeconds: TimeInterval? = nil
    ) {
        self.pid = pid
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.zombieCount = zombieCount
        self.startTime = startTime
        self.parentIsZombie = parentIsZombie
        self.liveChildCount = max(0, liveChildCount)
        self.sessionChildCount = max(0, sessionChildCount)
        self.sessionChildPIDs = sessionChildPIDs
        self.sessionIdleSeconds = sessionIdleSeconds
    }

    /// Copy with idle information filled in, once CPU time has been sampled.
    public func withSessionIdle(_ seconds: TimeInterval?) -> ZombieParent {
        ZombieParent(
            pid: pid, uid: uid, name: name, executablePath: executablePath,
            zombieCount: zombieCount, startTime: startTime, parentIsZombie: parentIsZombie,
            liveChildCount: liveChildCount, sessionChildCount: sessionChildCount,
            sessionChildPIDs: sessionChildPIDs, sessionIdleSeconds: seconds)
    }

    public func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startTime))
    }

    /// Text the allow/deny patterns are matched against: short name plus full path.
    public var matchableText: String {
        [name, executablePath ?? ""].joined(separator: " ")
    }
}
