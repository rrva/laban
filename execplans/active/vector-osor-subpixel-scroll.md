# Vector text: full OSOR pipeline — Retina-crisp, display-robust, smooth sub-pixel scrolling

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at the
repository root). Keep `Progress` and `Validation and Acceptance` current as work
proceeds. Add optional sections only when they hold information a fresh contributor
needs.

## Purpose / Big Picture

Laban has an optional GPU text backend, the **vector glyph renderer**
(`Sources/LabanRenderer/VectorGlyphRenderer.swift`), that rasterizes font outlines
directly on the GPU instead of using a pre-baked CoreText bitmap atlas. It follows
the approach described by Rubén Osorio López in "Rendering Crispy Text On The GPU"
(referred to here as **OSOR** — the author's handle; the technique, not a library).
The core idea, restated so this plan is self-contained:

- Convert every glyph outline to **quadratic Bézier curves** (a curve defined by 3
  points: start, one control point, end). Straight lines become a quadratic with the
  control point at the midpoint; cubic Béziers (4 points) are split into two
  quadratics.
- For each texel of a glyph, shoot a **horizontal ray** and count how many times it
  crosses the outline (the **winding number**); inside the glyph the count is
  non-zero. This yields **coverage** (how much of the texel is ink, 0..1).
- Take many jittered samples per texel over successive frames and average them
  (**temporal accumulation**) into a **resident atlas** (one big GPU texture holding
  many glyphs). A glyph stays in the atlas as long as it is used, refining toward
  high-quality anti-aliasing. Anti-aliasing (**AA**) = softening the hard edge of a
  glyph by partial coverage so it does not look jagged.
- Optionally, instead of one sample area per texel, sample three offset areas — one
  per **subpixel** (the physical red/green/blue stripes inside a monitor pixel) — to
  triple horizontal resolution. This is **subpixel AA**. Its quality depends entirely
  on matching the monitor's physical subpixel layout; a mismatch produces colored
  edges (**fringing**).

What someone gains after this ExecPlan:

1. **On a MacBook Retina display, text looks visibly better than today** — crisp,
   correctly-weighted (gamma-correct) grayscale anti-aliasing that matches or beats
   the classic CoreText backend.
2. **The renderer is robust across the whole MacBook line and future models** — it
   adapts to any backing scale factor and display color space, reconfigures live when
   the window moves between displays, and never fringes by default.
3. **Smooth sub-pixel scrolling** — when scrollback scrolls by a fraction of a row,
   glyphs are rasterized and cached *per sub-pixel phase* and placed at their true
   fractional position, so motion is smooth instead of snapping row-to-row, while
   each resting frame still converges to full quality.
4. **Power users on external monitors can opt into subpixel AA** calibrated to their
   panel (including non-standard OLED layouts), with safe auto-disable where it can't
   help.

How to see it working: build and install the app
(`./scripts/build-app && ./scripts/install-app`), switch the renderer to
"Vector glyph" (Renderer menu), and (a) read static text — it should be crisp and
correctly weighted; (b) hold a smooth scroll — text should glide, not jump, and stay
sharp once it settles. Autonomous gates (XCTest + the headless `laban-agent`
harness) prove each property without a human eye.

## Display reality this plan is built on (read first)

These facts shape every decision below; a contributor must not "add subpixel AA
everywhere" without understanding them.

- **macOS removed subpixel font smoothing in 2018 (Mojave).** Apple ships grayscale
  AA on Retina because at ~218–254 pixels-per-inch the eye cannot resolve a single
  pixel, so grayscale already looks excellent and never fringes. Our **default must be
  grayscale**, matching CoreText. Subpixel AA is an opt-in for specific external
  panels.
- **The target dev display:** MacBook Pro 14" (M2 Max, 2023), Liquid Retina XDR,
  3024×1964 native, backing scale factor 2.0, standard vertical-stripe RGB subpixels.
  "Looks perty here" = excellent gamma-correct grayscale at scale 2.
- **macOS "scaled" display modes resample the framebuffer.** When a user picks "More
  Space", macOS renders the app framebuffer at 2× a *larger* logical size, then the
  display engine **downscales** it to the physical panel. Subpixel AA cannot survive
  that resample, and even grayscale is softened. Therefore subpixel AA must
  **auto-disable** unless the framebuffer maps 1:1 to the panel (integer scale, no
  downscale). Grayscale degrades gracefully and stays the default.
- **macOS does not expose a display's physical subpixel layout** (OSOR laments this
  too). So subpixel AA can never be a safe *automatic* default; it requires explicit
  user calibration. Grayscale needs no panel knowledge and is always safe.

