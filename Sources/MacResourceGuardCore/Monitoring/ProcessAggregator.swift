import Foundation
import AppKit
import Darwin

/// Raw point-in-time record for a single OS process, used by both live Mach/libproc sampling
/// and deterministic unit tests.
public struct RawProcessRecord: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    public let startTimeSec: UInt64
    public let startTimeUsec: UInt64
    public let name: String
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let isGUIApplication: Bool
    public let cpuTimeTotalNs: UInt64
    public let physFootprintBytes: UInt64
    public let metricsComplete: Bool

    public init(
        pid: pid_t,
        ppid: pid_t,
        uid: uid_t,
        startTimeSec: UInt64,
        startTimeUsec: UInt64,
        name: String,
        bundleIdentifier: String?,
        executablePath: String?,
        isGUIApplication: Bool,
        cpuTimeTotalNs: UInt64,
        physFootprintBytes: UInt64,
        metricsComplete: Bool = true
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.isGUIApplication = isGUIApplication
        self.cpuTimeTotalNs = cpuTimeTotalNs
        self.physFootprintBytes = physFootprintBytes
        self.metricsComplete = metricsComplete
    }
}

/// Unique key for a process instance that prevents stale PID reuse mismatches across samples.
public struct ProcessInstanceKey: Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSec: UInt64
    public let startTimeUsec: UInt64

    public init(pid: pid_t, startTimeSec: UInt64, startTimeUsec: UInt64) {
        self.pid = pid
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
    }
}

/// Enumerates running processes on-demand using `libproc` (`proc_listallpids`, `proc_pidinfo`, `proc_pid_rusage`),
/// computes per-process CPU deltas normalized across cores, and groups child/helper processes under their parent application.
public final class ProcessAggregator {
    public let logicalCoreCount: Int
    private let machTimebase: mach_timebase_info_data_t

    /// Cached CPU cumulative nanoseconds from the previous sample, keyed by (pid, startTime)
    private var previousProcessCPUTimeNs: [ProcessInstanceKey: UInt64] = [:]
    private var previousSampleTimestampNs: UInt64?

    /// Cache of resolved executable paths by ProcessInstanceKey so we don't call proc_pidpath repeatedly
    private var executablePathCache: [ProcessInstanceKey: String] = [:]

    /// Cache of application icons keyed by executable/bundle path so icons are decoded at most once
    private var iconCacheByPath: [String: NSImage] = [:]

