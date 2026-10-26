import Foundation

/// Coordinates adaptive low-frequency background monitoring, threshold persistence confirmation,
/// on-demand process aggregation, and main-thread snapshot delivery.
public final class AdaptiveMonitorCoordinator {
    public enum SamplingMode: Equatable, Sendable {
        case stopped
        case lowFrequency(intervalSeconds: TimeInterval)
        case confirmingThreshold(intervalSeconds: TimeInterval)
        case popoverInteractive(intervalSeconds: TimeInterval)
    }

    private let monitorQueue = DispatchQueue(label: "com.macresourceguard.monitor", qos: .utility)
    private let settings: AppSettingsStore
    private let systemSampler: SystemMetricsSampler
    private let processAggregator: ProcessAggregator
    private let alertStateMachine: AlertStateMachine

    private var timer: DispatchSourceTimer?
    private var isRunning: Bool = false
    private var isPopoverVisible: Bool = false
    public private(set) var currentMode: SamplingMode = .stopped

    /// Cached top applications and background processes from the most recent detailed sample
    private var cachedTopByCPU: [AggregatedAppProcess] = []
    private var cachedTopByMemory: [AggregatedAppProcess] = []
    private var cachedTopBackgroundByCPU: [AggregatedAppProcess] = []
    private var cachedTopBackgroundByMemory: [AggregatedAppProcess] = []
    private var cachedHasIncompleteMetrics: Bool = false

    public private(set) var latestSnapshot: SystemSnapshot?

    /// Invoked on the main thread when a new snapshot is available.
    public var onSnapshotUpdate: ((SystemSnapshot) -> Void)?

    /// Invoked on the main thread when an actionable resource alert is triggered.
    public var onAlertTriggered: ((ResourceAlertEvent, SystemSnapshot) -> Void)?

    public init(
        settings: AppSettingsStore = .shared,
        systemSampler: SystemMetricsSampler = SystemMetricsSampler(),
        processAggregator: ProcessAggregator = ProcessAggregator(),
        alertStateMachine: AlertStateMachine = AlertStateMachine()
    ) {
        self.settings = settings
        self.systemSampler = systemSampler
        self.processAggregator = processAggregator
        self.alertStateMachine = alertStateMachine

        self.systemSampler.onKernelMemoryPressureChange = { [weak self] _ in
            // React immediately on the monitorQueue if the kernel fires a memory-pressure event
            self?.performSampleTick(forceDetailedProcesses: true)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: AppSettingsStore.didChangeNotification,
            object: settings
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    // MARK: - Lifecycle Controls

    public func start() {
        monitorQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true
            self.systemSampler.startMemoryPressureListener(on: self.monitorQueue)
            // Perform initial inexpensive system-wide sample without enumerating all processes at launch
            self.performSampleTick(forceDetailedProcesses: false)
            self.rescheduleTimerIfNeeded()
        }
    }

    public func stop() {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.systemSampler.stopMemoryPressureListener()
            self.timer?.cancel()
            self.timer = nil
            self.currentMode = .stopped
        }
    }

