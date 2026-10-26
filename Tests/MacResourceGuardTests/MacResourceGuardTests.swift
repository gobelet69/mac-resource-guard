import XCTest
#if canImport(MacResourceGuardCore)
@testable import MacResourceGuardCore
#else
@testable import MacResourceGuard
#endif

final class MacResourceGuardTests: XCTestCase {

    // MARK: - 1. CPU Percentage Calculations & Multicore Normalization

    func testSystemWideCPUTicksCalculation() {
        let prev = CPUTicksSample(user: 1_000, system: 500, idle: 2_500, nice: 0)
        // Delta across 8 cores: user +600, system +200, idle +200 -> active = 800, total = 1000 -> 80% total
        let curr = CPUTicksSample(user: 1_600, system: 700, idle: 2_700, nice: 0)

        let usage = CPUTicksSample.calculateUsage(previous: prev, current: curr)
        XCTAssertEqual(usage.totalPercent, 80.0, accuracy: 0.001)
        XCTAssertEqual(usage.userPercent, 60.0, accuracy: 0.001)
        XCTAssertEqual(usage.systemPercent, 20.0, accuracy: 0.001)
    }

    func testSystemWideCPUZeroDeltaReturnsZero() {
        let sample = CPUTicksSample(user: 500, system: 200, idle: 900, nice: 10)
        let usage = CPUTicksSample.calculateUsage(previous: sample, current: sample)
        XCTAssertEqual(usage.totalPercent, 0.0)
        XCTAssertEqual(usage.userPercent, 0.0)
        XCTAssertEqual(usage.systemPercent, 0.0)
    }

    func testMulticoreProcessCPUNormalization() {
        let eightCores = 8
        let elapsedNs: UInt64 = 2_000_000_000 // 2.0 seconds

        // 1 full core used for 2.0 seconds = 2_000_000_000 ns of CPU time
        // Single-core equivalent = 100%, 8-core machine share = 12.5%
        let oneCore = ProcessAggregator.computeProcessCPUPercent(
            cpuDeltaNs: 2_000_000_000,
            elapsedNs: elapsedNs,
            logicalCoreCount: eightCores
        )
        XCTAssertEqual(oneCore.singleCorePercent, 100.0, accuracy: 0.01)
        XCTAssertEqual(oneCore.machinePercent, 12.5, accuracy: 0.01)

        // 6 full cores used for 2.0 seconds = 12_000_000_000 ns of CPU time
        // Single-core equivalent = 600%, 8-core machine share = 75.0%
        let sixCores = ProcessAggregator.computeProcessCPUPercent(
            cpuDeltaNs: 12_000_000_000,
            elapsedNs: elapsedNs,
            logicalCoreCount: eightCores
        )
        XCTAssertEqual(sixCores.singleCorePercent, 600.0, accuracy: 0.01)
        XCTAssertEqual(sixCores.machinePercent, 75.0, accuracy: 0.01)
    }

    // MARK: - 2. Intelligent Memory-Pressure State Handling

    func testHighFileCacheDoesNotTriggerFalseMemoryPressure() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        // Simulate 92% of physical RAM in use, but 3.5 GB of it is reclaimable file cache + free pages!
        let availableWithCache: UInt64 = UInt64(3.5 * 1024 * 1024 * 1024)
        let compressed: UInt64 = 400 * 1024 * 1024