Conclusion encoded throughout: **grayscale is the star on Apple hardware; subpixel AA
is a power-user opt-in for external panels.** Smooth sub-pixel scrolling is
independent of subpixel AA — it works in grayscale (rasterize the grayscale mask per
sub-pixel phase).

## Context and Orientation

Key files (full repository-relative paths):

- `Sources/LabanRenderer/VectorGlyphRenderer.swift` — the backend. Builds per-frame
  instances, manages the mask atlas, calls the rasterizer, blits to the layer. The
  per-frame mask residency is `ensureResidentMask(...)`; glyph geometry is computed in
  `maskDescriptor(...)`; the on-screen quad in `glyphInstance(...)`.
- `Sources/LabanRenderer/VectorGlyphShaders.metal` — Metal shaders. Winding math is
  `winding_contribution`; the production rasterizer is the compute kernel
  `vectorGlyphAccumulateAtlas` (512 jittered samples accumulated); the screen blend is
  configured in Swift by `configureSubpixelCoverageBlend` /
  `configureAdditiveRGBPreserveAlphaBlend`.
- `Sources/LabanRenderer/VectorGlyphScratchRasterizer.swift` — Swift wrapper that
  encodes the rasterize/accumulate kernels (`encodeAccumulate`, `rasterize`).
- `Sources/LabanRenderer/VectorGlyphMaskAtlas.swift` — CPU-side atlas bookkeeping:
  the cache `Key`, slot reservation, transposed-Morton (Z-order) packing,
  `sampleCount` tracking. **No eviction or last-used tracking today.**
- `Sources/LabanRenderer/VectorSubpixelLayout.swift` — subpixel sample-area presets
  (`grayscale`, `rgbStripe`, `calibratedRGB`, …) and persistence. `VectorSubpixelArea`
  currently locks the sample area's y-range to [0,1].
- `Sources/LabanRenderer/GlyphCurveStore.swift` — CoreText outline → quadratic curves;
  also `GlyphCurveCPUOracle`, a CPU ground-truth winding/coverage used by tests.
- `Sources/LabanCore/FrameProducer.swift` — turns a terminal snapshot into
  `FrameCommand`s (glyph runs with point origins). Cells use integer `cw`/`ch`.
- `Sources/LabanApp/TerminalBitmapView.swift` — owns scrolling. Already has
  `subCellRows` / `fractionalScrollOffset` / `scrollAnimating` state
  (`shouldForceFullDamage`, ~line 1623) used by the classic path; the vector path does
  not yet consume a fractional offset.
- `Tests/LabanRendererTests/VectorGlyphSizeSweepTests.swift` — the autonomous size
  sweep added in M0 (GPU-vs-oracle and accumulate-vs-supersampled-oracle).
- Headless harness: `docs/process/dev-process.md` describes the `laban-agent`
  debug/HTTP runtime (`/debug/render`, `/debug/screenshot`, `startCapture`). Scripts
  `scripts/vector-glyph-parity-matrix` and `scripts/vector-renderer-switch-smoke`
  exist for vector verification.

Definitions used below:
- **Backing scale factor** — `NSScreen.backingScaleFactor`: device pixels per point
  (2.0 on Retina, 1.0 on a non-Retina external display).
