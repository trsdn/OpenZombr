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
    private let idleTracker = IdleTracker()
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
        guard timer == nil else { return }
        poll()
        restartTimer()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
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
    public func cleanupNow() {
        if let fresh = try? sampler.sample(idleTracker: idleTracker) {
            snapshot = fresh
            lastSuccessfulPoll = Date()
            runCleanup(snapshot: fresh)
        } else if let snapshot {
            // Sampling failed. Falling back to the stored snapshot is still safe because
            // the reaper re-verifies each target's identity before signalling it.
            runCleanup(snapshot: snapshot)
        }
    }

    private func runCleanup(snapshot: ZombieSnapshot) {
        guard !isCleaning else { return }
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
