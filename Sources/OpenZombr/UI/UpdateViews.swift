import SwiftUI

/// The update items of the menu bar menu. A separate view so the menu follows the
/// manager's state; `MenuBarContentView` only observes `ZombrModel`.
struct UpdateMenuItems: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        if let status = updates.state.germanStatus {
            Text(status)
        }
        switch updates.state {
        case .readyToInstall(let version):
            Button("Update \(version) installieren und neu starten") {
                Task { await updates.installAndRelaunch() }
            }
            Button("Update verwerfen") {
                Task { await updates.dismiss() }
            }
        case .upToDate, .failed:
            Button("Nach Updates suchen …") {
                Task { await updates.check(userInitiated: true) }
            }
            Button("Hinweis ausblenden") {
                Task { await updates.dismiss() }
            }
        default:
            Button("Nach Updates suchen …") {
                Task { await updates.check(userInitiated: true) }
            }
            .disabled(updates.isBusy)
        }
        Toggle("Automatisch nach Updates suchen", isOn: $updates.automaticChecksEnabled)
    }
}

/// The "Updates" section of the preferences window.
struct UpdateSettingsSection: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        Section("Updates") {
            Toggle("Automatisch nach Updates suchen", isOn: $updates.automaticChecksEnabled)
            HStack {
                Button("Jetzt nach Updates suchen …") {
                    Task { await updates.check(userInitiated: true) }
                }
                .disabled(updates.isBusy || isReady)
                if case .readyToInstall(let version) = updates.state {
                    Button("Update \(version) installieren und neu starten") {
                        Task { await updates.installAndRelaunch() }
                    }
                }
            }
            Text(updates.state.germanStatus ?? Self.idleText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isReady: Bool {
        if case .readyToInstall = updates.state { return true }
        return false
    }

    private static let idleText =
        "Einmal täglich wird geprüft, ob es auf GitHub eine neuere, notariell beglaubigte "
        + "Version gibt. Vor dem Neustart wird eine laufende Bereinigung abgewartet."
}

extension UpdateManager.State {
    /// Status line for menu and preferences, or `nil` when there is nothing to say.
    var germanStatus: String? {
        switch self {
        case .idle: return nil
        case .checking: return "Suche nach Updates …"
        case .upToDate: return "OpenZombr ist aktuell"
        case .downloading(let version): return "Lade Update \(version) …"
        case .readyToInstall(let version): return "Update \(version) ist bereit"
        case .waitingForCleanup(let version):
            return "Update \(version): warte auf laufende Bereinigung …"
        case .installing: return "Update wird installiert …"
        case .failed(let message): return "Update fehlgeschlagen: \(message)"
        }
    }
}
