# Slug Render Loop Performance and Small-Size AA Quality

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that
helps a fresh contributor.

## Purpose / Big Picture

The Slug renderer (`slugGlyph`, an opt-in analytic text backend, ADR 0027)
currently re-encodes and re-draws the entire frame on every render call, even
when the terminal dirtied a single row or only the cursor blinked. It also pays
avoidable per-cell CPU costs (a `String` allocation per visible cell, per-cell
emoji probing without a run-level gate) that its sibling `VectorGlyphRenderer`
already eliminated. Finally, an open quality question from the renderer's
build-out was never answered: whether 2 area-AA samples per edge pixel are
enough at small point sizes.

After this plan:

- Typing, cursor blink, and partial-screen updates (TUI status lines, editors)
  cost the GPU and CPU an amount proportional to what changed, not to the whole
  screen. This is a battery/thermals win for the dominant real-world terminal
  workloads, and headroom for lower-end Apple Silicon. Full-screen scroll is
  unchanged by design (everything moves, so damage is full).
- The per-cell hot loop stops allocating and stops probing emoji/CJK per cell
  when the run cannot contain them.
- The small-size AA question is answered with measurements, and a size-dependent
  sample count ships only if it measurably improves fidelity within frame
  budget.

How to see it working: run the frame-time bench before and after (commands in
Concrete Steps) and compare the new typing-workload numbers; run the damage
parity tests proving partial redraw is pixel-identical to full redraw; run the
AA fidelity tests at 9 to 11 pt and read the recorded metric deltas in this
plan.

## Relationship to prior plans

- `execplans/active/slug-glyph-renderer.md` built this renderer (M0 to M4
  landed, M5 partially landed, plan now dormant). This plan supersedes its open
  performance follow-ups. One piece of its remaining M5 scope is absorbed here
  because verification needs it: making `slugGlyph` selectable in the headless
  debug runtime (M0 below).
- `execplans/active/vector-encode-loop-perf.md` optimized the equivalent CPU
  encode loop in `VectorGlyphRenderer`. Its lessons are binding constraints
  here; see "Prior-art lessons" below.
- `execplans/active/subpixel-seam-accumulate-once.md` designed the subpixel
  accumulate-then-composite pass this plan scissors but must not regress.
- An out-of-repo proposal ("Introduce DirtyRowSet Row-Space Damage Primitive",
  drafted 2026-06-20, not checked in) argued for one canonical normalized
  damage representation and observed that `MetalRenderer` collapses sparse
  dirty bands into a union bounding box, losing the fact that clean rows
  between two dirty rows are clean. Its row-space migration of
  `TerminalSurfaceController`, laband, and `TerminalCellPayload` is NOT this
  plan's scope. This plan adopts only its y-space core as a `DirtyYRangeSet`
  type (spec in Interfaces and Dependencies) because Slug's ring-slot damage
  accumulation makes disjoint bands the common case, where a union collapses
  to near-full-screen. If that proposal is later executed in-repo, its
  row-space `DirtyRowSet` should convert into this same `DirtyYRangeSet` at
  the renderer boundary.

## Context and Orientation

### What the Slug renderer is

`Sources/LabanRenderer/SlugGlyphRenderer.swift` is one of five selectable
renderer backends. Instead of baking glyphs into a texture atlas, it uploads
each glyph's quadratic Bezier outline curves once (extracted at a fixed
reference size of 14 pt, size-independent per ADR 0027) and evaluates coverage
analytically in the fragment shader (`Sources/LabanRenderer/VectorGlyphShaders.metal`,
functions `slugGlyphReferenceCoverage` and up). Terms used below:

- **Instance**: one GPU struct per drawn quad. `SlugGlyphGPUInstance` (64
  bytes) per glyph cell, `SlugSolidInstance` per background/cursor/selection
  rect, `SlugTextureInstance` per raster-fallback glyph (CJK, color emoji).
- **Band walk**: the fragment shader's per-pixel loop over the curves that
  intersect one of 64 horizontal/vertical bands of the glyph's bounding box.
  This is the expensive analytic work; its cost scales with covered fragments.
- **Accumulate-then-composite**: the RGB-subpixel path. One MRT pass draws all
  glyph quads into two full-resolution GPU-private `rgba16Float` textures with
  additive blending (per-channel coverage and premultiplied color), then two
  full-screen draws composite them over the target once. Grayscale skips this
  entirely and draws glyphs directly into the content pass.
- **Target ring**: under the ADR 0026 present path, `render()` draws into one
  of three offscreen textures (`targetRingDepth = 3`,
  `ensureTargetTexture()` at `SlugGlyphRenderer.swift:1587`) and publishes the
  completed texture to a `CAMetalDisplayLink` present thread. A given ring slot
  is therefore 3 frames stale when it is next drawn into. Headless and legacy
  paths use a single persistent target instead.
- **ppem**: on-screen em size in device pixels (point size times backing
  scale).

### The frame pipeline today, and what costs what

`render(_ commands:damage:)` (`SlugGlyphRenderer.swift:624`) currently ignores
`damage` entirely. Every call:

1. **CPU instance build** (`buildInstances` at `:985`, `appendGlyphRun` at
   `:1025`): iterates every `FrameCommand`, and for glyph runs iterates every
   cell (`Character`) at `:1055`. Per cell it currently pays:
   - `ColorGlyphSupport.clusterMayBeColor(cluster)` (cheap, but per cell, with
     no run-level pre-gate; only `emojiRenderingMode == .color` gates it),
   - `TerminalCJKFontPolicy.containsCJK(String(cluster))` at `:1070`, which
     **allocates a `String` per visible cell per frame**,
   - a dictionary lookup keyed by `SlugGlyphResolveKey` (`:83`), whose hash
     includes a `String` PostScript name re-hashed per cell.
   A full 160x48 grid is 7,680 cells per frame.
2. **Geometry cache** (`ensureGlyph` at `:1210`): size-independent, keyed by
   (PostScript name, glyph ID). New glyphs append to `curves`/`glyphs`/`bands`/
   `bandIndices` arrays and set `geometryBuffersDirty`;
   `ensureGeometryBuffersIfNeeded` (`:1448`) then re-uploads the **entire**
   arrays into fresh `MTLBuffer`s.
3. **GPU passes**: the subpixel accumulate pass (two full-res `rgba16Float`
   attachments, cleared and rewritten every frame, encoder at `:670`), the
   content pass (solids, then either direct grayscale glyphs or the two
   full-screen composite draws at `:765`, then raster/color fallback quads),
   then blit/present per ADR 0026.
4. **Per-frame `MTLBuffer` allocation** (`makeBuffer` at `:1670`) for the four
   instance arrays. Note: the equivalent copy in the vector renderer measured
   ~19 microseconds and a buffer-reuse ring was explicitly declined there; do
   not "fix" this without new evidence (see Prior-art lessons).

### The damage contract

`RenderDamage` is defined at `Sources/LabanRenderer/RendererBackend.swift:11-26`:

- `.full`: complete redraw.
- `.partial(yRanges: [DirtyYRange])` where `DirtyYRange` has `y: CGFloat` and
  `height: CGFloat` in CG points, **y-up from the surface bottom**. An empty
  `yRanges` array means "nothing changed in the grid; skip content work, just
  re-present" (cursor blink frames arrive this way).

Callers: `Sources/LabanApp/TerminalBitmapView.swift` computes damage from
libghostty per-row dirty bits and passes it at `:2814` and `:3114`; it forces
`.full` on renderer swap/first paint (`:1223`, `:1258`) and whenever a sub-cell
smooth-scroll offset is active (`:2235`, `:2808`). An upstream idle gate at
`:2602-2619` already skips calling `render()` at all unless something changed
(dirty terminal, cursor blink, attention strip, etc.), so the frames this plan
targets are the ones that do arrive: typing (one or two dirty rows), cursor
blink (empty partial), TUI partial updates. `HeadlessDebugRuntime.swift:802`
and `CaptureReplayRunner.swift:426` use the `.full` convenience.

Precedent: `MetalRenderer` is the only backend that scopes work by damage
today. Empty `.partial` skips the content pass and only rebuilds the cursor and
re-presents (`MetalRenderer.swift:1208-1210`). Non-empty `.partial` converts
the y ranges to a scissor rect (`damageYBounds`/`scissorRectFromYRanges` at
`MetalRenderer.swift:3511`; note the y-flip, since damage is y-up points and
Metal scissor rects are y-down device pixels) and sets `MTLScissorRect` so the
GPU culls fragments in clean rows while the instance list stays full.
`VectorGlyphRenderer` only reads `damage == .full` for its present drop policy
(`:870`). Study both before implementing M2.

### Prior-art lessons that bind this plan

From `execplans/active/vector-encode-loop-perf.md` (same shape of work, same
codebase):

- **Hoisting per-run-constant math out of the per-cell loop landed and paid**
  (its M2, commit 8f6d15e). That is the pattern M1 below copies.
- **A direct-to-buffer instance writer was declined**: the array-to-buffer copy
  measured ~19 microseconds p50, below noise, and added CPU/GPU hazard surface.
  Do not add a buffer-reuse ring here without a new measurement showing
  otherwise.
