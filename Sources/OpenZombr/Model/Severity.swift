import Foundation

/// How close the current uid is to `kern.maxprocperuid`.
public enum Severity: Int, Sendable, Comparable, CaseIterable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// German, because the UI is German.
    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warnung"
        case .critical: return "Kritisch"
        }
    }

    /// SF Symbols render as template images, so they stay legible in both light and
    /// dark menu bars. The *shape* changes with severity, not only the colour, so the
    /// state is still readable in monochrome menu bars and for colour-blind users.
    public var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// Warning and critical levels, expressed as a fraction of `kern.maxprocperuid`
/// rather than as absolute process counts.
///
/// Percentages are used on purpose: the limit is read from sysctl at runtime and may
/// differ per machine or be raised by the user, and absolute thresholds would silently
/// become meaningless if it changed.
public struct Thresholds: Sendable, Equatable {
    public static let defaultWarningFraction = 0.50
    public static let defaultCriticalFraction = 0.75

    public var warningFraction: Double
    public var criticalFraction: Double

    public init(
        warningFraction: Double = Thresholds.defaultWarningFraction,
        criticalFraction: Double = Thresholds.defaultCriticalFraction
    ) {
        let warning = Thresholds.clamp(warningFraction)
        self.warningFraction = warning
        // Critical below warning would make critical unreachable.
        self.criticalFraction = max(warning, Thresholds.clamp(criticalFraction))
    }

    public static func clamp(_ value: Double) -> Double {
        min(max(value, 0.01), 1.0)
    }

    public func severity(forUsageFraction usage: Double) -> Severity {
        if usage >= criticalFraction { return .critical }
        if usage >= warningFraction { return .warning }
        return .normal
    }

    public func fraction(for severity: Severity) -> Double? {
        switch severity {
        case .normal: return nil
        case .warning: return warningFraction
        case .critical: return criticalFraction
        }
    }
}
