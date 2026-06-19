# Vector (Curve) Glyph Renderer

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then deliver a working opt-in vector-glyph renderer without repeating
prior research.

## Purpose / Big Picture

Laban ships three renderers today: `software` (CPU bitmap, used by headless /
fixtures / capture-replay), `classic` (Metal, the default), and `gpuDriven`
(Metal GPU-cell path, opt-in on macOS 26). All three rasterize glyphs the same
way: CoreText draws each glyph's alpha mask into a CPU buffer once, the mask is
uploaded to an R8 atlas texture (`Sources/LabanRenderer/MetalGlyphAtlas.swift`,
`Sources/LabanRenderer/FontAtlas.swift`), and the atlas is sampled at one
fixed subpixel position. That is fast and well-understood, but it caps text
quality at whatever resolution CoreText rasterized, has no real subpixel
anti-aliasing, and re-rasterizes from scratch whenever the size or subpixel
position changes.

This plan adds a **fourth, opt-in renderer** — `vectorGlyph` — that takes the
approach described in <https://osor.io/text> (read in full before starting; the
summary below is not a substitute). Instead of baking alpha masks, it extracts
the **Bézier curves** that define each glyph, sends them to the GPU, and
**rasterizes them at runtime** into an atlas. Glyphs stay resident in the atlas
across frames so the renderer can keep adding coverage samples ("temporal
accumulation"), converging to high-quality anti-aliasing for static text at
near-zero per-frame cost, while still supporting subpixel positioning and
subpixel (per-R/G/B-element) anti-aliasing.

After this work, a user can pick "Vector Glyph Renderer" from the View ▸
Renderer menu (or the Settings popup), their live terminal session keeps running
without restart, and text renders with crisp vector outlines and configurable
subpixel anti-aliasing. The existing `software`, `classic`, and `gpuDriven`
renderers are unchanged and remain the defaults/fallbacks.

### Why this belongs in Laban

- A terminal is almost entirely text that stays still for many frames — the
  ideal workload for a temporal-accumulation rasterizer.
- Laban is a polished macOS terminal where text quality carries perceived
  product quality; OLED-style panel owners (Samsung QD-OLED, LG WOLED) suffer
  visible color fringing from the current single-sample approach.
- The curve data is already available on-device via CoreText (`CTFontCreatePathForGlyph`),
  so — unlike the article, which uses an offline FreeType bake — Laban can do
  the whole pipeline at runtime with no offline tooling.

### Non-goals (this plan)

- Replacing `classic` as the default. `vectorGlyph` ships opt-in and
  default-off, exactly as `gpuDriven` did. Default-enable is a separate,
  evidence-gated decision (see ADR 0017's threshold model).
- Subpixel structures read from the OS/display protocol. macOS exposes no
  arbitrary subpixel layout API; the user picks a layout (RGB stripe default,
  plus a debug editor). This matches the article's "A Plea" being unresolved.
- Hinting. Like the article, glyphs are not hinted; positions fall between
  pixels on purpose. (Box-drawing alignment is handled separately — see M5.)
- Changing the `[FrameCommand]` contract, the software/offscreen/debug/capture
  paths, or `TerminalCellPayload`. Those remain the shared language.

## Research / SOTA context (June 2026)

This section records what web research found about the state of the art, so a
fresh contributor does not re-derive it. Verified sources:

- **The technique is mature and settled.** The per-pixel horizontal-ray-vs-
  quadratic-Bézier winding number (solved via the quadratic formula) is the
  canonical method. Lineage: Will Dobbie, *GPU text rendering with vector
  textures* (origin) → GreenLightning/gpu-font-rendering (GitHub, the clearest
  open write-up of the winding-number math, including the elegant result that
  `t0` is always an exit and `t1` always an entry) → Evan Wallace, *Easy
  Scalable Text Rendering on the GPU* (subpixel AA + horizontal-blur insight)
  → Sebastian Lague's Text-Rendering repo (Unity/C#, popularizer).
- **osor.io's contribution is the engineering recipe, not new math:** runtime
  curve extraction → resident atlas → **temporal accumulation** → subpixel AA
  with overlapping sample quads. That recipe is the de-facto 2026 SOTA for this
  family.
- **No terminal ships GPU curve rasterization today.** Verified: Ghostty (which
  Laban already uses via `libghostty-vt`) rasterizes glyphs on the CPU
  (`src/font/Atlas.zig`, `SharedGrid.zig`) and uploads an alpha-mask texture —
  the same model as Laban's `MetalGlyphAtlas`. kitty/WezTerm/Alacritty are the
  same family. So `vectorGlyph` is greenfield in the terminal space, not
  catch-up.
- **The Slug algorithm (Eric Lengyel) is the numerical-precision SOTA but is
  patent-encumbered** (US 9,710,310, granted 2017, ~2035 term). Everyone —
  including osor.io and GreenLightning — omits it "due to the associated
  patent" and instead **masks precision errors with temporal accumulation**
  (a single bad intersection sample is 1/512 error, imperceptible). This plan
  follows that patent-safe stance.
- **No Metal reference implementation exists.** osor.io's author (Rubén Osorio)
  publishes only Jai helper modules on Codeberg (including `osor_vulkan`); the
  article's renderer is Vulkan/D3D12-HLSL on a 9070 (Windows), not Metal. The
  MSL compute shader is written from scratch by translating the HLSL winding-
  number kernel. There is no code to copy.
- **The other SOTA contender is Linebender's GPU-compute 2D path rendering**
  (vello / vello_sparse_strips / vello_hybrid, Rust + wgpu, Metal-supported).
  These solve *general* 2D vector graphics via prefix-sum parallelization, but
  vello explicitly lists **"Glyph caching" as an open alpha gap** (issue #204,
  still open) and is "not yet suitable for production use." For a terminal's
  specific workload (monospaced, mostly-static, single-font, heavy reuse) the
  winding-number-per-texel-into-a-resident-atlas approach is simpler,
  lower-risk, and purpose-fit. vello's glyph-cache gap is exactly what osor.io's
  temporal-accumulation atlas already solves.

### Mac-specific findings that shape the plan

1. **Apple GPU `simdgroup` is 32-wide, not 16.** The article's band
   scalarization assumes 16-thread NVIDIA waves. On Apple Silicon a Metal
   `simdgroup` is 32-wide, so `WaveActiveMin/Max` ↔ `simd_min`/`simd_max` still
   scalarizes the row-major curve loop, but the wave geometry and thread-to-
   texel packing constants differ. The M1 milestone uses 32-wide groups.
2. **Apple GPUs are TBDR with programmable tile shaders / imageblocks.** This
   is an opportunity the article doesn't use: a tile-shader coverage pass could
   rasterize into tile memory and resolve to the atlas without a separate
   compute pass + barrier. This is a **stretch spike for a future milestone**,
   not v1 — the plain compute-into-atlas path works fine on Apple Silicon and
   matches the article.
3. **Curve extraction at runtime via `CTFontCreatePathForGlyph` is strictly
   better than the article's offline FreeType bake** — live outlines for any
   CoreText font, no offline tool, no asset format. The plan banks this.
4. **macOS exposes no arbitrary subpixel-layout API.** The article's "A Plea"
   is unresolved; user-configurable layout (RGB stripe default + custom for
   OLED) is the best achievable. The plan specifies exactly this.

## Reference summary of the osor.io technique

Embedding the essential method here so the plan is self-contained (per
`PLANS.md`: do not outsource to external blogs). Cross-check the SOTA notes
above: every item here matches the established method.

1. **Curves.** Each glyph is a set of outline segments: lines, quadratic
   Béziers (3 points), and cubic Béziers (4 points). Lines become quadratics by
   inserting a midpoint. Cubics are split into **two** quadratics: given cubic
   `p0,p1,p2,p3`, compute `c0 = lerp(p0,p1,0.75)`, `c1 = lerp(p3,p2,0.75)`,
   `m = lerp(c0,c1,0.5)`, then emit `p0,c0,m` and `m,c1,p3`. After this step a
   glyph is a flat list of quadratic Béziers, each stored as three `float2`
   control points (consecutive curves share endpoints, so storage is 2 points
   per curve + 1 seed).

2. **Coverage (the winding-number kernel — embedded in full).** For each atlas
   texel, shift coordinates so the sample point is the origin and the ray is the
   +x axis, then test every curve for intersection and accumulate a **winding
   number**. For a quadratic Bézier with control points `P0=(x0,y0)`,
   `P1=(x1,y1)`, `P2=(x2,y2)`:
   - The y-component is `y(t) = (1-t)²y0 + 2(1-t)t·y1 + t²y2 = a·t² − 2b·t + c`,
     where `a = y0 − 2y1 + y2`, `b = y0 − y1`, `c = y0`.
   - Solve `a·t² − 2b·t + c = 0`:
     - If `|a|` ≈ 0 (linear segment, e.g. a converted line): at most one root,
       `t = c / (2b)` when `b ≠ 0`.
     - Else discriminant `d = b² − a·c`. If `d < 0`, no intersection. Else
       `t0 = (b − √d)/a` and `t1 = (b + √d)/a`.
   - A root is a valid intersection only if `0 ≤ t < 1` (end-exclusive; the
     endpoint belongs to the next segment) **and** `x(t) ≥ 0`, where
     `x(t) = (1-t)²x0 + 2(1-t)t·x1 + t²x2`.
   - **Classification (the sign rule):** `t0` is always an **exit** (winding
     `+1`) and `t1` is always an **entry** (winding `−1`). This is fixed by the
     derivative `dC_y/dt`, which is `−2√d ≤ 0` at `t0` and `+2√d ≥ 0` at `t1`,
     combined with the TrueType contour convention (outer contours clockwise,
     filled area to the right). It holds regardless of the sign of `a`.
   - Winding number `W = (#exits) − (#entries)` summed over all curves. The
     texel is **inside** when `|W| ≠ 0`. Per-sample coverage is
     `saturate(abs(W))` (see the orientation trap below). For anti-aliasing,
     intersections falling within one pixel-width of the origin contribute a
     fractional weight (the pixel-window rule) instead of ±1, giving exact 1-D
     coverage along the ray; multiple ray directions (x and y) give 2-D AA, and
     temporal accumulation (item 6) gives sub-pixel AA.

   **Orientation / Y-flip trap (load-bearing).** `CTFontCreatePathForGlyph`
   returns outlines in **em-space, Y-up**. The atlas texture is top-left,
   **Y-down**. Naively negating y to fill the texture reverses contour winding
   direction, which flips the sign of `W`. If coverage were `saturate(W)`
   (clamping negative → 0), a flipped glyph would read as fully *outside*
   (alpha 0) — every glyph invisible. Two safe options; this plan picks **(a)**:
   - **(a) Sign-invariant coverage:** compute `saturate(abs(W))` per sample, and
     accumulate `sum += uint4(saturate(abs(W)), 1)` into the RGBA accum buffer.
     Robust to any orientation flip; costs one `abs`.
   - **(b) Preserve orientation:** consistently flip the ray axis (or negate
     control-point x, not y) so `W` stays positive for inside, then use
     `saturate(W)`. More fragile — any path that touches y must agree on the
     flip convention. Not chosen.
   The M0 CPU oracle and the M1 GPU readback both assert `saturate(abs(W))`
   matches the CoreText alpha mask; this is the correctness invariant the
   Y-flip trap would otherwise silently break.

3. **Band acceleration.** Split each glyph into horizontal bands; a bitset per
   band marks which local curve indices cross it. A texel only tests the curves
   in its band. Threads are packed **row-major** across the glyph so a GPU wave
   spans a minimal band range, letting curve iteration and curve reads
   **scalarize** via `WaveActiveMin/Max` (`simd_min`/`simd_max` in Metal — note
   Apple GPU `simdgroup` is **32-wide**, not the article's 16-wide NVIDIA wave;
   the scalarization still applies but packing constants differ).

4. **Atlas packing.** The atlas is one large 2D texture (grown in power-of-two
   dimensions up to the device maximum, e.g. 8192²; see the Eviction Decision).
   It is divided into **base slots of 16×16 texels** — that 16×16 is the
   minimum allocation unit, *not* the atlas extent. A free-cell bitset (one bit
   per base slot) tracks occupancy. A glyph rounds its texel size up to a
   power-of-two slot count and finds that many **aligned** contiguous free bits,
   then maps the 1D bit index back to 2D via a Morton (Z-order) decode.
   **Transposed** Z-order (swap x/y on decode) packs tall thin Latin glyphs
   ("l","j","1") into vertical 1×2 slot rectangles. When no aligned run is free,
   see the Eviction Decision — the atlas never silently drops a glyph.

5. **Atlas key.** `(font, glyphIndex, quantizedSizeX, quantizedSizeY,
   quantizedSubpixelOffsetX, quantizedSubpixelOffsetY)`. Size is u24.8 fixed
   point; subpixel offset is u0.8. Fixed point collapses near-identical floats
   that would otherwise miss the cache. Monospaced editors can additionally
   round advances to pixel boundaries so the same glyph in every column/row
   hits one atlas entry.

6. **Temporal accumulation.** A newly seen glyph gets many samples its first
   frame (e.g. 8), then fewer (4, 2, 1) until a cap (e.g. 512). Each frame adds
   a `uint4(coverage, 1)` to the texel's running `sum = (r,g,b,count)`; final
   alpha = `sum.rgb / sum.a`. Static text converges for free; moving/resizing
   glyphs re-seed. Sample jitter uses a quasirandom $R_2$ sequence (Martin
   Roberts). A single bad intersection sample is 1/512 error — imperceptible.

7. **Subpixel AA.** Instead of one coverage value per pixel, compute three
   coverage values — one per R/G/B subpixel element — by sampling the winding
   number at each element's position. Effective horizontal resolution triples on
   a classic RGB-stripe panel. The sample quad for each element can **overlap**
   its neighbors and bleed outside the pixel (equivalent to Evan Wallace's
   "blur horizontally after subpixel AA" but folded into the sample geometry),
   which kills fringing on non-stripe layouts. An editor lets the user place
   each element's quad to match their panel.

## Architecture: where this fits

Read these files first to orient:

- `Sources/LabanRenderer/RendererBackend.swift` — the swappable-backend
  protocol every renderer implements. `render(_ commands:, cellPayload:,
  damage:, rendererFallbackReason:)` is the entry point.
- `Sources/LabanRenderer/RendererMode.swift` — the persisted enum (`classic`,
  `gpuDriven`). Gains a `.vectorGlyph` case. **Cascades:** `RendererMode` is
  `CaseIterable` with an exhaustive `isAvailableOnCurrentOS` switch
  (`RendererMode.swift:9-17`), so adding `.vectorGlyph` forces edits to that
  switch and to `defaultMode`. Intended: `vectorGlyph.isAvailableOnCurrentOS`
  returns `true` unconditionally (no macOS-26 gate), so it surfaces in
  `availableModes` on every OS, and `defaultMode` is left returning
  `.gpuDriven ?? .classic` (default unchanged). The exhaustive switch in Swift
  is a feature here — the compiler proves no mode is forgotten.
- `Sources/LabanRenderer/MetalRenderer.swift` — owns the `CAMetalLayer`, the
  persistent target texture, the drawable scheduler, theme reconciliation, and
  the `classic`/`gpuDriven` content-pass dispatch (`encodeContentPass` vs
  `encodeGPUCellContentPass`). ~3600 lines; the new renderer does **not** grow
  this file. It reuses `MetalDrawableScheduler`, `ThemeData` (the renderer's
  theme value type, `Sources/LabanRenderer/Theme.swift`), `FontAtlas` metrics,
  and the `[FrameCommand]`/`TerminalCellPayload` producers as-is.
- `Sources/LabanApp/RendererModeMenuController.swift` — the View ▸ Renderer menu
  and the `RendererSelection` enum (`software`/`classic`/`gpuDriven`). Gains a
  `vectorGlyph` item.
- `Sources/LabanRenderer/Shaders.metal` — the classic/gpuDriven shaders. The
  vector renderer gets its **own** `.metal` file (`VectorGlyphShaders.metal`)
  compiled into the same `Laban_LabanRenderer.bundle` resource bundle (see
  `Sources/LabanRenderer/ResourceBundle.swift`); it does not edit the existing
  shaders.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` — must gain feature parity
  with the live window path (ADR / AGENTS.md hard rule). The renderer is
  selectable headless and exposes debug endpoints.
- `docs/adr/0017-gpu-driven-cell-renderer.md` — the regime this plan follows:
  additive opt-in mode, frame-command contract preserved, raw-RGBA parity
  tests, release timing evidence, session-identity-safe live switching.

The new renderer is a new `RendererBackend` implementation:
`Sources/LabanRenderer/VectorGlyphRenderer.swift`. It owns its own
`CAMetalLayer` (like `MetalRenderer`), its own compute+render pipelines, its own
atlas (curve-backed, not alpha-mask-backed), and its own persistent target
texture. It consumes `[FrameCommand]` and (when available) the
`TerminalCellPayload` exactly as the other backends do; it never makes the
software/debug/capture paths depend on its Metal internals.

### Ownership boundary (load-bearing)

`VectorGlyphRenderer` is a peer of `MetalRenderer`, not a mode inside it. Rationale:
`MetalRenderer` is already ~3600 lines with two interleaved content passes and a
shared persistent-target/drawable lifecycle; the vector path has a fundamentally
different resource set (curve buffers, a coverage-accumulation atlas with a
sample-count channel, a compute rasterizer, temporal state). Inlining it would
entangle the classic path. Both backends implement the same
`RendererBackend` protocol, so the host view, `AppModel`, and `Session` are
unaware of which one is active — which is what makes live switching safe.

## Getting curves on macOS (no offline bake)

The article uses FreeType offline. Laban can do better at runtime:

- `CTFontGetGlyphsForCharacters(font, &uniChars, &glyphs, count)` → glyph IDs.
- `CTFontCreatePathForGlyph(font, glyph, &transform, &err)` → a `CGPath` for
  that glyph's outline (this is the live equivalent of FreeType's outline
  extraction; it works for any CoreText-loadable font including the bundled
  JetBrainsMono TTF, user NSFontPanel picks, and system fonts).
- Walk the path with `CGPath.apply(info:function:)` using the element applier
  (`.moveToPoint`, `.addLineToPoint`, `.addQuadCurveToPoint`,
  `.addCurveToPoint`, `.closeSubpath`) to extract raw segments, then apply the
  article's line→quadratic and cubic→2×quadratic transforms to produce the
  canonical all-quadratic form.

This curve extraction lives in a pure-Swift/CoreGraphics module-visible type
(`GlyphCurveStore`) with no Metal dependency, so it is unit-testable against
CoreText's own alpha mask without a GPU.

## Milestones

Each milestone is independently verifiable and additive. Nothing here touches
the shipping renderers until M5 wires the menu item, and even then it is opt-in.

### M0 — Curve extraction (CPU, no GPU)

Scope: a `GlyphCurveStore` that, given a `CTFont` and a glyph ID, returns the
canonical quadratic-curve list. Pure Swift + CoreGraphics; no Metal.

What exists after: a tested type that turns any CoreText glyph into the exact
curve representation the GPU will consume, plus a reference CPU rasterizer
(horizonal-ray winding number, no band acceleration) used only as a test oracle.

Commands:
- `./scripts/build-app`
- `swift test --filter GlyphCurveStoreTests`

Acceptance:
- For every printable ASCII scalar in JetBrainsMono and Menlo, the CPU
  reference rasterizer's coverage (256 samples per pixel, no subpixel) matches
  a CoreText alpha mask (`CTFontDrawGlyphs` into a `CGContext`) within ±2/255
  per pixel over the glyph's ink bounds. Test emits expected/actual/diff PNGs
  to `.build/vector-glyph-parity/` on mismatch (mirror `GPUCellParityTests`).
- Cubic→2×quadratic split unit test uses a concrete worked example, not a
  reference to the article. Given `p0=(0,0)`, `p1=(0,4)`, `p2=(4,4)`,
  `p3=(4,0)`:
  - `c0 = lerp(p0,p1,0.75) = (0,3)`
  - `c1 = lerp(p3,p2,0.75) = (4,3)`
  - `m  = lerp(c0,c1,0.5) = (2,3)`
  - Output curves: `Q1 = (0,0),(0,3),(2,3)` and `Q2 = (2,3),(4,3),(4,0)`.
  The test asserts `c0`, `c1`, `m` to 1e-6, that `Q1`'s end equals `Q2`'s start
  (`m`, i.e. C0-continuous), and that the midpoint of each output quadratic
  lies on the original cubic (tangent-preserving spot check at t=0.25 and
  t=0.75 of the source cubic).
- Winding-number unit test on a synthetic unit square (4 line-segments → 4
  quadratics) asserts `|W| = 1` for an interior sample and `|W| = 0` for an
  exterior one, using the embedded kernel (coefficients `a,b,c`, root
  selection `0≤t<1` and `x(t)≥0`, t0-exit/t1-entry rule).

### M1 — Compute rasterizer into a scratch atlas (no packing, no temporal)

Scope: a Metal compute pipeline (`VectorGlyphShaders.metal`) that rasterizes
one glyph's curves into a fixed scratch region, single sample, no band
acceleration, no accumulation. Proves the GPU coverage matches the M0 CPU
oracle. This is a **from-scratch MSL port** of the HLSL/D3D12 winding-number
kernel from the osor.io article — no Metal reference implementation exists
(see Research / SOTA context). Translate the per-texel horizontal-ray +
quadratic-formula winding-number logic; do not port banding, accumulation, or
subpixel in this milestone.

What exists after: a GPU winding-number shader and a readback harness.

Acceptance:
- A debug-only test rasterizes the ASCII set through the compute shader and
  compares the readback to the M0 CPU oracle within ±3/255 per pixel (the extra
  tolerance covers float-vs-double and GPU ray-quad precision). Same PNG-on-
  mismatch artifact discipline.
- `scripts/analyze-metal-trace --self-test` still passes (the perf tooling is
  not broken by the new shader).

### M1a (stretch) — Tile-shader coverage pass on Apple Silicon

Scope: optional spike that replaces the M1 compute pass with an Apple-GPU
**tile shader** rasterizing coverage into tile memory (imageblock) and
resolving to the atlas, avoiding the compute-pass + barrier. The article does
not use this; it is a Mac-specific optimization enabled by TBDR.

Acceptance: only promoted if it beats the M1 compute path on release timing
for the ASCII set *and* keeps the M1 readback parity; otherwise it is recorded
as a no-go in the Decision Log and discarded. Not a blocker for M2.

### M2 — Z-order atlas + `VectorGlyphRenderer` on screen (ASCII, no temporal)

Scope: the resident curve atlas with Morton free-cell packing (transposed
Z-order), keyed by `(font, glyphIndex, quantizedSize, quantizedSubpixelOffset)`.
A minimal `VectorGlyphRenderer: RendererBackend` that renders `.glyphRun` frame
commands for single-scalar ASCII to its own `CAMetalLayer`, single sample per
frame, no accumulation. Plumb it into `RendererMode` / `RendererSelection` /
`RendererModeMenuController` as an opt-in, default-off, all-OS-available mode
(curve rasterization needs no macOS 26 feature; do **not** gate it behind
`#available(macOS 26, *)`).

What exists after: a selectable renderer that draws plain ASCII terminal text
on screen, missing most features (decorations, wide glyphs, overlays), but
demonstrably vector-rasterized.

Acceptance:
- Selecting "Vector Glyph Renderer" in a live window renders readable ASCII
  output (e.g. `seq 100 | shuf | head`) without restarting the session; the
  shell keeps running, scrolling works, and switching back to `classic`
  restores the classic look. Session identity survives (verified by the
  M5 session-identity check, but exercised here manually).
- `GET /debug/render` returns a `RenderResponse` whose `configuredRenderer`
  and `effectiveRenderer` are both `"vectorGlyph"` (this endpoint already
  exists — `Sources/LabanDebug/DebugRenderEndpoints.swift:29`, route
  `/debug/render` at `DebugHTTPServer.swift:323`; the headless parity test is
  `testRuntimeRenderStateReportsRendererStatus` in
  `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`). When the Metal device
  is unavailable, `effectiveRenderer` falls back to `"classic"` with a
  non-nil `fallbackReason`.
- Coverage parity for a plain-ASCII fixture vs the **M0/M1 single-sample CPU/GPU
  oracle** within ±2/255 per pixel over ink (both are single-sample point
  tests, so they agree by construction; this proves the on-screen path wires
  the same kernel). **Do not** compare M2 against `classic` here: M2 is
  single-sample with no AA while `classic` samples an anti-aliased CoreText
  mask, so edge texels differ by up to ~255. The classic-parity gate is
  deferred to M3's converged output.

### M3 — Temporal accumulation

Scope: convert the atlas texels from single-sample R8 to an RGBA accum buffer
`(sumR,sumG,sumB,count)`; add the article's sample schedule (8/4/2/1, cap 512)
and $R_2$ quasirandom jitter; resolve to alpha for sampling. Add a per-frame
sample budget and time-slicing so a frame full of fresh glyphs can't spike.

What exists after: static text that converges to high-quality AA; moving text
that re-seeds cleanly.

Convergence / determinism protocol (load-bearing for the parity and headless
gates, which assume reproducible output): the $R_2$ quasirandom sequence is
**deterministic given a sample index**. So a glyph's accumulated coverage is
a pure function of `(atlasKey, sampleCount)`. Tests and headless captures
therefore **pump exactly N frames** to a known sample index before reading
the atlas/screenshot — never capture mid-convergence against a wall clock.
Specifically: a fixture renders N identical frames (no damage, no scroll),
advancing each resident glyph's sample count by the 8/4/2/1 schedule capped
at 512; the capture happens at frame N where every glyph has reached ≥256
samples (or the cap). The exact N and the per-frame sample schedule are fixed
constants in `VectorGlyphParityTests` and the headless fixture driver, so the
same binary + fixture always produces byte-identical converged output. R₂
jitter is seeded from the glyph's atlas-key hash, not from wall time.

Acceptance:
- Visual: with the renderer selected and the terminal idle, a screenshot after
  pumping to the fixed converged sample count shows smooth anti-aliased ASCII
  indistinguishable (to a human diff) from the classic CoreText mask, but
  sharper than M2's first frame. Capture a converged vs first-frame screenshot
  pair as an artifact.
- Classic parity (deferred from M2): raw-RGBA of converged ASCII vs `classic`
  within ±4/255 per pixel over ink. Now achievable because both are
  anti-aliased.
- Perf: `scripts/analyze-metal-trace --record 10 --attach Laban` on a 4K-full
  of static ASCII reports the vector content pass at **≤0.3 ms p50** once
  converged (the article reports ~0.1 ms on a 9070; the gate is generous for an
  Apple GPU first pass). Record the baseline JSON under
  `.build/vector-glyph-trace/m3.json`.

### M4 — Subpixel anti-aliasing + layout editor

Scope: per-R/G/B coverage in the compute shader (three winding-number
evaluations per sample, one per element quad). A configurable subpixel layout
(RGB stripe default; transposed/RGB-BGR options; a JSON-editable custom layout
for OLED). Sample quads may overlap and bleed outside the pixel. A debug
endpoint to set/query the layout; the layout persists in UserDefaults.

What exists after: subpixel AA with no fringing on the user's actual panel.

Acceptance:
- A fringing test: render a thin-feature glyph (e.g. Miama or Nacelle ultra-
  light, or Menlo at small size) with (a) RGB-stripe layout on a simulated
  stripe panel and (b) a custom layout; capture both as artifacts and assert
  no single channel exceeds the others by more than a threshold at a known
  edge (i.e. no magenta/green fringe).
- A settings/debug UI (View ▸ Subpixel Layout, or a debug endpoint) lets the
  user change the layout live and see the effect without a restart.

### M5 — Feature parity, gates, docs, default-off ship

Scope: bring the vector renderer to feature parity with `classic` for
terminal-critical content, then run the full ADR-0017-style gate.

Parity items (each needs a raw-RGBA parity test where geometry allows, or a
documented fallback to the command path):
- Box-drawing / block elements / private-use symbols (these are
  **curve-aligned to the cell grid** so they must not subpixel-jitter; pin
  their atlas key's subpixel offset to (0,0) and round size to the cell —
  this is the "monospaced editor pixel-align" optimization from the article,
  applied selectively).
- Wide / CJK / ZWJ cluster glyphs (use the `TerminalCellPayload` cluster path
  and the existing `TerminalGlyphFallback`).
- Text decorations (underline/strikethrough/overline, all styles) and
  hyperlink visuals — emit as solid overlays exactly as the gpuDriven path does.
- Selection / find / cursor overlays, image quads, sidebar text, preedit.
- Inverse/faint/invisible — already pre-resolved into colors by
  `FrameProducer`, so the vector path renders them like the gpuDriven path.

Then:
- Raw-RGBA parity suite `VectorGlyphParityTests` modeled on
  `GPUCellParityTests`: zero-tolerance where geometry is identical (solid
  fills, decorations), tolerance-banded for glyph ink. Expected/actual/diff
  PNGs on mismatch.
- `HeadlessDebugRuntime` parity: the renderer is selectable headless,
  `GET /debug/screenshot` works through it, and a headless E2E renders a
  fixture identically to the live path.
- Release timing matrix via `scripts/analyze-metal-trace`: cursor blink,
  one-row append, 5%/25% dirty, sparse rows, full repaint, fast scroll, dense
  colours, box drawing, emoji/CJK/ZWJ, theme/atlas growth. Compare p50/p95/p99
  render-CPU and GPU against `classic`.
- Session-identity live-switch test: switch classic↔vectorGlyph mid-session on
  a running TUI (e.g. `btop`, `vim`) and assert the session, scrollback, cwd,
  and tab badge survive. Add `testVectorGlyphSwitchPreservesActiveSessionIdentity`
  to the existing `Tests/LabanAppTests/RendererModeSettingsTests.swift`, modeled
  on the proven `testRendererModeSwitchPreservesActiveSessionIdentity` (line 117)
  and `testRendererSelectionSwitchesBetweenSoftwareAndMetalWithoutReplacingSession`
  (line 156) in that same file — do not invent a new `RendererLiveSwitchTests`.
- Ship **default-off**. Do not change `RendererMode.defaultMode`. The menu item
  is enabled on all supported macOS versions (no `#available(macOS 26, *)`
  gate) unless a concrete blocker is found and logged in the Decision Log.
- Write/land the companion ADR `docs/adr/0022-vector-glyph-renderer.md` and add
  its one-line index entry to `docs/adr/README.md`.

Acceptance (the gate — all must pass):
- `swift test` green, including the new parity suite and the live-switch test.
- `./scripts/build-app` and `./scripts/install-app` produce a bundle where the
  View ▸ Renderer menu offers "Vector Glyph Renderer", selecting it renders a
  live shell with no session restart, and switching back is lossless.
- `GET /debug/render` returns a `RenderResponse` whose `configuredRenderer`/
  `effectiveRenderer`/`fallbackReason` report the correct pair and fall back to
  `classic` with a reason when the Metal device is missing (same endpoint as
  M2; the headless assertion is
  `testRuntimeRenderStateReportsRendererStatus` in
  `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`).
- Release timing JSON committed under `.build/vector-glyph-trace/m5.json`; the
  Decision Log records whether `vectorGlyph` met the ADR-0017 default-enable
  threshold (it is expected **not** to, this plan ships it opt-in regardless).

## Validation and Acceptance

The authoritative acceptance is the M5 gate above. In summary, a reviewer can
verify completion by:

1. `./scripts/build-app && ./scripts/install-app`, then launch Laban, open a
   shell, run `btop`, switch to Vector Glyph Renderer from the View menu, and
   confirm the TUI keeps running and text looks crisp with no session restart.
2. `swift test --filter VectorGlyphParityTests` is green and leaves no diff PNGs
   (new file `Tests/LabanRendererTests/VectorGlyphParityTests.swift`, modeled
   on `Tests/LabanRendererTests/GPUCellParityTests.swift`).
3. `swift test --filter RendererModeSettingsTests` is green, including the new
   `testVectorGlyphSwitchPreservesActiveSessionIdentity`. (There is no
   `RendererLiveSwitchTests`; the live-switch harness lives in
   `Tests/LabanAppTests/RendererModeSettingsTests.swift`.)
4. Headless: `laban-agent --headless --fixture=fixtures/<vector-fixture>.json`
   (per `docs/process/dev-process.md`) renders identically to the live path
   via `GET /debug/screenshot`.
5. `scripts/analyze-metal-trace` produces the M5 timing JSON; the numbers are
   recorded in the Decision Log.

If any gate fails, the renderer stays opt-in and the failure is recorded; it
does not block shipping the opt-in mode unless the failure is a correctness
regression in another renderer (which, by design, this plan cannot cause — it
adds files and adds enum cases, it does not edit `MetalRenderer`'s content
passes or the existing shaders).

## Progress

- [ ] M0 — `GlyphCurveStore`: CoreText→quadratic-curve extraction + CPU winding-number oracle; ASCII-vs-CoreText parity within ±2/255; cubic→2×quadratic and winding-number unit tests with embedded worked examples.
- [ ] M1 — Metal compute rasterizer (from-scratch MSL port) into scratch atlas, single sample; ASCII readback vs M0 oracle within ±3/255; `analyze-metal-trace --self-test` still passes.
- [ ] M1a (stretch) — Apple-GPU tile-shader coverage pass; promoted only if it beats M1 on release timing and keeps parity.
- [ ] M2 — Z-order (transposed) resident atlas + `VectorGlyphRenderer: RendererBackend` on screen for ASCII, single sample, no accumulation; wired into `RendererMode`/`RendererSelection`/`RendererModeMenuController` (default-off, no macOS-26 gate); on-screen ASCII readable, session survives; `GET /debug/render` reports `vectorGlyph`; parity vs M0/M1 oracle within ±2/255.
- [ ] M3 — Temporal accumulation (RGBA accum buffer, 8/4/2/1 schedule, cap 512, R₂ jitter); convergence/determinism protocol (pump-to-N, hash-seeded jitter); classic parity within ±4/255 at convergence; ≤0.3 ms p50 trace.
- [ ] M4 — Subpixel AA (per-R/G/B winding) + user-configurable layout (RGB stripe default, custom JSON for OLED); overlapping sample quads; fringing test artifact.
- [ ] M5 — Feature parity (box-drawing grid-pinned, wide/CJK/ZWJ, decorations, overlays, image quads, sidebar, preedit); `VectorGlyphParityTests` suite; `HeadlessDebugRuntime` parity + `/debug/screenshot`; release timing matrix; `testVectorGlyphSwitchPreservesActiveSessionIdentity` in `RendererModeSettingsTests`; ship default-off; ADR 0022 + index entry landed.
- [ ] ADR `docs/adr/0022-vector-glyph-renderer.md` and `docs/adr/README.md` index entry landed.

## Decision Log

- Decision: follow the patent-safe "temporal accumulation + tolerance" stance,
  not the Slug algorithm.
  Rationale: Slug (Eric Lengyel, US 9,710,310, granted 2017, ~2035 term) is the
  numerical-precision SOTA but is patent-encumbered; GreenLightning and osor.io
  both omit it "due to the associated patent." Temporal accumulation makes a
  single bad intersection sample 1/512 error — imperceptible — so it is the
  correct and only patent-safe path. This is also what makes the M0 CPU oracle
  and the tolerance-banded parity tests load-bearing.
  Date/Author: 2026-06-19 / planning + research.

- Decision: ship `vectorGlyph` knowing no terminal currently ships GPU curve
  rasterization (greenfield, not catch-up).
  Rationale: Verified Ghostty (Laban's terminal core) uses a CPU-rasterized
  alpha-mask atlas (`src/font/Atlas.zig`), same as kitty/WezTerm/Alacritty and
  Laban's own `MetalGlyphAtlas`. The osor.io recipe is the 2026 SOTA for this
  technique family and is purpose-fit for a terminal's mostly-static, single-
  font, heavy-reuse workload. vello/sparse-strips solve general 2D vector
  graphics but have an open glyph-caching gap and are not production-ready.
  Date/Author: 2026-06-19 / planning + research.

- Decision: implement as a new `RendererBackend` peer, not a third mode inside
  `MetalRenderer`.
  Rationale: `MetalRenderer` already interleaves two content passes over a
  shared target/drawable lifecycle; the vector path's resources (curve buffers,
  accumulation atlas, compute rasterizer, temporal state) are disjoint. A peer
  keeps the classic path untouched and makes live switching safe via the shared
  protocol.
  Date/Author: 2026-06-19 / planning.

- Decision: do **not** gate `vectorGlyph` behind `#available(macOS 26, *)`.
  Rationale: curve rasterization uses only compute + render pipelines available
  on the full macOS deployment range; unlike `gpuDriven` it needs no macOS-26
  API. Gating it would needlessly withhold it. (Revisit if a concrete API
  requirement is discovered.)
  Date/Author: 2026-06-19 / planning.

- Decision: extract curves at runtime via `CTFontCreatePathForGlyph`, not an
  offline FreeType bake.
  Rationale: CoreText exposes live outlines for every loadable font on-device,
  so there is no offline tool, no asset format, and no rebuild step — strictly
  simpler than the article's pipeline and naturally supports user NSFontPanel
  picks and live font-size zoom.
  Date/Author: 2026-06-19 / planning.

- Decision: ship default-off, opt-in; do not change `RendererMode.defaultMode`.
  Rationale: ADR 0017's regime — a new renderer earns default-enable only with
  release timing + parity evidence. This plan delivers opt-in quality; the
  default-enable decision is deferred to a later evidence-gated plan.
  Date/Author: 2026-06-19 / planning.

- Decision: pin box-drawing / block-element glyphs to a (0,0) subpixel key and
  rounded cell size.
  Rationale: these must align to the cell grid (a half-pixel-shifted box-drawing
  border is visibly broken), and the article's own monospaced-editor
  optimization applies cleanly. This also maximizes atlas reuse for them.
  Date/Author: 2026-06-19 / planning.

- Decision: compute coverage as `saturate(abs(W))` (sign-invariant), not
  `saturate(W)`.
  Rationale: `CTFontCreatePathForGlyph` returns Y-up em-space outlines; the
  atlas texture is Y-down. Negating y to fill the texture reverses contour
  winding and flips the sign of the winding number `W`, so `saturate(W)` would
  clamp a flipped glyph to 0 (invisible). `saturate(abs(W))` is robust to any
  orientation flip at the cost of one `abs`; temporal accumulation stores
  `sum += uint4(saturate(abs(W)), 1)`. This is the correctness invariant the
  M0/M1 parity tests pin.
  Date/Author: 2026-06-19 / review fix.

- Decision: snap the terminal cell origin and per-column x to integer device
  pixels for the general text path (the article's monospaced-editor
  pixel-align), keeping u0.8 subpixel quantization only for fractional scroll.
  Rationale: a cell at column N sits at `N×cellWidth`; if `cellWidth` is
  non-integer, every column has a distinct subpixel offset → a distinct atlas
  entry per column for the same glyph → cache thrash that would blow the M3
  ≤0.3 ms p50 gate (which silently assumes cache hits). Snapping the content
  origin and column x to integer device pixels makes every column share one
  atlas entry per glyph+size, exactly like the box-drawing pin but for all
  text. Fractional scroll (pixel-smooth scrollback) temporarily uses the
  quantized subpixel key; on scroll-stop the snap re-applies and the working
  set collapses back. This is load-bearing for the perf claim and must be
  implemented by M2, not deferred.
  Date/Author: 2026-06-19 / review fix.

- Decision: atlas grows in power-of-two dimensions up to the device maximum,
  with LRU eviction and a `classic` fallback — never silent glyph drops.
  Rationale: a terminal's working set (scrollback variety, CJK, font-zoom-
  generated quantized sizes, per-subpixel-offset keys) blows past a small fixed
  atlas fast. The atlas starts at a power-of-two size and doubles on pressure
  up to the device max (e.g. 8192²; query `MTLDevice.maxTextureLength`). Each
  atlas entry tracks last-used-frame. When a glyph needs a slot and no aligned
  contiguous run is free: evict least-recently-used entries large enough to
  satisfy the request, clear their accum regions to 0, free their bits, and
  re-seed the new glyph from sample 0. If the texture is at device max and
  eviction still cannot free enough, that frame falls back to `classic` with a
  `fallbackReason` (mirroring the M5 remote/laband fallback model) — never
  crash, never drop a glyph silently. Because temporal accumulation means an
  evicted-then-readded glyph must re-seed, hot-glyph eviction is costly; LRU +
  terminal locality (visible screen ≈ thousands of cells but unique
  glyph+size entries ≈ low hundreds) keeps it rare. The 16×16 base slot is the
  minimum allocation unit, not the atlas extent.
  Date/Author: 2026-06-19 / review fix.

## Surprises & Discoveries

(To be filled as implementation proceeds — e.g. Metal compute precision
quirks, `CTFontCreatePathForGlyph` differences across fonts, Apple-GPU wave
width vs the article's 16-thread assumption, accumulation-buffer format
choices.)

## Review Gate

Review status: NOT REVIEWED

A fresh review agent must confirm, against the commit SHA under review:

- [ ] `rg "vectorGlyph" Sources/LabanRenderer/RendererMode.swift
     Sources/LabanApp/RendererModeMenuController.swift` shows the new case
     wired into both the persisted enum and the menu, and
     `RendererMode.defaultMode` still returns `.gpuDriven ?? .classic` (i.e.
     default unchanged). Expect `defaultMode` to **not** mention `vectorGlyph`.
- [ ] `rg "encodeContentPass|encodeGPUCellContentPass"
     Sources/LabanRenderer/MetalRenderer.swift` shows the classic/gpuDriven
     dispatch is unchanged in substance. Run `git diff` on
     `Sources/LabanRenderer/MetalRenderer.swift` and confirm no behavioral edit
     to the two existing content passes.
- [ ] `rg "Shaders.metal" Sources/LabanRenderer/` — `Shaders.metal` is
     untouched; the vector shaders live in a separate `VectorGlyphShaders.metal`.
- [ ] `swift test --filter VectorGlyphParityTests` exits 0 and leaves no
     `*.diff.png` under `.build/vector-glyph-parity/`.
- [ ] `swift test --filter RendererModeSettingsTests` exits 0, including the
     new `testVectorGlyphSwitchPreservesActiveSessionIdentity`.
- [ ] `./scripts/build-app` exits 0; `rg "Vector Glyph Renderer"` on the
     installed `~/Laban.app` bundle resources finds the menu title string.
- [ ] `docs/adr/0022-vector-glyph-renderer.md` exists and `docs/adr/README.md`
     contains a one-line entry for it.
- [ ] `RendererMode.defaultMode` and `RendererMode.gpuDriven.isAvailableOnCurrentOS`
     behavior for `classic`/`gpuDriven` is unchanged (regression: run
     `swift test --filter GPUCellParityTests` —
     `testRendererModeDefaultsToGPUDrivenWhereAvailableAndGatesAvailability`
     at `Tests/LabanRendererTests/GPUCellParityTests.swift:22` must pass; there
     is no `RendererModeTests`).
- [ ] `GET /debug/render` returns `configuredRenderer: "vectorGlyph"`,
     `effectiveRenderer: "vectorGlyph"` when selected (asserted headless by
     `testRuntimeRenderStateReportsRendererStatus` in
     `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`); there is no
     `/debug/renderer-status` route — do not invent one.

Review findings:

_(filled in by the review agent)_
