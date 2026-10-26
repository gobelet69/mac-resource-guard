import Foundation
import Darwin

/// Low-overhead system-wide CPU and Memory-Pressure sampler using Mach host traps and sysctl.
/// Does NOT enumerate processes or invoke external shell utilities (`top`, `ps`, `vm_stat`).
public final class SystemMetricsSampler {
    public let totalPhysicalMemoryBytes: UInt64
    public let logicalCoreCount: Int
    public let pageSizeBytes: UInt64

    private var previousCPUTicks: CPUTicksSample?
    private var previousSwapOutsPages: UInt64?
    private var previousSampleTimestampNs: UInt64?

    private var dispatchMemoryPressureLevel: MemoryPressureLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Optional callback invoked immediately when the kernel dispatches a memory-pressure event.
    public var onKernelMemoryPressureChange: ((MemoryPressureLevel) -> Void)?

    public init() {
        self.totalPhysicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        self.logicalCoreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        self.pageSizeBytes = UInt64(vm_kernel_page_size)

        // Prime initial baseline so the very first subsequent sample has a valid delta
        self.previousCPUTicks = Self.readHostCPUTicks()
        if let vmStat = Self.readHostVMStatistics() {
            self.previousSwapOutsPages = vmStat.swapouts
        }
        self.previousSampleTimestampNs = Self.monotonicNanoseconds()
    }

    deinit {
        stopMemoryPressureListener()
    }

    // MARK: - Monotonic Clock

    /// Returns monotonic uptime in nanoseconds (`CLOCK_UPTIME_RAW`), unaffected by wall-clock adjustments.
    public static func monotonicNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    // MARK: - DispatchSource Memory Pressure Listener

