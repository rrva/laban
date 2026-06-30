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
  oracle, an AppKit scroll-debug `/zoom/state` check proving zoom is free (no
  mask bakes, no stale sizes), and a true headless `laban-agent` check proving
  the backend can be selected and reported without the AppKit window — all
  without a human hand on the trackpad.

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
  shaders/structs from `*Spike` names into the production renderer; package
  resource wiring for any new `.metal` file; renderer-menu, Settings popup,
  debug action schema, and `laban-agent --renderer` help updates; perf +
  correctness + zoom-is-free autonomous gates.
- **Non-goals (do NOT change behavior):** the `VectorGlyphRenderer`,
  `MetalRenderer` (classic/gpuDriven), and `SoftwareBackend` keep their current
  rendering behavior, defaults, and performance gates. Additive shared-protocol
  conformance or diagnostic extraction is allowed only where M3 needs it to make
  vector and Slug use the same zoom interface, and must be covered by existing
  vector tests. This plan does NOT make Slug the default, does NOT delete the
  atlas, and does NOT change scroll behavior. Whether Slug eventually *replaces*
  the vector renderer is a separate future decision gated on this renderer
  shipping and proving itself; this plan only makes it a coexisting, selectable
  option.
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
- **Slug geometry cache** (new, inside `SlugGlyphRenderer.swift`, unless it
  grows large enough for its own file): this is NOT the same cache key as
  `GlyphCurveStore`. `GlyphCurveStore` deliberately includes `pointSize`
  because CoreText outline coordinates are size-scaled. Slug's GPU cache must
  exclude point size: create outlines from a fixed reference size (use the
  spike's 14 pt reference unless a better constant is measured), store
  reference-size curves/bands, and pass the active point-size scale in instance
  data or uniforms. The cache key is `postScriptName + glyph + normalized font
  matrix/style identity`, never `CTFont` object identity and never active point
  size. This is the structural gate for "zoom is free."
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
- EDIT `Package.swift` if `SlugGlyphShaders.metal` is created, adding it to the
  `LabanRenderer` target's `resources`; otherwise keep the production Slug
  functions in the already-packaged `VectorGlyphShaders.metal`. Update
  `scripts/smoke-runtime` to assert the shipped `.app` contains whichever shader
  resource the production renderer loads.
- EDIT `Sources/LabanRenderer/RendererSelection.swift` — add `case slugGlyph` and
  a `makeRendererBackend` branch.
- EDIT the Renderer menu and Settings wiring in `Sources/LabanApp/`:
  `RendererModeMenuController.swift`, `SettingsWindowController.swift`,
  `TerminalBitmapView.swift`, and the exact-title/index assertions in
  `Tests/LabanAppTests/RendererModeSettingsTests.swift`.
- EDIT `Sources/LabanApp/ScrollDebugServer.swift` help text if needed. The
  `/config/renderer` route parses `RendererSelection(rawValue:)` and should
  accept `slugGlyph` once the enum exists, but the `/zoom/*` routes only exercise
  the AppKit scroll-debug server, not true `laban-agent --headless`.
- EDIT headless/automation surfaces:
  `Sources/LabanCore/Intents/DebugRequestPayloads.swift` (`setRenderer` schema
  enum values), `Sources/LabanAgent/main.swift` (`--renderer` help text), and
  `Sources/LabanDebug/DebugWindowActions.swift`/`HeadlessDebugRuntime.swift` only
  if the generic renderer rebuild/reporting path needs slug-specific status.
- EDIT `Sources/LabanApp/TerminalBitmapView.swift` to replace vector-only zoom
  type checks with a shared Slug/vector zoom capability (see M3). Do not leave
  `backend is VectorGlyphRenderer` as the definition of fractional/free zoom.
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

3. **Upload curves + band index once per glyph, keyed by size-independent
   geometry.** `GlyphCurveStore` is safe but size-keyed today: its key includes
   `pointSize` because CoreText path coordinates are scaled by the `CTFont`
   size. Slug must not reuse that key for GPU buffers. Build Slug geometry from
   a fixed reference `CTFont` size (14 pt, matching the spike, unless M0 records
   a better constant), store reference-size curves and bands, and scale those
   curves in the shader/instance data for the active `FontAtlas.pointSize`. The
   Slug cache key includes font PostScript name, glyph id, and normalized
   style/matrix identity; it excludes active point size and CTFont object
   identity. Acceptance must include a counter or trace proving that rendering
   the same glyph at 9, 14, and 28 pt builds one curve/band GPU entry, not three.

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
   The current gesture machinery is vector-specific (`backend is
   VectorGlyphRenderer`, vector-only `setGestureZoom`, and vector-only debug
   fields). M3 must introduce a small shared capability instead of adding more
   type checks:

   ```swift
   protocol GestureZoomRenderable {
     var supportsFractionalLiveZoom: Bool { get }
     func setGestureZoom(_ factor: CGFloat, anchor: CGPoint)
     var zoomDiagnostics: RendererZoomDiagnostics { get }
   }
   ```

   Exact names may differ. `VectorGlyphRenderer` and `SlugGlyphRenderer`
   conform; classic, gpuDriven, and software do not. `TerminalBitmapView`
   `applyZoomMagnification`, `debugApplyPinch`, `debugZoomSweep`, and
   `debugZoomState` use that capability so Slug does not fall back to the rounded
   non-vector zoom path. Gesture-end commit for Slug is just updating font
   metrics and grid size; it must not run vector mask reconfigure/bake code.

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
  `isAvailableOnCurrentOS` correct), and `RendererSelection.allCases`-driven
  UI/tests include the new case without index/title drift.
