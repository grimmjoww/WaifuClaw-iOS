<p align="center">
  <img src="./frontend/public/brand/kline-full-body-f493b31f.png" width="100%" alt="Phantom Horizons Studios — Kline brand art" />
</p>

<h1 align="center">WaifuClaw</h1>

<p align="center">
  <strong>A companion-first desktop agent workbench that does the work and shows the evidence.</strong>
</p>

<p align="center">
  <img alt="Desktop: Electron" src="https://img.shields.io/badge/DESKTOP-ELECTRON-ff2f9f?style=for-the-badge&labelColor=100b18" />
  <img alt="Interface: Next.js and React" src="https://img.shields.io/badge/INTERFACE-NEXT.JS_%2B_REACT-a855f7?style=for-the-badge&labelColor=100b18" />
  <img alt="Languages: TypeScript and Python" src="https://img.shields.io/badge/CODE-TYPESCRIPT_%2B_PYTHON-22d3ee?style=for-the-badge&labelColor=100b18" />
  <img alt="Platform: Windows" src="https://img.shields.io/badge/PLATFORM-WINDOWS-f472b6?style=for-the-badge&labelColor=100b18" />
</p>

<p align="center"><sub><strong>Private development · Paid desktop product · Windows-first</strong></sub></p>

WaifuClaw combines a persistent companion experience with long-running agent
work, skills, memory, team coordination, code intelligence, and governed
recovery. The product is being built by **Phantom Horizons Studios** as a
polished Windows desktop application rather than another thin chat wrapper.

> [!IMPORTANT]
> WaifuClaw is in private active development. Screens and capabilities must
> report their real build state; planned integrations are never presented as
> active before their adapters and verification paths exist.

## A companion that can actually act

<table>
  <tr>
    <td width="64%" valign="top">
      <h3>Why WaifuClaw exists</h3>
      <p>
        Most agent products either interrupt constantly or disappear behind a
        silent “autonomous” mode. WaifuClaw is designed for the middle that
        serious work needs: act within granted authority, narrate meaningful
        milestones, stop before consequential outward actions, and return
        evidence instead of a trust-me completion claim.
      </p>
      <p>
        The companion is not decorative chrome. She is the visible operator of
        a durable work system spanning skills, memory, teams, code intelligence,
        verification, recovery, and long-running goals.
      </p>
    </td>
    <td width="36%" align="center" valign="middle">
      <img src="./frontend/public/brand/kline-profile-afcbe711.png" width="300" alt="Kline, Phantom Horizons Studios mascot and WaifuClaw brand guardian" />
      <br />
      <sub><strong>Kline · Brand guardian and operator guide</strong></sub>
    </td>
  </tr>
</table>

## Product principles

- **Do the work without babysitting.** Long tasks should checkpoint, resume,
  recover, and return useful evidence.
- **Make skills visible.** The user can see which skill was selected, why it was
  used, whether it ran, failed, deviated, fell back, or was verified.
- **Fail honestly and improve.** Failure is evidence for recovery and learning,
  not something an agent should hide.
- **Every mutation has a recovery path.** Code work uses Git checkpoints;
  high-risk operations require an appropriate backup or rollback mechanism.
- **Companion-first, work-ready.** Kline and the user's chosen companion belong
  in the experience without compromising serious engineering workflows.
- **Freemium with a real license.** Free tier = bring-your-own model key +
  basic memory. Pro tier (associative memory / pro recall) is gated by
  offline-verified Ed25519 license keys (`WC1-…`) — no phone-home, ever.
  Every paid surface fails loudly: a Free user hitting a Pro endpoint gets a
  machine-readable `402` with an upsell card, never a silent empty result.

## Technology

| Layer | Current implementation | Build state |
| --- | --- | --- |
| Windows desktop | Electron 40 with `electron-builder` and NSIS packaging | Active foundation |
| Interface | Next.js 16, React 19, TypeScript, Tailwind CSS 4, Radix primitives | Active foundation |
| Agent service | Python 3.12+, FastAPI, LangGraph SDK, DeerFlow runtime | Active foundation |
| Verification | Rstest, Playwright, Pytest, ESLint, TypeScript, Hallmark gates | Active foundation |
| Native code workspace | CodeMirror 6 packages plus an approved clean-room behavior contract | Planned M5 surface |
| Product integrations | Custom Sage, Hermes components, ClawTeam, OpenViking, OutcomeRun | Milestone-gated; not claimed active |

## Current build

