# Wake The Frame Loop When GPU Capacity Frees

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

When one GPU frame takes a long time, Laban's window does not merely update
late — it freezes on the *previous* content and stays there after the slow frame
has finished. After this change a slow frame degrades gracefully: the window is
stale for exactly that frame, then updates immediately.

This is renderer-neutral. It was found while diagnosing the retired vector
backend (ADR 0033), whose at-rest glyph baking produced a 9.67-second GPU frame,
but nothing here is specific to that cause. Any backend that produces one slow
frame — for any reason — hits the same amplification.

### Why one slow frame froze the window

A GPU frame's completion handler does two load-bearing things:

1. It calls `publishLatestTarget`, which is what hands the frame to the
   renderer-owned present link. Nothing reaches the screen until it runs.
2. It calls `scheduledFrame.finish()`, releasing the one-frame-in-flight
   semaphore in `MetalDrawableScheduler`.

While a slow frame runs, both are pending, so: nothing new is presented (the
window shows the frame before it), and every attempted frame is refused with
`previousFrameInFlight`. That much is faithful — you cannot present a frame that
is not finished.

The defect is what happened next: **nothing woke the frame loop when the frame
finally completed.** The refused frames were not retried, so the window kept
showing stale content until an unrelated wake — a keystroke, PTY output, a
display-link tick — happened to fire. With the link parked (ADR 0018) that can
be seconds. Evidence, from a live journal dump on 2026-08-24:

    17:56:57 f1272 rendered      TABSWITCH        gpuDone=1205  cb/pr=3089/3089
    17:56:58 f1273 renderFailed  previousFrameInFlight  gpuDone=1205  cb/pr=3089/3089
    17:56:58 f1273 renderFailed  previousFrameInFlight  gpuDone=1205  cb/pr=3089/3089
            … no journal entries at all for the next 4 seconds …

`gpuFrameCompletions` frozen at 1205 is the slow frame; the present link's
callback counter frozen at 3089 is the window not updating.

## What changes

`TerminalBitmapView.installFrameCompletionHook` already hops to the main queue on
every completion to update counters. It now also calls
`wakeFrameLoopIfCapacityJustFreed()`, which schedules one coalesced frame when
`TerminalRenderGate.shouldWakeFrameLoopOnCompletion(consecutiveBackendRenderFailures:)`
says a frame was actually refused since the last successful render.

The gate matters. A healthy pipeline completes a frame every tick, so an ungated
wake would schedule a frame from every completion — an idle terminal spinning at
GPU cadence, which is the no-progress loop this whole investigation began with.
`consecutiveBackendRenderFailures` is cleared by any frame that renders, so the
sequence is self-limiting: refuse → wake → render → counter clears → the next
completion is silent.

## Non-goals

`MetalDrawableScheduler.beginFrame` still blocks the main thread for up to 16 ms
per non-scroll frame waiting for capacity. That block exists so non-scroll frames
are never dropped ("typed output and static repaints keep the old always-commit
guarantee"), and the scroll path already opted out of it on the grounds that "a
skipped tick is repainted one tick later from newer state" — equally true for
output frames. This change supplies the missing half of that argument: a
completion-driven wake makes the retry guaranteed, so the block could become a
non-blocking probe. Deliberately left for a follow-up so this change can be
measured on its own; it alters a documented invariant.

## Progress

- [x] Established the mechanism from journal dumps: completion frozen, present
      callbacks frozen, refusals until it lands, then silence.
- [x] Added `TerminalRenderGate.shouldWakeFrameLoopOnCompletion` and wired the
      completion hook to it.
- [x] Added `Tests/LabanAppTests/FrameCompletionWakeTests.swift`.
- [x] Ran the affected filters, the lint gate, and the full suite.

## Decision Log

- Decision: gate the wake on a prior refusal rather than waking on every
  completion. Waking unconditionally is simpler but reintroduces a
  completion-driven render loop on an idle terminal, which is the failure mode
  `execplans/active/vector-render-failure-backpressure.md` exists to prevent.
- Decision: express the gate as a pure helper on `TerminalRenderGate` rather than
  an inline condition, matching the file's existing decision helpers so the
  production condition is the one under test instead of a copy of it.

## Validation and Acceptance

    swift build
    swift test --filter FrameCompletionWakeTests
    swift test --filter TerminalRenderFailureRetryTests

Expected: all pass. (`swift test` with no filter also surfaces two pre-existing
`CJKFontSettingsTests` failures from a test-isolation bug unrelated to this
change; they pass when that suite runs alone.)

Behavioral acceptance: with the render journal enabled, provoke a slow frame and
confirm that the entries following its completion include a `renderRetry` wake
rather than a gap that ends only at the next unrelated event. Before this change
the same reproduction showed several seconds with no journal entries at all after
the refusals.
