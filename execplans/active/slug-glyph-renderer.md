# Slug glyph renderer: a resolution-independent, atlas-free GPU text backend

This ExecPlan is a living document maintained in accordance with `PLANS.md` at the
repository root. Keep `Progress` and `Validation and Acceptance` current as work
proceeds. It is written to be executed by a fresh agent (likely Codex) with no
prior context beyond this file and the current working tree.

## Purpose / Big Picture

Laban (a macOS terminal) renders text on the GPU with the **vector glyph
renderer** (`Sources/LabanRenderer/VectorGlyphRenderer.swift`): it rasterizes
glyph outlines into a **size-keyed mask atlas** (a texture of baked glyph
bitmaps) and then samples that atlas. This is excellent for static and scrolling
text — bake once, reuse — and is the renderer's hard-won 120 Hz scroll path.

But the atlas is **size-specific**: a mask baked at 14 pt cannot be reused at
17.3 pt. Continuous pinch / Cmd+scroll **zoom** changes the size every frame, so
the atlas is in permanent cache-miss and must re-bake the whole screen
constantly. Profiling of heavy in-out-in zooming (recorded in
`execplans/active/vector-zoom-smoothness.md` §"Heavy-Zoom Profiling") showed
main-thread stalls up to **818 ms**, entirely in the bake path, with multiple
synchronous commit frames stacking. Every zoom bug fought in that effort
(stale masks, two-sizes-in-one-frame, re-bake freeze, stuck-rectangle) is a
symptom of *having a size-keyed bitmap cache at all*.

