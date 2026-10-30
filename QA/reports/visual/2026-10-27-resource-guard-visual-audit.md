# Resource Guard visual audit

**Audit started:** 2026-10-27

**Remediation verified:** 2026-10-30

**Mode:** Audit + Fix

**Status:** WARN — application content corrected and verified; compositor-only states remain BLOCKED

## Outcome

Resource Guard now has deterministic, sanitized visual-QA scenarios for normal, elevated CPU, critical memory pressure, top-three applications, single and multiple selection, notification presentation states, and force-quit confirmation. All scenarios bypass live process enumeration, monitoring, notifications, and destructive actions. The Release application produced the committed light/dark captures below.

The small status badge now uses appearance-specific foreground and background colors that meet the 4.5:1 small-text target. Selected rows add a checkbox, an accent-tinted fill, and a 1 pt border, so selection does not rely on color alone. Visual-state updates disable implicit Core Animation actions.

No user application was terminated, no notification was sent, no private process name was committed, and no release was built or published.

## Visual direction

Resource Guard remains a compact native instrument rather than a decorative dashboard:

- system typography and controls;
- semantic green, orange, and red reserved for status;
- two equal metric cards, a segmented filter row, three process rows, one batch-action row, and a compact footer;
- no gradient, nested blur, or decorative animation;
- fixed 424 × 476 pt popover, exported at 2× (848 × 952 px).

The root remains the existing 96%-opaque lightweight custom surface. A native material change was intentionally not made because Screen Recording permission is unavailable, so its shadow, transparency, and energy impact could not be compared safely.

## State matrix

| Requested state | Evidence | Result |
|---|---|---|
| Menu bar icon | Real `NSStatusBarButton` content in normal/elevated/critical states | WARN — button content passes; placement and surrounding menu bar are BLOCKED |
| Normal popover | Sanitized Release capture, light and dark | PASS for application content |
| High CPU | Synthetic 88% elevated state, Release capture | PASS for application content |
| High memory pressure | Synthetic critical pressure with compression and swap, Release capture | PASS for application content |
| Top 3 resource-consuming apps | Aurora Editor, Northstar Browser, Canvas Studio; CPU and memory sorts | PASS, sanitized |
| Application selection | Checkbox plus row fill and border | PASS |
| Multiple selection | Two selected rows and count in batch action | PASS |
| Quit confirmation | Real `NSAlert` content using synthetic identity and no confirm handler | PASS for alert content; window placement/shadow BLOCKED |
| Notification states | Enabled, disabled, paused, and Do Not Disturb presentation | PASS for in-app state; no OS notification was sent |
| Light and dark | Full application-content matrix | PASS |
| Increased contrast | High-contrast light and dark Release captures | PASS |
| Graphite accent | Selection remains legible without color alone | WARN — actual Graphite appearance could not be forced process-locally |
| Transparency and shadow | Screen capture API unavailable | BLOCKED |
| Hover, keyboard focus, VoiceOver traversal | UI-control surface could not attach to the menu-bar-only app | BLOCKED |
| Responsive/scale | 424 × 476 pt layout and 848 × 952 px Retina output inspected | PASS at the designed fixed size only |

## Curated screenshots

All files below were exported by the Release application from inert fixtures:

- [`popover-light-normal.png`](screenshots/2026-10-27/popover-light-normal.png)
- [`popover-dark-normal.png`](screenshots/2026-10-27/popover-dark-normal.png)
- [`popover-light-high-cpu.png`](screenshots/2026-10-27/popover-light-high-cpu.png)
- [`popover-dark-memory-pressure.png`](screenshots/2026-10-27/popover-dark-memory-pressure.png)
- [`popover-light-single-selection.png`](screenshots/2026-10-27/popover-light-single-selection.png)
- [`popover-dark-multiple-selection.png`](screenshots/2026-10-27/popover-dark-multiple-selection.png)
- [`notification-light-enabled.png`](screenshots/2026-10-27/notification-light-enabled.png)
- [`notification-dark-paused.png`](screenshots/2026-10-27/notification-dark-paused.png)
- [`notification-light-do-not-disturb.png`](screenshots/2026-10-27/notification-light-do-not-disturb.png)
- [`quit-confirmation-light.png`](screenshots/2026-10-27/quit-confirmation-light.png)
- [`quit-confirmation-dark.png`](screenshots/2026-10-27/quit-confirmation-dark.png)
- [`status-item-light-normal.png`](screenshots/2026-10-27/status-item-light-normal.png)
- [`status-item-dark-elevated.png`](screenshots/2026-10-27/status-item-dark-elevated.png)
- [`status-item-light-critical.png`](screenshots/2026-10-27/status-item-light-critical.png)
- [`popover-high-contrast-light.png`](screenshots/2026-10-27/popover-high-contrast-light.png)
- [`popover-high-contrast-dark.png`](screenshots/2026-10-27/popover-high-contrast-dark.png)

## Corrected findings

### Status badge contrast

Before remediation, the small semantic labels measured 1.77:1 green, 1.84:1 orange, and 2.61:1 red in light appearance; dark red measured 3.67:1. The adaptive palette tests now require all normal, elevated, and critical pairs in light and dark to be at least 4.5:1.

### Selection clarity

Before remediation, only the checkbox changed. Selected rows now have a visible fill and border in addition to the checked control, with an accessibility value of `Selected` or `Not selected`.

### Deterministic and private QA

Before remediation, screenshots exposed local process names and could not reach several requested states. The explicit `--visual-qa-scenario` path now injects three fictional applications with invalid negative PIDs, disables quit controls before lookup, bypasses monitoring and notification configuration, and never installs a force-quit handler for the synthetic alert.

### Active control state

The application activates only for explicit visual-QA launches before export, allowing AppKit to draw active segmented controls without changing normal background operation.

## Lightweightness evidence

The styling correction adds only static color resolution and border/fill changes; it adds no timers, blur layers, observers, or animation loops.

Controlled dark multiple-selection measurement, using only an audit-owned synthetic process:

| Measurement | Before styling | After styling | Delta |
|---|---:|---:|---:|
| `footprint` | 39,388,120 B | 39,470,016 B | +81,896 B (+0.21%) |
| Stabilized CPU | 0.0% | 0.0% | 0.0 pp |

A final Release sanity run after all QA hooks reported a 37 MB footprint and five consecutive 0.0% CPU samples. RSS fluctuated during AppKit startup and is not used for the conclusion. Only the recorded audit PID was signalled after measurement.

## Verification and limitations

- SwiftPM test suite: 26 tests, 0 failures.
- Xcode macOS test action: 26 tests, 0 failures; `TEST SUCCEEDED`.
- Xcode Release build with derived data under `/tmp`: `BUILD SUCCEEDED`.
- Release exports: 16 committed sanitized PNGs; popovers are 848 × 952 px, alerts 520 × 564 px, and status-button content 138–140 × 44–46 px.
- A minimal `screencapture -x -R0,0,10,10` probe still returns `could not create image from rect`. Therefore menu-bar context, native window shadow/material, hover, and modal placement are not claimed as passed.
- The installed CoreSimulator is older than Xcode, but macOS builds succeed; no simulator is involved in this audit.

## Remaining follow-up

Grant Screen Recording to the audit host, then recapture the actual menu bar and composed popover/alert windows in light, dark, and Graphite appearances. Only after that evidence and a repeated resource comparison should the custom root surface be reconsidered.
