# Park the display link completely when the terminal is quiescent

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. This is Stage 2 of a two-stage idle-energy design; Stage 1
(cursor blink as an owned, settings-gated wake source) is the prerequisite
plan `execplans/active/cursor-style-and-blink-settings.md` — summarized in
"Prerequisite: the cursor-blink plan" below so this document stays
self-contained even if that file is not yet on disk.

## Purpose / Big Picture

Laban drives all terminal painting from a per-frame *display link* — a
vsync-aligned OS timer (`CADisplayLink` on macOS 14+) that calls
`TerminalBitmapView.advanceFrame()` in
`Sources/LabanApp/TerminalBitmapView.swift`. Today the link is parked
(paused) only when the window is unfocused or fully occluded. Whenever the
window is focused and visible, `TerminalIdlePolicy`
(`Sources/LabanCore/TerminalIdlePolicy.swift`) keeps the link ticking at an
8 Hz floor even when nothing on screen can change.

Measured cost of that floor on a focused, fully idle window (Instruments
Time Profiler, main thread, normalized to per-minute):

    advanceFrame total            ~90 ms/min, of which
      Session.snapshot              18.9
      AppModel.syncSurfaceMetadata  17.7
      Session.renderDirty           13.2
      RenderState.update            ~7.5
    updateDisplayLinkRunState      10.8
    main-runloop wake fixed cost  ~124 ms/min at 8 wakes/s

This plan is the last tier of a measured idle-energy effort. Earlier rounds
(event-driven transcript writer, batched idle counters, watchdog cadence)
took unfocused idle from 440 to ~150 ms/min and focused idle from 521 to
~400 ms/min. After this change:

1. **Full park.** The display link stops completely when the terminal is
   quiescent — no dirty output, no animation in flight, no cursor blink due —
   *even when the window is focused and visible*. Frame production becomes
   fully event-driven: every state change that can alter pixels wakes the
   frame loop explicitly.
2. **Tick-work gating.** The per-tick bookkeeping
   (`AppModel.syncSurfaceMetadata`, `Session.snapshot`,
   `Session.renderDirty`) becomes change-driven regardless of park state, by
   gating it on the session dirty-generation counter that already exists in
   the C core (`s->dirty_generation`, bumped by
   `laban_session_note_terminal_dirty` in
   `Sources/LabanTerminalCore/capture.c`).
3. **Animation budget.** Decorative animation (the breathing sidebar
   attention marker) runs the link at a budget rate (30 fps) instead of the
   maximum 120 fps. Smooth scroll keeps 120 fps.

Target: focused-idle main-thread CPU ≤ ~50 ms/min and ~0–2 idle wakeups/s
with cursor blink off (the Stage-1 default). Observable as: with the app
focused and a quiet shell prompt, the `IdleCounters` sidecar shows zero
`displayLinkTicks` deltas, `scripts/bench-idle-cpu` reports a lower CPU%,
and typing/output/scroll/tab-switch all still paint instantly.

## RISK: the frozen-frame failure mode (read this first)

The failure mode of this change is the **frozen-frame class — historically
this repository's worst bug family**. If any state change that should
repaint the screen fails to wake the parked link, the screen is permanently
stale: the PTY and terminal model advance while the user stares at an old
frame. Prior incidents and the tooling they produced:

- `execplans/active/gpu-render-freeze-journal-diagnostic.md` documents the
  GPU drawable-starvation freeze: an 8 ms drawable-acquire timeout left a
  "poison gate" set, and an immediate-retry loop amplified one slow drawable
  into bursts of 8–12 failed frames. It shipped `GPURenderFreezeDetector`
  (sampled by `sampleGPUFreezeDetector(...)` in
  `Sources/LabanApp/TerminalBitmapView.swift`, ~line 1843) and the
  auto-dump switch `LabanGPUFreezeJournalAutoDumpEnabled` /
  `LABAN_GPU_FREEZE_JOURNAL_AUTODUMP=1`.
- The **render journal** (`Sources/LabanApp/RenderJournal.swift`, enabled by
  the `LabanRenderJournalEnabled` user default) records per-frame decisions
  to `~/Library/Logs/Laban/render-journal/<timestamp>/entries.jsonl`. Each
  entry carries a `displayLink` snapshot (`kind`, `paused`,
  `preferredFramesPerSecond`, `reason`, `lastTickIntervalMs`) and a `window`
  snapshot with `visibleToUser`. This is the primary forensic tool for
  wake-coverage bugs.

A poll-with-floor design hides missed-wake bugs: at 8 Hz the next tick
repairs any staleness within 125 ms, invisibly. Full park removes that
implicit repair, so **every** wake source must be enumerated, wired, and
proven. The mitigations baked into this plan:

- **(a) Rollout parachute.** The 8 Hz visible-idle floor stays in the code
  behind the `LabanDisplayLinkIdleFloor` user default (bool). Default
  `false` = the new fully-parked behavior. `defaults write
  com.rrva.Laban LabanDisplayLinkIdleFloor -bool YES` + relaunch instantly
  restores today's behavior with no rebuild. The flag is read at policy
  evaluation time (cached at view init is acceptable; relaunch applies it).
- **(b) Wake-coverage validation.** Milestone 2 lands a wake-source audit
  table (below), per-wake instrumentation (`wakeSource` tag on journal
  entries), unit tests per wired source, headless E2E runs through the
  dev-process harness (`docs/process/dev-process.md`,
  `scripts/run-debug-script`, `scripts/test-e2e`), and capture/replay
  checks — all green **before** the park policy in Milestone 3 turns on.
- **(c) Safety-net poll.** A temporary 1/30 s low-frequency check runs while
  the link is parked. If it finds a session whose dirty generation advanced
  past the last-rendered generation with no frame produced, it (1) calls
  `advanceFrame()` to repair the screen and (2) logs
  `render.displayLink.safetyNetRepair` to `EventLog` and the render journal
  as a bug signal. Every such event is a missed wake to root-cause. The
  safety net is removed by a follow-up commit only after the soak criteria
  in Milestone 5 are met.

## Progress

- [ ] Milestone 1: dirty-generation accessor + tick-work gating
      (independently shippable).
