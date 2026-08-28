import XCTest

@testable import OpenZombrKit

final class GrowthEstimatorTests: XCTestCase {
    private func observations(
        start: Date = Fixture.epoch,
        intervalSeconds: TimeInterval,
        counts: [Int]
    ) -> [GrowthEstimator.Observation] {
        counts.enumerated().map { index, count in
            GrowthEstimator.Observation(
                timestamp: start.addingTimeInterval(Double(index) * intervalSeconds),
                totalProcesses: count
            )
        }
    }

    private func feed(
        _ estimator: inout GrowthEstimator,
        _ observations: [GrowthEstimator.Observation],
        limit: Int
    ) -> ForkFailureForecast {
        var forecast = ForkFailureForecast.unavailable
        for observation in observations {
            forecast = estimator.record(observation, limit: limit)
        }
        return forecast
    }

    /// No estimate from one or two points: a fabricated ETA would be worse than none.
    func testNoForecastBelowMinimumSamples() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator, observations(intervalSeconds: 60, counts: [100, 110]), limit: 4000)
        XCTAssertNil(forecast.secondsToExhaustion)
        XCTAssertEqual(forecast.slotsPerSecond, 0)
        XCTAssertEqual(forecast.sampleCount, 2)
    }

    /// The measured leak: 10 slots per minute.
    func testMeasuresTheObservedLeakRate() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator,
            observations(intervalSeconds: 60, counts: [1000, 1010, 1020, 1030, 1040]),
            limit: 4000
        )
        XCTAssertEqual(forecast.slotsPerMinute, 10, accuracy: 0.001)
        XCTAssertTrue(forecast.isGrowing)
    }

    /// The incident condition: 3869 of 4000 at 10/min is ~13 minutes from lockup.
    func testETAMatchesTheIncidentNumbers() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator,
            observations(intervalSeconds: 60, counts: [3839, 3849, 3859, 3869]),
            limit: 4000
        )
        let eta = try! XCTUnwrap(forecast.secondsToExhaustion)
        XCTAssertEqual(eta, (4000.0 - 3869.0) / (10.0 / 60.0), accuracy: 1.0)
        XCTAssertEqual(eta / 60, 13.1, accuracy: 0.2)
    }

    func testNoETAWhenTheCountIsFlat() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator, observations(intervalSeconds: 60, counts: [500, 500, 500, 500]),
            limit: 4000)
        XCTAssertEqual(forecast.slotsPerSecond, 0, accuracy: 0.0001)
        XCTAssertNil(forecast.secondsToExhaustion)
    }

    /// After a cleanup the count falls. A falling count is not on a path to exhaustion,
    /// so it must not produce a negative or nonsensical ETA.
    func testNoETAWhenTheCountIsFalling() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator, observations(intervalSeconds: 60, counts: [3800, 2000, 1000, 600]),
            limit: 4000)
        XCTAssertLessThan(forecast.slotsPerSecond, 0)
        XCTAssertNil(forecast.secondsToExhaustion)
        XCTAssertFalse(forecast.isGrowing)
    }

    func testETAIsZeroWhenAlreadyAtTheLimit() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator, observations(intervalSeconds: 60, counts: [3980, 3990, 4000]),
            limit: 4000)
        XCTAssertEqual(try XCTUnwrap(forecast.secondsToExhaustion), 0, accuracy: 0.001)
    }

    /// A burst that has stopped must stop influencing the forecast once it ages out.
    func testObservationsOutsideTheWindowAreDropped() {
        var estimator = GrowthEstimator(window: 300)
        var forecast = feed(
            &estimator,
            observations(intervalSeconds: 60, counts: [1000, 1600, 2200]),
            limit: 4000
        )
        XCTAssertGreaterThan(forecast.slotsPerMinute, 500)

        // Six minutes of flat readings push the burst out of the five-minute window.
        let calm = observations(
            start: Fixture.epoch.addingTimeInterval(180),
            intervalSeconds: 60,
            counts: [2200, 2200, 2200, 2200, 2200, 2200, 2200]
        )
        forecast = feed(&estimator, calm, limit: 4000)
        XCTAssertEqual(forecast.slotsPerMinute, 0, accuracy: 0.5)
        XCTAssertNil(forecast.secondsToExhaustion)
    }

    func testResetClearsHistory() {
        var estimator = GrowthEstimator()
        _ = feed(&estimator, observations(intervalSeconds: 60, counts: [1, 2, 3, 4]), limit: 4000)
        XCTAssertEqual(estimator.sampleCount, 4)
        estimator.reset()
        XCTAssertEqual(estimator.sampleCount, 0)
        XCTAssertNil(estimator.forecast(limit: 4000).secondsToExhaustion)
    }

    /// Identical timestamps give no time base, so there is no rate to compute.
    func testIdenticalTimestampsProduceNoRate() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator, observations(intervalSeconds: 0, counts: [100, 200, 300]), limit: 4000)
        XCTAssertEqual(forecast.slotsPerSecond, 0)
        XCTAssertNil(forecast.secondsToExhaustion)
    }

    /// The slope is fitted, not taken from the last two points, so one noisy reading
    /// must not swing the estimate.
    func testSingleNoisySampleDoesNotDominateTheSlope() {
        var estimator = GrowthEstimator()
        let forecast = feed(
            &estimator,
            observations(intervalSeconds: 60, counts: [1000, 1010, 1020, 1005, 1040, 1050]),
            limit: 4000
        )
        XCTAssertEqual(forecast.slotsPerMinute, 10, accuracy: 3.0)
    }
}
