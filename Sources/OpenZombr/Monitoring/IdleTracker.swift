import Foundation

/// Tracks how long each process has gone without consuming CPU.
///
/// Existence of a live child is not evidence that a wrapper is doing work. This was
/// established the hard way: during the incident, wrapper 60581 had a live `copilot`
/// child and killing it was still exactly the right call — it freed 308 slots and the
/// child survived, reparented to launchd. The child was resident but finished. Every
/// leaking wrapper looked like that, so a rule based on "has a session child" would have
/// protected all six and left the machine to hit the fork limit.
///
/// What separates a finished session from a working one is that a finished one stops
/// burning CPU. Accumulated user + system CPU time is monotonic, so an unchanged value
/// across two readings means the process ran for zero cycles in between.
///
/// The window has to be long. Sampling over 20 s during the incident showed the user's
/// *own* session child idle simply because they were between turns, so a short window
/// would reap a live session that happens to be thinking. Idleness is only meaningful at
/// the scale of hours — the actual giveaway on the day was a session untouched for five.
/// Idle does not mean "zero cycles". Measured on the affected machine over a 3 minute
/// window: a session child that was genuinely between turns still accrued 0.40 s of CPU
/// (0.22 % of a core) from its heartbeat, while children doing real work accrued 4.56 s
/// and 7.45 s (2.5 % and 4.1 %). Treating any increase at all as activity would therefore
/// reset the idle clock on every poll forever and the override could never fire, which is
/// the same "never clean anything" failure it exists to remove. Activity is instead a
/// *rate*: CPU consumed since the last activity, over the time since then, above
/// ``activityRateThreshold``.
///
/// Not internally synchronised: it is created and used only from the main actor, where
/// polling happens, so a lock would add cost for no benefit.
public final class IdleTracker: @unchecked Sendable {
    private struct Observation {
        /// Guards against pid reuse: a recycled pid has a different start time, and its
        /// history must not be inherited.
        let startTime: Date
        /// CPU time and wall clock as of the previous reading, which is what the rate is
        /// measured over. Comparing against the last *activity* instead would dilute a
        /// genuine wake-up by however long the process had been idle beforehand, so a
        /// session resuming after hours would take hours to be recognised as working.
        let cpuSeconds: TimeInterval
        let readAt: Date
        /// When the process was last seen to be doing work.
        let lastActive: Date
    }

    private var observations: [pid_t: Observation] = [:]

    /// Fraction of one core above which a process counts as working. The default of 1 %
    /// sits an order of magnitude above the measured heartbeat of an idle session and an
    /// order of magnitude below the measured floor of a working one.
    public static let defaultActivityRateThreshold: Double = 0.01

    private let activityRateThreshold: Double

    public init(activityRateThreshold: Double = IdleTracker.defaultActivityRateThreshold) {
        self.activityRateThreshold = max(0, activityRateThreshold)
    }

    /// Records a reading and returns how long the process has been idle, or `nil` when
    /// this is the first time it has been seen.
    ///
    /// `nil` is deliberate and is treated as "active" by callers: with no history there
    /// is no evidence of idleness, and the conservative reading of no evidence is that
    /// the process is busy. The consequence is that shortly after OpenZombr starts, no
    /// wrapper can be reclaimed through the idle override — which is correct, because at
    /// that point the app genuinely does not know.
    @discardableResult
    public func observe(
        pid: pid_t,
        startTime: Date,
        cpuSeconds: TimeInterval,
        now: Date
    ) -> TimeInterval? {
        guard let previous = observations[pid], previous.startTime == startTime else {
            observations[pid] = Observation(
                startTime: startTime, cpuSeconds: cpuSeconds, readAt: now, lastActive: now)
            return nil
        }

        // CPU time is monotonic for a given process, so the delta since the last activity
        // is never negative. Comparing against the elapsed time turns it into a duty
        // cycle, which is what distinguishes a heartbeat from work.
        let sincePoll = now.timeIntervalSince(previous.readAt)
        let consumed = max(0, cpuSeconds - previous.cpuSeconds)
        let isWorking = sincePoll <= 0 ? consumed > 0 : (consumed / sincePoll) > activityRateThreshold
        if isWorking {
            observations[pid] = Observation(
                startTime: startTime, cpuSeconds: cpuSeconds, readAt: now, lastActive: now)
            return 0
        }

        observations[pid] = Observation(
            startTime: startTime, cpuSeconds: cpuSeconds, readAt: now,
            lastActive: previous.lastActive)
        return max(0, now.timeIntervalSince(previous.lastActive))
    }

    /// Idle duration for a pid without recording a new reading.
    public func idleDuration(for pid: pid_t, now: Date) -> TimeInterval? {
        guard let observation = observations[pid] else { return nil }
        return max(0, now.timeIntervalSince(observation.lastActive))
    }

    /// Drops processes that no longer exist, so the table cannot grow without bound on a
    /// machine that is spawning hundreds of processes a minute.
    public func prune(keeping alive: Set<pid_t>) {
        observations = observations.filter { alive.contains($0.key) }
    }

    public var trackedCount: Int { observations.count }
}