- **An ASCII scalar fast path was declined despite a real ~285 microsecond
  per-frame CPU saving** because it was invisible through the GPU-bound p95.
  Consequence for this plan: every CPU milestone must measure **CPU-encode time
  directly** (not just end-to-end p95) and must be reverted if it does not move
  a measured number beyond run-to-run noise.
- The remaining vector scroll tail was presentation pacing, which became ADR
  0026. Do not chase present-side pacing in this plan.

`VectorGlyphRenderer` already demonstrates the M1 target state: it caches the
styled font variant **plus** the font's color trait per (attrs, atlas)
(`VectorGlyphRenderer.swift:2336-2358`), gates per-cell emoji checks behind a
per-run `ColorGlyphSupport.textMayContainColor(text:fontHasColorTrait:)`
(`:1327-1330`, `:1406-1409`), caches glyph IDs (`:2366`), and never calls
`containsCJK` inside the per-cell loop.

### Invariants that must not break

From ADR 0026 (display-synced presentation):

- `render()` never calls `nextDrawable()` while the present link exists; the
  link is the sole presenter. The legacy path is only for macOS 13 / opt-out.
- The 3-deep target ring plus the dedicated present queue provide cross-thread
  safety; the latest completed target is published under `presentTargetLock`
  from the command-buffer completion handler. Keep `maximumDrawableCount = 3`
  and `allowsNextDrawableTimeout = true`.
- Honor `waitForFrameCompletion` on every path. Verify present cadence via
  `GET /scroll/present-stats`, not the offscreen bench.

From ADR 0027 (Slug is an opt-in analytic backend):

- Glyph geometry stays keyed by visual font identity plus glyph ID,
  **excluding active point size**; zoom is a projection/instance transform,
  never a geometry rebuild. Never key caches on `ObjectIdentifier(font)`.
- Slug consumes the existing `[FrameCommand]` stream and must not extend the
  renderer contract or add Slug-specific state to `VectorGlyphRenderer`.
- Fallback texture instances stay layout-compatible with
  `VectorGlyphInstance`. Slug stays default-off.

Repo standing rules that apply: renderer changes are verified measure-first;
commits are atomic with single-line reason-style messages; never launch
`Laban.app` via `open` from a shell (install it and let the user launch it; see
`docs/process/agent-operating-guide.md` for install-path overrides so parallel
agents do not clobber `~/Laban.app`).

## Scope and non-goals

In scope: per-cell CPU cost in `appendGlyphRun`; damage-aware GPU scissoring
and (measured) damage-scoped instance building; scoping the subpixel
accumulate/composite passes by the same scissor; small-size AA sample-count
validation; headless `slugGlyph` selectability (verification prerequisite);
conditionally, incremental geometry buffer upload.

Non-goals: changing the default renderer; folding Slug into Vector or removing
`vectorGlyph` (each needs a new ADR); present-link/pacing changes (ADR 0026
owns that); retuning the 64-band count (only reopen if M0 flags the band walk
as dominant); new fallback-rate telemetry beyond the existing
`RendererStatus.rasterFallbackGlyphs`.

## Progress

- [x] M0: baseline measurements, typing-workload bench, headless slug
      selectability, baseline capture recorded. (GPU trace baseline remains
      deferred pending a manual app launch; see Artifacts and Notes.)
- [x] M1: per-cell CPU cost reduction in `appendGlyphRun` (run-level color
      gate, allocation-free CJK check, cheaper resolve key, reserveCapacity).
- [x] M2: damage-aware rendering (empty-partial fast path, scissored partial
      redraw across content + accumulate + composite passes, per-ring-slot
      damage accumulation). Stage B (CPU-side command filtering) was not
      needed; see M2 results.
- [x] M3: small-size AA sample-count validation. Answered no: measured 2/4/8
      samples at 9/11 pt, evidence shows no fidelity win and real cost;
      discarded, shader define confirmed restored to 2. See M3 results.
- [x] M4 (conditional on M0 evidence): incremental geometry buffer upload,
      landed with a measured win on the burst workload. See M4 results.

## Milestones

### M0: Instrument and baseline (no behavior change)

What exists at the end: reproducible numbers for where Slug frame time goes,
a bench that can detect the wins and regressions of M1/M2, and the headless
verification path this plan's acceptance depends on.

Work:

1. Extend `Tests/LabanRendererTests/SlugGlyphFrameTimeBench.swift` (gated
   behind `LABAN_RUN_PERF_BENCH=1`, prints only):
   - Split timing into **CPU-encode** (start of `render()` to just after
     `commit`, measurable by timing the `render()` call with
     `waitForFrameCompletion = false`) and **wall** (with
     `waitForFrameCompletion = true`), reporting p50/p95/p99 for each.
   - Add a **typing workload**: render one full-screen frame, then 200 frames
     whose command list differs in a single row, passed with
     `.partial(yRanges:)` covering that row. Until M2 lands this measures the
     full-rebuild cost of a one-row change; after M2 it proves the win.
   - Add a **cursor-blink workload**: 200 frames with identical commands except
     the cursor rect, passed with empty `.partial`.
   - Run all workloads in grayscale and RGB subpixel modes (use
     `setSubpixelLayout` and note `effectiveSubpixelLayout` gating).
   - Add a **new-glyph-burst workload**: 200 frames each introducing ~20
     previously unseen glyphs (walk up the Unicode plane), to time the
     full-array geometry re-upload (`ensureGeometryBuffersIfNeeded`). This is
     the M4 gate.
2. Record a 10 s GPU trace of the installed app scrolling under `slugGlyph`
   and save a baseline: see Concrete Steps. Note the per-encoder GPU times for
   `laban.slug.glyph-accumulate`, `laban.slug.content`, and the composite
   draws.