This plan adds a **second, independent renderer** — `SlugGlyphRenderer` — that
evaluates glyph coverage **analytically in the fragment shader directly from the
glyph's Bézier curves, with no atlas**. Coverage is computed per pixel from the
outline, so the *same* uploaded curve data renders correctly at *any* size: zoom
is free, nothing goes stale, and there is no bake. This is the Slug algorithm
(Eric Lengyel, JCGT 2017, "GPU-Centered Font Rendering Directly from Glyph
Outlines"); the patent was **dedicated to the public domain** in March 2026
(terathon.com/blog/decade-slug.html), so it is free to implement.

After this change, a user can select "Slug glyph" in the Renderer menu and get
text that is crisp and correct at every fractional size during a continuous
zoom, with no re-bake stall, while the existing vector and classic renderers are
left **completely untouched** and remain the default.

### What someone gains, and how to see it

- Build & install (`./scripts/build-app && ./scripts/install-app`), relaunch
  Laban, pick **Slug glyph** in the Renderer menu, then pinch / Cmd+scroll to
  zoom. Text stays crisp at every intermediate fractional size with no freeze.
- Autonomous gates: a perf bench proving full-screen frame time holds the
  120 Hz budget, a correctness gate proving analytic coverage matches the CPU
  oracle, and a headless `/zoom/state` check proving zoom is free (no mask bakes,
  no stale sizes) — all without a human hand on the trackpad.

### Feasibility is already proven (do not re-litigate)

A feasibility spike is committed on `main`: `Sources/LabanRenderer/SlugGlyphSpike.swift`
+ `Tests/LabanRendererTests/SlugSpikeFrameTimeBench.swift` (run with
`LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugSpikeFrameTimeBench`).
Measured on an Apple M2 Max, release, full screen (160×48 = 7680 glyphs) at live
scale (2880×1824 px):

| mode     | size  | wall p50/p95/p99 ms | verdict |
|----------|-------|---------------------|---------|
| banded   | 9 pt  | 0.87 / 0.98 / 1.28  | PASS    |
| banded   | 14 pt | 1.34 / 1.47 / 1.63  | PASS    |
| banded   | 28 pt | 1.24 / 1.37 / 1.43  | PASS    |
| unbanded | 14 pt | 1.68 / 2.02 / 2.19  | PASS    |

Budget is 8.33 ms (120 Hz). Slug renders a full screen in ~1.5 ms — **5–6× under
budget** — and the cost is **flat across point size** (the atlas's whole problem
disappears). The band optimization (partition each glyph's curves into horizontal
bands so a pixel tests only the few curves crossing its row) helps but is not
strictly required at these glyph complexities. Correctness matches the CPU
oracle. **The spike's job is done; this plan promotes it to a real backend.**

## Scope and non-goals

- **In scope:** a new `SlugGlyphRenderer` conforming to `RendererBackend`; a new
  `RendererSelection` case `slugGlyph`; wiring it into `makeRendererBackend`, the
  Renderer menu, and the debug/headless harness; subpixel-AA + gamma-correct
  compositing to reach parity with the vector renderer's quality; the band
  index built per glyph on the CPU and uploaded once; promoting the spike's
  shaders/structs from `*Spike` names into the production renderer; perf +
  correctness + zoom-is-free autonomous gates.
- **Non-goals (do NOT touch):** the `VectorGlyphRenderer`, `MetalRenderer`
  (classic/gpuDriven), and `SoftwareBackend` stay byte-for-byte as they are.
  This plan does NOT make Slug the default, does NOT delete the atlas, and does
  NOT change scroll behavior. Whether Slug eventually *replaces* the vector
  renderer is a separate future decision gated on this renderer shipping and
  proving itself; this plan only makes it a coexisting, selectable option.
- **Deferred within this plan (call out, do not silently skip):** color/emoji
  glyphs and CJK. The fragment evaluates monochrome outline coverage; color
  emoji and very-high-curve-count CJK glyphs fall back to the existing raster
  path or are explicitly listed as a known limitation with a measurement. See
  M4.

## Context and Orientation

All paths are repository-relative from the repo root (`/Users/rrj/wrk/laban`).
A reader who knows nothing about this repo needs these facts.

### Terms

- **`RendererBackend`** (`Sources/LabanRenderer/RendererBackend.swift`): the
  protocol every renderer conforms to. Key members: `render(_:damage:) -> Bool`,
  `resize(pixelWidth:pixelHeight:scale:)`, `surfaceWidth/Height/Scale`,
  `presentationLayer` (the `CAMetalLayer` the host view installs; nil for
  software), `presentationImage`, `pngData` (offscreen readback for screenshots/
  tests), `onFrameCompleted`, `waitForFrameCompletion` (block until the frame
  completes — used by the live-resize/zoom path so a self-presenting backend
  never shows a mixed frame), and `rendererStatus`.
- **`RendererSelection`** (`Sources/LabanRenderer/RendererSelection.swift`): a
  `String`-backed enum of the selectable renderers — `software`, `classic`,
  `gpuDriven`, `vectorGlyph`. `makeRendererBackend(selection:fontAtlas:...)` is
  the factory that constructs the right backend (and falls back to software when
  no Metal device exists). A new renderer adds a case here and a branch there.
- **`FontAtlas`** (`Sources/LabanRenderer/FontAtlas.swift`): wraps a `CTFont` at
  one `pointSize`, exposes cell metrics and styled variants. The renderer is
  constructed with a terminal `FontAtlas` and a sidebar `FontAtlas`.
- **`GlyphCurveStore`** (`Sources/LabanRenderer/GlyphCurveStore.swift`): returns
  a glyph's outline as **quadratic Bézier curves** (`GlyphCurveOutline` with
  `.curves: [GlyphQuadraticCurve]` and `.contours: [GlyphContour]`). Keyed on
  the font's *visual identity* (PostScript name, point size, glyph, matrix) — NOT
  the object address — so it is safe across transient fonts. Also exposes
  `GlyphCurveCPUOracle` (a CPU winding-number coverage rasterizer) used as the
  ground-truth oracle in correctness tests.
- **Winding-number coverage:** a point is inside a glyph if a horizontal ray from
  it crosses the outline an odd/non-zero number of times. The existing vector
  shader already implements this analytically (`winding_contribution`,
  `curve_x_at`, `valid_root` in `Sources/LabanRenderer/VectorGlyphShaders.metal`)
  — today in a *compute* pass that bakes the atlas. Slug runs the same evaluation
  in the *fragment* shader, per screen pixel, with no atlas.
- **Band optimization:** without it, each pixel tests *all* of a glyph's curves
  (O(curves)). With it, the glyph's vertical extent is split into N horizontal
  bands; each band lists only the curves crossing it; a pixel looks up its band
  and tests only those few curves. This is what keeps per-pixel cost bounded for
  complex glyphs (and is the crux for CJK). The spike already implements it.
- **The spike** (`Sources/LabanRenderer/SlugGlyphSpike.swift` + `*Spike` shader
  functions in `VectorGlyphShaders.metal`): a standalone, non-`RendererBackend`
  prototype that uploads per-glyph curves + a band index once and renders glyph
  quads whose fragment shader computes coverage analytically. It is the
  blueprint; this plan turns it into a real backend. Read it first.

