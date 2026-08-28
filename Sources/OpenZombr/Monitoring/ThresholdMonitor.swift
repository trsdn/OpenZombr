import Foundation

/// A threshold crossing worth notifying about.
public struct ThresholdAlert: Sendable, Equatable {
    public let severity: Severity
    public let snapshot: ZombieSnapshot
    public let thresholdFraction: Double

    public init(severity: Severity, snapshot: ZombieSnapshot, thresholdFraction: Double) {
        self.severity = severity
        self.snapshot = snapshot
        self.thresholdFraction = thresholdFraction
    }
}

/// Debounce and hysteresis tuning.
public struct MonitorPolicy: Sendable, Equatable {
    /// A severity must hold for this many consecutive polls before it takes effect, so a
    /// single spiky reading cannot fire a notification.
    public var confirmationSamples: Int
    /// After a level has fired it only re-arms once usage falls below
    /// `threshold * releaseFraction`. Without this, usage oscillating around a threshold
    /// would notify on every poll.
    public var releaseFraction: Double

    public init(confirmationSamples: Int = 2, releaseFraction: Double = 0.9) {
        self.confirmationSamples = max(1, confirmationSamples)
        self.releaseFraction = min(max(releaseFraction, 0.1), 1.0)
    }
}

/// Threshold state machine with hysteresis.
///
/// Rules, in the order they matter:
/// 1. A severity only becomes effective after `confirmationSamples` consecutive polls.
/// 2. Each level fires at most once per crossing, and re-arms only after usage drops
///    below `threshold * releaseFraction`.
/// 3. Firing critical also disarms warning, so a machine coming back down does not
///    produce a pointless warning after the critical notification.
/// 4. De-escalation is immediate and silent: the menu bar must stop showing "critical"
///    as soon as the machine recovers, but that is not news worth a notification.
public struct ThresholdMonitor: Sendable {
    public private(set) var currentSeverity: Severity = .normal

    private var thresholds: Thresholds
    private let policy: MonitorPolicy

    private var warningArmed = true
    private var criticalArmed = true
    private var candidateSeverity: Severity = .normal
    private var candidateStreak = 0

    public init(thresholds: Thresholds = Thresholds(), policy: MonitorPolicy = MonitorPolicy()) {
        self.thresholds = thresholds
        self.policy = policy
    }

    /// Applies new thresholds and re-arms both levels: the user just redefined what they
    /// consider dangerous and deserves to hear about it under the new rules.
    public mutating func updateThresholds(_ newThresholds: Thresholds) {
        guard newThresholds != thresholds else { return }
        thresholds = newThresholds
        warningArmed = true
        criticalArmed = true
        candidateStreak = 0
        candidateSeverity = currentSeverity
    }

    /// Feeds one poll in. Returns an alert only when the user should actually be told.
    @discardableResult
    public mutating func evaluate(_ snapshot: ZombieSnapshot) -> ThresholdAlert? {
        let usage = snapshot.usageFraction
        let observed = thresholds.severity(forUsageFraction: usage)

        if observed == candidateSeverity {
            candidateStreak += 1
        } else {
            candidateSeverity = observed
            candidateStreak = 1
        }

        rearmIfRecovered(usage: usage)

        if observed < currentSeverity {
            currentSeverity = observed
            return nil
        }

        guard candidateStreak >= policy.confirmationSamples else { return nil }
        let previous = currentSeverity
        currentSeverity = observed
        guard observed > previous || shouldRefire(observed) else { return nil }

        switch observed {
        case .normal:
            return nil
        case .warning:
            guard warningArmed else { return nil }
            warningArmed = false
            return ThresholdAlert(
                severity: .warning, snapshot: snapshot,
                thresholdFraction: thresholds.warningFraction)
        case .critical:
            guard criticalArmed else { return nil }
            criticalArmed = false
            warningArmed = false
            return ThresholdAlert(
                severity: .critical, snapshot: snapshot,
                thresholdFraction: thresholds.criticalFraction)
        }
    }

    /// A level that has re-armed (usage dropped and climbed back) may fire again even
    /// though the effective severity did not change on this tick.
    private func shouldRefire(_ severity: Severity) -> Bool {
        switch severity {
        case .normal: return false
        case .warning: return warningArmed
        case .critical: return criticalArmed
        }
    }

    private mutating func rearmIfRecovered(usage: Double) {
        if usage < thresholds.warningFraction * policy.releaseFraction { warningArmed = true }
        if usage < thresholds.criticalFraction * policy.releaseFraction { criticalArmed = true }
    }
}
