# Subpixel seam accumulate-once compositing

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Repository root: `/Users/user/wrk/laban`. `PLANS.md` lives at the repo root.

## Purpose / Big Picture

When RGB subpixel vector text AA is enabled in the Slug Glyph or Vector Glyph
renderer, abutting glyphs that share a pixel row (the canonical case: btop
drawing a vertical frame with stacked `│` box-drawing characters) show a
brighter, color-fringed notch at the seam where the characters meet. Grayscale
AA does not show it.

After this change, abutting same-color subpixel glyphs composite as if their
coverage were a union: two stacked `│` render as a continuous stem with no
seam notch, matching the grayscale result. A new regression test renders
stacked `│` in both renderers with RGB subpixel and asserts the seam pixel is
no brighter than the steady interior.

## Root cause (summary)

Both renderers composite subpixel text **per glyph** with a darken pass
(`dst *= 1 − cov`) then an additive pass (`dst += fg·cov`) — the per-channel
"over" operator, run once per glyph. At a seam, the bottom AA ramp of the
upper glyph and the top AA ramp of the lower glyph both contribute partial
per-channel coverage to the same pixel row. Compositing each glyph separately
applies "over" twice, which is not additive in coverage:

```
seam_ch    = bg·(1−c1)(1−c2) + fg·(c1+c2−c1·c2)
steady_ch  = bg·(1−c_full)   + fg·c_full       where c_full = c1 + c2
Δ          = c1·c2·(bg − fg)          // a bright (less-ink) notch per channel
```

Grayscale spreads the stem across the whole pixel (`h ≈ 0.4–0.6`, so `h²` is
small and the notch is a uniform ~4–9 %, imperceptible). RGB subpixel samples
each channel from a third of the pixel, so the dominant subpixel channel is
nearly fully covered (`h ≈ 1.0`), `c1·c2` reaches ~0.25, and the notch is a
~25 % brightening concentrated in one channel — a visible color fringe.

The Slug coverage-cache path compounds this: its coverage-write descriptor
(`Sources/LabanRenderer/SlugGlyphRenderer.swift` lines 359–363) sets no blend,
so it defaults to **replace**, and all glyphs are drawn in one instanced call —
overlapping quads at a seam keep only the last instance's coverage, then the
per-glyph sample passes composite that wrong coverage twice.

### Second root cause — additive composite over-coverage (the actual btop trigger)

The per-glyph-over bug above is what accumulate-once fixes. The **user's
reported btop artifact** is a second, distinct bug that the accumulate-once
rework *exposes* on the **additive** composite path (light glyph on dark
background — btop draws its `│` frames as grey `#303030` on black):

1. The `│` box-drawing glyph's outline **ink height exceeds the cell pitch**
   (e.g. at the captured 13.75 pt font, ink height ≈ 20.9 pt vs cell height
   19 pt). The terminal tiles `│` at the cell pitch, so abutting `│` **overlap
   at every seam even at rest (integer Y origins)** — no fractional scroll
   shift is needed to reproduce.
2. The accumulate pass sums `glyphColor · perChannelCoverage · α` additively
   into `colorAccum`, and the matching per-channel coverage into `coverageAccum`.
   At an overlapping seam the summed per-channel coverage exceeds 1.0 (observed
   ~1.44 → seam pixel 69 vs stem 48, i.e. `48 · 1.44 ≈ 69`).
3. The darken composite correctly `saturate()`s its coverage, so it clears the
   background fully at the seam. But the additive composite
   (`subpixelCompositeAdditiveFragment`) emitted `colorAccum.rgb` **unclamped**,
   so it added `glyphColor · summedCoverage` — *more than the glyph color* —
   making the seam **brighter than the glyph stem itself**. That is exactly the
   "brighter pixels at the intersection" the user reported, and it is absent in
   grayscale (which stays on the per-glyph over path with no accumulate step).

## Fix

Restructure the subpixel path to **accumulate, then composite once**:

1. Accumulate per-channel coverage additively (clamped on read) across all
   glyphs into a coverage buffer, and accumulate premultiplied foreground
   (`fg·cov·α`) additively into a color buffer — one MRT pass per glyph quad.
