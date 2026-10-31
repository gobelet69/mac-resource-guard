# Mac Resource Guard — Release Guard Check — 2026-10-30

## Final status: WARN

The application meets all internal functional, automated test, performance, and visual requirements for its initial v1.0.0 release. Publication remains blocked by external distribution requirements: no Apple Developer ID Application certificate or notarization credentials configured.

No release, tag, push, GitHub mutation, or website update was performed.

## Gates

| Gate | Result |
|---|---|
| `swift test` | PASS — 13 tests passed, 0 failed (0.008s) |
| Native AppKit compilation | PASS |
| Packaging (`dist/MacResourceGuard-1.0.0.dmg`) | PASS |
| `hdiutil verify` | PASS — valid checksum |
| Staged bundle `codesign --verify --deep --strict` | PASS (ad-hoc) |
| Performance audit (`QA/reports/performance/`) | PASS — idle CPU 0.01%, memory 15.4 MiB RSS, zero shell command overhead |
| Visual audit (`QA/reports/visual/`) | PASS — native status bar item, popover layout, dark/light dynamic vibrancy |

## Artifact Details

- DMG: `dist/MacResourceGuard-1.0.0.dmg`
- SHA-256: `ea8c3765e6494351c9f3c058b9ce5e5da3d8b324d80e83ed90e0c6fb0e9da770`
- Architecture: arm64
- Codesign: Ad-hoc (`-`) with hardened runtime
- Notarization: Not performed (credentials unavailable)

## Remaining Warnings

1. **P2 / WARN — Distribution signing**: Application is ad-hoc signed. Requires Apple Developer ID and notarization before macOS Gatekeeper will permit direct launch without user override.

## Decision

**WARN — verified locally; ready for release approval under ad-hoc distribution policy.**
