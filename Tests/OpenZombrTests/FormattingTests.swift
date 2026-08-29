import XCTest

@testable import OpenZombrKit

final class FormattingTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(Formatting.percent(0.967), "97 %")
        XCTAssertEqual(Formatting.percent(0), "0 %")
    }

    func testCountUsesGermanGrouping() {
        XCTAssertEqual(Formatting.count(3326), "3.326")
        XCTAssertEqual(Formatting.count(29), "29")
    }

    func testDuration() {
        XCTAssertEqual(Formatting.duration(30), "unter 1 Min.")
        XCTAssertEqual(Formatting.duration(786), "13 Min.")
        XCTAssertEqual(Formatting.duration(3600), "1 Std.")
        XCTAssertEqual(Formatting.duration(4320), "1 Std. 12 Min.")
        XCTAssertEqual(Formatting.duration(400_000), "über 2 Tage")
        XCTAssertEqual(Formatting.duration(-5), "unbekannt")
        XCTAssertEqual(Formatting.duration(.infinity), "unbekannt")
    }

    func testETAWording() {
        XCTAssertEqual(Formatting.eta(.unavailable), "wird ermittelt …")
        XCTAssertEqual(
            Formatting.eta(
                ForkFailureForecast(
                    slotsPerSecond: 0, secondsToExhaustion: nil, sampleCount: 5)),
            "stabil")
        XCTAssertEqual(
            Formatting.eta(
                ForkFailureForecast(
                    slotsPerSecond: -2, secondsToExhaustion: nil, sampleCount: 5)),
            "sinkt")
        XCTAssertEqual(
            Formatting.eta(
                ForkFailureForecast(
                    slotsPerSecond: 0.16, secondsToExhaustion: 786, sampleCount: 5)),
            "13 Min.")
    }

    func testAlertCopyContainsTheDecisiveNumbers() {
        let snapshot = Fixture.snapshot(
            totalProcesses: 3869, zombieCount: 3326, limit: 4000,
            offenders: [Fixture.parent(pid: 87537, zombieCount: 600)])
        let alert = ThresholdAlert(
            severity: .critical, snapshot: snapshot, thresholdFraction: 0.75)
        let forecast = ForkFailureForecast(
            slotsPerSecond: 10.0 / 60.0, secondsToExhaustion: 786, sampleCount: 5)

        let body = AlertPresentation.thresholdBody(alert, forecast: forecast)
        XCTAssertTrue(body.contains("3.869"))
        XCTAssertTrue(body.contains("4.000"))
        XCTAssertTrue(body.contains("3.326"))
        XCTAssertTrue(body.contains("13 Min."))
        XCTAssertTrue(body.contains("87537"))
        XCTAssertEqual(
            AlertPresentation.thresholdTitle(alert), "Kritisch: Prozess-Limit fast erreicht")
    }

    func testCleanupCopyReportsWhatHappened() {
        let report = CleanupReport(
            startedAt: Fixture.epoch,
            results: [
                ReapResult(
                    parent: Fixture.parent(pid: 87537, zombieCount: 600),
                    outcome: .terminatedBySIGKILL, signalsSent: [15, 9])
            ],
            skipped: [],
            zombiesBefore: 3350,
            zombiesAfter: 29,
            processesBefore: 3892,
            processesAfter: 565
        )

        XCTAssertEqual(AlertPresentation.cleanupTitle(report), "Bereinigung erfolgreich")
        let body = AlertPresentation.cleanupBody(report)
        XCTAssertTrue(body.contains("3.321 Zombies aufgeräumt"))
        XCTAssertTrue(body.contains("3.327 Slots frei"))
        XCTAssertTrue(body.contains("durch SIGKILL beendet"))
    }

    func testSeverityGlyphsDifferPerLevel() {
        let symbols = Set(Severity.allCases.map(\.symbolName))
        XCTAssertEqual(symbols.count, Severity.allCases.count)
        XCTAssertTrue(Severity.critical > Severity.warning)
        XCTAssertTrue(Severity.warning > Severity.normal)
    }
    /// The UI is German; an English error string leaking into the menu is a small but real
    /// inconsistency. The sysctl name and the strerror text stay untranslated on purpose.
    func testProcessTableErrorHasGermanWordingForTheMenu() {
        let failure = ProcessTableError.sysctlFailed(name: "kern.proc.all", errno: EPERM)
        XCTAssertTrue(failure.germanDescription.contains("fehlgeschlagen"))
        XCTAssertTrue(failure.germanDescription.contains("kern.proc.all"))
        XCTAssertTrue(failure.description.contains("failed"))
        XCTAssertTrue(
            ProcessTableError.unexpectedSize.germanDescription.contains("Puffergröße"))
    }
}