2. Composite once with a full-screen quad: `result = bg·(1−saturate(cov)) + color`,
   implemented as the existing darken blend then additive blend, each reading
   the accumulation textures.
3. **Clamp the additive composite to the glyph color** (the actual btop fix):
   `subpixelCompositeAdditiveFragment` now also reads `coverageAccum` and emits
   `colorAccum.rgb / max(coverageAccum.rgb, 1.0)`. Since
   `colorAccum = glyphColor · summedCoverage`, dividing by
   `max(summedCoverage, 1)` restores `glyphColor` where the summed coverage
   exceeds 1.0 (overlapping light-on-dark seams) and is a no-op elsewhere. This
   is symmetric with the darken path's existing `saturate()` on coverage.

At an abutting same-color seam, `cov_acc = c1 + c2 = c_full`, so the seam
equals the steady interior. For a single glyph, accumulate-once equals "over",
so non-seam pixels are unchanged. Grayscale keeps its existing per-glyph
`glyphAlphaPipeline` (over) path — untouched, no regression.

## Progress

- [x] Metal shaders: MRT accumulate fragments (Slug analytic, Vector atlas),
      shared full-screen vertex, shared composite darken + additive fragments,
      additive accumulation blend config. (2026-07-03)
- [x] Slug: replace coverage-write + per-glyph sample passes with MRT
      accumulate (coverage + color textures) + full-screen composite. (2026-07-03)
- [~] Vector: add coverage + color accumulation textures, MRT accumulate pass
      (per clip, additive into shared textures cleared once per frame), single
      full-screen composite after solids.
      **Deferred.** The Vector renderer keeps box-drawing `│` vertical edges
      pixel-crisp (pure 0/255, no vertical AA at the seam) in crisp, fluid, and
      per-phase scroll modes (verified by stem-column profile dumps in all three
      modes). With no vertical AA ramp at the cell-boundary seam, the c1*c2
      notch does not reproduce under unit-test conditions, so an accumulate-once
      rewrite has no verifiable benefit and risks the Vector fidelity gates for
      nothing. Revisit only if a real btop-on-scrolled-terminal reproduction
      surfaces. The shared shaders/blend config added for Slug remain available.
- [~] Shader cache: build the new accumulate + composite pipelines.
      Slug builds its own accumulate + composite pipelines in `init?` (no
      `VectorGlyphShaderCache` change needed while Vector is deferred).
- [x] Regression test: stacked `│` seam, Slug renderer, RGB subpixel — seam
      pixel no brighter than steady interior; fails before (median 255 / min 0
      gap at the seam from the per-glyph over + coverage-cache overwrite), passes
      after (accumulate-once). `SubpixelSeamAccumulateTests`. (2026-07-03)
- [x] Additive-composite clamp: `subpixelCompositeAdditiveFragment` reads
      `coverageAccum` (texture 1) and divides `colorAccum` by
      `max(coverage, 1)` so overlapping light-on-dark `│` seams emit the glyph
      color, not `glyphColor · summedCoverage`. Slug binds `coverageAccum` to
      fragment texture 1 for the additive composite pass. (2026-07-04)
- [x] Regression test: light-on-dark stacked `│` seam, Slug, RGB subpixel —
      `testSlugStackedBoxDrawingSeamIsNotBrighterThanInteriorLightOnDark`.
      Red→green verified: pre-fix seam ink 186 < stem 207 (gap 21, fails at the
      15-point band); post-fix seam matches stem (passes). Reproduces at integer
      origins because the `│` ink height (27.4 pt at 18 pt) exceeds the cell
      pitch (24 pt), so abutting `│` overlap at every seam. (2026-07-04)
- [x] Build + run `LabanRendererTests`; confirm no fidelity-gate regressions.
      `SlugGlyphAAFidelityTests` (12 gates) green with the fix. Full suite: 266
      tests, only `VectorZoomGlyphSizeConsistencyTests.testGlyphSizesStaySingleAcrossZoomCommits`
      fails — and it fails identically on clean main (pre-existing,
      environment-dependent Vector live-zoom frame-scheduling flake), not a
      regression from this change. (2026-07-04)
- [x] Seam + Slug + fidelity re-run after the additive clamp: 43 tests, 1
      skipped, 0 failures. (2026-07-04)

## Capture reproduction findings (2026-07-04, definitive)