- [ ] Milestone 2: wake-source audit complete; missing wakes wired;
      per-wake instrumentation and tests green.
- [ ] Milestone 3: full-park policy in `TerminalIdlePolicy` + plumbing,
      `LabanDisplayLinkIdleFloor` parachute, safety-net poll, ADR 0018.
- [ ] Milestone 4: animation budget rates (attention 30 fps).
- [ ] Milestone 5: soak validation (render journal, bench, Instruments,
      E2E), safety-net removal criteria evaluated.
- [x] (2026-06-10) Plan authored after source research; no implementation
      started.

## Decision Log

These decisions are already settled with the product owner; do not re-open
them without recording a superseding entry here.

- Decision: Park the link fully even when the window is focused and visible.
  Rationale: trace evidence shows the visible-idle 8 Hz floor costs
  ~110 ms/min of main-thread CPU plus ~124 ms/min of runloop wake overhead
  for zero visible benefit; the push path already paints occluded windows
  without a link. Stage 2 of the agreed two-stage idle-energy design.
  Date/Author: 2026-06-10 / settled with product owner.
- Decision: Keep the 8 Hz floor behind `LabanDisplayLinkIdleFloor`
  (default off = parked) instead of deleting it.
  Rationale: instant, no-rebuild rollback for the frozen-frame risk class.
  Date/Author: 2026-06-10 / settled with product owner.
- Decision: Attention "breathing" pulse animates at 30 fps, not 120 fps.
  Rationale: `AttentionPulse.period` is 1.5 s (a raised-cosine breath,
  `Sources/LabanCore/TabAttention.swift`); 30 fps gives 45 samples per
  breath — visually smooth — at a quarter of the energy. Smooth scroll keeps
  120 fps because finger-tracking latency is user-perceivable.
  Date/Author: 2026-06-10 / settled with product owner.
- Decision: Gate tick work on the existing C `dirty_generation` counter via
  a new exported accessor, rather than Swift-side bookkeeping.
  Rationale: the counter is already bumped at every terminal-content
  mutation (VT write, resize, replay, viewport scroll — see audit in
  Context) under the session lock; one `uint64` read replaces the
  `renderDirty`/`snapshot`/metadata cluster on quiescent ticks.
  Date/Author: 2026-06-10 / Claude.
- Decision: Child-exit detection bumps the dirty generation, and
  `SessionRunner` fires `onDirty` on generation change rather than only on
  `drained > 0`.
  Rationale: today an exiting child that emits no trailing bytes never fires
  `onDirty` (`Sources/LabanCore/SessionRunner.swift` line ~75 fires only
  when `drained > 0`; the exit branch in
  `Sources/LabanTerminalCore/pty_io.c` `laban_session_drain_locked_` sets
  `s->status` without noting dirty). The 8 Hz floor currently hides this;
  full park would freeze the "process exited" UI. One counter becomes the
  single currency for both gating and waking.
  Date/Author: 2026-06-10 / Claude.
- Decision: While parked, per-tab metadata freshness (foreground process,
  git branch dot) becomes event-driven; a quiescent tab's metadata may lag
  until the next wake or safety-net tick.
  Rationale: practically every user-visible metadata change arrives as
  terminal bytes (OSC title, OSC 7 cwd, OSC 133/agent status) and therefore
  bumps the generation; the residual cases (background git refresh,
  foreground-process change without output) are wired as explicit wakes in
  Milestone 2. Accepted trade.
  Date/Author: 2026-06-10 / settled with product owner.
- Decision: Write ADR 0018 for this change.
  Rationale: this reverses the settled poll-with-floor frame-driving
  architecture (the link as a guaranteed periodic repaint) in favor of
  event-driven frame production with the link as a transient animation
  timer. That is a durable architectural policy reversal, which is exactly
  what `docs/adr/README.md` says warrants an ADR.
  Date/Author: 2026-06-10 / Claude.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan
done until this gate has passed. Run all commands from the repository root
(the worktree being reviewed). Checks are per-milestone where marked; the
final review runs all of them.

- [ ] `rtk swift test --filter TerminalIdlePolicyTests` exits 0 with
      0 failures and executes **at least 14** tests (9 pre-existing + the
      new park/budget/floor tests named in Milestone 3/4).
- [ ] `rtk swift test --filter TerminalSurfaceControllerTests` exits 0 with
      0 failures, including a test whose name contains `Generation` proving
      unchanged-generation ticks skip metadata sync.
- [ ] `rtk swift test --filter SessionRunnerTests` (or
      `LabanSessionTests` if placed there) exits 0 and includes a test whose
      name contains `ExitWakes` proving a zero-output child exit fires
      `onDirty`.
- [ ] `rtk swift test --filter TerminalBitmapViewWakeTests` exits 0 with
      0 failures.
- [ ] `grep -n "laban_session_dirty_generation"
      Sources/LabanTerminalCore/include/LabanTerminalCore.h` — at least one
      hit (the new exported accessor).
- [ ] `grep -rn "LabanDisplayLinkIdleFloor" Sources/` — hits in both the
      policy input plumbing (`Sources/LabanApp/TerminalBitmapView.swift`)
      and exactly one place that reads `UserDefaults`.
- [ ] `grep -n "note_terminal_dirty"
      Sources/LabanTerminalCore/pty_io.c` — at least one hit inside the
      child-exit branch of `laban_session_drain_locked_`.
- [ ] `grep -n "drained > 0" Sources/LabanCore/SessionRunner.swift` — the
      `onDirty` firing condition is no longer solely `drained > 0` (either
      the grep has zero hits, or the surrounding code also fires on a
      generation change; quote the lines in findings).
- [ ] `grep -n "safetyNetRepair" Sources/LabanApp/` recursively — at least
      one hit (EventLog kind) — UNLESS the Progress section shows the
      safety net was already removed post-soak, in which case verify the
      removal commit is referenced in `Outcomes & Retrospective`.
