import Foundation

/// Computes the set of PIDs that must never be signalled.
///
/// This exists because of a concrete near-miss: on the machine this app was written for,
/// the live ancestor chain was `bash → copilot(87594) → agency copilot(87537) →
/// GitHub Copilot.app(4264)`. PID 87537 was an `agency` wrapper holding ~600 zombies —
/// exactly the shape of process the cleanup routine targets. Killing it would have
/// severed the user's own running session.
///
/// The protection is therefore computed dynamically from the live process table on every
/// poll, and never hardcoded to a pid or a name.
public enum ProcessProtection {
    /// `getpid()` plus every ancestor up to (and including) PID 1.
    ///
    /// Walks `ppid` links with a visited set, so a malformed or recycled table cannot
    /// send this into an infinite loop.
    public static func protectedPIDs(of pid: pid_t, in entries: [ProcessEntry]) -> Set<pid_t> {
        let parents = Dictionary(
            entries.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })

        var protected: Set<pid_t> = [pid]
        var current = pid
        while let parent = parents[current], parent > 0, !protected.contains(parent) {
            protected.insert(parent)
            current = parent
        }
        // launchd is protected unconditionally, even if it never showed up in the walk.
        protected.insert(1)
        return protected
    }
}
