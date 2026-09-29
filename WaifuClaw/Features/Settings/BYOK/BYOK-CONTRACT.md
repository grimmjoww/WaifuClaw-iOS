# BYOK Contract — Bring Your Own Key (free tier)

**Status:** iOS side implemented · desktop side SPEC-NOT-IMPLEMENTED
**Version:** v1 · 2026-09-29
**Author:** API Platform Engineer (🔌)

This document is the source of truth for BYOK. The spec comes before the
implementation and is reviewed for decade-long livability — because a
published phone↔desktop contract is a promise we can't take back.

---

## 1. Mechanism decision

**Chosen: key-forwarding to the desktop over the pinned-TLS pairing connection.**

The iPhone stores the user's provider key in its Keychain, validates it
directly against the provider (immediate user feedback), then forwards it
once to the desktop via an authenticated, TLS-pinned device-channel
endpoint. The desktop stores it per-device (encrypted at rest) and uses it
as the model API key for agent runs originating from that device.

### Why not direct provider calls from the phone for chat?

In phase 1 the agent — tools, sandbox, memory, subagents, run engine —
lives on the desktop. If the phone called OpenAI/Anthropic directly it would
get a bare chat completion: no tools, no memory, no Kline operator context,
no run lifecycle. That reduces the phone to a dumb chat client and breaks
the phase-1 remote-control architecture. Direct provider calls from the
phone are used **only** for key validation (a single `GET /models`-style
probe), never for agent inference.

### Why not a third-party provider SDK on the phone?

The model-calling "SDK" that matters is the desktop's langchain-based model
factory (`deerflow.models.create_chat_model()`), which already speaks
OpenAI, Anthropic, Gemini, DeepSeek, and OpenAI-compatible endpoints. A
phone-side SDK would duplicate every provider integration and still could
not run the agent. No third-party dependency is justified for v1 — `URLSession`
covers the validation probe.

### Trust boundary

The desktop **never trusts the phone's validation result**. The phone
validates for UX (fast feedback); the desktop re-validates on receipt with
its own provider probe before marking the key active. The phone never sends
the key anywhere except the paired desktop over the pinned channel.

---

## 2. Provider registry (v1)

Provider ids match the desktop setup-wizard registry (`scripts/wizard/providers.py`)
— the desktop is authoritative. The phone carries a small affordance table
(display name, default model, key-format hint, validation probe); if the
desktop rejects an id with `byok_unsupported_provider`, the phone surfaces it
loudly instead of guessing.

| id | Display name | Default model | Key hint | Validation probe |
|----|--------------|---------------|----------|------------------|
| `openai` | OpenAI | `gpt-5` | starts with `sk-` | `GET https://api.openai.com/v1/models` + `Authorization: Bearer <key>` |
| `anthropic` | Anthropic | `claude-sonnet-4-20250514` | starts with `sk-ant-` | `GET https://api.anthropic.com/v1/models` + `x-api-key: <key>`, `anthropic-version: 2023-06-01` |
| `deepseek` | DeepSeek | `deepseek-reasoner` | starts with `sk-` | `GET https://api.deepseek.com/v1/models` + `Authorization: Bearer <key>` |
| `google` | Google Gemini | `gemini-2.5-pro` | starts with `AIza` | `GET https://generativelanguage.googleapis.com/v1beta/models` + `x-goog-api-key: <key>` |
| `openai_compatible` | Custom (OpenAI-compatible) | _(required from user)_ | any non-empty | `GET {base_url}/v1/models` + `Authorization: Bearer <key>` |

Rules:

- `model` is **optional** on save. Empty = desktop uses its configured default
  model for that provider (from `config.yaml`).
- `base_url` is **required** when `provider == openai_compatible`, forbidden
  otherwise (desktop rejects with `byok_bad_request`).
- Adding a provider later is **additive** (safe, no version bump). Renaming or
  removing a provider id is **breaking** (needs a versioned path + migration).

---

## 3. Phone → desktop contract (`/api/remote/v1`)

Auth, transport, and conventions are identical to the existing remote API:
`Authorization: Bearer <device-token>`, TLS-pinned session, JSON with
**snake_case** keys, ISO-8601 timestamps, machine-readable `code` +
human `detail` on errors (same shape as `pairing_code_expired`).
All routes 404 while `remote.enabled` is false.

### 3.1 Save / rotate key

```
POST /api/remote/v1/byok/key
```

