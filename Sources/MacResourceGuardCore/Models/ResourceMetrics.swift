import Foundation
import AppKit

/// Represents the intelligent memory pressure state of macOS.
/// Unlike naive "RAM used %" metrics, this reflects kernel memory pressure signals,
/// compressor load, and active swap activity rather than benign file caching.
public enum MemoryPressureLevel: Int, Comparable, Codable, Sendable {
    case normal = 0
    case elevated = 1
    case critical = 2

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .normal:
            return "Healthy"
        case .elevated:
            return "Elevated Pressure"
        case .critical:
            return "Critical Pressure"
        }
    }

    public var summaryDescription: String {
        switch self {
        case .normal:
            return "Memory is healthy. Cached files can be reclaimed instantly by macOS."
        case .elevated:
            return "Memory compression and swap activity are elevated."
        case .critical:
            return "Critical memory pressure with active swap thrashing. Close heavy apps."
        }
    }
}

/// Overall severity level for status bar indicator and alerts.
public enum ResourceSeverity: Int, Comparable, Codable, Sendable {
    case normal = 0
    case elevated = 1
    case critical = 2

    public static func < (lhs: ResourceSeverity, rhs: ResourceSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var badgeText: String {
        switch self {
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

/// Identifies which system resource is primarily responsible for pressure.
public enum PressureResourceKind: String, Codable, Sendable {
    case none
    case cpu
    case memory
    case both

    public var displayName: String {
        switch self {
        case .none: return "System Normal"
        case .cpu: return "CPU Utilization"
        case .memory: return "Memory Pressure"
        case .both: return "CPU & Memory Pressure"
        }
    }
}

/// Raw Mach host CPU load tick counters across all logical cores.
public struct CPUTicksSample: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Computes normalized system-wide CPU percentages (0.0...100.0) from two tick samples.
    /// Because `HOST_CPU_LOAD_INFO` aggregates ticks across all logical cores,
    /// dividing active tick deltas by total tick deltas across all cores naturally normalizes to 0-100%.
    public static func calculateUsage(
        previous: CPUTicksSample,
        current: CPUTicksSample
    ) -> (totalPercent: Double, userPercent: Double, systemPercent: Double) {
        let userDelta = current.user >= previous.user ? current.user - previous.user : 0
        let systemDelta = current.system >= previous.system ? current.system - previous.system : 0
        let idleDelta = current.idle >= previous.idle ? current.idle - previous.idle : 0
        let niceDelta = current.nice >= previous.nice ? current.nice - previous.nice : 0

        let activeTicks = userDelta + systemDelta + niceDelta
        let totalTicks = activeTicks + idleDelta

        guard totalTicks > 0 else {
            return (0.0, 0.0, 0.0)
        }

        let totalDouble = Double(totalTicks)
        let totalPercent = min(100.0, max(0.0, (Double(activeTicks) / totalDouble) * 100.0))
        let userPercent = min(100.0, max(0.0, (Double(userDelta + niceDelta) / totalDouble) * 100.0))
        let systemPercent = min(100.0, max(0.0, (Double(systemDelta) / totalDouble) * 100.0))

        return (totalPercent, userPercent, systemPercent)
    }
}

/// System-wide memory and swap statistics derived from Mach VM counters and sysctl.
/// Note: This combines documented kernel pressure signals (`kern.memorystatus_vm_pressure_level`
/// and `DispatchSourceMemoryPressure`) with Mach VM metrics (`HOST_VM_INFO64` and `vm.swapusage`).
/// It is an engineering heuristic rather than a claim to replicate Activity Monitor's undocumented internal graph formula.
public struct MemoryMetrics: Equatable, Sendable {
    public let totalPhysicalBytes: UInt64
    public let appMemoryBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let availableBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapOutsDeltaPages: UInt64
    public let swapRateBytesPerSec: Double
    public let kernelPressureRawLevel: Int32
    public let dispatchPressureLevel: MemoryPressureLevel
    public let pressureLevel: MemoryPressureLevel

    public init(
        totalPhysicalBytes: UInt64,
        appMemoryBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedFilesBytes: UInt64,
        availableBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        swapOutsDeltaPages: UInt64,
        swapRateBytesPerSec: Double,
        kernelPressureRawLevel: Int32,
        dispatchPressureLevel: MemoryPressureLevel,
        pressureLevel: MemoryPressureLevel
    ) {
        self.totalPhysicalBytes = totalPhysicalBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.availableBytes = availableBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapOutsDeltaPages = swapOutsDeltaPages
        self.swapRateBytesPerSec = swapRateBytesPerSec
        self.kernelPressureRawLevel = kernelPressureRawLevel
        self.dispatchPressureLevel = dispatchPressureLevel
        self.pressureLevel = pressureLevel
    }

    /// Evaluates composite memory pressure without false alarms from high file cache usage.
    public static func evaluatePressureLevel(
        totalPhysicalBytes: UInt64,
        availableBytes: UInt64,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        swapRateBytesPerSec: Double,
        kernelPressureRawLevel: Int32,
        dispatchPressureLevel: MemoryPressureLevel
    ) -> MemoryPressureLevel {
        // 1. Honor explicit kernel critical signals immediately
        if kernelPressureRawLevel >= 4 || dispatchPressureLevel == .critical {
            return .critical
        }

        // 2. Honor explicit kernel warning signals
        if kernelPressureRawLevel == 2 || dispatchPressureLevel == .elevated {
            // Check if supporting metrics indicate severe thrashing that warrants critical
            let total = Double(max(1, totalPhysicalBytes))
            let availableRatio = Double(availableBytes) / total
            let compressedRatio = Double(compressedBytes) / total
            if availableRatio < 0.05 && compressedRatio > 0.35 && swapRateBytesPerSec > 16.0 * 1024.0 * 1024.0 {
                return .critical
            }
            return .elevated
        }

        // 3. Supporting Mach VM heuristics when kernel pressure sysctl is still at 1:
        // Note that `availableBytes` includes free + inactive + purgeable + external (file cache).
        // Therefore, a system with 90% RAM filled by file cache has high `availableBytes` and stays `.normal`.
        guard totalPhysicalBytes > 0 else { return .normal }
        let total = Double(totalPhysicalBytes)
        let availableRatio = Double(availableBytes) / total
        let compressedRatio = Double(compressedBytes) / total
        let mbPerSec = swapRateBytesPerSec / (1024.0 * 1024.0)

        // Critical: Very low reclaimable memory AND heavy compression AND active swap thrashing
        if availableRatio < 0.06 && compressedRatio > 0.40 && mbPerSec >= 20.0 {
            return .critical
        }

        // Elevated: Low reclaimable memory with substantial compression or sustained swap-out activity
        if availableRatio < 0.12 && (compressedRatio > 0.28 || (swapUsedBytes > 512 * 1024 * 1024 && mbPerSec >= 4.0)) {
            return .elevated
        }

        return .normal
    }
}

/// Represents a user-facing application aggregated with all of its verified child/helper processes.
public struct AggregatedAppProcess: Identifiable, Equatable {
    public let id: pid_t
    public let startTimeSec: UInt64
    public let startTimeUsec: UInt64
    public let bundleIdentifier: String?
    public let displayName: String
    public let executablePath: String?
    public let icon: NSImage?
    /// Normalized CPU usage as a percentage of total machine CPU capacity (0.0...100.0%).
    public let cpuPercentMachine: Double
    /// Unnormalized CPU usage where 100% = 1 full logical core (0.0...(coreCount * 100)%).
    public let cpuPercentSingleCoreEquivalent: Double
    /// Physical memory footprint (`ri_phys_footprint`) summed across main app + helper processes.
    public let memoryFootprintBytes: UInt64
    /// Number of child/helper processes aggregated into this entry (excluding the root process itself).
    public let helperProcessCount: Int
    /// All PIDs belonging to this application group.
    public let groupedPIDs: [pid_t]
    /// Whether this process is an essential macOS component or Mac Resource Guard itself.
    public let isProtectedSystemApp: Bool
    public let protectionReason: String?
    /// True if one or more processes in this group could not be inspected due to OS restrictions.
    public let hasIncompleteMetrics: Bool
    /// True if this entry represents a background agent/daemon/helper rather than a regular Dock application.
    public let isBackgroundProcess: Bool
    /// True if this process or application is part of macOS or Apple system services.
    public let isMacOSSystemRelated: Bool

    public var canSafelyClose: Bool {
        !isProtectedSystemApp
    }

    public var totalProcessCount: Int {
        1 + helperProcessCount
    }

    public init(
        id: pid_t,
        startTimeSec: UInt64,
        startTimeUsec: UInt64,
        bundleIdentifier: String?,
        displayName: String,
        executablePath: String?,
        icon: NSImage? = nil,
        cpuPercentMachine: Double,
        cpuPercentSingleCoreEquivalent: Double,
        memoryFootprintBytes: UInt64,
        helperProcessCount: Int,
        groupedPIDs: [pid_t],
        isProtectedSystemApp: Bool,
        protectionReason: String? = nil,
        hasIncompleteMetrics: Bool = false,
        isBackgroundProcess: Bool = false,
        isMacOSSystemRelated: Bool = false
    ) {
        self.id = id
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.executablePath = executablePath
        self.icon = icon
        self.cpuPercentMachine = cpuPercentMachine
        self.cpuPercentSingleCoreEquivalent = cpuPercentSingleCoreEquivalent
        self.memoryFootprintBytes = memoryFootprintBytes
        self.helperProcessCount = helperProcessCount
        self.groupedPIDs = groupedPIDs
        self.isProtectedSystemApp = isProtectedSystemApp
        self.protectionReason = protectionReason
        self.hasIncompleteMetrics = hasIncompleteMetrics
        self.isBackgroundProcess = isBackgroundProcess
        self.isMacOSSystemRelated = isMacOSSystemRelated
    }

    public static func == (lhs: AggregatedAppProcess, rhs: AggregatedAppProcess) -> Bool {
        lhs.id == rhs.id &&
        lhs.startTimeSec == rhs.startTimeSec &&
        lhs.startTimeUsec == rhs.startTimeUsec &&
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
        lhs.displayName == rhs.displayName &&
        abs(lhs.cpuPercentMachine - rhs.cpuPercentMachine) < 0.05 &&
        lhs.memoryFootprintBytes == rhs.memoryFootprintBytes &&
        lhs.helperProcessCount == rhs.helperProcessCount &&
        lhs.isProtectedSystemApp == rhs.isProtectedSystemApp &&
        lhs.hasIncompleteMetrics == rhs.hasIncompleteMetrics &&
        lhs.isBackgroundProcess == rhs.isBackgroundProcess &&
        lhs.isMacOSSystemRelated == rhs.isMacOSSystemRelated
    }
}

/// Complete point-in-time snapshot of system health and top resource-consuming applications.
public struct SystemSnapshot: Equatable {
    public let timestampNs: UInt64
    public let wallTime: Date
    public let cpuTotalPercent: Double
    public let cpuUserPercent: Double
    public let cpuSystemPercent: Double
    public let coreCount: Int
    public let memory: MemoryMetrics
    public let severity: ResourceSeverity
    public let primaryPressureKind: PressureResourceKind
    public let statusSummary: String
    public let topAppsByCPU: [AggregatedAppProcess]
    public let topAppsByMemory: [AggregatedAppProcess]
    public let topBackgroundByCPU: [AggregatedAppProcess]
    public let topBackgroundByMemory: [AggregatedAppProcess]
    public let isDetailedSample: Bool
    public let hasIncompleteProcessMetrics: Bool

    public init(
        timestampNs: UInt64,
        wallTime: Date = Date(),
        cpuTotalPercent: Double,
        cpuUserPercent: Double,
        cpuSystemPercent: Double,
        coreCount: Int,
        memory: MemoryMetrics,
        severity: ResourceSeverity,
        primaryPressureKind: PressureResourceKind,
        statusSummary: String,
        topAppsByCPU: [AggregatedAppProcess],
        topAppsByMemory: [AggregatedAppProcess],
        topBackgroundByCPU: [AggregatedAppProcess] = [],
        topBackgroundByMemory: [AggregatedAppProcess] = [],
        isDetailedSample: Bool,
        hasIncompleteProcessMetrics: Bool
    ) {
        self.timestampNs = timestampNs
        self.wallTime = wallTime
        self.cpuTotalPercent = cpuTotalPercent
        self.cpuUserPercent = cpuUserPercent
        self.cpuSystemPercent = cpuSystemPercent
        self.coreCount = coreCount
        self.memory = memory
        self.severity = severity
        self.primaryPressureKind = primaryPressureKind
        self.statusSummary = statusSummary
        self.topAppsByCPU = topAppsByCPU
        self.topAppsByMemory = topAppsByMemory
        self.topBackgroundByCPU = topBackgroundByCPU
        self.topBackgroundByMemory = topBackgroundByMemory
        self.isDetailedSample = isDetailedSample
        self.hasIncompleteProcessMetrics = hasIncompleteProcessMetrics
    }
}

/// Formatting utilities for compact, human-readable resource numbers without allocations.
public enum ByteFormatter {
    public static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 100.0 {
            return String(format: "%.0f MB", mb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.0f KB", kb)
    }

    public static func formatPercent(_ value: Double) -> String {
        if value >= 10.0 {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.1f%%", max(0.0, value))
    }
}
