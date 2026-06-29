# 26. Display-Synced Drawable Acquisition on macOS 26 (CAMetalDisplayLink)

Date: 2026-06-29

## Status

Proposed. Implementation tracked in
`execplans/active/vector-drawable-pacing-120hz.md`.

## Context

Laban's Metal-backed renderers (`MetalRenderer` for classic/gpuDriven,
`VectorGlyphRenderer` for the curve renderer) present by borrowing a
`CAMetalDrawable` from a `CAMetalLayer` pool via `layer.nextDrawable()`. That call
**blocks** the caller until Core Animation recycles a presented drawable, which
only happens on a display refresh. With one frame in flight
(`MetalDrawableScheduler.frameInFlight = DispatchSemaphore(value: 1)`) the pool
drains every frame, so on a 120 Hz ProMotion display the cadence collapses into a
harmonic of the refresh rate — the "half-rate basin" — where frames land every
~16 ms instead of ~8.33 ms.

`MetalDrawableScheduler` already mitigates this heavily: it issues `nextDrawable()`
asynchronously on a background queue, parks late drawables for the next frame
("carry-forward"), prefetches, and has an explicit basin escape hatch
(`onDrawableReadyAfterMiss`). But it is still ultimately blocking on
`nextDrawable()` and gating on a single in-flight frame, so it moves the wait off
the main thread's *stack* without removing it from the *pipeline*.

A GPU System Trace of heavy vector smooth-scroll (build 206e4fa, captured via
`scripts/analyze-metal-trace`) measured the main thread spending p50 **7.2 ms** /
p95 **~15 ms** blocked in "wait for next drawable", while the actual GPU render
pass (`laban.vector.content`) was only p95 **1.13 ms**. The bottleneck is drawable
acquisition, not GPU compute or (after ADR-adjacent work) CPU encode.

The classic renderer stays at 120 Hz where the vector renderer falls into the
basin because the two have identical scheduler wiring but the vector renderer's
single per-frame command buffer also carries the GPU glyph-mask bakes
(`ensureResidentMask`→`encodeAccumulate`), so its one-in-flight window spans
bake+render+present.

Apple's current (June 2026) recommended mechanism for this exact problem is
`CAMetalDisplayLink` (macOS 14+): its per-frame delegate callback delivers an
already-acquired drawable plus a render deadline and an estimated presentation
timestamp, so the app never calls `nextDrawable()` on its own thread. Apple DTS
states it directly: "For frame pacing in particular we strongly advise using
CAMetalDisplayLink over CADisplayLink." The deployment target is macOS 13, but the
goal is scoped to macOS 26 (the user's machine), so the feature can live behind an
availability gate with the existing path as the legacy fallback.

## Decision

Add a **display-synced drawable-acquisition path** for the Metal renderers, gated
on macOS availability and selected only on macOS 26+ where the 120 Hz goal must
hold:

1. On the fast path, a `CAMetalDisplayLink` (constructed under
   `#available(macOS 14.0, *)`) running on a dedicated high-QoS thread drives
   presentation. Its callback supplies `update.drawable`; the renderer gains an
   entry point that **renders into a supplied drawable** without touching
   `MetalDrawableScheduler` or calling `nextDrawable()`. Animation is advanced
   from `update.targetPresentationTimestamp`.

2. Frames-in-flight is raised above 1 (target 2, matching Apple's WWDC25 reference
   architecture), with the per-frame-written offscreen target/accumulation
   textures owned per in-flight slot so the shared-resource invariant is
   preserved. `maximumDrawableCount` stays 3 and `allowsNextDrawableTimeout` stays
   `true` (setting it `false` risks a documented indefinite hang).

3. On macOS below the gate, nothing changes: the `CADisplayLink`/`CVDisplayLink`
   tick, `MetalDrawableScheduler`, and the blocking-but-mitigated `nextDrawable()`
   path remain byte-for-byte as they are. The goal is not required to hold there.

This is the project's standard OS-gated dual-path shape: a SOTA `#available` fast
path plus an untouched, pinned legacy fallback.

## Consequences

- On macOS 26, the render path no longer blocks on `nextDrawable()`; the heavy
  scroll p99 frame interval should hold near 8.33 ms and the live `jankFrames`
  counter (`GET /scroll/frame-stats`) drop to ~0. This is verified against the live
  app under `--scroll-debug`, not the offscreen `VectorScrollFrameTimeBench` (which
  cannot observe drawable wait).
- Two presentation code paths now exist (display-link-driven vs scheduler-driven),
  selected by `#available` and renderer kind. The legacy path is retained
  unchanged, so the maintenance cost is additive and the fallback is low-risk.
- Raising frames-in-flight requires per-in-flight ownership of the offscreen
  target/accum textures; getting that wrong would let frame N+1 stomp frame N. The
  ExecPlan gates this behind the existing vector parity tests (zero pixel-diff).
- Presentation work moves to a dedicated thread, interacting with the existing
  main-thread watchdog and the event-driven frame production model (ADR 0018);
  idle behavior (`isPaused`) must be wired to the same wake sources so a quiescent
  terminal still parks.
- Frame-command contract (ADR 0017/0022) and MVP behavior are unchanged; this is a
  presentation/pacing change, not a rendering-semantics change.

## Alternatives considered

- **Keep tuning `MetalDrawableScheduler` only.** It is already near the ceiling of
  what async `nextDrawable()` + 1-in-flight can do; the GPU trace shows the wait
  persists. Rejected as insufficient for the goal on macOS 26.
- **Disable vsync (`displaySyncEnabled = false`) or set
  `allowsNextDrawableTimeout = false`.** The former tears (unacceptable for a
  terminal); the latter risks an indefinite main-thread hang (documented
  third-party deadlock). Rejected.
- **A custom present thread with `MTLSharedEvent` + `kqueue` timer pacing**
  (Apple's WWDC25 game architecture). Correct but far heavier than a terminal
  needs and aimed at frame interpolation. `CAMetalDisplayLink` gives the needed
  win at a fraction of the complexity. Deferred unless measurement demands it.
