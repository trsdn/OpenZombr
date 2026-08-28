import Foundation
import UserNotifications

/// Delivers user-visible alerts. Behind a protocol so the model can be tested without
/// touching `UNUserNotificationCenter`, which is unavailable outside a bundled app.
public protocol AlertNotifying: AnyObject, Sendable {
    func notifyThreshold(_ alert: ThresholdAlert, forecast: ForkFailureForecast)
    func notifyCleanup(_ report: CleanupReport)
}

/// German user-facing copy. Kept pure and separate from delivery so the wording is
/// testable and does not require notification permissions.
public enum AlertPresentation {
    public static func thresholdTitle(_ alert: ThresholdAlert) -> String {
        switch alert.severity {
        case .critical: return "Kritisch: Prozess-Limit fast erreicht"
        case .warning: return "Warnung: viele Zombie-Prozesse"
        case .normal: return "OpenZombr"
        }
    }

    public static func thresholdBody(_ alert: ThresholdAlert, forecast: ForkFailureForecast)
        -> String
    {
        let snapshot = alert.snapshot
        var parts = [
            "\(Formatting.count(snapshot.totalProcesses)) von "
                + "\(Formatting.count(snapshot.limit)) Prozessen "
                + "(\(Formatting.percent(snapshot.usageFraction))), "
                + "davon \(Formatting.count(snapshot.zombieCount)) Zombies."
        ]
        if forecast.isGrowing, let seconds = forecast.secondsToExhaustion {
            parts.append("Limit erreicht in ca. \(Formatting.duration(seconds)).")
        }
        if let top = snapshot.topOffender {
            parts.append(
                "Größter Verursacher: \(top.name) (PID \(top.pid), "
                    + "\(Formatting.count(top.zombieCount)) Zombies).")
        }
        return parts.joined(separator: " ")
    }

    public static func cleanupTitle(_ report: CleanupReport) -> String {
        report.verified ? "Bereinigung erfolgreich" : "Bereinigung ohne Wirkung"
    }

    public static func cleanupBody(_ report: CleanupReport) -> String {
        var parts = [report.germanSummary]
        for result in report.results {
            parts.append(
                "\(result.parent.name) (PID \(result.parent.pid)): "
                    + result.outcome.germanDescription + ".")
        }
        return parts.joined(separator: " ")
    }
}

/// Real delivery through `UNUserNotificationCenter`.
///
/// Requires a bundle identity: under `swift run` there is no bundle and macOS refuses
/// the request, which is why the app logs instead of crashing in that case.
public final class UserNotificationAlertNotifier: NSObject, AlertNotifying, @unchecked Sendable {
    private var authorizationRequested = false

    public override init() {
        super.init()
    }

    public func notifyThreshold(_ alert: ThresholdAlert, forecast: ForkFailureForecast) {
        deliver(
            title: AlertPresentation.thresholdTitle(alert),
            body: AlertPresentation.thresholdBody(alert, forecast: forecast),
            critical: alert.severity == .critical
        )
    }

    public func notifyCleanup(_ report: CleanupReport) {
        deliver(
            title: AlertPresentation.cleanupTitle(report),
            body: AlertPresentation.cleanupBody(report),
            critical: !report.verified
        )
    }

    private func deliver(title: String, body: String, critical: Bool) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("OpenZombr notification (no bundle): \(title) — \(body)")
            return
        }
        let center = UNUserNotificationCenter.current()
        requestAuthorizationIfNeeded(center) { granted in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = critical ? .defaultCritical : .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error { NSLog("OpenZombr: notification failed: \(error)") }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        _ center: UNUserNotificationCenter, completion: @escaping (Bool) -> Void
    ) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("OpenZombr: notification authorization failed: \(error)") }
            completion(granted)
        }
    }
}
