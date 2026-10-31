# Resource Guard self-impact performance audit

**Date:** 2026-10-27  
**Mode:** Audit + Fix (baseline complete; remediation pending plan approval)  
**Status:** WARN

## Scope and constraints

This audit measures Resource Guard's own CPU, memory, process-enumeration, wakeup, and lifecycle cost. It uses only audit-owned Resource Guard instances and a synthetic CPU worker that exits naturally. No user application was terminated, no personal file was mutated, and no release was published.

## Environment

- Apple M2, 8 logical cores, 8 GiB physical memory
- macOS 27.0 (26A428)
- Xcode 27.1 (27A9275), Swift 5.10 project settings
- Release build: `-O`, whole-module optimization, unsigned, isolated derived data under `/tmp`
- Existing user Resource Guard process PID 60082 was observed but never signalled or profiled as the controlled target

## Controlled scenarios and baseline

| Scenario | Window | Metric | Baseline | Result |
|---|---:|---|---:|---|
| Closed popover, default 10 s monitor interval | 20 × 2 s samples after 5 s warm-up | Stabilized CPU average | 0.144% | PASS against the existing `<0.2%` idle target |
| Closed popover | same | CPU peak | 0.6% | PASS; short sampling/status update spikes |
| Closed popover | after sampling | Physical footprint | 18.8 MiB, 19.0 MiB peak | PASS against the existing `<40 MiB` target |
| Closed popover | same | Idle wakeups reported by `top` | 0 in all 20 samples | PASS, limited to `top`'s observable idle-wakeup field |
| Open popover with one synthetic CPU worker | 20 × 1 s samples | Stabilized CPU average | 1.080% | WARN; detailed enumeration dominates interactive cost |
| Open popover | same | CPU peak after warm-up | 7.0% | WARN; aligns with the 3 s detailed refresh cadence |
| Open popover | same | Resident memory from `top` | 34–41 MiB steady, transient 55 MiB | WARN |
| Open popover | after sampling | Physical footprint | 63.3 MiB, 71.8 MiB peak | FAIL against the existing `<40 MiB` target while interactive |
| Idle and open popover | 5–45 s live runs | `leaks` | 13–20 KiB in LaunchServices/AppKit XPC cycles | WARN; no Resource Guard allocation stack was reported, so no application leak is confirmed |

The open-popover average including launch and first-paint work was 3.110% with a 20.7% one-second peak. This value is reported separately from the stabilized average because it includes UI construction and the initial burst.

## Confirmed findings

### P1 — Interactive sampling performs redundant full process captures

Opening the popover currently calls `primeBaseline()`, immediately calls `sampleTopApplications()`, and schedules another detailed sample 650 ms later. The first two operations enumerate the complete process table back-to-back. The second capture is sufficient both to populate memory data and establish the next CPU baseline, so the explicit prime is redundant.

Every detailed sample requests 15 results in each of four lists and resolves icons for those lists even though the UI displays at most three entries. This expands icon decoding/caching and retained snapshot data without user-visible benefit.

Expected correction: one immediate detailed capture, one 650 ms follow-up, and three retained entries per category. Measure the same popover scenario before and after.

### P1 — Available-memory estimate double-counts overlapping VM classifications

`availableBytes` adds free, inactive, external/file-backed, and purgeable pages. `inactive_count` is an activity-state count while `external_page_count` is a backing-type count; the sets overlap. The current formula can therefore count file-backed inactive pages twice. The SDK also states that speculative pages are already included in `free_count`, so they must not be added separately.

Expected correction: use a conservative reclaimable estimate of free + inactive + purgeable, capped at physical memory, while retaining external + purgeable as the separately labelled cache estimate. Kernel and dispatch pressure signals remain authoritative.

### P2 — System CPU delta mishandles 32-bit Mach counter wrap

`HOST_CPU_LOAD_INFO` exposes `natural_t cpu_ticks[4]`; on arm64 `natural_t` is an unsigned 32-bit integer. The current calculation converts samples to `UInt64` and substitutes zero whenever a current field is lower than its previous value. At a counter wrap this drops the real delta for that field and can materially skew one sample.

Expected correction: calculate each field delta modulo `UInt32.max + 1`, with a regression test spanning the boundary.

### P2 — Detailed caches have no explicit background lifecycle

Detailed snapshots and the icon dictionary remain retained after the popover closes. The icon dictionary is not pruned when an application exits. This is a bounded short-run cost but an unbounded long-running cache under application churn.

Expected correction: clear transient detailed snapshots and icon objects when returning to background monitoring, while retaining only the inexpensive CPU/path baseline needed for correct next-sample deltas.

## Other focus areas

- **Monitoring frequency:** 10 s idle, 2 s threshold confirmation, 3 s interactive. The adaptive policy is appropriate; no frequency change is justified before eliminating redundant work.
- **Background operation:** low-frequency samples use Mach/sysctl only and do not enumerate processes unless pressure confirmation requires attribution.
- **Menu bar lifecycle:** status updates avoid redundant AppKit writes when rounded text and severity are unchanged. Transient detailed caches still need explicit release.
- **Sleep/wake:** no destructive live sleep test was run because it would disrupt the user's machine. Dispatch timers and `CLOCK_UPTIME_RAW` are appropriate primitives, but a deterministic suspend/resume baseline-reset test is still required.
- **CPU accuracy:** normal and multicore math tests pass; wrap handling is missing.
- **Memory-pressure accuracy:** kernel and dispatch pressure mappings are correct; the secondary available-memory heuristic is not.

## Verification completed

- `swift test -c release --scratch-path /tmp/mrg-audit-spm-before`: 13 tests, 0 failures.
- `xcodebuild ... -configuration Release -derivedDataPath /tmp/mrg-audit-dd-before CODE_SIGNING_ALLOWED=NO build`: `BUILD SUCCEEDED`.
- Idle and popover runs used only child PIDs created by the audit and cleaned them up after collection.
- `sample` showed the main thread blocked in the AppKit event loop during idle windows; no sustained application hot stack was captured.

## Open blockers

- After-measurements cannot exist until the remediation plan is approved and implemented.
- `powermetrics` process-energy sampling is not available without elevated privileges in this environment. CPU time, footprint, timer cadence, and observable idle wakeups are used as non-privileged energy proxies.
- A real machine sleep/wake cycle was intentionally not triggered. Verification will use injected lifecycle notifications and baseline-reset assertions, then document the lack of real sleep hardware proof.

## Exit criteria for PASS

- Same controlled idle and popover workloads repeated on the corrected Release build.
- Idle CPU does not regress beyond run-to-run variability and remains below 0.2% stabilized average.
- Popover stabilized CPU and first-open burst both improve relative to this baseline.
- Interactive physical footprint is reduced; any result still above 40 MiB remains WARN/FAIL with attribution.
- All unit tests, Release build, lifecycle checks, and leak inspection complete without an application-owned leak.
