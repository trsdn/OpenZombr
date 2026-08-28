import Foundation
import ServiceManagement

/// User settings, persisted in `UserDefaults`.
public final class Preferences: ObservableObject {
    public enum Key {
        public static let pollInterval = "pollIntervalSeconds"
        public static let warningFraction = "warningThresholdFraction"
        public static let criticalFraction = "criticalThresholdFraction"
        public static let autoCleanupEnabled = "autoCleanupEnabled"
        public static let minimumZombiesPerParent = "minimumZombiesPerParent"
        public static let allowedPatterns = "allowedNamePatterns"
        public static let deniedPatterns = "deniedNamePatterns"
        public static let notificationsEnabled = "notificationsEnabled"
    }

    public static let defaultPollInterval: TimeInterval = 60
    public static let minimumPollInterval: TimeInterval = 5
    public static let maximumPollInterval: TimeInterval = 3600

    private let defaults: UserDefaults

    /// Clamping happens in `didSet` rather than in a setter because SwiftUI binds
    /// directly to these properties. Each clamp re-assigns at most once and the second
    /// pass is a no-op, so the observers cannot recurse.
    @Published public var pollInterval: TimeInterval {
        didSet {
            let clamped = Self.clampInterval(pollInterval)
            if clamped != pollInterval {
                pollInterval = clamped
                return
            }
            defaults.set(pollInterval, forKey: Key.pollInterval)
        }
    }

    /// Stored as a percentage because that is what the user types.
    @Published public var warningPercent: Double {
        didSet {
            let clamped = Self.clampPercent(warningPercent)
            if clamped != warningPercent {
                warningPercent = clamped
                return
            }
            defaults.set(warningPercent, forKey: Key.warningFraction)
            if criticalPercent < warningPercent { criticalPercent = warningPercent }
        }
    }

    @Published public var criticalPercent: Double {
        didSet {
            let clamped = max(warningPercent, Self.clampPercent(criticalPercent))
            if clamped != criticalPercent {
                criticalPercent = clamped
                return
            }
            defaults.set(criticalPercent, forKey: Key.criticalFraction)
        }
    }

    /// On by default. Unlike OpenDefendrWatchr, where tamper protection made automatic
    /// remediation impossible, killing a leaking wrapper here is both effective and
    /// non-destructive: its live child survives, reparented to launchd.
    @Published public var autoCleanupEnabled: Bool {
        didSet { defaults.set(autoCleanupEnabled, forKey: Key.autoCleanupEnabled) }
    }

    @Published public var minimumZombiesPerParent: Int {
        didSet {
            let clamped = max(1, minimumZombiesPerParent)
            if clamped != minimumZombiesPerParent {
                minimumZombiesPerParent = clamped
                return
            }
            defaults.set(minimumZombiesPerParent, forKey: Key.minimumZombiesPerParent)
        }
    }

    /// Comma-separated in the UI, stored as a list.
    @Published public var allowedPatternsText: String {
        didSet { defaults.set(allowedPatternsText, forKey: Key.allowedPatterns) }
    }

    @Published public var deniedPatternsText: String {
        didSet { defaults.set(deniedPatternsText, forKey: Key.deniedPatterns) }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.object(forKey: Key.pollInterval) as? TimeInterval
        self.pollInterval = Self.clampInterval(storedInterval ?? Self.defaultPollInterval)
        self.warningPercent = Self.clampPercent(
            defaults.object(forKey: Key.warningFraction) as? Double
                ?? Thresholds.defaultWarningFraction * 100)
        self.criticalPercent = Self.clampPercent(
            defaults.object(forKey: Key.criticalFraction) as? Double
                ?? Thresholds.defaultCriticalFraction * 100)
        self.autoCleanupEnabled =
            defaults.object(forKey: Key.autoCleanupEnabled) as? Bool ?? true
        self.minimumZombiesPerParent =
            defaults.object(forKey: Key.minimumZombiesPerParent) as? Int
            ?? CleanupPolicy.defaultMinimumZombies
        self.allowedPatternsText =
            defaults.string(forKey: Key.allowedPatterns)
            ?? CleanupPolicy.defaultAllowedPatterns.joined(separator: ", ")
        self.deniedPatternsText = defaults.string(forKey: Key.deniedPatterns) ?? ""
        self.notificationsEnabled =
            defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
    }

    public var thresholds: Thresholds {
        Thresholds(
            warningFraction: warningPercent / 100,
            criticalFraction: criticalPercent / 100
        )
    }

    public var cleanupPolicy: CleanupPolicy {
        CleanupPolicy(
            minimumZombiesPerParent: minimumZombiesPerParent,
            allowedNamePatterns: Self.patterns(from: allowedPatternsText),
            deniedNamePatterns: Self.patterns(from: deniedPatternsText)
        )
    }

    public static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func clampInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumPollInterval), maximumPollInterval)
    }

    public static func clampPercent(_ value: Double) -> Double {
        min(max(value, 1), 100)
    }

    // MARK: - Launch at login

    /// Uses `SMAppService` (macOS 13+), not a legacy login item.
    public var launchAtLoginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("OpenZombr: launch-at-login change failed: \(error)")
            }
        }
    }

    /// `SMAppService` only works for a real, installed `.app`. Under `swift run` it
    /// always fails, so the UI disables the toggle rather than lying about it.
    public var launchAtLoginAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}