- [ ] Mutation check (wake coverage): in
      `Sources/LabanApp/TerminalBitmapView.swift`, comment out the single
      wake call added at the end of `override func scrollWheel` (Milestone 2
      names it; it reads `advanceFrame(wake: .scrollWheel)` or equivalent).
      Run `rtk swift test --filter TerminalBitmapViewWakeTests`; expect at
      least one failure. Revert the mutation. Confirm
      `git diff --stat` is empty afterwards.
- [ ] `ls docs/adr/ | grep 0018` — one file; and
      `grep -c "0018" docs/adr/README.md` ≥ 1 (index entry added).
- [ ] `./scripts/test-e2e` exits 0.
- [ ] `rtk ./scripts/check` exits 0 (full repository gate).
- [ ] `grep -n "idleDisplayLinkFramesPerSecond = 8"
      Sources/LabanCore/TerminalIdlePolicy.swift` — still present (the
      floor constant must survive for the parachute path).

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Context and Orientation

Definitions used throughout (plain language):

- **Display link**: a vsync-aligned OS timer. On macOS 14+ Laban uses
  `CADisplayLink` created in `startDisplayLink()`
  (`Sources/LabanApp/TerminalBitmapView.swift` ~line 782) with
  `CAFrameRateRange(minimum: 8, maximum: 120, preferred: <policy>)`; its
  target is `displayLinkTick`, which calls `advanceFrame()`. Older macOS
  falls back to `CVDisplayLink`, which cannot be cheaply paused and is out
  of scope: the fallback keeps today's behavior (see "Interfaces").
- **Park**: setting `CADisplayLink.isPaused = true`. Done today in
  `updateDisplayLinkRunState()` (~line 967) when
  `TerminalIdlePolicy.displayLinkShouldRun(windowVisibleToUser:scrollAnimating:)`
  returns false — i.e. only when unfocused/occluded and not mid-scroll.
- **Wake source**: any code path that calls `advanceFrame()` (directly or
  via `TerminalDisplayKickCoalescer.requestFrameAdvance`,
  `Sources/LabanApp/TerminalDisplayKickCoalescer.swift`) so a parked link
  still produces a frame. `advanceFrame()` ends with
  `defer { updateDisplayLinkRunState() }` (~line 1148), so a single wake
  that starts an animation (scroll, output hold, attention) automatically
  un-parks the link for the animation's duration. This defer-reconcile
  machinery is proven: it is exactly how occluded windows paint today.
- **Dirty generation**: `uint64_t dirty_generation` on the C session struct
  (`Sources/LabanTerminalCore/session_internal.h` lines 261–262), bumped by
  `laban_session_note_terminal_dirty()`
  (`Sources/LabanTerminalCore/capture.c` lines 65–71; wraps past 0 to 1).
  Verified bump sites (all terminal-content mutations):
  - VT write path (`capture.c` line 62 — every drained PTY byte chunk),
  - resize (`session_lifecycle.c` ~line 767),
  - replayed output (`session_lifecycle.c` ~line 814),
  - viewport scroll, delta and scroll-to-bottom (`snapshot.c` ~lines
    790–802 and 820–831).
  It is **not** currently exported to Swift: the only exported dirty API is
  `laban_session_render_dirty` (`Sources/LabanTerminalCore/include/
  LabanTerminalCore.h` line 268), which queries libghostty render state
  under the session lock — one of the per-tick costs we are eliminating.
- **Render journal**: opt-in per-frame decision log
  (`Sources/LabanApp/RenderJournal.swift`), enabled via the
  `LabanRenderJournalEnabled` user default. Dumps land under
  `~/Library/Logs/Laban/render-journal/<timestamp>/` as `summary.json` +
  `entries.jsonl` (+ `current-frame.png`). Entries already include
  `displayLink.paused`, `displayLink.reason`, and `window.visibleToUser`.
- **Headless harness**: `HeadlessDebugRuntime`
  (`Sources/LabanDebug/HeadlessDebugRuntime.swift`) serves the `/debug` HTTP
  API described in `docs/process/dev-process.md`. It has **no display
  link**: frames are produced on demand by `renderFrameUnlocked()` (~line
  665), which calls the same
  `TerminalSurfaceController.syncSessions(...)` with
  `polling: .pollAllSessions`. E2E scenarios run via
  `scripts/run-debug-script` and `scripts/test-e2e`.
- **IdleCounters**: low-cardinality counters
  (`Sources/LabanApp/IdleCounters.swift`) enabled by
  `LABAN_IDLE_COUNTERS=1` (or the `LabanIdleCountersEnabled` default),
  writing per-second snapshots of `displayLinkTicks`, `advanceFrames`, etc.
  to `~/Library/Logs/Laban/idle-counters.jsonl`.

How a frame is produced today (`advanceFrame()`, ~lines 1135–1412):

1. `surfaceController.syncSessions(captureFrame:polling:.none, ...)`
   (`Sources/LabanCore/TerminalSurfaceController.swift`, `syncSessions`
   ~line 379): for **every** tab it calls
   `AppModel.syncSurfaceMetadata(...)` (`Sources/LabanCore/AppModel.swift`
   line 1257 → `TabMetadataSynchronizer`) and `session.renderDirty()`. This
   is the per-tick cost cluster.
2. Window title sync, focus reporting, cursor-blink phase
   (`advanceCursorBlinkState`, 0.5 s interval, gated on visibility),
   smooth-scroll PD controller, remote (laband) snapshot generation check,
   synchronized-output and output-settle render gates (which schedule
   `scheduleOutputSettleWake` ~line 863 / are retried by
   `scheduleRenderRetry` ~line 873 — both one-shot direct `advanceFrame()`
   calls), attention classification
   (`TabAttentionClassifier.anyNeedsAction`,
   `Sources/LabanCore/TabAttention.swift`).
3. Early return when nothing changed (guard at ~line 1398), else render.
4. `defer { updateDisplayLinkRunState() }` reconciles pause state and
   preferred rate from `displayLinkPolicyState()` (~line 988), which feeds
   `TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(...)`:
   120 fps while `scrollAnimating || attentionAnimating ||
   terminalOutputActive` (output hold = 150 ms,
   `terminalOutputDisplayLinkHoldSeconds` at line 186), else 8 fps; paused
   only when not visible and not scrolling.

