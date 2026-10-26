# Mac Resource Guard

**Mac Resource Guard** is an ultra-lightweight, native macOS menu bar utility built with **Swift**, **AppKit**, and **low-level Mach/Darwin kernel APIs**. It monitors CPU utilization, intelligent memory pressure, and swap activity while consuming minimal system resources—designed and profiled specifically for 8 GB Apple Silicon Macs.

---

## 1. Architecture & Technical Highlights

- **Pure Native AppKit UI**: Built with `NSStatusBar`, `NSStatusItem`, `NSPopover`, `NSVisualEffectView`, `NSWindow`, and reusable `NSView` rows. Zero Electron, zero web views, zero SwiftUI attribute-graph overhead, and zero third-party dependencies.
- **Adaptive Two-Tier Monitoring**:
  - **Low-Frequency Idle Mode (Default: every 10s)**: Executes only two Mach traps (`host_statistics(HOST_CPU_LOAD_INFO)` and `host_statistics64(HOST_VM_INFO64)`) and two `sysctlbyname` calls (`vm.swapusage`, `kern.memorystatus_vm_pressure_level`) on a coalesced `.utility` background queue. **Zero process enumeration** and **zero shell commands** (`top`, `ps`, `vm_stat`) occur during normal background operation.
  - **Threshold Confirmation Mode (Every 2s)**: Triggered only when CPU exceeds the warning threshold (default 85%) or memory pressure elevates. Confirms persistence over the sustained duration (default 25s), samples per-process CPU deltas and physical memory footprints via `libproc`, fires an actionable alert identifying the top 3 culprit applications, and **immediately returns to low-frequency monitoring afterward**.
  - **Interactive Popover Mode (Every 3s while open)**: Refreshes top applications only while the user is actively viewing the popover, stopping immediately when closed.
- **Monotonic Time & Apple Silicon Timebase Accuracy**:
  - Uses `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` for monotonic elapsed intervals.
  - Converts `rusage_info_v4` (`ri_user_time + ri_system_time`) from Mach absolute ticks (`24 MHz` on Apple Silicon) into true nanoseconds via `mach_timebase_info` and normalizes per-process CPU usage across all logical cores (`0–100%` of total machine capacity).
- **Intelligent Memory-Pressure Detection**:
  - Combines event-driven kernel signals (`DispatchSource.makeMemoryPressureSource`), `kern.memorystatus_vm_pressure_level`, and Mach VM metrics (`compressor_page_count`, `swapouts` rate, `external_page_count` file cache, `purgeable_count`).
  - Does **not** trigger false alarms when macOS uses 85–90% of RAM for reclaimable file caching.
  - Note: This is a documented engineering heuristic combining kernel pressure signals and Mach VM counters; it does not claim to replicate Activity Monitor's proprietary internal graph formula.
- **Helper Process Grouping (Zero Double Counting)**:
  - Aggregates multi-process applications (**Google Chrome**, **Safari**, **Visual Studio Code**, **Discord**, etc.) using parent-PID (`ppid`) ancestry chains, outermost `.app` bundle path containment, and verified bundle-ID / WebKit XPC associations.
  - Deduplicates every PID per snapshot so memory footprint (`ri_phys_footprint`) and CPU deltas are never double-counted.
- **Safe Application Termination & PID Reuse Guard**:
  - Uses `NSRunningApplication.terminate()` first so applications can present standard macOS Save confirmation sheets.
  - Never silently force-quits an application; offers an explicit **Force Quit…** confirmation dialog only if an app remains open/unresponsive after a normal quit request.
  - Blocks termination of essential system components (`Finder`, `Dock`, `WindowServer`, `loginwindow`, `SystemUIServer`, `ControlCenter`, root daemons, and `MacResourceGuard` itself).
  - Verifies `(pid, pbi_start_tvsec, pbi_start_tvusec, bundleIdentifier)` via `proc_pidinfo(PROC_PIDTBSDINFO)` immediately prior to termination to prevent stale PID reuse races.

---

## 2. Project Structure

