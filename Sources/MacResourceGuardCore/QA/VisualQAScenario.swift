import Foundation

public enum VisualQANotificationPresentation: Equatable, Sendable {
    case enabled
    case disabled
    case paused
    case doNotDisturb

    public var subtitlePrefix: String? {
        switch self {
        case .enabled:
            return nil
        case .disabled:
            return "Alerts disabled."
        case .paused:
            return "Alerts paused temporarily."
        case .doNotDisturb:
            return "Do Not Disturb active."
        }
    }
}

public enum VisualQASafetyPolicy: Equatable, Sendable {
    case production
    case visualQAMode

    public var allowsDestructiveActions: Bool {
        self == .production
    }
}

public enum VisualQAScenario: String, CaseIterable, Sendable {
    case normal
    case highCPU
    case memoryPressure
    case singleSelection
    case multipleSelection
    case notificationsEnabled
    case notificationsPaused
    case doNotDisturb
    case forceQuitConfirmation

    public static func launchScenario(in arguments: [String]) -> VisualQAScenario? {
        let prefix = "--visual-qa-scenario="
        let values = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(prefix) else { return nil }
            return String(argument.dropFirst(prefix.count))
        }
        guard values.count == 1 else { return nil }
        return VisualQAScenario(rawValue: values[0])
    }

    public var notificationPresentation: VisualQANotificationPresentation {
        switch self {
        case .notificationsEnabled:
            return .enabled
        case .notificationsPaused:
            return .paused
        case .doNotDisturb:
            return .doNotDisturb
        default:
            return .disabled
        }
    }

    public var selectedProcessIDs: Set<pid_t> {
        switch self {
        case .singleSelection:
            return [-101]
        case .multipleSelection:
            return [-101, -102]
        default:
            return []
        }
    }

    public var snapshot: SystemSnapshot {
        let state: (cpu: Double, user: Double, system: Double, severity: ResourceSeverity, kind: PressureResourceKind, pressure: MemoryPressureLevel, summary: String)
        switch self {
        case .highCPU:
            state = (94.0, 71.0, 23.0, .critical, .cpu, .normal, "CPU utilization is critically high.")
        case .memoryPressure:
            state = (42.0, 30.0, 12.0, .critical, .memory, .critical, "Memory pressure is critical with active compression.")
        default:
            state = (18.0, 12.0, 6.0, .normal, .none, .normal, "Resources are operating normally.")
        }

        let apps = Self.syntheticApplications
        return SystemSnapshot(
            timestampNs: 1_978_111,
            wallTime: Date(timeIntervalSince1970: 252_460_800),
            cpuTotalPercent: state.cpu,
            cpuUserPercent: state.user,
            cpuSystemPercent: state.system,
            coreCount: 8,
            memory: Self.memoryMetrics(pressure: state.pressure),
            severity: state.severity,
            primaryPressureKind: state.kind,
            statusSummary: state.summary,
            topAppsByCPU: apps,
            topAppsByMemory: [apps[2], apps[1], apps[0]],
            isDetailedSample: true,
            hasIncompleteProcessMetrics: false
        )
    }

    private static let syntheticApplications: [AggregatedAppProcess] = [
        app(id: -101, name: "Aurora Editor", bundleID: "qa.111iridescence.aurora", cpu: 31.4, memoryMiB: 768),
        app(id: -102, name: "Northstar Browser", bundleID: "qa.111iridescence.northstar", cpu: 22.8, memoryMiB: 1_420, helpers: 4),
        app(id: -103, name: "Canvas Studio", bundleID: "qa.111iridescence.canvas", cpu: 14.2, memoryMiB: 2_240, helpers: 2)
    ]

    private static func app(
        id: pid_t,
        name: String,
        bundleID: String,
        cpu: Double,
        memoryMiB: UInt64,
        helpers: Int = 0
    ) -> AggregatedAppProcess {
        AggregatedAppProcess(
            id: id,
            startTimeSec: 0,
            startTimeUsec: 0,
            bundleIdentifier: bundleID,
            displayName: name,
            executablePath: nil,
            cpuPercentMachine: cpu,
            cpuPercentSingleCoreEquivalent: cpu * 8.0,
            memoryFootprintBytes: memoryMiB * 1_024 * 1_024,
            helperProcessCount: helpers,
            groupedPIDs: [id],
            isProtectedSystemApp: false
        )
    }

    private static func memoryMetrics(pressure: MemoryPressureLevel) -> MemoryMetrics {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        switch pressure {
        case .critical:
            return MemoryMetrics(
                totalPhysicalBytes: 16 * gib,
                appMemoryBytes: 10 * gib,
                wiredBytes: 2 * gib,
                compressedBytes: 3 * gib,
                cachedFilesBytes: gib / 2,
                availableBytes: gib / 2,
                swapUsedBytes: 4 * gib,
                swapTotalBytes: 6 * gib,
                swapOutsDeltaPages: 2_048,
                swapRateBytesPerSec: 24 * 1_024 * 1_024,
                kernelPressureRawLevel: 4,
                dispatchPressureLevel: .critical,
                pressureLevel: .critical
            )
        case .normal, .elevated:
            return MemoryMetrics(
                totalPhysicalBytes: 16 * gib,
                appMemoryBytes: 5 * gib,
                wiredBytes: 2 * gib,
                compressedBytes: gib / 2,
                cachedFilesBytes: 4 * gib,
                availableBytes: 8 * gib,
                swapUsedBytes: 0,
                swapTotalBytes: 4 * gib,
                swapOutsDeltaPages: 0,
                swapRateBytesPerSec: 0,
                kernelPressureRawLevel: 1,
                dispatchPressureLevel: .normal,
                pressureLevel: .normal
            )
        }
    }
}