    public init(logicalCoreCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)) {
        self.logicalCoreCount = max(1, logicalCoreCount)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        if tb.denom == 0 {
            tb.numer = 1
            tb.denom = 1
        }
        self.machTimebase = tb
    }

    // MARK: - Pure Calculations (Unit-Testable)

    /// Converts Mach absolute time ticks from `rusage_info_v4` into true nanoseconds.
    public func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        if machTimebase.numer == machTimebase.denom {
            return ticks
        }
        let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(machTimebase.numer))
        if overflow {
            return (ticks / UInt64(machTimebase.denom)) * UInt64(machTimebase.numer)
        }
        return product / UInt64(machTimebase.denom)
    }

    /// Computes both normalized machine CPU share (0-100%) and single-core equivalent CPU percentage (0 - N*100%).
    public static func computeProcessCPUPercent(
        cpuDeltaNs: UInt64,
        elapsedNs: UInt64,
        logicalCoreCount: Int
    ) -> (machinePercent: Double, singleCorePercent: Double) {
        guard elapsedNs > 0, logicalCoreCount > 0 else {
            return (0.0, 0.0)
        }
        let rawSingleCore = (Double(cpuDeltaNs) / Double(elapsedNs)) * 100.0
        let maxSingleCore = Double(logicalCoreCount) * 100.0
        let clampedSingleCore = min(maxSingleCore, max(0.0, rawSingleCore))
        let machinePercent = min(100.0, max(0.0, clampedSingleCore / Double(logicalCoreCount)))
        return (machinePercent, clampedSingleCore)
    }

    /// Extracts the outermost `.app` bundle path from an executable path.
    /// Example: `/Applications/Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper`
    /// returns `/Applications/Google Chrome.app`.
    public static func outermostAppBundlePath(for executablePath: String?) -> String? {
        guard let path = executablePath, !path.isEmpty else { return nil }
        guard let range = path.range(of: ".app/") else {
            if path.hasSuffix(".app") {
                return path
            }
            return nil
        }
        return String(path[..<range.upperBound].dropLast()) // includes ".app"
    }

    /// Determines whether a process or application is part of macOS or Apple system infrastructure.
    public static func isMacOSOrSystemProcess(
        name: String,
        bundleIdentifier: String?,
        executablePath: String?,
        uid: uid_t
    ) -> Bool {
        if uid != getuid() {
            return true
        }
        if let bundleID = bundleIdentifier?.lowercased(), bundleID.hasPrefix("com.apple.") {
            return true
        }
        let lowerName = name.lowercased()
        if lowerName.hasPrefix("com.apple.") {
            return true
        }
        let macOSBuiltInNames: Set<String> = [
            "System Settings", "Paramètres Système", "Réglages Système",
            "Activity Monitor", "Moniteur d’activité", "Finder", "Safari",
            "Siri", "Spotlight", "Dock", "WindowServer", "ControlCenter",
            "SystemUIServer", "NotificationCenter", "Preview", "Aperçu",
            "QuickTime Player", "Terminal", "Console", "Keychain Access",
            "fileproviderd", "zsh", "bash", "sh", "login", "launchd",
            "mds_stores", "cloudd", "bird", "nsurlsessiond", "trustd",
            "apsd", "cfprefsd", "distnoted", "secinitd", "tccd",
            "corespotlightd", "lsd", "iconservicesagent", "pbs",
            "WallpaperAgent", "WiFiAgent", "BluetoothUIServer"
        ]
        if macOSBuiltInNames.contains(name) {
            return true
        }
        if let path = executablePath {
            if path.hasPrefix("/System/") ||
               path.hasPrefix("/usr/") ||
               path.hasPrefix("/bin/") ||
               path.hasPrefix("/sbin/") ||
               path.hasPrefix("/Library/Apple/") ||
               path.hasPrefix("/Volumes/Preboot/Cryptexes/") {
                return true
            }
        }
        return false
    }

    // MARK: - Live Sampling Entry Point

    public struct AggregationOutput {
        public var topByCPU: [AggregatedAppProcess]
        public var topByMemory: [AggregatedAppProcess]
        public var topBackgroundByCPU: [AggregatedAppProcess]
        public var topBackgroundByMemory: [AggregatedAppProcess]
        public var hasIncompleteMetrics: Bool
    }

    /// Captures a live process snapshot, updates CPU deltas, aggregates helper processes,
    /// and returns both the top user applications and top background processes sorted by CPU and Memory.
    public func sampleTopApplications(
        topCount: Int = 15
    ) -> AggregationOutput {
        return autoreleasepool {
            let nowNs = SystemMetricsSampler.monotonicNanoseconds()
            let rawRecords = captureLiveProcessRecords()

            let elapsedNs: UInt64
            if let prevNs = previousSampleTimestampNs, nowNs > prevNs {
                elapsedNs = nowNs - prevNs
            } else {
                elapsedNs = 0
            }

            var result = Self.aggregateProcesses(
                records: rawRecords,
                previousCPUTimeByKey: previousProcessCPUTimeNs,
                elapsedNs: elapsedNs,
                logicalCoreCount: logicalCoreCount,
                iconsByPID: [:],
                topCount: topCount
            )

            // Lazily resolve & cache icons ONLY for the final Top 3 lists
            result.topByCPU = result.topByCPU.map { attachCachedIcon(to: $0) }
            result.topByMemory = result.topByMemory.map { attachCachedIcon(to: $0) }
            result.topBackgroundByCPU = result.topBackgroundByCPU.map { attachCachedIcon(to: $0) }
            result.topBackgroundByMemory = result.topBackgroundByMemory.map { attachCachedIcon(to: $0) }

            // Update state for next delta calculation and prune exited processes
            var nextCPUMap: [ProcessInstanceKey: UInt64] = [:]
            nextCPUMap.reserveCapacity(rawRecords.count)
            var liveKeys = Set<ProcessInstanceKey>()
            liveKeys.reserveCapacity(rawRecords.count)

            for rec in rawRecords {
                let key = ProcessInstanceKey(pid: rec.pid, startTimeSec: rec.startTimeSec, startTimeUsec: rec.startTimeUsec)
                nextCPUMap[key] = rec.cpuTimeTotalNs
                liveKeys.insert(key)
            }
            self.previousProcessCPUTimeNs = nextCPUMap
            self.previousSampleTimestampNs = nowNs

            // Keep path cache bounded to live processes only
            self.executablePathCache = self.executablePathCache.filter { liveKeys.contains($0.key) }

            return result
        }
    }

    private func attachCachedIcon(to app: AggregatedAppProcess) -> AggregatedAppProcess {
        if app.icon != nil { return app }
        let cacheKey = Self.outermostAppBundlePath(for: app.executablePath) ?? app.bundleIdentifier ?? "\(app.id)"
        let resolvedIcon: NSImage?
        if let cached = iconCacheByPath[cacheKey] {
            resolvedIcon = cached
        } else if let runningIcon = NSRunningApplication(processIdentifier: app.id)?.icon {
            iconCacheByPath[cacheKey] = runningIcon
            resolvedIcon = runningIcon
        } else if let bundlePath = Self.outermostAppBundlePath(for: app.executablePath) {
            let fileIcon = NSWorkspace.shared.icon(forFile: bundlePath)
            iconCacheByPath[cacheKey] = fileIcon
            resolvedIcon = fileIcon
        } else if let execPath = app.executablePath, FileManager.default.fileExists(atPath: execPath) {
            let fileIcon = NSWorkspace.shared.icon(forFile: execPath)
            iconCacheByPath[cacheKey] = fileIcon
            resolvedIcon = fileIcon
        } else {
            resolvedIcon = nil
        }

        return AggregatedAppProcess(
            id: app.id,
            startTimeSec: app.startTimeSec,
            startTimeUsec: app.startTimeUsec,
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            executablePath: app.executablePath,
            icon: resolvedIcon,
            cpuPercentMachine: app.cpuPercentMachine,
            cpuPercentSingleCoreEquivalent: app.cpuPercentSingleCoreEquivalent,
            memoryFootprintBytes: app.memoryFootprintBytes,
            helperProcessCount: app.helperProcessCount,
            groupedPIDs: app.groupedPIDs,
            isProtectedSystemApp: app.isProtectedSystemApp,
            protectionReason: app.protectionReason,
            hasIncompleteMetrics: app.hasIncompleteMetrics,
            isBackgroundProcess: app.isBackgroundProcess,
            isMacOSSystemRelated: app.isMacOSSystemRelated
        )
    }

    /// Primes the baseline process CPU map so a subsequent sample 1-2 seconds later has accurate deltas.
    public func primeBaseline() {
        autoreleasepool {
            let nowNs = SystemMetricsSampler.monotonicNanoseconds()
            let raw = captureLiveProcessRecords()
            var nextCPUMap: [ProcessInstanceKey: UInt64] = [:]
            nextCPUMap.reserveCapacity(raw.count)
            for rec in raw {
                let key = ProcessInstanceKey(pid: rec.pid, startTimeSec: rec.startTimeSec, startTimeUsec: rec.startTimeUsec)
                nextCPUMap[key] = rec.cpuTimeTotalNs
            }
            self.previousProcessCPUTimeNs = nextCPUMap
            self.previousSampleTimestampNs = nowNs
        }
    }

    // MARK: - Aggregation Engine (Pure & Deterministic)

    public static func aggregateProcesses(
        records: [RawProcessRecord],
        previousCPUTimeByKey: [ProcessInstanceKey: UInt64],
        elapsedNs: UInt64,
        logicalCoreCount: Int,
        iconsByPID: [pid_t: NSImage] = [:],
        topCount: Int = 3
    ) -> AggregationOutput {
        // 1. Deduplicate input records by PID to guarantee zero double counting
        var uniqueRecordsByPID: [pid_t: RawProcessRecord] = [:]
        uniqueRecordsByPID.reserveCapacity(records.count)
        for record in records where record.pid > 0 {
            if uniqueRecordsByPID[record.pid] == nil {
                uniqueRecordsByPID[record.pid] = record
            }
        }

        // 2a. Identify Regular GUI Root Applications (`isGUIApplication == true`, i.e. Dock apps)
        var regularRootPIDs = Set<pid_t>()
        var rootPIDs = Set<pid_t>()
        var rootPIDByAppBundlePath: [String: pid_t] = [:]
        var rootPIDByBundleID: [String: pid_t] = [:]

        for (pid, rec) in uniqueRecordsByPID {
            let outerApp = outermostAppBundlePath(for: rec.executablePath)
            let isNestedHelperPath = rec.executablePath?.contains(".app/Contents/Frameworks/") == true ||
                                     rec.executablePath?.contains(".app/Contents/Helpers/") == true ||
                                     rec.executablePath?.contains(".app/Contents/Library/LoginItems/") == true ||
                                     rec.executablePath?.contains(".app/Contents/XPCServices/") == true

            if rec.isGUIApplication && !isNestedHelperPath {
                regularRootPIDs.insert(pid)
                rootPIDs.insert(pid)
                if let outerApp = outerApp {
                    rootPIDByAppBundlePath[outerApp] = pid
                }
                if let bundleID = rec.bundleIdentifier, !bundleID.isEmpty {
                    rootPIDByBundleID[bundleID] = pid
                }
            }
        }

        // 2b. Identify Background `.app` Bundle Roots (e.g. SetappAgent, menu bar agents, background helpers)
        //     so their child processes are grouped cleanly under the background agent!
        for (pid, rec) in uniqueRecordsByPID where !rootPIDs.contains(pid) {
            guard let outerApp = outermostAppBundlePath(for: rec.executablePath) else { continue }
            let isMainMacOSBinary = rec.executablePath?.hasPrefix(outerApp + "/Contents/MacOS/") == true &&
                                    rec.executablePath?.contains(".app/Contents/Frameworks/") == false &&
                                    rec.executablePath?.contains(".app/Contents/Helpers/") == false
            if isMainMacOSBinary && rootPIDByAppBundlePath[outerApp] == nil {
                rootPIDs.insert(pid)
                rootPIDByAppBundlePath[outerApp] = pid
                if let bundleID = rec.bundleIdentifier, !bundleID.isEmpty, rootPIDByBundleID[bundleID] == nil {
                    rootPIDByBundleID[bundleID] = pid
                }
            }
        }

        // 3. Resolve parent/root group for every process
        func resolveRootPID(for record: RawProcessRecord) -> pid_t {
            if rootPIDs.contains(record.pid) {
                return record.pid
            }

            // Strategy A: Walk PPID ancestry chain up to 10 hops
            var currentPPID = record.ppid
            var visitedChain = Set<pid_t>([record.pid])
            var topMostBackgroundAncestor: pid_t? = nil
            var depth = 0
            while currentPPID > 1 && depth < 10 && !visitedChain.contains(currentPPID) {
                if rootPIDs.contains(currentPPID) {
                    return currentPPID
                }
                visitedChain.insert(currentPPID)
                if let parentRecord = uniqueRecordsByPID[currentPPID] {
                    topMostBackgroundAncestor = parentRecord.pid
                    currentPPID = parentRecord.ppid
                } else {
                    break
                }
                depth += 1
            }

            // Strategy B: Outermost `.app` bundle containment
            // (e.g., `/Applications/Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper`)
            if let outerApp = outermostAppBundlePath(for: record.executablePath),
               let matchingRootPID = rootPIDByAppBundlePath[outerApp] {
                return matchingRootPID
            }

            // Strategy C: Verified Bundle Identifier prefix match
            // (e.g., `com.google.Chrome.helper` -> `com.google.Chrome`, `com.microsoft.VSCode.helper` -> `com.microsoft.VSCode`)
            if let bundleID = record.bundleIdentifier, !bundleID.isEmpty {
                for (rootBundleID, rootPID) in rootPIDByBundleID {
                    if bundleID != rootBundleID && bundleID.hasPrefix(rootBundleID + ".") {
                        return rootPID
                    }
                }

                // Special case for Safari's out-of-process WebKit XPC services when Safari is running
                if (bundleID.hasPrefix("com.apple.WebKit.") || bundleID.hasPrefix("com.apple.Safari.")),
                   let safariPID = rootPIDByBundleID["com.apple.Safari"] {
                    return safariPID
                }
            }

            // Strategy D: If this is a child of a background agent tree (e.g. SetappAgent -> SetappUpdateHelper),
            // group it under the root background agent of that tree.
            if let bgAncestor = topMostBackgroundAncestor {
                return bgAncestor
            }

            // Otherwise, this process stands on its own
            return record.pid
        }

        // 4. Accumulate CPU deltas and Memory footprints per group without double-counting
        struct GroupAccumulator {
            var rootRecord: RawProcessRecord
            var totalCPUDeltaNs: UInt64 = 0
            var totalMemoryBytes: UInt64 = 0
            var helperCount: Int = 0
            var groupedPIDs: [pid_t] = []
            var hasIncomplete: Bool = false
        }

        var groups: [pid_t: GroupAccumulator] = [:]
        var anyIncompleteMetrics = false

        for (_, record) in uniqueRecordsByPID {
            let groupRootPID = resolveRootPID(for: record)
            let rootRec = uniqueRecordsByPID[groupRootPID] ?? record

            let key = ProcessInstanceKey(
                pid: record.pid,
                startTimeSec: record.startTimeSec,
                startTimeUsec: record.startTimeUsec
            )
            let cpuDeltaNs: UInt64
            if elapsedNs > 0, let prevCPU = previousCPUTimeByKey[key], record.cpuTimeTotalNs >= prevCPU {
                cpuDeltaNs = record.cpuTimeTotalNs - prevCPU
            } else {
                cpuDeltaNs = 0
            }

            if !record.metricsComplete {
                anyIncompleteMetrics = true
            }

            if var existing = groups[groupRootPID] {
                existing.totalCPUDeltaNs += cpuDeltaNs
                existing.totalMemoryBytes += record.physFootprintBytes
                if record.pid != groupRootPID {
                    existing.helperCount += 1
                }
                existing.groupedPIDs.append(record.pid)
                if !record.metricsComplete {
                    existing.hasIncomplete = true
                }
                groups[groupRootPID] = existing
            } else {
                groups[groupRootPID] = GroupAccumulator(
                    rootRecord: rootRec,
                    totalCPUDeltaNs: cpuDeltaNs,
                    totalMemoryBytes: record.physFootprintBytes,
                    helperCount: record.pid == groupRootPID ? 0 : 1,
                    groupedPIDs: [record.pid],
                    hasIncomplete: !record.metricsComplete
                )
            }
        }

        // 5. Convert accumulators into Regular Apps and Background Processes
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var regularAppsList: [AggregatedAppProcess] = []
        var backgroundProcessesList: [AggregatedAppProcess] = []
        regularAppsList.reserveCapacity(groups.count)
        backgroundProcessesList.reserveCapacity(groups.count)

        for (rootPID, group) in groups {
            if rootPID == selfPID {
                continue
            }

            let rec = group.rootRecord
            let cpuPercents = computeProcessCPUPercent(
                cpuDeltaNs: group.totalCPUDeltaNs,
                elapsedNs: elapsedNs,
                logicalCoreCount: logicalCoreCount
            )
            let isRegularUserApp = regularRootPIDs.contains(rootPID) || rec.isGUIApplication

            let protection = SafeAppTerminator.evaluateProtection(
                pid: rec.pid,
                uid: rec.uid,
                bundleIdentifier: rec.bundleIdentifier,
                processName: rec.name,
                executablePath: rec.executablePath
            )

            if !isRegularUserApp {
                // For the Background list, filter out protected OS processes and negligible idle daemons (< 10 MB and < 0.2% CPU)
                // so the Top 3 Background view focuses on actionable wasted background resources.
                if protection.isProtected {
                    continue
                }
                if cpuPercents.machinePercent < 0.2 && group.totalMemoryBytes < 10 * 1024 * 1024 {
                    continue
                }
            }

            let isMacOSRelated = isMacOSOrSystemProcess(
                name: rec.name,
                bundleIdentifier: rec.bundleIdentifier,
                executablePath: rec.executablePath,
                uid: rec.uid
            )

            let appProcess = AggregatedAppProcess(
                id: rec.pid,
                startTimeSec: rec.startTimeSec,
                startTimeUsec: rec.startTimeUsec,
                bundleIdentifier: rec.bundleIdentifier,
                displayName: rec.name,
                executablePath: rec.executablePath,
                icon: iconsByPID[rec.pid],
                cpuPercentMachine: cpuPercents.machinePercent,
                cpuPercentSingleCoreEquivalent: cpuPercents.singleCorePercent,
                memoryFootprintBytes: group.totalMemoryBytes,
                helperProcessCount: group.helperCount,
                groupedPIDs: group.groupedPIDs.sorted(),
                isProtectedSystemApp: protection.isProtected,
                protectionReason: protection.reason,
                hasIncompleteMetrics: group.hasIncomplete,
                isBackgroundProcess: !isRegularUserApp,
                isMacOSSystemRelated: isMacOSRelated
            )

            if isRegularUserApp {
                regularAppsList.append(appProcess)
            } else {
                backgroundProcessesList.append(appProcess)
            }
        }

        func sortByCPU(_ list: [AggregatedAppProcess]) -> [AggregatedAppProcess] {
            Array(
                list.sorted { lhs, rhs in
                    if abs(lhs.cpuPercentMachine - rhs.cpuPercentMachine) > 0.05 {
                        return lhs.cpuPercentMachine > rhs.cpuPercentMachine
                    }
                    return lhs.memoryFootprintBytes > rhs.memoryFootprintBytes
                }
                .prefix(topCount)
            )
        }

        func sortByMemory(_ list: [AggregatedAppProcess]) -> [AggregatedAppProcess] {
            Array(
                list.sorted { lhs, rhs in
                    if lhs.memoryFootprintBytes != rhs.memoryFootprintBytes {
                        return lhs.memoryFootprintBytes > rhs.memoryFootprintBytes
                    }
                    return lhs.cpuPercentMachine > rhs.cpuPercentMachine
                }
                .prefix(topCount)
            )
        }

        return AggregationOutput(
            topByCPU: sortByCPU(regularAppsList),
            topByMemory: sortByMemory(regularAppsList),
            topBackgroundByCPU: sortByCPU(backgroundProcessesList),
            topBackgroundByMemory: sortByMemory(backgroundProcessesList),
            hasIncompleteMetrics: anyIncompleteMetrics
        )
    }

    // MARK: - Low-Level Darwin Process Capture

    private func captureLiveProcessRecords() -> [RawProcessRecord] {
        // 1. Snapshot NSWorkspace.shared.runningApplications for metadata (without decoding icons!)
        let runningApps = NSWorkspace.shared.runningApplications
        struct AppMeta {
            let localizedName: String?
            let bundleIdentifier: String?
            let executablePath: String?
            let isGUI: Bool
        }
        var appMetaByPID: [pid_t: AppMeta] = [:]
        appMetaByPID.reserveCapacity(runningApps.count)

        for app in runningApps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let isGUI = (app.activationPolicy == .regular)
            appMetaByPID[pid] = AppMeta(
                localizedName: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                executablePath: app.executableURL?.path ?? app.bundleURL?.path,
                isGUI: isGUI
            )
        }

        // 2. Enumerate active PIDs via proc_listallpids
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else {
            return []
        }

        let capacity = Int(estimatedCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualBytesOrCount = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(capacity * MemoryLayout<pid_t>.stride))
        }
        guard actualBytesOrCount > 0 else {
            return []
        }

        let pidCount = min(capacity, Int(actualBytesOrCount))
        var records: [RawProcessRecord] = []
        records.reserveCapacity(pidCount)

        let currentUID = getuid()
        let bsdInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)

        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var bsdInfo = proc_bsdinfo()
            let readBytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdInfoSize)
            guard readBytes == bsdInfoSize else { continue }

            let meta = appMetaByPID[pid]
            // Skip unrelated root processes that aren't GUI apps to keep sampling ultra-fast and avoid EPERM noise
            if bsdInfo.pbi_uid != currentUID && meta == nil {
                continue
            }

            let key = ProcessInstanceKey(
                pid: pid,
                startTimeSec: bsdInfo.pbi_start_tvsec,
                startTimeUsec: bsdInfo.pbi_start_tvusec
            )

            // Resolve process executable path (cached per ProcessInstanceKey)
            let execPath: String?
            if let metaPath = meta?.executablePath {
                execPath = metaPath
            } else if let cachedPath = executablePathCache[key] {
                execPath = cachedPath
            } else {
                var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
                if pathLen > 0 {
                    let resolved = String(cString: pathBuffer)
                    executablePathCache[key] = resolved
                    execPath = resolved
                } else {
                    execPath = nil
                }
            }

            // Resolve display name
            let displayName: String
            if let locName = meta?.localizedName, !locName.isEmpty {
                displayName = locName
            } else {
                let rawName = withUnsafePointer(to: bsdInfo.pbi_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if !rawName.isEmpty {
                    displayName = rawName
                } else {
                    displayName = withUnsafePointer(to: bsdInfo.pbi_comm) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                            String(cString: cStr)
                        }
                    }
                }
            }

            // Read CPU time and physical memory footprint via proc_pid_rusage(RUSAGE_INFO_V4)
            var rusage = rusage_info_v4()
            let rusageResult = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
                }
            }

            let cpuTotalNs: UInt64
            let physFootprint: UInt64
            let metricsComplete: Bool

            if rusageResult == 0 {
                let totalTicks = rusage.ri_user_time &+ rusage.ri_system_time
                cpuTotalNs = machTicksToNanoseconds(totalTicks)
                physFootprint = rusage.ri_phys_footprint
                metricsComplete = true
            } else {
                cpuTotalNs = 0
                physFootprint = 0
                metricsComplete = false
            }

            let record = RawProcessRecord(
                pid: pid,
                ppid: Int32(bsdInfo.pbi_ppid),
                uid: bsdInfo.pbi_uid,
                startTimeSec: bsdInfo.pbi_start_tvsec,
                startTimeUsec: bsdInfo.pbi_start_tvusec,
                name: displayName,
                bundleIdentifier: meta?.bundleIdentifier,
                executablePath: execPath,
                isGUIApplication: meta?.isGUI ?? false,
                cpuTimeTotalNs: cpuTotalNs,
                physFootprintBytes: physFootprint,
                metricsComplete: metricsComplete
            )
            records.append(record)
        }

        return records
    }
}
