import Darwin
import XCTest

@testable import OpenZombrKit

/// `POSIXSignalSender.isAlive` against the real kernel.
///
/// These use a real child process because the bug being pinned is precisely an
/// integration one: `kill(pid, 0)` succeeds for a zombie, so every mock in the suite
/// agreed with the old implementation while the live machine did not.
final class ProcessLivenessTests: XCTestCase {
    private let sender = POSIXSignalSender()

    func testOwnProcessIsAlive() {
        XCTAssertTrue(sender.isAlive(pid: getpid()))
    }

    /// A zombie is not alive.
    ///
    /// SIGKILLing a wrapper turns it into a zombie for as long as it takes its parent to
    /// reap it, so an escalation that asked `kill(pid, 0)` concluded the target had
    /// survived a signal it cannot survive. Observed live at 01:25:38Z:
    /// `kill:15+9 … survived;reaped=264;freed=295;verified=true` — one row asserting both
    /// that the target lived and that its 264 zombies had been released.
    func testAZombieIsNotAlive() throws {
        let child = try spawnImmediatelyExitingChild()
        defer { var status: Int32 = 0; waitpid(child, &status, 0) }

        try waitUntilZombie(child)

        // The old implementation's check, kept here to show it is not equivalent: the
        // kernel still answers for a zombie, which is exactly why it was the wrong test.
        XCTAssertEqual(kill(child, 0), 0, "a zombie still answers kill(pid, 0)")

        XCTAssertFalse(sender.isAlive(pid: child))
    }

    /// Once reaped, the pid is gone rather than a zombie, and must also read as not alive.
    func testAReapedChildIsNotAlive() throws {
        let child = try spawnImmediatelyExitingChild()
        try waitUntilZombie(child)
        var status: Int32 = 0
        waitpid(child, &status, 0)

        XCTAssertFalse(sender.isAlive(pid: child))
    }

    // MARK: - Helpers

    private func spawnImmediatelyExitingChild() throws -> pid_t {
        var pid: pid_t = 0
        let path = "/usr/bin/true"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }

        let result = posix_spawn(&pid, path, nil, nil, &argv, nil)
        try XCTSkipUnless(result == 0, "posix_spawn failed: \(result)")
        return pid
    }

    /// Polls until the child has exited but not yet been reaped. Deliberately does not
    /// `waitpid`, because that is what would collect it.
    private func waitUntilZombie(_ pid: pid_t) throws {
        for _ in 0..<200 {
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            if sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0,
                size >= MemoryLayout<kinfo_proc>.stride,
                info.kp_proc.p_stat == SysctlProcessEnumerator.zombieState
            {
                return
            }
            usleep(10_000)
        }
        throw XCTSkip("child never became a zombie within 2 s")
    }
}
