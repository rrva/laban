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
  family. With Slug now patent-free, the choice between "Slug per-pixel in the
  pixel shader, every frame" and "winding-number-into-a-resident-accumulation-
  atlas" is purely an **architecture-fit** call: Slug recomputes exact coverage
  from curves for every covered pixel on every frame with no caching, whereas a
  terminal redraws the *same* glyphs across many static frames, so a resident
  atlas that amortizes rasterization to near-zero per-frame cost and accumulates
  subpixel AA over time fits the workload better. See the Decision Log for the
  full legal / architecture / complexity / terminal-constraint breakdown.
- **No terminal ships GPU curve rasterization today.** Verified: Ghostty (which
  Laban already uses via `libghostty-vt`) rasterizes glyphs on the CPU
  (`src/font/Atlas.zig`, `SharedGrid.zig`) and uploads an alpha-mask texture —
  the same model as Laban's `MetalGlyphAtlas`. kitty/WezTerm/Alacritty are the
  same family. So `vectorGlyph` is greenfield in the terminal space, not
  catch-up.
- **The Slug algorithm (Eric Lengyel) is the numerical-precision SOTA and is no
  longer patent-encumbered.** Slug evaluates exact inside/outside per pixel
  directly from Bézier control points in the pixel shader, with proven
  floating-point robustness — no atlas, no precomputed coverage. It was covered
  by **US Patent 10,373,352** (granted 2019; nominal term to ~2038), which is
  historically why osor.io and GreenLightning omit it. **That legal constraint
  is gone:** on **2026-03-17** Lengyel dedicated the patent to the public domain
  via a USPTO terminal disclaimer (form SB/43) and published MIT-licensed
  reference vertex/pixel shaders (primary source: Eric Lengyel, *A Decade of
  Slug*, <https://terathon.com/blog/decade-slug.html>; corroborated by Hackaday,
  2026-03-20). So Slug is now freely implementable without a license, and its
  reference shaders are **prior art worth studying** — especially for the
  floating-point root-classification robustness that the per-texel kernel below
  handles with tolerance instead. The earlier "~2035 / US 9,710,310" framing in
  prior drafts of this plan was wrong on the patent number, grant year, and term
  and has been removed. Laban still chooses the osor.io resident-atlas +
  temporal-accumulation route **as the first implementation** — but for
  **architecture-fit / terminal-workload** reasons (see "Architecture decision:
  osor-style first, Slug-informed" and the Decision Log), **not** any legal one.
  Slug remains the natural candidate for a *future* **direct-vector** renderer (a
  v2 path) once the atlas backend's selection, debug/capture, and fallback
  surfaces are stable.
- **No Metal reference implementation exists.** osor.io's author (Rubén Osorio)
  publishes only Jai helper modules on Codeberg (including `osor_vulkan`); the
  article's renderer is Vulkan/D3D12-HLSL on a 9070 (Windows), not Metal. The
  MSL compute shader is written from scratch by translating the HLSL winding-
  number kernel. There is no code to copy.
- **The other SOTA contender is Linebender's GPU-compute 2D path rendering**
  (vello / vello_hybrid, Rust + wgpu, Metal-supported). These solve *general* 2D
  vector graphics via prefix-sum parallelization. Status as of the Linebender Q1
  2026 update (<https://linebender.org/blog/tmil-25/>): the main Vello crate is
  still labeled **alpha** and Vello Hybrid roughly **beta**; glyph caching has
  moved from planning into early implementation — a "first cut" landed, with
  `render_to_atlas`/`write_to_atlas` APIs and a shared `Glifo` outline crate
  (vello issue #204) — but upstream describes it as still maturing. The takeaway
  is unchanged but should be read as an **architecture-fit / maturity** judgment,
  not a claim that Vello "cannot" do this: for a terminal's specific workload
  (monospaced, mostly-static, single-font, heavy reuse) the
  winding-number-per-texel-into-a-resident-atlas approach is simpler, lower-risk,
  and purpose-fit, and Vello's still-maturing glyph cache is exactly the property
  osor.io's temporal-accumulation atlas already provides. Re-verify Vello's state
  before citing it as a reason; do not assert "not production-ready" as a fixed
  fact.

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

## Architecture decision: osor-style first, Slug-informed

**Decision: osor-style first, Slug-informed.** Laban's first vector glyph
renderer is an osor-inspired runtime outline rasterizer into a glyph atlas. The
decision rests on **architectural fit** with Laban's current renderer/backend
model, **not** on Slug patent avoidance (Slug is patent-free as of 2026-03-17;
see Research / SOTA). Slug is treated as **viable prior art** — a source of
robustness ideas, shader/data-layout lessons, correctness test cases, and a
plausible long-term *direct-vector* renderer — rather than the first integration
target.

Why osor-style is the better *first* fit for Laban (integration reasons):

- Laban already has backend selection, Metal rendering, a software fallback, and
  glyph-**atlas**-oriented rendering assumptions throughout the draw path.
- A vector-to-atlas path changes only **glyph production** (how the atlas cell is
  filled) while preserving the existing draw / composite / presentation model,
  the `[FrameCommand]` contract, and the capture/debug plumbing.
- Terminal workloads reuse the same glyphs heavily, so atlas caching plus
  temporal refinement is a natural fit and amortizes cost to ~0 per frame.
- It is **lower integration risk** than a direct vector renderer: incremental,
  reversible, and selectable beside the shipping backends.

What this decision does **not** claim:

- It does **not** claim osor is better because Slug is legally unavailable — Slug
  is available; the choice is architectural.
- It does **not** claim osor is the best renderer in isolation — Slug-style direct
  rendering may be technically superior on quality/atlas-pressure grounds.
- It does **not** claim osor can be copied blindly — it still needs explicit
  contour metadata, glyph fallback, accumulation math, and headless/debug work
  (see "Caveats the osor-first decision does not remove").

### Option comparison

| Option | Strength | Weakness | Decision |
|---|---|---|---|
| **osor-style vector-to-atlas** | Best incremental fit with Laban's current renderer and atlas model; good terminal glyph reuse; easier rollout | Needs careful contour metadata, accumulation math, cold-glyph quality, fallback handling | **First implementation** |
| **Slug-style direct vector renderer** | Strong long-term quality model; avoids some atlas pressure; robust text-specific algorithm; now patent-free | Larger architecture shift; more complex shader/data model; harder initial integration (headless/debug/capture, fallback reporting) | Study / reference; possible v2 |
| **Vello / vello_hybrid** | Mature general-2D direction; active ecosystem | Rust/wgpu-oriented; heavy integration for a Swift/Metal terminal; not a focused terminal-glyph solution; glyph cache still maturing | Not the first path |
| **CoreText raster atlas only** (today's `classic`/software) | Stable, shipped baseline | Does not advance the scalable/vector-glyph quality goal | Keep as fallback / baseline |

### Recommended path ranking (effort-to-impact)

1. **osor-inspired vector-to-atlas, Slug-informed** — first implementation (this
   plan).
2. **Slug-style direct vector renderer** — possible future research / v2 path,
   revisited only after backend selection, debug/capture, fallback reporting, and
   the atlas/vector test suites are stable.
3. **Vello integration** — not suitable as the first Swift/Metal terminal-specific
   integration.
4. **Existing CoreText raster atlas only** — fallback / baseline, retained
   unchanged.

### Why Slug is not the first target (and stays relevant)

Slug-style direct vector rendering may be technically superior in isolation —
especially for immediate high-quality glyph rendering and avoiding atlas pressure
— but it is a larger departure from Laban's current atlas/backend architecture:
direct curve rendering rather than atlas-first integration, more shader/data
complexity, harder headless/debug/capture integration, and a less incremental
migration from the current code. For the first implementation Laban uses Slug as
a **reference** for curve handling, floating-point robustness, test cases, and
possible future renderer design — not as the initial integration strategy. A
direct Slug-style backend remains a credible **v2** once the osor backend's
selection/debug/fallback surfaces have proven out.

### Caveats the osor-first decision does not remove

Choosing osor-style first does **not** waive any of the review fixes already in
this plan. They remain hard requirements:

- Store contour/subpath metadata explicitly; one seed/start point **per contour**,
  not per glyph; defined close-subpath and winding/fill-rule behavior
  (see "Curves and contours").
- Exact accumulation texture format and normalization math, with the
  **binary-vs-fractional** coverage question stated explicitly (see item 6).
- Acceptable cold-glyph quality before temporal refinement converges (item 6 /
  M3).
- Glyph fallback for clusters without usable outlines — nil
  `CTFontCreatePathForGlyph`, bitmap glyphs, color emoji, ZWJ clusters, complex
  CTLine fallback, missing glyphs, styled fallback fonts (see "Glyph fallback").
- Strict vector-geometry tests split from looser CoreText visual parity; no exact
  CoreText pixel equality for unhinted vector output (see "Test thresholds").
- Headless/debug screenshots treated as explicit work, not automatic
  (see "Headless / debug vector support").
- Report requested renderer, effective renderer, fallback reason, and per-glyph
  fallback occurrence where practical (see "Fallback cascade and status").

## Reference summary of the osor.io technique

Embedding the essential method here so the plan is self-contained (per
`PLANS.md`: do not outsource to external blogs). Cross-check the SOTA notes
above: every item here matches the established method.

1. **Curves and contours.** A glyph outline is **one or more closed contours**
   (subpaths). `O` has two (outer ring + inner hole), `i` has two disjoint
   contours (stem + tittle), `%` has several (two rings + the slash), `8`/`B`
   have nested holes, and a combining mark like a standalone acute is its own
   disconnected contour. Each contour is a sequence of segments: lines,
   quadratic Béziers (3 points), and cubic Béziers (4 points). Lines become
   quadratics by inserting a midpoint. Cubics are split into **two** quadratics:
   given cubic `p0,p1,p2,p3`, compute `c0 = lerp(p0,p1,0.75)`,
   `c1 = lerp(p3,p2,0.75)`, `m = lerp(c0,c1,0.5)`, then emit `p0,c0,m` and
   `m,c1,p3`.

   **Storage (contour-aware — endpoints are shared only *within* a contour,
   never across one).** After conversion a glyph is:
   - a flat `quadCurves: [float2 × 3]` (or the share-endpoint packing: a seed
     point per contour + 2 points per curve), **plus**
   - a `contours: [(curveStart: UInt32, curveCount: UInt32)]` index that records
     where each contour's curves begin and end. Each contour carries **its own
     seed/start point**; the previous "1 seed per glyph" packing is wrong because
     it would chain the last curve of one contour into the first curve of the
     next, fusing the outer ring and the hole into a single bogus path.
   - **Close-subpath:** each contour is explicitly closed. Walking the `CGPath`,
     `.moveToPoint` starts a new contour (record its seed); `.closeSubpath`
     closes back to that seed. If a contour's last point ≠ its seed and no
     explicit close was emitted, synthesize a closing line→quadratic from the
     last point back to the seed (CoreText glyph outlines are normally closed,
     but be defensive).
   - **Winding / fill rule:** TrueType/CFF use the **nonzero** winding rule with
     outer contours and holes wound in *opposite* directions. The kernel (item 2)
     sums a single net winding number `W` over the curves of **all** contours,
     then takes coverage from `|W|` — so a point in a hole gets `outer(±1) +
     inner(∓1) = 0` and reads empty, while a point in the solid ring gets `±1`
     and reads filled. **Take `abs` of the summed net `W`, not the sum of
     per-curve `abs`** — otherwise holes fill in. Contour orientations from
     CoreText must be preserved as-is; do **not** re-orient contours to a common
     winding (that destroys holes). The global Y-flip (item 2's trap) reverses
     *every* contour's orientation together, so relative orientation — and thus
     hole behavior — is preserved; only the global sign of `W` flips, which
     `abs` absorbs.

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
   - **(a) Sign-invariant coverage:** compute `cov = saturate(abs(W))` (a
     *fractional* value in `[0,1]`) per sample, quantize it to fixed point
     (`covFixed = uint(round(cov * 65535))`), and accumulate
     `sum += uint4(covFixed_r, covFixed_g, covFixed_b, 1)` into the
     `rgba32Uint` accum buffer. Robust to any orientation flip; costs one `abs`.
     **Note the scale:** `cov` is fractional, so it must be multiplied by 65535
     *before* the `uint` cast — `uint(saturate(cov))` alone would truncate every
     partial-coverage sample to 0 or 1 and destroy anti-aliasing. The exact
     format, scale, and normalization are specified in item 6.
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

5. **Atlas key.** `(kind, font, glyphIndex, quantizedSizeX, quantizedSizeY,
   quantizedSubpixelOffsetX, quantizedSubpixelOffsetY, bold, italic,
   syntheticBold, syntheticItalic)`. `kind ∈ {vector, raster}` keeps the vector
   atlas and the raster-fallback atlas in disjoint namespaces (see "Glyph
   fallback"); the style flags mirror the existing `MetalGlyphAtlas` key so
   synthesized bold/italic does not alias the regular weight (see "Synthetic
   bold / italic"). Size is u24.8 fixed point; subpixel offset is u0.8. Fixed
   point collapses near-identical floats that would otherwise miss the cache.
   Monospaced editors can additionally round advances to pixel boundaries so the
   same glyph in every column/row hits one atlas entry.

6. **Temporal accumulation (accumulation format pinned).** A newly seen glyph
   gets many samples its first frame (e.g. 8), then fewer (4, 2, 1) until a
   sample cap of **512**. Static text converges for free; moving/resizing glyphs
   re-seed. Sample jitter uses a quasirandom $R_2$ sequence (Martin Roberts),
   seeded from the glyph's atlas-key hash so it is deterministic. A single bad
   intersection sample is `1/512` of the final weight — imperceptible.

   The accumulation buffer's format is **load-bearing** and is fixed here so the
   pseudocode is unambiguous and implementable:

   - **Texture format:** `MTLPixelFormat.rgba32Uint` — four unsigned 32-bit
     integer channels per texel, holding `(sumR, sumG, sumB, count)`. The
     three colour channels carry the per-R/G/B-subpixel coverage sums (item 7);
     in the pre-subpixel milestones (M1–M3) all three hold the same single
     coverage value, and `count` (the `.a` channel) holds the number of samples
     accumulated so far.
   - **Coverage representation:** **fixed point**, not float. Per-sample coverage
     `cov ∈ [0,1]` is quantized as `covFixed = round(cov * COV_SCALE)` with
     **`COV_SCALE = 65535`** (u16 range stored inside the u32 accumulator).
     Fixed-point integer accumulation is **exactly associative and commutative**,
     so the converged value is independent of GPU thread/frame scheduling — this
     is what makes the parity and headless gates byte-reproducible. (A
     `rgba32Float` accumulator would be ~equally precise but float addition is
     non-associative, so two runs could differ in the low bits; rejected for
     determinism, not precision.)
   - **Coverage model — FRACTIONAL, not binary (stated explicitly).** Each sample
     contributes a *fractional* coverage in `[0,1]`, not a binary inside/outside
     0/1. The fractional value comes from the pixel-window AA rule (item 2): a
     curve intersection within one pixel-width of the ray contributes a fractional
     weight, so `cov = saturate(abs(W))` is a *windowed* winding value in `[0,1]`,
     not the integer winding count. This is why the fixed-point `round(cov*65535)`
     quantization is required. **Integer 0/1 accumulation would be valid only for
     pure binary point sampling** (accumulate inside-count, divide by total
     count); Laban does **not** use that model — binary point sampling needs far
     more samples to reach the same edge quality and produces noisier cold
     glyphs. If a future milestone switches to binary point sampling, the format
     must be re-stated (a plain count buffer) — the two models are not
     interchangeable under the same normalization.
   - **Per-frame update (plain read-modify-write, no atomics):** each texel is
     written by exactly one thread per frame, and frames are serialized, so
     `sum.rgb += uint3(round(covRGB * 65535)); sum.a += sampleCountThisFrame`.
   - **Normalization (resolve to alpha):** the sampled coverage for channel `c`
     is `alpha_c = float(sum.c) / (float(sum.a) * 65535.0)`, giving a value in
     `[0,1]`. The resolve pass writes the R8/sRGB alpha (or three subpixel
     alphas) the content pass samples.
   - **Overflow proof:** the maximum any colour channel can reach is
     `count_max * COV_SCALE = 512 * 65535 = 33,553,920`, which is `< 2^32 − 1 =
     4,294,967,295` by a factor of ~128. So **u32 cannot overflow at the 512
     sample cap** (nor at 256). The headroom permits up to
     `floor((2^32 − 1) / 65535) = 65537` samples before overflow, far above any
     schedule used here. `count` itself maxes at 512, trivially within u32.
   - **Convergence:** a glyph is treated as **converged** once `count` reaches
     the 512 cap; tests and headless captures read the atlas only at a fixed
     sample index where every resident glyph has `count ≥ 256` (see M3's
     determinism protocol), never mid-convergence against a wall clock.
   - **Cold glyphs (must be legible at frame 1, before convergence).** A
     freshly-seeded glyph has only its first-frame budget (8 samples), which is
     enough to read but visibly less smooth than the converged result. The
     first-frame burst (8) and the front-loaded 8/4/2/1 schedule exist precisely
     so a newly-typed/scrolled-in glyph is immediately acceptable. To avoid
     first-frame stochastic noise, the **initial burst uses a fixed low-
     discrepancy sample set** (the first N points of the $R_2$ sequence, which are
     deterministic and well-distributed) rather than random jitter, so a cold
     glyph is smooth-but-slightly-soft, not speckled. The cold→converged delta is
     captured as an M3 artifact (first-frame vs converged screenshot pair).

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
- `Sources/LabanRenderer/RendererMode.swift` — the **Metal-internal** mode enum
  (`classic`, `gpuDriven`) that `MetalRenderer` consumes to pick a content pass.
  **It is left unchanged — `vectorGlyph` is NOT added here.** `RendererMode`'s
  whole domain is "which Metal content pass does `MetalRenderer` run", and
  `MetalRenderer.effectiveRendererMode` (`MetalRenderer.swift:642`) forces any
  non-`gpuDriven` value to `.classic`. The vector renderer is a *separate
  backend*, not a Metal mode, so giving it a `RendererMode` case would create a
  value that is invalid everywhere `RendererMode` is consumed (see
  "Backend selection vs Metal mode" below and Decision Log). Keeping
  `RendererMode` to `{classic, gpuDriven}` means it is impossible to route a
  vector selection into `MetalRenderer` by mistake. `defaultMode` stays
  `.gpuDriven ?? .classic`.
- `Sources/LabanRenderer/MetalRenderer.swift` — owns the `CAMetalLayer`, the
  persistent target texture, the drawable scheduler, theme reconciliation, and
  the `classic`/`gpuDriven` content-pass dispatch (`encodeContentPass` vs
  `encodeGPUCellContentPass`). ~3600 lines; the new renderer does **not** grow
  this file. It reuses `MetalDrawableScheduler`, `ThemeData` (the renderer's
  theme value type, `Sources/LabanRenderer/Theme.swift`), `FontAtlas` metrics,
  and the `[FrameCommand]`/`TerminalCellPayload` producers as-is.
- `Sources/LabanApp/RendererModeMenuController.swift` — the AppKit View ▸
  Renderer menu. The `RendererSelection` enum currently *lives in this file*
  (`software`/`classic`/`gpuDriven`), but it is a pure Foundation enum with no
  AppKit dependency, so M2 **moves it down to `LabanRenderer`** (new file
  `Sources/LabanRenderer/RendererSelection.swift`) and adds the `vectorGlyph`
  case there. The menu controller and `SettingsWindowController` keep building
  the AppKit UI in `LabanApp` but now reference the lower-level type. This is the
  load-bearing move that lets `LabanDebug` (which must not import `LabanApp`)
  share the same selection type and backend factory — see "Backend selection vs
  Metal mode" and "Headless renderer selection".
- `Sources/LabanRenderer/Shaders.metal` — the classic/gpuDriven shaders. The
  vector renderer gets its **own** `.metal` file (`VectorGlyphShaders.metal`).
  **Bundling is not automatic:** `Package.swift` only `.process("Shaders.metal")`
  today (`Package.swift:49`), and the loader reads that one file by name and
  compiles it from source at startup (~1 ms, `MetalRenderer.swift:668`). So M2
  must (a) add `.process("VectorGlyphShaders.metal")` to the `LabanRenderer`
  target's `resources` in `Package.swift`, and (b) give `VectorGlyphRenderer`
  its own loader that reads `"VectorGlyphShaders".metal` from
  `LabanRendererResources.bundle` and compiles a separate `MTLLibrary`. SwiftPM
  does not pre-compile `.metal` to `.metallib`; both files ship as source in
  the bundle. The Review Gate proves the new file is bundled and compiled.
  The vector renderer does not edit the existing shaders.
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

### Backend selection vs Metal mode, factory, and status wiring (load-bearing — not free)

Two distinct concepts must not be conflated (this is the root of several earlier
plan errors):

- **`RendererMode`** (`Sources/LabanRenderer/RendererMode.swift`): a
  *Metal-internal* enum `{classic, gpuDriven}` — "which content pass does
  `MetalRenderer` run". `vectorGlyph` is **not** one of these and is never added
  here.
- **`RendererSelection`** (today `Sources/LabanApp/RendererModeMenuController.swift`,
  moved to `Sources/LabanRenderer/RendererSelection.swift` in M2): the
  *requested backend* enum `{software, classic, gpuDriven}` → gains
  `vectorGlyph`. Its `metalMode: RendererMode?` returns `nil` for both
  `.software` **and** `.vectorGlyph` (those are not Metal modes), and `.classic`
  /`.gpuDriven` for the two Metal modes. Because `.vectorGlyph.metalMode == nil`,
  it is *structurally impossible* to hand a vector selection to `MetalRenderer`
  (which only accepts a `RendererMode`) — the illegal routing the current
  `effectiveRendererMode` collapse (`MetalRenderer.swift:642`, forces
  non-`gpuDriven` → `.classic`) would otherwise hide is unrepresentable.

**A shared backend factory in `LabanRenderer`.** Today the only factory is
`TerminalBitmapView.makeBackend` (`Sources/LabanApp/TerminalBitmapView.swift:825`),
which is `private static` and lives in `LabanApp`. `LabanDebug` **cannot** call
it (it must not depend on `LabanApp`), and `RendererSelection` is not visible to
`LabanDebug` either. This is not merely a convention: `LabanApp` already depends
on `LabanDebug` in `Package.swift`, so a `LabanDebug → LabanApp` edge would be a
dependency **cycle SwiftPM rejects at build time** — the illegal direction is
structurally impossible, not just discouraged. The legal direction is to put the
shared type and factory in `LabanRenderer` (the lowest target, which both
`LabanApp` and `LabanDebug` already depend on). So M2 introduces:

```
// LabanRenderer (visible to both LabanApp and LabanDebug)
public func makeRendererBackend(
  selection: RendererSelection,
  fontAtlas: FontAtlas,
  sidebarFontAtlas: FontAtlas,
  // …pixel size/scale for software, as makeBackend already threads…
) -> RendererBackend
```

It encapsulates the routing **and the fallback cascade** (next section), stamping
the returned backend's `rendererStatus` (`configuredRenderer` = the requested
`selection`, plus any `fallbackReason`). `TerminalBitmapView.makeBackend` becomes
a thin caller of this (or is replaced by it); `HeadlessDebugRuntime` calls the
same function. There is exactly one place that knows how a selection maps to a
backend.

The required edits (all M2; the Review Gate checks them mechanically):

- **Move `RendererSelection` to `LabanRenderer`** and add `.vectorGlyph`
  (`metalMode == nil`, `isAvailableOnCurrentOS == true` unconditionally — curve
  rasterization needs no macOS-26 API). `RendererMode` is untouched.
- **`makeRendererBackend` (LabanRenderer):** `switch selection` with explicit
  cases (no `default`, so a future selection can't silently fall through):
  `.software` → `SoftwareBackend`; `.classic`/`.gpuDriven` → `MetalRenderer(…,
  rendererMode: selection.metalMode!)` with the no-device cascade below;
  `.vectorGlyph` → `VectorGlyphRenderer(…)` with its cascade.
- **`TerminalBitmapView` accessors** (`rendererMode`/`rendererSelection`,
  `TerminalBitmapView.swift:867`/`:874`): currently
  `guard let metal = backend as? MetalRenderer else { return .classic/.software }`,
  which would **mislabel `VectorGlyphRenderer` as software/classic**. Fix by
  reading identity from the backend's `rendererStatus` (preferred — protocol-level,
  no `as?` sniffing) and/or adding a `backend as? VectorGlyphRenderer` arm
  returning `.vectorGlyph`. See "Backend identity / labeling".
- **`TerminalBitmapView.installFrameCompletionHook`
  (`TerminalBitmapView.swift:854`):** currently `guard let metal = backend as?
  MetalRenderer else { return }`. The vector path needs its own frame-completion
  callback (GPU freeze detector + input-latency recording) — promote it to a
  `RendererBackend` protocol requirement (e.g. `var onFrameCompleted: (() ->
  Void)? { get set }`) so both Metal and vector wire it without `as?` arms.
  Decide in M2 and record in the Decision Log.
- **`TerminalBitmapView.applyFontSize` (`TerminalBitmapView.swift:3479`):** today
  it `reconfigureFonts` on a `MetalRenderer` but **replaces any other backend
  with a fresh `SoftwareBackend`**. As written this would **silently drop the
  vector renderer to software on every font-zoom**. M2 must add a vector branch:
  either `VectorGlyphRenderer.reconfigureFonts(…)` (preferred — keeps the atlas
  warm) or rebuild via `makeRendererBackend(selection: .vectorGlyph, …)`. After
  zoom, `rendererSelection` must still report `.vectorGlyph` (the M5/UI test
  pins this). The general text path also re-snaps cell origin/column-x to integer
  device pixels here (see the pixel-align Decision) so the working set collapses
  back to one atlas entry per glyph+size.
- **Live switching:** `RendererModeMenuController.applySelection` already rebuilds
  the backend on selection change; verify `VectorGlyphRenderer` is constructed
  and that switching classic↔vectorGlyph preserves the `AppModel`, active tab id,
  and `Session` (M5 session-identity test).

### Fallback cascade and status (corrected semantics)

There is no "fall back to classic when Metal is unavailable" — **classic is
itself a Metal renderer**, so it cannot be the fallback when there is no Metal
device. The corrected model has four distinct outcomes, each reported through the
existing `RendererStatus { configuredRenderer, effectiveRenderer, fallbackReason }`:

1. **No Metal device at all** (`MTLCreateSystemDefaultDevice()` is nil, so both
   `MetalRenderer.init?` and `VectorGlyphRenderer.init?` return nil): effective
   backend is **software**. `makeRendererBackend` returns `SoftwareBackend` with
   `configuredRenderer = selection`, `effectiveRenderer = "software"`,
   `fallbackReason = "noMetalDevice"`. (This already happens for classic/gpuDriven
   in `makeBackend` today — the recovery target is software, never classic.)
2. **Metal device present but the vector pipeline/resource compilation fails**
   (`VectorGlyphRenderer.init?` returns nil though a device exists): fall back to
   **classic Metal**. `configuredRenderer = "vectorGlyph"`, `effectiveRenderer =
   "classic"`, `fallbackReason = "vectorPipelineUnavailable"`. The factory builds
   a `MetalRenderer(rendererMode: .classic)` and stamps these fields.
3. **Vector active but a specific glyph/cluster has no usable outline**
   (per-glyph): that glyph falls back to the **raster/classic atlas** path for
   that cell only (see "Glyph fallback"), while the rest of the screen stays
   vector. This is reported as an aggregate `rasterFallbackGlyphs` count in debug
   status, **not** a whole-renderer fallback (`effectiveRenderer` stays
   `"vectorGlyph"`).
4. **Vector active, everything supported:** `configuredRenderer =
   effectiveRenderer = "vectorGlyph"`, `fallbackReason = nil`.

`requested renderer` (= `configuredRenderer`), `effective renderer`, `fallback
reason`, and `backend capability` (does this device support the requested
backend at all) are therefore four separate facts; the plan and the debug status
must keep them separate and never report `"classic"` when there is no Metal
device.

### Backend identity / labeling (don't call vector "software")

Capture recording, `GET /debug/render`, screenshots, and the menu/Settings UI
currently infer the renderer by `backend as? MetalRenderer` (anything else =
"software"/"classic"). With a third Metal-family backend that is **not** a
`MetalRenderer` subclass, that inference mislabels vector as software. The fix is
to source the label from the protocol: `RendererBackend.rendererStatus`
(`effectiveRenderer`/`configuredRenderer`) already exists in `LabanRenderer` and
is the single identity of record. `SoftwareBackend` reports `"software"`,
`MetalRenderer` reports `"classic"`/`"gpuDriven"`, `VectorGlyphRenderer` reports
`"vectorGlyph"`. Every label site (UI accessors, capture metadata, debug render
state) reads `rendererStatus` rather than type-sniffing, so all four backends —
software, classic Metal, gpu-driven Metal, vector — are distinguishable.

### Headless / debug vector support (explicit work — NOT free)

AGENTS.md's hard rule: `HeadlessDebugRuntime` stays in feature parity with
`MainWindowController.makeAndShow`. But headless vector support is **not** a
free consequence of selecting the backend — the current headless/debug stack is
tightly coupled to `BitmapSurface` + `SoftwareRenderer` and bypasses the
`RendererBackend` protocol entirely. Concretely, today:

- `HeadlessDebugRuntime` owns `surface: BitmapSurface` and `renderer:
  SoftwareRenderer` as concrete fields and constructs them directly
  (`HeadlessDebugRuntime.swift`); it holds no `RendererBackend`.
- `DebugScreenshotEndpoints.screenshotBytes()`/`writeScreenshotArtifact()` read
  pixels from `surface.pngData` (concrete `BitmapSurface`), **not** from
  `RendererBackend.presentationImage`/`pngData`.
- `DebugRenderEndpoints.renderState()` hard-codes `backend = configuredRenderer =
  effectiveRenderer = "software"`, `fallbackReason = nil`.
- `DebugWindowActions.resizeWindow()`/`setFontSize()` and
  `DebugFixtureEndpoints` rebuild a `SoftwareRenderer`/`BitmapSurface` on every
  resize and font-size change.

A Metal-family backend (classic, gpuDriven, vector) renders into an `MTLTexture`,
not a CPU `BitmapSurface`, and headless has no on-screen drawable. So making
vector output observable in debug screenshots is real, scoped work. The design:

- **Hold a `RendererBackend`, not a `SoftwareRenderer`.** Give
  `HeadlessDebugRuntime` a `rendererSelection: RendererSelection` parameter
  (default `.software`, so every existing test/fixture stays byte-identical) and
  build the backend via the shared `makeRendererBackend(...)` in `LabanRenderer`
  — the *same* factory the live view uses. The runtime keeps a `RendererBackend`
  reference and routes frames through the protocol.
- **Offscreen Metal rendering + readback.** `VectorGlyphRenderer` (and
  `MetalRenderer`, for headless classic/gpuDriven) must support an **offscreen
  render target**: render into an `MTLTexture` with no `CAMetalLayer` drawable,
  then expose `presentationImage`/`pngData` by blitting/reading that texture back
  to a `CGImage`. Two integration options for the screenshot endpoints, pick one
  in M2 and record it:
  - **(a) Read from the backend protocol:** change `screenshotBytes()` to read
    `activeBackend.pngData` (which `SoftwareBackend` already satisfies via its
    `BitmapSurface`). Cleanest long-term; touches the screenshot endpoints.
  - **(b) Mirror into `BitmapSurface`:** after an offscreen vector frame, copy
    the read-back pixels into the existing `surface` so `surface.pngData` keeps
    working unchanged. Smaller blast radius; keeps a CPU copy around.
- **`renderState()` reads `rendererStatus`.** Replace the hard-coded `"software"`
  literals with the live backend's `RendererStatus`
  (`configuredRenderer`/`effectiveRenderer`/`fallbackReason`). `RendererBackend`
  already exposes `rendererStatus` in `LabanRenderer`.
- **Resize / font-size / fixtures** (`DebugWindowActions`,
  `DebugFixtureEndpoints`) rebuild through `makeRendererBackend(selection:…)`
  with the runtime's current selection instead of hard-coding `SoftwareRenderer`,
  so a headless vector session survives resize and font-size changes.
- **Determinism for capture:** headless vector screenshots pump to the fixed
  converged sample index (M3's protocol) before reading, so the PNG is
  byte-reproducible.

Endpoints and their initial status under vector selection (state limitations
explicitly rather than implying universal support):

| Endpoint | Vector plan |
| --- | --- |
| `GET /debug/render` | Reports backend `rendererStatus` (configured/effective/fallback). M2. |
| `GET`/`POST /debug/screenshot` | Offscreen readback or `BitmapSurface` mirror (above). M2 for ASCII, M5 E2E pins it. |
| `POST /debug/fixture`, `POST /debug/actions` (resize/window/input) | Rebuild backend via factory; reuse frame-command path. M2. |
| `POST /debug/pixel-probe` | Samples the read-back image; works once screenshot readback lands. |
| `POST /debug/render-trace` | Metal-pass-specific; the vector pass has different contributors/resources. **Software/classic-only initially**; a vector render-trace is a later, named follow-up, not an M2 deliverable. |
| `GET /debug/atlas` | Curve-backed atlas has a different shape than the R8 alpha atlas. **Reports the classic atlas initially**; vector-atlas diagnostics (resident curve slots, sample counts, `rasterFallbackGlyphs`) are an explicit later addition. |

- **Tests:** add `testRuntimeRenderStateReportsVectorGlyphRendererStatus` to
  `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`: construct
  `HeadlessDebugRuntime(rendererSelection: .vectorGlyph)` **gated on a Metal
  device being present** (skip otherwise) and assert `configuredRenderer ==
  "vectorGlyph"`, `effectiveRenderer == "vectorGlyph"`, `fallbackReason == nil`.
  When **no Metal device** is present the effective backend is **software** (not
  classic) with `fallbackReason == "noMetalDevice"` — assert that. The existing
  `testRuntimeRenderStateReportsRendererStatus` (software default) must stay
  green.

There is **no** `/debug/renderer-status` route — `GET /debug/render` is the
status payload. Do not invent a new route.

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

### Glyph fallback: not every displayed glyph has a usable outline

`CTFontCreatePathForGlyph` returns `nil` (or an empty/unusable path) for a real
fraction of terminal content, and the plan must not assume an outline always
exists. Cases to handle:

- **`nil` / empty outline paths** — return `nil` from `GlyphCurveStore`.
- **Bitmap (`sbix`) and color (`COLR`/`CBDT`) glyphs, color emoji** — Apple Color
  Emoji has no monochrome outline path; it must rasterize through the existing
  color/bitmap path.
- **ZWJ emoji clusters and complex CTLine fallback** — multi-scalar grapheme
  clusters resolved by shaping (the `TerminalCellPayload` cluster path +
  `TerminalGlyphFallback`) are not single outline glyphs.
- **Missing glyphs (`.notdef`)** — render the fallback/notdef box, not a vector
  path.
- **Ligatures** — a shaped ligature *glyph id* (e.g. `fi`) usually has a normal
  outline, so it goes through the vector path like any other glyph id; only
  clusters that never resolve to a single outline glyph use the fallback.
- **Styled fallback fonts** — when a scalar resolves to a different physical font
  (CJK, symbols), the vector path extracts that font's outline; if that font has
  no outline for the glyph, it falls back per the above.

**Design.** `GlyphCurveStore` returns an optional curve set. The renderer routes
outline glyphs to the vector atlas and everything else to the **existing
raster/classic alpha-mask atlas (`MetalGlyphAtlas`)** for that glyph/cell only —
a per-glyph fallback (cascade case 3 above), not a whole-renderer fallback.

**Atlas keying must not collide.** The vector atlas and the raster-fallback atlas
are **separate namespaces** (separate atlases, or a `kind: {vector, raster}`
discriminator in the key) so a vector `A` and a raster-fallback `A` (different
rasterizations) never alias. Debug status exposes a `rasterFallbackGlyphs` count
(or at minimum a boolean "raster fallback occurred") so the fallback is
observable.

### Synthetic bold / italic

The existing raster atlas key already carries `boldFallback` and `italicFallback`
flags (`MetalGlyphAtlas.swift`), because terminal text frequently asks for a bold
or italic style the chosen font has no real face for. The vector atlas key
**must** include the same style discriminators or styled text will silently
render at regular weight / upright. Plan:

- **Style flags in the key:** extend the vector atlas key to
  `(font, glyphIndex, quantizedSize, quantizedSubpixelOffset, bold, italic,
  syntheticBold, syntheticItalic)`. A real styled face and a synthesized one must
  key differently.
- **Real styled face available** (CoreText resolves an actual bold/italic
  `CTFont`): extract that font's outline — it is just a different `CTFont`, the
  normal vector path.
- **Fake italic:** apply a shear transform to the extracted control points (a
  skew matrix, ~0.2 slant) in `GlyphCurveStore`; cheap and exact on curves.
  Cache key sets `syntheticItalic`.
- **Fake bold:** outline emboldening (a small uniform dilation/stroke offset) is
  the eventual goal, but robust curve emboldening is non-trivial. **For the
  initial ship, synthetic bold falls back to the raster path** (which already
  emboldens) rather than mis-rendering bold as regular weight; outline
  emboldening is a named later improvement recorded in the Decision Log. Cache
  key sets `syntheticBold`.
- **Tests:** fake-bold and fake-italic behavior tests — a font with no italic
  face must produce sheared (vector) output distinct from regular; a font with no
  bold face must produce the raster-fallback emboldened output, not regular
  weight.

## Test thresholds (four classes — what is exact vs approximate)

The current classic/`gpuDriven` renderers rasterize glyphs via CoreText, so their
parity tests can demand near-exact equality. The vector renderer is **unhinted**
and rasterizes from outlines with its own kernel, so requiring tight per-pixel
equality against CoreText is unrealistic and is **not** a goal. Tests are bucketed
into four classes with explicitly different thresholds; never apply the geometry
threshold to a CoreText comparison or vice-versa:

1. **Geometry / oracle tests (exact).** Vector math against analytic or
   self-consistent ground truth: winding number on a unit square, analytic disc
   coverage, contour topology (holes/disjoint marks), cubic-split sampled
   deviation, CPU-oracle-vs-GPU-readback (same kernel both sides). Tight bands
   (±1–3/255, or exact set membership for topology). These prove the
   implementation is internally correct.
2. **Synthetic fixtures (exact-ish).** Constructed shapes with known coverage
   (e.g. solid fills, box-drawing rectangles aligned to the grid, decorations):
   **zero tolerance** where the geometry is identical to the classic path (solid
   fills, underline/strike rects, cursor/selection rects), since those are not
   glyph ink.
3. **Real-font visual comparison (perceptual).** Unhinted vector glyph ink vs
   CoreText/`classic`: a perceptual metric (mean-abs over ink + percentile within
   a band, e.g. mean-abs ≤ ~3/255 and ≥98% within ±6/255 at M0/M3), **not**
   per-pixel equality. Edge pixels differ by design. Capture diff PNGs as
   artifacts for human review.
4. **UI / layout invariants (exact).** Cursor position, cell-grid alignment,
   overlay/selection/find rectangles, sidebar layout, atlas packing offsets:
   these are geometry, not glyph alpha, and are asserted exactly (pixel-accurate
   rects / integer cell coordinates), independent of how the glyph interior is
   shaded.

## Milestones

Each milestone is independently verifiable and additive. The **behavior** of the
shipping `software`/`classic`/`gpuDriven` renderers is never modified by this
plan — their content passes and shaders are untouched throughout. What changes
incrementally is the **selection plumbing**: M2 adds the additive, default-off
opt-in entry (the moved `RendererSelection` gains `vectorGlyph`, the menu/Settings
gain an item, the factory and headless runtime learn to build it), and M5 brings
the vector backend to feature parity and runs the gate. So "shipping renderers
untouched" is a statement about their *behavior at all times*, and "exposed in the
UI" happens at *M2*, not M5. (Earlier drafts said the menu is wired only at M5,
which contradicted M2 — corrected here.)

### M0 — Curve extraction (CPU, no GPU)

Scope: a `GlyphCurveStore` that, given a `CTFont` and a glyph ID, returns the
canonical **contour-aware** quadratic-curve list (per-contour seed + curve
ranges; see "Curves and contours") or `nil` when the glyph has no usable outline
(see "Glyph fallback"). Pure Swift + CoreGraphics; no Metal.

What exists after: a tested type that turns any CoreText glyph into the exact
curve representation the GPU will consume, plus a reference CPU rasterizer
(horizontal-ray winding number, no band acceleration) used only as a test oracle.

Commands:
- `./scripts/build-app`
- `swift test --filter GlyphCurveStoreTests`

Acceptance is split into **strict geometry/oracle tests** (exact, because they
test the vector math against analytic or self-consistent ground truth) and a
**perceptual CoreText comparison** (loose, because unhinted vector outlines are
*not* expected to be pixel-equal to CoreText's rasterized — and possibly hinted —
alpha mask). See "Test thresholds" for the four threshold classes.

Strict geometry/oracle tests (these must be tight):
- **Winding-number kernel** on a synthetic unit square (4 line-segments → 4
  quadratics) asserts `|W| = 1` for an interior sample and `|W| = 0` for an
  exterior one, using the embedded kernel (coefficients `a,b,c`, root selection
  `0≤t<1` and `x(t)≥0`, t0-exit/t1-entry rule).
- **Analytic coverage** on a unit-radius circle (built from quadratics): the
  oracle's coverage matches the analytic disc area per pixel within ±1/255 — a
  ground-truth shape with no font involved.
- **Contour topology** (the holes/disconnected-marks correctness the storage fix
  protects): the oracle renders `O` (outer ring + inner hole — hole reads
  empty), `i` (two disjoint contours — stem + tittle both present, nothing
  between them), `%` (multiple contours: two rings + slash), at least one glyph
  with **nested/multiple holes** (`8` or `B`), and a **combining mark** /
  disconnected-mark case where practical (e.g. a standalone combining acute, or a
  decomposed `é` whose accent is a separate contour). Each asserts the per-pixel
  inside/outside set from the multi-contour `|net W|` matches the expected
  topology (hole interior empty, disjoint contours both filled). These would all
  fail under the old "1 seed per glyph" packing.
- **Cubic→2×quadratic split** unit test, concrete worked example (not a reference
  to the article). Given `p0=(0,0)`, `p1=(0,4)`, `p2=(4,4)`, `p3=(4,0)` (units
  are **abstract control-point units**, not em):
  - `c0 = lerp(p0,p1,0.75) = (0,3)`
  - `c1 = lerp(p3,p2,0.75) = (4,3)`
  - `m  = lerp(c0,c1,0.5) = (2,3)`
  - Output curves: `Q1 = (0,0),(0,3),(2,3)` and `Q2 = (2,3),(4,3),(4,0)`.
  The test asserts `c0`, `c1`, `m` to 1e-6 and that `Q1`'s end equals `Q2`'s
  start (`m`, i.e. C0-continuous). It does **not** assert the output quadratics
  lie exactly on the source cubic — this order-lowering is **lossy** by
  construction. Instead it asserts a bounded **sampled max deviation** (the
  maximum, over 33 sampled `t`, of the distance from the cubic point to the
  nearest point on the two output quadratics). **This is a one-directional
  sampled deviation, deliberately *not* called "Hausdorff"** — a true Hausdorff
  distance is the bidirectional nearest-point sup and is not what this test
  computes; the name is corrected here. For this worked example the test pins the
  known deviation: cubic@t=0.25 = (0.625, 2.25) vs nearest point on `Q1` ≈
  Q1@t=0.5 = (0.5, 2.25) → Δ ≈ 0.125; cubic@t=0.75 = (3.375, 2.25) vs nearest on
  `Q2` ≈ (3.5, 2.25) → Δ ≈ 0.125. The threshold for **this synthetic example** is
  `ε = 0.15` control-point units, so the observed `0.125 < 0.15` passes (the old
  text used `0.05 em` while citing a `0.125` deviation as "within epsilon", which
  is self-contradictory — fixed). The example is a deliberately sharp ~90° turn
  to keep the arithmetic legible; **real** glyph cubics curve far less per
  segment, so for actual fonts the per-split deviation is well under `0.02 em`,
  and the *visual* correctness bound is the raster parity below, not this unit
  check.

Perceptual CoreText comparison (loose — do NOT require pixel equality):
- For every printable ASCII scalar in JetBrainsMono and Menlo, the CPU reference
  rasterizer's coverage (256 samples per pixel, no subpixel) is compared to a
  CoreText alpha mask (`CTFontDrawGlyphs` into a `CGContext`). Because the vector
  output is **unhinted** and CoreText's is independently rasterized, the gate is
  **perceptual, not per-pixel exact**: mean absolute coverage difference over the
  ink bounds ≤ ~3/255 **and** ≥ 98% of ink pixels within ±6/255, with edge
  pixels expected to differ most. Test emits expected/actual/diff PNGs to a local
  temp dir on mismatch (mirror `GPUCellParityTests`). This catches gross errors
  (missing contours, flipped winding, wrong scale) without chasing impossible
  CoreText equality.

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
Z-order), keyed as in technique item 5. A minimal `VectorGlyphRenderer:
RendererBackend` that renders `.glyphRun` frame commands for single-scalar ASCII
to its own `CAMetalLayer`, single sample per frame, no accumulation. Plumb it in
as an opt-in, default-off, all-OS-available backend (curve rasterization needs no
macOS 26 feature; do **not** gate it behind `#available(macOS 26, *)`). The
plumbing is:
- `RendererSelection` (moved to `LabanRenderer`) gains `.vectorGlyph`;
  `RendererMode` is **not** touched.
- The shared `makeRendererBackend(...)` factory (LabanRenderer) builds it, with
  the fallback cascade; `TerminalBitmapView` and `HeadlessDebugRuntime` both call
  the factory.
- **Both** UI surfaces gain a consistent entry: the View ▸ Renderer menu
  (`RendererModeMenuController`, title e.g. "Vector Glyph Renderer") **and** the
  Settings popup (`SettingsWindowController`, its own title style e.g. "Vector
  Glyph"). They need not share the exact string, but must expose the same set of
  selections. Update `RendererModeMenuController.gpuDrivenTitle`-style title
  wiring and `SettingsWindowController.rendererTitle`.
- Update the tests that hard-code the renderer item list — at minimum
  `RendererModeSettingsTests.testRendererMenuPersistsAvailableSelectionAndAppliesLiveMode`
  (asserts the exact menu title array) and the `SettingsWindowController`
  popup-population assertions.
- `TerminalBitmapView.applyFontSize` gains the vector branch so font zoom keeps
  the vector backend (see "Backend selection vs Metal mode").

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
  and `effectiveRenderer` are both `"vectorGlyph"` when that backend is
  selected. **This is new work, not a pre-existing property:** today
  `DebugRenderEndpoints.renderState()` hard-codes `backend/configuredRenderer/
  effectiveRenderer = "software"` (`Sources/LabanDebug/DebugRenderEndpoints.swift:33`),
  and the existing `testRuntimeRenderStateReportsRendererStatus`
  (`Tests/LabanDebugTests/LabanDebugSmokeTests.swift:543`) only asserts the
  software case. M2 must make `HeadlessDebugRuntime` carry a selectable
  renderer (see "Headless / debug vector support" above) and report the live
  backend's configured/effective/fallback; the existing software assertions
  must stay green (regression). When **no Metal device** is available the
  effective backend is **`"software"`** (not classic) with `fallbackReason ==
  "noMetalDevice"`; only a *device-present but vector-pipeline-failed* case
  reports `effectiveRenderer == "classic"` (see "Fallback cascade and status").
- Coverage parity for a plain-ASCII fixture vs the **M0/M1 single-sample CPU/GPU
  oracle** within ±2/255 per pixel over ink (both are single-sample point
  tests, so they agree by construction; this proves the on-screen path wires
  the same kernel). **Do not** compare M2 against `classic` here: M2 is
  single-sample with no AA while `classic` samples an anti-aliased CoreText
  mask, so edge texels differ by up to ~255. The classic-parity gate is
  deferred to M3's converged output.

### M3 — Temporal accumulation

Scope: convert the atlas texels from single-sample R8 to the **`rgba32Uint`**
accum buffer `(sumR,sumG,sumB,count)` with fixed-point coverage
(`COV_SCALE = 65535`) exactly as pinned in technique item 6; add the sample
schedule (8/4/2/1, cap 512) and $R_2$ quasirandom jitter (seeded from the atlas-
key hash); resolve to alpha via `sum.c / (sum.a · 65535)`. Add a per-frame sample
budget and time-slicing so a frame full of fresh glyphs can't spike.

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
- Classic parity (deferred from M2), **perceptual not per-pixel-exact** (class 3
  of "Test thresholds"): converged ASCII vs `classic` over ink by mean-abs ≤
  ~4/255 and ≥95% of ink pixels within ±8/255. Exact per-pixel equality is **not**
  required — `classic` is CoreText-rasterized (and may be hinted) while vector is
  unhinted, so edge texels legitimately differ. Solid fills / decorations
  (geometry-identical) still use zero tolerance (class 2).
- Perf: `scripts/analyze-metal-trace --record 10 --attach Laban` on a 4K-full
  of static ASCII reports the vector content pass at **≤0.3 ms p50** once
  converged (the article reports ~0.1 ms on a 9070; the gate is generous for an
  Apple GPU first pass). Emit the trace JSON to a local temp path for
  inspection (`.build/` is gitignored, so it cannot be the evidence store);
  record the quoted p50/p95/p99 numbers in the Decision Log as the committed
  evidence, mirroring how ADR 0017 records its M5/M6 numbers in prose.

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
- **Glyph fallback** (see "Glyph fallback"): glyphs/clusters with no usable
  outline — `nil`/empty paths, bitmap/`sbix` glyphs, color emoji, `.notdef`,
  unresolved clusters — render through the existing raster/classic alpha-mask
  atlas, keyed in a disjoint namespace (`kind = raster`). Test: a mixed fixture
  (ASCII + emoji + a CJK glyph + a missing glyph) renders correctly with vector
  selected, and debug status reports a non-zero `rasterFallbackGlyphs`.
- **Synthetic bold / italic** (see "Synthetic bold / italic"): style flags in the
  atlas key; real styled face → styled outline; fake italic → shear; fake bold →
  raster fallback initially. Test: fake-italic produces sheared output distinct
  from regular; fake-bold does not render at regular weight.
- Text decorations (underline/strikethrough/overline, all styles) and
  hyperlink visuals — emit as solid overlays exactly as the gpuDriven path does.
- Selection / find / cursor overlays, image quads, sidebar text, preedit.
- Inverse/faint/invisible — already pre-resolved into colors by
  `FrameProducer`, so the vector path renders them like the gpuDriven path.

Then:
- Raw-RGBA parity suite `VectorGlyphParityTests` modeled on
  `GPUCellParityTests`, using the four "Test thresholds" classes: **zero
  tolerance** where geometry is identical to the classic path (solid fills,
  decorations, overlay/cursor/selection rects — classes 2 & 4) and a
  **perceptual band** for glyph ink (class 3, mean-abs + percentile, never
  per-pixel CoreText equality). Expected/actual/diff PNGs on mismatch.
- `HeadlessDebugRuntime` parity: the renderer is selectable headless via the
  shared factory, `GET /debug/screenshot` works through it **via the offscreen
  Metal render + readback** built in M2/M4 (not the software `surface.pngData`
  path), and a headless E2E renders a fixture identically to the live path after
  pumping to the converged sample index.
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
- ADR `docs/adr/0022-vector-glyph-renderer.md` **already exists and is already
  indexed** in `docs/adr/README.md` (it was landed alongside this plan). M5 does
  not "write" it; M5 updates its **Evidence** section with the release-timing
  numbers and confirms its Status reflects the shipped opt-in renderer. Keep ADR
  and plan in agreement (no `/debug/renderer-status` route; selection vs Metal
  mode split).

Acceptance (the gate — all must pass):
- `swift test` green, including the new parity suite and the live-switch test.
- `./scripts/build-app` and `./scripts/install-app` produce a bundle where the
  View ▸ Renderer menu offers "Vector Glyph Renderer", selecting it renders a
  live shell with no session restart, and switching back is lossless.
- `GET /debug/render` returns a `RenderResponse` whose `configuredRenderer`/
  `effectiveRenderer`/`fallbackReason` report the correct tuple: with a Metal
  device and vector selected, all `"vectorGlyph"`/`nil`; with **no Metal device**,
  `effectiveRenderer == "software"`, `fallbackReason == "noMetalDevice"` (not
  classic); device-present-but-vector-pipeline-failed → `effectiveRenderer ==
  "classic"`, `fallbackReason == "vectorPipelineUnavailable"`. Same endpoint as
  M2; the vector headless assertion is
  `testRuntimeRenderStateReportsVectorGlyphRendererStatus` and the software
  default stays covered by `testRuntimeRenderStateReportsRendererStatus`
  (both in `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`).
- Release timing: run the matrix via `scripts/analyze-metal-trace`; emit the
  JSON locally for inspection, then record the quoted p50/p95/p99 numbers in
  the Decision Log (and ADR 0022's Evidence section) as the committed
  evidence — `.build/`, `.artifacts/`, and `.tmp/` are all gitignored, so a
  committed JSON file is not an option. The Decision Log records whether
  `vectorGlyph` met the ADR-0017 default-enable threshold (it is expected
  **not** to, this plan ships it opt-in regardless).

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

If any gate fails, the failure is recorded in the Decision Log and blocks
completing M5. The only gates that may fail **without** blocking the opt-in
ship are the **perf/default-enable** thresholds (the M3 ≤0.3 ms p50 trace and
the ADR-0017 default-enable comparison): a missed perf target means the
renderer ships opt-in at whatever quality/speed it achieved, with the numbers
recorded. The **correctness** gates — parity (`VectorGlyphParityTests`),
headless/screenshot E2E, session-identity live switch, the M0/M1 oracle, and
no regression in `classic`/`gpuDriven`/software — are hard blockers; M5 is
not done until they pass. (This plan adds files and enum cases; it does not
edit `MetalRenderer`'s content passes or the existing shaders, so a
correctness regression in another renderer would be a bug to fix, not an
acceptable outcome.)

## Progress

- [ ] M0 — `GlyphCurveStore`: CoreText→contour-aware quadratic extraction (per-contour seed, nil for outline-less glyphs) + CPU winding-number oracle; strict geometry/oracle tests (unit square, analytic disc, contour topology O/i/%/8/combining-mark, cubic sampled-max-deviation) + perceptual CoreText comparison (mean-abs/percentile, not ±2/255 exact).
- [ ] M1 — Metal compute rasterizer (from-scratch MSL port) into scratch atlas, single sample; ASCII readback vs M0 oracle within ±3/255; `analyze-metal-trace --self-test` still passes.
- [ ] M1a (stretch) — Apple-GPU tile-shader coverage pass; promoted only if it beats M1 on release timing and keeps parity.
- [ ] M2 — Z-order (transposed) resident atlas + `VectorGlyphRenderer: RendererBackend` on screen for ASCII, single sample, no accumulation; `RendererSelection` moved to `LabanRenderer` + `.vectorGlyph` (RendererMode untouched), shared `makeRendererBackend` factory, menu **and** Settings entries + test updates, `applyFontSize` vector branch (default-off, no macOS-26 gate); on-screen ASCII readable, session survives; `GET /debug/render` reports `vectorGlyph` (no-device → software); parity vs M0/M1 oracle within ±2/255.
- [ ] M3 — Temporal accumulation (`rgba32Uint` fixed-point accum, 8/4/2/1 schedule, cap 512, R₂ jitter); convergence/determinism protocol (pump-to-N, hash-seeded jitter); perceptual classic parity at convergence (mean-abs, not per-pixel exact); ≤0.3 ms p50 trace.
- [ ] M4 — Subpixel AA (per-R/G/B winding) + user-configurable layout (RGB stripe default, custom JSON for OLED); overlapping sample quads; fringing test artifact.
- [ ] M5 — Feature parity (box-drawing grid-pinned, wide/CJK/ZWJ, glyph fallback for non-outline/emoji/.notdef, synthetic bold/italic, decorations, overlays, image quads, sidebar, preedit); `VectorGlyphParityTests` (four threshold classes); `HeadlessDebugRuntime` parity + offscreen `/debug/screenshot`; release timing matrix; `testVectorGlyphSwitchPreservesActiveSessionIdentity` in `RendererModeSettingsTests`; ship default-off; ADR 0022 Evidence updated.
- [x] ADR `docs/adr/0022-vector-glyph-renderer.md` written and `docs/adr/README.md` index entry — **already landed** (ADR 0022 exists and is indexed). M5 only updates its Evidence section.

## Decision Log

- Decision: **osor-style first, Slug-informed.** Use the osor.io resident-atlas +
  temporal-accumulation approach as the **first** vector renderer; treat Slug as
  viable prior art (robustness/shader/data-layout/test-case reference) and a
  possible **v2** direct-vector renderer, not the first integration target. The
  choice is architecture fit, **not** legal. The four dimensions kept
  deliberately separate:
  - **Legal risk: none (changed in 2026).** Slug was covered by **US Patent
    10,373,352** (Eric Lengyel; granted 2019; nominal term to ~2038). On
    **2026-03-17** Lengyel dedicated it to the public domain via a USPTO terminal
    disclaimer (form SB/43) and released MIT-licensed reference shaders (primary
    source: <https://terathon.com/blog/decade-slug.html>; corroborated by
    Hackaday 2026-03-20). So Slug is freely implementable today, and its
    reference shaders are prior art worth studying. The prior plan's "patent-
    encumbered, US 9,710,310, ~2035" claim was wrong on number, year, and term
    and is retracted. **Patent risk no longer factors into this decision.**
  - **Architecture fit:** Slug evaluates exact coverage per pixel in the pixel
    shader on every frame with no caching; a terminal redraws the same static
    glyphs across many frames, so a resident atlas that amortizes rasterization
    to ~0 per-frame cost and accumulates subpixel AA over time fits the workload
    better.
  - **Implementation complexity:** the accumulation approach tolerates a single
    bad intersection sample (1/512 of the final weight — imperceptible), so it
    does **not** need Slug's floating-point-exact root classification; the M0 CPU
    oracle + perceptual parity tests are sufficient. Slug buys exactness Laban
    does not need for a cached atlas.
  - **Terminal-specific constraints:** monospaced, single-font, mostly-static,
    heavy glyph reuse, and pixel-aligned columns mean the atlas working set is
    small (low hundreds of unique glyph+size entries) and cache hit rates are
    high — exactly where caching beats per-pixel recompute.
  - **Ranking / sequencing:** (1) osor-style vector-to-atlas first; (2) Slug-style
    direct renderer as a studied v2, revisited only after backend selection,
    debug/capture, fallback reporting, and the atlas/vector tests are stable;
    (3) Vello not the first Swift/Metal terminal integration; (4) CoreText raster
    atlas retained as baseline/fallback. Full comparison table in "Architecture
    decision: osor-style first, Slug-informed".
  Date/Author: 2026-06-19 / planning + research; 2026-06-20 / corrected Slug
  legal status and split into four dimensions; 2026-06-20 / explicit "osor-style
  first, Slug-informed" framing + option ranking.

- Decision: ship `vectorGlyph` knowing no terminal currently ships GPU curve
  rasterization (greenfield, not catch-up).
  Rationale: Verified Ghostty (Laban's terminal core) uses a CPU-rasterized
  alpha-mask atlas (`src/font/Atlas.zig`), same as kitty/WezTerm/Alacritty and
  Laban's own `MetalGlyphAtlas`. The osor.io recipe is the 2026 SOTA for this
  technique family and is purpose-fit for a terminal's mostly-static, single-
  font, heavy-reuse workload. Vello / vello_hybrid solve general 2D vector
  graphics and are a maturing ecosystem, but they are a heavy Rust/wgpu/general-2D
  integration relative to Laban's Swift/Metal terminal-specific needs — not
  selected for the first path on integration grounds (re-verify upstream state
  before citing it; do not assert "not production-ready" as a fixed fact).
  Date/Author: 2026-06-19 / planning + research; 2026-06-20 / Vello wording
  softened to integration-fit, not maturity claim.

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

- Decision: coverage is `saturate(abs(W))` where `W` is the **net** winding
  summed over the curves of **all contours**, sign-invariant — not `saturate(W)`
  and not a sum of per-curve `abs`.
  Rationale: `CTFontCreatePathForGlyph` returns Y-up em-space outlines; the atlas
  texture is Y-down. Negating y to fill the texture reverses every contour's
  winding together and flips the sign of `W`, so `saturate(W)` would clamp a
  flipped glyph to 0 (invisible). Taking `abs` of the *net* `W` is robust to the
  flip **and** preserves holes (outer `±1` + hole `∓1` = 0 inside the hole); a
  sum of per-curve `abs` would fill holes in. Accumulation stores the
  **fixed-point** coverage, not a truncated cast:
  `sum += uint4(round(saturate(abs(W)) * 65535) [×3], 1)` into the `rgba32Uint`
  buffer (technique item 6) — `uint(saturate(W))` alone would quantize partial
  coverage to 0/1 and kill AA. This is the correctness invariant the M0/M1 parity
  and contour-topology tests pin.
  Date/Author: 2026-06-19 / review fix; 2026-06-20 / net-W-over-contours + fixed-
  point scaling.

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
  with LRU eviction and, on exhaustion, a per-glyph raster fallback (cascade
  case 3) escalating to a whole-frame `classic` fallback — never silent glyph
  drops. Note this `classic` fallback is legitimate **only because a Metal device
  is present** in this scenario (atlas pressure, not a missing device); it is
  *not* the no-device path, which resolves to **software** (cascade case 1).
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

- Decision: `vectorGlyph` is a value of `RendererSelection` (the requested-backend
  type), **not** of `RendererMode` (the Metal-internal mode type); and
  `RendererSelection` + a shared `makeRendererBackend(...)` factory move down to
  `LabanRenderer`.
  Rationale: `RendererMode` (`{classic, gpuDriven}`) only ever feeds
  `MetalRenderer`, whose `effectiveRendererMode` collapses any non-`gpuDriven`
  value to `.classic`; a `RendererMode.vectorGlyph` would be a value that is
  invalid everywhere it is consumed. Keeping vector out of `RendererMode` and
  giving `RendererSelection.vectorGlyph` a `nil` `metalMode` makes "route vector
  into a Metal-mode API" *unrepresentable*. The factory and selection type must
  sit in `LabanRenderer` because `LabanDebug` (headless) must construct the same
  backend and **must not depend on `LabanApp`** — where `RendererSelection` and
  the `private static makeBackend` live today. `RendererStatus` already lives in
  `LabanRenderer` on `RendererBackend`, so the status plumbing is already at the
  right level. This corrects the earlier plan, which added vector to *both* enums
  and assumed `LabanDebug` could call `TerminalBitmapView.makeBackend`.
  Date/Author: 2026-06-20 / review fix (package boundary + domain separation).

- Decision: the fallback model has four distinct, separately-reported outcomes;
  "no Metal device → software", never "→ classic".
  Rationale: classic is itself a Metal renderer, so it cannot recover a missing
  Metal device. `MTLCreateSystemDefaultDevice()` nil → `SoftwareBackend`
  (`fallbackReason "noMetalDevice"`). Device present but vector pipeline build
  fails → classic Metal (`"vectorPipelineUnavailable"`). Per-glyph unusable
  outline → raster atlas for that cell only (`rasterFallbackGlyphs` count),
  `effectiveRenderer` stays vector. All reported via the existing
  `RendererStatus{configuredRenderer, effectiveRenderer, fallbackReason}`. The
  earlier "fall back to classic when Metal is unavailable" wording was wrong.
  Date/Author: 2026-06-20 / review fix.

- Decision: the accumulation buffer is `rgba32Uint` with fixed-point coverage
  (`COV_SCALE = 65535`), not a float buffer and not a truncating `uint` cast.
  Rationale: fractional coverage must be scaled before integer storage
  (`round(cov*65535)`), or partial coverage truncates to 0/1 and AA dies.
  Integer fixed-point addition is exactly associative/commutative, so converged
  output is independent of GPU scheduling → byte-reproducible for the parity and
  headless gates (a float accumulator is ~equally precise but order-dependent in
  the low bits). Overflow-safe: `512 × 65535 ≈ 3.36e7 ≪ 2^32`. See technique
  item 6 for format, normalization, and the overflow proof.
  Date/Author: 2026-06-20 / review fix.

- Decision: glyph geometry is stored **per contour** (contour ranges + a seed per
  contour), with nonzero fill over the net winding; not "2 points per curve + 1
  seed per glyph".
  Rationale: a single per-glyph seed chains the last curve of one contour into
  the first of the next, fusing outer rings with holes and merging disjoint marks
  — `O`, `i`, `%`, `8`/`B`, and combining marks would all render wrong.
  Contour-aware storage + `|net W|` makes holes empty and disjoint contours both
  fill; contour orientations from CoreText are preserved (never re-normalized).
  Tested by the M0 contour-topology suite.
  Date/Author: 2026-06-20 / review fix.

- Decision: not every displayed glyph has a usable outline; outline glyphs go
  vector, everything else (nil/empty paths, bitmap/`sbix`, color emoji,
  `.notdef`, unresolved clusters) falls back to the existing raster atlas, in a
  disjoint key namespace (`kind = raster`). Style flags (`bold/italic/
  syntheticBold/syntheticItalic`) join the vector key; real styled faces use the
  styled outline, fake italic uses a shear, fake bold falls back to raster
  initially (outline emboldening is a later improvement) so styled text never
  renders at regular weight.
  Rationale: `CTFontCreatePathForGlyph` returns nil/unusable for a real fraction
  of terminal content, and the existing `MetalGlyphAtlas` key already carries
  `boldFallback`/`italicFallback` — the vector path must match or silently
  mis-render styled and non-outline glyphs. Debug status exposes
  `rasterFallbackGlyphs` so the fallback is observable.
  Date/Author: 2026-06-20 / review fix.

- Decision: headless/debug vector support is explicit, scoped work — **not** a
  free consequence of selecting the backend.
  Rationale: today `HeadlessDebugRuntime` holds a concrete `BitmapSurface` +
  `SoftwareRenderer` (no `RendererBackend`), `/debug/screenshot` reads
  `surface.pngData`, `renderState()` hard-codes `"software"`, and resize/font-
  size rebuild a `SoftwareRenderer`. A Metal-family backend renders into an
  `MTLTexture` with no on-screen drawable, so vector output needs offscreen
  render + readback (or mirroring into `BitmapSurface`), the runtime must hold a
  `RendererBackend`, and `renderState()` must read `rendererStatus`. Some
  endpoints (`/debug/render-trace`, `/debug/atlas`) stay software/classic-only
  initially and are named as such. The earlier "screenshots become free once the
  backend is selected" claim was false.
  Date/Author: 2026-06-20 / review fix.

- Decision: tests are bucketed into four threshold classes (geometry/oracle =
  exact; synthetic geometry-identical = zero tolerance; real-font glyph ink =
  perceptual; UI/layout = exact). Vector glyph ink is **not** required to be
  pixel-equal to CoreText/`classic`.
  Rationale: the vector path is unhinted and rasterizes from outlines with its
  own kernel, while `classic` rasterizes via CoreText (possibly hinted), so tight
  per-pixel parity against CoreText is unachievable and not a goal. Exactness is
  reserved for the math (winding/topology/oracle) and for non-glyph geometry
  (fills, decorations, cursor/overlay rects); glyph ink uses a perceptual metric.
  Date/Author: 2026-06-20 / review fix.

## Surprises & Discoveries

(To be filled as implementation proceeds — e.g. Metal compute precision
quirks, `CTFontCreatePathForGlyph` differences across fonts, Apple-GPU wave
width vs the article's 16-thread assumption, accumulation-buffer format
choices.)

## Review Gate

Review status: NOT REVIEWED

A fresh review agent must confirm, against the commit SHA under review:

- [ ] `rg "vectorGlyph" Sources/LabanRenderer/RendererMode.swift` returns
     **nothing** — `RendererMode` stays `{classic, gpuDriven}` (Metal-internal
     modes only). `vectorGlyph` lives in `RendererSelection` (now in
     `Sources/LabanRenderer/RendererSelection.swift`, moved from `LabanApp`), and
     `RendererSelection.vectorGlyph.metalMode == nil`. `RendererMode.defaultMode`
     still returns `.gpuDriven ?? .classic` (default unchanged).
- [ ] `rg "encodeContentPass|encodeGPUCellContentPass"
     Sources/LabanRenderer/MetalRenderer.swift` shows the classic/gpuDriven
     dispatch is unchanged in substance. Run `git diff` on
     `Sources/LabanRenderer/MetalRenderer.swift` and confirm no behavioral edit
     to the two existing content passes.
- [ ] `rg "Shaders.metal" Sources/LabanRenderer/` — `Shaders.metal` is
     untouched; the vector shaders live in a separate `VectorGlyphShaders.metal`,
     and `Package.swift` has `.process("VectorGlyphShaders.metal")` in the
     `LabanRenderer` target `resources` (without it SwiftPM will not bundle the
     file and the renderer's loader will return nil at startup).
- [ ] The new shader is actually bundled and loadable:
     `LabanRendererResources.bundle?.url(forResource: "VectorGlyphShaders",
     withExtension: "metal")` resolves inside `.build/laban/Laban.app`, and
     `VectorGlyphRenderer` compiles a non-nil `MTLLibrary` from it.
- [ ] **Shared factory + selection routing** (the "peer backend" is actually
     wired and the package graph is legal): `RendererSelection` is in
     `LabanRenderer` and `RendererSelection.vectorGlyph.metalMode` is `nil` (like
     `.software`, so it is not collapsed to classic by
     `MetalRenderer.effectiveRendererMode`); a `public makeRendererBackend(...)`
     factory lives in `LabanRenderer` with an explicit `.vectorGlyph` →
     `VectorGlyphRenderer` case and the no-device→software / pipeline-fail→classic
     cascade; **both** `TerminalBitmapView` (LabanApp) and `HeadlessDebugRuntime`
     (LabanDebug) call that factory — neither re-implements routing, and
     `LabanDebug` does **not** import `LabanApp`. `TerminalBitmapView.rendererMode`/
     `rendererSelection` report vector (via `rendererStatus` or a `backend as?
     VectorGlyphRenderer` arm), and `applyFontSize` has a vector branch so font
     zoom does not drop to software.
- [ ] **Headless / debug vector support**: `HeadlessDebugRuntime` takes a
     `rendererSelection`, holds a `RendererBackend` (not just a `SoftwareRenderer`),
     and `DebugRenderEndpoints.renderState()` reads configured/effective/fallback
     from the live backend's `rendererStatus` (no hard-coded `"software"` literal
     for the vector path); `/debug/screenshot` produces vector output via offscreen
     readback (or `BitmapSurface` mirror) rather than assuming `surface.pngData` is
     software; resize/font-size rebuild via the shared factory.
     `testRuntimeRenderStateReportsVectorGlyphRendererStatus` (device-present →
     vectorGlyph; no device → software/`noMetalDevice`) passes, and the existing
     `testRuntimeRenderStateReportsRendererStatus` (software default) still passes.
- [ ] `swift test --filter VectorGlyphParityTests` exits 0 and leaves no
     `*.diff.png` under `.build/vector-glyph-parity/`.
- [ ] `swift test --filter RendererModeSettingsTests` exits 0, including the new
     `testVectorGlyphSwitchPreservesActiveSessionIdentity` and the updated
     `testRendererMenuPersistsAvailableSelectionAndAppliesLiveMode` (its
     hard-coded menu title array now includes the vector entry). The
     `SettingsWindowController` renderer-popup population (which uses
     `RendererSelection.allCases`) and its title assertions include vector too,
     so menu and Settings expose the same set of selections.
- [ ] `./scripts/build-app` exits 0 and `rg "Vector Glyph Renderer"` on the
     built bundle `.build/laban/Laban.app` (the `build-app` output,
     `scripts/build-app:76`) finds the menu title string. (Do not grep
     `~/Laban.app` — that is refreshed only by `scripts/install-app` and may be
     stale; either check `.build/laban/Laban.app` directly or run
     `./scripts/install-app` first.)
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
     the new `testRuntimeRenderStateReportsVectorGlyphRendererStatus` in
     `Tests/LabanDebugTests/LabanDebugSmokeTests.swift` — the existing
     `testRuntimeRenderStateReportsRendererStatus` only covers software, since
     `renderState()` previously hard-coded it); there is no
     `/debug/renderer-status` route — do not invent one.

Review findings:

_(filled in by the review agent)_
