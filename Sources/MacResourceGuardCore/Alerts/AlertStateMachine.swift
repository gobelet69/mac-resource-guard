import Foundation

/// Actionable alert payload emitted when sustained CPU or memory pressure is confirmed.
public struct ResourceAlertEvent: Equatable {
    public let id: UUID
    public let timestampNs: UInt64
    public let wallTime: Date
    public let kind: PressureResourceKind
    public let severity: ResourceSeverity
    public let title: String
    public let message: String
    public let cpuPercent: Double
    public let memoryPressure: MemoryPressureLevel
    public let topApplications: [AggregatedAppProcess]

    public init(
        id: UUID = UUID(),
        timestampNs: UInt64,
        wallTime: Date = Date(),
        kind: PressureResourceKind,
        severity: ResourceSeverity,
        title: String,
        message: String,
        cpuPercent: Double,
        memoryPressure: MemoryPressureLevel,
        topApplications: [AggregatedAppProcess]
    ) {
        self.id = id
        self.timestampNs = timestampNs
        self.wallTime = wallTime
        self.kind = kind
        self.severity = severity
        self.title = title
        self.message = message
        self.cpuPercent = cpuPercent
        self.memoryPressure = memoryPressure
        self.topApplications = topApplications
    }
}

/// Configuration snapshot passed to the AlertStateMachine on each evaluation step.
public struct AlertConfiguration: Equatable, Sendable {
    public var cpuAlertsEnabled: Bool
    public var memoryAlertsEnabled: Bool
    public var notificationsEnabled: Bool
    public var doNotDisturbEnabled: Bool
    public var isPaused: Bool
    public var cpuWarningThresholdPercent: Double
    public var cpuSustainedDurationSeconds: TimeInterval
    public var cpuHysteresisMarginPercent: Double
    public var memoryConfirmationSeconds: TimeInterval
    public var cooldownSeconds: TimeInterval

    public init(
        cpuAlertsEnabled: Bool = true,
        memoryAlertsEnabled: Bool = true,
        notificationsEnabled: Bool = true,
        doNotDisturbEnabled: Bool = false,
        isPaused: Bool = false,
        cpuWarningThresholdPercent: Double = 85.0,
        cpuSustainedDurationSeconds: TimeInterval = 25.0,
        cpuHysteresisMarginPercent: Double = 10.0,
        memoryConfirmationSeconds: TimeInterval = 6.0,
        cooldownSeconds: TimeInterval = 300.0
    ) {
        self.cpuAlertsEnabled = cpuAlertsEnabled
        self.memoryAlertsEnabled = memoryAlertsEnabled
        self.notificationsEnabled = notificationsEnabled
        self.doNotDisturbEnabled = doNotDisturbEnabled
        self.isPaused = isPaused
        self.cpuWarningThresholdPercent = cpuWarningThresholdPercent
        self.cpuSustainedDurationSeconds = cpuSustainedDurationSeconds
        self.cpuHysteresisMarginPercent = cpuHysteresisMarginPercent
        self.memoryConfirmationSeconds = memoryConfirmationSeconds
        self.cooldownSeconds = cooldownSeconds
    }
}

/// Pure, deterministic state machine that handles CPU & memory threshold detection,
/// sustained duration verification, hysteresis recovery, and notification cooldowns.
public final class AlertStateMachine {
    public enum ChannelState: Equatable, Sendable {
        case normal
        case confirming(sinceTimestampNs: UInt64)
        case alertedAwaitingRecovery(alertedAtNs: UInt64, alertedSeverity: ResourceSeverity)
    }

    public private(set) var cpuState: ChannelState = .normal
    public private(set) var memoryState: ChannelState = .normal

    public private(set) var lastCPUAlertTimestampNs: UInt64?
    public private(set) var lastMemoryAlertTimestampNs: UInt64?
    public private(set) var lastTriggeredAlert: ResourceAlertEvent?

    public init() {}

    /// True ONLY when a threshold has been crossed and the state machine is actively confirming persistence
    /// before emitting an alert. Once the alert is emitted (or the burst ends), this returns false so
    /// the coordinator returns to low-frequency monitoring.
    public var isConfirmingThresholdPersistence: Bool {
        if case .confirming = cpuState { return true }
        if case .confirming = memoryState { return true }
        return false
    }

    public struct EvaluationOutput {
        public let severity: ResourceSeverity
        public let primaryKind: PressureResourceKind
        public let statusSummary: String
        public let needsDetailedSamplingNow: Bool
        public let triggeredAlert: ResourceAlertEvent?
    }

