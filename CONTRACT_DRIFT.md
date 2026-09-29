# CONTRACT_DRIFT.md — iOS ↔ backend contract ambiguities

Leaf 4 (iOS remote app) owns `ios/` only and never edits backend code.
This file is the ledger of every contract detail the app had to assume,
confirm, or work around. B1 (backend remote API) and B3 (licensing) own
the resolutions. Nothing here was "fixed" by changing the backend.

Status: ✅ confirmed · ⚠️ assumed (needs owner confirmation) · 🔍 resolved during build

## Pairing

- ✅ QR payload: `waifuclaw://pair?code=…&host=…&fingerprint=…` (confirmed with B2).
- ✅ Fingerprint encoding: 64-char lowercase hex SHA-256 of the leaf certificate
  DER. The app normalizes (strips colons/spaces, lowercases) before comparing.
- ⚠️ mDNS service type: the app browses `_waifuclaw._tcp`. B2 must advertise
  exactly this string or discovery finds nothing.
- ✅ Pairing exchange request: `{code, device_name, device_model}`
  → `POST /api/remote/v1/pairing/exchange`.
- ⚠️ Pairing exchange response: the app requires `device_token` and `user_id`;
  `device_id` is optional. If the backend never returns `device_id`, the
  Settings → Unpair flow can only wipe locally (server-side revoke is skipped).
- ✅ Pairing code expiry: HTTP 410 → the app shows the expired-code screen
  with regeneration guidance.
- ✅ Default port: **8001** when the QR/manual host has no port (matches the
  Gateway port in the repo's service topology).

## Chat streaming

- ⚠️ `POST /api/remote/v1/chat/stream` request shape assumed:
  `{thread_id, input: {messages: [{role, content}]}, stream_mode: ["messages","values"], on_disconnect: "continue"}`.
  B2 to confirm field names and valid `stream_mode` values.
- ⚠️ SSE event shapes assumed. The app extracts text deltas tolerantly from
  `{content}`, `{data:{content}}`, or `[{content}]` frames, and treats a frame
  whose content starts with the current text as cumulative (replace) rather
  than a delta (append). After every stream the app re-fetches thread messages,
  so the server stays the source of truth even if this heuristic is wrong.
  B2 to confirm the exact chunk schema.
- ✅ `Content-Location` response header carries the run id (used for
  best-effort server-side cancel on Stop).
- 🔍 Thread search resolved during build: `POST /api/threads/search` with
  `{metadata, limit, offset, status?}` → `[ThreadResponse]`
  (`thread_id, status, created_at, updated_at`). Verified against
  `backend/app/gateway/routers/threads.py`.
- ⚠️ Cancel-run response shape unknown: the app fire-and-forgets
  `POST /api/threads/{id}/runs/{rid}/cancel` and tolerates any JSON object.
- ⚠️ Wake response: the app expects `license` (a license-status object)
  embedded in the wake response to keep the Pro badge fresh. B2 to confirm.

## Memory

- ✅ Free-tier shapes verified against `backend/memory.py`:
  `GET /api/memory` → `{facts: [{id, content, category, confidence, createdAt, source, sourceError?}]}`;
  `POST /api/memory/facts` → `{content, category, confidence}`;
  `PATCH/DELETE /api/memory/facts/{id}`.
- ⚠️ Associative recall/retain shapes assumed:
  recall `{query, top_k?}` → `{results: [{content?, score?}]}`;
  retain `{content}`. B1/B3 to confirm.
- ✅ HTTP 402 from recall/retain → the app shows the Pro upsell (never silent).

## Licensing / IAP

- ✅ `GET /api/remote/v1/license/status` and `POST /api/remote/v1/license/activate`
  (`{key}`) verified against `backend/app/gateway/routers/license.py`.
  The iOS `LicenseStatus` mirrors `LicenseStatusResponse`
  (`tier, key_id, expires_at, device_limit, devices_used, features, reason, message, is_pro`).
- ⚠️ **IAP fulfillment: no backend support exists.** The app verifies the
  purchase on-device with StoreKit 2, then calls `license/activate` with key
  `"iap:<productID>:<transactionID>"`. This scheme is invented by the iOS leaf.
  **B3 must confirm or replace it** — until then, IAP purchases verify with
  Apple but may not unlock Pro on the desktop (the app says exactly this
  in the failure notice, with Restore as the retry path).
- ⚠️ StoreKit product IDs are placeholders
  (`studio.phantomhorizons.waifuclaw.pro.monthly` /
  `...pro.yearly`) — they must be created in App Store Connect and the
  bundle ID `studio.phantomhorizons.waifuclaw.ios` registered.
- ⚠️ WC1- inline validation in the app is prefix (`WC1-`) + minimum length
  only; the backend is the source of truth for format/signature/expiry.

## Connectivity

- ⚠️ Desktop-closed vs. unreachable is a client-side heuristic:
  transport-level `URLError`s → "can't reach" (LAN vs. tunnel message);
  a connection that establishes but yields no valid HTTP → "is the WaifuClaw
  app running?". B2 to confirm whether the desktop exposes a health signal
  the phone should prefer.
- ✅ Every 401 is inspected for revocation markers; the wake poll is the
  authoritative revoked-device detector.

## Not yet used by the app (future work, endpoints exist)

- `GET /api/remote/v1/pairing/devices` — device audit list (no UI yet).
- `POST /api/remote/v1/agent/stop`, `GET /api/remote/v1/agent/status` —
  agent controls beyond wake (no UI yet).
