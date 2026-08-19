# Diagnose GPU Renderer Freezes With Automatic Render Journal Dumps

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Some tabs can stop visually updating while the opt-in `gpuDriven` renderer is
active. The PTY and terminal state may continue to advance, because switching
tabs away and back or scrolling back to the bottom can briefly repaint one
frame before the visible output freezes again. After this change, a developer
can enable a local diagnostic switch, reproduce the freeze, and Laban will
automatically dump the existing render journal when the GPU frame loop shows a
no-progress pattern. The dump contains the recent frame decisions, viewport and
scroll state, damage, command and payload summaries, Metal failure reasons, and
the current frame PNG needed to debug the freeze without relying on memory of
what the user saw.

## Progress

- [x] (2026-06-04 14:46Z) Created a new worktree at
      `.codex/worktrees/gpu-freeze-render-journal` on branch
      `gpu-freeze-render-journal`.
- [x] (2026-06-04 14:46Z) Read `docs/process/dev-process.md`,
      `docs/process/observability.md`, `docs/product/mvp.md`, `PLANS.md`,
      `docs/process/agent-operating-guide.md`, and ADR 0017.
- [x] (2026-06-04 14:46Z) Located the existing journal in
      `Sources/LabanApp/RenderJournal.swift` and the app frame loop in
      `Sources/LabanApp/TerminalBitmapView.swift`.
- [x] (2026-06-04 15:39Z) Implemented `GPURenderFreezeDetector` plus
      `freezeDetected` journal entries and `FreezeSnapshot` serialization.
- [x] (2026-06-04 15:39Z) Wired the detector into
      `TerminalBitmapView.advanceFrame()` and Metal
      frame completion callbacks.
- [x] (2026-06-04 15:39Z) Added focused tests for diagnostic switch parsing,
      detection, completion reset, throttling, and journal serialization.
- [x] (2026-06-04 15:59Z) Ran targeted tests and the repository check gate:
      `rtk swift test --filter RenderJournalTests`,
      `rtk swift test --filter RendererModeSettingsTests`,
      `rtk swift test --filter TerminalBitmapViewSyncOutputTests`,
      `rtk swift test --filter TerminalBitmapViewScrollToBottomTests`,
      `rtk git diff --check`, and `rtk ./scripts/check`.
- [x] (2026-06-04 16:04Z) Ran `update_rpg`, lifted the new
      `RenderJournal`/`GPURenderFreezeDetector` entities, lifted the new
      `RenderJournalTests` entities, and refreshed the touched
      `TerminalBitmapView` detector/wiring entities. The graph still reports a
      broader pre-existing backlog: 4631/5126 lifted (90%), 61 unlifted files,
      and stale features in the three changed files because
      `TerminalBitmapView.swift` alone queues ten lifting batches.
- [x] Recorded the final validation state after the last small detector reset
      and journal-detail adjustment: focused checks pass, while the full gate
      rerun stopped in the `coverage-labpty` deterministic harness.
- [x] Re-ran RPG maintenance after the final small patch. The specific touched
      entities were re-lifted and `finalize_lifting` completed; the graph still
      reports the broader backlog at 4631/5126 lifted (90%), 61 unlifted files,
      and 225 stale features.

## Decision Log

- Decision: The automatic dump remains opt-in through a new diagnostic switch
  instead of dumping terminal contents unconditionally.
  Rationale: The render journal can include visible terminal text, paths,
  commands, and a PNG. A local-only dump is useful for this bug, but it should
  be deliberately enabled.
  Date/Author: 2026-06-04 / Codex.

- Decision: Enabling the freeze auto-dump switch also enables the in-memory
  render journal ring.
  Rationale: A detector that only fires when `LABAN_RENDER_JOURNAL=1` is easy to
  forget during a rare freeze. A single freeze-diagnostic switch should collect
  the bounded recent history it will later dump.
  Date/Author: 2026-06-04 / Codex.

## Context and Orientation

The GPU-driven renderer is an opt-in macOS 26 renderer described by
`docs/adr/0017-gpu-driven-cell-renderer.md`. The classic frame-command path
remains the default. The app layer drives both renderers from
`TerminalBitmapView.advanceFrame()` in `Sources/LabanApp/TerminalBitmapView.swift`.
That method decides whether terminal output, scrolling, tab changes, cursor
blink, attention animation, or invalidation require a frame. It then asks
`TerminalSurfaceController` for a `TerminalSurfaceFrame`, calls
`RendererBackend.render(...)`, records journal entries, marks the terminal
snapshot rendered, and clears invalidation.

