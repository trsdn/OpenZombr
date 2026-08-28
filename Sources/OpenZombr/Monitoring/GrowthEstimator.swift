import Foundation

/// Estimated time until `fork()` starts failing.
public struct ForkFailureForecast: Sendable, Equatable {
    /// Slots consumed per second. Negative when the count is falling.
    public let slotsPerSecond: Double
    /// Seconds until `totalProcesses` reaches the limit, or `nil` when the count is flat
    /// or shrinking and no exhaustion is implied.
    public let secondsToExhaustion: TimeInterval?
    /// How many samples the estimate is based on. Below `GrowthEstimator.minimumSamples`
    /// there is no estimate at all rather than a fabricated one.
    public let sampleCount: Int

    public var slotsPerMinute: Double { slotsPerSecond * 60 }

    public var isGrowing: Bool { slotsPerSecond > 0 }

    public init(slotsPerSecond: Double, secondsToExhaustion: TimeInterval?, sampleCount: Int) {
        self.slotsPerSecond = slotsPerSecond
        self.secondsToExhaustion = secondsToExhaustion
        self.sampleCount = sampleCount
    }

    public static let unavailable = ForkFailureForecast(
        slotsPerSecond: 0, secondsToExhaustion: nil, sampleCount: 0)
}

/// Estimates the growth rate of the process count and, from it, the time left before the
/// per-uid limit is hit.
///
/// This is the single most actionable number the app produces. During the incident that
/// motivated this app the machine sat at 3869 of 4000 processes and was growing at
/// 10 slots/minute — roughly 13 minutes from being unable to open a terminal — and
/// nothing on the system said so.
///
/// A least-squares fit over a bounded time window is used rather than the delta between
/// the last two polls: single polls are noisy because unrelated processes start and exit
/// constantly, and a two-point delta would swing the ETA wildly between ticks.
public struct GrowthEstimator: Sendable {
    public static let minimumSamples = 3

    public struct Observation: Sendable, Equatable {
        public let timestamp: Date
        public let totalProcesses: Int

        public init(timestamp: Date, totalProcesses: Int) {
            self.timestamp = timestamp
            self.totalProcesses = totalProcesses
        }
    }

    /// Observations older than this are dropped, so a burst that has stopped stops
    /// influencing the forecast.
    public let window: TimeInterval
    private var observations: [Observation] = []

    public init(window: TimeInterval = 600) {
        self.window = max(60, window)
    }

    public var sampleCount: Int { observations.count }

    public mutating func reset() {
        observations.removeAll()
    }

    @discardableResult
    public mutating func record(_ snapshot: ZombieSnapshot) -> ForkFailureForecast {
        record(
            Observation(timestamp: snapshot.timestamp, totalProcesses: snapshot.totalProcesses),
            limit: snapshot.limit)
    }

    @discardableResult
    public mutating func record(_ observation: Observation, limit: Int) -> ForkFailureForecast {
        observations.append(observation)
        let cutoff = observation.timestamp.addingTimeInterval(-window)
        observations.removeAll { $0.timestamp < cutoff }
        return forecast(limit: limit)
    }

    public func forecast(limit: Int) -> ForkFailureForecast {
        guard observations.count >= Self.minimumSamples, let last = observations.last else {
            return ForkFailureForecast(
                slotsPerSecond: 0, secondsToExhaustion: nil, sampleCount: observations.count)
        }

        let base = observations[0].timestamp
        let xs = observations.map { $0.timestamp.timeIntervalSince(base) }
        let ys = observations.map { Double($0.totalProcesses) }
        let n = Double(observations.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        // All observations share a timestamp: no time base, no rate.
        guard variance > 0 else {
            return ForkFailureForecast(
                slotsPerSecond: 0, secondsToExhaustion: nil, sampleCount: observations.count)
        }

        let slope = covariance / variance
        let remaining = Double(max(0, limit - last.totalProcesses))
        // A flat or falling count is not on a path to exhaustion, so there is no ETA.
        let eta = slope > 0 ? remaining / slope : nil

        return ForkFailureForecast(
            slotsPerSecond: slope,
            secondsToExhaustion: eta,
            sampleCount: observations.count
        )
    }
}