    public func startMemoryPressureListener(on queue: DispatchQueue) {
        stopMemoryPressureListener()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source = source else { return }
            let event = source.data
            let newLevel: MemoryPressureLevel
            if event.contains(.critical) {
                newLevel = .critical
            } else if event.contains(.warning) {
                newLevel = .elevated
            } else {
                newLevel = .normal
            }
            if self.dispatchMemoryPressureLevel != newLevel {
                self.dispatchMemoryPressureLevel = newLevel
                self.onKernelMemoryPressureChange?(newLevel)
            }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    public func stopMemoryPressureListener() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Inexpensive System-Wide Sampling

    public struct SystemWideSample {
        public let timestampNs: UInt64
        public let cpuTotalPercent: Double
        public let cpuUserPercent: Double
        public let cpuSystemPercent: Double
        public let memory: MemoryMetrics
    }

    /// Samples system-wide CPU and memory metrics in a few microseconds using Mach traps and sysctl.
    public func sampleSystemWide() -> SystemWideSample {
        let nowNs = Self.monotonicNanoseconds()
        let elapsedSeconds: Double
        if let prevNs = previousSampleTimestampNs, nowNs > prevNs {
            elapsedSeconds = Double(nowNs - prevNs) / 1_000_000_000.0
        } else {
            elapsedSeconds = 1.0
        }
        previousSampleTimestampNs = nowNs

        // 1. CPU Load via HOST_CPU_LOAD_INFO
        let currentTicks = Self.readHostCPUTicks()
        let cpuUsage: (totalPercent: Double, userPercent: Double, systemPercent: Double)
        if let prevTicks = previousCPUTicks {
            cpuUsage = CPUTicksSample.calculateUsage(previous: prevTicks, current: currentTicks)
        } else {
            cpuUsage = (0.0, 0.0, 0.0)
        }
        previousCPUTicks = currentTicks

        // 2. Mach VM Info via HOST_VM_INFO64
        let vmStat = Self.readHostVMStatistics()
        let pSize = pageSizeBytes

        let freeBytes = UInt64(vmStat?.free_count ?? 0) * pSize
        let inactiveBytes = UInt64(vmStat?.inactive_count ?? 0) * pSize
        let wireBytes = UInt64(vmStat?.wire_count ?? 0) * pSize
        let compressedBytes = UInt64(vmStat?.compressor_page_count ?? 0) * pSize
        let internalBytes = UInt64(vmStat?.internal_page_count ?? 0) * pSize
        let purgeableBytes = UInt64(vmStat?.purgeable_count ?? 0) * pSize
        let externalBytes = UInt64(vmStat?.external_page_count ?? 0) * pSize

        // App Memory = anonymous internal pages minus purgeable pages
        let appMemoryBytes = internalBytes > purgeableBytes ? (internalBytes - purgeableBytes) : internalBytes
        // Cached Files = file-backed external pages + purgeable pages (reclaimable without swapping!)
        let cachedFilesBytes = externalBytes + purgeableBytes
        // Available Memory = free + inactive + purgeable + external
        let rawAvailable = freeBytes + inactiveBytes + externalBytes + purgeableBytes
        let availableBytes = min(totalPhysicalMemoryBytes, rawAvailable)

        let currentSwapOuts = vmStat?.swapouts ?? 0
        let swapOutsDelta: UInt64
        if let prevSwapOuts = previousSwapOutsPages, currentSwapOuts >= prevSwapOuts {
            swapOutsDelta = currentSwapOuts - prevSwapOuts
        } else {
            swapOutsDelta = 0
        }
        previousSwapOutsPages = currentSwapOuts

        let swapRateBytesPerSec = (Double(swapOutsDelta * pSize)) / max(0.1, elapsedSeconds)

        // 3. Swap Usage via sysctl("vm.swapusage")
        let swapInfo = Self.readSwapUsage()

        // 4. Kernel Memory Pressure Level via sysctl("kern.memorystatus_vm_pressure_level")
        let kernelPressureRaw = Self.readKernelMemoryPressureLevel()

        let evaluatedPressure = MemoryMetrics.evaluatePressureLevel(
            totalPhysicalBytes: totalPhysicalMemoryBytes,
            availableBytes: availableBytes,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapInfo.used,
            swapRateBytesPerSec: swapRateBytesPerSec,
            kernelPressureRawLevel: kernelPressureRaw,
            dispatchPressureLevel: dispatchMemoryPressureLevel
        )

        let memoryMetrics = MemoryMetrics(
            totalPhysicalBytes: totalPhysicalMemoryBytes,
            appMemoryBytes: appMemoryBytes,
            wiredBytes: wireBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            availableBytes: availableBytes,
            swapUsedBytes: swapInfo.used,
            swapTotalBytes: swapInfo.total,
            swapOutsDeltaPages: swapOutsDelta,
            swapRateBytesPerSec: swapRateBytesPerSec,
            kernelPressureRawLevel: kernelPressureRaw,
            dispatchPressureLevel: dispatchMemoryPressureLevel,
            pressureLevel: evaluatedPressure
        )

        return SystemWideSample(
            timestampNs: nowNs,
            cpuTotalPercent: cpuUsage.totalPercent,
            cpuUserPercent: cpuUsage.userPercent,
            cpuSystemPercent: cpuUsage.systemPercent,
            memory: memoryMetrics
        )
    }

    // MARK: - Low-Level Mach & Sysctl Readers

    public static func readHostCPUTicks() -> CPUTicksSample {
        var cpuLoadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kerr = withUnsafeMutablePointer(to: &cpuLoadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else {
            return CPUTicksSample(user: 0, system: 0, idle: 0, nice: 0)
        }
        return CPUTicksSample(
            user: UInt64(cpuLoadInfo.cpu_ticks.0),
            system: UInt64(cpuLoadInfo.cpu_ticks.1),
            idle: UInt64(cpuLoadInfo.cpu_ticks.2),
            nice: UInt64(cpuLoadInfo.cpu_ticks.3)
        )
    }

    public static func readHostVMStatistics() -> vm_statistics64_data_t? {
        var vmStat = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kerr = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return vmStat
    }

    public static func readSwapUsage() -> (total: UInt64, used: UInt64, free: UInt64) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let res = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard res == 0 else {
            return (0, 0, 0)
        }
        return (swap.xsu_total, swap.xsu_used, swap.xsu_avail)
    }

    public static func readKernelMemoryPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        let res = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard res == 0 else { return 1 }
        return level
    }
}
