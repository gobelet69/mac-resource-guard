# Resource Guard Visual Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Resource Guard's menu-bar popover consistently legible, selection-safe, sanitized for visual QA, and natively macOS without increasing background resource use.

**Architecture:** Preserve the compact AppKit hierarchy and semantic status model. Add a deterministic QA-scenario provider that feeds inert synthetic snapshots into the real UI, centralize adaptive status colors, add a lightweight selected-row state, and evaluate one root native material only after measurable and screenshot-verifiable evidence.

**Tech Stack:** Swift 5.10, AppKit, Core Animation, XCTest, Xcode Release builds, macOS screenshot/accessibility tooling.

**Spec:** `QA/reports/visual/2026-10-27-resource-guard-visual-audit.md`

## Global Constraints

- No QA scenario may enumerate, display, notify, or terminate a real user process.
- No release, push, distributable rebuild, or `/Applications` installation.
- Use one root visual effect at most; no nested blur, continuous animation, or decorative gradient.
- Preserve the fixed 424 × 476 pt popover and native SF typography.
- Capture every corrected state from the real Release application in both light and dark.

## Review Focus

- QA-only arguments must be inert outside explicit screenshot launches and impossible to route into process termination.
- Light and dark semantic badge colors must remain distinguishable in increased-contrast and reduced-transparency settings.
- Selection must remain visible when accent color is graphite and cannot rely on hue alone.
- Long names and large localized values must not collide with the metric or Quit columns.
- Accessory-app activation for screenshots must never steal focus during normal monitoring.

---

### Task 1: Add deterministic sanitized visual-QA scenarios

**Files:**
- Create: `Sources/MacResourceGuardCore/QA/VisualQAScenario.swift`
- Modify: `Sources/MacResourceGuardApp/AppDelegate.swift`
- Modify: `Sources/MacResourceGuardApp/UI/StatusBarController.swift`
- Modify: `Sources/MacResourceGuardApp/UI/PopoverViewController.swift`
- Modify: `project.yml` only if the generated Xcode project does not pick up the new source automatically.
- Modify: `Package.swift`
- Test: `Tests/MacResourceGuardTests/VisualQAScenarioTests.swift`

**Interfaces:**
- Produces: `VisualQAScenario` cases `normal`, `highCPU`, `memoryPressure`, `singleSelection`, `multipleSelection`, `notificationsEnabled`, `notificationsPaused`, `doNotDisturb`, and `forceQuitConfirmation`.
- Produces: sanitized `SystemSnapshot` values and inert `AggregatedAppProcess` fixtures named Aurora Editor, Northstar Browser, and Canvas Studio. Fixtures use invalid/non-routable process identifiers and the application-level QA mode disables every destructive action before a process lookup can occur.

- [ ] **Step 1: Write failing scenario tests**

Assert exact semantic severity, pressure kind, three sanitized app names, notification copy, and invalid/non-routable PIDs. Add an application-target test seam proving QA mode disables Quit and batch Quit before any process lookup; do not add a public fixture flag to the production process model.

- [ ] **Step 2: Verify RED**

Run the focused tests and confirm failure because the scenario provider and guard do not exist.

- [ ] **Step 3: Implement the minimal QA provider and launch routing**

Recognize only `--visual-qa-scenario=<case>`. Bypass live process sampling/notifications in that path, open the real popover, apply the synthetic snapshot, optionally set selection state, and activate the app only for capture. Production launch behavior remains unchanged.

- [ ] **Step 4: Verify GREEN and safety**

Run focused core tests plus the application test seam and full Release tests. Prove both invalid-PID rejection in `SafeAppTerminator` and disabled destructive UI actions in QA mode.

- [ ] **Step 5: Capture baseline scenario matrix in `/tmp`**

Export all non-modal states in light/dark. Keep raw evidence private until it contains only synthetic names and values.

### Task 2: Correct badge contrast and row-selection hierarchy

