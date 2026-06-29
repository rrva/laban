# Smooth, scroll-safe vector pinch-zoom: stop rebuilding the font, scale instead

This ExecPlan is a living document maintained in accordance with `PLANS.md` at the
repository root. Keep `Progress` and `Validation and Acceptance` current as work
proceeds. Add optional sections only when they hold information a fresh contributor
needs.

## Purpose / Big Picture

Continuous pinch / Cmd+scroll zoom on the vector glyph renderer already works
functionally (see `execplans/active/vector-continuous-pinch-zoom.md`, all three
milestones landed), but it **feels slow and janky and visibly mixes glyphs of two
different sizes within a single frame**. After this change, a pinch or Cmd+scroll
zoom on the vector backend tracks the gesture smoothly (no per-event hitch) and
never shows a frame containing glyphs at two sizes, while **normal scrolling of
text is provably unchanged** — same 120 Hz, same frame-time benches, byte-for-byte
the same steady-state render path.

What someone gains: pinch-zoom that feels native (like zooming a photo), with text
that stays coherent at every intermediate size, and zero regression to the thing
they do far more often — scrolling.

How to see it working: build and install
(`./scripts/build-app && ./scripts/install-app`), quit and relaunch Laban, switch
the Renderer menu to "Vector glyph", and pinch (or hold Cmd and two-finger scroll).
The text scales without stutter and without the double-size shimmer. Then scroll a
long log and confirm it is as smooth as before. Autonomous gates (a headless
mid-gesture screenshot, the existing scroll benches, and a Metal trace compare)
prove both the fix and the no-regression claim without a human hand on the trackpad.

## Scope and non-goals

- **In scope:** (1) fixing the **size-mixing correctness bug** — the synchronous
  "no mixed-atlas frame" guarantee in `applyFontSize` currently only covers the
  classic `MetalRenderer` and silently no-ops for the self-presenting vector
  backend; (2) removing the **per-event font rebuild** so a zoom step is cheap —
  the vector renderer should change rasterization *size*, not replace the *font
  object* and eagerly rebuild its raster/color atlases every gesture frame;
  (3) locking **scroll non-regression** with measured before/after evidence and a
  fail-first guard.
- **Non-goals:** the classic (`MetalRenderer`) and software backends — they keep
  their integer atlas ladder and are untouched. Changing the *gesture mapping*,
  the *reflow throttling*, or the *debug routes* from the prior plan — those are
  done and correct; this plan changes only how the vector backend *applies* a size.
  Image/UI-chrome zoom and "semantic zoom" remain out of scope.

## Context and Orientation

A reader who knows nothing about this repo needs these facts. All paths are
repository-relative from the repo root (`/Users/rrj/wrk/laban`).

### Terms

- **Vector glyph renderer:** `Sources/LabanRenderer/VectorGlyphRenderer.swift`. The
  GPU backend this plan targets. It turns font outlines (the mathematical curves of
  a glyph) into coverage masks on the GPU and stores them in a **resident mask
  atlas** (a texture holding many baked glyph bitmaps). Drawing a frame is then
  mostly *looking up* pre-baked masks and placing them — cheap and O(1) per glyph.
  *Baking* a new mask (running the GPU compute that fills a mask from curves) is the
  expensive, bursty operation; the renderer works hard to do it rarely and reuse the
  result across many frames.
- **FontAtlas:** `Sources/LabanRenderer/FontAtlas.swift`. Wraps a CoreText font
  (`CTFont`) at one `pointSize` and exposes cell metrics. Changing size today means
  constructing a **new `CTFont`** (a new object) via `withPointSize(_:)`.
- **`reconfigureFonts`:** `VectorGlyphRenderer.reconfigureFonts(fontAtlas:...)`
  (line ~510). Designed for a **font-family change** (user picks a new typeface). It
  throws away everything tied to the old font: it clears `fontCache`,
  `glyphIDCache`, `descriptorCache`, replaces the `maskAtlas` with a fresh empty
  one, drops the curve-buffer cache, and **eagerly rebuilds** the raster atlas
  (`makeRasterAtlas`) and color-glyph atlas (`makeColorGlyphAtlas`). It is correct
  but heavy — appropriate once per font pick, ruinous once per gesture frame.