A real btop PTY capture
(`~/Library/Logs/Laban/captures/appkit-2026-07-03T20-06-43Z`, Slug backend,
3024x1898 @2). The captured `│` row pitch is 19 device-px cells; inferring the
`FontAtlas` whose `cellSize.height` matches (13.75 pt) reproduces the captured
frame at the right scale. Frames were re-rendered through a Slug probe with
`rgbStripe` to inspect the seam directly.

### btop `│` geometry — natural overlap at rest

At 13.75 pt the `│` outline **ink height ≈ 20.9 pt exceeds the cell pitch 19
pt**, so the terminal's cell-pitch tiling makes abutting `│` **overlap at every
seam even with integer Y origins**. No fractional scroll shift is required to
reproduce the artifact — the earlier "fractional-scroll-only" reading was an
artifact of the first capture's at-rest frame not being measured at the right
point size.

### btop `│` is grey-on-black → additive composite path

btop draws its frame `│` as a **grey `#303030` glyph on a black `#000000`
background**, which takes the **additive** composite path
(`dst += color`), not the darken path. The earlier olive-on-cream reading came
from a different btop UI element; the canonical frame `│` is grey-on-black.

### The notch: seam brighter than the glyph color

Probe measurements on the re-rendered btop frame (and reproduced in the
synthetic light-on-dark test):

| region              | pixel RGB | ink (255−min) | meaning |
|---------------------|-----------|--------------:|---------|
| steady `│` stem     | (48,48,48)   | 207 | glyph color at ~100 % coverage |
| seam (pre-fix)      | (69,69,69)   | 186 | **brighter than the glyph color** |
| seam (post-fix)     | (48,48,48)   | 207 | matches the stem |

`69 = 48 · 1.44`: the summed per-channel coverage at the overlapping seam is
~1.44, and the pre-fix additive composite emitted `glyphColor · summedCoverage`
unclamped, so the seam is brighter than the glyph itself. Grayscale has no
accumulate step (per-glyph over) and shows no such notch.

### Earlier "neutral / coverage / background-discontinuity" readings — superseded

An earlier second-pass A/B concluded the accumulate-once fix was **neutral** on
this artifact and attributed the notch to a row-rect background discontinuity
or a `slugGlyphCoverageRGB` coverage difference. That conclusion was wrong: it
was measured on the **olive-on-cream** `│` (darken path, where `saturate()`
already clamps) rather than the canonical **grey-on-black** `│` (additive
path), and it predated the `coverageAccum` clamp. The definitive isolation is
the additive-path clamp below: zeroing it reproduces the 48→69 notch;
reinstating it makes the seam match the stem at 48. The notch is a composite
over-coverage on the additive path, and the fix is the
`colorAccum / max(coverageAccum, 1)` clamp in
`subpixelCompositeAdditiveFragment`.

## Decision Log

- Decision (revised 2026-07-04, definitive): the accumulate-once Slug change
      **plus the additive-composite clamp IS the fix** for the user's reported
      btop `│` seam artifact.
  Rationale: the btop `│` is grey-on-black, so it takes the **additive**
  composite path. The `│` outline ink height (20.9 pt at 13.75 pt) exceeds the
  cell pitch (19 pt), so abutting `│` overlap at every seam at rest, and the
  accumulate pass sums per-channel coverage past 1.0 (~1.44). The pre-fix
  additive composite emitted `glyphColor · summedCoverage` unclamped → seam
  pixel 69 > glyph 48 (brighter than the glyph). The fix
  (`subpixelCompositeAdditiveFragment` divides `colorAccum` by
  `max(coverageAccum, 1)`) clamps the emitted color to the glyph color, making
  the seam match the stem. Verified red→green on
  `testSlugStackedBoxDrawingSeamIsNotBrighterThanInteriorLightOnDark`
  (pre-fix seam ink 186 < stem 207; post-fix 207). The earlier "second-pass"
  reading that the fix was neutral was measured on the olive-on-cream `│`
  (darken path, already clamped by `saturate()`) rather than the canonical
  grey-on-black `│` (additive path) — superseded.
  Date: 2026-07-04