3. Verify `RendererSelection.slugGlyph` is selectable in
   `Sources/LabanDebug/HeadlessDebugRuntime.swift` so `GET /debug/screenshot`
   can render via Slug. If it is not wired, wire it (absorbed from the old
   plan's M5; keep the change minimal: selection plumbing only).
4. Record a capture with screenshots on a Slug session
   (`--capture=... --capture-screenshots=final`) to serve as the renderer
   replay regression baseline for M1/M2.

Acceptance: bench prints all five workloads' p50/p95/p99 for CPU-encode and
wall in both AA modes; `.build/slug-baseline.json` exists; a headless
screenshot rendered by Slug is retrievable; baseline numbers and the capture
path are recorded in this plan under Artifacts and Notes.

### M1: Per-cell CPU cost reduction in `appendGlyphRun`

What exists at the end: the per-cell loop does no heap allocation and no
per-cell emoji/CJK probing for runs that cannot contain them, mirroring the
pattern proven in `VectorGlyphRenderer`.

Work items, each landed only if it moves the M0 CPU-encode p50 beyond
run-to-run noise (compare 5 runs) or strictly removes allocation with no
complexity cost; otherwise revert and record in the Decision Log:

1. **Run-level color gate.** Cache the font's color trait alongside the styled
   variant (as `VectorGlyphRenderer.swift:2336-2358` does; the styled variant
   itself is already memoized in `FontAtlas.styledFontVariant`,
   `FontAtlas.swift:133-160`). Compute once per glyph run:
   `runWantsColor = source != .sidebar && emojiRenderingMode == .color &&
   ColorGlyphSupport.textMayContainColor(text:, fontHasColorTrait:)`
   (`ColorGlyphSupport.swift:65`). Call `clusterMayBeColor` per cell only when
   `runWantsColor`.
2. **Allocation-free CJK check.** Add a run-level pre-gate using
   `text.unicodeScalars` (one pass per run, no allocation) or a
   `Character`-based `containsCJK` overload on
   `TerminalCJKFontPolicy` (`TerminalCJKFontPolicy.swift:92` currently takes
   `String`) iterating `cluster.unicodeScalars`. The per-cell
   `containsCJK(String(cluster))` at `SlugGlyphRenderer.swift:1070` must not
   survive: when the run-level gate misses (the common case, pure ASCII/Latin
   rows), no per-cell CJK work happens at all. Note `resolveGlyph` (`:1284`
   region) also builds `String(cluster)`; that path only runs on cache misses
   and may keep it.
3. **Cheaper resolve-cache key.** `SlugGlyphResolveKey` re-hashes the
   PostScript name `String` per cell. Intern the (reference PostScript name,
   bold, italic) triple to a small integer once per run (a
   `[String: Int]` table on the renderer) and key the per-cell cache on
   (fontID, `Character`). Semantics stay visual-font-identity (ADR 0027).
4. **`reserveCapacity`** on the four instance arrays in `render()` using the
   previous frame's counts.

Acceptance: `swift test --filter SlugGlyph` green (correctness, AA fidelity),
`swift test --filter SlugWeightCoreTextParityTests` green, renderer replay of
the M0 capture byte-identical, bench CPU-encode p50 delta recorded in this
plan, emoji/CJK behavior unchanged (the existing color-emoji, monochrome-tint,
CJK-fallback, and adjacent-CJK-seam tests in
`Tests/LabanRendererTests/SlugGlyphRendererTests.swift` all pass).

### M2: Damage-aware rendering

What exists at the end: `render()` honors `.partial`, drawing only damaged
regions while producing pixels identical to a full redraw; empty-partial
frames skip all content encoding.

Design (decided here so the executor does not have to):

- **`DirtyYRangeSet`, the damage value type.** A small normalized y-band set:
  sorted by `y`, non-positive heights dropped, overlapping or adjacent bands
  merged with a tiny epsilon (`0.0001` in point space), with `union(_:)` and
  `overlaps(y:height:)`. New file `Sources/LabanRenderer/DirtyYRangeSet.swift`
  next to `RendererBackend.swift`, public, so `MetalRenderer` or a future
  row-space plan can adopt it without Slug-specific baggage. Linear scans are
  fine (tens of bands at most). This is deliberately the y-space half of the
  out-of-repo DirtyRowSet proposal; keeping bands exact instead of collapsing
  to one min/max interval is the point.
- **Per-ring-slot damage accumulation.** Because a ring slot's texture content
  is 3 frames old when reused, a partial redraw into slot `i` must cover
  everything that changed since slot `i` was last drawn. Maintain a
  `DirtyYRangeSet` accumulator per ring slot: union each incoming frame's
  damage into every slot's accumulator; when rendering into slot `i`,
  `effectiveDamage = accumulator[i].union(incoming)`, then reset
  `accumulator[i]` to empty. Normalization keeps the accumulator small and
  exact across the 3-frame window: typing at the prompt while a status line
  blinks stays two narrow bands, not one near-full union. The headless/legacy
  single persistent target is the degenerate 1-slot case. (Alternative
  considered and parked: a persistent canvas texture plus a full-frame blit
  into the ring slot; see Decision Log.)
- **Cursor correctness.** Cursor rects arrive as `FrameCommand.cursor`
  commands, drawn as solids inside the content pass. Remember the previous
  frame's cursor rects; union previous and current cursor rects into
  `effectiveDamage`, so empty-partial cursor-blink frames redraw exactly the
  cursor cells (MetalRenderer precedent, `MetalRenderer.swift:1208-1210`).
- **Force `.full`** whenever any of these changed since the previous rendered
  frame: `gestureZoom` or its anchor (the projection transform moves every
  pixel), surface size or scale (resize already resets targets),
  `effectiveSubpixelLayout`, `textWeight`, `emojiRenderingMode`, or the ring
  was (re)allocated. Damage `.full` from upstream stays full. Geometry buffer
  re-uploads do NOT force full (same glyphs produce the same pixels).
- **Scissoring (stage A, GPU).** Keep the instance build full. Convert each
  band of the effective `DirtyYRangeSet` to a device-pixel `MTLScissorRect`
  (y-flip: damage is y-up CG points, scissor rects are y-down device pixels;
  `MetalRenderer.scissorRectFromYRanges` at `MetalRenderer.swift:2192` is the
  reference, and its per-range use at `:1987-2002` is precedent for per-band
  scissors). Do not collapse bands to one min/max scissor: with per-slot
  accumulation, disjoint bands (prompt row plus status line) are the common
  case, and a union degenerates to near-full-screen. Instead, per pass, loop
  the bands: set the band's scissor, issue the draws. Vertex work repeats per
  band but fragment work (the band walk, the expensive part) is exactly
  culled; band counts are small (single digits) after normalization. If a
  frame's band count exceeds a small cap (say 8), fall back to one union
  scissor for that frame — correctness is unaffected either way. Apply this
  banding to the accumulate pass, the content pass, and both composite draws.
  Note this is a pure fragment-cost win for Slug, not a correctness fix:
  Slug's redraw is deterministic (analytic coverage into freshly cleared
  accumulate textures), so redrawing a clean row under a wider scissor
  produces identical pixels, unlike the AA-edge accumulation risk
  MetalRenderer documents for its persistent target
  (`MetalRenderer.swift:1672-1681`). The gesture-zoom identity assumption
  holds throughout (zoom forces full, so scissors never coexist with a non-1
  zoom). Load actions on partial frames: the content target
  switches from `.clear` to `.load` (Metal's `.clear` clears the entire
  attachment regardless of scissor; study how `MetalRenderer` handles
  load-vs-clear for its persistent target and mirror it), and the background
  is repainted inside the scissor by the frame's own background rect commands.
  The accumulate textures keep whole-texture `.clear` (tile clears are
  effectively free on Apple GPUs, and the composite only reads accumulate
  texels inside the scissor, so stale texels outside are never read).
- **Empty effective damage** (no y ranges, cursor rects unchanged): skip
  encoding entirely and do not rotate the ring; if `presentsToLayer`,
  re-publish the latest target so the present link still has content. Call
  `onFrameCompleted` to preserve the completion contract.
- **Stage B (CPU), gated on M0/M2 typing numbers.** If the typing workload's
  CPU-encode remains material after stage A, filter commands during
  `buildInstances` via `effectiveDamage.overlaps(y:height:)` against each
  command's rect/run extent expanded by one cell height in y (glyph quads
  overhang their cells by the dilation pad and italic slant; one cell is a
  conservative bound; assert it against `localPixelPad`). The exact band set
  matters here even more than on the GPU: a union filter would rebuild every
  row between two distant dirty rows. Never filter on force-full frames. If stage A already
  makes typing cheap enough that stage B is below noise, record that and skip
  it (the vector M3 lesson).

Acceptance:

- New test file `Tests/LabanRendererTests/SlugGlyphDamageTests.swift`:
  1. Render frame A (full), then frame B with one changed row as
     `.partial`; separately render frame B as `.full` on a fresh renderer.
     The two B PNGs are byte-identical (use `pngData` and compare; run in
     grayscale and subpixel modes).
  2. Repeat across 4+ consecutive partial frames so every ring slot is
     exercised at age 3 (this is the test that catches accumulation bugs).
     Include a sparse-band case: two dirty rows separated by 10+ clean rows,
     asserting the clean rows between them are byte-identical to the previous
     frame AND that the union of the two bands was not what got redrawn
     (probe: make the middle rows' content differ between the partial command
     list and what a union redraw would produce, so a union bug changes
     pixels).
  3. Cursor blink via empty `.partial` toggles exactly the cursor pixels
     (diff vs previous frame is confined to the cursor rect union).
  4. A gesture-zoom change between partial frames forces a full redraw
     (output identical to a fresh full render at that zoom).
  5. Empty effective damage does not rotate the ring and still reports
     success.
- Bench: typing and cursor-blink workloads improve vs the M0 baseline
  (record numbers here); full-screen scroll workload unchanged within noise.
- Renderer replay of the M0 capture unchanged (replay uses `.full`).
- GPU trace during typing shows `laban.slug.*` encoder time reduced vs
  baseline; `scripts/analyze-metal-trace ... --fail-on-regression` passes on
  the scroll trace (exit code not 3).

### M3: Small-size AA sample-count validation (prototyping)

What exists at the end: an evidence-backed answer to "is
`kSlugAreaAASampleCount = 2` (`VectorGlyphShaders.metal:654`) enough at small
sizes", and either a promoted size-dependent sample count or a recorded
discard.

Background: `slugGlyphAreaCoverage` (`VectorGlyphShaders.metal:795-838`) takes
one analytic center sample and returns it directly for deep interior/exterior
pixels; only edge pixels integrate `kSlugAreaAASampleCount` extra samples. At
small ppem (9 to 11 pt), more of every stem is "edge", so sample placement and
count matter most there.

Work:

1. Extend `Tests/LabanRendererTests/SlugGlyphAAFidelityTests.swift` with
   small-size probes: render the same probe text through `SoftwareBackend`
   (CoreText ground truth) and Slug at 9 and 11 pt, scales 1 and 2, grayscale
   and subpixel, and compute `computeTextAAMetrics`
   (`Tests/LabanRendererTests/RendererImageTestSupport.swift`: ink mass,
   edge-pixel ratio, gradients, edge chroma, coverage spread). Record the
   Slug-vs-software deltas at sample count 2.
2. A/B higher sample counts by editing the `#define` (the shader library is
   compiled from bundle source at renderer init, so `swift test` picks it up
   after a rebuild): 4 samples, and an 8-sample rotated-grid variant. Record
   the same metrics plus `SlugGlyphFrameTimeBench` full-screen numbers for
   each.
3. Promote only if (a) at least one small-size metric moves toward the
   software envelope by more than the existing test tolerance band, and (b)
   full-screen bench p99 stays at or under 8.33 ms at the highest affected
   size. The promoted implementation selects the sample count in-shader from
   `unitsPerPixel` (already computed via `fwidth`), keeping large sizes at 2
   samples; plumb no new uniforms.
4. If not promoted: restore the define to 2, record the measured deltas in
   Surprises & Discoveries, and check the milestone off as answered-no.

Acceptance: metric tables for 2/4/8 samples at 9 and 11 pt recorded in this
plan; either a landed size-dependent sample count with green AA fidelity and
bench gates, or a recorded discard with evidence.

### M4 (conditional): Incremental geometry buffer upload

