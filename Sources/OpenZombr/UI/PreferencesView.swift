import SwiftUI

public struct PreferencesView: View {
    @ObservedObject var preferences: Preferences

    public init(preferences: Preferences) {
        self.preferences = preferences
    }

    public var body: some View {
        Form {
            Section("Messung") {
                LabeledContent("Intervall") {
                    HStack {
                        TextField(
                            "", value: $preferences.pollInterval,
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 70)
                        Text("Sekunden")
                    }
                }
            }

            Section("Schwellen (in % des wirksamen Prozesslimits)") {
                LabeledContent("Warnung") {
                    HStack {
                        TextField(
                            "", value: $preferences.warningPercent,
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 70)
                        Text("%")
                    }
                }
                LabeledContent("Kritisch") {
                    HStack {
                        TextField(
                            "", value: $preferences.criticalPercent,
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 70)
                        Text("%")
                    }
                }
                Text(
                    "Prozentwerte statt fester Zahlen, damit die Schwellen auch dann "
                        + "stimmen, wenn sich das Limit ändert. Maßgeblich ist immer die "
                        + "niedrigste Decke: kern.maxprocperuid, RLIMIT_NPROC oder der "
                        + "systemweite Rest von kern.maxproc."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Automatische Bereinigung") {
                Toggle("Automatisch aufräumen", isOn: $preferences.autoCleanupEnabled)
                Toggle(
                    "Prozesse mit aktiver Sitzung verschonen",
                    isOn: $preferences.spareActiveSessions)
                Text(
                    "Beendet nie einen Prozess, der noch ein lebendes Kind eines anderen "
                        + "Programms hat. Diese Regel schützt die laufende Sitzung auch dann, "
                        + "wenn OpenZombr beim Anmelden von launchd gestartet wurde.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "Sitzung gilt als beendet nach "
                        + Formatting.duration(preferences.sessionIdleHours * 3600)
                        + " ohne CPU-Nutzung",
                    value: $preferences.sessionIdleHours,
                    in: Preferences.minimumSessionIdleHours...Preferences
                        .maximumSessionIdleHours,
                    step: 0.5
                )
                .disabled(!preferences.spareActiveSessions)
                Text(
                    "Ein Kindprozess, der stundenlang keine CPU-Zeit verbraucht, gehört zu "
                        + "einer beendeten Sitzung und schützt den Elternprozess nicht mehr. "
                        + "Kurze Denkpausen bleiben dadurch unangetastet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Notfall: bei vollem Prozesstisch trotzdem eingreifen",
                    isOn: $preferences.emergencyOverrideEnabled)
                    .disabled(!preferences.spareActiveSessions)
                Stepper(
                    "Notfall ab höchstens "
                        + String(format: "%.0f", preferences.emergencyFreeSlotPercent)
                        + " % freien Slots",
                    value: $preferences.emergencyFreeSlotPercent,
                    in: 0...Preferences.maximumEmergencyFreeSlotPercent,
                    step: 1
                )
                .disabled(
                    !preferences.spareActiveSessions || !preferences.emergencyOverrideEnabled)
                Text(
                    "Sind die Slots aufgebraucht, schützt die Sitzungsregel nichts mehr: "
                        + "eine Sitzung, die nicht mehr forken kann, ist bereits kaputt. "
                        + "Dann wird genau ein Prozess beendet — der mit den meisten "
                        + "Zombies. Prozesse, deren Sitzungssignale unlesbar sind, bleiben "
                        + "auch im Notfall verschont.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Ab Zombies pro Elternprozess") {
                    TextField(
                        "", value: $preferences.minimumZombiesPerParent,
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(width: 70)
                }
                LabeledContent("Erlaubte Namen") {
                    TextField("agency", text: $preferences.allowedPatternsText)
                }
                LabeledContent("Verbotene Namen") {
                    TextField("", text: $preferences.deniedPatternsText)
                }
                Text(
                    "Komma-getrennte Textteile. Nur passende Elternprozesse werden "
                        + "beendet. Leere Liste = keine Bereinigung. Der eigene Prozess, "
                        + "alle eigenen Vorfahren und launchd sind immer geschützt."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Sonstiges") {
                Toggle("Mitteilungen", isOn: $preferences.notificationsEnabled)
                Toggle(
                    "Beim Anmelden starten",
                    isOn: Binding(
                        get: { preferences.launchAtLoginEnabled },
                        set: { preferences.launchAtLoginEnabled = $0 }
                    )
                )
                .disabled(!preferences.launchAtLoginAvailable)
                if !preferences.launchAtLoginAvailable {
                    Text("Nur in der installierten App verfügbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
