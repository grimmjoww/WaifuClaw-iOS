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

## Roadmap

**Now — Phase 1: phone as remote.** The iPhone app remote-controls the WaifuClaw
running on your own computer. No hosted servers.

- [x] SwiftUI app compiles on a real Mac (unsigned CI via Codemagic + GitHub Actions)
- [ ] Design adaptation — mockup designs become real SwiftUI (in progress)
- [ ] First-launch onboarding: intro pages, display name, iOS permission prompts
      (notifications, Face ID, local network)
- [ ] Pairing with the WaifuClaw desktop over the local network
- [ ] BYOK — bring your own provider key (free tier)

**Next:**

- [ ] Pro tier — associative memory / pro recall (paid)
- [ ] Monetization call: Apple in-app purchase vs web-issued license keys
- [x] Apple Developer Program membership ($99/yr, active since 2026-09-30)
- [ ] TestFlight beta
- [ ] App Store release

**Later:**

- [ ] Kline, the animated companion (sprite animation first, 3D down the road)
- [ ] Self-hosted servers — once the app earns its keep, the phone app becomes
      standalone and the desktop stops being required
