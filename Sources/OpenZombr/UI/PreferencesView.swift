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

            Section("Schwellen (in % von kern.maxprocperuid)") {
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
                        + "stimmen, wenn sich das Limit ändert."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Automatische Bereinigung") {
                Toggle("Automatisch aufräumen", isOn: $preferences.autoCleanupEnabled)
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
