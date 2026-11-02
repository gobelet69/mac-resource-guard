# Mac Resource Guard — Agent Instructions & Architectural Guidelines

## 1. Project Overview & Architecture

**Mac Resource Guard** is an ultra-lightweight native macOS menu bar resource monitor and process manager:
- **Language & Runtime**: Swift 6.0, SwiftUI, AppKit.
- **Architecture**:
  - `Sources/MacResourceGuardCore/`: Mach kernel telemetry (`host_statistics64`, `processor_info`), system-wide CPU tick calculations, memory pressure monitoring (`host_page_size`, active/inactive/wire/free pages), and process inspection.
  - `Sources/MacResourceGuardApp/`: Menu bar item (`NSStatusItem`), popover dashboard, per-process drill-down, and PID-reuse protection.
- **Distribution**: Non-sandboxed macOS application (required for Mach kernel APIs and process signals).
- **Brand Identity**: Emerald Phosphor (`#047857` / `#10B981` Light / `#34D399` Dark) and Controlled Turquoise.

---

## 2. Invariants & Safety Rules

1. **System Process Protection**:
   - Critical system daemons (`launchd`, `kernel_task`, `WindowServer`, `loginwindow`) must be strictly protected from process signals.
   - PID reuse protection: verify process start time before sending signals to prevent terminating a new process with a recycled PID.
2. **Minimal Overhead**:
   - Resource Guard must maintain near-zero idle CPU usage (< 0.5% CPU when polling).
   - Use CoreAnimation static level bars and monospaced digits; avoid continuous animations or heavy timers when popover is closed.
3. **iCloud Build Invariant**:
   - Always run tests and builds with a `/tmp` scratch path:
     ```bash
     swift test --scratch-path /tmp/mac-resource-guard-test
     ```
4. **Clean Code Signing**:
   - Strip extended attributes (`xattr -cr`) to prevent codesign detritus errors.

---

## 3. Verification Commands

Before submitting or committing changes:
```bash
# 1. Run automated Swift test suite (13 tests)
swift test --scratch-path /tmp/mac-resource-guard-test

# 2. Build Release Application Bundle
./Scripts/build.sh
```

---

## 4. Standards Reference

Refer to the shared DevKit standards in `../111iridescence-devkit/standards/`:
- `swift-macos.md`: Strict concurrency, AppKit/SwiftUI integration, `/tmp` scratch builds.
- `quality-gates.md`: Evidence-based release gates, zero P0/P1 issues.
- `brand.md`: Studio identity `111iridescence`, privacy constraints.
