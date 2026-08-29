import Darwin
import Foundation

/// Reads the whole process table through `sysctl(KERN_PROC, KERN_PROC_ALL)`.
///
/// This is deliberately not `ps`: the app polls on a timer, and every `ps` invocation
/// would itself `fork()` — the exact operation that is failing when the process table is
/// exhausted. A watchdog that cannot take a reading precisely when things go wrong is
/// useless, so the reading path allocates a buffer and makes one syscall instead.
public struct SysctlProcessEnumerator: ProcessEnumerating {
    /// `kp_proc.p_stat` value for "dead, awaiting collection by parent".
    public static let zombieState = SZOMB

    private let maximumAttempts: Int

    public init(maximumAttempts: Int = 5) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public func enumerateProcesses() throws -> [ProcessEntry] {
        let raw = try readProcessTable()
        let bootTime = Self.bootTime()
        return raw.map { Self.entry(from: $0, bootTime: bootTime) }
    }

    public func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    public func cpuSeconds(for pid: pid_t) -> TimeInterval? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // `pti_total_user` / `pti_total_system` are in mach absolute time units, not
        // nanoseconds. On Apple Silicon the timebase is 125/3, so skipping this
        // conversion under-reports CPU time by a factor of ~41.7. Verified against
        // `ps -o time=`: raw 1.778 became the correct 74.48 s once converted.
        let raw = Double(info.pti_total_user &+ info.pti_total_system)
        return raw * Self.timebaseNumerator / Self.timebaseDenominator / 1_000_000_000
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private static let timebaseNumerator = Double(timebase.numer)
    private static let timebaseDenominator = Double(timebase.denom)

    // MARK: - Raw table

    /// The table can grow between sizing and reading, which makes `sysctl` return
    /// `ENOMEM`. Retry with a fresh size, and over-allocate slightly so a few processes
    /// spawning mid-read do not cost another round trip. On a leaking machine this race
    /// is not hypothetical: hundreds of processes appear per minute.
    private func readProcessTable() throws -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        for _ in 0..<maximumAttempts {
            var required = 0
            guard sysctl(&mib, 4, nil, &required, nil, 0) == 0 else {
                throw ProcessTableError.sysctlFailed(name: "kern.proc.all", errno: errno)
            }
            guard required > 0 else { throw ProcessTableError.unexpectedSize }

            let slack = 64 * stride
            var capacity = required + slack
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity / stride + 1)

            let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                capacity = pointer.count * stride
                return sysctl(&mib, 4, pointer.baseAddress, &capacity, nil, 0)
            }

            if status == 0 {
                let count = capacity / stride
                return Array(buffer.prefix(count))
            }
            if errno != ENOMEM {
                throw ProcessTableError.sysctlFailed(name: "kern.proc.all", errno: errno)
            }
        }
        throw ProcessTableError.sysctlFailed(name: "kern.proc.all", errno: ENOMEM)
    }

    private static func entry(from proc: kinfo_proc, bootTime: Date) -> ProcessEntry {
        let mutable = proc
        var comm = mutable.kp_proc.p_comm
        let commSize = MemoryLayout.size(ofValue: comm)
        let name = withUnsafePointer(to: &comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: commSize) {
                String(cString: $0)
            }
        }
        let start = mutable.kp_proc.p_un.__p_starttime
        let startTime = Date(
            timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)

        return ProcessEntry(
            pid: mutable.kp_proc.p_pid,
            ppid: mutable.kp_eproc.e_ppid,
            uid: mutable.kp_eproc.e_ucred.cr_uid,
            name: name,
            isZombie: mutable.kp_proc.p_stat == zombieState,
            // A zero start time (seen for a few kernel tasks) would render as 1970 and
            // produce an absurd age, so fall back to boot time.
            startTime: start.tv_sec == 0 ? bootTime : startTime
        )
    }

    private static func bootTime() -> Date {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: Double(value.tv_sec))
    }

    /// Reads a process's argument vector via `KERN_PROCARGS2`.
    ///
    /// The buffer layout is: a 4 byte argc, the executable path, then a run of padding
    /// NULs, then argc NUL-terminated arguments, then the environment. Only the arguments
    /// are returned. Readable for processes of the same uid, which is the only case this
    /// is ever called for.
    public func arguments(for pid: pid_t) -> [String]? {
        var argumentMax: Int = 0
        var sizeName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maxSize = MemoryLayout<Int>.size
        guard sysctl(&sizeName, 2, &argumentMax, &maxSize, nil, 0) == 0, argumentMax > 0
        else { return nil }

        var buffer = [CChar](repeating: 0, count: argumentMax)
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentMax
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        // Skip the executable path, then the padding NULs that follow it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var current: [CChar] = []
        while index < size, arguments.count < Int(argc) {
            let byte = buffer[index]
            if byte == 0 {
                current.append(0)
                arguments.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        return arguments
    }
}

/// Reads the process ceilings at runtime.
///
/// Never hardcoded: `kern.maxprocperuid` is 4000 on the machine this app was written for,
/// but it is a tunable and the thresholds are percentages of whatever it currently is.
public struct SysctlProcessLimitReader: ProcessLimitReading {
    public init() {}

    /// All three ceilings. Only `kern.maxprocperuid` is required; the other two degrade
    /// to `nil`, which `ProcessLimits` treats as "does not constrain" rather than as
    /// zero, so an unreadable limit can never fabricate pressure that is not there.
    public func processLimits() throws -> ProcessLimits {
        ProcessLimits(
            perUID: try maximumProcessesPerUID(),
            softNProc: Self.softProcessLimit(),
            systemWide: try? maximumProcesses()
        )
    }

    public func maximumProcessesPerUID() throws -> Int {
        try Self.integer(forName: "kern.maxprocperuid")
    }

    /// System-wide limit, shared with every other uid.
    public func maximumProcesses() throws -> Int {
        try Self.integer(forName: "kern.maxproc")
    }

    /// `RLIMIT_NPROC` — the soft per-uid process limit this process inherited.
    ///
    /// This is the limit that actually bit during the incident. It is handed down from
    /// launchd at login and raising `kern.maxprocperuid` afterwards does not change it,
    /// so the two can disagree indefinitely: measured, `kern.maxprocperuid` read 4000
    /// while `launchctl limit maxproc` still reported a soft limit of 2666, and the uid
    /// sat above 2666 for nine hours unable to fork.
    ///
    /// Read with `getrlimit`, a syscall. Not by shelling out to `ulimit` or `launchctl`:
    /// every subprocess is a `fork()`, which is precisely the operation that fails in the
    /// condition being monitored.
    ///
    /// Reading our *own* rlimit is the honest measurement, not an approximation. Started
    /// at login the app is a child of launchd, exactly like the user's terminal and every
    /// session wrapper, so it inherits the same value they do.
    static func softProcessLimit() -> Int? {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NPROC, &limits) == 0 else { return nil }
        // An unlimited soft limit constrains nothing, and must not be truncated into a
        // very small `Int` on the way through.
        guard limits.rlim_cur < Self.unlimitedRLimit, limits.rlim_cur <= rlim_t(Int.max) else {
            return nil
        }
        return Int(limits.rlim_cur)
    }

    /// `RLIM_INFINITY`, restated because it is a C macro
    /// (`(((__uint64_t)1 << 63) - 1)`) and so is not imported into Swift.
    private static let unlimitedRLimit = rlim_t(UInt64(1) << 63) - 1

    private static func integer(forName name: String) throws -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            throw ProcessTableError.sysctlFailed(name: name, errno: errno)
        }
        return Int(value)
    }

}
