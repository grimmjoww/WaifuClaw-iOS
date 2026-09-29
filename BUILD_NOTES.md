# BUILD_NOTES.md — WaifuClaw for iOS (Leaf 4)

## Environment honesty

This code was written on a Linux sandbox **without Xcode**. It has never
been compiled. Everything below is the complete, good-faith SwiftUI
implementation of the Leaf 4 contract; the Mac-side checklist at the bottom
is what stands between this source and a TestFlight build.

## What was built

`ios/WaifuClaw/` — a SwiftUI iOS 17+ app (iPhone, portrait):

| Area | Files |
|---|---|
| App shell, state, pairing lifecycle, wake poll | `App/AppState.swift`, `App/WaifuClawApp.swift` |
| Typed API client, SSE streaming, pairing client | `Core/API/APIClient.swift`, `PairingClient.swift`, `Endpoints.swift`, `Models.swift`, `APIError.swift` |
| Keychain token + fingerprint, TOFU pinning, QR parse | `Core/Security/KeychainStore.swift`, `TLSPinningDelegate.swift`, `PairingPayload.swift` |
| Theme (Phantom Horizons plum-black/magenta) | `Theme/Theme.swift` |
| Pairing: discovery, QR scan, confirm, mismatch warning | `Features/Pairing/` (5 files) |
| Chat: threads, streaming, states, stop | `Features/Chat/` (5 files) |
| Memory: free CRUD, Pro recall + 402 upsell | `Features/Memory/` (2 files) |
| License: status, WC1- activation, StoreKit 2 | `Features/License/` (2 files) |
| Settings: computer, connection, unpair, guidance | `Features/Settings/` (1 file) |
| Project config | `Info.plist`, `project.yml` (XcodeGen) |

## Static checks performed on Linux (2026-09-29)

- Every endpoint referenced exists in `Endpoints.swift`; every DTO field used
  exists in `Models.swift`; every `AppState`/`KeychainStore`/`TLSPinningDelegate`
  member referenced exists with a matching signature.
- Backend contract points re-verified against source: `POST /threads/search`
  body/response, `LicenseStatusResponse` fields, activate error codes,
  Gateway port 8001, and the absence of any IAP fulfillment endpoint.
- Brace/paren balance scanned across all Swift files.
- No file outside `ios/` was touched (no `backend/`, `frontend/`, packaging).

## Known non-verified items (need a Mac)

1. **Compilation** — first `xcodegen generate` + build will surface any typos
   the static pass missed.
2. **TLS pinning against the real desktop** — the SHA-256 leaf-cert comparison
   logic is written but untested against a live server.
3. **QR scan / mDNS discovery** — need a camera device and a desktop
   advertising `_waifuclaw._tcp`.
4. **StoreKit** — needs App Store Connect products + a `.storekit`
   configuration file for simulator testing (create in Xcode:
   File → New → StoreKit Configuration File, using the product IDs in
   `StoreKitManager.swift`), then sandbox testers.
5. **Background SSE behavior** — the run-continues state is implemented;
   real backgrounding needs device testing.

## Mac-side checklist

1. `brew install xcodegen`, then `cd ios && xcodegen generate`.
2. Open `WaifuClaw.xcodeproj` in Xcode 16+, set the development team
   (Apple Developer Program, $99/yr) for signing.
3. Create the `.storekit` config (see item 4 above) and attach it to the
   scheme for IAP testing.
4. `npx`-free: no JS tooling involved; pure Swift, no third-party deps.
5. Build to a physical device (camera + LAN don't work in the simulator
   for pairing; the simulator works for UI + StoreKit).
6. Confirm the IAP fulfillment protocol with B3 (see `CONTRACT_DRIFT.md`)
   before submitting — purchases currently assume the `iap:` key scheme.
7. TestFlight → App Store review (note: the app is a remote control for
   software on the user's own computer; no hosted backend in v1).

## Deliberate v1 limits

- iPhone only, portrait only. No iPad layout, no widgets, no push
  notifications (there is no relay server in Phase 1 by design).
- No on-device agent: the computer runs the engine; the phone is the remote.
- `appendingPathComponent` is used with leading-slash path constants
  (`"/api/…"`); Foundation handles this correctly (no double-encoding),
  verified by API contract review.
