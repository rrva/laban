# 33. Vector Glyph Renderer Is Retired

Date: 2026-08-24

## Status

Accepted. Supersedes the selectable-renderer half of ADR 0022. ADR 0032 (Slug
is the default) stands; this removes the alternative rather than changing the
default.

## Context

`vectorGlyph` (ADR 0022) rasterizes CoreText outlines into a resident,
size-keyed mask atlas and samples those masks while drawing. Glyph work is
amortized across frames, which suits static text and scrolling.

The amortization has a hole at rest. `accumulationSamplesThisFrame` gives every
first-seen glyph the full `accumulationSampleCap` (512) accumulation samples in
a single frame:

    if sampleStart == 0 { return Self.accumulationSampleCap }

The scrolling path was later capped — 64-sample chunks under a shared 1024
sample per-frame budget, plus a dispatch cap — because, in its own words, "a
512-sample burst per new glyph injects multi-ms of GPU compute into that scroll
frame's command buffer." Both caps are gated on `scrollPhaseOffset != .zero`.
At rest there is no budget of any kind.

First-painting an unfamiliar screen is exactly the uncapped case, and switching
tabs is exactly that. Measured on 2026-08-24 against a live session: a
tab-switch frame executed on the GPU for **9.67 seconds**
(`lastFrameGPUms` 9670.6, `commit → completion` 9673.7, against a p50 of
0.07 ms). The consequences follow mechanically:

- The frame holds the one-frame-in-flight slot for its whole duration, so every
  subsequent frame is refused with `previousFrameInFlight`.
- The publish to the present link happens in that frame's completion handler, so
  nothing new is presented and the window keeps showing the **previous** tab.

The user-visible result is a tab that takes several seconds to switch, worse for
tabs with more unfamiliar glyphs, and instant once those glyphs are resident —
the "warm-up" behaviour that made this hard to pin down. It is invisible to the
usual instruments: no main-thread stall, no hang, ~0.4% CPU. Switching the
renderer to Slug and back resolved it, which is what first implicated the
backend.

## Decision

Retire `vectorGlyph`.

- `RendererSelection.selectableCases` excludes it, so no menu or Settings picker
  offers it.
- `RendererSelection.migratingRetired(_:)` maps it to `slugGlyph`, applied in
  both `persisted(_:)` and `set(_:)`. An existing install that persisted
  `vectorGlyph` — every install predating ADR 0032, since a persisted choice
  always wins — moves to Slug on next launch without user action.
- The enum case and `VectorGlyphRenderer` itself remain, so an old persisted
  value still decodes and the fidelity and weight-parity harnesses can keep
  instantiating the backend directly for comparison.

## Consequences

Slug has neither a mask atlas nor an accumulation pass, so this cost model
cannot exist there; its glyph geometry is size-independent (ADR 0027). Classic
uses a pre-baked raster atlas. `encodeAccumulate` — the GPU compute dispatch at
the heart of this defect — appears exactly once in the renderer module, in
`VectorGlyphRenderer.swift`, and all 28 per-frame budget symbols are local to
that file. Retiring the backend removes the defect class rather than adding
another budget to tune.

The sub-pixel-phase smooth scrolling described in `docs/product/spec.md` was a
vector-only quality property and goes with it; Slug's analytic outlines address
the same sharpness goal by a different route.

Deleting `VectorGlyphRenderer` and its tests is deliberately **not** part of
this decision. Retirement stops it being reachable; deletion is a follow-up once
the fidelity reports confirm Slug is at least at parity, and is a large enough
diff to want its own review.

Two defects this exposed are NOT fixed by retiring, because they belong to the
shared frame loop and would amplify any slow frame from any backend:

1. `MetalDrawableScheduler.beginFrame` blocks the main thread up to 16 ms per
   non-scroll frame waiting for GPU capacity.
2. Nothing wakes the frame loop when a completion frees that capacity, so frames
   refused during a slow frame wait for an unrelated wake instead of drawing the
   newest state immediately.

Tracked in `execplans/active/frame-completion-wake.md`.