    /// Evaluates a new system sample and updates CPU and Memory alert state machines.
    /// - Parameters:
    ///   - timestampNs: Monotonic timestamp in nanoseconds.
    ///   - cpuPercent: Normalized overall CPU utilization (0.0...100.0).
    ///   - memoryPressure: Current intelligent memory pressure level.
    ///   - config: Current user alert configuration.
    ///   - topAppsByCPU: Top applications ranked by CPU (used when an alert triggers).
    ///   - topAppsByMemory: Top applications ranked by Memory (used when an alert triggers).
    public func evaluate(
        timestampNs: UInt64,
        cpuPercent: Double,
        memoryPressure: MemoryPressureLevel,
        config: AlertConfiguration,
        topAppsByCPU: () -> [AggregatedAppProcess],
        topAppsByMemory: () -> [AggregatedAppProcess]
    ) -> EvaluationOutput {
        let cpuRecoveryThreshold = max(10.0, config.cpuWarningThresholdPercent - config.cpuHysteresisMarginPercent)
        let sustainedNs = UInt64(max(1.0, config.cpuSustainedDurationSeconds) * 1_000_000_000.0)
        let memConfirmNs = UInt64(max(1.0, config.memoryConfirmationSeconds) * 1_000_000_000.0)
        let cooldownNs = UInt64(max(1.0, config.cooldownSeconds) * 1_000_000_000.0)

        var cpuReadyToFire = false
        var memoryReadyToFire = false

        // --- 1. CPU State Transitions ---
        switch cpuState {
        case .normal:
            if cpuPercent >= config.cpuWarningThresholdPercent {
                cpuState = .confirming(sinceTimestampNs: timestampNs)
            }
        case .confirming(let sinceNs):
            if cpuPercent < config.cpuWarningThresholdPercent {
                // Short burst ended before sustained duration was reached -> return to normal without alerting
                cpuState = .normal
            } else if timestampNs >= sinceNs && (timestampNs - sinceNs) >= sustainedNs {
                cpuReadyToFire = true
            }
        case .alertedAwaitingRecovery:
            // Hysteresis: require CPU to drop at or below recoveryThreshold before resetting alert eligibility
            if cpuPercent <= cpuRecoveryThreshold {
                cpuState = .normal
            }
        }

        // --- 2. Memory Pressure State Transitions ---
        switch memoryState {
        case .normal:
            if memoryPressure >= .elevated {
                memoryState = .confirming(sinceTimestampNs: timestampNs)
                // If already critical on entry, shorten confirmation
                if memoryPressure == .critical && memConfirmNs == 0 {
                    memoryReadyToFire = true
                }
            }
        case .confirming(let sinceNs):
            if memoryPressure == .normal {
                memoryState = .normal
            } else {
                let requiredNs = (memoryPressure == .critical) ? min(memConfirmNs, 2_000_000_000) : memConfirmNs
                if timestampNs >= sinceNs && (timestampNs - sinceNs) >= requiredNs {
                    memoryReadyToFire = true
                }
            }
        case .alertedAwaitingRecovery(_, let previousSeverity):
            if memoryPressure == .normal {
                // Hysteresis: recovered to normal
                memoryState = .normal
            } else if memoryPressure == .critical && previousSeverity == .elevated {
                // Escalated from elevated to critical
                memoryReadyToFire = true
            }
        }

        // --- 3. Determine Overall Severity & Primary Resource ---
        let cpuSeverity: ResourceSeverity
        if cpuPercent >= min(98.0, config.cpuWarningThresholdPercent + 10.0) {
            cpuSeverity = .critical
        } else if cpuPercent >= config.cpuWarningThresholdPercent {
            cpuSeverity = .elevated
        } else {
            cpuSeverity = .normal
        }

        let memSeverity: ResourceSeverity
        switch memoryPressure {
        case .normal: memSeverity = .normal
        case .elevated: memSeverity = .elevated
        case .critical: memSeverity = .critical
        }

        let overallSeverity = max(cpuSeverity, memSeverity)
        let primaryKind: PressureResourceKind
        if cpuSeverity > .normal && memSeverity > .normal {
            primaryKind = .both
        } else if memSeverity > .normal {
            primaryKind = .memory
        } else if cpuSeverity > .normal {
            primaryKind = .cpu
        } else {
            primaryKind = .none
        }

        // --- 4. Check Cooldown, DND, Pause, and Emit Actionable Alert ---
        var firedAlert: ResourceAlertEvent? = nil
        let notificationsSuppressed = config.isPaused || config.doNotDisturbEnabled || !config.notificationsEnabled

        if cpuReadyToFire {
            let cooldownExpired: Bool
            if let lastNs = lastCPUAlertTimestampNs, timestampNs >= lastNs {
                cooldownExpired = (timestampNs - lastNs) >= cooldownNs
            } else {
                cooldownExpired = true
            }

            if config.cpuAlertsEnabled && !notificationsSuppressed && cooldownExpired {
                let topCPU = topAppsByCPU()
                let topAppText: String
                if let culprit = topCPU.first {
                    topAppText = String(format: "%@ is using %.1f%% CPU.", culprit.displayName, culprit.cpuPercentMachine)
                } else {
                    topAppText = "Open Mac Resource Guard to inspect running applications."
                }
                let alert = ResourceAlertEvent(
                    timestampNs: timestampNs,
                    kind: memSeverity > .normal ? .both : .cpu,
                    severity: max(.elevated, cpuSeverity),
                    title: String(format: "High CPU Usage (%.0f%%)", cpuPercent),
                    message: "Sustained CPU load above \(Int(config.cpuWarningThresholdPercent))%. \(topAppText)",
                    cpuPercent: cpuPercent,
                    memoryPressure: memoryPressure,
                    topApplications: topCPU
                )
                firedAlert = alert
                lastTriggeredAlert = alert
                lastCPUAlertTimestampNs = timestampNs
                cpuState = .alertedAwaitingRecovery(alertedAtNs: timestampNs, alertedSeverity: cpuSeverity)
            } else if !config.cpuAlertsEnabled || notificationsSuppressed || !cooldownExpired {
                // Transition out of confirming so we return to low-frequency monitoring instead of spinning
                cpuState = .alertedAwaitingRecovery(alertedAtNs: timestampNs, alertedSeverity: cpuSeverity)
            }
        }

        if memoryReadyToFire {
            let isEscalationToCritical: Bool
            if case .alertedAwaitingRecovery(_, let prevSev) = memoryState, prevSev == .elevated && memSeverity == .critical {
                isEscalationToCritical = true
            } else {
                isEscalationToCritical = false
            }

            let cooldownExpired: Bool
            if isEscalationToCritical {
                cooldownExpired = true
            } else if let lastNs = lastMemoryAlertTimestampNs, timestampNs >= lastNs {
                cooldownExpired = (timestampNs - lastNs) >= cooldownNs
            } else {
                cooldownExpired = true
            }

            if config.memoryAlertsEnabled && !notificationsSuppressed && cooldownExpired && firedAlert == nil {
                let topMem = topAppsByMemory()
                let topAppText: String
                if let culprit = topMem.first {
                    topAppText = "\(culprit.displayName) is using \(ByteFormatter.formatBytes(culprit.memoryFootprintBytes))."
                } else {
                    topAppText = "Open Mac Resource Guard to close memory-intensive apps."
                }
                let title = memoryPressure == .critical ? "Critical Memory Pressure" : "Elevated Memory Pressure"
                let alert = ResourceAlertEvent(
                    timestampNs: timestampNs,
                    kind: cpuSeverity > .normal ? .both : .memory,
                    severity: memSeverity,
                    title: title,
                    message: "\(memoryPressure.title) detected. \(topAppText)",
                    cpuPercent: cpuPercent,
                    memoryPressure: memoryPressure,
                    topApplications: topMem
                )
                firedAlert = alert
                lastTriggeredAlert = alert
                lastMemoryAlertTimestampNs = timestampNs
                memoryState = .alertedAwaitingRecovery(alertedAtNs: timestampNs, alertedSeverity: memSeverity)
            } else {
                memoryState = .alertedAwaitingRecovery(alertedAtNs: timestampNs, alertedSeverity: memSeverity)
            }
        }

        // --- 5. Build Status Summary ---
        let statusSummary: String
        switch primaryKind {
        case .none:
            statusSummary = "System resources are operating within healthy limits."
        case .cpu:
            if case .confirming = cpuState {
                statusSummary = String(format: "Elevated CPU (%.0f%%) — verifying if sustained…", cpuPercent)
            } else {
                statusSummary = String(format: "Sustained CPU load (%.0f%% across %d cores).", cpuPercent, ProcessInfo.processInfo.activeProcessorCount)
            }
        case .memory:
            statusSummary = memoryPressure.summaryDescription
        case .both:
            statusSummary = String(format: "High CPU (%.0f%%) and %@", cpuPercent, memoryPressure.title.lowercased())
        }

        return EvaluationOutput(
            severity: overallSeverity,
            primaryKind: primaryKind,
            statusSummary: statusSummary,
            needsDetailedSamplingNow: isConfirmingThresholdPersistence || firedAlert != nil,
            triggeredAlert: firedAlert
        )
    }

    public func reset() {
        cpuState = .normal
        memoryState = .normal
        lastCPUAlertTimestampNs = nil
        lastMemoryAlertTimestampNs = nil
        lastTriggeredAlert = nil
    }
}