```text
Mac Ressource Guard/
├── project.yml                      # XcodeGen specification
├── Package.swift                    # Swift Package Manager manifest
├── MacResourceGuard.xcodeproj/      # Generated native Xcode project
├── Sources/
│   ├── MacResourceGuardCore/        # Core monitoring, aggregation, alerts, termination safety
│   │   ├── Models/
│   │   │   ├── ResourceMetrics.swift
│   │   │   └── AppSettings.swift
│   │   ├── Monitoring/
│   │   │   ├── SystemMetricsSampler.swift
│   │   │   ├── ProcessAggregator.swift
│   │   │   └── AdaptiveMonitorCoordinator.swift
│   │   ├── Alerts/
│   │   │   └── AlertStateMachine.swift
│   │   └── Termination/
│   │       ├── SafeAppTerminator.swift
│   │       └── AppSelectionModel.swift
│   └── MacResourceGuardApp/         # Native AppKit menu bar UI & notification controller
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── Notifications/
│       │   └── NotificationManager.swift
│       ├── UI/
│       │   ├── StatusBarController.swift
│       │   ├── PopoverViewController.swift
│       │   ├── AppRowView.swift
│       │   └── SettingsWindowController.swift
│       └── Resources/
│           ├── Info.plist
│           ├── MacResourceGuard.entitlements
│           └── Assets.xcassets/
├── Tests/
│   └── MacResourceGuardTests/
│       └── MacResourceGuardTests.swift
├── Scripts/
│   ├── generate_icon.swift
│   ├── package_dmg.sh
│   └── profile_performance.sh
└── dist/
    ├── MacResourceGuard.app         # Signed Release application bundle
    └── MacResourceGuard-1.0.0.dmg   # Distributable disk image
```

---

## 3. Build & Test Instructions

### Run Automated Unit Tests
```bash
cd "/Users/theodeville/Documents/Mac Ressource Guard"
swift test --scratch-path /tmp/mrg-spm-build
```

### Build Release `.app` and `.dmg`
```bash
cd "/Users/theodeville/Documents/Mac Ressource Guard"
./Scripts/package_dmg.sh
```
This script:
1. Generates `MacResourceGuard.xcodeproj` via `xcodegen`.
2. Compiles the Release build (`-O -whole-module-optimization`) via `xcodebuild`.
3. Signs `dist/MacResourceGuard.app` with Hardened Runtime and entitlements.
4. Packages `dist/MacResourceGuard-1.0.0.dmg` with an `/Applications` drop link.

### Install in `/Applications`
```bash
cp -R "/Users/theodeville/Documents/Mac Ressource Guard/dist/MacResourceGuard.app" /Applications/
open /Applications/MacResourceGuard.app
```
Or open `dist/MacResourceGuard-1.0.0.dmg` and drag **Mac Resource Guard** into **Applications**.

---

## 4. Distribution, App Sandbox & Notarization Guidance

### Why Non-Sandboxed Developer ID Distribution?
On macOS, a strict Mac App Store sandbox (`com.apple.security.app-sandbox = true`) blocks `proc_pid_rusage()` on peer user processes (`EPERM`) and forbids calling `NSRunningApplication.terminate()` on other applications.

Following the standard architecture used by native macOS system monitors, **Mac Resource Guard** uses **Direct Developer ID Distribution** (`com.apple.security.app-sandbox = false` with **Hardened Runtime** enabled). This allows full user-space process inspection and graceful application quitting with **zero administrator (`sudo`) privileges**, **zero Accessibility permissions**, and **zero Full Disk Access**.

### Developer ID Code Signing & Notarization Commands
To sign and notarize for public distribution with an Apple Developer ID certificate:

```bash
# 1. Sign with Developer ID Application certificate and Hardened Runtime
codesign --force --deep --options runtime --timestamp \
  --entitlements "Sources/MacResourceGuardApp/Resources/MacResourceGuard.entitlements" \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  "dist/MacResourceGuard.app"

# 2. Re-create the DMG from the signed app and submit to Apple Notary Service
xcrun notarytool submit "dist/MacResourceGuard-1.0.0.dmg" \
  --keychain-profile "AC_NOTARY_PROFILE" \
  --wait

# 3. Staple the notarization ticket
xcrun stapler staple "dist/MacResourceGuard-1.0.0.dmg"
```
