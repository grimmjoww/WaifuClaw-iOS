# WaifuClaw code-checking workflow

Use **Xcode compilation and iPhone simulator tests** for behavior; use the MIT-licensed [Graft code graph](https://github.com/trailhq/Graft) to find Swift call sites and review a feature's blast radius. A graph edge or a plausible-looking screen is **not** evidence that an endpoint works.

The old `graft-ios/` graph was generated before the standalone phone runtime existed. It has been removed from version control: do not use or commit it. Graphs are regenerable local caches.

## Local structural graph (no model calls)

From the repository root, with Node.js available:

```sh
export DO_NOT_TRACK=1
export GRAFT_NO_GITIGNORE=1 GRAFT_NO_IGNORE=1
export GRAFT_GRAPH="${HOME}/.cache/waifuclaw-graft"

npx --yes @nanonets/graft@0.21.1 --dir "$GRAFT_GRAPH" build \
  --extensions .swift \
  --only-dir WaifuClaw --only-dir WaifuClawTests --only-dir WaifuClawUITests \
  --no-gitignore --no-ignore .

npx --yes @nanonets/graft@0.21.1 --dir "$GRAFT_GRAPH" map
npx --yes @nanonets/graft@0.21.1 --dir "$GRAFT_GRAPH" callers NativeGuardianAIReviewer.review
npx --yes @nanonets/graft@0.21.1 --dir "$GRAFT_GRAPH" blast --base origin/main --depth 1 --format markdown
```

`build` without `--deep` is deterministic tree-sitter indexing, with no model request or provider key. `DO_NOT_TRACK=1` opts out of anonymous telemetry, including npm-install telemetry. Do not run `graft init`, `graft trail push`, or `graft build --deep` as part of the project checking workflow: these may change agent configuration or send source context to a provider. The `--dir` option keeps generated graph files **outside the repository**.

Graft indexes source files in the checkout, including old desktop-pairing leaves deliberately excluded from the shipping target. For what actually ships, check the `WaifuClaw` target's explicit `sources` list in `project.yml`, then run `.github/workflows/ios-compile-check.yml` on macOS. CI must compile the actual target, execute XCTest/UI tests on a simulator, and inspect any failed test logs; an unsigned simulator result does not prove TestFlight signing, App Review acceptance, live third-party API interoperability, or all 63 upstream NeuralMemory tool contracts.