### Key files this plan touches or creates

- CREATE `Sources/LabanRenderer/SlugGlyphRenderer.swift` — the new backend.
- CREATE `Sources/LabanRenderer/SlugGlyphShaders.metal` (or promote the `*Spike`
  functions out of `VectorGlyphShaders.metal` into their own file).
- EDIT `Sources/LabanRenderer/RendererSelection.swift` — add `case slugGlyph` and
  a `makeRendererBackend` branch.
- EDIT the Renderer menu wiring in `Sources/LabanApp/` (search for where
  `vectorGlyph` appears in menu construction / `applyRendererSelection`).
- EDIT `Sources/LabanApp/ScrollDebugServer.swift` if the `/config/renderer` route
  needs the new name (it parses `RendererSelection(rawValue:)`, so it likely
  works for free — verify).
- CREATE tests under `Tests/LabanRendererTests/` (perf, correctness, zoom-free)
  and possibly `Tests/LabanAppTests/` (selection round-trip).
- WRITE an ADR under `docs/adr/` (see M5) recording the analytic-vs-atlas
  decision and that Slug coexists with, and does not replace, the vector renderer.

## Design decisions (made here, not left to the reader)

1. **New backend, not a mode of the vector renderer.** Slug's render path shares
   almost nothing with the atlas path (no mask atlas, no bake budget, no eviction,
   no scroll-phase machinery). Bolting it onto `VectorGlyphRenderer` would
   entangle two very different cost models and risk the hard-won scroll path.
   A separate `SlugGlyphRenderer` conforming to `RendererBackend` keeps both
   clean and independently testable. This matches how `MetalRenderer`,
   `VectorGlyphRenderer`, and `SoftwareBackend` already coexist.

2. **Opt-in, not default.** Ship `slugGlyph` as a selectable renderer the user
   chooses, with `vectorGlyph`/`classic` unchanged as defaults. This de-risks the
   rollout: Slug proves itself in real use before any conversation about making
   it the default or retiring the atlas. `isAvailableOnCurrentOS` returns true
   only where its Metal feature set is supported (match the vector renderer's
   floor; fall back to classic otherwise).

3. **Upload curves + band index once per glyph, keyed on visual identity.** The
   per-glyph GPU buffers (curves, bands) are size-INDEPENDENT geometry: build
   them once and reuse across all sizes (this is the whole point — zoom touches
   no per-glyph CPU/GPU work). Cache them keyed the same way `GlyphCurveStore`
   keys outlines (PostScript name + glyph + matrix; NOT point size, since the
   shader scales analytically; NOT object address). A glyph's curve buffer is
   built on first sight and never rebuilt for a size change.

4. **Reach quality parity before claiming done.** The spike cut subpixel AA and
   gamma-correct compositing. The vector renderer composites coverage in linear
   light (sRGB target) and supports subpixel AA with auto-disable on
   scaled/downsampled displays. Slug must match: evaluate coverage with
   supersampling or analytic-area AA, composite in linear light, and honor the
   same subpixel-layout policy. Parity is gated against the CPU oracle and (where
   reasonable) against the vector renderer's output, not asserted.

5. **Self-presenting, with the same `waitForFrameCompletion` contract.** Slug
   owns a `CAMetalLayer` like the vector/classic GPU backends and presents via
   the shared present-link path (ADR 0026 — `VectorPresentDisplayLink`) so it
   inherits the no-drawable-wait, idle-parking behavior. It must honor
   `waitForFrameCompletion` (block the frame) so the live-resize/zoom apply path's
   no-mixed-frame guarantee holds for it too.

6. **Zoom is just a transform.** Because coverage is analytic, a continuous zoom
   is a per-frame projection scale (same `gestureZoom` uniform the vector
   renderer already uses) with NO re-bake, NO atlas reset, NO font reconfigure.
   The entire `applyZoomMagnification` gesture machinery in `TerminalBitmapView`
   should work for Slug with the gesture-end commit being a trivial size change
   (the renderer does not bake, so "commit" is just updating the font size and
   reflowing the grid — no expensive frame). Verify and simplify the gesture path
   for the Slug backend accordingly, without regressing the vector path.

## Milestones

Each milestone is independently verifiable. Build with `swift build`; test with
`swift test --filter <name>`; lint with `scripts/lint`. Do NOT run two builds
concurrently against the same `.build/`. Commit frequently with single-line
reason-style messages (see `AGENTS.md`).