    /// Notifies the coordinator whether the user is actively viewing the popover.
    /// When open, performs an immediate detailed sample and refreshes while open;
    /// when closed, immediately returns to low-frequency background monitoring.
    public func setPopoverVisible(_ visible: Bool) {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            let changed = (self.isPopoverVisible != visible)
            self.isPopoverVisible = visible
            guard changed else { return }

            if visible {
                // Prime process baseline immediately, emit fast snapshot, and schedule a 0.6s follow-up
                // so live per-process CPU deltas are fresh right after opening the popover.
                self.processAggregator.primeBaseline()
                self.performSampleTick(forceDetailedProcesses: true)
                self.monitorQueue.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    guard let self = self, self.isPopoverVisible else { return }
                    self.performSampleTick(forceDetailedProcesses: true)
                }
            }
            self.rescheduleTimerIfNeeded()
        }
    }

    /// Requests an immediate on-demand refresh (e.g., after quitting an application).
    public func requestImmediateRefresh(detailed: Bool = true) {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            if detailed {
                self.performSampleTick(forceDetailedProcesses: true)
            } else {
                self.performSampleTick(forceDetailedProcesses: false)
            }
        }
    }

    @objc private func handleSettingsChanged() {
        monitorQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.rescheduleTimerIfNeeded()
        }
    }

    // MARK: - Adaptive Timer Management

    private func desiredSamplingMode() -> SamplingMode {
        guard isRunning else { return .stopped }
        if isPopoverVisible {
            return .popoverInteractive(intervalSeconds: 3.0)
        }
        if alertStateMachine.isConfirmingThresholdPersistence {
            return .confirmingThreshold(intervalSeconds: 2.0)
        }
        let baseInterval = AppSettingsStore.clamp(settings.monitoringIntervalSeconds, min: 5.0, max: 60.0)
        return .lowFrequency(intervalSeconds: baseInterval)
    }

    private func rescheduleTimerIfNeeded() {
        let targetMode = desiredSamplingMode()
        guard targetMode != currentMode else { return }
        currentMode = targetMode

        timer?.cancel()
        timer = nil

        let intervalSeconds: TimeInterval
        let leeway: DispatchTimeInterval

        switch targetMode {
        case .stopped:
            return
        case .lowFrequency(let interval):
            intervalSeconds = interval
            leeway = .milliseconds(1000)
        case .confirmingThreshold(let interval):
            intervalSeconds = interval
            leeway = .milliseconds(250)
        case .popoverInteractive(let interval):
            intervalSeconds = interval
            leeway = .milliseconds(250)
        }

        let newTimer = DispatchSource.makeTimerSource(queue: monitorQueue)
        newTimer.schedule(
            deadline: .now() + intervalSeconds,
            repeating: intervalSeconds,
            leeway: leeway
        )
        newTimer.setEventHandler { [weak self] in
            self?.performSampleTick(forceDetailedProcesses: false)
        }
        newTimer.resume()
        self.timer = newTimer
    }

    // MARK: - Core Sampling Tick

    private func performSampleTick(forceDetailedProcesses: Bool) {
        autoreleasepool {
            let wasConfirming = alertStateMachine.isConfirmingThresholdPersistence
            let sysSample = systemSampler.sampleSystemWide()

            let alertConfig = AlertConfiguration(
                cpuAlertsEnabled: settings.cpuAlertsEnabled,
                memoryAlertsEnabled: settings.memoryAlertsEnabled,
                notificationsEnabled: settings.notificationsEnabled,
                doNotDisturbEnabled: settings.doNotDisturbEnabled,
                isPaused: settings.isCurrentlyPaused(),
                cpuWarningThresholdPercent: settings.cpuWarningThresholdPercent,
                cpuSustainedDurationSeconds: settings.cpuSustainedDurationSeconds,
                cpuHysteresisMarginPercent: settings.cpuHysteresisMarginPercent,
                memoryConfirmationSeconds: 6.0,
                cooldownSeconds: settings.notificationCooldownSeconds
            )

            var didSampleProcessesThisTick = false
            let ensureProcessesSampled: () -> Void = { [weak self] in
                guard let self = self, !didSampleProcessesThisTick else { return }
                didSampleProcessesThisTick = true
                let result = self.processAggregator.sampleTopApplications(topCount: 15)
                self.cachedTopByCPU = result.topByCPU
                self.cachedTopByMemory = result.topByMemory
                self.cachedTopBackgroundByCPU = result.topBackgroundByCPU
                self.cachedTopBackgroundByMemory = result.topBackgroundByMemory
                self.cachedHasIncompleteMetrics = result.hasIncompleteMetrics
            }

            // If popover is open or forced, sample processes before evaluation
            if forceDetailedProcesses || isPopoverVisible {
                ensureProcessesSampled()
            }

            let eval = alertStateMachine.evaluate(
                timestampNs: sysSample.timestampNs,
                cpuPercent: sysSample.cpuTotalPercent,
                memoryPressure: sysSample.memory.pressureLevel,
                config: alertConfig,
                topAppsByCPU: {
                    ensureProcessesSampled()
                    return self.cachedTopByCPU
                },
                topAppsByMemory: {
                    ensureProcessesSampled()
                    return self.cachedTopByMemory
                }
            )

            // If we just transitioned from normal into confirming, prime the process CPU baseline
            // so that when the confirmation window finishes, we have an exact per-process CPU delta!
            if !wasConfirming && alertStateMachine.isConfirmingThresholdPersistence && !didSampleProcessesThisTick {
                processAggregator.primeBaseline()
            }

            let snapshot = SystemSnapshot(
                timestampNs: sysSample.timestampNs,
                wallTime: Date(),
                cpuTotalPercent: sysSample.cpuTotalPercent,
                cpuUserPercent: sysSample.cpuUserPercent,
                cpuSystemPercent: sysSample.cpuSystemPercent,
                coreCount: systemSampler.logicalCoreCount,
                memory: sysSample.memory,
                severity: eval.severity,
                primaryPressureKind: eval.primaryKind,
                statusSummary: eval.statusSummary,
                topAppsByCPU: cachedTopByCPU,
                topAppsByMemory: cachedTopByMemory,
                topBackgroundByCPU: cachedTopBackgroundByCPU,
                topBackgroundByMemory: cachedTopBackgroundByMemory,
                isDetailedSample: didSampleProcessesThisTick,
                hasIncompleteProcessMetrics: cachedHasIncompleteMetrics
            )

            // Adjust timer frequency if confirmation state changed (e.g. return to low-frequency after alert fires!)
            rescheduleTimerIfNeeded()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.latestSnapshot = snapshot
                self.onSnapshotUpdate?(snapshot)
                if let triggeredAlert = eval.triggeredAlert {
                    self.onAlertTriggered?(triggeredAlert, snapshot)
                }
            }
        }
    }
}
