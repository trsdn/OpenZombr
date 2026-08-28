import Foundation

/// Human-readable formatting for the menu bar and the menu. German, matching the UI.
public enum Formatting {
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.0f %%", fraction * 100)
    }

    public static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Compact duration: "3 Min.", "1 Std. 12 Min.", "unter 1 Min.".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unbekannt" }
        if seconds < 60 { return "unter 1 Min." }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 { return "\(totalMinutes) Min." }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 48 { return "über 2 Tage" }
        return minutes == 0 ? "\(hours) Std." : "\(hours) Std. \(minutes) Min."
    }

    public static func rate(_ slotsPerMinute: Double) -> String {
        String(format: "%.1f/Min.", slotsPerMinute)
    }

    /// "vor 2 Std. 5 Min." for a process age.
    public static func age(_ seconds: TimeInterval) -> String {
        "seit \(duration(seconds))"
    }

    public static func eta(_ forecast: ForkFailureForecast) -> String {
        guard forecast.sampleCount >= GrowthEstimator.minimumSamples else {
            return "wird ermittelt …"
        }
        guard let seconds = forecast.secondsToExhaustion else {
            return forecast.slotsPerSecond < 0 ? "sinkt" : "stabil"
        }
        return duration(seconds)
    }
}