The push path that already exists (and already paints occluded windows):
per-session reader threads (`SessionRunner.start()` loop,
`Sources/LabanCore/SessionRunner.swift` lines 69–81) call
`laban_session_poll_blocking`, and when `drained > 0` fire `onDirty` →
`SessionRegistry.onSessionDirty` (`Sources/LabanCore/SessionRegistry.swift`
lines 64–73) → `AppModel.onSessionDirty` (`AppModel.swift` line 56) → the
view's coalescer → `advanceFrame()` on main
(`TerminalBitmapView.swift` lines 402–406). On the laband tier, the
equivalent push is `startLabandSnapshotGenerationMonitor` (lines 704–711).

### Prerequisite: the cursor-blink plan

`execplans/active/cursor-style-and-blink-settings.md` (Stage 1) delivers,
in summary (this is the contract this plan relies on; if that file is
absent or unimplemented, treat the fallback below as binding):

- Cursor blink becomes a user setting, **off by default**.
- When blink is enabled, the blink phase is driven by an **owned ~2 Hz
  one-shot wake** (a timer that calls `advanceFrame()` when the next toggle
  is due, armed only while the window is visible and key) — not by the
  display link's idle floor.

Fallback if implementing before Stage 1 lands: keep the link running at
8 fps whenever the rendered cursor is blinking
(`lastRenderedCursorBlinking`, set from the snapshot at
`TerminalBitmapView.swift` ~line 1524) and the window is visible. The park
policy input `cursorBlinkActive` (Milestone 3) carries this; once Stage 1
lands, the blink timer owns the wake and `cursorBlinkActive` is fed `false`
when the setting is off (the default), which is what achieves the
0–2 wakeups/s target.

## Wake-Source Audit Table

Every row must end Milestone 2 as "exists+proven" or "wired+proven", where
proven = a unit test or E2E assertion fails if the wake is removed, or
(rows marked *journal*) a recorded `wakeSource` tag observed in a live
render-journal session. File references verified 2026-06-10; re-verify line
numbers before editing.

| # | Source | Mechanism | Where | Status |
|---|--------|-----------|-------|--------|
| 1 | PTY output (child output, key echo, OSC title/status/notification bytes) | reader thread → `onDirty` → `AppModel.onSessionDirty` → coalescer → `advanceFrame` | `SessionRunner.swift:69-81`, `SessionRegistry.swift:64-73`, `TerminalBitmapView.swift:402-406` | exists (proven machinery — paints occluded windows today) |
| 2 | laband snapshot generation (remote tier) | `LabandSnapshotGenerationMonitor` → coalescer → `advanceFrame` | `TerminalBitmapView.swift:704-711` | exists |
| 3 | Keyboard input | `keyDown` writes to PTY; echo rides #1, but no-echo cases (echo off, app ignoring keys) and blink-phase reset get no wake | `TerminalBitmapView.swift:2607` (`keyDown`) | **needs wiring**: kick at end of `keyDown` |
| 4 | Scroll wheel | `scrollWheel` sets `targetScrollRows` + `renderInvalidated` and returns; relies on the running link to start the glide | `TerminalBitmapView.swift:~3607-3675` | **needs wiring**: kick at end of `scrollWheel`; the first frame sets `scrollAnimating`, whose defer-reconcile un-parks the link at 120 fps until the PD controller settles |
| 5 | Tab switch / open / close (sidebar click, Cmd-digit, menus, debug endpoints) | `model.selectTab` etc. mutate the model; today the next 8 Hz tick notices `tabChanged` | `AppModel.swift:924` (`selectTab`), view entry points `TerminalBitmapView.swift:2359-2428` | **needs wiring**: model-level hook (see Milestone 2) so *all* mutation entry points wake, not just view-local ones |
| 6 | Focus / occlusion | `didBecomeKey` → `advanceFrame`; `didResignKey` → `updateDisplayLinkRunState`; occlusion change → `advanceFrame` | `installWindowFocusObservers`, `TerminalBitmapView.swift:713-739` | exists |
| 7 | One-shot render gates | `scheduleOutputSettleWake` (output-settle defer) and `scheduleRenderRetry` (theme/renderer-switch/backpressure) call `advanceFrame` directly | `TerminalBitmapView.swift:863-881` | exists — these MUST remain direct calls; with a parked link they are the only continuation after a deferred frame |
| 8 | Attention transitions carried by output (OSC 133 / agent status / notifications) | bytes bump generation → row #1 | `tab_status.c`, `osc133.c`, `osc_host.c` | exists via #1 |
| 9 | Model metadata written off the output path (background git-branch resolution, daemon surface signals, agent status updates) | `applyResolvedBranch` (`AppModel.swift:1869`), `applySurfaceSignals` (`AppModel.swift:~1290`) write tabs with no wake; today the floor repaints | `AppModel.swift` | **needs wiring**: fire the Milestone-2 model hook from these mutation sites |
| 10 | Child exit with no trailing bytes | exit branch in `laban_session_drain_locked_` sets `s->status` only; runner fires `onDirty` only when `drained > 0` | `pty_io.c:135-171`, `SessionRunner.swift:75` | **needs wiring**: bump generation on exit transition; runner fires on generation change (Milestone 1+2) |
| 11 | Cursor blink | Stage-1 owned ~2 Hz one-shot wake while enabled+visible (default off); fallback: link runs at 8 fps while `cursorBlinkActive` | prerequisite plan; `TerminalBitmapView.swift:293,1120-1133,1524` | dependency (see Prerequisite section) |
| 12 | Theme change | observer → `scheduleRenderRetry` | `TerminalBitmapView.swift:370-382` | exists |
| 13 | Reduce Motion change | observer sets `renderInvalidated = true` only; today repaired by the floor | `TerminalBitmapView.swift:387-393` | **needs wiring**: add `scheduleRenderRetry()` |
| 14 | Find, selection, renderer switch, live-resize frames | direct `advanceFrame()` calls | `TerminalBitmapView.swift:2586,2893-2986,3145` | exists |
| 15 | Tracked-mouse drag autoscroll | dedicated 20 Hz `Timer` pump, link-independent | `TerminalBitmapView.swift:4649-4656` | exists |
| 16 | Capture indicator / window-title updates | computed inside `advanceFrame`; inputs all arrive via rows above | `TerminalBitmapView.swift:1174-1180` | covered |