- Decision: ship the Slug accumulate-once fix and Slug seam regression test;
      defer the Vector accumulate-once rewrite.
  Rationale: the Slug path is fixed and verified red->green. The Vector renderer
      keeps `│` vertical edges pixel-crisp (no vertical AA at the seam) in every
      mode drivable from a unit test, so the seam artifact does not reproduce there
      and a Vector rewrite is unverifiable. The user's Vector observation may stem
      from a specific live-scroll/font condition not captured here; pursue only with
      a concrete reproduction to avoid regressing the Vector fidelity gates.
  Date: 2026-07-03

- Decision: accumulate coverage and premultiplied color in two float textures,
  composite once with a full-screen quad.
  Rationale: the per-glyph "over" operator cannot sum abutting coverage; only
  accumulation does. Storing premultiplied color (not just coverage) preserves
  per-glyph foreground colors at the composite. MRT writes both in one pass so
  Slug's analytic coverage band-walk still runs once per glyph.
  Date: 2026-07-03

- Decision: keep grayscale on the existing per-glyph over path.
  Rationale: grayscale's seam notch is imperceptible (`h²` small) and the user
  reports no grayscale artifact; changing it risks the grayscale fidelity gates
  for no user-visible benefit.
  Date: 2026-07-03

## Context and Orientation

- `Sources/LabanRenderer/VectorGlyphShaders.metal` — all GPU shaders for both
  curve renderers. `slugGlyphCoverageRGB` (line ~840) computes per-channel
  analytic coverage; `slugGlyphCoverageFragment`/`slugGlyphColorFragment` are
  the per-glyph over passes; `vectorGlyphCoverageFragment`/`vectorGlyphColorFragment`
  sample the baked coverage atlas for the Vector renderer.
- `Sources/LabanRenderer/SlugGlyphRenderer.swift` — analytic curve renderer.
  `render()` (line ~610) opens a coverage-write encoder then a main encoder.
  The coverage-write descriptor (line 359) has no blend (replace). Sample passes
  at lines 735–748 draw all glyphs per pass.
- `Sources/LabanRenderer/VectorGlyphRenderer.swift` — atlas-based curve
  renderer. `encode()` (line ~1040) clears the target, then `flush()` (line
  ~1087) draws solids, then glyph coverage+color (lines 1115–1126), then
  raster/color, once per clip region.
- `Sources/LabanRenderer/VectorGlyphShaderCache.swift` — process-wide cache of
  the compiled library + pipeline states shared by both renderers' Vector
  shaders. New pipelines must be added here (and the Slug renderer builds its
  own pipelines in its `init?`).
- `configureSubpixelCoverageBlend` / `configureAdditiveRGBPreserveAlphaBlend`
  (`VectorGlyphRenderer.swift` lines 2419, 2432) are the darken and additive
  blends reused by the composite pass.
- `Tests/LabanRendererTests/SlugGlyphAAFidelityTests.swift` — the AA fidelity
  gates (ink mass, gradient, fringing budgets) the change must not regress.

## Plan of Work

### Shaders (`VectorGlyphShaders.metal`)

Add:
- `struct MRTAccumOut { float4 coverage [[color(0)]]; float4 color [[color(1)]]; }`.
- `slugGlyphAccumulateFragment` — wraps `slugGlyphCoverageRGB`, writes
  `coverage·α` to color(0) and `in.color.rgb·coverage·α` to color(1).
- `vectorGlyphAccumulateFragment` — samples the atlas coverage, writes the same
  two attachments.
- `struct FullscreenOut { float4 position [[position]]; };` and
  `vectorFullscreenVertex` — a 3-vertex full-screen triangle in NDC.
- `subpixelCompositeDarkenFragment` — reads the coverage accum texture at
  `in.position.xy`, returns `saturate(cov)`; used with
  `configureSubpixelCoverageBlend`.
- `subpixelCompositeAdditiveFragment` — reads the color accum texture, returns
  its RGB; used with `configureAdditiveRGBPreserveAlphaBlend`.

### Blend config

Add `configureAdditiveAccumBlend(_:)` (rgb: src=one, dst=one, add; alpha:
src=zero, dst=one) for the two accumulation attachments.

### Slug renderer

- Replace `coverageTexture` (single rgba16Float) with two textures:
  `subpixelCoverageAccum` and `subpixelColorAccum`, both rgba16Float, private,
  `[.renderTarget, .shaderRead]`, recreated on resize.