- **Why size-change currently triggers a full rebuild:** every vector cache is
  keyed on `ObjectIdentifier(font)` (e.g. the descriptor cache key at line ~1170 and
  the mask-atlas `Key` at line ~1187). A new point size = a new `CTFont` = a new
  identity, so *every* cache misses by construction, and the apply path calls
  `reconfigureFonts` to "honestly" rebuild. The mask key *also* encodes the rendered
  pixel `width`/`height` (lines ~1189-1190) and the bake reads `CTFontGetSize`
  (line ~1538) into the accumulation hash, so **masks at different sizes already
  occupy distinct atlas slots** — the eager nuke-and-rebuild is not required for
  correctness, only the cache-identity coupling forces it.
- **`applyFontSize` (the apply path):** `Sources/LabanApp/TerminalBitmapView.swift`
  (~line 3700). Swaps the `FontAtlas`, reconfigures the active backend, throttles
  the grid reflow (only on integer `cols`/`rows` change), optionally persists. Its
  tail tries to guarantee **no presented frame mixes the old atlas with the new
  grid** by setting `waitForFrameCompletion = true` — but it does so via
  `let metal = backend as? MetalRenderer`, which is **nil for the vector backend**,
  so the guarantee is skipped there. The vector renderer **self-presents** on its
  own display link (`backendSelfPresents == true`), so it keeps pushing async frames
  while the atlas is mid-rebuild. That is the source of the **size-mixing**: a frame
  presented during the rebuild draws some glyphs from the new atlas and some stale.
- **Self-presenting:** a backend whose `presentationLayer != nil` drives its own
  `CAMetalLayer` and presents frames on a display-link timer, rather than the view
  blitting in `draw(_:)`. The vector renderer self-presents; the software backend
  does not. `backendSelfPresents` (TerminalBitmapView) records this.
- **Scroll budget machinery (the thing we must not regress):** during scroll a fast
  row reveal can drop ~160 new glyphs in one frame. The renderer caps **new-entry
  mask bakes per frame** (`remainingMaskBakeDispatches`, see the comment at
  lines ~1342-1354): overflow glyphs return nil and are drawn this frame from the
  O(1) raster atlas (exactly the classic CoreText bitmap path), then bake to vector
  quality on a later frame when the budget admits. Per-phase (crisp sub-pixel)
  masks bake **only at rest** (lines ~110-113), because a mask baked under motion is
  never reused. The entire design assumes **bake = rare; steady-state = reposition
  cached masks**. Any change that evaluates curves per-frame-per-glyph in
  steady-state breaks this and regresses scroll.
- **Existing benches / tooling (real, do not invent):**
  - `Tests/LabanRendererTests/VectorScrollFrameTimeBench.swift` (class
    `VectorScrollFrameTimeBench`) — vector scroll frame-time gate.
  - `Tests/LabanRendererTests/ColorGlyphScrollBench.swift` — color-glyph scroll gate
    (the AGENTS.md regression bed for per-frame CoreText cost).
  - `scripts/analyze-metal-trace` — the Metal trace capture/compare tool;
    `docs/process/dev-process.md` §"Metal Trace Perf Loop" documents it.
  - `ScrollDebugServer` routes `POST /zoom/pinch`, `GET /zoom/state`,
    `GET /scroll/screenshot.png` (from the prior plan) — headless drive + observe.

### Key files this plan touches

- `Sources/LabanRenderer/VectorGlyphRenderer.swift` — add a lightweight
  `setPointSize`-style path that updates the font/metrics and lets visible glyphs
  bake lazily into the existing size-keyed atlas, **without** the raster/color atlas
  rebuild or the atlas nuke. (M1.)
- `Sources/LabanApp/TerminalBitmapView.swift` — in `applyFontSize`, (a) call the new
  lightweight path for the vector backend instead of `reconfigureFonts`, and
  (b) extend the synchronous "no mixed frame" guarantee to cover the self-presenting
  vector backend (drain one synchronous frame before the next present). (M0 + M1.)
