# WaifuClaw iOS

The iPhone companion app for WaifuClaw — your agent system in your pocket.
Phase 1: the phone is a remote for the WaifuClaw running on your own computer.
No hosted servers.

**Proprietary software.** Copyright (c) 2026 Willie Stewart / Phantom Horizons
Studios. All rights reserved — see `LICENSE`. This is not MIT-licensed and not
open source. (Per-component MIT attributions for any vendored third-party code
live in `THIRD-PARTY-NOTICES.md`.)

## Layout

- `WaifuClaw/` — SwiftUI source (XcodeGen project, see `project.yml`)
- `codemagic.yaml` — Mac cloud CI: unsigned compile check on every push/PR
- `.github/workflows/ios-compile-check.yml` — the same check on GitHub's Mac runners

## Building

No Mac needed for a compile check: push a branch and CI builds it unsigned.
Locally: `xcodegen generate`, then open in Xcode.

Signing and TestFlight need the $99/year Apple Developer Program membership —
not set up yet.

## Backend

The desktop app and backend live in `grimmjoww/WaifuClaw-Source` (private). The
iPhone app talks to it over the existing authenticated, TLS-pinned remote API.