Enter this milestone only if M0's new-glyph-burst workload shows the full
re-upload in `ensureGeometryBuffersIfNeeded` (`SlugGlyphRenderer.swift:1448`)
causing frame-time spikes (it re-copies the entire curves/glyphs/bands/
band-index arrays into brand-new `MTLBuffer`s whenever any new glyph appears).
The geometry arrays are append-only by construction, so the candidate fix is
capacity-doubling persistent buffers with tail-only writes. Respect the
declined-buffer-ring lesson: land only with a measured win on the burst
workload, and keep `geometryBufferUploadCount` semantics intact (tests use it
to prove zoom does not re-upload).

## Plan of Work (edit map)

- `Sources/LabanRenderer/SlugGlyphRenderer.swift`: M1 items 1-4 inside
  `appendGlyphRun`/`ensureGlyph` and `render()`; M2 damage state
  (per-slot accumulators, previous cursor rects, previous zoom/layout/weight
  snapshot), scissor computation, load-action switching, empty-damage early
  out; M4 `ensureGeometryBuffersIfNeeded`/new `ensureIncrementalBuffer<T>`
  helper and per-array uploaded-count tracking.
- `Sources/LabanRenderer/TerminalCJKFontPolicy.swift`: M1 item 2 overload.
- `Sources/LabanRenderer/VectorGlyphShaders.metal`: M3 only
  (`kSlugAreaAASampleCount` region); no shader changes in M1/M2 (scissor is
  encoder state).
- `Sources/LabanDebug/HeadlessDebugRuntime.swift`: M0 item 3 if slug selection
  is missing.
- `Tests/LabanRendererTests/SlugGlyphFrameTimeBench.swift`: M0 workloads.
- `Tests/LabanRendererTests/SlugGlyphDamageTests.swift`: new in M2.
- `Tests/LabanRendererTests/SlugGlyphSmallSizeAAProbeBench.swift`: new in M3,
  print-only small-size probes (see Decision Log for why this is a new file
  rather than an extension of `SlugGlyphAAFidelityTests.swift`).
- `Tests/LabanRendererTests/SlugGlyphIncrementalGeometryUploadTests.swift`:
  new in M4 (byte-identical incremental-vs-fresh-upload gate, zoom-still-
  does-not-upload regression).
- `Sources/LabanRenderer/DirtyYRangeSet.swift`: new in M2 (normalized y-band
  set + `Tests/LabanRendererTests/DirtyYRangeSetTests.swift` covering
  normalization: drop non-positive heights, sort, epsilon-merge overlapping
  and adjacent bands, union, overlaps-keeps-gaps). Migrating `MetalRenderer`'s
  `DamageYBounds` union onto it is a candidate follow-up, not this plan.
- Shared scissor helper: if `MetalRenderer`'s y-range-to-scissor conversion is
  reusable, hoist it rather than duplicating (keep the change mechanical; do
  not restructure `MetalRenderer`).

## Concrete Steps

All commands run from the repository root `/Users/user/wrk/laban`.

Build and test:

    swift build --target LabanRenderer          # fast type-check of renderer edits
    swift test --filter SlugGlyph               # correctness + AA fidelity + damage tests
    swift test --filter SlugWeightCoreTextParityTests

Bench (release, prints percentiles, asserts nothing):

    LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugGlyphFrameTimeBench

App build for headful tracing (install, then ask the user to launch; never
`open` the bundle from the shell):

    ./scripts/build-app --profile
    ./scripts/install-app

Switch the running app to Slug and drive workloads via the scroll-debug server
(launch arg `--scroll-debug`, default port 8787):

    curl -X POST 'http://127.0.0.1:8787/config/renderer?name=slugGlyph'
    curl 'http://127.0.0.1:8787/scroll/present-stats'

GPU trace baseline and comparison (xctrace may print a benign "log archive
corrupt" warning; the bundle still analyzes, see
`docs/process/profiling-hiccups.md`):

    scripts/analyze-metal-trace --record 10 --attach Laban \
      --json-output .build/slug-baseline.json
    scripts/analyze-metal-trace --record 10 --attach Laban \
      --baseline .build/slug-baseline.json --fail-on-regression   # exit 3 = regression
    scripts/analyze-metal-trace <trace> --cpu-only                # CPU attribution

Headless screenshot and capture replay:

    .build/debug/laban-agent --headless --debug-server=127.0.0.1:0 \
      --artifacts=.artifacts/slug-perf \
      --capture=slug-perf-baseline --capture-screenshots=final
    # GET /debug/screenshot on the printed port; renderer must be slugGlyph
    ./scripts/replay-capture <capture-dir> --mode=renderer

## Validation and Acceptance

Phrased as behavior:

1. After M1: `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter
   SlugGlyphFrameTimeBench` prints a full-screen CPU-encode p50 lower than the
   M0 number recorded in Artifacts and Notes (delta beyond the 5-run noise
   band), and `swift test --filter SlugGlyph` reports 0 failures.
2. After M2: the typing workload's CPU-encode and wall p50 drop materially vs
   M0 (record the numbers), `SlugGlyphDamageTests` passes (partial output
   byte-identical to full across ring ages, cursor blink confined to cursor
   rects, zoom forces full), and a 10 s scroll trace compared against
   `.build/slug-baseline.json` with `--fail-on-regression` does not exit 3.
3. After M3: the plan contains a metric table for sample counts 2/4/8 at 9 and
   11 pt, and either the size-dependent sample count is landed with green
   fidelity/bench gates or the discard is recorded with evidence.
4. After M4 (if entered): the new-glyph-burst workload's CPU-encode p50 drops
   materially vs the pre-M4 baseline (record the numbers), incremental
   buffer growth is proven byte-identical to a fresh single-shot upload
   across a capacity-doubling boundary, and `geometryBufferUploadCount`
   semantics stay intact (zoom does not re-upload).
5. Throughout: renderer replay of the M0 capture stays byte-identical, and the
   existing Slug test suites (`SlugGlyphCorrectnessTests`,
   `SlugGlyphAAFidelityTests`, `SlugWeightCoreTextParityTests`) stay green.

## Decision Log

- Decision: per-ring-slot accumulated damage rather than a persistent canvas
  texture plus full-frame blit.
  Rationale: avoids a fourth full-resolution texture and a ~30 MB copy per
  frame; matches standard swapchain-age practice; MetalRenderer proves
  scissored partial redraw is sound and the ring only adds age bookkeeping. If
  a correctness issue emerges that the damage tests cannot pin down, fall back
  to canvas-plus-blit and record it here.
  Date/Author: 2026-07-05 / plan author.
- Decision: keep whole-texture `.clear` on the accumulate textures during
  partial frames; scissor only draws and composites.
  Rationale: attachment clears are tile operations on Apple GPUs (effectively
  free), and correctness holds because the composite reads accumulate texels
  only inside the scissor.
  Date/Author: 2026-07-05 / plan author.
- Decision: every CPU-side change is gated on a directly measured CPU-encode
  delta, and below-noise changes are reverted even when "obviously good".
  Rationale: the vector encode-loop plan declined both its buffer-ring (M1)
  and ASCII fast path (M3) on exactly this basis; Slug shares the same
  GPU/present-bound risk profile.
  Date/Author: 2026-07-05 / plan author.
- Decision: adopt exact per-band damage (`DirtyYRangeSet`, per-band scissors)
  instead of MetalRenderer's union-bounding-box approach, taking only the
  y-space half of the out-of-repo DirtyRowSet proposal and none of its
  row-space migration (TerminalSurfaceController, laband ring,
  TerminalCellPayload).
  Rationale: Slug's per-ring-slot accumulation over a 3-frame window makes
  disjoint dirty bands the common case (cursor row plus a status line), and a
  union collapses that to near-full-screen, forfeiting most of the fragment
  savings; the row-space migration is a cross-layer refactor with its own
  blast radius, orthogonal to Slug, and its plan predates current line
  numbers. The type is placed renderer-neutral so that refactor can adopt it
  later. Slug redraw is deterministic into cleared accumulate textures, so
  exact banding here is a cost optimization, not the correctness fix the
  proposal needed for MetalRenderer's persistent target.
  Date/Author: 2026-07-05 / plan author.
- Decision: absorb only the headless-selectability slice of the dormant
  `slug-glyph-renderer.md` M5, not its broader menu/ship parity.
  Rationale: this plan's acceptance requires headless Slug screenshots; the
  rest of M5 is product-parity work unrelated to perf/quality and stays with
  the old plan.
  Date/Author: 2026-07-05 / plan author.
- Decision: M3's small-size probes landed as a new, separate,
  `LABAN_RUN_PERF_BENCH`-gated print-only file
  (`SlugGlyphSmallSizeAAProbeBench.swift`) instead of extending
  `SlugGlyphAAFidelityTests.swift` with hard assertions.
  Rationale: at the time these probes were written, the right tolerance
  band was unknown (that is what the probes were for), and the outcome was
  "discard" — landing hard-gated assertions pinned to a sample count that was
  reverted would either assert against the wrong (discarded) configuration or
  need immediate deletion. A print-only exploration file mirrors the existing
  `SlugGlyphFrameTimeBench.swift` convention and stays as a reusable probe for
  any future revisit of this question without carrying assertion maintenance
  cost for a milestone that answered "no change."
  Date/Author: 2026-07-05 / plan author.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan
done until this gate passes. Per-milestone reviews may check the subset marked
for that milestone.

