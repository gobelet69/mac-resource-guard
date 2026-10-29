# Resource Guard visual audit

**Date:** 2026-10-27  
**Mode:** Audit + Fix (baseline complete; remediation pending plan approval)  
**Status:** BLOCKED for compositor-level verification; WARN for captured application content

## Scope and safety

The Release application was built and launched from isolated derived data under `/tmp`. Four real AppKit popover views were captured in light/dark and application/background modes. Those raw captures remain in `/tmp` because they contain local process names and are not suitable for publication. No user application was terminated, no notification was sent, and no release was published.
Mass Print visual audit synthetic document: 01 Cover Mass Print visual audit synthetic document: 01 Cover Letter.txt
Letter.txt

The macOS screen-capture API returned `could not create image from rect`, and the accessibility/UI-control surface could not attach to this menu-bar-only application. Therefore the actual menu bar item, window shadow, compositor translucency, hover/focus state, and modal quit confirmation remain blocked rather than passed.

## Visual direction

Resource Guard should remain a compact native instrument rather than a decorative dashboard.

- **Palette:** system surface light `#F5F5F7`, system surface dark `#2C2C2E`, healthy `#34C759`, warning `#FF9F0A`, critical `#FF453A`, interaction `#0A84FF`; semantic adaptive foreground variants must meet contrast requirements.
- **Type:** SF Pro for labels and actions; monospaced SF digits only for changing measurements.
- **Layout:** left-aligned status hierarchy, two equal metric cards, one segmented filter row, three process rows, one batch-action row, one compact footer.

```text
┌ status icon  status title                  state ┐
│ status explanation                               │
├ CPU card ───────────┬ memory card ──────────────┤
├ category segments ──┴────────── sort segments ──┤
│ □ app                                       metric │
│ □ app                                       metric │
│ □ app                                       metric │
├ select all      hide system       quit selected ┤
└ Activity Monitor   Alerts   Settings   Quit Guard┘
```

The initial design review rejected adding an iridescent gradient or nested blur layers: they would dilute status meaning and increase rendering cost. The distinctive element remains the live, color-coded system state; everything else stays quiet and native.

## State matrix

| State | Light | Dark | Actual runtime evidence | Result |
|---|---|---|---|---|
| Menu bar icon | — | — | Screen Recording unavailable | BLOCKED |
| Normal popover | Captured | Captured | Real Release app, background-process view | PASS for content only |
| High CPU | Not safely reached | Not safely reached | No deterministic QA state exists | BLOCKED |
| Elevated memory pressure | Captured | Captured | Real kernel elevated state | PASS for content only |
| Top 3 applications | Captured | Captured | Real local process enumeration; raw files kept private | WARN, unsanitized |
| Application selection | Not captured | Not captured | No safe automation hook | BLOCKED |
| Multiple selection | Not captured | Not captured | No safe automation hook | BLOCKED |
| Quit confirmation | Not captured | Not captured | UI automation unavailable; no termination attempted | BLOCKED |
| Notifications disabled | Captured | Captured | Subtitle and footer action visible | PASS for content only |
| Notifications enabled/paused/DND | Not captured | Not captured | No deterministic QA state exists | BLOCKED |
| Window transparency/shadow | — | — | View export cannot verify compositor output | BLOCKED |
| Long application name | Captured | Captured | `1Password-Crash-Handler` fit without collision | PASS |
| Compact/responsive layout | Fixed 424 × 476 pt | Fixed 424 × 476 pt | Popover is intentionally non-resizable | PASS at designed size only |

## Confirmed findings

### P1 — Status badge contrast is insufficient in light appearance

The 11 pt semibold `Normal`, `Elevated`, and critical labels use their semantic system color over the same color at 16% opacity. Measured against the current popover surface, the foreground/background ratios are only 1.77:1 green, 1.84:1 orange, and 2.61:1 red in light appearance. Dark green and orange pass at 5.45:1 and 5.02:1, but dark red reaches only 3.67:1. These values are below the 4.5:1 target for small text. The palette needs adaptive, darker semantic foregrounds in light appearance and a corrected critical foreground in dark appearance.

