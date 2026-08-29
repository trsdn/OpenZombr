import XCTest

@testable import OpenZombrKit

final class PreferencesTests: XCTestCase {
    func testDefaults() {
        let preferences = Preferences(defaults: .makeTransient())
        XCTAssertEqual(preferences.pollInterval, 60)
        XCTAssertEqual(preferences.warningPercent, 50)
        XCTAssertEqual(preferences.criticalPercent, 75)
        XCTAssertTrue(preferences.autoCleanupEnabled)
        XCTAssertEqual(preferences.minimumZombiesPerParent, 100)
        XCTAssertEqual(preferences.cleanupPolicy.allowedNamePatterns, ["agency"])
        XCTAssertTrue(preferences.cleanupPolicy.deniedNamePatterns.isEmpty)
    }

    func testThresholdsAreExposedAsFractions() {
        let preferences = Preferences(defaults: .makeTransient())
        preferences.warningPercent = 40
        preferences.criticalPercent = 80
        XCTAssertEqual(preferences.thresholds.warningFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(preferences.thresholds.criticalFraction, 0.8, accuracy: 0.0001)
    }

    func testRaisingWarningAboveCriticalPushesCriticalUp() {
        let preferences = Preferences(defaults: .makeTransient())
        preferences.warningPercent = 90
        XCTAssertEqual(preferences.criticalPercent, 90)
    }

    func testValuesAreClamped() {
        let preferences = Preferences(defaults: .makeTransient())
        preferences.pollInterval = 1
        XCTAssertEqual(preferences.pollInterval, Preferences.minimumPollInterval)
        preferences.pollInterval = 99999
        XCTAssertEqual(preferences.pollInterval, Preferences.maximumPollInterval)
        preferences.warningPercent = 500
        XCTAssertEqual(preferences.warningPercent, 100)
        preferences.minimumZombiesPerParent = 0
        XCTAssertEqual(preferences.minimumZombiesPerParent, 1)
    }

    func testSettingsPersist() {
        let defaults = UserDefaults.makeTransient()
        let first = Preferences(defaults: defaults)
        first.pollInterval = 120
        first.warningPercent = 33
        first.autoCleanupEnabled = false
        first.allowedPatternsText = "agency, foo"

        let second = Preferences(defaults: defaults)
        XCTAssertEqual(second.pollInterval, 120)
        XCTAssertEqual(second.warningPercent, 33)
        XCTAssertFalse(second.autoCleanupEnabled)
        XCTAssertEqual(second.cleanupPolicy.allowedNamePatterns, ["agency", "foo"])
    }

    func testPatternParsingTrimsAndDropsEmptyEntries() {
        XCTAssertEqual(
            Preferences.patterns(from: " agency ,, foo\nbar , "), ["agency", "foo", "bar"])
        XCTAssertTrue(Preferences.patterns(from: "   ").isEmpty)
        XCTAssertTrue(Preferences.patterns(from: "").isEmpty)
    }

    /// Clearing the allowlist must disable cleanup, not enable it for everything.
    func testClearingTheAllowlistDisablesCleanup() {
        let preferences = Preferences(defaults: .makeTransient())
        preferences.allowedPatternsText = ""
        XCTAssertFalse(
            preferences.cleanupPolicy.permits(Fixture.parent(pid: 10, zombieCount: 5000)))
    }
    /// A session idle threshold beyond the log reader's horizon can never be reached, so
    /// storing one would switch cleanup off without any visible sign. It is clamped both
    /// when set and when read back from a value an older build may have stored.
    func testSessionIdleHoursIsClampedToWhatTheLogReaderCanProve() {
        let defaults = UserDefaults.makeTransient()
        let preferences = Preferences(defaults: defaults)

        preferences.sessionIdleHours = 24
        XCTAssertEqual(preferences.sessionIdleHours, Preferences.maximumSessionIdleHours)
        preferences.sessionIdleHours = 0.1
        XCTAssertEqual(preferences.sessionIdleHours, Preferences.minimumSessionIdleHours)

        defaults.set(24.0, forKey: "sessionIdleHours")
        XCTAssertEqual(
            Preferences(defaults: defaults).sessionIdleHours,
            Preferences.maximumSessionIdleHours)
    }

    /// The bound is derived from the reader rather than written out twice, so the two
    /// cannot drift apart.
    func testMaximumSessionIdleHoursTracksTheReaderHorizon() {
        XCTAssertEqual(
            Preferences.maximumSessionIdleHours, SessionLogReader.defaultHorizon / 3600)
        XCTAssertEqual(SessionLogReader().horizon, SessionLogReader.defaultHorizon)
    }
}