Audit closing rule (Milestone 2): sweep every `renderInvalidated = true`
assignment in `Sources/LabanApp/TerminalBitmapView.swift` (`grep -n
"renderInvalidated = true" Sources/LabanApp/TerminalBitmapView.swift`).
Each site must either (a) be inside `advanceFrame()`'s own flow, or (b) be
followed by a wake (`advanceFrame()`/`scheduleRenderRetry()`/coalescer
kick). Convert stragglers to a new private helper
`invalidateRenderAndWake()` so future sites cannot regress silently.

## Plan of Work

### Milestone 1 — Tick-work gating via dirty generations (shippable alone)

Goal: a focused-idle trace stops showing the
`syncSurfaceMetadata`/`snapshot`/`renderDirty` cluster, while the link still
ticks at 8 Hz. No park behavior changes. This milestone is independently
shippable and valuable even if the rest is delayed.

1. **Export the counter.** In
   `Sources/LabanTerminalCore/include/LabanTerminalCore.h` declare
   `int laban_session_dirty_generation(LabanSession *session,
   uint64_t *out_generation);` (style matches
   `laban_session_render_dirty` at line 268). Implement in
   `Sources/LabanTerminalCore/capture.c` next to
   `laban_session_note_terminal_dirty`: take `SESSION_LOCK(s)`, write
   `s->dirty_generation`, return 0 (−1 on NULL).
2. **Bump on exit.** In `Sources/LabanTerminalCore/pty_io.c`, inside
   `laban_session_drain_locked_`'s exit branch (lines ~156–166, where
   `waitpid` sets `s->status`), call `laban_session_note_terminal_dirty(s)`
   when `s->status` transitions from 0 to nonzero. This makes "child
   exited" a generation event — the single currency for gating and waking.
3. **Swift accessor.** In `Sources/LabanCore/Session.swift` add
   `public func dirtyGeneration() -> UInt64` beside `renderDirty()`
   (~line 589), returning 0 on failure.
4. **Gate `syncSessions`.** In
   `Sources/LabanCore/TerminalSurfaceController.swift`, inside
   `syncSessions(...)` (~line 379): per tab, read
   `session.dirtyGeneration()` and compare against a new
   `private var lastSyncedGeneration: [Session.ID: UInt64]`. When the
   generation is unchanged **and** `polling != .pollAllSessions` has
   already run its `session.poll()` (keep the poll itself — it drains the
   PTY for in-process/headless callers and may bump the generation; read
   the generation *after* the poll), skip `model.syncSurfaceMetadata(...)`
   and `session.renderDirty()` for that tab and continue. Update the stored
   generation whenever sync work runs. Prune entries for closed sessions.
   Leave the returned `TerminalSurfaceSessionSyncResult` semantics
   unchanged: a skipped tab reports not-dirty / no model change, exactly as
   an unchanged tab reports today.
   Force-refresh hatch: add a method
   `func invalidateSessionSyncCache()` (clears the map) and call it on tab
   open/close/restore so a recycled session ID cannot alias a stale
   generation. Fixture-mode (laband) sessions go through the same path:
   replayed output bumps the generation
   (`session_lifecycle.c` ~line 814), so remote tabs gate correctly.
5. **Tests.** Extend
   `Tests/LabanCoreTests/TerminalSurfaceControllerTests.swift`: add a
   counting seam (`private(set) var metadataSyncCountForTesting` on the
   controller, incremented when per-tab sync work actually runs — same
   pattern as the existing `sidebarRebuildCountForTesting`). Tests:
   (a) two consecutive `syncSessions` calls with no writes run sync work
   once; (b) writing bytes to a session between calls runs it again;
   (c) title/exit/dirty reporting through the public API is byte-for-byte
   identical with gating on (reuse the five existing tests as the oracle);
   (d) a child that exits with no output flips the tab's exit state within
   one `syncSessions` call after exit (proves step 2).
6. Commit (atomic, reason-statement), e.g.:
   `Idle ticks must not pay metadata-sync costs for unchanged sessions`.

### Milestone 2 — Wake-source audit, instrumentation, missing wakes

Goal: every row in the audit table is exists+proven or wired+proven. No
park yet — added wakes are strictly additive and safe to ship.

1. **Wake tagging.** In `Sources/LabanApp/TerminalBitmapView.swift` add
   `enum FrameWakeSource: String { case displayLink, sessionDirty,
   labandGeneration, keyboard, scrollWheel, modelMutation, focus,
   occlusion, settleWake, renderRetry, blinkTimer, safetyNet, other }` and
   `func advanceFrame(wake: FrameWakeSource)`; keep the existing
   `@objc func advanceFrame()` as a shim that passes `.other`, and have
   `displayLinkTick` pass `.displayLink`. Record the last wake source on
   the next journal entry: add `var wakeSource: String?` to
   `RenderJournal.Entry` (`Sources/LabanApp/RenderJournal.swift` — optional
   field, old dumps still decode; mirror the `modelChanged` precedent
   noted in `gpu-render-freeze-journal-diagnostic.md`). Update existing
   call sites to pass their tag.
2. **Wire row 3 (keyboard).** At the end of
   `override func keyDown(with:)` (~line 2607) call
   `advanceFrame(wake: .keyboard)`. This also restarts the blink phase
   immediately on typing.
3. **Wire row 4 (scroll wheel).** At the end of the `scrollWheel` handler
   (after `renderInvalidated = true`, ~line 3674) call
   `advanceFrame(wake: .scrollWheel)`.