- [ ] `swift test --filter SlugGlyph` exits 0. (M1, M2, M3)
- [ ] `swift test --filter SlugWeightCoreTextParityTests` exits 0. (M1, M3)
- [ ] `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter
      SlugGlyphFrameTimeBench` exits 0 and its output contains p50/p95/p99
      lines for a typing workload and a cursor-blink workload. (M0)
- [ ] `grep -n 'containsCJK(String(cluster))'
      Sources/LabanRenderer/SlugGlyphRenderer.swift` returns zero hits. (M1)
- [ ] `grep -n 'textMayContainColor'
      Sources/LabanRenderer/SlugGlyphRenderer.swift` returns at least one hit.
      (M1)
- [ ] `grep -n 'case .partial' Sources/LabanRenderer/SlugGlyphRenderer.swift`
      returns at least one hit. (M2)
- [ ] `swift test --filter SlugGlyphDamageTests` exits 0 and the file contains
      a test exercising at least 4 consecutive partial frames. (M2)
- [ ] `grep -n 'setScissorRect' Sources/LabanRenderer/SlugGlyphRenderer.swift`
      returns at least one hit. (M2)
- [ ] `test -f Sources/LabanRenderer/DirtyYRangeSet.swift` exits 0 and
      `swift test --filter DirtyYRangeSetTests` exits 0. (M2)
- [ ] `grep -n 'import' Sources/LabanRenderer/DirtyYRangeSet.swift` shows no
      import beyond CoreGraphics/Foundation, and the file contains no
      Slug-prefixed identifier. (M2)
- [ ] `git diff Sources/LabanRenderer/VectorGlyphShaders.metal` is empty (the
      M3 sample-count define is confirmed back at its default of 2). (M3)
- [ ] `swift test --filter SlugGlyphIncrementalGeometryUploadTests` exits 0.
      (M4)
- [ ] The plan's Artifacts and Notes section contains recorded baseline and
      post-change bench numbers for every landed milestone, and the Progress
      checkboxes match the actual state of the working tree. (all)

Review status: NOT REVIEWED

## Idempotence and Recovery

Every milestone is additive and independently revertible by git. Benches,
tests, traces, and captures are re-runnable; re-recording a baseline is safe
(overwrite `.build/slug-baseline.json`). If a partial-damage defect ships, the
immediate mitigation is a one-line guard forcing `.full` at the top of
`render()` while diagnosing; `SlugGlyphDamageTests` then pins the fix. M3's
shader define edits must never be left in a non-default state on a discard
(restore `kSlugAreaAASampleCount` to 2 before closing the milestone).

## Interfaces and Dependencies

No new external dependencies. End state per milestone:

- M1: `TerminalCJKFontPolicy` gains a `Character`-or-scalar-level CJK check
  (no `String` construction on the per-cell path);
  `SlugGlyphRenderer` caches the color trait with its styled-variant usage and
  interns font identity to an `Int` for the per-cell resolve cache.
- M2: `SlugGlyphRenderer.render(_:damage:)` honors
  `RenderDamage.partial(yRanges:)` including the empty-array re-present
  semantics; per-slot accumulators and cursor/zoom snapshots are private to
  the renderer; no `RendererBackend` protocol change. One new public type:

      public struct DirtyYRangeSet: Equatable, Sendable {
        public private(set) var ranges: [DirtyYRange]
        public init(_ ranges: [DirtyYRange])   // normalizes: drops height <= 0,
                                               // sorts by y, merges overlapping/
                                               // adjacent bands (epsilon 0.0001)
        public var isEmpty: Bool
        public func union(_ other: DirtyYRangeSet) -> DirtyYRangeSet
        public func overlaps(y: CGFloat, height: CGFloat) -> Bool  // false for
                                               // non-positive height; exact per
                                               // band, no min/max collapse
      }

  in `Sources/LabanRenderer/DirtyYRangeSet.swift`, renderer-neutral (imports
  `CoreGraphics` only, no Slug types), so other backends can migrate later.
- M3: no shipped interface change. Explored shader-side promotion (sample
  count selected from existing `unitsPerPixel`) but discarded on evidence;
  `kSlugAreaAASampleCount` stays fixed at 2. See M3 results.
- M4: no `SlugGlyphRenderer` public-interface change;
  `geometryBufferUploadCount`'s existing semantics (increments once per
  `render()` call that pushes new geometry bytes) are preserved unchanged.
- M0: `HeadlessDebugRuntime` can select `slugGlyph` (only if it cannot today).

## Artifacts and Notes

### M0 baseline (2026-07-05)

Bench command:

    LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugGlyphFrameTimeBench

Machine note: this run shares the box with an active Cursor/agent session, so
the existing full-screen 120 Hz gate (`testSlugRendererFrameTimeFullScreenIs120HzFlatAcrossPointSize`)
read OVER budget at all three point sizes (wall p99 10.5-15.7 ms vs the 8.33 ms
budget); re-running on a clean stash of the same commit still failed
intermittently (1-3 of 3 sizes OVER, numbers 7.1-9.1 ms). This is pre-existing
machine-load flakiness in a full-screen gate outside this plan's scope (typing/
cursor-blink/partial damage), not a regression introduced here. Treat the
CPU-encode numbers below (measured with `waitForFrameCompletion = false`,
isolated from GPU/present contention) as the more load-independent signal for
M1 comparisons.

**Power-state correction (2026-07-05, later same day):** the numbers below
were recorded while this machine was running on battery, which (confirmed via
`pmset -g batt` / `lowpowermode` after the fact) most likely had macOS Low
Power Mode engaged — this throttles CPU/GPU clocks system-wide independent of
which app is frontmost. Once plugged into AC power with Low Power Mode off,
re-measuring the identical pre-M1 code (via `git stash` of the M1 diff, same
bench, same machine) gave grayscale cpu-encode p50s roughly 25-30% lower than
recorded here (e.g. typing 1.51 ms vs 2.06 ms below) with much tighter p95/p99
spread. The numbers below are kept as the historical record of what M0
observed, but **M1's acceptance comparison uses a freshly re-measured,
power-controlled pre-M1 baseline** (see M1 Artifacts below) rather than these
numbers, because the two were not recorded under comparable conditions. RGB
subpixel numbers are dominated by the accumulate/composite GPU passes and are
much less sensitive to this effect (M1's before/after subpixel numbers stayed
within noise of each other either way, as expected since M1 only touches
per-cell CPU cost). Lesson for future milestones: confirm AC power and Low
Power Mode off (`pmset -g batt`) before recording any baseline this plan will
diff against, and prefer interleaved A/B (`git stash`/`pop` around single runs
of the same bench invocation, alternating) over separated before/after runs to
cancel out any remaining ambient load drift.

Typing workload (one dirty row/frame, 200 frames, 160x48 grid, scale 2):

| mode | cpu-encode p50/p95/p99 ms | wall p50/p95/p99 ms |
| --- | --- | --- |
| grayscale | 2.062 / 2.449 / 2.973 | 4.882 / 8.518 / 8.893 |
| rgbStripe | 17.961 / 24.026 / 26.165 | 19.350 / 23.149 / 24.721 |

Cursor-blink workload (empty `.partial`, 200 frames):

| mode | cpu-encode p50/p95/p99 ms | wall p50/p95/p99 ms |
| --- | --- | --- |
| grayscale | 3.487 / 6.260 / 14.570 | 5.835 / 9.105 / 10.660 |
| rgbStripe | 17.779 / 23.745 / 25.827 | 18.532 / 30.405 / 35.602 |

New-glyph-burst workload (~20 new glyphs/frame, 200 frames; M4 gate):

| mode | cpu-encode p50/p95/p99 ms | wall p50/p95/p99 ms |
| --- | --- | --- |
| grayscale | 7.171 / 12.117 / 23.288 | 11.652 / 15.512 / 16.298 |
| rgbStripe | 13.870 / 21.935 / 24.675 | 23.411 / 29.945 / 33.011 |

Reading for M4: the grayscale burst cpu-encode p99 (23.3 ms) is far above its
p50 (7.2 ms) — a real spike consistent with `ensureGeometryBuffersIfNeeded`'s
full-array re-upload. **M4 is entered** on this evidence (see M4 section).

Full-screen (unchanged full redraw, all rows dirty) and CJK full-screen, for
context (same command, existing test methods, machine caveat above applies to
wall numbers):

| workload | size | wall p50/p95/p99 ms | verdict |
| --- | --- | --- | --- |
| full-screen ASCII | 9 pt | 5.652 / 9.205 / 10.549 | OVER (load-noise, see caveat) |
| full-screen ASCII | 14 pt | 5.916 / 9.593 / 11.581 | OVER (load-noise, see caveat) |
| full-screen ASCII | 28 pt | 7.812 / 11.039 / 15.685 | OVER (load-noise, see caveat) |
| full-screen CJK | 14 pt | 1.833 / 3.753 / 4.305 | PASS |