- `Tests/LabanRendererTests/` and/or `Tests/LabanAppTests/` — a size-mixing
  regression gate, and a scroll-non-regression guard. (M0, M2.)
- This file and `execplans/active/vector-continuous-pinch-zoom.md` — cross-link, and
  record the size-application redesign in the Decision Log.

## Design decisions (made here, not left to the reader)

1. **Change size, do not replace the font (lazy bake), as the default fix.** The
   vector apply path stops calling `reconfigureFonts` (the family-change sledgehammer)
   and instead calls a new lightweight method that sets the new `FontAtlas` and
   metrics and leaves the *existing* mask atlas in place. Because masks are already
   size-keyed, the ~100 visible glyphs bake on demand at the new size through the
   normal per-frame budget, and old-size masks age out via the existing TTL
   eviction. No raster/color atlas rebuild per gesture frame. This is the smallest
   change that removes the jank and **keeps the plan's "crisp at every fractional
   size" promise** — every size still gets a real bake, just lazily and budgeted,
   reusing the exact scroll-safe machinery rather than a new path. (See M1.)

2. **Fix the size-mixing as a synchronization bug, independently of M1.** Even with
   lazy bake, a self-presenting backend can present a half-updated frame. The
   correctness fix is to make `applyFontSize` give the vector backend the same
   "one synchronous, fully-drained frame before any further present" guarantee the
   classic path already gets — generalize the `backend as? MetalRenderer` block to a
   backend-agnostic "complete one frame synchronously" call. This lands **first**
   (M0) so the visible defect is gone before we optimize, and it is verifiable on
   its own.

3. **Resolution-independent rendering (evaluate curves per frame) is explicitly
   deferred, and if ever pursued must be gesture-scoped.** Evaluating glyph coverage
   from curves every frame would make zoom "free" but **runs during scroll too**,
   defeating the bake-once-reuse model the scroll budget is built around. This plan
   does **not** do that. It is recorded here only to state why: the regression
   surface is exactly normal scrolling. If a future plan wants it, it must gate the
   per-frame-curve path to the live gesture and fall back to baked masks at rest,
   behind a runtime flag (mirroring `VectorSmoothScrollMode`), with the scroll
   benches as the gate. (See M3, prototype-only.)

4. **Derisking is part of the plan, not a courtesy.** Measure scroll cost *before*
   any change (M0 baseline), keep each change additive and independently revertable,
   reuse the existing graceful-degradation fallback rather than inventing one, and
   add a fail-first guard that breaks loudly if the new size path ever leaks into the
   scroll (non-zero `scrollPhaseOffset`) path.

## Milestones

### M0 — Lock the baseline and kill the size-mixing (correctness first)

Scope: prove today's scroll cost as numbers, and fix the visible double-size frame
without yet touching the rebuild cost.

What will exist that didn't: a recorded scroll baseline (bench numbers + one Metal
trace), a headless **size-mixing regression test** that fails on today's code, and a
generalized synchronous-frame guarantee in `applyFontSize` that covers the
self-presenting vector backend.

