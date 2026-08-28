import XCTest

@testable import OpenZombrKit

final class ThresholdTests: XCTestCase {
    // MARK: - Percentage classification

    func testSeverityIsDerivedFromThePercentageOfTheLimit() {
        let thresholds = Thresholds(warningFraction: 0.5, criticalFraction: 0.75)
        XCTAssertEqual(thresholds.severity(forUsageFraction: 0.0), .normal)
        XCTAssertEqual(thresholds.severity(forUsageFraction: 0.49), .normal)
        XCTAssertEqual(thresholds.severity(forUsageFraction: 0.50), .warning)
        XCTAssertEqual(thresholds.severity(forUsageFraction: 0.74), .warning)
        XCTAssertEqual(thresholds.severity(forUsageFraction: 0.75), .critical)
        XCTAssertEqual(thresholds.severity(forUsageFraction: 1.5), .critical)
    }

    /// The whole point of percentage thresholds: the same counts classify differently
    /// when the limit changes, without anyone editing a setting.
    func testThresholdsAdaptWhenTheLimitChanges() {
        let thresholds = Thresholds()
        let atFourThousand = Fixture.snapshot(totalProcesses: 3000, limit: 4000)
        let atTwelveThousand = Fixture.snapshot(totalProcesses: 3000, limit: 12000)

        XCTAssertEqual(atFourThousand.severity(thresholds: thresholds), .critical)
        XCTAssertEqual(atTwelveThousand.severity(thresholds: thresholds), .normal)
    }

    func testCriticalIsNeverBelowWarning() {
        let thresholds = Thresholds(warningFraction: 0.8, criticalFraction: 0.2)
        XCTAssertEqual(thresholds.criticalFraction, 0.8)
    }

    func testFractionsAreClamped() {
        let thresholds = Thresholds(warningFraction: -5, criticalFraction: 42)
        XCTAssertEqual(thresholds.warningFraction, 0.01)
        XCTAssertEqual(thresholds.criticalFraction, 1.0)
    }

    /// The incident reading: 3869 of 4000 is 96.7%, which must be critical.
    func testIncidentReadingIsCritical() {
        let snapshot = Fixture.snapshot(totalProcesses: 3869, zombieCount: 3326, limit: 4000)
        XCTAssertEqual(snapshot.severity(thresholds: Thresholds()), .critical)
        XCTAssertEqual(snapshot.usageFraction, 0.96725, accuracy: 0.0001)
        XCTAssertEqual(snapshot.freeSlots, 131)
    }

    // MARK: - Hysteresis

    private func monitor(
        confirmationSamples: Int = 2,
        releaseFraction: Double = 0.9
    ) -> ThresholdMonitor {
        ThresholdMonitor(
            thresholds: Thresholds(warningFraction: 0.5, criticalFraction: 0.75),
            policy: MonitorPolicy(
                confirmationSamples: confirmationSamples, releaseFraction: releaseFraction)
        )
    }

    private func snapshot(usage: Double, limit: Int = 4000) -> ZombieSnapshot {
        Fixture.snapshot(
            totalProcesses: Int(Double(limit) * usage), zombieCount: 0, limit: limit)
    }

    func testSingleSpikeDoesNotNotify() {
        var monitor = self.monitor(confirmationSamples: 2)
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.9)))
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.1)))
    }

    func testNotifiesOnceConfirmed() {
        var monitor = self.monitor(confirmationSamples: 2)
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.6)))
        let alert = monitor.evaluate(snapshot(usage: 0.6))
        XCTAssertEqual(alert?.severity, .warning)
    }

    /// The failure mode this exists to prevent: a value parked just above a threshold
    /// notifying on every single poll.
    func testDoesNotNotifyRepeatedlyWhileParkedAboveTheThreshold() {
        var monitor = self.monitor(confirmationSamples: 2)
        _ = monitor.evaluate(snapshot(usage: 0.6))
        XCTAssertNotNil(monitor.evaluate(snapshot(usage: 0.6)))
        for _ in 0..<20 {
            XCTAssertNil(monitor.evaluate(snapshot(usage: 0.6)))
        }
    }

    func testEscalationFromWarningToCriticalNotifiesAgain() {
        var monitor = self.monitor(confirmationSamples: 2)
        _ = monitor.evaluate(snapshot(usage: 0.6))
        XCTAssertEqual(monitor.evaluate(snapshot(usage: 0.6))?.severity, .warning)
        _ = monitor.evaluate(snapshot(usage: 0.8))
        XCTAssertEqual(monitor.evaluate(snapshot(usage: 0.8))?.severity, .critical)
    }

    /// Coming back down from critical must be silent — nothing bad is happening.
    func testDeescalationIsSilentAndImmediate() {
        var monitor = self.monitor(confirmationSamples: 2)
        _ = monitor.evaluate(snapshot(usage: 0.8))
        _ = monitor.evaluate(snapshot(usage: 0.8))
        XCTAssertEqual(monitor.currentSeverity, .critical)
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.1)))
        XCTAssertEqual(monitor.currentSeverity, .normal)
    }

    /// Only a meaningful drop re-arms: back down to just under the threshold is not
    /// enough, or a value oscillating by one process would notify forever.
    func testRearmsOnlyAfterAMeaningfulDrop() {
        var monitor = self.monitor(confirmationSamples: 1, releaseFraction: 0.9)
        XCTAssertNotNil(monitor.evaluate(snapshot(usage: 0.6)))

        // 0.48 is below the 0.5 threshold but above the 0.45 release point.
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.48)))
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.6)))

        // A real drop below 0.45 re-arms the level.
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.30)))
        XCTAssertNotNil(monitor.evaluate(snapshot(usage: 0.6)))
    }

    /// Firing critical disarms warning, so a machine on its way down does not produce a
    /// pointless warning after the critical notification.
    func testCriticalSuppressesTheFollowingWarning() {
        var monitor = self.monitor(confirmationSamples: 1)
        XCTAssertEqual(monitor.evaluate(snapshot(usage: 0.8))?.severity, .critical)
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.6)))
    }

    func testChangingThresholdsRearmsBothLevels() {
        var monitor = self.monitor(confirmationSamples: 1)
        XCTAssertNotNil(monitor.evaluate(snapshot(usage: 0.6)))
        XCTAssertNil(monitor.evaluate(snapshot(usage: 0.6)))

        monitor.updateThresholds(Thresholds(warningFraction: 0.4, criticalFraction: 0.9))
        XCTAssertNotNil(monitor.evaluate(snapshot(usage: 0.6)))
    }

    func testAlertCarriesTheCrossedThreshold() {
        var monitor = self.monitor(confirmationSamples: 1)
        let alert = try! XCTUnwrap(monitor.evaluate(snapshot(usage: 0.8)))
        XCTAssertEqual(alert.thresholdFraction, 0.75)
        XCTAssertEqual(alert.snapshot.usageFraction, 0.8, accuracy: 0.0001)
    }
}
