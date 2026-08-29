import AppKit
import SwiftUI

/// The dropdown menu. German UI copy; English code and comments.
public struct MenuBarContentView: View {
    @ObservedObject var model: ZombrModel

    public init(model: ZombrModel) {
        self.model = model
    }

    public var body: some View {
        // A stale reading is announced before the numbers, not after them. The failure
        // mode this app must not have is looking healthy while blind: its sister app was
        // dead for a day and a half without anyone noticing.
        if model.isStale() {
            if let staleness = model.staleness() {
                Text("⚠︎ Messung veraltet – letzte vor \(Formatting.age(staleness))")
            } else {
                Text("⚠︎ Keine erfolgreiche Messung")
            }
            if let error = model.lastError {
                Text("Fehler: \(error)")
            }
            Divider()
        }

        if let snapshot = model.snapshot {
            Text(
                "Prozesse: \(Formatting.count(snapshot.totalProcesses)) / "
                    + "\(Formatting.count(snapshot.limit)) "
                    + "(\(Formatting.percent(snapshot.usageFraction)))")
            Text("Zombies: \(Formatting.count(snapshot.zombieCount))")
            Text("Freie Slots: \(Formatting.count(snapshot.freeSlots))")
            Text("Zuwachs: \(Formatting.rate(model.forecast.slotsPerMinute))")
            Text("Limit erreicht in: \(Formatting.eta(model.forecast))")
            Text("Status: \(model.severity.title)")
        } else if let error = model.lastError {
            Text("Fehler: \(error)")
        } else {
            Text("Messung läuft …")
        }

        Divider()

        if model.offenders.isEmpty {
            Text("Keine Zombie-Erzeuger gefunden")
        } else {
            Text("Größte Zombie-Erzeuger")
            ForEach(model.offenders) { offender in
                Text(
                    "  \(offender.name) (PID \(offender.pid)) · "
                        + "\(Formatting.count(offender.zombieCount)) Zombies · "
                        + Formatting.age(offender.age())
                        + (offender.hasUnreadableSessionSignal ? " · Signal unlesbar" : ""))
            }
        }

        Divider()

        if let report = model.lastCleanup {
            Text("Letzte Bereinigung: \(report.germanSummary)")
        }

        Button(model.isCleaning ? "Bereinigung läuft …" : "Jetzt aufräumen") {
            model.cleanupNow()
        }
        .disabled(model.isCleaning || model.snapshot == nil)

        Button("Jetzt messen") { model.poll() }

        Divider()

        Button("Protokoll im Finder zeigen") {
            NSWorkspace.shared.activateFileViewerSelecting([model.log.fileURL])
        }

        SettingsLink {
            Text("Einstellungen …")
        }

        Divider()

        Button("OpenZombr beenden") { NSApplication.shared.terminate(nil) }
    }
}
