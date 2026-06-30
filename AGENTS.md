# Laban

This repository builds a macOS terminal application. **It is post-MVP**: the
MVP shipped 2026-05-17, so `docs/product/mvp.md` is now a regression contract
(shipped behavior not to break), not a build target — its Non-Goals are the
post-MVP roadmap, not a ban list. New direction lives in `docs/product/spec.md`.

This file is the map. Keep it small. Open the deeper documents only when the
task matches them.

## First Moves

1. Start from the user's task and the files already in front of you.
2. Check `docs/product/mvp.md` as a regression contract — never break a
   behavior required there.
3. Check `docs/product/spec.md` before expanding product scope.
4. For non-trivial or cross-boundary work, create or update an ExecPlan using
   `PLANS.md`.

## Source Of Truth

- `docs/product/mvp.md` is the regression contract for shipped behavior; its
  non-goals and milestones are historical, superseded by `spec.md`.
- `docs/product/spec.md` is the long-term direction; new scope flows through it.
- Bug fixes, polish, performance, and refactors that preserve MVP behavior
  do not need spec.md approval.
- Do not add product behavior outside the product docs unless the user asks
  for it or it is required to keep an MVP behavior working.

## Read This When

| Open | When |
| --- | --- |
| `docs/product/mvp.md` | You are checking whether a change risks breaking shipped behavior. |
| `docs/product/spec.md` | You are expanding product scope or need long-term direction. |
| `docs/process/dev-process.md` | You are implementing or changing debug hooks, headless mode, screenshots, capture/replay artifacts, fixtures, CI E2E tests, or autonomous verification — or iterating on renderer perf with Instruments traces (§Metal Trace Perf Loop, `scripts/analyze-metal-trace`). |
| `docs/process/worktree-isolation.md` | You are adding run commands, artifact directories, temp dirs, debug ports, or multi-worktree execution support. |
| `docs/process/observability.md` | You are adding logs, debug events, metrics, traces, or failure artifacts. |
| `docs/reference/prototype-implementation-notes.md` | You need prototype lessons, known pitfalls, or reusable terminal-core behavior. |
| `docs/process/agent-operating-guide.md` | You need detailed engineering style, verification, changeset, or documentation rules. |
| `PLANS.md` | You are creating or updating an ExecPlan, or an existing ExecPlan has a Review Gate. |
| `execplans/` | The task names a plan, changes a planned feature, crosses major boundaries, or needs design history. |
| `schemas/` | You are changing debug endpoints, fixture formats, artifact metadata, or typed contracts. |
| `docs/quality/` | You are tracking drift, test gaps, debt, or quality gates. |
| `docs/adr/README.md` | A change touches the terminal library, PTY ownership, rendering architecture, SwiftPM target boundaries, or a decision that looks previously settled (the ADR index). |
| `docs/process/formal-specs.md` | You are changing a labpty state machine with a TLA+ spec in `specs/labpty/`, a CBMC proof or trace-conformance harness in `proofs/labpty/`, the MC/DC or mutation-adequacy gates (`coverage-labpty`, `check-{trace,cbmc}-mutants`), or a recent fix needs regression coverage. |
| `docs/process/rpg-graph-maintenance.md` | You are lifting or refreshing the `.rpg` semantic graph (`graph.json`), or wiring it into git worktrees. |

## Project Landmarks
Core maps: `README.md`, `PLANS.md`, `execplans/`, `docs/adr/`, `docs/quality/`.
Product and process truth: `docs/product/`, `docs/process/`, `docs/reference/`.
Debug contracts and data: `schemas/`, `fixtures/`.

## Build & Install

- `./scripts/build-app` builds the three products (`LabanApp`, `laband`, `labpty`)
  into `.build/laban/Laban.app` — debug by default (stripped, home-path scrubbed,
  ad-hoc signed). `--profile` makes it a release build and emits a `.dSYM` beside
  the bundle. Use this, not `swift build` (it also assembles the bundle).
- `./scripts/install-app` runs `build-app --profile` and replaces `~/Laban.app`
  (plus `~/Laban.app.dSYM`) in lockstep. This is how you refresh the installed
  app. `LABAN_INSTALL_DIR=/Applications scripts/install-app` targets elsewhere.
- Both stamp `Info.plist:LABANBuildCommit` with `<short-sha>[+dirty]`. A dirty
  *tracked* tree stamps `+dirty` — note that a regenerated `.rpg/graph.json` alone
  trips it. When a just-shipped fix "doesn't work", verify the running bundle's
  stamp matches HEAD before debugging source.
- Never `open`/launch the bundle from the shell: a windowless launch grabs the
  single-instance lock. Quit and relaunch Laban yourself to pick up a new build.
- The bundle sets `Info.plist:LSMultipleInstancesProhibited` (single-instance).
  So any relaunch that `open`s the bundle while the old process is still alive
  is a no-op — Launch Services re-activates the dying instance, then it quits and
  nothing respawns (the app "just quits"). In-process relaunch must wait for the
  current pid to exit *before* `open` (see `AppDelegate.relaunchCommand`).
- Don't run two builds (or two `scripts/check`/`build-app`) concurrently against
  the same worktree `.build/`: a competing `swift build` relinks the bundle binary
  *after* `build-app` ad-hoc-signs it, invalidating the signature so the
  codesign/smoke-runtime check fails spuriously. Run them serially, or confirm
  `pgrep -fl "swift build"` is empty first. (Most common when a review subagent
  and the main agent both run `scripts/check`.)

## Runtime Artifacts (where to look — don't re-search)

Under `~/Library/Logs/Laban/`:

- **PTY capture** — `captures/appkit-<UTC>/streams/`: `pty-output.bin` (child→terminal), `pty-input.bin` (keys), `terminal-response.bin` (Laban's replies back to the child — **confirm a responder fired here**: CPR/DA/kitty/OSC 10-11). Also `manifest.json`, `frames/`, `snapshots/`. Headless: `/debug` `startCapture` (`docs/process/dev-process.md`).
- **Asciinema cast** — `casts/laban-<UTC>-lastNs.cast` (`LABAN_CAST_DIR` overrides).
- **Tab-state journal** — always-on in-memory history of what each tab showed (title/status/selection/badge + banner notes), capture-clock timestamps. Query `GET /debug/tab-journal`, dump via Debug ▸ Dump Tab Journal (`tab-journal/` here), mirrored into capture `timeline.ndjson` as `tab.metadata`. First stop for "the badge/banner came late" questions.
- **Main-thread stall stacks** — `~/laban-watchdog/inproc-stall-*.txt`.

## Decision Index

Architecture decisions are catalogued in `docs/adr/README.md` — every ADR with a
one-line summary, plus when to write a new one. Read it before touching the
terminal library, PTY ownership, rendering architecture, SwiftPM target
boundaries, or any decision that looks previously settled.

## Worktree Setup

Git worktrees do not clone `.external/`; if missing, symlink it from the main repo:
`ln -s "$LABAN_MAIN_REPO/.external" .external`. It holds shared vendored libs.

`.rpg/graph.json` is a committed, generated artifact: the pre-commit hook keeps
structure current on every branch (do not strip those hunks from commits, and do
not set `skip-worktree` — it makes the hook's `git add` fail, blocking the
commit); `main` owns semantic refreshes (lifting). See
`docs/process/rpg-graph-maintenance.md`.

## Hard Rules

- The project must be autonomously verifiable. User-visible terminal behavior needs tests, debug-state checks, screenshot artifacts, or capture/replay artifacts.
- The debug/headless harness in `docs/process/dev-process.md` is product infrastructure, not optional polish.
- `HeadlessDebugRuntime` stays in feature parity with `MainWindowController.makeAndShow`. Wire new subsystems into both and expose HTTP endpoints. Move shared types from `LabanApp` down to `LabanCore` (no AppKit deps) so `LabanDebug` can reach them.
- Terminal session identity must survive tab selection, view rebuilds, resize, and UI refresh.
- Native text input wins over raw modifier interpretation.
- The renderer's per-frame encode/glyph-build path must not read `UserDefaults` or run CoreText/`CTLine` work per cell. Static glyph properties (e.g. color-ness) are decided once at rasterization and cached on the atlas entry; settings are cached and refreshed via their change notification, never polled per frame. (Regression bed1a2b: a per-cluster `CTLine` color scan cost +60–105 ms/frame while scrolling — guard it with `ColorGlyphScrollBench`.)
- Metal renderer instance data must be tested at live terminal scale, not only
  small/headless fixtures. Any renderer path that batches rect/glyph instances
  needs a regression exceeding Metal's 4 KB `setVertexBytes` inline limit and
  must use buffer-backed uploads when the batch is larger.
- Glyph/outline/atlas caches must key on **visual font identity** (PostScript
  name + point size + matrix + glyph), never `ObjectIdentifier(font)` — a CTFont
  address is reused, so address keys alias stale wrong-size entries. This was the
  "z is small, W is large" mixed-size zoom bug: `GlyphCurveStore` keyed on address
  and returned size-stale outlines. Guard with `GlyphCurveStoreInvalidateTests` /
  `VectorZoomGlyphSizeConsistencyTests`.
- A **self-presenting / decoupled present link** (a `CAMetalDisplayLink` that
  blits a published target on its own thread, ADR 0026) creates a "rendered but
  not shown" failure class the synchronous `present(drawable)` renderers cannot
  have. Two invariants: (1) every present path — including the fast/decoupled one
  — must honor `waitForFrameCompletion` (the live-resize/zoom no-mixed-frame
  guarantee silently no-ops otherwise); (2) the idle policy must not park the link
  while a freshly published frame is unpresented (else the initial frame and tab
  switches stay blank until the next keystroke — `PresentParkDecisionTests`). Do
  not drive zoom via a CALayer transform that races a self-presenting link; scale
  in the vertex projection instead.
- Extract present/idle/zoom **decision logic into pure, GPU-free value types**
  (e.g. `PresentParkDecision`) so the rule is unit-testable without a Metal
  device; the renderer just applies the decision. Provide test-only synchronous
  seams for debounced work (`debugFlushZoomCommit`) so timing-dependent gates stay
  deterministic without sleeping.
- For a renderer **visual artifact** ("glyphs wrong size", "blank", "mixed
  sizes"), build the diagnostic seam and MEASURE before theorizing a cause: the
  mixed-size bug was found only after adding `lastFrameQuadHeights` and reading it
  live via `/zoom/state`, after several wrong code theories. Per-`.ended` zoom
  commits stack into a multi-hundred-ms freeze — debounce to one bake on settle
  (`ContinuousZoomTests.testRapidInOutPinchFlurryCoalescesToOneCommit`).
- Keep changesets focused on one behavioral reason.
- Git commits are atomic. Commit messages are single-line reason statements: why the change exists, not what changed. Bad: `Update plans`. Good: `Agents need bounded execution shards`.

## Self-Improvement Loop

After completing a task, debugging an issue, or identifying a mistake, pattern, or gotcha: reflect on what was learned. If — and only if — it yields a durable, generalizable lesson, update this file (AGENTS.md) in the relevant section with the new rule, example, or guidance so future sessions inherit the improvement. Most tasks teach nothing new — skip the update rather than force one, and leave this file untouched on review-only or read-only tasks. Keep entries concise, concrete, and actionable. Prefer sharpening or merging an existing entry over appending a near-duplicate, and remove entries that no longer hold.