        let level = MemoryMetrics.evaluatePressureLevel(
            totalPhysicalBytes: eightGB,
            availableBytes: availableWithCache,
            compressedBytes: compressed,
            swapUsedBytes: 0,
            swapRateBytesPerSec: 0,
            kernelPressureRawLevel: 1,
            dispatchPressureLevel: .normal
        )
        XCTAssertEqual(level, .normal, "High cached RAM must be treated as Healthy, not memory pressure")
    }

    func testElevatedAndCriticalMemoryPressureDetection() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024

        // Kernel warning signal -> .elevated
        let elevatedFromKernel = MemoryMetrics.evaluatePressureLevel(
            totalPhysicalBytes: eightGB,
            availableBytes: 1024 * 1024 * 1024,
            compressedBytes: 1024 * 1024 * 1024,
            swapUsedBytes: 256 * 1024 * 1024,
            swapRateBytesPerSec: 0,
            kernelPressureRawLevel: 2,
            dispatchPressureLevel: .normal
        )
        XCTAssertEqual(elevatedFromKernel, .elevated)

        // Kernel critical signal -> .critical
        let criticalFromKernel = MemoryMetrics.evaluatePressureLevel(
            totalPhysicalBytes: eightGB,
            availableBytes: 200 * 1024 * 1024,
            compressedBytes: 3 * 1024 * 1024 * 1024,
            swapUsedBytes: 2 * 1024 * 1024 * 1024,
            swapRateBytesPerSec: 32 * 1024 * 1024,
            kernelPressureRawLevel: 4,
            dispatchPressureLevel: .critical
        )
        XCTAssertEqual(criticalFromKernel, .critical)

        // Supporting Mach VM heuristic: < 5% available, > 40% compressed, and >= 20 MB/s swap thrashing
        let criticalFromThrashing = MemoryMetrics.evaluatePressureLevel(
            totalPhysicalBytes: eightGB,
            availableBytes: 300 * 1024 * 1024,
            compressedBytes: 3600 * 1024 * 1024,
            swapUsedBytes: 1500 * 1024 * 1024,
            swapRateBytesPerSec: 25 * 1024 * 1024,
            kernelPressureRawLevel: 1,
            dispatchPressureLevel: .normal
        )
        XCTAssertEqual(criticalFromThrashing, .critical)
    }

    // MARK: - 3. Threshold Detection, Short Bursts, Hysteresis, and Cooldown

    func testShortCPUBurstDoesNotTriggerAlert() {
        let sm = AlertStateMachine()
        let config = AlertConfiguration(
            cpuWarningThresholdPercent: 85.0,
            cpuSustainedDurationSeconds: 25.0,
            cpuHysteresisMarginPercent: 10.0,
            cooldownSeconds: 300.0
        )

        let t0: UInt64 = 10_000_000_000
        // Spike to 92% at t=0 -> enters confirming
        let step1 = sm.evaluate(
            timestampNs: t0,
            cpuPercent: 92.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [] },
            topAppsByMemory: { [] }
        )
        XCTAssertNil(step1.triggeredAlert)
        XCTAssertTrue(sm.isConfirmingThresholdPersistence)

        // Still 90% at t + 15s (below 25s requirement) -> no alert yet
        let step2 = sm.evaluate(
            timestampNs: t0 + 15_000_000_000,
            cpuPercent: 90.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [] },
            topAppsByMemory: { [] }
        )
        XCTAssertNil(step2.triggeredAlert)

        // Drops to 40% at t + 18s (short startup burst ended) -> returns to normal without alerting
        let step3 = sm.evaluate(
            timestampNs: t0 + 18_000_000_000,
            cpuPercent: 40.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [] },
            topAppsByMemory: { [] }
        )
        XCTAssertNil(step3.triggeredAlert)
        XCTAssertFalse(sm.isConfirmingThresholdPersistence)
        XCTAssertEqual(sm.cpuState, .normal)
    }

    func testSustainedCPUTriggersAlertHysteresisAndCooldown() {
        let sm = AlertStateMachine()
        let config = AlertConfiguration(
            cpuWarningThresholdPercent: 85.0,
            cpuSustainedDurationSeconds: 25.0,
            cpuHysteresisMarginPercent: 10.0, // Recovery requires <= 75.0%
            cooldownSeconds: 300.0
        )

        let dummyApp = AggregatedAppProcess(
            id: 4001,
            startTimeSec: 100,
            startTimeUsec: 0,
            bundleIdentifier: "com.google.Chrome",
            displayName: "Google Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            cpuPercentMachine: 68.5,
            cpuPercentSingleCoreEquivalent: 548.0,
            memoryFootprintBytes: 1_500_000_000,
            helperProcessCount: 12,
            groupedPIDs: [4001, 4002],
            isProtectedSystemApp: false
        )

        let t0: UInt64 = 1_000_000_000
        _ = sm.evaluate(
            timestampNs: t0,
            cpuPercent: 88.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )

        // At t0 + 26s (exceeds 25s sustained window) -> Alert MUST fire!
        let tAlert = t0 + 26_000_000_000
        let fired = sm.evaluate(
            timestampNs: tAlert,
            cpuPercent: 91.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        XCTAssertNotNil(fired.triggeredAlert)
        XCTAssertEqual(fired.triggeredAlert?.topApplications.first?.displayName, "Google Chrome")
        // Verify we exit confirming state so adaptive monitor returns to low-frequency monitoring
        XCTAssertFalse(sm.isConfirmingThresholdPersistence)

        // Hysteresis check: CPU dips slightly to 79% (below 85% threshold, but ABOVE 75% recovery threshold)
        // Must remain in alertedAwaitingRecovery and NOT reset to normal!
        _ = sm.evaluate(
            timestampNs: tAlert + 10_000_000_000,
            cpuPercent: 79.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        if case .alertedAwaitingRecovery = sm.cpuState {
            // Expected
        } else {
            XCTFail("Hysteresis failed: state reset prematurely at 79% when recovery threshold is 75%")
        }

        // Now CPU drops to 72% (<= 75% hysteresis recovery threshold) -> state resets to .normal!
        _ = sm.evaluate(
            timestampNs: tAlert + 20_000_000_000,
            cpuPercent: 72.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        XCTAssertEqual(sm.cpuState, .normal)

        // Cooldown check: Spike again at tAlert + 40s (still within 300s cooldown) for 30s
        let tSpike2 = tAlert + 40_000_000_000
        _ = sm.evaluate(
            timestampNs: tSpike2,
            cpuPercent: 90.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        let suppressedByCooldown = sm.evaluate(
            timestampNs: tSpike2 + 30_000_000_000,
            cpuPercent: 90.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        XCTAssertNil(suppressedByCooldown.triggeredAlert, "Cooldown must prevent duplicate alert within 300s")

        // Recover again and spike after 350s (> 300s cooldown) -> Alert fires again!
        let tAfterCooldown = tAlert + 350_000_000_000
        _ = sm.evaluate(
            timestampNs: tAfterCooldown - 10_000_000_000,
            cpuPercent: 30.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        _ = sm.evaluate(
            timestampNs: tAfterCooldown,
            cpuPercent: 93.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        let allowedAfterCooldown = sm.evaluate(
            timestampNs: tAfterCooldown + 26_000_000_000,
            cpuPercent: 94.0,
            memoryPressure: .normal,
            config: config,
            topAppsByCPU: { [dummyApp] },
            topAppsByMemory: { [dummyApp] }
        )
        XCTAssertNotNil(allowedAfterCooldown.triggeredAlert, "Alert should fire again after recovery + cooldown expiration")
    }

    // MARK: - 4. Helper Process Aggregation & Zero Double Counting

    func testHelperProcessGroupingWithoutDoubleCountingOrFalseAttribution() {
        let uid: uid_t = 501
        let elapsedNs: UInt64 = 1_000_000_000 // 1 second
        let cores = 8

        // Simulate:
        // 1. Google Chrome (PID 100) + 2 helpers (PID 101 via PPID, PID 102 via bundle path with ppid=1)
        // 2. Safari (PID 200) + WebKit WebContent XPC helper (PID 201 with ppid=1)
        // 3. Visual Studio Code (PID 300) + Code Helper (PID 301)
        // 4. Discord (PID 400) + Discord Helper (PID 401)
        let records: [RawProcessRecord] = [
            RawProcessRecord(
                pid: 100, ppid: 1, uid: uid, startTimeSec: 10, startTimeUsec: 0,
                name: "Google Chrome", bundleIdentifier: "com.google.Chrome",
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                isGUIApplication: true, cpuTimeTotalNs: 1_000_000_000, physFootprintBytes: 400_000_000
            ),
            RawProcessRecord(
                pid: 101, ppid: 100, uid: uid, startTimeSec: 11, startTimeUsec: 0,
                name: "Google Chrome Helper (Renderer)", bundleIdentifier: "com.google.Chrome.helper.renderer",
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                isGUIApplication: false, cpuTimeTotalNs: 2_000_000_000, physFootprintBytes: 800_000_000
            ),
            RawProcessRecord(
                pid: 102, ppid: 1, uid: uid, startTimeSec: 12, startTimeUsec: 0,
                name: "Google Chrome Helper (GPU)", bundleIdentifier: nil,
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)",
                isGUIApplication: false, cpuTimeTotalNs: 1_000_000_000, physFootprintBytes: 300_000_000
            ),
            // Duplicate entry of PID 102 to verify strict deduplication (no double counting!)
            RawProcessRecord(
                pid: 102, ppid: 1, uid: uid, startTimeSec: 12, startTimeUsec: 0,
                name: "Google Chrome Helper (GPU)", bundleIdentifier: nil,
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)",
                isGUIApplication: false, cpuTimeTotalNs: 1_000_000_000, physFootprintBytes: 300_000_000
            ),
            // Safari + WebKit XPC helper
            RawProcessRecord(
                pid: 200, ppid: 1, uid: uid, startTimeSec: 20, startTimeUsec: 0,
                name: "Safari", bundleIdentifier: "com.apple.Safari",
                executablePath: "/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
                isGUIApplication: true, cpuTimeTotalNs: 500_000_000, physFootprintBytes: 250_000_000
            ),
            RawProcessRecord(
                pid: 201, ppid: 1, uid: uid, startTimeSec: 21, startTimeUsec: 0,
                name: "com.apple.WebKit.WebContent", bundleIdentifier: "com.apple.WebKit.WebContent",
                executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                isGUIApplication: false, cpuTimeTotalNs: 1_500_000_000, physFootprintBytes: 950_000_000
            ),
            // VS Code + Code Helper
            RawProcessRecord(
                pid: 300, ppid: 1, uid: uid, startTimeSec: 30, startTimeUsec: 0,
                name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode",
                executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                isGUIApplication: true, cpuTimeTotalNs: 500_000_000, physFootprintBytes: 350_000_000
            ),
            RawProcessRecord(
                pid: 301, ppid: 300, uid: uid, startTimeSec: 31, startTimeUsec: 0,
                name: "Code Helper (Plugin)", bundleIdentifier: "com.microsoft.VSCode.helper",
                executablePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                isGUIApplication: false, cpuTimeTotalNs: 500_000_000, physFootprintBytes: 600_000_000
            ),
            // Discord + Discord Helper
            RawProcessRecord(
                pid: 400, ppid: 1, uid: uid, startTimeSec: 40, startTimeUsec: 0,
                name: "Discord", bundleIdentifier: "com.hnc.Discord",
                executablePath: "/Applications/Discord.app/Contents/MacOS/Discord",
                isGUIApplication: true, cpuTimeTotalNs: 200_000_000, physFootprintBytes: 200_000_000
            ),
            RawProcessRecord(
                pid: 401, ppid: 400, uid: uid, startTimeSec: 41, startTimeUsec: 0,
                name: "Discord Helper", bundleIdentifier: "com.hnc.Discord.helper",
                executablePath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper",
                isGUIApplication: false, cpuTimeTotalNs: 200_000_000, physFootprintBytes: 300_000_000
            )
        ]

        // Baseline CPU map = 0 for all keys so cpuDeltaNs == cpuTimeTotalNs
        var baseline: [ProcessInstanceKey: UInt64] = [:]
        for r in records {
            baseline[ProcessInstanceKey(pid: r.pid, startTimeSec: r.startTimeSec, startTimeUsec: r.startTimeUsec)] = 0
        }

        let aggregated = ProcessAggregator.aggregateProcesses(
            records: records,
            previousCPUTimeByKey: baseline,
            elapsedNs: elapsedNs,
            logicalCoreCount: cores,
            topCount: 4
        )

        XCTAssertEqual(aggregated.topByMemory.count, 4)

        // Rank 1 by Memory & CPU: Google Chrome (400M + 800M + 300M = 1,500,000,000 bytes; 2 helpers; 4s CPU / 8s = 50% machine CPU)
        let chrome = aggregated.topByMemory[0]
        XCTAssertEqual(chrome.displayName, "Google Chrome")
        XCTAssertEqual(chrome.memoryFootprintBytes, 1_500_000_000)
        XCTAssertEqual(chrome.helperProcessCount, 2)
        XCTAssertEqual(chrome.cpuPercentMachine, 50.0, accuracy: 0.01)

        // Rank 2 by Memory: Safari (250M + 950M = 1,200,000,000 bytes; 1 helper)
        let safari = aggregated.topByMemory[1]
        XCTAssertEqual(safari.displayName, "Safari")
        XCTAssertEqual(safari.memoryFootprintBytes, 1_200_000_000)
        XCTAssertEqual(safari.helperProcessCount, 1)

        // Rank 3 by Memory: Visual Studio Code (350M + 600M = 950,000,000 bytes; 1 helper)
        let vscode = aggregated.topByMemory[2]
        XCTAssertEqual(vscode.displayName, "Visual Studio Code")
        XCTAssertEqual(vscode.memoryFootprintBytes, 950_000_000)
        XCTAssertEqual(vscode.helperProcessCount, 1)

        // Rank 4 by Memory: Discord (200M + 300M = 500,000,000 bytes; 1 helper)
        let discord = aggregated.topByMemory[3]
        XCTAssertEqual(discord.displayName, "Discord")
        XCTAssertEqual(discord.memoryFootprintBytes, 500_000_000)
        XCTAssertEqual(discord.helperProcessCount, 1)
    }

    func testBackgroundAgentsSeparatedFromRegularApps() {
        let uid: uid_t = 501
        let records: [RawProcessRecord] = [
            // Regular GUI app
            RawProcessRecord(
                pid: 100, ppid: 1, uid: uid, startTimeSec: 10, startTimeUsec: 0,
                name: "Helium", bundleIdentifier: "com.helium.app",
                executablePath: "/Applications/Helium.app/Contents/MacOS/Helium",
                isGUIApplication: true, cpuTimeTotalNs: 500_000_000, physFootprintBytes: 900_000_000
            ),
            // Background agent .app bundle (`isGUIApplication == false`) + 1 child helper
            RawProcessRecord(
                pid: 500, ppid: 1, uid: uid, startTimeSec: 50, startTimeUsec: 0,
                name: "SetappAgent", bundleIdentifier: "com.setapp.DesktopClient.SetappAgent",
                executablePath: "/Users/user/Library/Application Support/Setapp/LaunchAgents/Setapp.app/Contents/Library/LoginItems/SetappAgent.app/Contents/MacOS/SetappAgent",
                isGUIApplication: false, cpuTimeTotalNs: 300_000_000, physFootprintBytes: 200_000_000
            ),
            RawProcessRecord(
                pid: 501, ppid: 500, uid: uid, startTimeSec: 51, startTimeUsec: 0,
                name: "SetappUpdateHelper", bundleIdentifier: nil,
                executablePath: "/Users/user/Library/Application Support/Setapp/LaunchAgents/Setapp.app/Contents/Library/LoginItems/SetappAgent.app/Contents/MacOS/SetappUpdateHelper",
                isGUIApplication: false, cpuTimeTotalNs: 100_000_000, physFootprintBytes: 50_000_000
            )
        ]

        var baseline: [ProcessInstanceKey: UInt64] = [:]
        for r in records {
            baseline[ProcessInstanceKey(pid: r.pid, startTimeSec: r.startTimeSec, startTimeUsec: r.startTimeUsec)] = 0
        }

        let output = ProcessAggregator.aggregateProcesses(
            records: records,
            previousCPUTimeByKey: baseline,
            elapsedNs: 1_000_000_000,
            logicalCoreCount: 8,
            topCount: 3
        )

        XCTAssertEqual(output.topByMemory.count, 1)
        XCTAssertEqual(output.topByMemory[0].displayName, "Helium")
        XCTAssertFalse(output.topByMemory[0].isBackgroundProcess)

        XCTAssertEqual(output.topBackgroundByMemory.count, 1)
        XCTAssertEqual(output.topBackgroundByMemory[0].displayName, "SetappAgent")
        XCTAssertEqual(output.topBackgroundByMemory[0].memoryFootprintBytes, 250_000_000)
        XCTAssertEqual(output.topBackgroundByMemory[0].helperProcessCount, 1)
        XCTAssertTrue(output.topBackgroundByMemory[0].isBackgroundProcess)
    }

    // MARK: - 5. Multi-Selection Logic

    func testMultiSelectionSkipsProtectedAppsAndReconciles() {
        let chrome = AggregatedAppProcess(
            id: 100, startTimeSec: 1, startTimeUsec: 0, bundleIdentifier: "com.google.Chrome",
            displayName: "Google Chrome", executablePath: nil, cpuPercentMachine: 30,
            cpuPercentSingleCoreEquivalent: 240, memoryFootprintBytes: 1_000_000_000,
            helperProcessCount: 5, groupedPIDs: [100], isProtectedSystemApp: false
        )
        let finder = AggregatedAppProcess(
            id: 200, startTimeSec: 1, startTimeUsec: 0, bundleIdentifier: "com.apple.finder",
            displayName: "Finder", executablePath: "/System/Library/CoreServices/Finder.app",
            cpuPercentMachine: 10, cpuPercentSingleCoreEquivalent: 80, memoryFootprintBytes: 300_000_000,
            helperProcessCount: 0, groupedPIDs: [200], isProtectedSystemApp: true,
            protectionReason: "Essential macOS system component"
        )
        let discord = AggregatedAppProcess(
            id: 300, startTimeSec: 1, startTimeUsec: 0, bundleIdentifier: "com.hnc.Discord",
            displayName: "Discord", executablePath: nil, cpuPercentMachine: 15,
            cpuPercentSingleCoreEquivalent: 120, memoryFootprintBytes: 600_000_000,
            helperProcessCount: 3, groupedPIDs: [300], isProtectedSystemApp: false
        )

        let list = [chrome, finder, discord]
        var selection = AppSelectionModel()

        // Attempting to select protected Finder must be ignored
        selection.setSelected(true, for: finder)
        XCTAssertFalse(selection.isSelected(finder.id))

        // Select All Eligible selects Chrome and Discord, skipping Finder
        selection.selectAllEligible(in: list)
        XCTAssertTrue(selection.isSelected(chrome.id))
        XCTAssertTrue(selection.isSelected(discord.id))
        XCTAssertFalse(selection.isSelected(finder.id))
        XCTAssertTrue(selection.areAllEligibleSelected(in: list))
        XCTAssertEqual(selection.selectedApplications(in: list).map { $0.id }, [100, 300])

        // Reconcile when Discord exits
        selection.reconcile(with: [chrome, finder])
        XCTAssertEqual(selection.selectedPIDs, [100])
    }

    // MARK: - 6. Process Termination Eligibility & PID Reuse Protection

    func testCriticalSystemProcessesAreProtected() {
        let protectedTargets: [(pid: pid_t, uid: uid_t, bundleID: String?, name: String, path: String?)] = [
            (1, 0, nil, "launchd", "/sbin/launchd"),
            (310, 501, "com.apple.finder", "Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            (311, 501, "com.apple.dock", "Dock", "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            (180, 88, "com.apple.WindowServer", "WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"),
            (190, 501, "com.apple.loginwindow", "loginwindow", "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"),
            (ProcessInfo.processInfo.processIdentifier, 501, "com.macresourceguard.app", "MacResourceGuard", nil)
        ]

        for target in protectedTargets {
            let result = SafeAppTerminator.evaluateProtection(
                pid: target.pid,
                uid: target.uid,
                bundleIdentifier: target.bundleID,
                processName: target.name,
                executablePath: target.path
            )
            XCTAssertTrue(result.isProtected, "\(target.name) must be protected from termination")
            XCTAssertNotNil(result.reason)
        }

        // Standard user application is eligible
        let userApp = SafeAppTerminator.evaluateProtection(
            pid: 9876,
            uid: 501,
            bundleIdentifier: "com.google.Chrome",
            processName: "Google Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        XCTAssertFalse(userApp.isProtected)
    }

    func testPIDReuseProtectionBlocksStaleSnapshotTermination() {
        let snapshotApp = AggregatedAppProcess(
            id: 5555,
            startTimeSec: 1_700_000_100,
            startTimeUsec: 500,
            bundleIdentifier: "com.google.Chrome",
            displayName: "Google Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            cpuPercentMachine: 45.0,
            cpuPercentSingleCoreEquivalent: 360.0,
            memoryFootprintBytes: 800_000_000,
            helperProcessCount: 4,
            groupedPIDs: [5555],
            isProtectedSystemApp: false
        )

        // Case 1: Live process matches exact startTimeSec, startTimeUsec, and bundleID
        let validCheck = SafeAppTerminator.verifyProcessIdentity(for: snapshotApp) { _ in
            (startTimeSec: 1_700_000_100, startTimeUsec: 500, bundleID: "com.google.Chrome")
        }
        XCTAssertTrue(validCheck.exists)
        XCTAssertTrue(validCheck.isMatchingIdentity)

        // Case 2: PID 5555 was reused by a new process started 2 seconds later!
        let reusedPIDCheck = SafeAppTerminator.verifyProcessIdentity(for: snapshotApp) { _ in
            (startTimeSec: 1_700_000_102, startTimeUsec: 120, bundleID: "com.apple.TextEdit")
        }
        XCTAssertTrue(reusedPIDCheck.exists)
        XCTAssertFalse(reusedPIDCheck.isMatchingIdentity, "PID reuse must be detected and rejected!")
    }

    func testMacOSSystemProcessClassificationAndDefaultAlertsDisabled() {
        let currentUID = getuid()
        // macOS / Apple system processes -> true
        XCTAssertTrue(ProcessAggregator.isMacOSOrSystemProcess(
            name: "Finder",
            bundleIdentifier: "com.apple.finder",
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            uid: currentUID
        ))
        XCTAssertTrue(ProcessAggregator.isMacOSOrSystemProcess(
            name: "mds_stores",
            bundleIdentifier: nil,
            executablePath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds_stores",
            uid: 0
        ))
        // Third-party user app & background agent -> false
        XCTAssertFalse(ProcessAggregator.isMacOSOrSystemProcess(
            name: "Helium",
            bundleIdentifier: "com.helium.app",
            executablePath: "/Applications/Helium.app/Contents/MacOS/Helium",
            uid: currentUID
        ))
        XCTAssertFalse(ProcessAggregator.isMacOSOrSystemProcess(
            name: "SetappAgent",
            bundleIdentifier: "com.setapp.DesktopClient.SetappAgent",
            executablePath: "/Users/user/Library/Application Support/Setapp/LaunchAgents/Setapp.app/Contents/Library/LoginItems/SetappAgent.app/Contents/MacOS/SetappAgent",
            uid: currentUID
        ))

        let testSuiteName = "com.macresourceguard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: testSuiteName)!
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(store.notificationsEnabled, "Alerts must be disabled by default")
        XCTAssertFalse(store.hideMacOSSystemProcesses, "Hide macOS / System checkbox defaults to off")
        store.hideMacOSSystemProcesses = true
        XCTAssertTrue(store.hideMacOSSystemProcesses)
        defaults.removePersistentDomain(forName: testSuiteName)
    }
}
