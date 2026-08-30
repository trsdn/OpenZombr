import XCTest

@testable import OpenZombrKit

/// TEMPORARY diagnostic. Runs the real selection logic against the *live* process table,
/// modelling the installed app (pid passed in) rather than this test process, so the
/// ancestry protection is the one the installed app actually computes.
final class LiveOverrideCheck: XCTestCase {
    func testWhatTheInstalledAppWouldDo() throws {
        let installedPID = pid_t(
            ProcessInfo.processInfo.environment["OZ_APP_PID"].flatMap { Int32($0) } ?? 1)

        let enumerator = SysctlProcessEnumerator()
        let realLimits = try SysctlProcessLimitReader().processLimits()

        let sampler = ZombieSampler(
            enumerator: enumerator, currentUID: getuid(), currentPID: installedPID)

        // The installed app has been polling for hours, so its IdleTracker has history and
        // the signals read as numbers rather than as "unknown". Two samples reproduce that;
        // one does not, and a single-sample run would wrongly show every parent protected
        // by `sessionSignalUnavailable`.
        let tracker = IdleTracker()
        _ = try sampler.sample(idleTracker: tracker)
        Thread.sleep(forTimeInterval: 3)
        let entries = try enumerator.enumerateProcesses()

        for (label, limits) in [
            ("JETZT (echte Limits)", realLimits),
            (
                "SIMULIERT: 4 % freie Slots",
                ProcessLimits(
                    perUID: realLimits.perUID,
                    softNProc: Int(
                        Double(entries.filter { $0.uid == getuid() }.count) / 0.96),
                    systemWide: realLimits.systemWide)
            ),
        ] {
            let base = sampler.snapshot(from: entries, limits: limits, now: Date())
            let snapshot = sampler.applyingIdle(
                to: base, entries: entries, tracker: tracker, now: Date())
            let policy = CleanupPolicy()
            let selection = ZombieReaper(currentUID: getuid())
                .selectTargets(in: snapshot, policy: policy)

            print("")
            print("=== \(label) ===")
            print(
                "  \(snapshot.totalProcesses) Prozesse / \(snapshot.limit) "
                    + "(\(String(format: "%.1f", snapshot.usageFraction * 100)) %), "
                    + "\(snapshot.freeSlots) frei "
                    + "= \(String(format: "%.1f", snapshot.freeSlotFraction * 100)) %")
            print("  Quelle: \(snapshot.bindingCeiling.rawValue)")
            print("  Notfalldruck: \(policy.isUnderEmergencyPressure(snapshot))")
            print("  geschuetzte PIDs (Sicht der App): \(snapshot.protectedPIDs.sorted())")
            for offender in snapshot.offenders.prefix(3) {
                print(
                    "  Signal \(offender.pid): "
                        + EvidenceCSVLog.sessionSignal(for: offender)
                        + " aktiv=\(offender.isSessionActive(idleThreshold: policy.sessionIdleThreshold))")
            }
            print("  ZIELE: \(selection.targets.map { "\($0.pid) (\($0.zombieCount) Zombies)" })")
            print("  Override: \(selection.emergencyOverrides.sorted())")
            for skip in selection.skipped.prefix(4) {
                print("  uebersprungen \(skip.parent.pid) (\(skip.parent.zombieCount)): "
                    + "\(skip.reason.rawValue)")
            }
        }
    }
}
