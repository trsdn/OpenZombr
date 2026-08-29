import Foundation
import ServiceManagement

/// Launch-at-login registration, reachable without the menu bar UI.
///
/// `SMAppService.mainApp` registers *the calling bundle*, so registration can only happen
/// from inside an installed `OpenZombr.app` — there is no external command that can do it
/// on the app's behalf. That is why the executable exposes `--login-item`: it lets the
/// registration be performed and, more importantly, *read back* from a terminal instead of
/// being asserted. A watchdog that silently fails to come back after a reboot is the exact
/// failure this app exists to prevent.
public enum LoginItem {
    public enum Outcome: Equatable {
        case status(String)
        case failed(String)

        public var exitCode: Int32 {
            switch self {
            case .status: return 0
            case .failed: return 1
            }
        }

        public var text: String {
            switch self {
            case .status(let text): return text
            case .failed(let text): return text
            }
        }
    }

    /// Rendered separately from the `SMAppService` call so the wording is testable without
    /// touching the real login item database.
    public static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "registriert"
        case .notRegistered: return "nicht registriert"
        case .requiresApproval: return "wartet auf Freigabe in den Systemeinstellungen"
        case .notFound: return "nicht gefunden"
        @unknown default: return "unbekannt (\(status.rawValue))"
        }
    }

    /// `true` only for a state in which the app will actually be launched at the next
    /// login. `requiresApproval` deliberately counts as *not* effective: the item exists
    /// but macOS will not start it until the user approves it.
    public static func isEffective(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    public static func run(arguments: [String], bundle: Bundle = .main) -> Outcome {
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else {
            return .failed(
                "--login-item braucht ein installiertes App-Bundle; hier läuft "
                    + bundle.bundleURL.path)
        }

        let service = SMAppService.mainApp
        let command = arguments.first ?? "status"
        do {
            switch command {
            case "register": try service.register()
            case "unregister": try service.unregister()
            case "status": break
            default: return .failed("unbekannter Befehl: \(command)")
            }
        } catch {
            return .failed("\(command) fehlgeschlagen: \(error.localizedDescription)")
        }

        let status = service.status
        return .status(
            "Login-Item: \(describe(status)) [status=\(status.rawValue), "
                + "wirksam=\(isEffective(status) ? "ja" : "nein")] — \(bundle.bundleURL.path)")
    }
}