Request:

```json
{
  "provider": "openai",
  "api_key": "sk-…",
  "model": "gpt-5",
  "base_url": null
}
```

- `provider` (string, required) — registry id, §2.
- `api_key` (string, required, min length 8) — the raw provider key.
- `model` (string, optional) — overrides the desktop default for this device.
- `base_url` (string, optional) — required iff `provider == openai_compatible`.

Response `200`:

```json
{
  "provider": "openai",
  "model": "gpt-5",
  "active": true,
  "validated": true,
  "last_validated_at": "2026-09-29T18:00:00Z"
}
```

Semantics: **upsert** — POSTing again rotates the key (idempotent on
`(device, provider)`). The desktop validates against the provider **before**
persisting; a failed validation persists nothing and returns the error.

### 3.2 Key status

```
GET /api/remote/v1/byok/status
```

Response `200` — metadata only, **the key is never returned**:

```json
{
  "configured": true,
  "provider": "openai",
  "model": "gpt-5",
  "active": true,
  "last_validated_at": "2026-09-29T18:00:00Z"
}
```

`configured: false` → all other fields absent/null. `active: false` means
"stored but currently failing" (e.g. provider started rejecting it) — the
phone prompts the user to re-validate, loudly.

### 3.3 Delete key

```
DELETE /api/remote/v1/byok/key
```

Response `200`: `{ "configured": false }`. Idempotent — deleting twice is fine.
Device revoke/unpair **cascades**: deleting the device row deletes its key row.

### 3.4 Future (not v1)

```
GET /api/remote/v1/byok/providers
→ { "providers": [{ "id": "openai", "display_name": "OpenAI", "default_model": "gpt-5" }, …] }
```

Lets the phone discover providers dynamically instead of its baked-in table.
Additive — safe to ship later inside v1.

---

## 4. Error semantics (all loud, per product law Q3)

| HTTP | `code` | Meaning | Phone message |
|------|--------|---------|---------------|
| 400 | `byok_unsupported_provider` | id not in the desktop registry | "Your computer doesn't support the {name} provider yet — update WaifuClaw on your computer." |
| 400 | `byok_bad_request` | e.g. `base_url` missing for `openai_compatible` | detail from server |
| 400 | `byok_key_invalid` | provider rejected the key (401/403 on probe) | "That key was rejected by {Provider}. Check it and try again." |
| 502 | `byok_provider_unreachable` | validation probe couldn't reach the provider | "Couldn't reach {Provider} to check the key — try again." |
| 429 | `byok_quota_exceeded` | provider rate-limited the probe | "That key is valid but {Provider} is rate-limiting — try again in a bit." |
| 404 | (existing) | desktop too old / remote disabled | "Your computer's WaifuClaw doesn't support phone key sync yet — update it." |

Error body shape (matches existing conventions):

```json
{ "code": "byok_key_invalid", "detail": "The key was rejected by OpenAI (401).", "provider": "openai" }
```