4. **Wire rows 5 and 9 (model mutations).** Add to
   `Sources/LabanCore/AppModel.swift` a dedicated multicast-safe hook
   `public var onSurfaceStateChanged: (@Sendable () -> Void)?`
   (do **not** piggyback `onWorkspaceMutation` — that is single-cast and
   owned by `PersistenceCoordinator.attach(_:)`, `AppModel.swift` line 75).
   Fire it (outside the model lock, after the mutation) from:
   `selectTabUnlocked`, tab open/close/reorder paths, `applyResolvedBranch`
   (line 1869), `applySurfaceSignals`, and the agent-status update at
   ~line 1858. In `TerminalBitmapView.init`, subscribe it through the
   existing `displayKickCoalescer` (same pattern as `onSessionDirty`,
   lines 402–406) with tag `.modelMutation`. In `HeadlessDebugRuntime`,
   leave it unset for now (frames there are endpoint-driven), but note the
   hook in the parity comment so future subsystems wire both — this keeps
   the AGENTS.md `HeadlessDebugRuntime`/`MainWindowController` parity rule
   honest: the *policy and gating* live in LabanCore and are shared; the
   hook is the AppKit-only plumbing.
5. **Wire row 10 (exit wake).** In `Sources/LabanCore/SessionRunner.swift`
   change the loop to track the last seen `laban_session_dirty_generation`
   (via the Milestone-1 accessor on the raw handle, or a small C helper)
   and fire `onDirty()` whenever the generation moved — which now includes
   the exit transition — instead of only `drained > 0`. Keep the
   `drained < 0 → break` permanent-error exit, and fire one final
   `onDirty()` before the loop exits so even an error-path teardown
   repaints.
6. **Wire row 13 (Reduce Motion).** In the `reduceMotionObserver` closure
   (~lines 387–393) add `self?.scheduleRenderRetry()`.
7. **Audit closing rule.** Run the `renderInvalidated = true` sweep
   described under the table; convert stragglers to
   `invalidateRenderAndWake()`.
8. **Tests.** New `Tests/LabanAppTests/TerminalBitmapViewWakeTests.swift`
   (instantiate the view the way
   `Tests/LabanAppTests/TerminalBitmapViewSyncOutputTests.swift` does; add
   `private(set) var advanceFrameCallCountForTesting` incremented at the
   top of `advanceFrame`). Cover: keyDown wakes; scrollWheel wakes
   (synthesize the event via `CGEvent`/`NSEvent` as the selection tests
   do); `onSurfaceStateChanged` wakes through the coalescer; Reduce Motion
   observer schedules a retry. New `SessionRunner` test (LabanCoreTests):
   spawn `/bin/sh -c 'exit 0'` via the normal session spawn path, assert
   `onDirty` fires after exit with zero output (name contains `ExitWakes`).
9. **E2E.** Add a scenario under the dev-process harness (schema
   `schemas/debug-script.schema.json`, runner `scripts/run-debug-script`,
   suite `scripts/test-e2e`): start a session, run `sh -c 'exit 3'`, wait,
   assert `/debug/state` shows the exited tab state. (Headless has no
   link, so this proves the model-level signal chain; the link-level proof
   is the unit layer + live journal.)
10. Commits (atomic), e.g.:
    `A parked frame loop needs every state change to announce itself`,
    `Child exit must wake the frame loop even when it emits no bytes`.

### Milestone 3 — Full park policy + parachute + safety net + ADR

Goal: focused-idle parks the link; every Milestone-2 wake un-parks it on
demand; `LabanDisplayLinkIdleFloor` restores today's behavior instantly.

