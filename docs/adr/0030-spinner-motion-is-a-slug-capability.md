# 30. Spinner Motion Smoothing Is a Slug-Only Capability

Date: 2026-07-20

## Status

Accepted. Implementation tracked in `execplans/active/spinner-motion-smoothing.md`.

## Context

Terminal spinners and status ripples repeatedly recolor the same small set of
glyphs at a steady cadence. Laban's other renderers (`software`, `classic`,
`gpuDriven`, and `vectorGlyph`) consume shared frame commands and render each
authoritative terminal state immediately. Interpolating between two authoritative
states on those backends would require CPU-side recoloring, duplicate glyph
compositions, or per-frame command rewriting, none of which preserve the exact
coverage and alpha semantics of the existing renderers.

ADR 0027 added `slugGlyph` as an analytic glyph renderer. Its instance payload
already carries an `effectKind`/`effectStart` GPU animation channel, its vertex
shader already receives a per-frame `timeSeconds`, and its effect scheduler
already provides bounded liveness, live-band damage, settle repaints, and display-
link parking (ADR 0018). These facilities are exactly what spinner motion needs:
a single analytic glyph instance can mix from a previous linear-light foreground
to a new one inside the vertex shader, with no extra coverage cost and no CPU
recoloring.

No other backend possesses that combination. Extending the feature to them would
therefore require a different, lower-quality implementation, and would couple
spinner-specific state to renderer-neutral data structures.

## Decision

Spinner motion smoothing is intentionally a Slug-only capability. It is gated on
the **effective** renderer being `slugGlyph`, the persisted setting being enabled,
and Reduce Motion being off.

- `SpinnerMotionDetector` in `Sources/LabanCore/SpinnerMotion.swift` is renderer-
  neutral: it observes resolved cell state, qualifies changed regions, tracks
cadence, and produces transition metadata. It is gated on the renderer-eligibility
signal supplied by `TerminalBitmapView` or `HeadlessDebugRuntime`, not on any
renderer object.
- `FrameCommand.glyphRun` carries optional `foregroundTransition` metadata. Non-Slug
  renderers ignore it; `SlugGlyphRenderer` routes annotated analytic glyphs into a
separate `SlugGlyphMotionGPUInstance` path.
- The motion vertex shader (`slugGlyphMotionVertex`) performs the linear-light
  foreground mix and emits the existing `SlugGlyphVertexOut`, so coverage,grayscale,
subpixel accumulation, and translucent composition are unchanged.
- `SlugGlyphRenderer` reports actual liveness through `glyphEffectAnimatingRemainingSeconds`
  and `glyphEffectFrameCount`; `TerminalIdlePolicy` and the display link already
consume those values. No spinner-specific wake source or idle-policy input isadded.
- The UI checkbox is disabled when the configured renderer is not Slug, and the
debug endpoint reports `configured`, `rendererEligible`, `effectiveEnabled`, and anexplicit reason when unavailable.

## Consequences

- Users on other renderers continue to see authoritative terminal color changes
  immediately; the feature is not degraded to a partial or flickering approximation.
- `SlugGlyphRenderer` owns all time-varying spinner pixels. The core owns detection
  and metadata, preserving the renderer boundary from ADR 0027.
- Non-Slug code paths (software, classic Metal, GPU-driven Metal, vector glyph,
`TerminalCellPayload`) contain no spinner effect fields, transition state, or
shader motion code.
- A future decision to make spinner motion available on another renderer requires
  a new ADR backed by an equally capable backend substrate: per-glyph GPU time,
single analytic instance, and bounded liveness/settle parking.

## Applies To New Code

Do not add spinner-motion state, fields, or shaders to non-Slug renderers or to
shared rendering data structures. Keep `foregroundTransition` optional and nil by
default. Gate effective behavior on the effective `slugGlyph` renderer, not on
configured selection or on renderer internals.
