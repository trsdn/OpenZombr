import Combine
import Foundation

/// Drives the poll loop and owns everything the UI displays.
@MainActor
public final class ZombrModel: ObservableObject {
    @Published public private(set) var snapshot: ZombieSnapshot?
    @Published public private(set) var forecast: ForkFailureForecast = .unavailable
    @Published public private(set) var severity: Severity = .normal
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastCleanup: CleanupReport?
    @Published public private(set) var isCleaning = false
    /// Set while an update is being installed. No cleanup may *start* once this is true;
    /// one already running is allowed to finish, and the installer waits for it.
    @Published public private(set) var isHaltedForUpdate = false
    /// When the last sample actually succeeded.
    ///
    /// A failing poll leaves `snapshot` untouched, so without this the UI would keep
    /// displaying the last healthy reading forever and a watchdog that had gone blind
    /// would look exactly like a watchdog reporting good news. The sister app died
    /// unnoticed for a day and a half; being silently wrong is the failure mode that
    /// matters here.
    @Published public private(set) var lastSuccessfulPoll: Date?

    /// How long ago the last successful sample was, or `nil` if there has never been one.
    public func staleness(now: Date = Date()) -> TimeInterval? {
        lastSuccessfulPoll.map { now.timeIntervalSince($0) }
    }

    /// A reading is stale once it is older than several poll intervals — long enough not
    /// to flag a single skipped timer tick, short enough that a wedged watchdog is
    /// visible well within the daily cadence of the leak.
    public func isStale(now: Date = Date()) -> Bool {
        guard let lastSuccessfulPoll else { return snapshot != nil }
        return now.timeIntervalSince(lastSuccessfulPoll) > preferences.pollInterval * 3 + 10
    }

    public let preferences: Preferences
    public let log: EvidenceCSVLog

    private let sampler: ZombieSampler
    /// Owned here rather than by the sampler because it accumulates state across polls.
    /// Only touched from the main actor, where polling happens.
    private let idleTracker = IdleTracker(awakeClock: {
        // Excludes time spent asleep, unlike `Date`.
        ProcessInfo.processInfo.systemUptime
    })
    private let cleanupService: CleanupService
    private let reaper: ZombieReaper
    private let notifier: AlertNotifying

    private var monitor: ThresholdMonitor
    private var estimator: GrowthEstimator
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Auto-cleanup is rate limited independently of the poll interval. Killing a
    /// wrapper takes a moment to show up in the process table, and a leak that restarts
    /// immediately must not turn into a kill loop.
    public static let autoCleanupCooldown: TimeInterval = 120
    private var lastAutoCleanup: Date?