| Surface | Current state |
| --- | --- |
| Native Windows Electron launcher | Implemented and covered by launcher contracts |
| Companion workbench shell | Candidate implemented with exact Kline branding, responsive layouts, and dark/light themes; M1 verification is in progress |
| Chat, agents, skills, memory, and settings | Connected to the existing runtime surfaces |
| System truth rail | Implemented; unavailable capabilities remain visibly unavailable |
| Visible skill execution lifecycle | In progress |
| OutcomeRun and custom Sage evidence | Planned milestone |
| ClawTeam task/team board | Planned milestone |
| WaifuClaw native IDE | Clean-room behavior spec approved; implementation planned |
| OpenViking evolution and achievements | Planned milestone |
| Signed installer and commercial release | Not released |

## Roadmap

- [x] **M0 — Truthful product root:** reversible Electron launcher and honest
  capability registry.
- [ ] **M1 — WaifuClaw shell (verification in progress):** Kline brand system,
  Home, auth, responsive navigation, accessibility effects, About truth, and
  Hallmark visual gates.
- [ ] **M2 — Visible skills:** durable selected → loaded → invoked → running →
  completed/failed/deviated → verified/fallback receipts.
- [ ] **M3 — OutcomeRun + Sage:** durable objectives, candidate evidence,
  approval invalidation, investigated failure reasons, and recovery state.
- [ ] **M4 — ClawTeam:** dependency-aware Kanban, workers, inbox, presence,
  worktrees, and synthesis.
- [ ] **M5 — WaifuClaw IDE:** project tree, editor, search, symbols,
  references, diagnostics, terminal, tests, Git diff, and evidence-bound agent
  edits.
- [ ] **M6 — Memory and evolution:** OpenViking-backed recall, skill cognition,
  proposals, achievements, and complete settings surfaces.
- [ ] **M7 — Release candidate:** privacy scan, packaging, native smoke tests,
  rollback proof, signed distribution plan, and private release history.

The roadmap is a scope ledger, not permission to display fake telemetry. A
surface moves to complete only after its real adapter and acceptance checks
pass.

## Development quick start

### Requirements

- Windows 10/11 for the native desktop workflow
- Python 3.12+
- Node.js 22+
- `uv`
- `pnpm`

### Runtime setup

From the repository root:

```powershell
make setup
make dev
```

The setup wizard creates local configuration and keeps secrets outside source
control. Review `config.example.yaml` for optional providers, sandboxing, MCP,
channels, and model configuration.

### Desktop workflow

From `frontend/`:

```powershell
pnpm install
pnpm desktop:test
pnpm desktop:dev
```

Build an unpacked local candidate without installing it:

```powershell
pnpm desktop:pack
```

Freeze the Python gateway into a Nuitka onedir binary before packing
(required on Windows; `desktop:pack`/`desktop:dist` fail loudly without it):

```powershell
pnpm desktop:freeze
```

`desktop:dev`, `desktop:pack`, and `desktop:dist` must not rewrite the user's
global or per-user `PATH`. Production distribution still requires signing and
a final Windows install/upgrade/rollback validation pass.

## Verification

Use the smallest complete check for the changed surface:

```powershell
cd frontend
pnpm test
pnpm typecheck
pnpm lint
pnpm build
pnpm desktop:test
```

Rendered product changes also require the focused Playwright and Hallmark
responsive/interaction gates. Passing unit tests alone does not prove visual
quality.

## Architecture boundaries

| System | Product role | Current status |
| --- | --- | --- |
| **WaifuClaw** | Product identity, desktop UX, truth surfaces, governance, and release behavior | Current product layer |
| **DeerFlow** | Long-horizon runtime and frontend foundation | Current foundation |
| **Hermes Agent** | Personal-agent, provider, ACP, and tool components | Planned adapter work |
| **Custom Sage** | Process composition, evidence, correction learning, and approval boundaries | Approved design; M3 product integration planned |
| **ClawTeam** | Multi-agent team and Kanban coordination | M4 integration planned |
| **OpenViking** | Durable memory and skill cognition | M6 integration planned |
| **OutcomeRun** | Durable objective, evidence, and recovery lifecycle | M3 implementation planned |

### WaifuClaw IDE clean-room boundary

WaifuClaw IDE is an independent product surface built from permitted components
and neutral behavior requirements. The separate Hermes IDE implementation is
not copied, forked, or shipped as WaifuClaw source.

## Privacy and repository safety

- Never commit credentials, memory databases, personal conversations, local
  profiles, or machine-specific paths.
- Never push this private product branch to an unverified public remote.
- Generated candidates, backups, and test evidence stay outside distributable
  source unless deliberately sanitized and reviewed.
- Before a release checkpoint: privacy-scan the exact diff, verify remote
  visibility, then preserve the reviewed commit to the approved private remote.

---

**Phantom Horizons Studios** · A beautiful companion lives here, but serious
work happens here too.