The existing render journal is `Sources/LabanApp/RenderJournal.swift`. It keeps
a bounded in-memory ring of recent frame entries and writes
`summary.json`, `entries.jsonl`, and optionally `current-frame.png` under
`~/Library/Logs/Laban/render-journal/<timestamp>/`. It already records events
for rendered, skipped, render-failed, and dump frames. Entries can include
renderer status, surface size, frame-state booleans, viewport and scroll state,
damage, command counts, payload summary, terminal-surface diagnostics, Metal
instance counts, GPU-cell payload build failures, and the typed
`MetalRenderer.RenderFailureReason`.

The freeze signature this plan targets is not a general main-thread stall. The
existing `MainThreadWatchdog` samples long `advanceFrame()` stalls. This plan
detects GPU-renderer no-progress: repeated render failures with active terminal
or scroll work, or a GPU-driven frame accepted by `MetalRenderer.render(...)`
that is followed by repeated dirty/retry attempts while no Metal frame
completion arrives.

## Plan of Work

Add a small pure detector type in `Sources/LabanApp/RenderJournal.swift`, near
the journal because it is a journal policy and should be tested without AppKit
or Metal devices. The detector accepts compact samples from the frame loop:
frame number, tab id, session id, whether GPU-driven rendering is active,
whether user-visible work is pending, whether the frame rendered, optional
`MetalRenderer.RenderFailureReason`, and whether a Metal frame completion has
arrived. It returns a diagnostic result only after a threshold of consecutive
GPU no-progress samples. It also throttles repeated dumps for the same
tab/session/reason so one freeze does not create many directories.

Extend `RenderJournal` with:

- `gpuFreezeAutoDumpDefaultKey = "LabanGPUFreezeJournalAutoDumpEnabled"`;
- `gpuFreezeAutoDumpEnvironmentKey = "LABAN_GPU_FREEZE_JOURNAL_AUTODUMP"`;
- a helper that reads the new switch from `UserDefaults` or environment;
- a `freezeDetected` journal event;
- a compact `FreezeSnapshot` field on `RenderJournal.Entry` containing the
  detector reason, streak count, pending work booleans, last render failure
  reason, and Metal completion counters.

Wire `TerminalBitmapView` so the detector is sampled after every render failure,
after every successful rendered GPU-driven frame, and from the Metal
`onFrameCompleted` callback. When the detector fires, first record a
`freezeDetected` entry with the same state capture used by existing rendered and
failed entries, then call `renderJournal.dump(currentPNG: backend.pngData)`.
Log the dump path to `AppLog.render` and `EventLog` with an event kind such as
`render.gpuFreeze.autoDump`.

Keep the behavior narrow:

- do nothing when the effective renderer is not `gpuDriven`;
- do nothing when no active terminal/scroll/invalidation work exists;
- do nothing when only cursor blink or sidebar attention animation is active;
- reset suspicion on a successful GPU-driven render that is followed by a Metal
  frame completion;
- avoid new render retries from the detector itself.

## Concrete Steps

Work from:

```sh
cd /Users/user/wrk/laban/.codex/worktrees/gpu-freeze-render-journal
```

Edit:

- `Sources/LabanApp/RenderJournal.swift`
- `Sources/LabanApp/TerminalBitmapView.swift`
- `Tests/LabanAppTests/RenderJournalTests.swift`

Use:

```sh
LABAN_GPU_FREEZE_JOURNAL_AUTODUMP=1 ./scripts/build-app
```

or run the app with that environment through the local run script, then select
the GPU-driven renderer and reproduce the freeze. A suspected freeze should
write a directory under `~/Library/Logs/Laban/render-journal/` and log
`render.gpuFreeze.autoDump` with the path.

## Validation and Acceptance

Targeted test command:

```sh
rtk swift test --filter RenderJournalTests
```

Expected result: all `RenderJournalTests` pass, including new tests that prove
the detector ignores classic rendering, ignores cursor-only work, fires after
the configured GPU no-progress threshold, records a `freezeDetected` entry that
round-trips through JSON, and throttles duplicate dumps.

Focused app compile command:

```sh
rtk swift test --filter RendererModeSettingsTests
```

Expected result: renderer-mode switching still preserves the active session and
the added completion-hook state does not break existing app tests.

Actual result:

- `rtk swift test --filter RenderJournalTests` passed, 11 tests.
- `rtk swift test --filter RendererModeSettingsTests` passed, 5 tests.
- `rtk swift test --filter TerminalBitmapViewSyncOutputTests` passed, 6 tests.
- `rtk swift test --filter TerminalBitmapViewScrollToBottomTests` passed, 4
  tests.
- `rtk git diff --check` passed after the final patch.
- `rtk swift test --filter RenderJournalTests` passed after the final patch.
- An earlier `rtk ./scripts/check` passed before the final small detector reset
  and journal-detail adjustment. That run executed 1276 XCTest tests with 12
  skips and no failures, passed `smoke-runtime`, passed `test-e2e`, and held
  the `coverage-labpty` MC/DC floor at 45.52%.
