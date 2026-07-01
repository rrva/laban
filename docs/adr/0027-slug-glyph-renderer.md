# 27. Slug Glyph Renderer Is an Opt-In Analytic Text Backend

Date: 2026-06-30

## Status

Proposed. Implementation tracked in
`execplans/active/slug-glyph-renderer.md`.

## Context

ADR 0022 added `vectorGlyph` as an opt-in renderer that extracts CoreText
outlines, bakes glyph masks into a resident atlas, and samples those masks during
normal terminal rendering. That architecture fits static text and scrolling:
glyph work is amortized across many frames, and the existing renderer/debug
contracts stay intact.

Continuous zoom has a different cost model. A mask atlas is keyed by glyph size,
so every fractional point size invalidates the resident masks and turns zoom into
a repeated bake path. The vector zoom smoothness work measured multi-hundred-ms
stalls from this size-keyed atlas churn. Correctness issues around stale masks,
mixed glyph sizes, and debounced zoom commits all come from the same structural
fact: the atlas stores resolution-specific glyph bitmaps.

The Slug algorithm (Eric Lengyel, JCGT 2017, "GPU-Centered Font Rendering
Directly from Glyph Outlines") evaluates glyph coverage analytically from the
outline in the fragment shader. The uploaded glyph geometry is size-independent;
the active point size is a transform/uniform. Its former patent encumbrance no
longer blocks implementation: the Terathon Slug patent was dedicated to the
public domain in March 2026, with MIT-licensed reference material available.

Slug is therefore a better fit for continuous fractional zoom, while the
atlas-backed vector renderer remains the better-proven scroll path. The right
architectural boundary is a new backend, not a replacement for the vector
renderer.

## Decision

Add `slugGlyph` as a new, opt-in `RendererSelection` and `RendererBackend` peer
beside `software`, `classic`, `gpuDriven`, and `vectorGlyph`.

- `SlugGlyphRenderer` owns its own Metal layer, render target, analytic glyph
  geometry cache, and Slug shader pipelines. Its outline path follows the public
  Slug reference model: fixed-size curve geometry, horizontal and vertical band
  lists, derivative-scaled root coverage in the fragment shader, and per-channel
  sampling only when RGB subpixel mode is active. It consumes the existing
  `[FrameCommand]` stream and does not extend the terminal renderer contract.
- Slug geometry is built from a fixed reference point size and keyed by visual
  font identity plus glyph id. The active terminal point size is excluded from
  that cache key, so the same curve/band data is reused across fractional and
  committed zoom sizes.
- Continuous zoom is handled through the shared gesture-zoom capability used by
  vector and Slug renderers: per-frame zoom is a projection/instance transform,
  not a font reconfigure or atlas bake.
- Slug presents its `CAMetalLayer` through the same ADR 0026
  `CAMetalDisplayLink` path used by the vector glyph renderer when available:
  content rendering writes an offscreen target, publishes the completed target
  from the command-buffer completion handler, and the host's existing idle/active
  display-link policy drives the present thread. The legacy `nextDrawable()` path
  remains only for systems or settings where the present link was never created.
- Slug ships default-off. `classic`/`gpuDriven`/`vectorGlyph` behavior and
  defaults are unchanged.
- Color emoji and very high-complexity CJK glyphs use the existing color/R8
  raster atlas fallback paths at cell granularity. Slug remains the configured
  and effective renderer for the frame; fallback glyph counts are reported
  through `RendererStatus`.
- Headless/debug surfaces select and report `slugGlyph` through the same shared
  renderer-selection contract as AppKit.

## Consequences

- Laban gains a resolution-independent text backend for continuous zoom without
  making Slug the default renderer or perturbing the atlas-backed vector scroll
  path.
- The project now has two curve-rendering backends with intentionally different
  cost models: `vectorGlyph` amortizes static text through a resident mask atlas;
  `slugGlyph` recomputes analytic coverage per presented pixel from
  size-independent geometry.
- Slug must honor the same renderer contracts as the other GPU backends:
  `waitForFrameCompletion`, screenshot/readback, renderer status reporting, menu
  and settings selection, headless selection, debug observability, and the
  presenter/idle guarantees of the vector glyph renderer.
- Default-enable is a later decision. It requires live AppKit evidence, release
  timing evidence, fallback coverage for real-world Unicode, and parity with the
  current presenter/idle guarantees. This ADR only records the opt-in backend
  boundary.
- Any future attempt to fold Slug into `VectorGlyphRenderer`, delete
  `vectorGlyph`, or make Slug the default requires a new ADR because it would
  change the renderer architecture and rollout posture recorded here and in
  ADR 0022.

## Applies To New Code

New renderer work must keep renderer selection at the `RendererBackend` boundary
unless the backend already owns the relevant cost model. Do not add Slug-specific
state to `VectorGlyphRenderer`, and do not treat continuous fractional zoom as a
size-keyed atlas operation. Glyph caches must key on visual font identity and the
properties that affect rendered geometry, never transient `CTFont` object
addresses.