Headless `slugGlyph` selectability (M0 item 3): confirmed already wired
end-to-end (`RendererSelection.slugGlyph` existed, `HeadlessDebugRuntime`
already accepted it via `--renderer=slugGlyph` and the `setRenderer` debug
action). The only real bug was that `POST /debug/snapshot` and
`POST /debug/artifact-snapshot` read screenshots from the runtime's internal
`SoftwareBackend`-only `surface` field instead of the active
`rendererBackend`, so Slug (and every other non-software backend) produced a
blank screenshot. Fixed in `Sources/LabanDebug/DebugCaptureEndpoints.swift`
and `Sources/LabanDebug/DebugArtifactEndpoints.swift` (read
`rendererBackend.pngData`/`.surfaceWidth`/`.surfaceHeight`). Verified via
`GET /debug/screenshot` and `POST /debug/snapshot` against a
`--renderer=slugGlyph` headless agent: both return a non-blank 920x456 PNG
showing the sidebar tab, prompt, and cursor rendered by Slug.

Capture-replay baseline (M0 item 4): recorded at
`.artifacts/slug-perf/captures/slug-perf-baseline` (25 frames; typed
`echo hello world` + `ls -la`). `./scripts/replay-capture --mode=terminal
.artifacts/slug-perf/captures/slug-perf-baseline` reports
`"terminalReplay":"passed"`, 25 frames compared, 0 mismatches.
`--mode=renderer` is **not usable for Slug**: `CaptureReplayRunner.runRendererReplay`
hardcodes a fresh `SoftwareRenderer` for its replay regardless of the
capturing backend, so it always reports a `rendererScreenshotHash` mismatch
against a Slug-recorded `pixelHash`, even on a clean baseline (verified). The
per-frame `frame-*.render.json` sidecars still carry the true Slug
`pixelHash` recorded at capture time (`backend:"slugGlyph"`), which is what
"renderer replay of the M0 capture byte-identical" (M1/M2 acceptance) means in
practice. `Tests/LabanDebugTests/SlugGlyphCaptureReplayTests.swift` is the
committed mechanism: it records its own short `slugGlyph` capture in-process
via `HeadlessDebugRuntime`, then replays every frame's command list through a
fresh `SlugGlyphRenderer` and asserts the PNG hash matches the hash recorded
at capture time. Run it (`swift test --filter SlugGlyphCaptureReplayTests`)
before and after M1/M2 changes as the byte-identical gate; it passes on the
M0 baseline.

GPU trace baseline (M0 item 2): **deferred, needs a manual step.** Per
`docs/process/agent-operating-guide.md` and this plan's Invariants, an agent
must not launch `Laban.app` via `open` from a shell; the user launches it. A
profile build was installed (`./scripts/install-app`, commit `51771c0+dirty`)
so the trace can be captured as soon as the app is running:

    scripts/analyze-metal-trace --record 10 --attach Laban --json-output .build/slug-baseline.json

Ask the user to launch/relaunch `~/Laban.app`, switch it to `slugGlyph`
(`curl -X POST 'http://127.0.0.1:8787/config/renderer?name=slugGlyph'` with
`--scroll-debug` armed) and scroll, then this command records the baseline.
Recorded here once captured; M2's GPU trace comparison depends on this file
existing.

### M1 results (2026-07-05)

Implemented all four work items in `appendGlyphRun`/`ensureGlyph`/`render()`:
run-level color gate (`runWantsColor`, cached `fontHasColorTrait`), run-level
CJK pre-gate (`runMayContainCJK` plus a new allocation-free
`TerminalCJKFontPolicy.containsCJK(Character)` overload), font-identity
interning (`SlugFontIdentityKey` -> `Int`, `SlugGlyphResolveKey` now
`(fontID, Character)` instead of re-hashing a `String` per cell), and
`reserveCapacity` on the four instance arrays using the previous frame's
counts.

Correctness: `swift test --filter SlugGlyph` (44 tests, includes
`SlugGlyphCorrectnessTests`, `SlugGlyphAAFidelityTests`,
`SlugGlyphCaptureReplayTests`, `SlugGlyphFrameTimeBench`) and
`swift test --filter SlugWeightCoreTextParityTests` both green, 0 failures.
`SlugGlyphCaptureReplayTests` (the M0 capture's byte-identical replay gate)
passes with M1 applied.

Review-gate greps: `grep -n 'containsCJK(String(cluster))'
Sources/LabanRenderer/SlugGlyphRenderer.swift` returns zero hits;
`grep -n 'textMayContainColor' Sources/LabanRenderer/SlugGlyphRenderer.swift`
returns one hit.

Performance: measured with a fresh, power-controlled baseline (AC power,
`lowpowermode 0`, confirmed via `pmset`), using interleaved A/B (`git stash`
the M1 diff, run, `git stash pop`, run again, repeat) to cancel ambient load
drift, 200-frame workloads, `-c release`. Full-screen CPU-encode is the
plan's M1 acceptance metric (measured by a new print-only
`testSlugFullScreenCPUEncodeIsMeasured`, since M0 only recorded full-screen
*wall* time; see Decision Log):

| workload (grayscale) | pre-M1 cpu-encode p50 | post-M1 cpu-encode p50 | delta |
| --- | --- | --- | --- |
| full-screen (3 interleaved pairs) | 1.514 / 1.502 / 1.491 ms | 1.031 / 0.984 / 1.009 ms | ~-33%, zero overlap across all 3 pairs |
| typing (1 dirty row/frame) | 1.513 / 1.510 ms | 0.985 / 1.036 ms | ~-33% |
| cursor-blink (empty partial) | 1.543 / 1.525 ms | 1.020 / 1.013 ms | ~-34% |
| new-glyph-burst (~20 new glyphs/frame) | 5.136 / 5.265 ms | 4.614 / 4.562 ms | ~-12% |

Wall p50 (grayscale) moved with it: typing 3.98 ms to 3.33 ms, cursor-blink
4.05 ms to 3.46 ms, new-glyph-burst ~7.2 ms to ~6.6 ms.

RGB-subpixel (`rgbStripe`) numbers stayed flat within noise before/after
(full-screen ~12.5 ms both sides, typing ~12.2-12.6 ms both sides,
cursor-blink ~12.3-12.6 ms both sides, burst ~13.2 ms pre vs ~12.2-12.8 ms
post) — expected, since the accumulate/composite GPU passes dominate subpixel
mode and M1 only touches per-cell CPU cost. This confirms the plan's M1
acceptance ("full-screen CPU-encode p50 lower than the M0 number... beyond
the noise band") on the corrected baseline: three tightly-clustered
interleaved pairs with no overlap between the pre- and post-M1 ranges is
stronger evidence than the plan's suggested 5 separated runs.

New-glyph-burst's p99 spike relative to p50 persists after M1 (pre: p50 5.1-5.3
ms, p99 16-30 ms; post: p50 4.6 ms, p99 16-17 ms) — M1 shaved the per-cell
baseline cost but did not touch `ensureGeometryBuffersIfNeeded`'s full-array
re-upload, so **M4 stays entered** on this evidence too.

Decision: added `testSlugFullScreenCPUEncodeIsMeasured` to
`SlugGlyphFrameTimeBench.swift` because M0 only measured full-screen *wall*
time (the existing 120 Hz gate), not CPU-encode, and the M1 acceptance
criterion is phrased in terms of full-screen CPU-encode p50. The new test
mirrors the existing `timeRun` machinery against 200 identical full-screen
ASCII frames with `.full` damage, `waitForFrameCompletion = false`, print-only,
gated behind `LABAN_RUN_PERF_BENCH=1`.
Date/Author: 2026-07-05 / plan author.

### M2 results (2026-07-05)

Implemented the design as specified: `DirtyYRangeSet` (new file, see below),
per-ring-slot `DirtyYRangeSet` accumulators plus a sticky `slotNeedsForceFull`
flag (`resolveEffectiveDamage` in `SlugGlyphRenderer.swift`), previous-cursor-
rect tracking unioned into incoming damage (`cursorDamage`), a force-full
snapshot of `gestureZoom`/`gestureZoomAnchor`/`effectiveSubpixelLayout`/
`textWeight`/`emojiRenderingMode` (`configChangedSincePreviousFrame`/
`snapshotConfigForNextFrame`), an empty-effective-damage fast path that skips
encoding and ring rotation but still republishes the latest target and calls
`onFrameCompleted`, and per-band `MTLScissorRect` application
(`SlugScissorPlan`/`repeatingBands`) across the accumulate pass, the content
pass (solids, direct-glyph, subpixel composite x2, coverage/color fallback x2),
and the raster/color fallback passes. The content target's load action
switches `.clear` (full) to `.load` (partial), matching the plan; the
subpixel accumulate textures keep unconditional whole-texture `.clear`.
`ensureTargetTexture()` was split into a pure `peekNextRingSlot()` query and a
mutating `commitRingSlot()` so the empty-damage path can decide to skip before
committing to a ring rotation.

