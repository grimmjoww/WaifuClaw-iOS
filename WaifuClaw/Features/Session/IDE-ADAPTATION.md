# IDE Adaptation — the phone answer to mockup 3 (Native IDE)

Leaf 1.5.1 · 2026-09-29 · Mobile App Builder

## The question

Mockup 3 shows a full native IDE: file tree, code editor, terminal, tool
panels. Does that belong on a phone?

## Options considered

1. **Full IDE on the phone** (editor + file tree + terminal). Rejected:
   a phone is the wrong tool for editing agent-run code, and two of the
   panels had no real backend behind them (see below).
2. **Read-only session window** (chosen). The phone shows what's happening
   on the paired desktop — live output, skill activity — and never pretends
   to be a workbench.
3. **Defer the whole thing.** Rejected: the live run stream is real,
   useful, and cheap to show honestly.

## Recommendation

Ship the read-only session window (option 2). It is built at
`WaifuClaw/Features/Session/`:

- **Session list** — active/past sessions (runs), filterable, from the real
  runs endpoints via the shared `RunsData` seam.
- **Terminal card** — the run's stored event backlog plus the live SSE join
  stream, with an always-visible `Live` / `Connecting` / `Reconnecting` /
  `Paused` / `Ended` / `Offline` badge, Pause/Resume/Reconnect controls, a
  persisted per-session auto-scroll toggle, and loud Retry/Reconnect on
  failure.
- **Skills card** — real skill-execution receipts from
  `GET …/runs/{run}/skill-receipts` with Active / Needs attention / Done /
  Idle badges. Shown only when the backend has telemetry; otherwise the
  card says so.
- **Kline micro-row** — "I learn first, then I build."
- **Footer** — "Editing happens on your desktop — this is a window, not a
  workbench."

## What was deferred and why

- **File tree + file preview** (contract §8 item 2, GAP-03 `SessionFileRow`).
  Deferred: no backend endpoint lists a run's workspace files. The only
  file route (`GET /api/threads/{id}/artifacts/{path}`) fetches one file
  by exact path — there is no listing to build a tree from. Rendering a
  tree anyway would be fake data. If the backend ever gains a workspace
  listing route, the tree can be built honestly on top of it.
- **Phone code editor.** Deferred as phone-inappropriate by design (and it
  would need the file endpoint above). The footer says this out loud.
- **Syntax highlighting.** Deliberately absent — the terminal is plain
  mono text; fake highlighting is worse than none.
- **Invented "Tool Usage" categories** (Git/Browser/Terminal/Memory/IDE
  Tools from the mockup). Replaced with the real skill receipts above —
  the mockup's categories have no backend source.

## Product call

Minimal view (this document's scope) — per the contract §8 spec the leaf
was dispatched with. No Session tab ships from this leaf; leaf 1.6.1 wires
`SessionListView` into navigation and `SessionDetailView` behind the run
detail's "View session" link.