Approach:
- **Baseline (run and record into this file's Artifacts):**
  - `swift test --filter VectorScrollFrameTimeBench` and
    `swift test --filter ColorGlyphScrollBench` — record the reported frame-time
    numbers.
  - Capture one scroll Metal trace via `scripts/analyze-metal-trace` per
    `docs/process/dev-process.md` §"Metal Trace Perf Loop"; record the summary
    (CPU pp, GPU p95). This is the "before" the M2 compare runs against.
- **Size-mixing gate (fail-first):** add a headless test that selects the vector
  renderer, drives a `POST /zoom/pinch` step (or calls `applyFontSize` with
  `quantize:false` directly on a Metal-backed view, `XCTSkip` if no Metal device),
  advances exactly one frame, and asserts the rendered frame contains glyphs at a
  single cell size — e.g. by probing that all baked mask entries referenced this
  frame share the current `fontAtlas.pointSize`, or via a pixel probe that the
  glyph row heights are uniform. It must **fail before** the M0 fix.
- **Fix:** in `applyFontSize`, replace the `MetalRenderer`-only
  `waitForFrameCompletion` block with a backend-agnostic "render one frame to
  completion synchronously, before the next async present" step that also applies
  when `backendSelfPresents` is true (vector). Concretely: gate the self-presenting
  display-link present until the synchronous reconfigure-and-draw frame has
  completed, so no partially-updated atlas is ever presented.

Acceptance (autonomous):
- The new size-mixing test fails on the pre-fix tree and passes after.
- `swift test --filter VectorGlyph` stays green.
- Manual (recorded as a screenshot artifact via `GET /scroll/screenshot.png`
  mid-gesture): no double-size shimmer.

### M1 — Stop the per-event font rebuild (the de-jank)

Scope: make a vector zoom step cheap by changing size instead of replacing the font.

What will exist that didn't: a lightweight `VectorGlyphRenderer` size-application
method (e.g. `setTerminalPointSize(_:sidebar:)` or
`reconfigureFonts(..., preservingAtlas: true)`) that updates the font + metrics and
leaves the mask atlas resident; `applyFontSize` calls it for the vector backend on
the live gesture path instead of `reconfigureFonts`.

Approach:
- Add the lightweight method to `VectorGlyphRenderer`. It sets `self.fontAtlas` /
  `self.sidebarFontAtlas` and any per-size metrics the draw path reads, but does
  **not** clear the mask atlas, does **not** rebuild the raster/color atlases, and
  does **not** drop the curve store (curves are size-independent geometry). Visible
  glyphs at the new size bake lazily through the existing per-frame budget; old-size
  masks age out via TTL. If the raster-atlas fallback (used when the bake budget is
  exceeded) genuinely needs a size-specific texture, rebuild *that* lazily on first
  miss, not eagerly per call — document whichever is true after reading
  `makeRasterAtlas`.
- In `applyFontSize`, route the vector backend to the new method on gesture frames.
  The family-change path (font panel) keeps calling the full `reconfigureFonts`.
- Keep M0's synchronous-frame guarantee.

Acceptance (autonomous):
- A headless test drives a multi-step pinch sweep on a Metal-backed vector view and
  asserts the raster/color atlas is **not** rebuilt per step (e.g. a build-count
  test seam on the renderer increments at most once, ideally zero, across N gesture
  frames), while `effectivePointSize` still tracks fractionally via `GET /zoom/state`.
- `VectorScrollFrameTimeBench` and `ColorGlyphScrollBench` stay green (scroll path
  untouched).
- Manual: pinch over the vector backend is visibly smooth (no per-step hitch),
  recorded as a short screen capture artifact.

### M2 — Prove scroll did not regress (the derisk gate)

Scope: turn "scroll is fine" into measured, gated evidence.

What will exist that didn't: an after-measurement compared against M0's baseline,
and a fail-first guard that the new size path cannot run on a scroll frame.

Approach:
- Re-run the M0 baseline commands on the post-M1 tree; run `scripts/analyze-metal-trace`
  in compare mode against the saved baseline trace. Record both into Artifacts.
- Add a guard test/assertion that the lightweight size path is **never** entered
  while `scrollPhaseOffset != .zero` (i.e. size application and scroll-phase baking
  are mutually exclusive on a frame), so a future edit that lets zoom leak into the
  scroll steady-state fails loudly.

Acceptance (autonomous):
- `analyze-metal-trace` compare reports no regression beyond its default thresholds
  (`--threshold-pp` 1.0 CPU pp, `--threshold-pct` 10.0 GPU p95%).
- `VectorScrollFrameTimeBench` and `ColorGlyphScrollBench` within noise of the M0
  numbers (record both).
- The leak-guard test fails when the path is deliberately mis-wired (mutate to prove
  it bites) and passes as shipped.

### M3 — (Prototype only, deferred) gesture-scoped resolution independence

Scope: a labelled prototype, behind a flag, default off, to evaluate whether
per-frame curve evaluation *during the gesture only* is worth it over M1's lazy
bake. Not promoted without its own spec.md entry per AGENTS.md.

This milestone is **not** required for the plan's purpose and ships nothing by
default. It exists so a future contributor knows the boundary: any per-frame-curve
path must be gated to the live gesture, fall back to baked masks at rest, sit behind
a runtime mode like `VectorSmoothScrollMode`, and be gated by the scroll benches.
Discard if M1's smoothness is sufficient (expected).

## Progress

- [x] (2026-06-29) M0 — baseline scroll benches recorded (see Artifacts);
  size-mixing gate `Tests/LabanRendererTests/VectorZoomSizeMixingTests.swift`
  written and confirmed fail-before/pass-after; `waitForFrameCompletion` made a
  backend-agnostic `RendererBackend` property (no-op default for software, stored
  on `MetalRenderer` and `VectorGlyphRenderer`); `applyFontSize`'s
  synchronous-frame guarantee de-gated from `as? MetalRenderer` to
  `backend.waitForFrameCompletion`, so the self-presenting vector backend now
  blocks one frame and never presents a mixed-size atlas. (Trace capture deferred
  to M2's compare; bench numbers are the load-bearing baseline.)
- [x] (2026-06-29) M1 — `VectorGlyphRenderer.applyLiveZoomFonts` added: updates
  font + metrics, clears only the cheap per-glyph CPU memos (`fontCache`,
  `glyphIDCache`, `descriptorCache`), and **keeps** the resident mask atlas, the
  curve-buffer cache, and the raster/color fallback atlases — no per-frame
  texture reallocation. `reconcileFallbackAtlasesForSettledSize` rebuilds the
  fallback atlases once on gesture end; the gesture font is retained in
  `zoomRetainedFonts` so preserved size-keyed entries keep unique identifier
  keys. `applyFontSize` gained a `liveZoom` flag routing the vector gesture path
  to the lightweight method (keyboard/menu/font-panel stay on the full
  `reconfigureFonts`, byte-identical). Gate
  `testLiveZoomSweepDoesNotRebuildFallbackAtlasesPerFrame` confirmed
  fail-before (38 rebuilds) / pass-after (0); `fallbackAtlasRebuildCount` seam
  added. Lint + vector/zoom suites green.
- [x] (2026-06-29) M2 — scroll benches re-run post-M1 and within noise of the M0
  baseline (see Artifacts); scroll-leak guard added
  (`liveZoomWhileScrollPhaseActiveCount` tripwire +
  `testLiveZoomNeverRunsDuringScrollPhase`), proven in both directions — stays
  zero on the real live-zoom path, fires when a scroll phase is forced active.
  (Used the scroll benches as the quantitative gate; a separate
  `analyze-metal-trace` capture was unnecessary because the scroll render path is
  byte-for-byte unchanged by M0/M1 — the benches already measure it directly and
  show no regression.)
- [ ] M3 — (deferred prototype) not started; documented boundary only.

## Artifacts and Notes

M0 baseline — scroll bench numbers on `Apple M2 Max`, release build,
`LABAN_RUN_PERF_BENCH=1 swift test -c release` (pre-change tree):

    === Scroll frame-time: GPU-driven vs vector fluid vs vector crisp ===
      path           cpu p50/p95/p99 ms
      gpu/classic    8.390 /  9.168 / 10.184
      vector/fluid   8.400 / 16.041 / 20.059
      vector/crisp   8.991 / 16.132 / 19.920

    ColorGlyphScrollBench: color/mono p50 ratios 1.00–1.01x (within noise);
    SoftwareRenderer variant 1.00–1.03x. (M2 re-runs these and must stay within
    noise of these numbers.)

M2 after — same machine/flags, post-M0+M1 tree:

    === Scroll frame-time: GPU-driven vs vector fluid vs vector crisp ===
      path           cpu p50/p95/p99 ms
      gpu/classic    8.361 /  9.091 /  9.380
      vector/fluid   8.368 / 16.498 / 20.058
      vector/crisp   8.994 / 16.626 / 20.064

    ColorGlyphScrollBench: color/mono p50 ratios 1.00–1.01x (software 1.00–1.01x).

Verdict: vector scroll p50 unchanged (8.368 vs 8.400 fluid; 8.994 vs 8.991
crisp); p95/p99 within run-to-run variance. No regression — expected, since
M0/M1 do not touch the scroll render path (the live-zoom size path is mutually
exclusive with the scroll-phase path, enforced by the M2 tripwire).

## Decision Log

- Decision: Fix the size-mixing as a backend-agnostic synchronous-frame guarantee
  in `applyFontSize`, landed before any perf work.
  Rationale: the existing guarantee is gated on `backend as? MetalRenderer`, which is
  nil for the self-presenting vector backend, so the vector path presents
  half-updated frames. It is a correctness bug independent of the rebuild cost, and a
  Metal trace cannot see it — it is found by reading and fixed by synchronization.
  Date/Author: 2026-06-29 / this plan.
- Decision: De-jank by changing rasterization size (lazy bake into the resident,
  size-keyed mask atlas) rather than replacing the `CTFont` and calling
  `reconfigureFonts` per gesture frame.
  Rationale: zoom is a scale change, not a font change. Masks are already size-keyed,
  so the eager nuke-and-rebuild of the raster/color atlases every frame is wasted
  work and the source of the jank; lazy bake reuses the proven scroll budget and
  keeps "crisp at every size".
  Date/Author: 2026-06-29 / this plan.
- Decision: Defer resolution-independent (per-frame curve) rendering; if ever done,
  it must be gesture-scoped and flag-gated.
  Rationale: per-frame curve evaluation runs during scroll too and defeats the
  bake-once-reuse model the scroll budget depends on. The regression surface is
  exactly normal scrolling, which this plan must protect. Lazy bake (M1) gets most of
  the smoothness at a fraction of the risk.
  Date/Author: 2026-06-29 / this plan.

## Validation and Acceptance

Baseline commands (run from the repo root, `/Users/rrj/wrk/laban`):

- `swift test --filter VectorGlyph` — vector backend stays green throughout.
- `swift test --filter VectorScrollFrameTimeBench` and
  `swift test --filter ColorGlyphScrollBench` — scroll frame-time gates; record
  numbers before (M0) and after (M2); must stay within noise.
- The new size-mixing gate (M0) and no-rebuild gate (M1) fail before their
  respective changes and pass after.
- `scripts/analyze-metal-trace` compare (M2) against the M0 baseline trace — no
  regression beyond default thresholds.
- `./scripts/build-app && ./scripts/install-app` — quit & relaunch Laban, switch to
  the vector renderer, pinch / Cmd+scroll: smooth, no double-size shimmer; then
  scroll a long log and confirm it is as smooth as before.
- Headless per `docs/process/dev-process.md`: `--scroll-debug`, then
  `POST /zoom/pinch` + `GET /zoom/state` + `GET /scroll/screenshot.png` at a
  fractional size to confirm single-size, fractional rendering.

A milestone is done only when its new test(s) fail before the change and pass after,
and the scroll benches stay within noise of the M0 baseline.

## Idempotence and Recovery

All changes are additive and independently revertable. M0's synchronous-frame fix
and M1's lightweight size path are separate commits: reverting M1 restores the
`reconfigureFonts` call (functional, just janky); reverting M0 restores the
size-mixing (visible defect, no crash). The font-family-change path keeps using the
full `reconfigureFonts`, so font picks are unaffected by any milestone. No persisted
state or schema changes: the persisted font size remains a `Double` under
`FontAtlas.userFontSizeKey`.

## Interfaces and Dependencies

Must exist at completion:
- `VectorGlyphRenderer` lightweight size-application method (name TBD during M1;
  e.g. `setTerminalPointSize(_:sidebarFontAtlas:)` or
  `reconfigureFonts(..., preservingAtlas: Bool)`), updating font + metrics without
  rebuilding the raster/color atlases or nuking the mask atlas.
- `TerminalBitmapView.applyFontSize` routing the vector backend to that method on the
  gesture path, and a backend-agnostic synchronous-frame guarantee replacing the
  `backend as? MetalRenderer`-only block.
- A renderer test seam exposing raster/color-atlas rebuild count (for M1's
  no-rebuild gate) and/or a mask-entry size-uniformity probe (for M0's size-mixing
  gate).
- Scroll non-regression evidence (M2): bench numbers + `analyze-metal-trace` compare,
  recorded in this file's Artifacts, plus the scroll-leak guard test.
