import XCTest

@testable import OpenZombrKit

/// The app used to read one ceiling and call it "the limit". On 2026-08-29 that was wrong
/// for nine hours straight, and the whole incident is reproduced here as a test.
final class ProcessLimitsTests: XCTestCase {

    // MARK: - The incident

    /// The exact reading the app had at 22:42 on 2026-08-29, and what it should have said.
    ///
    /// `kern.maxprocperuid` had been raised to 4000 mid-incident. `RLIMIT_NPROC` — which
    /// launchd hands out at login, and which the sysctl write does not touch — was still
    /// 2666 (`launchctl limit maxproc` reported `2666 4000`). The uid held 2744 processes,
    /// so `fork()` was already failing.
    ///
    /// The app reported 67,5 % used and 1299 slots free, never reached its 75 % critical
    /// threshold, and therefore never ran a cleanup. It should have read 102,9 % and zero
    /// slots.
    func testTheIncidentReadingBindsToTheSoftLimitNotToMaxProcPerUID() {
        let snapshot = Fixture.snapshot(
            totalProcesses: 2744,
            zombieCount: 2038,
            limits: ProcessLimits(perUID: 4000, softNProc: 2666, systemWide: 4000)
        )

        XCTAssertEqual(snapshot.limit, 2666)
        XCTAssertEqual(snapshot.bindingCeiling, .softNProc)
        XCTAssertEqual(snapshot.freeSlots, 0)
        XCTAssertEqual(snapshot.usageFraction, 2744.0 / 2666.0, accuracy: 0.0001)
        XCTAssertGreaterThan(snapshot.usageFraction, 1.0)
    }

    /// The consequence that actually mattered: with the real ceiling the reading is
    /// critical, which is the only severity that lets `ZombrModel` run a cleanup at all.
    /// Against `kern.maxprocperuid` alone the same machine looks merely "warning".
    func testTheIncidentReadingIsCriticalOnlyAgainstTheRealCeiling() {
        let thresholds = Thresholds()

        let asMeasuredThen = Fixture.snapshot(
            totalProcesses: 2744, zombieCount: 2038, limit: 4000)
        XCTAssertEqual(asMeasuredThen.severity(thresholds: thresholds), .warning)

        let asMeasuredNow = Fixture.snapshot(
            totalProcesses: 2744,
            zombieCount: 2038,
            limits: ProcessLimits(perUID: 4000, softNProc: 2666, systemWide: 4000)
        )
        XCTAssertEqual(asMeasuredNow.severity(thresholds: thresholds), .critical)
    }

    // MARK: - Which ceiling wins

    func testTheLowestCeilingWins() {
        let limits = ProcessLimits(perUID: 4000, softNProc: 2666, systemWide: 10000)
        XCTAssertEqual(limits.binding(foreignProcesses: 0).limit, 2666)
        XCTAssertEqual(limits.binding(foreignProcesses: 0).ceiling, .softNProc)
    }

    /// `kern.maxproc` is shared with root and every other uid, so it only becomes this
    /// uid's ceiling after their slots are subtracted.
    func testSystemWideCeilingIsReducedByForeignProcesses() {
        let limits = ProcessLimits(perUID: 4000, softNProc: 4000, systemWide: 4000)

        XCTAssertEqual(limits.binding(foreignProcesses: 0).ceiling, .perUID)

        let crowded = limits.binding(foreignProcesses: 1500)
        XCTAssertEqual(crowded.limit, 2500)
        XCTAssertEqual(crowded.ceiling, .systemWide)
    }

    func testTiesResolveToThePerUIDCeiling() {
        let limits = ProcessLimits(perUID: 2666, softNProc: 2666, systemWide: 2666)
        XCTAssertEqual(limits.binding(foreignProcesses: 0).ceiling, .perUID)
        XCTAssertEqual(limits.binding(foreignProcesses: 0).limit, 2666)
    }

    // MARK: - Missing readings

    /// An unreadable limit must not constrain. `getrlimit` can fail, and a watchdog that
    /// treated failure as "zero slots left" would send SIGKILL on no information at all.
    func testUnreadableCeilingsDoNotConstrain() {
        let limits = ProcessLimits(perUID: 4000, softNProc: nil, systemWide: nil)
        XCTAssertEqual(limits.binding(foreignProcesses: 900).limit, 4000)
        XCTAssertEqual(limits.binding(foreignProcesses: 900).ceiling, .perUID)
    }

    /// Absence of every reading is reported as 0, which every consumer already treats as
    /// "unknown" — never as "full".
    func testNoReadableCeilingIsUnknownNotFull() {
        let limits = ProcessLimits(perUID: 0, softNProc: nil, systemWide: nil)
        XCTAssertEqual(limits.binding(foreignProcesses: 0).limit, 0)

        let snapshot = Fixture.snapshot(totalProcesses: 3000, zombieCount: 10, limits: limits)
        XCTAssertEqual(snapshot.usageFraction, 0)
        XCTAssertEqual(snapshot.freeSlotFraction, 0)
        XCTAssertEqual(snapshot.severity(thresholds: Thresholds()), .normal)
    }

    // MARK: - Live machine

    /// Runs against the real machine, so it asserts only what holds on any Mac.
    func testLiveLimitsAreCoherent() throws {
        let limits = try SysctlProcessLimitReader().processLimits()

        XCTAssertGreaterThan(limits.perUID, 0)
        if let soft = limits.softNProc { XCTAssertGreaterThan(soft, 0) }
        if let system = limits.systemWide { XCTAssertGreaterThan(system, 0) }

        let binding = limits.binding(foreignProcesses: 0)
        XCTAssertGreaterThan(binding.limit, 0)
        XCTAssertLessThanOrEqual(binding.limit, limits.perUID)
    }
}
