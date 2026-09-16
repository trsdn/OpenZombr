import AppUpdater
import Foundation
import os.log

/// What the updater needs from the watchdog around an install.
///
/// A protocol rather than a direct reference to `ZombrModel` so the ordering rules below
/// stay readable in one place and do not depend on how the model is built.
@MainActor
public protocol UpdateInstallHost: AnyObject {
    /// Whether the process table is currently critical. Checking and preparing an update
    /// forks helpers (`hdiutil`, `codesign`), and relaunching forks the new instance, so
    /// background work competes for exactly the slots the watchdog is trying to free.
    var isUnderProcessPressure: Bool { get }
    /// Stops monitoring and returns once no termination is in flight.
    func haltForUpdate() async
    /// Restarts monitoring after an install that did not quit the app.
    func resumeAfterFailedUpdate()
}

extension ZombrModel: UpdateInstallHost {
    public var isUnderProcessPressure: Bool { severity == .critical }
}

/// Checks GitHub Releases for a newer OpenZombr and installs it in place.
///
/// Backed by [AppUpdater](https://github.com/mxcl/AppUpdater), as in OpenWritr and OpenLens.
/// It only accepts a release asset named exactly `OpenZombr-<semver>.dmg`, and only if the
/// app inside carries the same Developer ID Team ID, signing identifier and bundle
/// identifier as this one. Ad-hoc signed builds (0.2.0 and earlier) therefore never update
/// themselves; the check fails and says so.
///
/// GitHub artifact attestation is deliberately not required: the notarization broker
/// builds the release in its own repository, so there is no provenance from
/// `trsdn/OpenZombr` for AppUpdater to check against.
@MainActor
public final class UpdateManager: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case readyToInstall(version: String)
        /// A cleanup was running when the user clicked install. Quitting mid-escalation
        /// would leave a half-terminated target, so the install waits for it.
        case waitingForCleanup(version: String)
        case installing
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    @Published public var automaticChecksEnabled: Bool {
        didSet {
            guard automaticChecksEnabled != oldValue else { return }
            defaults.set(automaticChecksEnabled, forKey: Self.automaticChecksKey)
            if automaticChecksEnabled { startAutomaticChecks() } else { stopAutomaticChecks() }
        }
    }

    public static let automaticChecksKey = "updates.automaticChecks.v1"
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private weak var host: UpdateInstallHost?
    private let defaults: UserDefaults
    private let updater = AppUpdater(owner: "trsdn", repo: "OpenZombr")
    private let log = Logger(subsystem: "com.openzombr.app", category: "updates")
    private var preparedUpdate: PreparedUpdate?
    private var lastAutomaticCheck: Date?
    private var automaticCheckTask: Task<Void, Never>?

    public init(host: UpdateInstallHost?, defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
        automaticChecksEnabled = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .waitingForCleanup, .installing: return true
        default: return false
        }
    }

    // MARK: - Automatic checks

    public func startAutomaticChecks() {
        automaticCheckTask?.cancel()
        guard automaticChecksEnabled else { return }
        // Wakes hourly but checks at most once a day: a Mac that sleeps through the night
        // would otherwise miss a plain 24-hour timer indefinitely.
        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.isAutomaticCheckDue {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    public func stopAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    private var isAutomaticCheckDue: Bool {
        // Deferred, not skipped: `lastAutomaticCheck` stays untouched, so the next hourly
        // wake after the pressure clears checks straight away.
        if host?.isUnderProcessPressure == true { return false }
        guard let lastAutomaticCheck else { return true }
        return Date().timeIntervalSince(lastAutomaticCheck) >= Self.automaticCheckInterval
    }

    // MARK: - Check, install, dismiss

    /// Looks for a newer release and, if there is one, downloads and validates it so that
    /// installing is a single click.
    ///
    /// A failed background check stays in the log: being offline is not worth a line in
    /// the menu of a watchdog. A check the user asked for always answers.
    public func check(userInitiated: Bool) async {
        guard !isBusy, preparedUpdate == nil else { return }
        if userInitiated {
            state = .checking
        } else {
            lastAutomaticCheck = Date()
        }

        do {
            guard let update = try await updater.check() else {
                log.info("No update available")
                state = userInitiated ? .upToDate : .idle
                return
            }
            log.notice("Update available: \(update.version, privacy: .public)")
            state = .downloading(version: update.version)
            preparedUpdate = try await update.prepareInstallation()
            state = .readyToInstall(version: update.version)
        } catch is CancellationError {
            state = .idle
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Halts the watchdog, replaces the app and relaunches it. On success this never
    /// returns: AppUpdater starts the new instance before quitting this one.
    ///
    /// On failure AppUpdater has already rolled the bundle back, so monitoring resumes in
    /// this process. Unlike an app whose install tears down hardware state, nothing here
    /// needs a restart to work again, and a watchdog left halted would be blind.
    public func installAndRelaunch() async {
        guard let prepared = preparedUpdate, case .readyToInstall(let version) = state else {
            return
        }
        preparedUpdate = nil
        stopAutomaticChecks()

        state = .waitingForCleanup(version: version)
        await host?.haltForUpdate()
        state = .installing
        log.notice("Installing update \(version, privacy: .public)")

        do {
            try await prepared.installAndRelaunch()
        } catch {
            log.error("Install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            host?.resumeAfterFailedUpdate()
            startAutomaticChecks()
        }
    }

    /// Throws the downloaded update away. The next automatic check finds it again.
    public func dismiss() async {
        if let prepared = preparedUpdate {
            preparedUpdate = nil
            await prepared.discard()
        }
        state = .idle
    }
}
