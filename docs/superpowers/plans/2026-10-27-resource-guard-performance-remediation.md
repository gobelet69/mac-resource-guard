# Resource Guard Performance Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct CPU and memory-pressure measurements while reducing Resource Guard's interactive process-enumeration, retained-memory, wakeup, and lifecycle cost without weakening monitoring or touching user applications.

**Architecture:** Keep the existing adaptive coordinator and Darwin sampling design. Make the measurement formulas deterministic and unit-testable, expose the narrow process-sampling lifecycle behind an internal protocol for coordinator tests, and release only transient detailed/icon state when the popover closes. Re-run the identical Release workloads after each performance-relevant task.

**Tech Stack:** Swift 5.10, AppKit, Foundation, Darwin/Mach, libproc, XCTest, zsh profiling tools.

**Spec:** `qa/reports/performance/2026-10-27-resource-guard-audit.md`

## Global Constraints

- Do not terminate or signal any process not launched by the audit harness.
- Do not publish a release, push, or mutate user applications or personal files.
- Preserve the 10 s idle, 2 s confirmation, and 3 s interactive monitoring policy unless before/after evidence independently justifies a frequency change.
- Measure the same controlled workload before and after every performance correction.
- Keep raw traces in `/tmp`; commit only concise non-personal summaries.

## Review Focus

- A 32-bit CPU tick wrapping while other tick counters do not wrap must produce the correct modulo delta, not zero or a spike.
- VM page categories that overlap must not be added twice; speculative pages must not be added on top of `free_count`.
- Opening the popover must perform exactly one immediate detailed capture and one delayed follow-up, without a separate prime capture.
- Closing the popover during the delayed-follow-up window must prevent that follow-up and release detailed/icon state.
- Reopening after background cleanup must rebuild accurate process CPU deltas without stale icons or duplicate enumeration.

---

### Task 1: Correct CPU counter wrap and available-memory accounting

**Files:**
- Modify: `Sources/MacResourceGuardCore/Models/ResourceMetrics.swift`
- Modify: `Sources/MacResourceGuardCore/Monitoring/SystemMetricsSampler.swift`
- Modify: `Tests/MacResourceGuardTests/MacResourceGuardTests.swift`

**Interfaces:**
- Produces: `CPUTicksSample.counterDelta(previous:current:) -> UInt64` with 32-bit modulo semantics.
- Produces: `MemoryMetrics.reclaimableBytes(freeBytes:inactiveBytes:purgeableBytes:totalPhysicalBytes:) -> UInt64`.

- [ ] **Step 1: Write failing formula tests**

Add `testSystemWideCPUTicksHandleUInt32Wrap()` with hand-derived deltas spanning `UInt32.max`, and `testReclaimableMemoryDoesNotDoubleCountFileBackedPages()` with literal byte counts proving only free + inactive + purgeable are included and capped.

- [ ] **Step 2: Verify both tests fail for the expected old behavior**

Run: `swift test -c release --scratch-path /tmp/mrg-audit-task1-red --filter 'MacResourceGuardTests.(testSystemWideCPUTicksHandleUInt32Wrap|testReclaimableMemoryDoesNotDoubleCountFileBackedPages)'`

Expected: FAIL because wrap currently becomes zero and the reclaimable helper does not exist.

- [ ] **Step 3: Implement the minimal formula corrections**

Use modulo-`UInt32` delta calculation for each host CPU field. Compute `availableBytes` from free + inactive + purgeable only, with overflow-safe addition and a physical-memory cap. Keep external + purgeable for the separately labelled cache metric and document the overlapping classifications.

- [ ] **Step 4: Verify formulas and the full suite**

Run: `swift test -c release --scratch-path /tmp/mrg-audit-task1-green`

Expected: all tests PASS with 0 failures.

- [ ] **Step 5: Measure formula overhead and record results**

Run the same 20 × 2 s closed-popover Release scenario. Expected: no measurable idle CPU or footprint regression beyond sampling variability; add exact numbers to the audit report.

### Task 2: Remove redundant interactive enumeration and over-fetching

**Files:**
- Modify: `Sources/MacResourceGuardCore/Monitoring/AdaptiveMonitorCoordinator.swift`
- Modify: `Sources/MacResourceGuardCore/Monitoring/ProcessAggregator.swift`
- Modify: `Tests/MacResourceGuardTests/MacResourceGuardTests.swift`

**Interfaces:**
- Produces: internal `ProcessSampling` protocol with `sampleTopApplications(topCount:)`, `primeBaseline()`, and transient-cache cleanup.
- Consumes: a test fake through an internal coordinator initializer; the public initializer remains source-compatible.

- [ ] **Step 1: Write a failing coordinator behavior test**