- Replace the coverage-write encoder + `glyphCoverageSamplePipeline` +
  `glyphColorSamplePipeline` with:
  - An accumulate encoder: MRT render pass, `loadAction = .clear` (clear 0) on
    both attachments, `storeAction = .store`; draw all glyph quads with the
    `slugGlyphAccumulateFragment` pipeline (additive blend on both
    attachments).
  - A composite step in the main encoder, after solids: two full-screen draws
    (darken then additive) reading the accum textures. Set the viewport to the
    target size.
- Keep the grayscale `glyphAlphaPipeline` path unchanged.
- Drop the now-unused `glyphCoverageWritePipeline`, `glyphCoverageSamplePipeline`,
  `glyphColorSamplePipeline`, and `slugGlyphCoverageSampleFragment`/
  `slugGlyphColorSampleFragment` usage (remove pipelines + the coverage texture
  field).

### Vector renderer

- Add `subpixelCoverageAccum` and `subpixelColorAccum` textures (rgba16Float,
  private, `[.renderTarget, .shaderRead]`), recreated on resize and cleared to
  0 once per frame.
- In `encode()`: open an accumulate encoder **before** the main encoder; for
  each clip segment, set the scissor and draw that segment's analytic glyphs
  with the `vectorGlyphAccumulateFragment` pipeline (MRT, additive). Clear the
  accum textures at the start of this encoder.
- In the main encoder: after solids are drawn, run the composite once
  (full-screen darken + additive) reading the accum textures; then draw raster
  and color glyphs as today. Restructure `flush()` so the per-clip glyph
  coverage+color draws are replaced by the accumulate encoder draws, and the
  composite is a single full-screen step after all solids.
- Add the new pipelines to `VectorGlyphShaderCache` (accumulate MRT + composite
  darken + composite additive), keyed by the same `(device, pixelFormat)`.
- Keep grayscale on `glyphCoveragePipeline`/`glyphColorPipeline`? No —
  grayscale uses `rasterGlyphPipeline`/alpha path. Confirm and leave grayscale
  untouched.

### Test

Add `Tests/LabanRendererTests/SubpixelSeamAccumulateTests.swift`:
- For each of Slug and Vector, render two stacked `│` glyphs in the same column
  with `rgbStripe` (or `calibratedRGB`) on a solid background, integer cell
  height, and assert the seam pixel row's max-channel value is not greater than
  the steady-interior row's max-channel value within a small tolerance (e.g.
  seam ≤ interior + 4/255). Before the fix the seam is ~25 % brighter in the
  dominant channel, so the assertion fails.
- Also assert grayscale shows no such regression (sanity, unchanged).

## Concrete Steps

Run from the repo root `/Users/user/wrk/laban`.

Build the renderer target:

    swift build --target LabanRenderer

Run the renderer tests (Metal device required; tests skip without one):

    swift test --filter LabanRendererTests

Run just the new seam test:

    swift test --filter LabanRendererTests.SubpixelSeamAccumulateTests

## Validation and Acceptance

- `swift build --target LabanRenderer` succeeds.
- `swift test --filter LabanRendererTests` passes, including the existing
  `SlugGlyphAAFidelityTests` gates (ink mass, gradient, fringing budgets) —
  non-seam pixels are unchanged so these stay green.
- `SubpixelSeamAccumulateTests` fails before the renderer changes and passes
  after, for both Slug and Vector, RGB subpixel. Grayscale sanity passes.
- Manual: enable Slug or Vector Glyph renderer with RGB subpixel AA, run btop,
  observe vertical `│` frames have no brighter notch where characters meet.

## Idempotence and Recovery

The change is additive at the shader level (new fragments/vertex) and a
swap of the subpixel composite path. Grayscale is untouched. To revert, restore
the per-glyph coverage/color passes and the single coverage texture; the new
shaders/pipelines can remain (unused) or be removed.

## Artifacts and Notes

The seam error term `c1·c2·(bg−fg)` per channel is the whole bug. For the
dominant subpixel channel `c1·c2` can reach ~0.25; accumulate-once makes
`cov_acc = c1 + c2 = c_full` at an abutting seam, eliminating the term.