1. **Policy (pure, unit-tested).** In
   `Sources/LabanCore/TerminalIdlePolicy.swift` extend the enum (keep
   existing constants; the formatter and parity reviewers rely on them):

       public static let animationDisplayLinkFramesPerSecond = 30

       public static func displayLinkShouldRun(
         windowVisibleToUser: Bool,
         scrollAnimating: Bool,
         attentionAnimating: Bool,
         terminalOutputActive: Bool,
         cursorBlinkActive: Bool,
         idleFloorEnabled: Bool
       ) -> Bool

   Semantics: run if `scrollAnimating` (never freeze a settling scroll,
   matching today's gate); else require `windowVisibleToUser` AND any of
   `terminalOutputActive`, `attentionAnimating`, `cursorBlinkActive`, or
   `idleFloorEnabled`. Keep the existing two-argument
   `displayLinkShouldRun` as a deprecated shim or migrate its callers —
   pick one and note it in the Decision Log. Update
   `preferredDisplayLinkFramesPerSecond` to take the same inputs and
   return: 120 for scroll or active output; 30 for attention-only
   (Milestone 4 may land this constant together with this signature —
   that is fine, keep the commits separate by behavior); 8 for
   blink-only or floor-only.
2. **Plumbing.** In `TerminalBitmapView`:
   - Read the parachute once:
     `private let displayLinkIdleFloorEnabled =
     UserDefaults.standard.bool(forKey: "LabanDisplayLinkIdleFloor")`.
   - `displayLinkPolicyState()` (~line 988) computes the two new inputs:
     `cursorBlinkActive` per the Prerequisite section, and passes
     `idleFloorEnabled: displayLinkIdleFloorEnabled`. Extend the `reason`
     string ladder with `"parked"` (visible, quiescent, floor off) so
     `entries.jsonl` distinguishes the new state from `"notVisible"`.
   - `updateDisplayLinkRunState()` (~line 967) uses the new predicate for
     `link.isPaused`.
   - **Do not** touch the `CVDisplayLink` fallback (pre-macOS-14): it
     cannot pause cheaply and keeps today's behavior; the policy change is
     inert there because pausing is only applied to `CADisplayLink`.
3. **Safety net (temporary).** In `TerminalBitmapView`, a
   `DispatchSourceTimer` on main, 30 s interval, 5 s leeway, armed inside
   `updateDisplayLinkRunState()` when transitioning to parked and
   cancelled when resuming (and in `deinit`). On fire: ask the surface
   controller whether any session's `dirtyGeneration()` differs from its
   `lastSyncedGeneration` (add a cheap
   `func hasUnseenSessionActivity() -> Bool` to
   `TerminalSurfaceController`). If yes: log
   `EventLog.shared.log("render.displayLink.safetyNetRepair", [...])`,
   record a journal entry with `wakeSource: "safetyNet"`, then
   `advanceFrame(wake: .safetyNet)`. If no: do nothing (zero render work).
   Naming/payload conventions: `docs/process/observability.md`.
4. **ADR 0018.** Write
   `docs/adr/0018-event-driven-frame-production.md` following the existing
   structure (Status, Context, Decision, Consequences, Applies To New
   Code): the display link is a transient animation timer; frame
   production is event-driven via enumerated wake sources; the 8 Hz floor
   survives only behind `LabanDisplayLinkIdleFloor`; any new subsystem
   that mutates visible state must wake the frame loop (cite
   `invalidateRenderAndWake()` and `onSurfaceStateChanged`). Add the
   one-line index entry to `docs/adr/README.md`.
5. **Tests.** Extend
   `Tests/LabanCoreTests/TerminalIdlePolicyTests.swift` (9 existing tests
   stay green): parks when visible+quiescent+floor-off; runs when floor
   on; runs for blink-active; runs for attention; runs for output hold;
   scroll overrides visibility; rate ladder 120/30/8 per input
   combination. Names must make the ≥14-test Review Gate count
   unambiguous.
6. Commits, e.g.:
   `A quiescent focused terminal must not tick the display link at all`,
   `Frozen-frame rollback needs a no-rebuild parachute flag`,
   `Missed wakes must repair themselves and leave a bug signal`.

### Milestone 4 — Animation budget

If not already landed with the Milestone-3 signature change: attention-only
frames prefer `animationDisplayLinkFramesPerSecond` (30); scroll and active
output keep 120. Verify the pulse stays smooth: `AttentionPulse.alpha(at:)`
is a continuous function of wall-clock `now`
(`Sources/LabanCore/TabAttention.swift`), so a lower sample rate cannot
drift phase. Update/extend
`testAttentionAnimationPrefersActiveFrameRate` to assert 30. Commit:
`A breathing sidebar dot does not justify 120 Hz frame production`.

### Milestone 5 — Soak validation and safety-net retirement criteria

Run the full Validation and Acceptance section below on a real installed
build. Safety-net removal criteria (all required):

- 7 consecutive days of normal daily use with `LabanRenderJournalEnabled`
  on and **zero** `render.displayLink.safetyNetRepair` events
  (`grep -r safetyNetRepair ~/Library/Logs/Laban/` and the EventLog).
- The Review Gate mutation check and all wake unit tests green at HEAD.
- `./scripts/test-e2e` and `rtk ./scripts/check` green at HEAD.

Then remove the safety-net timer in its own commit
(`Soak proved wake coverage; the safety net poll has no job left`), update
this plan's Progress + Outcomes, and re-run the Review Gate.

## Concrete Steps

Working directory: the repository root. Prefer a worktree for this work
(AGENTS.md "Worktree Setup"): symlink `.external` if missing and run
`git update-index --skip-worktree .rpg/graph.json` in the worktree. Note
the worktree base may lag local `main` — rebase onto local `main` before
building or measuring.

Build and focused tests (run after each milestone):

    cd /Users/rrj/wrk/laban    # or the worktree root
    rtk swift test --filter TerminalIdlePolicyTests
    rtk swift test --filter TerminalSurfaceControllerTests
    rtk swift test --filter TerminalBitmapViewWakeTests
    rtk swift test --filter LabanSessionTests
    ./scripts/build-app                  # never `swift build` directly

Full gate before declaring any milestone done:

    ./scripts/test-e2e
    rtk ./scripts/check

Install for live validation (do NOT `open` the bundle from the shell — a
windowless launch grabs the single-instance lock; install, then quit and
relaunch Laban yourself):

    ./scripts/install-app                # build --profile + replace ~/Laban.app

Verify the running bundle before trusting any observation
(`LABANBuildCommit` is `<short-sha>[+dirty]`; a regenerated
`.rpg/graph.json` alone trips `+dirty`):

    /usr/libexec/PlistBuddy -c 'Print LABANBuildCommit' \
      ~/Laban.app/Contents/Info.plist
    git -C /Users/rrj/wrk/laban rev-parse --short HEAD

## Validation and Acceptance

All acceptance is phrased as observable behavior. Baseline every
measurement once on `main` before Milestone 1 so deltas are attributable.

1. **Unit tests.**
   `rtk swift test --filter TerminalIdlePolicyTests` — expect ≥14 tests,
   0 failures (new park/floor/budget tests fail before Milestone 3/4 code
   and pass after).
   `rtk swift test --filter TerminalSurfaceControllerTests` — expect the
   generation-gating test to fail before Milestone 1 and pass after, with
   the five pre-existing tests unchanged.
   `rtk swift test --filter TerminalBitmapViewWakeTests` — each test
   removes nothing and passes only when its wake fires (the Review Gate
   mutation check depends on this property).

2. **Tick-work gating, observed (Milestone 1).** Install, relaunch, open
   one tab at a quiet prompt, keep the window focused. Record 60 s:

       xcrun xctrace record --template 'Time Profiler' \
         --attach LabanApp --time-limit 60s \
         --output .artifacts/cpu/full-park-m1.trace

   Expect: `TabMetadataSynchronizer.syncSurfaceMetadata`,
   `Session.snapshot`, and `Session.renderDirty` effectively disappear from
   the main-thread samples (single-digit sample rows, versus the ~90 ms/min
   cluster in the baseline). `updateDisplayLinkRunState` and the 8 Hz wake
   cost remain — that is Milestone 3's job.

3. **Full park, observed (Milestone 3).** Same setup, blink off (Stage-1
   default). Enable counters and journal, relaunch:

       defaults write com.rrva.Laban LabanIdleCountersEnabled -bool YES
       defaults write com.rrva.Laban LabanRenderJournalEnabled -bool YES

   - After 60 s of focused idle, consecutive snapshots in
     `~/Library/Logs/Laban/idle-counters.jsonl` show `displayLinkTicks`
     and `advanceFrames` deltas of 0 (safety-net frames excepted: at most
     one `advanceFrames` per 30 s, and only if a repair fired — which is
     itself a bug to chase).
   - `top -l 3 -stats pid,command,cpu,idlew -pid "$(pgrep -x LabanApp)"`
     — idle wakeups in the last sample ≤ ~2/s (other app subsystems wake
     occasionally; the 8/s link cadence must be gone).
   - `scripts/bench-idle-cpu 60` (from the repo root, app built at
     `.build/laban/Laban.app`; quit any other running Laban first) —
     focused-idle CPU% corresponding to ≤ ~50 ms/min, i.e. ≤ ~0.08%.
     Compare against the recorded baseline (~400 ms/min ≈ 0.67%).
   - Dump the render journal (Debug menu) and inspect
     `entries.jsonl`: the last entry before quiescence has
     `displayLink.reason == "parked"` and `displayLink.paused == true`
     while `window.visibleToUser == true`.

4. **Wake coverage, observed (Milestone 3, the frozen-frame check).** With
   the journal on, in the focused parked window: (a) run
   `while true; do date; sleep 1; done` — output appears every second,
   journal shows `wakeSource: "sessionDirty"` frames; ctrl-C, wait 1 s,
   confirm parked again; (b) type into the prompt — instant echo,
   `wakeSource: "keyboard"`/`"sessionDirty"`; (c) wheel-scroll — the glide
   animates smoothly, `reason: "scroll"` at 120, then re-parks;
   (d) Cmd-digit tab switch — repaint, `wakeSource: "modelMutation"`;
   (e) `sh -c 'sleep 2; exit 3'` and hands off keyboard — the exited state
   appears within ~1 s of exit, not 30 s (proves the exit wake, not the
   safety net, fired); (f) in a background tab, trigger an agent
   `needsAction` state — the sidebar marker breathes (journal
   `reason: "attention"`, preferred 30), and stops when attended.
   Throughout: `grep safetyNetRepair` over `~/Library/Logs/Laban/` stays
   empty.
5. **Parachute.** `defaults write com.rrva.Laban LabanDisplayLinkIdleFloor
   -bool YES`, relaunch: focused-idle journal shows `reason: "idle"`,
   `paused: false`, ~8 Hz `lastTickIntervalMs` (~125) — today's behavior
   restored. Delete the default afterwards.
6. **MVP regression contract** (`docs/product/mvp.md` — do not break):
   live colored output, terminal titles updating tab/window labels,
   process-exited state visible, mouse scrollback + scroll indicator,
   selection, find — exercised by `./scripts/test-e2e` plus the manual
   sweep in step 4. Cursor blink (when enabled in Settings) still blinks at
   0.5 s; smooth scroll still glides; attention pulse still breathes.
7. **E2E + full gate.** `./scripts/test-e2e` exit 0; `rtk ./scripts/check`
   exit 0 (runs `swift test`, `smoke-runtime`, `test-e2e`, labpty coverage
   gates).

## Idempotence and Recovery

- All code changes are source-only; every step can be re-run by rebuilding
  and retesting. Measurement runs write only under `.artifacts/` and
  `~/Library/Logs/Laban/`; both are safe to delete.
- Instant behavior rollback without rebuild:
  `defaults write com.rrva.Laban LabanDisplayLinkIdleFloor -bool YES` and
  relaunch. Full rollback: revert the Milestone-3 commit(s); Milestones 1–2
  are behavior-preserving and can stay.
- If a frozen frame is reported in the field: capture
  `LabanRenderJournalEnabled` output, check the last entry's
  `displayLink.paused`/`reason`/`wakeSource`, and look for
  `safetyNetRepair` events — they name the missed wake. The
  `sampleGPUFreezeDetector` machinery is orthogonal (GPU no-progress, not
  missed wakes) but its dumps include the same journal.
- Keep `defaults delete com.rrva.Laban LabanIdleCountersEnabled` /
  `LabanRenderJournalEnabled` after validation so daily use is not
  journaling.

## Interfaces and Dependencies

- New C export (`Sources/LabanTerminalCore/include/LabanTerminalCore.h`,
  implemented in `Sources/LabanTerminalCore/capture.c`):
  `int laban_session_dirty_generation(LabanSession *session,
  uint64_t *out_generation);` — locked read of `s->dirty_generation`.
- `Sources/LabanCore/Session.swift`:
  `public func dirtyGeneration() -> UInt64`.
- `Sources/LabanCore/TerminalSurfaceController.swift`:
  `lastSyncedGeneration` map, `invalidateSessionSyncCache()`,
  `hasUnseenSessionActivity() -> Bool`,
  `metadataSyncCountForTesting`.
- `Sources/LabanCore/AppModel.swift`:
  `public var onSurfaceStateChanged: (@Sendable () -> Void)?`.
- `Sources/LabanCore/SessionRunner.swift`: `onDirty` fires on dirty
  generation change (including exit), plus a final fire on loop exit.
- `Sources/LabanCore/TerminalIdlePolicy.swift`: extended
  `displayLinkShouldRun(...)` / `preferredDisplayLinkFramesPerSecond(...)`
  with `attentionAnimating`, `terminalOutputActive`, `cursorBlinkActive`,
  `idleFloorEnabled`; new constant
  `animationDisplayLinkFramesPerSecond = 30`. Stays pure and AppKit-free —
  this is a hard rule; all window/UserDefaults reads happen in
  `TerminalBitmapView` and are passed in as plain values.
- `Sources/LabanApp/TerminalBitmapView.swift`: `FrameWakeSource`,
  `advanceFrame(wake:)`, `invalidateRenderAndWake()`, parachute read,
  safety-net timer, wake wiring per Milestone 2.
- `Sources/LabanApp/RenderJournal.swift`: optional
  `Entry.wakeSource: String?`.
- User defaults introduced: `LabanDisplayLinkIdleFloor` (bool, default
  false). EventLog kind introduced: `render.displayLink.safetyNetRepair`
  (temporary, removed with the safety net).
- Dependency: `execplans/active/cursor-style-and-blink-settings.md`
  (Stage 1). This plan is implementable before it via the
  `cursorBlinkActive` fallback described above, but the 0–2 wakeups/s
  acceptance number assumes Stage-1's blink-off default.
- Out of scope: `CVDisplayLink` fallback behavior (pre-macOS-14),
  `HeadlessDebugRuntime` frame cadence (it has no link; it benefits from
  Milestone-1 gating automatically via the shared
  `TerminalSurfaceController`), and any change to the laband snapshot
  publishing protocol.