### M0 — Backend skeleton that renders monochrome text (no atlas)

Scope: a `SlugGlyphRenderer: RendererBackend` that constructs, owns a
`CAMetalLayer`, uploads per-glyph curves+bands once, and renders a full frame of
monochrome analytic-coverage text into its target. Promote the spike's structs
and `*Spike` shader functions into production names/files. Wire `case slugGlyph`
into `RendererSelection` + `makeRendererBackend` (Metal-or-fallback). It need not
be subpixel/gamma-perfect yet.

Acceptance:
- `swift build` clean. `RendererSelection.slugGlyph` round-trips
  (`RendererSelection(rawValue: "slugGlyph") == .slugGlyph`,
  `isAvailableOnCurrentOS` correct).
- A new correctness test: analytic coverage from the production renderer matches
  `GlyphCurveCPUOracle` for printable ASCII within tolerance (port the spike's
  `SlugSpikeCorrectness`).
- `pngData` returns a decodable image of rendered text (a headless render test).

### M1 — Perf gate at full screen, resolution-independence proven

Scope: a production perf bench (port `SlugSpikeFrameTimeBench`) on the real
backend, full screen 160×48 @2x, 200 frames, reporting cpu+wall p50/p95/p99 and a
verdict vs 8.33 ms, across 9/14/28 pt.

Acceptance:
- Full-screen wall p99 ≤ 8.33 ms at all three sizes (it was ~1.3–1.6 ms in the
  spike — leave generous headroom).
- Cost is flat across point size (assert p50 at 28 pt is within ~1.5× of 9 pt) —
  the resolution-independence claim, gated.

### M2 — Quality parity: subpixel AA + gamma-correct compositing

Scope: match the vector renderer's visual quality. Composite coverage in linear
light into the sRGB target; implement grayscale AA (supersampled or analytic
area) and opt-in subpixel AA honoring the same display-condition auto-policy the
vector renderer uses (grayscale fallback on scaled/downsampled displays).

Acceptance:
- A gamma/AA test mirroring `VectorGlyphGammaTests`: white-on-black AA edge pixels
  read `srgbEncode(coverage)`, not a gamma-space blend.
- The clear color for the Slug target is linearized like the vector renderer's
  (see `VectorGlyphRenderer.linearizedClearColor`) so themed backgrounds and the
  zoom-out margin are correct (reuse the same derivation).
- Visual spot-check artifact (a `pngData` screenshot at 14 pt) recorded.

### M3 — Continuous zoom is free (the payoff)

Scope: wire Slug into the zoom gesture. Zoom should be a per-frame `gestureZoom`
projection scale with no bake; gesture-end commit is just a font-size + grid
change (cheap, since nothing rebakes). Reuse the existing `TerminalBitmapView`
gesture machinery; ensure the Slug backend path does not trigger the vector
renderer's reconfigure/bake.

Acceptance (autonomous, via `--scroll-debug` + `/zoom/*` routes that already
exist):
- Select Slug (`POST /config/renderer?name=slugGlyph`), drive a continuous
  in/out sweep (`/zoom/pinch` or `/zoom/sweep`), and assert via `/zoom/state`
  that `lastFrameQuadHeights` (or the Slug equivalent) shows a SINGLE consistent
  size at every step — no mixed sizes, ever — and that no mask bake/reflow storm
  occurs. The mixed-size and re-bake-freeze classes are impossible by
  construction; the gate proves it.
- A frame-time measurement during the sweep shows NO commit stall (contrast with
  the vector renderer's ~130 ms settle and stacked-commit stalls recorded in
  `vector-zoom-smoothness.md`).
- Manual (artifact): pinch-zoom over Slug is smooth and crisp at every size.

### M4 — Color/emoji + CJK: parity or honest limitation

Scope: decide and implement the fallback story for glyphs the monochrome analytic
path does not cover. Color emoji: fall back to the existing color-glyph raster
path (or render monochrome and document). CJK: measure full-screen CJK frame time
(thousands of curves/glyph — bands matter most here); if it holds budget, support
it; if not, document the limit and fall back to raster for CJK runs.

Acceptance:
- A CJK perf measurement recorded (full screen of CJK at 14 pt, p99 vs budget).
- Color emoji either render correctly (test) or are explicitly routed to the
  raster fallback with a test proving they still appear (not invisible).
- No glyph the user types renders as blank/garbage; everything has a path.

### M5 — Ship: menu, harness parity, ADR