    public init(
        preferences: Preferences = Preferences(),
        sampler: ZombieSampler = ZombieSampler(),
        cleanupService: CleanupService = CleanupService(),
        reaper: ZombieReaper = ZombieReaper(),
        notifier: AlertNotifying = UserNotificationAlertNotifier(),
        log: EvidenceCSVLog = EvidenceCSVLog()
    ) {
        self.preferences = preferences
        self.sampler = sampler
        self.cleanupService = cleanupService
        self.reaper = reaper
        self.notifier = notifier
        self.log = log
        self.monitor = ThresholdMonitor(thresholds: preferences.thresholds)
        self.estimator = GrowthEstimator()

        // Threshold and interval edits take effect immediately rather than at the next
        // restart, so preference changes feel like they did something.
        preferences.$warningPercent
            .combineLatest(preferences.$criticalPercent)
            .dropFirst()
            .sink { [weak self] _, _ in self?.applyThresholds() }
            .store(in: &cancellables)

        preferences.$pollInterval
            .dropFirst()
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil, !isHaltedForUpdate else { return }
        poll()
        restartTimer()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Updates

    /// Stops polling and returns only once no termination is in flight.
    ///
    /// Replacing the bundle quits this process. Quitting between the SIGTERM and the
    /// SIGKILL of a cleanup would leave a half-terminated wrapper and a report that never
    /// reaches the evidence log, so the installer must wait for the whole run —
    /// escalation, verification re-sample and logging — rather than interrupt it. The
    /// flag is set before the wait, on the main actor, so no new run can slip in behind
    /// the one being waited for.
    public func haltForUpdate() async {
        isHaltedForUpdate = true
        stop()
        // Unbounded on purpose: a run is bounded by `maximumTargetsPerRun` grace periods,
        // and giving up early would reintroduce exactly the interruption this prevents.
        while isCleaning {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Undoes `haltForUpdate` after an install that did not quit the app. AppUpdater rolls
    /// the bundle back in that case, and a watchdog left halted would be blind without
    /// saying so.
    public func resumeAfterFailedUpdate() {
        isHaltedForUpdate = false
        start()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        // The interval publisher can fire while halted; it must not revive the timer.
        guard !isHaltedForUpdate else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: preferences.pollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = preferences.pollInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func applyThresholds() {
        monitor.updateThresholds(preferences.thresholds)
        if let snapshot { severity = snapshot.severity(thresholds: preferences.thresholds) }
    }

    // MARK: - Polling

    public func poll() {
        do {
            let snapshot = try sampler.sample(idleTracker: idleTracker)
            self.snapshot = snapshot
            self.lastError = nil

            forecast = estimator.record(snapshot)
            severity = snapshot.severity(thresholds: preferences.thresholds)
            lastSuccessfulPoll = Date()

            let alert = monitor.evaluate(snapshot)
            log.append(snapshot: snapshot, forecast: forecast)

            if let alert, preferences.notificationsEnabled {
                notifier.notifyThreshold(alert, forecast: forecast)
            }

            // Only the hysteresis-confirmed severity may reach the destructive path. The
            // raw `severity` published above drives the menu bar, where reacting to a
            // single sample is merely noisy; here it would let one spurious reading send
            // SIGKILL. `ThresholdMonitor` requires `confirmationSamples` consecutive
            // samples, which is the entire reason it exists.
            if monitor.currentSeverity == .critical {
                maybeAutoCleanup(snapshot: snapshot)
            }
        } catch {
            // German for the menu, since that is where it is read.
            lastError = (error as? ProcessTableError)?.germanDescription ?? "\(error)"
        }
    }

    private func maybeAutoCleanup(snapshot: ZombieSnapshot) {
        guard preferences.autoCleanupEnabled, !isCleaning else { return }
        if let last = lastAutoCleanup,
            Date().timeIntervalSince(last) < Self.autoCleanupCooldown
        {
            return
        }
        // Do not burn the cooldown on a run that has nothing to do.
        let selection = reaper.selectTargets(in: snapshot, policy: preferences.cleanupPolicy)
        guard !selection.targets.isEmpty else { return }
        lastAutoCleanup = Date()
        runCleanup(snapshot: snapshot)
    }

    // MARK: - Cleanup

    /// Manual "Jetzt aufräumen". Runs exactly the same routine as auto-cleanup.
    ///
    /// Takes a fresh sample rather than reusing `snapshot`. The poll interval can be set
    /// as high as an hour, so the stored snapshot may name processes that exited long
    /// ago; the reaper's identity check would then refuse every target and the button
    /// would appear broken. Sampling here costs one sysctl and makes the decision current.
    public func cleanupNow(now: Date = Date()) {
        guard !isHaltedForUpdate else { return }
        if let fresh = try? sampler.sample(idleTracker: idleTracker) {
            snapshot = fresh
            lastSuccessfulPoll = Date()
            runCleanup(snapshot: fresh)
        } else if let snapshot,
            now.timeIntervalSince(snapshot.timestamp) <= Self.maximumFallbackSnapshotAge
        {
            // Sampling failed, but the stored snapshot is essentially the current picture.
            // The reaper still re-verifies each target's identity before signalling it.
            runCleanup(snapshot: snapshot)
        } else {
            // Identity verification catches pid reuse, not a session that became active or
            // an ancestry that changed since the snapshot. Those are decided from the
            // sample, and `poll` may have stored one up to an hour ago, so an old snapshot
            // must not stand in for a fresh one. Refusing is shown rather than silent.
            lastError = "Keine aktuelle Messung möglich — Bereinigung abgebrochen."
        }
    }

    /// How old a stored snapshot may be and still replace a failed sample. Seconds, not the
    /// poll interval: every safety rule that reads liveness was evaluated against it.
    public static let maximumFallbackSnapshotAge: TimeInterval = 60

    private func runCleanup(snapshot: ZombieSnapshot) {
        guard !isCleaning, !isHaltedForUpdate else { return }
        isCleaning = true
        let policy = preferences.cleanupPolicy
        let service = cleanupService
        let notifyEnabled = preferences.notificationsEnabled

        // Signalling and the verification re-sample both block; keeping them off the
        // main actor stops the menu from freezing during a cleanup.
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = service.run(on: snapshot, policy: policy)
            guard let strongSelf = self else { return }
            await MainActor.run {
                strongSelf.isCleaning = false
                strongSelf.lastCleanup = report
                strongSelf.log.append(report: report, snapshot: snapshot)
                if notifyEnabled, report.didAnything {
                    strongSelf.notifier.notifyCleanup(report)
                }
                // The estimator's history describes the pre-cleanup curve and would
                // produce a nonsense ETA after a large drop.
                strongSelf.estimator.reset()
                strongSelf.poll()
            }
        }
    }

    // MARK: - Presentation

    /// Compact figure for the menu bar: the zombie count, or the usage percentage once
    /// things get serious, because that is the number that predicts the failure.
    public var menuBarTitle: String {
        guard let snapshot else { return "–" }
        if severity == .normal { return Formatting.count(snapshot.zombieCount) }
        return "\(Formatting.count(snapshot.zombieCount)) · "
            + Formatting.percent(snapshot.usageFraction)
    }

    /// Parents currently leaking, for the menu.
    public var offenders: [ZombieParent] {
        Array((snapshot?.offenders ?? []).prefix(5))
    }

    public var cleanupCandidates: [ZombieParent] {
        guard let snapshot else { return [] }
        return reaper.selectTargets(in: snapshot, policy: preferences.cleanupPolicy).targets
    }
}