- **Sub-pixel phase** — the fractional part of a glyph's device-pixel position,
  `frac(pixel_pos)`. AA computed for one phase is only correct at that phase, so
  smooth motion needs a mask per phase.
- **Gamma-correct blending** — compositing coverage in linear light rather than in
  the display's non-linear (gamma) encoding. Blending AA in gamma space makes thin
  light-on-dark text too thin and dark-on-light too heavy; CoreText blends
  gamma-corrected. Today both renderers use a plain `.bgra8Unorm` target and blend in
  gamma space.

Current baseline (already landed): commit `af4380d` made `winding_contribution`
numerically stable (Vieta/Numerical-Recipes roots + FMA discriminant), fixing
size-dependent garbling of straight-stroke glyphs, and added
`VectorGlyphSizeSweepTests`. That is **M0** and is complete.

## Milestones

Order is chosen so the user-visible Retina win and robustness land first, the opt-in
subpixel work next, and the smooth-scroll machinery last (it is the largest and
depends on the atlas-residency rework).

### M0 — Numerically stable winding (DONE)

Already shipped at `af4380d`. Acceptance: `swift test --filter VectorGlyphSizeSweep`
passes; both sweep tests fail on the pre-`af4380d` shader and pass after.

### M1 — Gamma-correct grayscale, tuned for Retina

Scope: make grayscale AA the high-quality default and blend it gamma-correctly. This
is the single biggest "looks perty" lever on a Retina panel and is display-safe
everywhere.

What will exist that didn't: a gamma-correct coverage→screen blend for the vector
backend, verified to weight stems like CoreText within tolerance.