Add `testOpeningPopoverUsesOneImmediateCaptureAndOneDelayedFollowUp()` with a fake process sampler. Assert the first delivered detailed snapshot follows one `sampleTopApplications(topCount: 3)` call, zero `primeBaseline()` calls, and the delayed refresh raises the sample count to exactly two.

- [ ] **Step 2: Verify RED**

Run the filtered test and confirm failure reports the existing prime call and/or `topCount: 15`.

- [ ] **Step 3: Implement the narrow sampling abstraction and minimal coordinator change**

Remove the popover-open prime call, keep the immediate detailed capture as the CPU baseline, retain the 650 ms follow-up, and request exactly three results per category. Keep threshold-confirmation priming unchanged.

- [ ] **Step 4: Verify GREEN and cancellation behavior**

Add `testClosingPopoverCancelsDelayedDetailedFollowUp()` before changing cancellation code if required. Run both focused tests, then the full Release suite.

- [ ] **Step 5: Rebuild Release and repeat the controlled popover workload**

Measure 20 × 1 s samples with the same naturally exiting synthetic CPU worker. Record stabilized average/peak CPU, first-open average/peak, RSS, physical footprint, and observable idle wakeups in the report before continuing.

### Task 3: Bound detailed cache lifetime on popover close

**Files:**
- Modify: `Sources/MacResourceGuardCore/Monitoring/AdaptiveMonitorCoordinator.swift`
- Modify: `Sources/MacResourceGuardCore/Monitoring/ProcessAggregator.swift`
- Modify: `Sources/MacResourceGuardApp/UI/AppRowView.swift`
- Modify: `Sources/MacResourceGuardApp/UI/PopoverViewController.swift`
- Modify: `Sources/MacResourceGuardApp/UI/StatusBarController.swift`
- Modify: `Tests/MacResourceGuardTests/MacResourceGuardTests.swift`

**Interfaces:**
- Produces: `ProcessAggregator.discardTransientCaches()` that clears decoded icons but preserves lightweight live-process CPU/path baseline state.
- Produces: `AppRowView.prepareForReuse()` and `PopoverViewController.releaseDetailedContent()` to drop retained app/icon references without destroying the reusable popover layout.

- [ ] **Step 1: Write failing lifecycle tests**

Add a fake-sampler coordinator test asserting one cleanup call and empty detailed snapshot lists after `setPopoverVisible(false)`. Add an AppKit unit test in the Xcode test target asserting `prepareForReuse()` clears `currentApp`; keep the SwiftPM core suite independent of app UI.

- [ ] **Step 2: Verify RED with the focused SwiftPM and Xcode tests**

Expected: missing cleanup APIs and retained detailed state fail the assertions.

- [ ] **Step 3: Implement transient cleanup**

On close, cancel eligibility for the delayed follow-up, clear coordinator detailed arrays, clear decoded icon cache, reset row-held applications/icons, and leave the system snapshot plus process CPU baseline intact.

- [ ] **Step 4: Verify GREEN and reopen correctness**

Add `testReopeningAfterCleanupRepopulatesDetailedData()` using the fake sampler. Run focused tests, full SwiftPM tests, and the Xcode test scheme.

- [ ] **Step 5: Measure open/close/reopen memory**

Use an audit-only close hook or injected lifecycle test rather than global keyboard automation. Capture physical footprint before open, after stabilization, after close/autorelease drain, and after reopen. Record retained and peak deltas in the report.

### Task 4: Harden the repeatable profiler and complete the final gate

**Files:**
- Modify: `Scripts/profile_performance.sh`
- Modify: `qa/reports/performance/2026-10-27-resource-guard-audit.md`
- Modify: `README.md` only if documented monitoring behavior changed.

**Interfaces:**
- Produces: a path-independent profiler that accepts an explicit app binary and output directory, records only audit-owned PIDs, and never sends a signal to unrelated processes.

- [ ] **Step 1: Add a shell-level smoke test for missing binary, owned PID cleanup, and output creation**

The test must use a harmless synthetic executable and prove cleanup targets only the recorded child PID.

- [ ] **Step 2: Verify RED, then update the profiler minimally**

Remove obsolete absolute paths, separate idle and popover scenarios, label units, calculate averages/peaks, and retain raw traces under `/tmp` by default.

- [ ] **Step 3: Run final verification from a clean Release build**

Run `swift test -c release`, the Xcode test scheme, and `xcodebuild` Release with signing disabled. Require 0 failures and `BUILD SUCCEEDED`.

- [ ] **Step 4: Run final self-impact scenarios**

Repeat idle, interactive controlled load, open/close/reopen, `leaks`, and stack sampling. Compare every metric with the baseline table, include variability and limitations, and classify each row PASS/WARN/FAIL.

- [ ] **Step 5: Review scope and repository state**

Confirm no release/push occurred, no distributable changed, no real user application was terminated, raw traces are absent from Git, and only scoped code/tests/report changes remain.