Reproduction: launch with `--appearance=light --export-popover-png=...`; inspect the status badge at 100%.

### P1 — Selected rows have no row-level visual state

`AppRowView.configure(... isSelected:)` updates only the checkbox. The card background and border are identical for selected and unselected applications. This makes multi-selection difficult to scan and weakens confidence before a batch quit.

Expected correction: a subtle adaptive accent tint and border on selected rows, with no animation and no extra blur.

### P1 — Visual QA cannot produce sanitized deterministic states

Current screenshot hooks expose live process names, icons, process counts, and memory usage. They cannot render high CPU, critical memory, single/multiple selection, confirmation, or notification variants deterministically. Existing local screenshots must not be treated as publishable evidence.

Expected correction: explicit QA-only command-line scenarios that inject synthetic snapshots and inert sample applications, never enumerate private processes for curated captures, never send notifications, and never terminate a PID.

### P2 — The popover surface is nearly opaque custom drawing

`PopoverSurfaceView` draws a 96%-opaque fill and disables vibrancy. This is visually consistent in exported content but cannot demonstrate the requested premium native translucency. A single root `NSVisualEffectView` using the popover material would be more native than the custom surface, but it must be accepted only after real compositor screenshots and a before/after resource check. Nested effects are explicitly out of scope.

Rechecked on 2026-10-29 with a minimal 10 × 10 px `screencapture` permission probe: macOS still returned `could not create image from rect`. The material spike was therefore not implemented. The current custom surface remains intentional until compositor-level before/after evidence is available.

### P2 — Segmented selection is inconsistent in non-key capture

Some light captures show the selected segment only as a slightly darker gray while dark/key captures use the blue accent. The export hook shows the popover without reliably activating the accessory application, so it may be capturing AppKit's inactive control state rather than a product defect.

Expected correction: activate only in the explicit visual-QA launch path before capture. Do not force activation during normal background use.

## Checks that passed in captured content

- Two metric cards share height, internal baselines, corner radius, and padding.
- Process icons, names, secondary metadata, numeric columns, and Quit buttons align consistently.
- Long names truncate or fit without pushing the required metric/actions column.
- Normal, elevated, CPU, memory, and selection colors are not used decoratively outside their meaning.
- Dark-mode text, card borders, progress tracks, and secondary labels remain legible.
- The footer is dense but balanced at 424 pt; all five actions remain visible.
- No clipping, overlap, stale dirty rectangle, or font-smoothing box was visible in the four current captures.
- The current layer-backed bars/cards avoid per-frame custom drawing and implicit animation.

## Verification evidence

- Fresh Release build: `xcodebuild ... -configuration Release -derivedDataPath /tmp/mrg-visual-dd CODE_SIGNING_ALLOWED=NO build` → `BUILD SUCCEEDED`.
- Real runtime captures: `/tmp/mrg-visual-light-apps.png`, `/tmp/mrg-visual-dark-apps.png`, `/tmp/mrg-visual-light-background.png`, `/tmp/mrg-visual-dark-background.png` (848 × 952 px, private raw evidence).
- Badge contrast calculation: current semantic sRGB foreground over its 16%-tinted badge on the custom light/dark surface; light green 1.77:1, orange 1.84:1, red 2.61:1; dark green 5.45:1, orange 5.02:1, red 3.67:1.
- Controlled audit child processes exited or were signalled only by their recorded audit PIDs.

## Exit criteria

- Deterministic sanitized scenarios cover every requested state in light and dark.
- Badge foreground/background contrast is measured and passes for small text.
- Single and multiple selection are obvious without relying on color alone.
- Real Screen Recording captures verify the menu item, native popover shadow/material, modal confirmation, and notification states.
- Before/after CPU and footprint show no meaningful regression from visual effects.
- Release build and full test suite pass; no release or push occurs.