- A new correctness test: analytic coverage from the production renderer matches
  `GlyphCurveCPUOracle` for printable ASCII within tolerance (port the spike's
  `SlugSpikeCorrectness`).
- `pngData` returns a decodable image of rendered text (a headless render test).
- A new geometry-cache test renders the same glyph at 9, 14, and 28 pt and
  asserts the Slug curve/band GPU-entry build count does not increase after the
  first size. This test fails if the implementation keys GPU geometry on active
  `pointSize`.
- If `SlugGlyphShaders.metal` exists, `Package.swift` includes it as a
  `LabanRenderer` resource and `scripts/smoke-runtime` asserts the app bundle
  contains it. If Slug stays in `VectorGlyphShaders.metal`, the plan's file list
  and smoke check say so explicitly.

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

### M3 — Continuous zoom is free, and zoom-OUT is honest (the payoff)

Scope: wire Slug into the zoom gesture. Zoom should be a per-frame `gestureZoom`
projection scale with no bake; gesture-end commit is just a font-size + grid
change (cheap, since nothing rebakes). Reuse the existing `TerminalBitmapView`
gesture machinery; ensure the Slug backend path does not trigger the vector
renderer's reconfigure/bake.

This milestone must also get **zoom-OUT** right, which is a genuinely different
problem from zoom-in. It is grounded in research recorded at
`docs/reference/continuous-zoom-research.md` (read it). Key facts:

- **No GPU terminal does continuous fractional zoom** (Kitty, Ghostty, WezTerm,
  iTerm2, Alacritty all discrete-step + reflow). This is novel; there is no prior
  art to copy. SDF/analytic glyph rendering is specifically what makes a transient
  projection scale *visually safe* — edges stay ~1 px sharp at any scale-up/down.
  That is the research basis for building Slug at all: it is the renderer that
  makes continuous zoom viable.