**No silent fallback, ever.** If no BYOK key is configured, the desktop
uses its own configured model (existing behavior — that is the documented
default, not a fallback to a key the user didn't provide). If a stored key
starts failing mid-run, the run's SSE error event carries
`code: byok_key_invalid` and the phone maps it to
`APIError.byokKeyInvalid(provider:)` → *"Your {Provider} key was rejected —
update it in Settings → API Key."* The user is never left wondering why the
agent stopped working.

### Phone-side validation mapping (direct provider probe)

| Probe result | Meaning | UI |
|--------------|---------|----|
| 200 | key valid | "Key valid" → forward to desktop |
| 401 / 403 | key rejected | inline error, key NOT saved, NOT forwarded |
| 429 | valid but rate-limited | warning state, still forwardable |
| network/timeout | couldn't reach provider | inline error "Couldn't reach {Provider} — check your connection." |

---

## 5. iOS security rules (non-negotiable)

- Key lives in **Keychain only** (`KeychainStore.byokAPIKey`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Never `UserDefaults`,
  never logs, never plaintext files, never in crash reports.
- Key travels only over the **TLS-pinned** device channel
  (`APIClient` with `TLSPinningDelegate`).
- The key is **never** included in `GET /status` responses, never logged
  by the phone, and the validation probe uses header auth (keys never in
  URLs — including Gemini, via `x-goog-api-key`).
- **Unpair wipes the key**: `KeychainStore.wipeAll()` deletes the BYOK
  account (already called by `AppState.unpair()`), and device revoke on the
  desktop cascades to the stored key.
- Inline format hints (`sk-…`) are hints only — validation is always the
  live provider probe, never a regex.

---

## 6. Desktop spec — SPEC-NOT-IMPLEMENTED

> The desktop backend does not implement this yet. This section is the
> precise build spec for the backend workstream. Nothing below exists in
> `backend/` today.

**Router** — new `backend/app/gateway/routers/byok.py`, prefix
`/api/remote/v1`, registered in `app.py` next to `remote_control.py`.
Reuse `_require_remote_enabled` and `_require_user` (device-bearer) patterns.

**Storage** — new table `device_api_keys`:

```sql
CREATE TABLE device_api_keys (
    device_id     TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    provider      TEXT NOT NULL,
    model         TEXT,                       -- null = desktop default
    base_url      TEXT,                       -- only for openai_compatible
    key_encrypted BLOB NOT NULL,              -- Fernet, machine-local key
    validated_at  TIMESTAMPTZ,
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

- Encryption key: machine-local, from the OS keyring (`keyring` lib) or
  `backend/.deer-flow/.byok-fernet-key` with `0600` perms — **never**
  `config.yaml`, never env passthrough, never logs.
- `devices` row delete cascades (unpair/revoke forgets the key server-side).

**Validation on receipt** — before persisting, the desktop probes the
provider itself (same endpoints as §2, 10s timeout, no retries on 401):
401/403 → `byok_key_invalid`; timeout/DNS → `byok_provider_unreachable`;
429 → store anyway with `active=true` but surface the quota warning in
`detail`. Never persist a key that failed validation.

**Run-time wiring** — when a run is created from a device bearer that has
an active `device_api_keys` row: build an in-memory overlay on the resolved
`ModelConfig` replacing only `api_key` (and `base_url` for
`openai_compatible`, and `model_name` if the row sets one). The overlay is
per-run, in-memory only — `config.yaml` is never rewritten. If the provider
call then fails with 401 mid-run: mark the row `active=false`, and surface
`code: byok_key_invalid` on the run's SSE error so the phone prompts loudly.

**Provider allowlist** — accept only ids present in the wizard
`LLMProvider` registry (`scripts/wizard/providers.py`); anything else →
`byok_unsupported_provider`. `openai_compatible` maps to the
`openai`-factory path with the stored `base_url`.

**Tests** (backend workstream owns): validation-probe mapping (401/429/
timeout), cascade delete on device revoke, overlay never touches
`config.yaml`, key never appears in `GET /status` or logs.

---

## 7. Willie's three questions

1. **Does it need a button or setting?** Yes — this *is* a setting:
   Settings → API Key (provider picker, key field, model override, save,
   delete). No orphan capability.
2. **Does the user see feedback?** Validate-on-save with visible phases
   (checking → valid → syncing → active), a persistent status row
   ("Active · OpenAI · gpt-5" / "No key saved"), pull-to-refresh on the
   screen, and inline errors. No silent spinners.
3. **Does it fail loudly?** Every failure is explicit: bad key, unreachable
   provider, quota, unsupported provider, desktop-too-old, key-rejected
   mid-run. Nothing falls back silently; nothing fails to a blank screen.

---

## 8. File map (iOS)

| File | Owns |
|------|------|
| `Features/Settings/BYOK/BYOK-CONTRACT.md` | this contract |
| `Features/Settings/BYOK/BYOKProvider.swift` | provider registry (phone affordance table) |
| `Features/Settings/BYOK/BYOKModels.swift` | request/response models, client error type |
| `Features/Settings/BYOK/BYOKViewModel.swift` | `@Observable @MainActor` state + actions |
| `Features/Settings/BYOK/BYOKSettingsView.swift` | Settings UI + `#Preview` |
| `Core/API/BYOKClient.swift` | provider validation probe + desktop sync client |
| `Core/Security/KeychainStore.swift` | **extended**: `byokAPIKey` account; `wipeAll()` widened |
| `Core/API/Endpoints.swift` | **extended**: `Remote.byokKey`, `Remote.byokStatus` |
| `Core/API/APIError.swift` | **extended**: `byokKeyInvalid(provider:)` case |
| `Features/Settings/SettingsView.swift` | **extended**: API Key section linking to `BYOKSettingsView` |