- The final `rtk ./scripts/check` rerun passed the full XCTest phase, selected
  test phases, `smoke-runtime`, and `test-e2e`, then stopped in
  `coverage-labpty` at the deterministic `registry_cov` harness. A bounded
  retry with `rtk timeout 600 ./scripts/coverage-labpty --check 45` reproduced
  the same stop/hang, so the final full gate did not complete on the final
  diff.
- RPG maintenance was run with `set_project_root`, `update_rpg`,
  scoped `submit_lift_results`, `finalize_lifting`, and `lifting_status`.
  The touched diagnostic entities were lifted, but the worktree graph remains
  `STALE` with 225 stale features until the larger existing
  `TerminalBitmapView.swift` and renderer lifting backlog is processed.

## Idempotence and Recovery

The detector keeps only in-memory counters and writes local dump directories
when explicitly enabled. Re-running tests is safe. Deleting dump directories
under `~/Library/Logs/Laban/render-journal/` is safe if they were created by a
local diagnostic run. If false positives appear, raise the no-progress
threshold or tighten the pending-work predicate before changing renderer code.

## Outcome (2026-06-04)

The detector caught the freeze it shipped for. With the auto-dump switch enabled,
a live Claude Code TUI session produced the first real `freezeDetected` dump:
`reason: gpuRenderNoProgress`, `renderFailureReason: drawableUnavailable`,
`noProgressStreak: 12`, while idle (`terminalDirty: false`) with
`renderInvalidated` stuck true.

Root cause (in `Sources/LabanRenderer/MetalDrawableScheduler.swift` and the
`TerminalBitmapView` render-failure branch): the scheduler's 8 ms drawable-acquire
timeout abandoned the in-flight `nextDrawable()` but left `drawableRequestActive`
set, so every subsequent frame fast-failed until the stuck call unblocked (a
"poison gate"); meanwhile the failure branch re-asserted `renderInvalidated` and
called `scheduleRenderRetry()`, a plain `DispatchQueue.main.async` hop that spun
once per main-loop turn. Together they amplified one ~16 ms drawable-drain wait
into bursts of 8-12 failed frames — a visible freeze the strict-consecutive-12
detector only caught at its worst.

Fix shipped (two reviews — an architect subagent and Codex — concurred):

- `MetalRenderer.RenderFailureReason.isGPUBackpressure` classifies
  `drawableUnavailable`/`previousFrameInFlight`.
- App-side pacing (commit `aa3c738`): on backpressure, leave the frame
  invalidated and let the next display-link tick repaint instead of an immediate
  retry; keep immediate retry for transient reasons (size mismatch, no-content
  full redraw).
- Scheduler carry-forward (commit `2c5d98c`, independently revertible): a late
  `nextDrawable()` is parked in `pendingDrawable` for the next acquire instead of
  poisoning subsequent frames; stale-sized carry-forward is caught by the
  existing `drawableSizeMismatch` guard.

Live-journal verification (heavier load than the bad baselines): `drawableUnavailable`
35% -> 4.7%, longest consecutive run 12 -> 2, `freezeDetected` 1 -> 0, no new
failure reasons. Two diagnostic commits added en route and kept as observability:
`f29b662` (off-bottom `noFrameNeeded` park trace) and `865ac2d`
(`modelChanged`/`metadataSignature` journal fields). Both the scroll-to-bottom and
title-spinner hypotheses they chased were disproven by the instrumentation before
the drawable-starvation root cause was found.

## Follow-up (2026-06-05)

Runtime inspection of the latest render journals showed the remaining
self-sustaining loop after the scheduler and immediate-retry fixes:

- latest manual dump `~/Library/Logs/Laban/render-journal/2026-06-04T200200585Z`
  had 34 idle `drawableUnavailable` misses where `terminalDirty`,
  `activeTerminalDirty`, tab change, cursor blink, attention animation, scroll,
  and resize were all false while only `renderInvalidated` stayed true;
- latest auto-freeze dump
  `~/Library/Logs/Laban/render-journal/2026-06-04T194439344Z` had 68 matching
  idle drawable misses, 45 with `gpuCellCommandFallbackPending` set only after a
  drawable miss, and a `freezeDetected` entry at `noProgressStreak: 12`.

Fix: track whether `renderInvalidated` is only being carried forward from a
GPU-backpressure miss. The first backpressure miss keeps the frame invalidated
for a display-link-paced retry; a repeated miss with no independent visual work
clears `renderInvalidated` and parks the loop. Drawable starvation no longer
sets `gpuCellCommandFallbackPending`; that fallback is reserved for
`.fullRedrawProducedNoContent` when a GPU-cell payload was present.