**Files:**
- Create: `Sources/MacResourceGuardCore/UI/ResourceStatusPalette.swift`
- Modify: `Sources/MacResourceGuardApp/UI/PopoverViewController.swift`
- Modify: `Sources/MacResourceGuardApp/UI/AppRowView.swift`
- Test: `Tests/MacResourceGuardTests/ResourceStatusPaletteTests.swift`
- Test: application-target selection-state tests configured through `project.yml`.

**Interfaces:**
- Produces: adaptive semantic foreground/background pairs for normal, elevated, and critical states.
- Produces: `AppRowView` selected appearance with both tint and border/checkbox cues.

- [ ] **Step 1: Write failing contrast and selection-state tests**

Convert the pure palette values to sRGB and assert at least 4.5:1 foreground/background contrast for the 11 pt badge in light and dark. In the application target, assert `configure(... isSelected: true)` exposes a selected accessibility value and a nonzero accent border while false restores the neutral state.

- [ ] **Step 2: Verify RED**

Confirm current system-color-on-tint pairs fail light contrast and rows expose no selected card state.

- [ ] **Step 3: Implement adaptive colors and static selection styling**

Use darker semantic foregrounds in light appearance and bright system-equivalent foregrounds in dark appearance. Apply a subtle accent fill plus 1 pt accent border to selected rows; disable implicit Core Animation actions.

- [ ] **Step 4: Verify GREEN and accessibility variants**

Run tests, then capture normal, elevated, critical, single-selection, and multiple-selection scenarios under light/dark plus increased contrast and graphite accent.

- [ ] **Step 5: Measure visual correction cost**

Repeat idle and open-popover CPU/footprint sampling. Expected: no measurable background change and no additional animation/wakeup source.

### Task 3: Validate one native popover material

**Files:**
- Modify: `Sources/MacResourceGuardApp/UI/PopoverViewController.swift`
- Modify: `QA/reports/visual/2026-10-27-resource-guard-visual-audit.md`

**Interfaces:**
- Produces: one root `NSVisualEffectView` with popover-appropriate material and automatic reduced-transparency fallback; cards remain opaque enough for text contrast.

- [ ] **Step 1: Capture real compositor baseline after Screen Recording access is available**

Capture the menu item and popover against controlled light and dark desktop backgrounds. If permission remains unavailable, leave this task BLOCKED and do not change the surface.

- [ ] **Step 2: Implement a single-root material spike**

Replace only the root custom fill. Do not add nested materials, motion, or shadows.

- [ ] **Step 3: Compare screenshots and resource measurements**

Accept the material only if contrast remains legible, reduced transparency has a solid fallback, and open-popover CPU/footprint does not materially regress. Otherwise revert the spike and document the custom surface as intentional.

### Task 4: Verify modal, notification, menu-bar, and final matrix

**Files:**
- Modify: `Sources/MacResourceGuardApp/AppDelegate.swift`
- Modify: `QA/reports/visual/2026-10-27-resource-guard-visual-audit.md`
- Add curated sanitized screenshots under: `QA/reports/visual/screenshots/2026-10-27/`

**Interfaces:**
- Consumes: inert visual scenarios from Task 1.
- Produces: actual runtime screenshots for every requested state without sending a notification or terminating a process.

- [ ] **Step 1: Add an inert modal presentation hook**

Factor alert construction from force-quit execution. The QA hook may present the real `NSAlert` for capture but has no confirm handler and no process identity.

- [ ] **Step 2: Capture the complete light/dark state matrix**

Capture menu bar normal/elevated/critical icons, normal/high-CPU/memory popovers, top three apps, one/multiple selection, force-quit confirmation, and notification enabled/disabled/paused/DND states.

- [ ] **Step 3: Check layout and interaction at 100% and 200% scale**

Inspect alignment, text clipping, focus rings, keyboard traversal, hover/pressed controls, status colors, shadow/material, and the longest fixture names and values.

- [ ] **Step 4: Run the final gate**

Run full SwiftPM/Xcode tests, Release build, visual scenario exports, and idle/open performance samples. Update every matrix row to PASS/WARN/BLOCKED with exact evidence.

- [ ] **Step 5: Review repository scope**

Confirm screenshots contain only synthetic data, no release/push occurred, no DMG or installed application changed, and the prior performance-audit files remain intact.