Approach:
- Composite glyph coverage in linear space. Two viable routes; pick per the Decision
  Log after a prototype: (a) make the render target / layer sRGB-aware
  (`.bgra8Unorm_srgb`) so the fixed-function blend operates on linear values; or
  (b) keep `.bgra8Unorm` and apply an explicit gamma curve to coverage in the
  fragment shader (a "text gamma" like CoreText's ~2.2/1.45 stem-darkening). Route (a)
  is cleaner if it does not disturb the classic backend or solid fills; route (b) is
  more surgical.
- Confirm the default layout is `grayscale` (it is in `VectorSubpixelLayout.persisted`)
  and that nothing forces `rgbStripe` on first run.

Acceptance (autonomous):
- New test renders representative glyphs (`H E o l . / 8`) at sizes 13–18pt, scale 2,
  via the vector backend and via the classic `MetalRenderer`/CoreText path, and
  asserts mean stem luminance agrees within a tolerance (e.g. ≤ 8/255). This fails
  before M1 (gamma-space blend is visibly lighter/heavier) and passes after.
- `swift test --filter VectorGlyph` stays green.

### M2 — Display robustness across the MacBook line

Scope: adapt to any display and react to live changes; never fringe by default.

What will exist that didn't: explicit display-capability detection feeding the vector
backend, and an auto-policy that selects grayscale unless conditions are right for
subpixel AA.

Approach:
- Detect, from `NSScreen` / the window: `backingScaleFactor`, color space, and whether
  the current mode is a **scaled (downsampled)** mode (compare the window's
  backing-pixel size to the screen's native panel resolution; if the framebuffer is
  not 1:1 with the panel, treat as scaled). Surface this to `LabanCore` as a small
  value type (no AppKit in `LabanCore`, per AGENTS.md) and wire it into both
  `MainWindowController.makeAndShow` and `HeadlessDebugRuntime`.
- React to `NSWindow.didChangeBackingProperties` and screen-change notifications by
  calling the existing `VectorGlyphRenderer.resize(pixelWidth:pixelHeight:scale:)` and
  re-evaluating the subpixel policy. Moving the window to a 1× external display must
  re-bake masks at the new scale (the atlas already invalidates on scale change).
- Auto-policy: if the user selected a subpixel layout but the display is scaled /
  unknown, fall back to grayscale for rendering while preserving the user's stored
  preference; expose the effective layout in `/debug/render` (the field
  `vectorSubpixelLayout` already exists).

Acceptance (autonomous):
- Unit tests over the policy: (scaled mode → grayscale), (integer scale + explicit
  layout → that layout), (scale change → atlas reset). Pure-logic, no GPU.
- Headless: drive `laban-agent` at scale 1 and scale 2, confirm `/debug/render`
  reports the expected effective layout and cell metrics, and a screenshot renders
  without crashing at both scales.

### M3 — OSOR subpixel calibration done right (opt-in)

Scope: for users on external panels who opt in, make subpixel AA actually fringe-free
per OSOR's central finding, and support non-stripe layouts.

What will exist that didn't: subpixel sample areas that **overlap and bleed outside
the pixel**, **2D** area calibration, real-monitor presets, and a fringing metric.

Approach:
- Replace `rgbStripe`/`calibratedRGB` with OSOR-correct defaults: per-subpixel sample
  areas wider than 1/3 of a pixel, overlapping neighbors, and allowed to extend past
  [0,1] (light bleeds from identical neighboring pixels). `VectorSubpixelArea` already
  permits `min<0`/`max>1`; the presets must use it.
- Lift `VectorSubpixelArea` so the y-range is calibratable too (not locked [0,1]),
  enabling non-vertical-stripe layouts (QD-OLED, WOLED RWBG). Update the calibration
  UI in `Sources/LabanApp/SettingsWindowController.swift` accordingly and keep
  persistence round-tripping (extend `VectorSubpixelLayoutTests`).
- Add coverage extreme-clamping in the resolve step (`≈0.002→0`, `≈0.998→1`) for
  crisper stems.

Acceptance (autonomous):
- **Fringing metric** test: render a white-on-black vertical and diagonal stroke at
  scale 2 with (i) grayscale and (ii) a chosen RGB layout; compute mean edge *chroma*
  (max channel − min channel along edge pixels). Assert grayscale chroma ≈ 0, and the
  OSOR-overlap layout's chroma is below a threshold and strictly lower than the
  non-overlapping-thirds `rgbStripe` it replaces. This makes "we implemented OSOR
  subpixel correctly" mechanically checkable.
- `VectorSubpixelLayoutTests` round-trips 2D custom layouts.

### M4 — Sub-pixel-offset glyph caching (off-grid correctness)

Scope: rasterize and cache a glyph per quantized sub-pixel phase, and place quads at
their true fractional position. This is the prerequisite for smooth scrolling.

What will exist that didn't: `VectorGlyphMaskAtlas.Key` carries a quantized sub-pixel
offset; masks rasterize for that phase; a glyph drawn at a fractional position is
correct (not snapped/blurred).

Approach:
- Extend `Key` with `quantizedOffsetX/Y` (OSOR's u0.8 — fixed-point fraction, 1/256
  resolution; quantizing collapses near-identical positions to one cache entry).
- In `maskDescriptor(...)`, accept the glyph's fractional device-pixel offset and bias
  the rasterization `origin` so the GPU sample grid lands at the on-screen phase.
- In `glyphInstance(...)`, stop assuming an integer position; place the quad at the
  true fractional device-pixel position corresponding to the cached phase.
- Static (non-scrolling) text keeps offset 0 (integer cells) → same single cache
  entry as today; no regression for the common case.

Acceptance (autonomous):
- Extend the size sweep to a set of fractional phases (e.g. 0, 1/4, 1/3, 1/2): the
  production accumulate path vs the supersampled oracle at each phase, gross-pixel
  (>80/255) disagreement must be ~0. (The M0 accumulate test already has the harness;
  add the phase loop with the AA gross threshold, not binary point-sampling.)
- A test asserting two different quantized phases of the same glyph produce *different*
  masks and *different* atlas entries.

### M5 — Atlas eviction and bounded per-frame work

Scope: keep the atlas bounded when many phases churn during a scroll, and keep
per-frame rasterization cost bounded so motion stays smooth.

What will exist that didn't: per-frame "touch"/last-used tracking, eviction of unused
entries, a per-frame total-sample budget, and OSOR's front-loaded refine schedule
reconciled with the existing "settled first paint".

Approach:
- Track a frame counter; mark each entry used when referenced in a frame; at end of
  frame free entries unused for N frames (OSOR's keep-or-free sweep). Today
  `VectorGlyphMaskAtlas` only `remove`s on rasterize failure.
- Size the atlas sensibly and **cap it regardless of system RAM** (96 GB on the dev
  box must not tempt an unbounded atlas — GPU memory and cache locality still matter).
  Allow the cap to scale modestly on higher-end GPUs but keep a hard ceiling; if the
  atlas is full, evict LRU then fall back to the raster path for the frame.
- Sample schedule: keep full-quality first paint for *static* glyphs, but introduce a
  **per-frame global sample budget** so that when many new phases appear in one frame
  (active scroll) each gets OSOR's front-loaded 8→4→2→1 instead of a full 512, with
  convergence to 512 once motion settles. `accumulationSamplesThisFrame` becomes
  budget-aware.

Acceptance (autonomous):
- Eviction stress test: simulate referencing many (glyph, phase) keys over many frames
  exceeding atlas capacity; assert the atlas never exceeds its slot count, live keys
  survive, and stale keys are freed (deterministic, CPU-only on
  `VectorGlyphMaskAtlas`).
- Budget test: with a low per-frame budget and many new keys in one frame, assert
  total samples encoded that frame ≤ budget and every key still becomes resident
  (lower quality, not missing).

### M6 — Smooth sub-pixel scroll, end to end

Scope: feed the existing fractional scroll offset into the vector path and prove the
whole thing on the headless harness.

What will exist that didn't: scrolling the terminal by a sub-cell amount renders
glyphs at the matching sub-pixel phase through the vector backend, smoothly.

Approach:
- Plumb `TerminalBitmapView`'s `subCellRows` / fractional offset into
  `FrameProducer` glyph-run origins on the vector path (a fractional device-pixel y
  added to each row's baseline). The classic path is unaffected.
- Ensure damage handling already forces full repaint during fractional offset
  (`shouldForceFullDamage` already returns true for `fractionalScrollOffset`).
- Add a line to `docs/product/spec.md` recording smooth sub-pixel scrolling for the
  vector renderer as intended product behavior (this milestone expands product scope,
  per AGENTS.md).

Acceptance (autonomous + observable):
- Headless: drive a scroll animation via `laban-agent`, capture frames at several
  fractional offsets, and assert via `/debug/render` that the vector backend stayed
  effective (no fallback) and that captured glyph rows shift by sub-pixel amounts
  between frames (compare row centroids; expect monotonic fractional shift).
- Manual: `./scripts/install-app`, scroll scrollback slowly with the vector backend —
  text glides and stays sharp once settled. Recorded as an artifact (asciinema/cast or
  screenshot series) per the project's autonomous-verification rule.

## Progress

- [x] (2026-06-28) M0 — numerically stable winding + size-sweep gates (commit `af4380d`).
- [x] (2026-06-28) M1 — gamma-correct grayscale via sRGB render target (vector-only; classic untouched), plus a user-tunable **text weight** (stem-darkening) setting (`VectorTextWeightSettings`, live Settings slider, 0 = thin/geometric, 1 = CoreText-ish; default 1.0). Gates: `VectorGlyphGammaTests` (linear-light compositing) and `VectorTextWeightTests` (exponent neutral@0, thickens@1, dark-on-light > light-on-dark, persistence). All `VectorGlyph`/`GlyphCurveStore`/`VectorSubpixelLayout` suites green; bundle builds. Awaiting manual visual confirmation on the MacBook before M2.
- [ ] M2 — display robustness (scale/color-space/scaled-mode detection, live reconfig, grayscale auto-policy).
- [ ] M3 — OSOR subpixel calibration: overlap/bleed, 2D areas, presets, fringing gate.
- [ ] M4 — sub-pixel-offset glyph caching + fractional-phase raster + fractional placement.
- [ ] M5 — atlas eviction + bounded per-frame sample budget + front-loaded schedule.
- [ ] M6 — smooth sub-pixel scroll plumbing + end-to-end gate + spec.md note.

## Decision Log

- Decision: Grayscale AA is the default and primary quality target; subpixel AA is an
  opt-in for external panels with auto-disable on scaled/unknown displays.
  Rationale: macOS dropped subpixel font smoothing in 2018; Retina panels look best
  with grayscale and fringe with mismatched subpixel layouts; macOS does not expose a
  panel's subpixel structure, so subpixel AA cannot be a safe automatic default. This
  is what makes the renderer robust across the whole MacBook line.
  Date/Author: 2026-06-28 / initial plan.
- Decision: Pursue smooth sub-pixel scrolling via OSOR's per-phase glyph caching
  (sub-pixel-offset atlas keys), not pixel-snapping.
  Rationale: user explicitly wants smooth sub-pixel scrolling; pixel-snapping would
  make motion jump row-to-row. This forces in atlas eviction and a bounded per-frame
  sample budget (M5), which is why those are explicit milestones.
  Date/Author: 2026-06-28 / initial plan.
- Decision: The classic/other renderers are NOT oracles; the vector renderer may
  depart from them. Gates assert against ground-truth math (e.g. linear-light
  compositing, the CPU winding oracle), never against the classic renderer's output.
  Rationale: user directive 2026-06-28; the vector path is meant to improve on the
  shipped look, so pinning it to classic would block the improvement.
  Date/Author: 2026-06-28 / user directive.
- Decision: M1 weight target is CoreText-match, but the renderer is free to depart
  from CoreText's extra stem weight where it improves readability/UX.
  Rationale: user directive 2026-06-28.
  Date/Author: 2026-06-28 / user directive.
- Decision: Execution pauses at each milestone gate for manual visual inspection on
  the user's display, announced via the macOS `say` command; do not auto-advance.
  Rationale: user directive 2026-06-28; perceptual quality is best judged on-device.
  Date/Author: 2026-06-28 / user directive.
- Decision: Cap atlas/GPU memory with a hard ceiling independent of system RAM.
  Rationale: traction across all MacBooks (not just a 96 GB box) requires bounded GPU
  footprint and good cache locality; eviction + raster fallback handle overflow.
  Date/Author: 2026-06-28 / initial plan.

## Validation and Acceptance

Per-milestone acceptance is listed above. Baseline commands (run from the repo root,
`/Users/rrj/wrk/laban`), each milestone must keep these green:

- `swift test --filter VectorGlyph` — vector backend + size/phase sweeps.
- `swift test --filter GlyphCurveStore` — outline extraction + CPU oracle.
- `swift test --filter VectorSubpixelLayout` — layout persistence/round-trip.
- `./scripts/build-app` then `./scripts/install-app` — bundle builds, codesigns,
  installs; quit & relaunch Laban to observe.
- Headless harness per `docs/process/dev-process.md` for M2/M6 (`/debug/render`,
  `/debug/screenshot`, scroll capture).

A milestone is done only when its new test(s) fail before the change and pass after,
and the baseline filters stay green.

## Idempotence and Recovery

All steps are additive and re-runnable. Atlas/format changes invalidate caches at
runtime (the renderer already rebuilds the atlas on scale/layout change); no
persisted on-disk migration is required. If a milestone destabilizes rendering, revert
that milestone's commits — earlier milestones remain independently valid because each
ships its own gate.