- **Whether the terminal owns content for the revealed area depends on the screen
  mode** (this is a correction to an earlier, too-strong "the terminal owns
  nothing" framing). Zoom-IN always magnifies cells that already have content —
  local, honest, free. Zoom-OUT shrinks cells so *more* rows/cols would fit; what
  can fill the revealed space differs:
  - **Alt-screen** (vim, htop, fullscreen TUI; `viewportState().altScreen ==
    true`): the app owns every cell and scrollback is suppressed. There is
    genuinely nothing to reveal until the grid grows and the app repaints via
    `SIGWINCH`. The empty-margin reality holds **here**.
  - **Normal screen with scrollback** (the common case — a shell prompt;
    `altScreen == false`, `scrollbackRows > 0`): the terminal DOES own more
    content — the scrollback buffer. Zoom-out reveals room into which **older
    scrollback lines scroll up**, exactly as a browser reveals off-screen DOM.
    The terminal can fill the revealed space from content it already holds; it is
    NOT empty. (Below the live bottom there is still nothing — the shell has not
    produced it — but above, scrollback fills.)
  - **Normal screen, no scrollback** (fresh shell): nothing above to reveal, so
    the margin is genuinely empty until reflow — same as alt-screen.
  In all cases the *authoritative* fill for a grown grid is the child program
  reflowing to the new size on `SIGWINCH` (the app's job). Revealing scrollback is
  a truthful *preview* using content the terminal already owns; the release-commit
  reflow makes it real. The signals to drive this are on `viewportState()`:
  `altScreen`, `scrollbackRows`, `totalRows`, `viewportRows`, `viewportOffset`.
- **The fill strategy, by mode** (research-backed: tile renderers / VNC say
  *never show empty/black gaps* — cover the revealed area with the best content
  you already have, and reflow on pause):
  - Normal screen with scrollback → **reveal scrollback** into the space above as
    the canvas shrinks (real content the terminal owns). The bottom margin (below
    the live prompt, which has no content yet) falls back to the opaque terminal
    background.
  - Alt-screen, or no scrollback → fill the revealed region with the **opaque
    terminal background** (the M2 linearized clear), since there is nothing to
    reveal.
  In all modes: do NOT fake content, do NOT `SIGWINCH` every frame, and commit one
  real font-size + `SIGWINCH` reflow on gesture release. Apply a **soft clamp /
  rubber-band** at the zoom-out edge. A **hard clamp at 1.0 is rejected** — it
  defeats continuous zoom-out entirely. (Scrollback-reveal-on-zoom-out may be
  staged as a follow-up after the opaque-margin baseline ships; the baseline is
  the minimum honest behavior, scrollback-reveal is the richer one. Sequence it
  in Progress, do not silently drop it.)

Zoom-out implementation requirements:
1. **Opaque background margin (baseline) + scrollback reveal (richer).** Baseline:
   clear the Slug target to the *terminal background* color, linearized for the
   sRGB target — the vector renderer does this via `linearizedClearColor`, which
   M2 already requires Slug to match; the zoom-out margin must read as theme
   background, never black and never an sRGB double-encoded near-white. Richer
   (normal screen, `scrollbackRows > 0`): as the canvas shrinks, reveal older
   scrollback lines into the space above (the terminal owns them) so zoom-out
   shows real content, not blank. Gate the scrollback path on `!altScreen`; the
   opaque margin always covers the genuinely-empty region (below the live bottom,
   or whenever there is no scrollback). Stage scrollback-reveal after the baseline
   if needed (record in Progress).
2. **Rubber-band / soft clamp at the zoom edges** (research recommendation #3,
   not yet built for the vector renderer either — this plan is where it lands):
   below a minimum effective point size (floor at `FontAtlas.zoomMinimumPointSize`,
   rubber-band onset a little above it) the gesture's effective scale RESISTS
   further shrink — additional pinch-in past the threshold maps through a
   diminishing/eased function so the canvas slows and stops rather than shrinking
   to a dot in a sea of background, and snaps back to the floor on release. Same
   easing at the zoom-IN maximum (`zoomMaximumPointSize`). Implement it as a PURE,
   testable mapping (inputs: base size + accumulated gesture magnification;
   output: eased, clamped effective scale), unit-tested like `zoomPointSize` in
   `Tests/LabanAppTests/ContinuousZoomTests.swift`. Do NOT hard-clamp at 1.0.
3. **Reflow on release, not per frame:** the gesture-end commit applies the real
   font size and the grid reflow once (SIGWINCH), filling the previously-empty
   margin with real cells. No per-frame SIGWINCH during the gesture.

Acceptance (autonomous, via `--scroll-debug` + `/zoom/*` routes that already
exist):
- Select Slug (`POST /config/renderer?name=slugGlyph`), drive a continuous
  in/out sweep (`/zoom/pinch` or `/zoom/sweep`), and assert via `/zoom/state`
  that `backend == "slugGlyph"`, `fractional == true`,
  `lastFrameQuadHeights` (or the shared `zoomDiagnostics.quadHeights`) shows a
  SINGLE consistent size at every step, `curveBufferBuildCount` is unchanged
  across the sweep, and `gridReflowCount` changes only when integer rows/cols
  change. No mixed sizes, ever; no per-frame geometry rebuild storm.
- A frame-time measurement during the sweep shows NO commit stall (contrast with
  the vector renderer's ~130 ms settle and stacked-commit stalls recorded in
  `vector-zoom-smoothness.md`).
- Unit coverage in `Tests/LabanAppTests/ContinuousZoomTests.swift` (or a new
  Slug-specific test file) proves the shared zoom capability path is used:
  during a changed event `TerminalBitmapView` calls Slug's `setGestureZoom` and
  does not execute the rounded non-vector `applyFontSize(... quantize: true)`
  path.
- **Zoom-out margin** gate: drive a zoom-OUT sweep on Slug and assert (via a
  `pngData`/`/scroll/screenshot.png` corner-pixel probe) the revealed margin is
  the terminal background, not black and not near-white — mirror
  `VectorGestureZoomProjectionTests.testZoomOutMarginMatchesThemeBackground`.
- **Rubber-band** gate: a pure unit test of the eased-scale mapping —
  monotonic, never produces an effective size below `zoomMinimumPointSize` or
  above `zoomMaximumPointSize`, resistance grows past the threshold (equal raw
  magnification past the edge yields progressively less effective change), and it
  is NOT a hard clamp at 1.0 (a small pinch past the edge still moves a little).
- Manual (artifact): pinch-zoom over Slug is smooth and crisp at every size; the
  zoom-out edge resists and snaps back rather than shrinking text to a dot.

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
- Settings popup shows "Slug Glyph" and persists it. Update
  `Tests/LabanAppTests/RendererModeSettingsTests.swift`, whose current menu test
  asserts the exact renderer titles and item indexes.
- AppKit scroll-debug validation: `POST /config/renderer?name=slugGlyph` works,
  `GET /zoom/state` reports `backend == "slugGlyph"` and the shared zoom
  diagnostics, and `GET /scroll/screenshot.png` returns a non-empty PNG after a
  Slug render. Renderer status for true headless runs is checked separately
  below; do not assume the AppKit scroll-debug server exposes `/debug/render`.
- True headless validation: `.build/debug/laban-agent --headless
  --debug-server=127.0.0.1:0 --renderer=slugGlyph ...` starts, `GET
  /debug/render` reports `configuredRenderer == "slugGlyph"` and either
  `effectiveRenderer == "slugGlyph"` or a documented fallback reason, and debug
  action schema discovery lists `slugGlyph` in `setRenderer` enum values. Do not
  cite `/zoom/state` as a headless route unless an implementation adds that route
  to `LabanControl`/`HeadlessDebugRuntime`.
- `Sources/LabanAgent/main.swift` help text lists `slugGlyph` for `--renderer`.
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
- [ ] M3 — continuous zoom is free; single-size-per-frame + no-stall gates;
  zoom-OUT honest (opaque background margin, rubber-band edge, reflow-on-release).
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
  built once per glyph, never per active point size.
  Rationale: `GlyphCurveStore` itself is size-keyed, so Slug needs its own
  reference-size geometry cache rather than reusing that key. The shader scales
  the reference curves analytically. This is what makes zoom touch zero per-glyph
  geometry work and is the structural reason the atlas's size-mixing/re-bake bug
  class cannot occur.
  Date/Author: 2026-06-30 / this plan.
- Decision: `TerminalBitmapView` gets a shared gesture-zoom capability for
  analytic/fractional renderers instead of recognizing only
  `VectorGlyphRenderer`.
  Rationale: the live source currently treats `backend is VectorGlyphRenderer`
  as the only fractional/free-zoom backend. Without a shared interface,
  `SlugGlyphRenderer` would take the rounded non-vector zoom path and fail the
  plan's purpose.
  Date/Author: 2026-06-30 / plan review fix.
- Decision: Zoom-OUT fills the revealed margin with the opaque terminal
  background and commits one real reflow on release; it applies a soft rubber-band
  at the zoom edges and is NOT hard-clamped at 1.0.
  Rationale: a terminal does not own content for the area revealed by zoom-out
  until the child process is reflowed via SIGWINCH (canvas/painter asymmetry).
  Cited research (`docs/reference/continuous-zoom-research.md`): no terminal does
  continuous fractional zoom; tile renderers / VNC answer the "no content for
  revealed area" problem with an opaque fallback fill + reflow-on-pause, and a
  hard clamp is rejected because it defeats zoom-out. SDF/analytic rendering is
  what makes the transient scale visually safe — the basis for choosing Slug.
  Date/Author: 2026-06-30 / zoom-out research applied.
- Decision: Slug targets CONTINUOUS fractional zoom, which is the only zoom the
  prebuilt atlas ladder cannot serve. Discrete Cmd+= / Cmd+- / Cmd+scroll on the
  classic/gpu-driven renderer is already excellent and stays untouched.
  Rationale: `MetalRenderer` has no zoom-specific code; discrete integer zoom is a
  pointer-swap into the prebuilt `GlyphAtlasLadder` (one baked atlas per integer
  8–40 pt) — instant, no re-bake. Fractional sizes are off the ladder, so every
  frame is a cache miss; that is the sole reason the vector renderer struggled and
  the reason Slug (analytic, size-flat) exists. Do not "improve" the gpu-driven
  discrete path to match Slug — it is not the same gesture and is not broken.
  Date/Author: 2026-06-30 / clarified after observing gpu-driven Cmd+/- feels good.

### Future directions (not in scope; capture so they are not lost)

- **Scrollback reveal needs reflow to be fully truthful.** Revealing older
  scrollback into the zoom-out margin is a good preview, but those lines were
  wrapped at the OLD column width; if zoom-out also changes columns they can
  mis-wrap. So scrollback-reveal is an approximation; the authoritative fill is
  still the child program reflowing at the new width. Treat reveal as preview,
  reflow-on-release as truth.
- **Speculative / predictive reflow (the "ask the painter in advance" idea).** As
  a pinch crosses toward a candidate integer grid size, the terminal could fire a
  `SIGWINCH` at that geometry AHEAD of release, let the child repaint into an
  offscreen buffer, and present the real reflowed content the instant the user
  settles there — no commit stall, and the closest a terminal can get to a
  browser's "it already knows what's off-screen." This is the most promising path
  to making zoom-out show *real* content live. Risks to weigh before building:
  `SIGWINCH` has side effects (many TUIs clear/redraw on resize), it is not free,
  and firing several candidate geometries speculatively could thrash a heavy app
  (vim, a build TUI) — so gate it to the normal screen / a cheap painter (a shell
  prompt) and debounce candidates. Out of scope for this plan; recorded as the
  natural next step after the opaque-margin + reflow-on-release baseline.

## Validation and Acceptance

Baseline commands (from repo root):
- `swift build` — clean.
- `swift test --filter SlugGlyphCorrectness` (M0) — analytic vs CPU oracle.
- `swift test --filter SlugGlyphGeometryCache` (M0/M3) — the same glyph rendered
  at multiple point sizes builds one reference curve/band GPU entry.
- `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugGlyphFrameTimeBench`
  (M1/M4) — full-screen p99 ≤ 8.33 ms; flat across size.
- `swift test --filter VectorGlyphGamma`-equivalent for Slug (M2).
- AppKit scroll-debug per `docs/process/dev-process.md`: start Laban with
  `--scroll-debug`, then `POST /config/renderer?name=slugGlyph`, `POST
  /zoom/sweep`, `GET /zoom/state`, and `GET /scroll/screenshot.png`; assert
  single-size-per-frame, no geometry rebuild storm, no stall, and slug renderer
  status (M3/M5).
- True headless: build `laban-agent`, start with `--headless
  --debug-server=127.0.0.1:0 --renderer=slugGlyph`, then `GET /debug/render`;
  assert configured/effective/fallback status and renderer schema/help coverage
  (M5).
- `./scripts/build-app` — clean and the app bundle contains every shader resource
  the Slug renderer loads.
- `scripts/lint` clean; `scripts/check` if present.

A milestone is done only when its new test(s) fail before the change and pass
after, and the existing vector/classic/scroll suites stay green (the vector
renderer's behavior and output must remain unchanged — run its parity + scroll
benches).

## Interfaces and Dependencies

Must exist at completion:
- `RendererSelection.slugGlyph` + a `makeRendererBackend` branch returning
  `SlugGlyphRenderer` (or software fallback when no Metal device).
- `SlugGlyphRenderer: RendererBackend` (self-presenting `CAMetalLayer`, honors
  `waitForFrameCompletion`, supports `pngData`, `resize`, `gestureZoom`).
- A shared AppKit zoom capability used by both vector and Slug so
  `TerminalBitmapView` does not special-case `VectorGlyphRenderer` as the only
  fractional renderer.
- Production Slug shaders (curves+bands fragment coverage, subpixel/gamma) and
  package/smoke-runtime resource wiring for the shader file that is actually
  loaded.
- A per-glyph curve/band buffer cache keyed on size-independent visual identity,
  with active point size excluded and tested.
- Renderer menu, Settings popup, debug action schema, `laban-agent --renderer`
  help, AppKit scroll-debug, and true headless debug reporting all know the
  `slugGlyph` selection.
- Perf + correctness + zoom-free gates as above; an ADR.

## Notes for the executor

- READ FIRST, in order: this file; `Sources/LabanRenderer/SlugGlyphSpike.swift`
  and its `*Spike` shaders (your blueprint); `VectorGlyphRenderer.swift` (for the
  `RendererBackend` shape, present-link wiring, `gestureZoom`, linearized clear,
  subpixel/gamma policy to mirror); `RendererSelection.swift`;
  `TerminalBitmapView.swift`'s `applyZoomMagnification` and `debugZoomState`
  paths; `Package.swift`'s `LabanRenderer` resources;
  `execplans/active/vector-zoom-smoothness.md` (why this exists + the profiling);
  and `docs/reference/continuous-zoom-research.md` (cited zoom-out UX research —
  governs M3 zoom-out: opaque margin, rubber-band, reflow-on-release).
- The vector renderer is OFF LIMITS for behavior changes. If you must move shared
  helpers (e.g. a clear-color derivation), keep the vector renderer's behavior
  identical and covered by its existing tests.
- This is a real backend, not a spike: correctness and quality must be GATED, not
  eyeballed. But the perf feasibility is already settled — do not re-prove it,
  build on it.