**Stage B (CPU-side command filtering) was not entered.** Per the plan's own
gate ("If stage A already makes typing cheap enough that stage B is below
noise, record that and skip it"), stage A's wall-time win already satisfies
the M2 acceptance criterion (see below); CPU-encode for grayscale typing/
cursor-blink did not regress, so there is no material CPU cost left to cut by
filtering commands. Skipping stage B also avoids the exact-band CPU filtering
complexity the plan flagged as risky (a naive union filter would rebuild every
row between two distant dirty rows).

Correctness: new `Tests/LabanRendererTests/SlugGlyphDamageTests.swift` (6
tests: byte-identical partial-vs-full redraw, 4+ consecutive partial frames
across ring ages, sparse dirty bands leaving rows between them untouched,
cursor blink via empty partial confined to cursor cells, gesture-zoom forcing
full redraw, empty effective damage not rotating the ring) — all green. Full
`swift test --filter LabanRendererTests` (skipping the pre-existing unrelated
`VectorZoomGlyphSizeConsistencyTests` flake, see Surprises below): 292 tests,
0 failures. Full `swift test --filter LabanDebugTests` (skipping the
pre-existing `DiscoveryEndpointParityTests` failure, see M0/M1 history): 213
tests, 0 failures, including `SlugGlyphCaptureReplayTests` (the M0 capture's
byte-identical replay gate stays green with M2 applied).

Review-gate greps: `grep -n 'case .partial'
Sources/LabanRenderer/SlugGlyphRenderer.swift` returns 2 hits;
`grep -n 'setScissorRect' Sources/LabanRenderer/SlugGlyphRenderer.swift`
returns 1 hit; `Sources/LabanRenderer/DirtyYRangeSet.swift` exists, imports
only `CoreGraphics`/`Foundation`, and contains no Slug-prefixed identifier
(one doc-comment mention of `SlugGlyphRenderer` for context, not an
identifier).

Performance: measured with the same interleaved A/B methodology as M1 (AC
power, `lowpowermode 0` confirmed via `pmset`; `git stash`/`pop` the M2 diff
around paired runs of the same bench invocation), 200-frame typing and
cursor-blink workloads, `-c release`, 2 interleaved pairs:

| workload (grayscale) | pre-M2 cpu-encode p50 | post-M2 cpu-encode p50 | pre-M2 wall p50 | post-M2 wall p50 |
| --- | --- | --- | --- | --- |
| typing (pair 1) | 1.029 ms | 0.882 ms | 3.230 ms | 1.780 ms |
| typing (pair 2) | 1.014 ms | 0.942 ms | 3.254 ms | 1.874 ms |
| cursor-blink (pair 1) | 1.015 ms | 0.906 ms | 3.257 ms | 1.809 ms |
| cursor-blink (pair 2) | 0.998 ms | 0.933 ms | 3.234 ms | 1.826 ms |

| workload (rgbStripe) | pre-M2 cpu-encode p50 | post-M2 cpu-encode p50 | pre-M2 wall p50 | post-M2 wall p50 |
| --- | --- | --- | --- | --- |
| typing (pair 1) | 12.052 ms | 1.096 ms | 13.008 ms | 2.660 ms |
| typing (pair 2) | 12.050 ms | 1.052 ms | 12.620 ms | 2.678 ms |
| cursor-blink (pair 1) | 12.250 ms | 0.973 ms | 12.680 ms | 2.135 ms |
| cursor-blink (pair 2) | 12.180 ms | 1.041 ms | 12.694 ms | 2.195 ms |

Reading: wall p50 for both workloads dropped ~42-44% in grayscale and
~79-83% in rgbStripe — consistent with theory, since scissoring cuts fragment
work to 1-2 rows instead of the full screen, and subpixel mode's
accumulate-plus-two-composite full-screen passes were the larger GPU cost to
begin with. Grayscale cpu-encode improved modestly (~8-14%); rgbStripe
cpu-encode dropped by roughly 12x at p50 while p95/p99 stayed near the old
full-frame cost (12-15 ms) in both pairs — see Surprises & Discoveries for the
unresolved part of this. Full-screen scroll (all rows dirty, forces `.full`)
is unchanged by design: `testSlugRendererFrameTimeFullScreenIs120HzFlatAcrossPointSize`
and `testSlugRendererCJKFrameTimeFullScreenIsMeasured` numbers stayed within
the same range as M0/M1 (9/14/28 pt wall p50 2.5-3.8 ms both before and after
M2 in this run).

GPU trace comparison against `.build/slug-baseline.json` remains blocked on
the same manual app-launch step as M0 (see M0 Artifacts); not re-attempted
here.

Surprises & Discoveries:

- The rgbStripe cpu-encode p50 drop (~12 ms to ~1 ms) is larger than stage
  A's design predicts: stage A only scopes GPU fragment work, and CPU-encode
  timing (`waitForFrameCompletion = false`) should in theory track the CPU
  instance-build cost, which stage A does not touch (stage B was not
  entered). The bimodal pattern — low p50, p95/p99 still near the old
  full-frame ~13-15 ms — reproduced identically across both interleaved
  pairs, so it is a real, consistent effect of the code change and not run
  noise, but the exact mechanism (most likely something in Metal's CPU-side
  encoding cost for a 2-attachment `rgba16Float` MRT pass scaling with
  scissored vs. full tile coverage) was not root-caused. Treat the wall-time
  numbers above as the primary, well-understood evidence for M2's win; the
  cpu-encode rgbStripe number is recorded as an observed bonus, not a
  claimed, understood mechanism.
- `VectorZoomGlyphSizeConsistencyTests.testGlyphSizesStaySingleAcrossZoomCommits`
  fails (12 assertion failures, "renderer never produced a non-dropped frame")
  on a clean tree at commit `44fcc0b`, i.e. before any M2 change — verified by
  stashing all M2 work (including untracked files via `git stash -u`) and
  re-running in isolation. This is `VectorGlyphRenderer` drawable-scheduling
  flakiness unrelated to `SlugGlyphRenderer`/M2 and out of this plan's scope;
  not investigated further here.

### M2 correction (2026-07-09): force-full drain dropped interleaved partial damage

The M2 implementation violated its own accumulation invariant ("union each
incoming frame's damage into every slot's accumulator"): the
`slotNeedsForceFull` early return in `resolveEffectiveDamage` ran *before*
the all-slots union, so a partial-damage frame landing on a still-flagged
slot rendered full (correct on screen) but never recorded its bands for the
other two slots. Any `.full` frame re-flags all three slots and the flags
drain one per frame, so content that alternates `.full` and `.partial` —
scrolling command output with `\r`-rewritten progress lines (git pull), or a
fullscreen TUI interleaving whole-screen repaints with spinner updates —
dropped the partials' bands for the two undrained slots. One ring revolution
later those rows reverted to that slot's stale content, then healed on the
next dirtying: the visible "rendered, undone, re-rendered" flicker. Diagnosed
from capture `appkit-2026-07-09T20-15-24Z` (355 pixel-hash changes across
same-visible-hash frame pairs, in runs of 3-5 distinct pixel states — more
than cursor blink can produce). Fix: accumulate into every slot first, then
take the force-full early return. Second, `render()` consumes a slot's
accumulator and force-full flag before the backpressure/allocation failure
guards; the GPU-backpressure park path (`TerminalBitmapView.swift`,
`backpressureInvalidationDecision.shouldPark`) can clear `renderInvalidated`
without a retry, stranding the consumed damage. `render()` now restores the
consumed damage (partial bands rejoin the accumulator; a consumed `.full`
re-flags the slot) on every non-committed exit. Regression test:
`testPartialDamageDuringForceFullDrainIsNotDroppedForOtherSlots` interleaves
partials into the middle of a force-full drain and requires the next
genuinely partial frame to be byte-identical to a full redraw; it fails
without the reorder (both grayscale and rgbStripe) and passes with it.

### M3 results (2026-07-05): answered no

Added a print-only exploration harness,
`Tests/LabanRendererTests/SlugGlyphSmallSizeAAProbeBench.swift` (gated behind
`LABAN_RUN_PERF_BENCH=1`, mirrors the existing bench-gating convention),
measuring Slug-vs-`SoftwareBackend` fidelity (ink-mass delta, mean-gradient
ratio, edge-pixel-ratio delta, mean edge chroma, mean coverage spread) at 9
and 11 pt, scales 1 and 2, grayscale and `calibratedRGB`, on a themed probe.
A/B'd `kSlugAreaAASampleCount` (`VectorGlyphShaders.metal:654`) at 2
(baseline), 4 (standard RGSS rotated-grid pattern), and 8 (standard D3D/Vulkan
fixed 8-sample pattern) by editing the shader define and its sample array,
rebuilding (`swift build --target LabanRenderer`), and re-running the probe
between each.

| pt | scale | mode | samples | ink %Δ vs software | mean-grad ratio | edge-ratio %Δ | edge chroma | coverage spread |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 9 | 1 | grayscale | 2 | 14.49% | 0.897 | -0.83% | 16.65 | 0.0274 |
| 9 | 1 | grayscale | 4 | 16.23% | 0.854 | -0.64% | 16.95 | 0.0272 |
| 9 | 1 | grayscale | 8 | 17.23% | 0.842 | -0.57% | 17.09 | 0.0268 |
| 9 | 1 | calibratedRGB | 2 | 12.68% | 0.919 | -1.21% | 41.72 | 0.1849 |
| 9 | 1 | calibratedRGB | 4 | 14.64% | 0.889 | -0.70% | 39.16 | 0.1726 |
| 9 | 1 | calibratedRGB | 8 | 15.26% | 0.881 | -0.70% | 38.60 | 0.1696 |
| 9 | 2 | grayscale | 2 | 14.17% | 1.074 | 10.63% | 17.05 | 0.0198 |
| 9 | 2 | grayscale | 4 | 14.91% | 1.065 | 11.05% | 17.19 | 0.0196 |
| 9 | 2 | grayscale | 8 | 15.13% | 1.062 | 11.14% | 17.26 | 0.0196 |
| 9 | 2 | calibratedRGB | 2 | 13.42% | 1.081 | 10.48% | 34.51 | 0.1372 |
| 9 | 2 | calibratedRGB | 4 | 14.04% | 1.073 | 10.89% | 33.39 | 0.1323 |
| 9 | 2 | calibratedRGB | 8 | 14.19% | 1.072 | 10.99% | 33.12 | 0.1305 |
| 11 | 1 | grayscale | 2 | 11.27% | 0.998 | 5.75% | 16.67 | 0.0236 |
| 11 | 1 | grayscale | 4 | 12.73% | 0.966 | 6.30% | 16.91 | 0.0233 |
| 11 | 1 | grayscale | 8 | 13.17% | 0.958 | 6.24% | 17.03 | 0.0234 |
| 11 | 1 | calibratedRGB | 2 | 10.13% | 1.016 | 5.58% | 38.28 | 0.1615 |
| 11 | 1 | calibratedRGB | 4 | 11.06% | 0.995 | 6.18% | 37.28 | 0.1573 |
| 11 | 1 | calibratedRGB | 8 | 11.53% | 0.989 | 6.18% | 36.87 | 0.1553 |
| 11 | 2 | grayscale | 2 | 9.43% | 1.210 | -5.28% | 17.02 | 0.0154 |
| 11 | 2 | grayscale | 4 | 9.79% | 1.202 | -4.82% | 17.14 | 0.0155 |
| 11 | 2 | grayscale | 8 | 10.16% | 1.197 | -4.82% | 17.25 | 0.0153 |
| 11 | 2 | calibratedRGB | 2 | 8.88% | 1.208 | -5.33% | 30.82 | 0.1073 |
| 11 | 2 | calibratedRGB | 4 | 9.31% | 1.198 | -4.86% | 30.03 | 0.1040 |
| 11 | 2 | calibratedRGB | 8 | 9.59% | 1.199 | -4.86% | 29.95 | 0.1034 |

Reading: every metric is essentially flat from 2 to 4 to 8 samples (values
converge by 4, 8 adds nothing further), and where anything moves, it moves
*away* from the software envelope, not toward it (ink-mass delta increases
monotonically with sample count at every size/scale/mode combination tested).
This says the small-size fidelity gap versus `SoftwareBackend`/CoreText is not
caused by insufficient edge-sample density — `slugGlyphAreaCoverage`'s single
analytic center sample already resolves the edge correctly; adding more
samples of the same analytic function just re-samples the same (correct)
answer and cannot fix a gap whose source is elsewhere (most likely CoreText's
hinting/rendering differing systematically from Slug's unhinted analytic
outlines at small ppem, which is out of this plan's scope to chase further).

Cost check confirms the same conclusion from the other direction: full-screen
bench (`-c release`, `testSlugRendererFrameTimeFullScreenIs120HzFlatAcrossPointSize`)
at 8 samples measured wall p50/p95/p99 of 4.10/4.73/5.59 ms (9 pt), 6.07/7.47/7.60
ms (14 pt), 6.96/8.49/9.21 ms (28 pt) — roughly 2x the 2-sample baseline
(M0/M1/M2 runs measured 2.5-3.8 ms p50 across the same sizes), and 28 pt
verdict flips to OVER the 8.33 ms/120 Hz budget. Per the plan's promotion
gate ("(a) at least one small-size metric moves toward the software envelope
... and (b) full-screen bench p99 stays at or under 8.33 ms"), neither
condition holds, so promotion criterion (a) alone is sufficient to decide
against landing a size-dependent sample count; (b)'s budget violation would
have blocked it even if (a) had passed.

Decision: **discarded.** `kSlugAreaAASampleCount` and its sample array in
`Sources/LabanRenderer/VectorGlyphShaders.metal` are confirmed restored to
the original 2-sample definition (`git diff` on that file is empty). The
milestone is answered rather than left open: the sample-count question is
closed with evidence, not merely deferred.
Date/Author: 2026-07-05 / plan author.

### M4 results (2026-07-05): landed

`ensureGeometryBuffersIfNeeded` (`SlugGlyphRenderer.swift`) now tracks a
per-array uploaded-element count (`curveBufferUploadedCount`/
`glyphBufferUploadedCount`/`bandBufferUploadedCount`/
`bandIndexBufferUploadedCount`) alongside each `MTLBuffer`, via a new generic
`ensureIncrementalBuffer<T>` helper: when the existing buffer's capacity
already covers the array's current count, only the newly appended tail
(`values[uploadedCount...]`) is memcpy'd in at the right offset; capacity
only grows (starting at 1024 elements, doubling) when the array has outgrown
the buffer, and a doubling reallocates fresh and re-copies from the CPU-side
array (the source of truth) rather than migrating bytes from the old,
smaller buffer. `bandIndices`' pre-existing empty-array placeholder fallback
(before the first glyph's bands exist) is kept as a separate, non-incremental
branch so that defensive, in-practice-unreachable edge case cannot corrupt
the tracked count. `geometryBufferUploadCount` keeps its exact pre-M4
semantics (incremented once per `render()` call that actually pushed new
geometry bytes, regardless of whether that was a tail-append or a
reallocation-copy), since the existing zoom/point-size tests assert it stays
flat when no new glyph is introduced.

Correctness: new `Tests/LabanRendererTests/SlugGlyphIncrementalGeometryUploadTests.swift`
(2 tests):
`testIncrementalBufferGrowthMatchesFreshSingleShotUpload` introduces 800 new
glyphs across 40 frames (comfortably forcing multiple capacity-doubling
reallocations on all four arrays, since `bands` alone grows by 128 elements
per glyph against a 1024-element starting capacity), then renders a final
frame with every introduced glyph and asserts its `pngData` hash is
byte-identical to a *fresh* renderer given only that final frame in one shot
(single-allocation upload, no incremental growth) — proving tail-append and
capacity-doubling-reallocate produce exactly the same buffer contents as a
from-scratch upload, regardless of how they got there.
`testGestureZoomStillDoesNotTriggerGeometryUpload` re-asserts the existing
"zoom never re-uploads geometry" contract holds under the new incremental
path. Both pass. Full `swift test --filter SlugGlyph` (53 tests, up from 51):
0 failures, including the pre-existing `geometryBufferUploadCount` zoom/
point-size tests in `SlugGlyphRendererTests.swift` (M4 does not change their
semantics) and the M0 capture's byte-identical replay gate
(`SlugGlyphCaptureReplayTests`).

Performance: interleaved A/B (`git stash -u`/`pop` around paired runs, same
methodology as M1/M2), `-c release`, new-glyph-burst workload (200 frames,
~20 previously-unseen glyphs/frame), 2 pairs:

| mode | metric | pre-M4 (pair 1) | post-M4 (pair 1) | pre-M4 (pair 2) | post-M4 (pair 2) |
| --- | --- | --- | --- | --- | --- |
| grayscale | cpu-encode p50 | 4.584 ms | 2.896 ms | 4.275 ms | 2.868 ms |
| grayscale | cpu-encode p99 | 15.958 ms | 13.469 ms | 16.037 ms | 13.130 ms |
| grayscale | wall p50 | 5.704 ms | 3.781 ms | 4.806 ms | 4.133 ms |
| grayscale | wall p99 | 9.039 ms | 6.515 ms | 7.405 ms | 7.354 ms |
| rgbStripe | cpu-encode p50 | 4.085 ms | 2.823 ms | 3.860 ms | 2.844 ms |
| rgbStripe | wall p50 | 5.232 ms | 4.695 ms | 5.729 ms | 4.706 ms |

Reading: cpu-encode p50 dropped ~33-37% in both pairs, and the p99 spike
(the M0 evidence that entered this milestone: full-array re-upload cost
scaling with total accumulated geometry rather than the frame's actual new
glyphs) shrank ~13-18% — a real but partial win. The residual p99 spike is
expected and inherent to the doubling strategy: a capacity-doubling
reallocation still copies the *entire* current array (not just the tail),
and those events, while now `O(log n)` in the number of new glyphs rather
than happening every single frame, still land on some frames. The dominant,
consistent win is p50: the common-case frame (capacity already sufficient)
now pays only for its own new glyphs' tail bytes instead of the whole
accumulated geometry every time, matching the plan's stated fix for what
`ensureGeometryBuffersIfNeeded`'s full-array re-upload was doing. Full-screen
and other workload numbers (which introduce no new glyphs after warmup) are
unaffected by design — no code on that path changed.

Decision: landed as specified, no further stage needed. The plan's own
gate ("land only with a measured win on the burst workload") is satisfied by
the p50 drop; further chasing the residual p99 spike (e.g. a non-doubling
growth strategy, or amortizing the reallocation copy across frames) is not
required by this plan's acceptance and is left as a candidate follow-up if
future evidence shows it still matters in practice.
Date/Author: 2026-07-05 / plan author.