Scope: expose Slug in the Renderer menu; ensure `HeadlessDebugRuntime` has parity
(per AGENTS.md hard rule — wire new subsystems into both the AppKit and headless
paths); write an ADR.

Acceptance:
- Renderer menu shows "Slug glyph"; selecting it swaps the backend live
  (mirrors `applyRendererSelection` for `vectorGlyph`) and survives tab
  switch/resize.
- Headless `/config/renderer?name=slugGlyph` works and `/debug` + `/zoom/state`
  report it.
- An ADR in `docs/adr/` (next number; update `docs/adr/README.md`) records:
  analytic-coverage Slug renderer added as a coexisting opt-in backend; why
  (atlas is size-keyed → zoom re-bake); that it does NOT replace the vector
  renderer (scroll parity / color / CJK still to be proven before any default
  switch); patent public-domain provenance.

## Progress

- [ ] M0 — backend skeleton renders monochrome text, no atlas; `slugGlyph`
  selectable; correctness vs CPU oracle.
- [ ] M1 — full-screen perf gate ≤8.33 ms; resolution-independence gated.
- [ ] M2 — subpixel AA + gamma-correct compositing parity.
- [ ] M3 — continuous zoom is free; single-size-per-frame + no-stall gates.
- [ ] M4 — color/emoji + CJK parity or documented fallback with measurement.
- [ ] M5 — menu + headless parity + ADR.

## Decision Log

- Decision: Slug is a NEW `RendererBackend`, opt-in, coexisting with the vector
  renderer — not a mode of it and not the default.
  Rationale: disjoint cost model (analytic per-frame vs bake-once atlas);
  isolating it protects the hard-won 120 Hz scroll path and lets Slug prove
  itself before any default/replace decision.
  Date/Author: 2026-06-30 / this plan.
- Decision: Outline/curve/band GPU buffers are keyed on visual font identity and
  built once per glyph, never per size.
  Rationale: the geometry is size-independent; the shader scales analytically.
  This is what makes zoom touch zero per-glyph work and is the structural reason
  the atlas's size-mixing/re-bake bug class cannot occur.
  Date/Author: 2026-06-30 / this plan.

## Validation and Acceptance

Baseline commands (from repo root):
- `swift build` — clean.
- `swift test --filter SlugGlyphCorrectness` (M0) — analytic vs CPU oracle.
- `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugGlyphFrameTimeBench`
  (M1/M4) — full-screen p99 ≤ 8.33 ms; flat across size.
- `swift test --filter VectorGlyphGamma`-equivalent for Slug (M2).
- Headless per `docs/process/dev-process.md`: `--scroll-debug`, then
  `POST /config/renderer?name=slugGlyph`, `/zoom/sweep`, `/zoom/state` — assert
  single-size-per-frame and no stall (M3).
- `scripts/lint` clean; `scripts/check` if present.

A milestone is done only when its new test(s) fail before the change and pass
after, and the existing vector/classic/scroll suites stay green (the vector
renderer must remain byte-for-byte unaffected — run its parity + scroll benches).

## Interfaces and Dependencies

Must exist at completion:
- `RendererSelection.slugGlyph` + a `makeRendererBackend` branch returning
  `SlugGlyphRenderer` (or software fallback when no Metal device).
- `SlugGlyphRenderer: RendererBackend` (self-presenting `CAMetalLayer`, honors
  `waitForFrameCompletion`, supports `pngData`, `resize`, `gestureZoom`).
- Production Slug shaders (curves+bands fragment coverage, subpixel/gamma), a
  per-glyph curve/band buffer cache keyed on visual identity.
- Perf + correctness + zoom-free gates as above; an ADR.

## Notes for the executor

- READ FIRST, in order: this file; `Sources/LabanRenderer/SlugGlyphSpike.swift`
  and its `*Spike` shaders (your blueprint); `VectorGlyphRenderer.swift` (for the
  `RendererBackend` shape, present-link wiring, `gestureZoom`, linearized clear,
  subpixel/gamma policy to mirror); `RendererSelection.swift`;
  `execplans/active/vector-zoom-smoothness.md` (why this exists + the profiling).
- The vector renderer is OFF LIMITS for behavior changes. If you must move shared
  helpers (e.g. a clear-color derivation), keep the vector renderer's behavior
  identical and covered by its existing tests.
- This is a real backend, not a spike: correctness and quality must be GATED, not
  eyeballed. But the perf feasibility is already settled — do not re-prove it,
  build on it.
