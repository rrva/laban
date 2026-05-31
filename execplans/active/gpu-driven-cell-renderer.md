# Two coexisting, user-selectable terminal renderers: a damage-optimized classic CPU renderer and a GPU-driven cell renderer (macOS 26)

## Purpose / Big Picture

When an agent (e.g. a Claude or Codex session) streams output into a Laban tab,
Laban burns **~16–23% of one CPU core** continuously. Profiling on the real
(release) build shows this is **CPU-render-bound, not GPU-bound**: the GPU is
**0.44% utilized** while the CPU rebuilds the *entire* on-screen frame — snapshot
→ command list → per-glyph instance list → Metal command-buffer encode — on every
output tick, even though a terminal screen is ~99% unchanged frame-to-frame.

This plan pursues **two renderers that both stay in the codebase permanently as a
user-selectable option** — not a migration that deletes the old one:

1. **Classic renderer, damage-optimized ("old but fixed").** A low-risk fix *on top
   of the existing CPU renderer*: only rebuild instances whose Y overlaps the current
   **dirty-scissor union** (the rest is already clipped by the existing damage scissor;
   true sparse-dirty-row scaling needs a later multi-scissor variant), instead of
   rebuilding the whole screen every frame. Plain Metal, **works on every supported macOS**, and
   is provably pixel-identical to today's output. This becomes the default renderer
   and the **baseline the GPU renderer must beat**.
2. **GPU-driven cell renderer (macOS 26).** The terminal grid lives in a **persistent
   GPU buffer** (one entry per cell) that the GPU re-draws every frame from its own
   memory; the CPU only **patches the cells in dirty rows** and issues a single
   instanced draw, and on macOS 26 the Metal 4 command-buffer, command-allocator,
   and argument-table **objects are reused** (allocator `reset()` +
   `beginCommandBuffer` + **re-encode** each frame) to cut per-frame encode
   *overhead* — the draw is still re-encoded every frame, not replayed. The idle
   GPU absorbs the per-frame work it is built for.

Both are selectable by the user; we keep both and **compare them head-to-head**
(M6). The classic-damage fix is the safe, universal win; the GPU-driven renderer is
the macOS-26 SOTA path that may or may not beat it enough to justify its complexity —
we decide that empirically, with both shipping.

**Observable outcome a human can verify:** with an agent streaming a large log,
`~/Laban.app` CPU (Activity Monitor or `ps -o %cpu`) drops materially from the
current ~16–23% under **both** renderers, *with no visible change to what is drawn* —
proven by pixel-for-pixel identical-output tests and release-mode microbenches that
show per-frame render CPU falling as the dirty-row fraction shrinks, plus a recorded
**head-to-head comparison** of the two renderers across workloads.

**Platform target — macOS 26 first for the GPU renderer; the classic renderer covers
every OS.** The GPU-driven cell path is the macOS 26 deliverable and lands first;
it is gated `#available(macOS 26, *)`. The damage-optimized classic renderer runs on
macOS 13+ and is the default everywhere. On macOS 13–25 the GPU renderer is simply
not offered (the user choice shows classic only); those OSes are allowed to stay on
the classic renderer, by explicit decision (Decision Log). This is the same OS-gated
SOTA dual-path the merged `FrameProducer` Span work uses. Because macOS 26 is the
only target for the GPU path, it may use macOS-26-only **Metal 4** APIs (M5) for the
command-encode-*overhead* reduction (object/allocator/binding churn — not encode
elimination), not just plain Metal buffers.

**Term definitions (plain language, used throughout):**

- **Cell**: one character box in the terminal grid (a column × row position).
- **Classic renderer**: the current CPU-instanced Metal path (`buildInstanceListsOnce`
  → `prepareInstanceBuffer` → instanced draws). M1 makes it rebuild only dirty rows.
- **GPU-driven cell renderer**: the new path — a persistent per-cell GPU buffer the
  GPU redraws each frame; CPU patches dirty cells only (M2–M5).
- **Glyph atlas**: a single GPU texture holding the rasterized alpha mask of every
  distinct character seen so far. Code: `Sources/LabanRenderer/MetalGlyphAtlas.swift`.
- **Instance / instanced draw**: Metal draws one quad (two triangles) per
  "instance"; the vertex shader is invoked per-instance with `instance_id`. The
  classic renderer already builds one instance per glyph on the CPU.
- **FrameCommand**: a flat drawing instruction (a background rect or a run of
  same-styled glyphs). Produced by `FrameProducer`. Code:
  `Sources/LabanRenderer/FrameCommand.swift`.
- **Damage / `RenderDamage`**: which rows changed this frame. `.full` = redraw
  everything; `.partial(yRanges:)` = only these vertical pixel ranges changed.
  Code: `Sources/LabanRenderer/` (the `RenderDamage`/`DirtyYRange` types) and the
  producer `TerminalSurfaceController.damage(snapshot:…)`
  (`Sources/LabanCore/TerminalSurfaceController.swift:583`).
- **Persistent target texture**: an offscreen GPU texture that survives between
  frames; on partial damage the renderer preserves it (`loadAction = .load`) and
  only redraws the dirty scissor region. Already exists in `MetalRenderer`.
- **Pixel-parity**: two render paths produce byte-for-byte identical output
  bitmaps. Verified via `MetalRenderer.captureMode` + `MetalRenderer.pngData`
  (a CPU readback of the rendered texture), already used by
  `Tests/LabanRendererTests/MetalFrameTimingBench.swift`.

## Progress

The classic-damage renderer (M1) runs on all macOS versions and is the default;
the GPU-driven renderer (M2–M5) is gated `#available(macOS 26, *)`. **Both renderers
stay in the codebase permanently** and are user-selectable (M6).

- [x] M0 — Renderer-selection scaffold + pixel-parity & head-to-head comparison harness
- [x] M1 — Classic renderer, damage-scoped incremental rebuild ("old but fixed"; all OSes; the baseline)
- [x] M2 — GPU-driven: text-only cell path, whole-buffer rebuild each frame, pixel-identical (macOS 26)
- [x] M3 — GPU-driven: persistent cell buffer + dirty-row-only patching (the CPU rebuild win)
- [ ] M4 — GPU-driven: feature parity (wide/cluster glyphs, box-drawing rects, decorations, selection/find, cursor, smooth-scroll, faint/inverse)
- [ ] M5 — GPU-driven: Metal 4 command-allocator/command-buffer reuse + argument tables (encode-*overhead* reduction, behind a proof spike; macOS 26 only)
- [ ] M6 — Expose renderer choice as a user setting; keep both renderers; record head-to-head comparison; ADR
- [ ] Review Gate passed

## Context and Orientation

### Why this matters (evidence)

Release-build profiling of the live app under a streaming agent (commit `15fb668`):

```
on-CPU total ............... 16.5–23.4% of one core
  advanceFrame ............. 44.9–46.7%   (the per-frame render tick)
    settle-wake driver ..... ~22%         (re-tick on new output)
    CADisplayLink driver ... ~18%         (vsync tick)
  MetalRenderer.render ..... 15.5%        (CPU-side Metal command-buffer ENCODE)
  buildInstanceList ........ 9.3%         (per-glyph instance construction)
  makeFrame (snapshot) ..... 9.6–12.4%
  FrameProducer.commands ... 3.4%         (per-cell -> run coalescing)
  MetalGlyphAtlas lookup ... 1.2%         (already optimized: scalar key)
```

Metal System Trace of the same run:

```
LabanApp GPU busy .... 88.7 ms / 20.3 s = 0.44% utilization
GPU frames ........... 18.5 / s,  237 µs GPU time per frame
Laban's own encoders . laban.frame:terminal-content 0.05 ms total (microseconds/frame)
```

Read this as: **the GPU does almost nothing; the CPU assembles every frame from
scratch.** Two independent levers follow: (1) stop rebuilding *unchanged rows* on the
CPU — cheaply, in the classic renderer, by scoping the instance build to the dirty
scissor (M1); and (2) stop rebuilding at all by keeping a persistent GPU grid and
patching dirty cells, plus reusing the command buffer on macOS 26 (M2–M5).

This plan builds on two already-merged optimizations (both on `main`, both
byte-identical, both release-microbenched). You do not need to re-do them; they
inform the patterns used here:

- **`FrameProducer` Span fast path** — the glyph command builder uses macOS-26
  `Span`/`UTF8Span` to avoid per-cell `String` allocation. Pattern of interest:
  an A/B toggle `FrameProducer._forceLegacyGlyphRuns` plus a byte-identical
  differential test (`Tests/LabanCoreTests/FrameProducerSpanParityTests.swift`).
- **Glyph-atlas scalar key** — `MetalGlyphAtlas.entry(character:)` keys single-scalar
  glyphs on an integer scalar instead of a `String`. Pattern: A/B toggle
  `MetalGlyphAtlas.useScalarFastPath` + release microbench
  (`Tests/LabanRendererTests/MetalGlyphAtlasLookupBench.swift`).

### Current render data flow (read these before coding)

1. `Sources/LabanCore/FrameProducer.swift` — `commands(from:…)` turns a libghostty
   terminal snapshot into a flat `[FrameCommand]`: a full-terminal background rect,
   per-row background-run rects, and per-row glyph runs (coalesced same-style cells).
2. `Sources/LabanRenderer/MetalRenderer.swift`:
   - `render(_ commands: [FrameCommand], damage:)` (line ~475) — entry point.
   - `encodeContentPass(…)` (line ~740) — builds instances, encodes the content pass.
   - `buildInstanceListsOnce(commands:surfacePxH:)` (line ~936) — walks the command
     list, calls `MetalGlyphAtlas.entry(character:)` per glyph, appends a
     `GlyphInstance`/`SolidInstance` per glyph/rect into reused arrays.
   - `prepareInstanceBuffer(…)` (line ~1074) — uploads an instance array into a
     reused `MTLBuffer` (grown via `ensureBuffer`, never per-frame allocated).
   - Two instanced draws: `solidPipeline` (backgrounds) and `glyphPipeline`
     (glyphs, sampling `glyphAtlas.texture`).
   - **Partial damage already uses `loadAction = .load` + a scissor rectangle**
     covering the union of dirty `yRanges` (lines ~752–778). Off-scissor pixels are
     preserved from the previous frame in the persistent target texture. **M1 exploits
     exactly this: instances outside the scissor are already clipped, so not building
     them is provably output-identical.**
3. `Sources/LabanRenderer/Shaders.metal` — `solid_vertex/solid_fragment`,
   `glyph_vertex/glyph_fragment`. Quads are unit squares expanded from
   `kQuadVertices`; `GlyphInstance` carries `{origin, size, uvOrigin, uvSize, color}`.
   The atlas is an `r8Unorm` alpha mask sampled and tinted by the instance color.
4. `Sources/LabanRenderer/MetalGlyphAtlas.swift` — `entry(character:font:boldFallback:
   italicFallback:) -> Entry?` returns the atlas tile for a glyph:
   `{pixelWidth, pixelHeight, originX, originY, logicalOriginX, logicalWidth}` (atlas
   pixel rect + sub-cell layout offsets). The atlas **grows by reallocation** when
   full; when it grows, all tile origins change (relevant to buffer invalidation).
5. Damage source: `Sources/LabanCore/TerminalSurfaceController.swift:583`
   (`damage(snapshot:…)`) reads `snapshot.dirty_rows` (one byte per row) and emits tight
   per-row `.partial(yRanges:)`. So **precise per-row dirty information already
   exists** and reaches `MetalRenderer.render` via `surfaceFrame.damage`
   (`Sources/LabanApp/TerminalBitmapView.swift:1155`). Both renderers consume it.

### Key insight that shapes the design

The renderer is **already GPU-instanced** — the GPU already expands quads from
CPU-built instances. So "move rendering to the GPU" does **not** mean writing a
fancier shader. Two distinct moves follow, and we do both:
- **Classic (M1):** the dirty scissor already clips off-damage pixels, so the CPU
  only needs to *build instances for the dirty rows*. Cheap, low-risk, all-OS.
- **GPU-driven (M2–M5):** keep one instance *per cell* in a persistent GPU buffer
  indexed by `row * cols + col`; each frame overwrite only the cells in dirty rows;
  the GPU re-draws the whole grid from its buffer (cheap — it is 99.6% idle); on
  macOS 26 reuse the command-buffer object (Metal 4) to cut encode *overhead* too. The
  CPU's per-frame cost becomes O(changed cells), and on macOS 26 the per-frame
  command-encode overhead is reduced (object/allocation/binding churn removed — not
  eliminated; the draw is still re-encoded each frame — see M5).

## Decision Log

- **Keep both renderers; make them a user choice; do not delete the classic one.**
  Per the user's directive, the GPU-driven renderer is a **user-selectable option**
  and the classic renderer **stays in the codebase permanently** (M6) — this is not a
  migration that removes the old path. The classic renderer is also *improved* (M1
  damage-scoped rebuild), so "old" does not mean "unoptimized." We then **compare the
  GPU-driven renderer head-to-head against the damage-optimized classic renderer** and
  record the result; the GPU path must beat that improved baseline to justify its
  complexity, not merely beat today's unoptimized renderer.
- **Target macOS 26 first for the GPU path; the classic renderer covers all OSes.**
  The GPU-driven path is gated `#available(macOS 26, *)` and lands first; macOS 13–25
  are served by the (improved) classic renderer. This is the user's preferred OS-gated
  SOTA dual-path (the merged Span work's pattern), and it brings the Metal 4
  command-encode win (M5) in-scope, because macOS 26 is the only target for the GPU
  path — see "Recent-Metal research" in Surprises.
- **Pursue *both* the damage-scoped classic fix and the persistent GPU buffer.** An
  earlier draft framed these as either/or ("persistent buffer *not* damage-scoped");
  the user has chosen **both**. The damage-scoped fix (M1) keeps the classic transient
  instance arrays but only builds instances whose Y overlaps the dirty scissor box —
  provably pixel-identical because the scissor already clips the rest, lower-risk, and
  ~7% absolute CPU on its own. The persistent per-cell GPU buffer (M3) yields a cleaner
  O(dirty cells) cost and exploits the idle GPU more directly, and is the architecture
  **kitty** uses (persistent GPU-side cell buffer + per-line dirty-flag upload;
  `reload_all_gpu_data` is its exceptional full-refresh path). **Correction (web
  research):** Ghostty — the closest comparator (Metal + CoreText + a 32-byte per-cell
  `CellText` struct + in-shader `grid_pos`) — and Alacritty instead **rebuild the full
  instance set on the CPU every frame** and are still fast (Ghostty is cited ~120 fps).
  So per-frame rebuild is *not* intrinsically the bottleneck — which is exactly why we
  ship the cheap classic fix *and* measure whether the GPU rewrite earns its keep
  against it (M6).
- **Correctness contract = pixel-parity (byte-identical readback), not eyeballing.**
  Both renderers ship; any visible regression is unacceptable. The gate compares the
  **raw RGBA bytes** of each new path against the classic path (PNG byte-equality is an
  encoder implementation detail, so raw pixels are the actual contract; the PNGs are
  written only as inspection artifacts) for a battery of frames including scroll,
  selection, find, resize, clusters, and box-drawing. M1's damage-scoped classic path
  must be pixel-identical to today's classic output; the GPU path must be
  pixel-identical to the classic path.
- **M2 feeds the cell buffer from existing `FrameCommand`s; M3 reads the snapshot
  cells in `LabanCore`.** Feeding from `FrameCommand`s in M2 reuses `FrameProducer`'s
  already-correct foreground/background/attribute/cluster logic, so parity is
  achievable before we bypass it. The CPU win requires reading only dirty rows, which
  means extracting per-cell data straight from the snapshot — but that extraction
  must run in `LabanCore` (`makeFrame`, snapshot alive), **not** in the renderer (the
  renderer only gets `[FrameCommand]` and the snapshot is freed before `makeFrame`
  returns). The result is a **renderer-neutral** value-type cell payload (raw cell
  data — text, colours, attributes, resolved underline style/colour, *resolved*
  hyperlink visual state, wide/spacer, grid position — *not* Metal `CellGlyph`s; the
  atlas lookup that builds `CellGlyph`s stays in `MetalRenderer`) carried on
  `TerminalSurfaceFrame`. **The payload TYPE lives in `LabanRenderer`, not
  `LabanCore`.** The dependency edge runs `LabanCore` → `LabanRenderer`
  (`Package.swift:46-49`), so a payload type defined in `LabanCore` could never be
  consumed by `MetalRenderer` (which lives in `LabanRenderer`) without a dependency
  cycle; therefore the neutral payload structs sit in `LabanRenderer` next to
  `FrameCommand`/`TextAttributes` (or a new render-model target), `LabanCore` imports
  `LabanRenderer` and *populates* them while the snapshot is alive, and `MetalRenderer`
  consumes them. "Neutral" still means no Metal types, no atlas UVs, no `MTLBuffer`,
  no `CellGlyph`. Bypassing `FrameProducer`'s glyph-run coalescing for the Metal cell
  path is the larger correctness surface, hence staged.
- **The GPU cell path is a Metal-only acceleration; `[FrameCommand]` stays the shared
  cross-backend language.** Per `mvp.md`/`dev-process.md`, software/offscreen,
  `/debug/frame-commands`, capture replay, and render trace all consume
  `[FrameCommand]`. Neither the classic-damage path nor the GPU cell payload replaces
  it. The software backend keeps rendering from commands and stays behavior-equivalent
  (`CrossBackendBitmapTests`); the Metal paths' pixel equivalence is the separate
  `GPUCellParityTests` gate (`CrossBackendBitmapTests` never instantiates
  `MetalRenderer`). Commands keep being emitted whenever a capture/debug/trace consumer
  is attached. Recorded as policy in the M6 ADR.
- **The GPU cell path stores CPU-computed final pixel geometry; the shader does not
  recompute it.** Zero-pixel parity is unreachable if the vertex shader recomputes a
  cell's screen origin from its grid index in `Float` while the classic path passes a
  CPU-computed origin (FP non-associativity + FMA contraction + sub-pixel snapping
  shift edge coverage by a whole pixel). So each `CellGlyph` carries the **final
  `originPx` computed on the CPU with the same arithmetic as the classic
  `GlyphInstance` path**; the shader only expands the quad (`px = originPx + unit *
  sizePx`) and uses `instance_id` solely as the buffer index, never as geometry input.
  `precise`/`fma`/`-ffp-contract`/`preserveInvariance` are kept only as defensive
  belt-and-braces for any residual shader math — they make a *single* expression
  invariant but do **not** make two different CPU/GPU formulas agree, so they are not
  a substitute for storing the CPU origin.
- **The persistent cell buffer is parameterised by the renderer's in-flight depth
  (today 1).** `MetalDrawableScheduler` currently serialises GPU frames with a
  `DispatchSemaphore(value: 1)`, so one in-place cell buffer is safe *today* — but at
  the cost of CPU/GPU overlap. The M3 design must be written for N slots so it stays
  correct when depth rises above 1, and CPU↔GPU safety then comes from **N-slot
  ownership + command-buffer completion handlers**, not from Metal 4 barriers (which
  only order GPU-side work) and not from residency sets (which manage residency, not
  hazards). When depth > 1, the persistent target texture, uniform/argument buffers,
  and counter-sample slots must be made slot-specific too — the cell buffer is not the
  only shared resource.
- **Every change must earn its keep via a release microbench, or it is reverted —
  not merged.** This is a hard gate, not advice. Before landing any milestone or
  sub-change, run its microbench `-c release` and compare against the baseline
  captured at the start of that milestone. Keep the change only if it shows a net
  win (for the perf milestones M1, M3, M5) or provably no regression (for parity-only
  milestones M0/M2/M4); otherwise `git checkout` it and record why in
  `Surprises & Discoveries`. **The GPU perf milestones (M3, M5) are benchmarked against
  the M1 damage-optimized classic baseline, not the original unoptimized renderer.**
  This is exactly what happened in the prior session: a
  `String(unsafeUninitializedCapacity:)` micro-fix was implemented, measured in
  release, found to *regress* (text 0.145→0.169 ms), and reverted — it did not
  reach `main`. Do the same here. **All benchmarks run `-c release`.** Debug builds
  do not specialize Swift generics and badly mislead (the merged `FrameProducer`
  Span change measured −40% in debug but is a 5–7× speedup in release; the String
  micro-fix above looked neutral in debug but regressed in release). See Surprises.
- **The renderer choice is a persisted user setting, not a transient flag that gets
  removed.** A `RendererMode` (`.classic` / `.gpuDriven`) is stored in user defaults,
  default `.classic`; `.gpuDriven` is selectable only on macOS 26 (otherwise hidden /
  disabled). For A/B testing and the parity/comparison harness, keep
  `nonisolated(unsafe) static var` overrides (e.g. `MetalRenderer.useGPUCellPath`,
  `MetalRenderer.useClassicDamageScoped`) so all paths live in one binary — same
  pattern as the two merged changes. Unlike a normal feature flag, **neither path is
  deleted at the end**; M6 surfaces the choice in preferences and both stay.

## Plan of Work

Each milestone is independently verifiable. The classic-damage renderer (M1) ships as
the default on all OSes; the GPU renderer (M2–M5) is gated `#available(macOS 26, *)`
and is **off by default** (opt-in) until M6 exposes the user setting. Build the app
with `./scripts/build-app` (debug) or `./scripts/install-app` (profilable release to
`~/Laban.app`). Run unit tests with `swift test`; run release microbenches with
`LABAN_RUN_PERF_BENCH=1 swift test -c release --filter <name>`. Work from the repo
root `/Users/rrj/wrk/laban` (or a git worktree of it).

### M0 [P0] Renderer-selection scaffold + parity/comparison harness

**Scope.** Introduce the renderer-selection plumbing and the test harness that every
later milestone reuses:
- A `RendererMode` setting (`.classic` / `.gpuDriven`), persisted, default `.classic`;
  `.gpuDriven` resolvable only under `#available(macOS 26, *)`. Plus A/B overrides
  (`nonisolated(unsafe) static var`) for `useClassicDamageScoped` (M1) and
  `useGPUCellPath` (M2+), both default off, so one binary can render every path.
- A render-path branch in `render(...)` that, with all overrides off, calls the
  existing classic path (no behavior change yet).
- `Tests/LabanRendererTests/GPUCellParityTests.swift` — renders a battery of frames
  through path A vs path B via `captureMode`/`pngData`, decodes both to **raw RGBA**,
  and asserts the **raw pixel bytes are identical** (PNGs are kept only as artifacts;
  raw RGBA is the contract). With M0's pass-through paths, parity is trivially true —
  this proves the harness is sound and reusable for M1–M4.
- A **comparison harness** scaffold (extend `MetalFrameTimingBench`) that can time the
  *same* frame battery through classic-damage vs GPU paths and print a side-by-side
  table (mean/p50/p95/p99 per-frame CPU) — the M6 head-to-head runs through it. **Fix
  the bench's GPU drain while here:** today it flips `captureMode` on *after* rendering
  and reads `pngData`, but `MetalReadback.pngData` returns nil unless a readback
  texture already exists, so it does not reliably drain the GPU before timing — add a
  `waitForLastFrame()` / `waitForFrameCompletion` drain on the final frame so the
  numbers are real.

**What exists at the end:** the selection plumbing, A/B overrides, a parity harness,
and a comparison-bench scaffold; `swift test --filter GPUCellParityTests` passes; no
rendered output changes.

**Acceptance:**
```
swift test --filter GPUCellParityTests
# -> all parity cases pass (raw RGBA bytes identical between path A and path B)
```

### M1 [P1] Classic renderer: damage-scoped incremental rebuild — "old but fixed" (all OSes)

**Scope.** Make the **classic** renderer rebuild only what changed. Today
`buildInstanceListsOnce` walks the whole `[FrameCommand]` list every frame; on
`.partial(yRanges)` damage, the off-scissor pixels are already preserved
(`loadAction = .load`) and off-scissor instances are already clipped — so building
them is wasted work. Scope the instance build to commands whose Y overlaps the dirty
scissor union (skip glyph runs / rects entirely outside it). On `.full` damage,
behave exactly as today. This is **provably pixel-identical** (the scissor already
discards what we now skip building) and needs no snapshot/boundary changes — it is
pure `MetalRenderer` + plain Metal, so it **runs on every supported macOS** and
becomes the default classic behavior and the **baseline the GPU path is measured
against**.

Keep it behind `useClassicDamageScoped` for the A/B parity test and bench; default it
on for the classic renderer once it passes.

**What exists at the end:** the classic renderer's per-frame CPU scales with the
**dirty-scissor union** (the bounding box over all dirty `yRanges`), not the raw
dirty-row count — sparse dirty rows whose union spans most of the screen see little
win, and **true sparse-dirty-row scaling needs a later multi-scissor variant** (one
pass/scissor per dirty run); byte-identical output; a shipping win on all OSes with no
new architecture. Filter instances by overlap with the **same union scissor**
`scissorRectFromYRanges` already computes (`MetalRenderer.swift:862`), so skipping is
provably identical to what the scissor already clips — do not filter by individual
dirty rows in this first landing (that would change the proof).

**Acceptance:**
```
swift test --filter GPUCellParityTests
# -> classic-damage path is byte-identical to the classic full-rebuild path
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench
# -> classic-damage frame CPU on a mostly-static screen is materially below the
#    full-rebuild path; no regression on full-redraw frames. Records the BASELINE
#    that M3/M5 must beat. Bench the dirty sets {0}, {23}, {0,23}, {0,12,23}, a
#    contiguous 1-row, and a contiguous 5-row run, so the table exposes whether the
#    win is genuine "dirty row" scaling or merely "dirty bounding box."
```

### M2 [P1] GPU-driven: text-only cell path (whole-buffer rebuild), pixel-identical (macOS 26)

**Scope.** Add a per-cell instance struct and shaders that draw a cell from a
**CPU-computed final pixel origin stored in the cell record** — the shader uses
`instance_id` only to select the cell, never to recompute geometry (gated
`#available(macOS 26, *)`):
- In `Shaders.metal`: a `CellGlyph` struct `{ float2 originPx; float2 sizePx;
  float2 uvOrigin; float2 uvSize; uint flags; float4 fg; }` and a `cell_glyph_vertex`
  that reads `instance_id` **only as the cell-buffer index** and expands the quad with
  `float2 px = cell.originPx + unit * cell.sizePx`, sampling the atlas exactly like
  `glyph_vertex`. It does **not** derive `col`/`row` to recompute the origin — see the
  pixel-parity precondition. A matching `cell_bg_vertex`/reuse of `solid` for per-cell
  backgrounds (also fed a CPU-computed `originPx`).
- **Pixel-parity precondition — store the CPU-computed final origin; do not recompute
  it in the shader (web/maths research).** The zero-tolerance gate is unreachable if
  the shader recomputes the origin from the grid index: the classic path passes a
  CPU-computed origin (`FrameProducer` does `originX + col*cw` in `Double`/CGFloat,
  then `MetalRenderer` casts to `Float × scale`), and a `Float` in-shader
  recomputation rounds differently (FP non-associativity + Metal **FMA contraction**),
  after which the rasterizer's fixed-point sub-pixel snap (~8 sub-pixel bits) can shift
  glyph coverage by a whole pixel at edges → non-identical pixels, failed gate.
  GLSL/MSL `invariant`/`precise`/`preserveInvariance` fix only *same-expression*
  variance; they do **not** make two different CPU/GPU formulas agree, so they are
  **not** a substitute. **The shipping design therefore computes the final pixel origin
  on the CPU with the same arithmetic as the classic `GlyphInstance` path** —
  ```swift
  let originPx = SIMD2<Float>(
    Float(cellX + entry.logicalOriginX) * scale,   // cellX = runOrigin.x + col*advance
    Float(cellY) * scale)
  ```
  — and stores it in `CellGlyph.originPx`; `row*cols+col` is used **only** as the
  buffer index. A documented bounded tolerance (max ULP / capped edge-pixel delta) is
  the *only* alternative if anyone later insists on shader-side geometry, and the plan
  forbids it for the shipping path. Add a `GPUOriginParityTests` suite that asserts
  the GPU-cell `originPx`/`sizePx`/`uvOrigin`/`uvSize`/colour bit patterns match the
  classic `GlyphInstance` exactly, *before* any pixel render. (Sources in Surprises &
  Discoveries.)
- In `MetalRenderer`: build pipelines for the new shaders; when `useGPUCellPath`,
  fill a CPU `[CellGlyph]` of size `cols*rows` (empty cells get `flags=0`/zero size)
  **from the current `[FrameCommand]` glyph runs** (expand each run into per-cell
  entries; reuse `MetalGlyphAtlas.entry`; compute each cell's final `originPx` on the
  CPU exactly as the classic `appendGlyph` does), upload it, and draw `instanceCount =
  cols*rows`.
- **In M2 only `.glyphRun` commands move to the cell path; every `.rect` stays on
  the existing solid path unchanged.** This matters for a mechanically checkable
  fallback: `FrameCommand.rect` carries only `(CGRect, color, source)`
  (`Sources/LabanRenderer/FrameCommand.swift:99`), so per-cell/run *backgrounds*
  (`FrameProducer.swift:150`) and procedural *box-drawing* rects
  (`FrameProducer.swift:600`) are **both** `.rect(_, color:, source: .terminal)` and
  cannot be told apart from the command alone. M2 does not try to: all `.rect`s
  (backgrounds *and* box-art) render via the unchanged solid path, and a box-art
  cell simply has no glyph entry in the cell buffer. So box-drawing needs no special
  fallback at all.
- **Fall back to the classic path for the whole frame** only on a predicate read
  straight off the `.glyphRun` commands the cell path consumes: any `attributes`
  outside the M2-supported set, a non-`.none` `underlineStyle`, a non-nil
  `underlineColor`/`hyperlink`, or a multi-cell cluster (text whose grapheme width
  exceeds one cell). These are all fields on the `glyphRun` case — checkable without
  any new rect-classification metadata — so M2 never renders wrong.

**What exists at the end:** a working GPU cell glyph pipeline; for plain-text
frames, output is byte-identical to the classic renderer. No CPU win yet (whole
buffer rebuilt each frame).

**Acceptance:**
```
swift test --filter GPUCellParityTests
# -> plain-text fixtures pass with GPU path ON (byte-identical to classic)
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench
# -> GPU path frame CPU is within noise of classic (no regression); records baseline
```

### M3 [P1] GPU-driven: persistent cell buffer + dirty-row-only patching — THE GPU CPU WIN

**Scope.** Make the cell buffer **persistent** (a member, indexed `row*cols+col`)
and a CPU mirror alongside it. Each frame:
- On `.full` damage, resize, theme change, **glyph-atlas regrow** (tile origins
  move), or any **`geometryEpoch`** bump, rebuild the whole buffer. Because each
  `CellGlyph` caches a **final screen-space `originPx`**, *any* global input that
  changes `originPx`/`sizePx` invalidates every slot even when no terminal cell is
  dirty — so maintain a `geometryEpoch` over backing scale, font/cell metrics,
  viewport/surface origin, content offset / smooth-scroll `contentYOffset`, grid
  dimensions, and font-fallback/layout metrics; when it changes, rebuild all slots or
  fall back to classic for that frame. A shader-side global scroll/transform uniform is
  allowed *only* if `GPUOriginParityTests` proves bit-identical `originPx` behaviour
  against the classic path (it must include a smooth-scroll /
  fractional-`contentYOffset` fixture).
- On `.partial(yRanges)`, map the dirty `yRanges` back to row indices, and for each
  dirty row: clear that row's cells in the buffer, then re-fill them (atlas lookup +
  `CellGlyph` write). Upload only the changed byte range(s) of the buffer
  (`MTLBuffer.contents()` is `storageModeShared`; write in place, no per-frame
  allocation). Draw the whole grid (`instanceCount = cols*rows`).
- **GPU-in-flight hazard — parameterise by in-flight depth; one in-place buffer is
  only safe at depth 1 (research).** Apple's Metal Best Practices require
  **multiple buffer instances** for a CPU-writable, GPU-readable buffer: "an access
  conflict occurs if CPU writing and GPU reading happen at the same time." **Today the
  renderer's in-flight depth is 1** — `MetalDrawableScheduler` serialises frames with
  `DispatchSemaphore(value: 1)` — so a single in-place cell buffer is safe *now*, but
  at the cost of CPU/GPU overlap. **Design the cell buffer as N slots parameterised by
  in-flight depth**, so it stays correct when depth rises: keep one master CPU mirror
  of the full grid plus a generation counter, and each frame bring the chosen slot
  current by replaying the **union of dirty rows since that slot was last used**
  (tracked per-slot via generation, *not* by replaying every patch onto all N slots —
  that would cost O(N × dirty)). On a slot that skipped K frames this replays the
  union of those K frames' dirty rows; cost stays O(unique dirty cells since the slot
  was last drawn). **CPU↔GPU safety comes from N-slot ownership + the command-buffer
  completion handler** (`onFrameCompleted`) — the CPU never overwrites a slot whose
  command buffer is still in flight. Metal 4 barriers only order *GPU-side* work and
  `MTLResidencySet` manages residency, *not* hazards — neither makes a CPU overwrite of
  an in-flight slot safe. **When depth > 1 the cell buffer is not the only shared
  resource**: the persistent target texture, uniform/argument buffers, and
  counter-sample slots must be made slot-specific too. Ghostty uses exactly such a
  multi-frame swap chain + semaphore. **Do not ship a design that assumes a single
  in-place buffer is safe at depth > 1.**
- Source the per-cell data from the snapshot cells (the cell path no longer needs
  `FrameProducer`'s glyph-run coalescing) so only dirty rows are read. The
  foreground/background/faint/inverse/attribute/underline/hyperlink resolution must be
  a **shared helper extracted from `FrameProducer`** (not reimplemented twice) so the
  payload cannot drift from the command path; validate against the `FrameProducer`
  path via the parity harness.
- **No per-frame heap allocation.** `TerminalSurfaceController` owns a reusable
  payload builder with retained `ContiguousArray`/byte-slab capacity (cells + a
  copied-UTF-8 slab). A frame may *grow* capacity on resize or a larger dirty burst,
  but after warm-up the steady streaming path must allocate **zero** times. A
  `TerminalCellPayloadAllocationBench` records the allocation count and gates on 0 for
  1-dirty-row frames.
- **Routing for the CPU win — no existing path skips command production; M3 must add
  one (review finding).** Today `makeFrame` *always* builds `commands +=
  producer.commands(...)` (local `TerminalSurfaceController.swift:427`, remote `:521`)
  and `TerminalBitmapView` *always* renders `surfaceFrame.commands` (`:1145`). So
  "skip `FrameProducer.commands`" is not free — M3 must add an explicit **render mode**
  to the frame request (e.g. `cellPayloadOnly` / `commands` / `both`) and a
  **consumer-detection contract**: build the neutral cell payload and skip command
  coalescing **only** when (a) the active renderer is GPU-cell mode **and** (b) no
  frame-command consumer is attached (capture recorder, `/debug/frame-commands`, render
  trace, the software backend, `snapshotCommandsHook`/`frameProbe`); otherwise build
  commands (optionally also the payload). `TerminalBitmapView` then renders the payload
  instead of `cmds` in that mode. Without this routing the CPU win does not materialise
  and the M3 benchmark misses its target.
- **The dirty signal M3 reuses is edge-triggered and *consumed* — preserve that
  lifecycle (damage-path research).** `dirty_rows` is populated from libghostty per
  snapshot (`Sources/LabanTerminalCore/snapshot.c`, reading
  `GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY`) and **cleared by `laban_session_mark_rendered()`**
  for the rows that were in the last snapshot, so the next snapshot only reports
  *newly*-changed rows. M3's payload extraction reuses the **same** `dirty_rows` (no new
  dirty tracking — it is the source `damage()` already reads), but it must (a) read
  `dirty_rows` **before** `mark_rendered` clears them, and (b) ensure `mark_rendered`
  still fires exactly once per rendered frame whichever path ran (commands or payload),
  or the next frame's dirty set is corrupt. Note: full redraws and alt-screen swaps
  arrive as **all-rows-dirty** (`snapshot.c` memsets `dirty_rows`), not as `.full`, so
  the per-dirty-row patch already covers them; M3's whole-buffer-rebuild branch keys off
  resize/theme/atlas-regrow/`geometryEpoch`, not this. (`FrameProducer` itself never reads dirty state —
  it always walks the full grid, `FrameProducer.swift:131,138`.)
- **GPU-cell mode is local-session only until the laband protocol is extended (review
  finding).** Background/remote sessions render from a `LabandSnapshotResponse` whose
  `LabandSnapshotCell` carries only `row/col/text/flags/fg/bg`
  (`LabandProtocol.swift:249`) — no underline colour/style, hyperlink, or wide/spacer —
  and `TerminalBitmapView` uses the remote frame for background sessions (`:1117`), so
  the full renderer-neutral payload cannot be built from it. **M3 scopes the GPU-cell
  path to local (in-process) libghostty-snapshot sessions** and falls back to the
  classic renderer for remote frames. The fallback must be observable: expose
  `{configuredRenderer, effectiveRenderer, fallbackReason}` in debug state (e.g.
  `effectiveRenderer = "classic"`, `fallbackReason = "remoteSnapshotPayloadIncomplete"`
  while the UI setting stays `gpuDriven`) and gate it with
  `RemoteSnapshotRendererModeTests` (gpuDriven configured + remote snapshot ⇒ classic
  path used, command stream and pixels unchanged). Extending the laband snapshot-cell
  protocol to carry the full cell is a separate cross-process contract change (its own
  ADR) — out of scope here; note it as future work.

**M3's cell payload crosses the renderer boundary (interface fix).** The renderer
*cannot* "read the snapshot directly": `MetalRenderer.render` only receives
`[FrameCommand]` + `RenderDamage` (`TerminalBitmapView.swift:1155`), and the
libghostty snapshot is freed by `defer { laban_snapshot_destroy(snap) }` before
`makeFrame` returns (`TerminalSurfaceController.swift:385`). Reading cells in the
renderer would mean keeping that snapshot alive past `makeFrame` — an unsafe
lifetime. So the dirty-row extraction happens **in `LabanCore`, inside `makeFrame`,
while the snapshot is still alive**, and copies a **renderer-neutral** per-cell
payload — for each dirty cell **everything `LabanCell` carries that affects rendering**:
its grapheme/cluster text (the bytes are **copied into a UTF-8 slab**, since the
snapshot is destroyed before the frame escapes), resolved foreground and background
colour, `TextAttributes`, **resolved underline style and underline colour, and the
hyperlink's resolved *visual* state — `hasHyperlink` + any hyperlink-default underline
style/colour, *not* the hyperlink id or URI** (the URI table is freed with the snapshot
and the renderer never needs it for drawing; click handling does not move into the
renderer), and wide/spacer state (`LabanTerminalCore.h:88` — narrowing to just
text/colours/attrs would fail M4 parity), and grid `col`/`row`, plus the list of dirty
row indices.

**The payload type lives in `LabanRenderer`, not `LabanCore` (module-boundary fix).**
The dependency edge runs `LabanCore` → `LabanRenderer` (`Package.swift:46-49`), so a
payload type *defined in* `LabanCore` could never be a parameter of
`RendererBackend.render`/`MetalRenderer` (both in `LabanRenderer`) without a dependency
cycle. The neutral payload structs therefore live in `LabanRenderer` (next to
`FrameCommand`/`TextAttributes`, e.g. `Sources/LabanRenderer/TerminalCellPayload.swift`,
or a new `LabanRenderModel` target); `LabanCore` already imports `LabanRenderer` and
*populates* them while the snapshot is alive. The payload must **not** carry
`CellGlyph`s: a `CellGlyph` needs atlas UVs, atlas texture size, and per-glyph tile
metrics, all of which come from `MetalGlyphAtlas` — a renderer-owned resource
(`MetalRenderer.swift:153`; UVs are computed from `atlas.textureSize` at
`MetalRenderer.swift:977`). So `LabanCore` does the cell-data resolution
(fg/bg/attributes/underline/hyperlink-visual, the part that needs the live snapshot,
via the shared helper extracted from `FrameProducer`), and **`MetalRenderer` does the
`MetalGlyphAtlas.entry` lookup, computes each cell's CPU `originPx`, and turns those
cells into `CellGlyph`s as it patches its persistent buffer.** `TerminalBitmapView`
just forwards the neutral payload to `backend.render`. This is why M3 is **not**
"touches only `Sources/LabanRenderer/`" (corrected in Interfaces and Dependencies).
The neutral payload is an internal acceleration channel — it does **not** replace the
`[FrameCommand]` language (see below).

**Frame-command and headless contract (resolves the Metal-only concern).** `mvp.md`
(Implementation Shape) and `dev-process.md` (Headless Rendering Contract,
`/debug/frame-commands`, capture replay `frames/*.commands.json`, render trace) make
`[FrameCommand]` the shared, serializable language that **both** the Metal and the
software/offscreen backends consume. The GPU cell path must not break that:
- The GPU cell path is a **Metal-interactive-only acceleration**. The
  software/offscreen backend keeps consuming `FrameProducer`'s `[FrameCommand]`
  unchanged and stays behavior-equivalent — enforced by `CrossBackendBitmapTests`
  (which exercises the *software* backend only). The Metal GPU path's pixel
  equivalence is separately enforced by the `GPUCellParityTests` pixel-parity gate.
- `FrameProducer.commands` continues to be produced whenever a frame-command
  consumer is active (capture/replay, `/debug/frame-commands`, render trace,
  headless). The CPU win applies to the steady interactive Metal path *when no such
  consumer is attached* — there, the dirty-row cell payload is built and command
  coalescing is skipped; when a consumer is attached, commands are still emitted so
  replay/debug/trace stay accurate. State this trade-off explicitly so an
  implementer does not assume commands disappear unconditionally.
- A frame whose cell payload the GPU path cannot yet represent still falls back to
  the `[FrameCommand]` path (the M2 fallback rule), so the contract holds at every
  milestone.

**What exists at the end:** GPU-path per-frame render CPU scales with dirty rows. On a
mostly static screen with a few changing lines, `buildInstanceList`-equivalent work
drops ~5–20×. The `[FrameCommand]` stream remains the authoritative cross-backend
language for software, headless, capture, and debug.

**Acceptance (must show the win, release mode):**
```
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter <new dirty-row microbench>
# -> "1 dirty row" frame CPU is dramatically lower than "full screen" frame CPU,
#    and lower than the M1 damage-optimized CLASSIC renderer on the same dirty set.
swift test --filter GPUCellParityTests
# -> still byte-identical, including a fixture that streams row-by-row (partial damage)
```
Then install a profilable build and confirm the live drop:
```
./scripts/install-app   # builds --profile release to ~/Laban.app + dSYM
# relaunch, stream a large log, compare `ps -o %cpu` and an Instruments Time
# Profiler before/after: FrameProducer.commands + buildInstanceList + encode share
# should fall substantially; GPU utilization stays trivially low.
```

### M4 [P1] GPU-driven: feature parity — remove the fallback

**Scope.** Extend the cell path to every terminal feature, each validated
pixel-identical via the parity harness before enabling it (add a fixture per
feature): wide/CJK and combining/ZWJ clusters (a cluster spans one wide cell +
spacer-tail; the cell entry must carry the composed glyph), **procedural
box-drawing rects** (currently CPU-emitted `.rect`s in `FrameProducer` /
`BoxDrawing`; the gnarliest case — flag procedural-box cells in the payload with
their scalar and let `MetalRenderer` generate the rect instances via the existing
`BoxDrawing`, or keep a small CPU side-channel), decorations (underline styles,
strikethrough, overline; currently `TextDecorationLayout`), selection / find
highlights, the cursor overlay (already a separate pass — keep it), smooth-scroll
`contentYOffset`, and faint/inverse. Remove the M2 fallback only when all fixtures
pass with the GPU path on.

**Overlay representation (decision).** In steady GPU-cell mode M3 skips full
`[FrameCommand]` coalescing, so the non-cell overlays — cursor, selection, find
highlights, and any image/texture quads — must be represented without rebuilding the
full glyph/background command stream. **Decision: `TerminalSurfaceFrame` carries a
small `overlayCommands` list** (cursor + selection + find only) alongside the cell
payload; the GPU path draws the cell buffer then those overlays. Full glyph/background
command coalescing stays skipped (otherwise the M3 CPU win erodes). Dedicated
`SelectionPayload`/`FindPayload`/`CursorPayload` types are a possible later cleanup,
not required for M4.

**Acceptance:** every fixture in `GPUCellParityTests` passes with the fallback
removed; the existing suites stay green:
```
swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor|GraphemeClustering|TextDecorationLayout|FrameProducer'
```

### M5 [P2] GPU-driven: Metal 4 command-allocator/buffer reuse + argument tables — THE ENCODE-OVERHEAD WIN (macOS 26)

**Scope.** M3 removes the per-frame *rebuild* cost; this milestone removes the
per-frame *encode* cost. `MetalRenderer.render`'s CPU-side command-buffer encode is
the largest single render slice in the profile (**15.5%**) and M0–M4 leave it
untouched. On macOS 26 the renderer adopts the **Metal 4** command model: command
buffers become long-lived, app-allocator-owned objects instead of fire-and-forget
transients recreated each frame, plus `MTL4ArgumentTable` binding and **residency
sets** (`MTLResidencySet`). **What this actually buys (corrected — Metal 4 has no
"encode once, replay" for graphics):** reusing an `MTL4CommandBuffer` means calling
`allocator.reset()` then `beginCommandBuffer(allocator:)` and **re-encoding the draw
each frame** — the win is removing per-frame *object/allocation/binding* churn (a
long-lived command buffer + a pool of reset-able command allocators +
`MTL4ArgumentTable`), **not** replaying an already-encoded buffer, so encode CPU is
*reduced*, not eliminated. A terminal is a reasonable fit because the draw shape is
identical every frame (`instanceCount = cols*rows`, one solid + one glyph pass) so the
encode is trivial and the per-frame object/allocator overhead is the part worth cutting.
**`MTLResidencySet` manages residency, not hazards** — it does *not* provide the
CPU↔GPU synchronisation the M3 N-buffered cell buffers need. **That safety comes from
N-slot ownership + command-buffer completion handlers** — the CPU must not overwrite a
buffer slot whose command buffer is still in flight. Metal 4 barriers order *GPU-side*
accesses within/between command streams; they do **not** make a CPU overwrite of an
in-flight shared buffer safe. The allocator/buffer pool is cycled on frame-completion
(an allocator cannot be `reset()` while its commands are still in flight). **Also note
argument-table snapshot semantics:** a Metal 4 argument table snapshots its resources
*when the draw/dispatch is encoded*, so swapping the bound cell-buffer slot by mutating
an argument table after an already-encoded draw will not work — keep resource objects
stable or re-encode the draw (which M5 does anyway). **Gate this milestone behind a
proof spike** that measures the real encode-CPU delta on representative frames *before*
committing to it — do not assume a large win.

This milestone is **macOS-26-only by construction** and is *the* reason the GPU path
targets macOS 26 (Purpose → Platform target). It **composes with M3, it does not
replace it**: keep M3's plain-Metal persistent-buffer path as the macOS-26 baseline,
and < macOS 26 stays on the (damage-optimized) classic renderer regardless.

**Do *not* reach for Indirect Command Buffers here.** ICBs pay off at *thousands* of
draw calls; Laban issues ~2 instanced draws, so the encode cost is render-pass +
buffer setup, not draw-call multiplicity — ICBs would add complexity for little gain
(web research). Metal 4 reusable command buffers attack the actual cost.

**What exists at the end:** on macOS 26, per-frame CPU encode is **reduced** (no
per-frame command-buffer/allocator object churn or argument re-binding; the draw is
still re-encoded, cheaply). The combined M3+M5 path should show the encode share of
the profile shrink alongside the rebuild share. This is a **perf milestone** —
earn-its-keep is strict here precisely because the win is overhead-reduction, not
replay: the proof spike and a release microbench must show a net encode-CPU reduction
(vs the M3-only GPU path and vs the M1 classic baseline) or it is reverted.

**Acceptance (release mode, macOS 26):**
```
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter <encode microbench>
# -> per-frame encode CPU on a static screen is measurably reduced vs the M3-only
#    path (overhead-reduction, not elimination); no regression on full-redraw frames.
swift test --filter GPUCellParityTests
# -> still byte-identical (the reused command buffer draws the same pixels)
```

### M6 [P2] User-selectable renderer + head-to-head comparison + ADR

**Scope.** Surface the renderer choice and keep both paths permanently:
- Expose `RendererMode` in preferences (Classic vs GPU-driven). The GPU-driven option
  is offered **only** under `#available(macOS 26, *)`; otherwise the control shows
  Classic only (or the GPU option is disabled with a "requires macOS 26" note).
  Default `.classic`. Persist across launches; the terminal session identity must
  survive a renderer switch (re-create the surface, keep the session — see AGENTS.md
  "session identity must survive view rebuilds").
- **Keep both renderers in the codebase.** Do **not** delete the classic path or the
  A/B overrides. This is a permanent two-renderer design, not a migration.
- **Head-to-head comparison (the point of keeping both).** Run the M0 comparison
  harness to produce a recorded table of **GPU-driven vs damage-optimized classic**
  across a broad workload matrix, not one log stream: 0-dirty/cursor-blink, 1-dirty-row
  append (the primary agent/log case), 5% and 25% contiguous dirty rows, **sparse
  dirty rows** (exposes the M1 union-scissor weakness), full-screen repaint, fast
  scroll, dense colours, box-drawing, emoji/CJK/ZWJ clusters, resize/theme/atlas
  growth, and a remote/laband frame (proves the fallback). For each, record **p50/p95/p99
  per-frame render CPU, total process CPU, GPU frame time, energy/wakeups, and dropped
  frames** on macOS 26 in `Outcomes & Retrospective`. State plainly which renderer wins
  where, and apply the **predeclared default-selection thresholds**:
  - **Make `.gpuDriven` the macOS-26 default** only if it shows **≥25% lower render CPU
    at both p50 and p99** on the streaming/TUI workloads, **no >10% full-redraw
    regression, no energy regression, and zero parity failures**.
  - **Keep `.gpuDriven` opt-in** if it wins only narrow workloads, has worse p99 or
    energy, the remote fallback is common, or M1 already makes CPU negligible.
  - **Disable the GPU option by default** if parity flakes, a feature fallback remains,
    or M3/M5 fails to beat the M1 classic baseline.
- Write `docs/adr/0016-gpu-driven-cell-renderer.md` (0014 and 0015 already exist — use
  the next sequential number; re-check `docs/adr/` at write time) recording: the
  **two coexisting user-selectable renderers** decision; the profile evidence; the
  damage-scoped classic fix; the persistent-buffer architecture; the **macOS-26
  `#available` dual-path**; the **Metal 4 command model** (M5); the head-to-head
  comparison result; **and the frame-command contract boundary** — the GPU cell path
  is a Metal-interactive-only acceleration; the software/offscreen backend,
  `/debug/frame-commands`, capture replay, and render trace keep consuming the
  `[FrameCommand]` language. Add the one-line ADR entry to the `AGENTS.md` Decision
  Index (the `AGENTS.md` "Write a new ADR" rule requires it). Update `docs/quality/`
  if it tracks render performance.

## Validation and Acceptance

The change is **internal** (same pixels, less CPU) and ships **two renderers**, so
acceptance is proven five ways, all reproducible from a clean checkout:

1. **Pixel-parity (correctness).** `swift test --filter GPUCellParityTests` renders
   a battery of frames (plain text, colored backgrounds, wide/CJK, emoji clusters,
   box-drawing, underline/strike/overline, hyperlinks, selection, find, cursor,
   scroll, resize, a row-by-row streaming sequence that exercises partial damage)
   through both the classic and GPU paths (and the classic-damage vs classic-full
   paths), decodes each readback to **raw RGBA**, and asserts the **raw pixel bytes are
   identical** (raw RGBA is the contract; PNG byte-equality is an encoder
   implementation detail, so PNGs are written only as artifacts). **On any mismatch the
   test must emit an actionable pixel diff, not just "failed":** report (a) the fixture
   name and grid size, (b) the first differing pixel as `(x, y)` with its expected vs
   actual RGBA values, (c) the total count of differing pixels and the maximum
   per-channel delta, and (d) write
   `<fixture>.expected.png`, `<fixture>.actual.png`, and `<fixture>.diff.png` (the diff
   highlighting differing pixels, e.g. magenta on black) to `LABAN_ARTIFACTS` (default
   `.artifacts/`) for inspection. "Identical" means **zero** differing pixels — there
   is no tolerance threshold; a single differing pixel fails the gate. This is the gate
   for every milestone that changes a render path.
2. **Performance (the point), release only.**
   `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
   and a new dirty-row microbench must show per-frame render CPU falling with the
   dirty-scissor-union / dirty fraction for **both** renderers, and not regressing on
   full-screen frames. Numbers are printed (mean/p50/p95/p99 ms per frame, plus energy
   where measurable); record them in `Outcomes & Retrospective`. **The bench must drain
   the GPU before timing** (`waitForLastFrame()` / `waitForFrameCompletion` on the final
   frame) — the current `MetalFrameTimingBench` flips `captureMode` on after rendering
   and reads `pngData`, which returns nil without a pre-existing readback texture and so
   does not reliably drain; fix that as part of M0. A `TerminalCellPayloadAllocationBench`
   (M3) must additionally show **zero heap allocations** on 1-dirty-row frames after
   warm-up.
3. **Head-to-head comparison (because both renderers ship).** The M0 comparison
   harness records GPU-driven vs damage-optimized classic across the **broad M6
   workload matrix** (0-dirty, 1-row append, 5%/25% contiguous, sparse dirty rows, full
   redraw, scroll, dense colour, box-drawing, emoji/CJK/ZWJ, resize/theme/atlas growth,
   remote fallback) on macOS 26, reporting p50/p95/p99 render CPU, total CPU, GPU time,
   energy, and dropped frames. The GPU perf milestones (M3, M5) must beat the **M1
   classic baseline**, not the original unoptimized renderer, to earn their keep, and
   the default-selection decision is made against the **predeclared M6 thresholds**.
4. **Live before/after.** Build `./scripts/install-app`, relaunch `~/Laban.app`,
   stream a large file in a tab, and capture an Instruments Time Profiler
   (`xcrun xctrace record --template "Time Profiler" --attach <pid> --time-limit 18s`)
   for each renderer. `FrameProducer.commands` + `buildInstanceList` +
   `MetalRenderer.render` encode share must drop substantially versus the `15fb668`
   baseline, with GPU utilization staying near 0.4% (Metal System Trace).
5. **Frame-command contract preserved (M2 onward).** The GPU cell path must not change
   the shared `[FrameCommand]` language or the software backend's output. No single
   existing test covers this, so the gate is two distinct checks — do not conflate
   them:
   - **Metal GPU-path pixel equivalence is `GPUCellParityTests`**: it renders through
     `MetalRenderer` with `useGPUCellPath` on vs off (`captureMode`/`pngData`) and
     asserts byte-identical pixels. **`CrossBackendBitmapTests` does *not* prove
     this** — its helpers render `FrameProducer.commands` → `SoftwareBackend` only
     (`CrossBackendBitmapTests.swift:126,240`) and never instantiate `MetalRenderer`,
     so flipping `useGPUCellPath` does not change what they exercise. They still must
     stay green, but only as evidence the *software* path and `FrameProducer`'s
     commands are unchanged. If you want a Metal-backed cross-backend check, you must
     **add** a fixture that renders a `MetalRenderer` bitmap with `useGPUCellPath` on
     (the current helpers cannot).
   - **Command-stream invariance**: with capture/debug active, `/debug/frame-commands`
     and capture-replay `frames/*.commands.json` for a given frame are **unchanged**
     flag-on vs flag-off (assert identical command streams for a capture fixture) —
     proving the cell payload is a Metal-only acceleration that does not divert the
     command language the software/headless path consumes.

6. **Payload & origin parity, remote fallback (M2/M3).** Before any M3 perf claim,
   `GPUOriginParityTests` asserts the GPU-cell `CellGlyph` fields
   (`originPx`/`sizePx`/`uvOrigin`/`uvSize`/colour) match the classic `GlyphInstance`
   bit-for-bit, and `CellPayloadParityTests` asserts the neutral payload, expanded back
   to synthetic commands by a test-only adapter, matches `FrameProducer`'s
   `[FrameCommand]` for glyph text, style, background, underline, hyperlink visual
   effect, procedural boxes, and cluster spans (run over the existing
   `FrameProducerSpanParityTests` fixtures). `RemoteSnapshotRendererModeTests` asserts
   that with `gpuDriven` configured and a remote snapshot, the classic path is used,
   command stream and pixels are unchanged, and debug state reports
   `effectiveRenderer = classic` / `fallbackReason = remoteSnapshotPayloadIncomplete`.

The existing renderer test suites must stay green at every milestone:
`MetalRendererSmokeTests`, `MetalRendererClearColorTests`,
`CrossBackendBitmapTests` (note: these spawn `laband`/`labpty` daemons and may
time out in sandboxed CI — they fail the same way on `main`, so treat a daemon
`ETIMEDOUT` as environmental, not a regression), `GraphemeClusteringTests`,
`TextDecorationLayoutTests`.

## Outcomes & Retrospective

### 2026-05-31 — M0/M1 landed in `gpu-work`

- M0 added the permanent `RendererMode` model (`classic` / `gpuDriven`), persisted
  under `LabanRendererMode`, with `.gpuDriven` resolving only on macOS 26+. The AppKit
  Metal renderer reads the persisted mode, and `MetalRenderer` keeps A/B overrides
  `useClassicDamageScoped` and `useGPUCellPath` for tests/benches. M0 initially made
  the GPU-cell override an explicit pass-through to classic; M2 replaced that branch
  with the text-only cell pipeline below.
- M0 added `GPUCellParityTests`, which decodes Metal readback PNGs to raw RGBA and
  compares bytes. On mismatch it writes `expected.png`, `actual.png`, and `diff.png`
  under `LABAN_ARTIFACTS` (default `.artifacts/GPUCellParityTests`) and reports the
  first differing pixel, total differing pixels, and max channel delta.
- M0 fixed the timing drain by adding `MetalRenderer.waitForLastFrame()` and making
  `MetalFrameTimingBench` drain the final frame directly instead of enabling readback
  after the fact.
- M1 made `useClassicDamageScoped` the default classic path. On partial damage,
  `MetalRenderer` scopes solid/glyph/selection/find instance construction to the same
  dirty Y union that the existing Metal scissor already applies; cursor instances are
  still collected globally for the overlay pass.
- Validation:
  - `swift test --filter GPUCellParityTests` passed (3 tests).
  - `swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor'`
    passed (16 tests).
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
    passed.
- Release benchmark evidence from `MetalFrameTimingBench`:
  - Frame-level timings are still dominated by drawable/present costs, so the table
    intentionally also reports an instance-list-only microbench for the CPU work M1
    changes.
  - Instance-list rebuild only, 160x48, p50:
    - row 0: full 615.7 us, scoped 13.8 us (glyphs 7329 -> 160)
    - row 23: full 580.5 us, scoped 13.7 us (glyphs 7331 -> 160)
    - sparse rows 0,23: full 593.2 us, scoped 303.7 us (dirty-union limitation)
    - sparse rows 0,12,23: full 595.7 us, scoped 305.0 us (dirty-union limitation)
    - contiguous 1 row: full 586.1 us, scoped 14.3 us
    - contiguous 5 rows: full 592.7 us, scoped 65.4 us
  - These numbers confirm M1's expected dirty-scissor-union scaling and expose the
    planned sparse-row weakness that a later multi-scissor variant would address.

### 2026-05-31 — M2 text-only GPU cell path landed in `gpu-work`

- M2 added `CellGlyph` to `Shaders.metal` and `MetalRenderer`, plus a
  `cell_glyph_vertex` pipeline. The shader uses `instance_id` only as the cell-buffer
  index; `originPx`, `sizePx`, UVs, and colour are CPU-computed with the same arithmetic
  as the classic `GlyphInstance` path.
- The GPU-cell branch now builds a whole-frame cell buffer from terminal
  `.glyphRun` commands while leaving every `.rect` on the existing solid pipeline.
  Sidebar glyphs continue through the classic glyph pipeline. M2 falls back to classic
  for decorated/linked terminal glyph runs or glyphs whose atlas entry spans more than
  one cell.
- `GPUCellParityTests` now checks the pre-render origin contract by comparing the raw
  float bit patterns of classic glyph instances and GPU cell records, rejects an
  unsupported decorated terminal run, and verifies real GPU-cell readback pixels match
  classic for plain text.
- Validation:
  - `swift test --filter GPUCellParityTests` passed (5 tests).
  - `swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor|MetalFrameTimingBench'`
    passed (19 tests).
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
    passed.
- Release benchmark evidence from `MetalFrameTimingBench`:
  - Classic vs GPU-cell full-frame text path, 160x48, p50/p95/p99 CPU:
    - classic: 6.966 / 8.028 / 8.413 ms, glyphs 6120, cellGlyphs 0, solids 48
    - gpuCell: 6.971 / 8.070 / 8.211 ms, glyphs 0, cellGlyphs 7680, solids 48
  - This confirms the expected M2 result: the whole-buffer cell path is
    pixel-identical and within noise of classic, but it is not a CPU win yet. The CPU
    win is still M3's dirty-row-only patching.

### 2026-05-31 — M3 persistent payload routing landed in `gpu-work`

- Added the renderer-neutral `TerminalCellPayload` type in `LabanRenderer` and wired
  `TerminalSurfaceController` to populate it while the local `LabanSnapshot` is alive.
  `TerminalBitmapView` now requests payload mode only for local interactive Metal
  GPU-cell rendering when no frame-command consumer is attached (`captureRecorder`,
  `frameProbe`, software/headless/remote all keep command production).
- `TerminalSurfaceController` skips terminal glyph/background command coalescing only
  when the payload is compatible with the current text-only GPU-cell milestone. It
  falls back to commands for selection/find overlays, exit banners, links,
  decorations, wide/cluster cells, procedural cells, invalid UTF-8, or missing cell
  storage.
- `MetalRenderer` can now consume the payload path, retain the persistent cell buffer,
  patch only the payload's dirty rows, upload only changed cell ranges, and still draw
  sidebar/chrome commands through the classic glyph/solid pipelines. A scalar atlas
  lookup avoids rebuilding a `Character` for payload glyphs.
- `MetalRenderer` now reports `{configuredRenderer, effectiveRenderer,
  fallbackReason}` and an explicit `remoteSnapshotPayloadIncomplete` reason forces the
  effective path to classic while preserving the configured GPU-driven status. The
  `/debug/render` response carries the same renderer-status fields for the software
  backend shape.
- `TerminalSurfaceController` retains reusable payload and dirty-row buffers across
  frames; `TerminalSurfaceControllerTests` verifies warmed capacity is reused. This is
  backed by a release-only `TerminalCellPayloadAllocationBench` that verifies zero
  warmed storage-growth events for repeated one-dirty-row payload builds.
- The payload builder now decodes single UTF-8 scalars directly into `scalarValue`
  without materializing a `String`; multi-scalar clusters still fall back to the command
  path until M4 carries cluster text through the payload model.
- `MetalRenderer` no longer allocates a temporary dirty-row bitmap for payload
  patches, and it skips clearing a dirty row only when the payload contains one glyph
  for every cell in every dirty row. Sparse dirty-row payloads still clear the row
  before patching, covered by `GPUCellParityTests`.
- New tests:
  - `TerminalSurfaceControllerTests` verifies compatible payload mode omits terminal
    glyph commands, selection mode falls back to commands, warmed payload capacity is
    retained, and single UTF-8 scalar cells avoid text materialization.
  - `GPUCellParityTests` verifies payload patching uploads only the dirty cell-buffer
    row range, sparse patches clear stale glyphs, and remote GPU-cell fallback reports
    classic effective status.
  - `LabanDebugSmokeTests.testRuntimeRenderStateReportsRendererStatus` verifies the
    debug render-state JSON includes renderer-status fields.
  - `TerminalCellPayloadAllocationBench` gates the warmed one-dirty-row payload builder
    on zero retained-storage growth events and compares the routed payload path against
    classic command production plus M1 scoped rebuild.
- Validation:
  - `swift test --filter 'GPUCellParity|TerminalSurfaceControllerTests|MetalFrameTimingBench'`
    passed (15 tests).
  - `swift test --filter 'GPUCellParity|testRuntimeRenderStateReportsRendererStatus|TerminalSurfaceControllerTests'`
    passed (17 tests).
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
    passed.
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter TerminalCellPayloadAllocationBench`
    passed.
- Release benchmark evidence from `MetalFrameTimingBench`:
  - GPU-cell command-fed patch vs payload patch, 160x48, p50:
    - row 0: command patch 95.3 us, payload 13.1 us
    - row 23: command patch 93.2 us, payload 13.6 us
    - sparse rows 0,23: command patch 342.7 us, payload 26.7 us
    - sparse rows 0,12,23: command patch 336.0 us, payload 40.4 us
    - contiguous 1 row: command patch 95.5 us, payload 13.5 us
    - contiguous 5 rows: command patch 137.9 us, payload 67.1 us
- `TerminalCellPayloadAllocationBench` evidence: 10,000 warmed one-dirty-row payload
  builds reported `storageGrowthEvents=0` and `perFrame=2.107 us` in release. The routed
  dirty-row bench reported classic command production plus M1 scoped rebuild at
  `113.1 us` p50 versus payload fill plus GPU patch at `14.8 us` p50.
- M3 is checked off with the M2 text-feature fallback still in place: multi-scalar
  cluster bytes are copied into the payload slab, but those cells still fall back to
  commands until M4 removes the text-feature fallback and renders them through the GPU
  cell path.

### 2026-05-31 — M4 slice 2 text decorations landed in `gpu-work`

- The GPU-cell path now accepts terminal underline, strikethrough, and overline
  attributes, plus explicit underline styles/colours. Hyperlinks, wide/cluster cells,
  procedural cells, and selection/find overlays still fall back to later M4 slices.
- `TextAttributes.gpuCellRenderableMask` now includes underline/strike/overline, and
  `FrameProducer.fillTerminalCellPayload` no longer marks plain text decorations as a
  payload fallback.
- `MetalRenderer` reuses the existing `TextDecorationLayout`/`emitDecorations`
  machinery for terminal GPU-cell runs. The command-fed path emits decorations once per
  terminal glyph run, and the payload path reconstructs adjacent same-style runs before
  emitting decorations so dotted/dashed/curly underline phase matches the classic
  coalesced command path.
- New tests:
  - `GPUCellParityTests` verifies command-fed and payload-fed GPU-cell text decorations
    are raw-RGBA identical to classic rendering across single/double/dotted/dashed/curly
    underline, underline colour, strikethrough, and overline.
  - `TerminalSurfaceControllerTests.testCellPayloadModeKeepsTextDecorationsOnPayloadPath`
    verifies decorated local snapshots still skip terminal glyph command coalescing in
    payload-preferred mode.
- Validation:
  - `swift test --filter 'GPUCellParity|TerminalSurfaceControllerTests'` passed (26
    tests).
  - `swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor|GraphemeClustering|TextDecorationLayout|FrameProducer'`
    passed (78 tests).
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
    passed.
- Release benchmark evidence from `MetalFrameTimingBench` after the slice:
  - Classic vs GPU-cell full-frame text path, 160x48, p50/p95/p99 CPU:
    - classic: 6.810 / 7.910 / 8.452 ms, glyphs 6120, cellGlyphs 0, solids 48
    - gpuCell: 6.823 / 7.870 / 8.431 ms, glyphs 0, cellGlyphs 7680, solids 48
  - GPU-cell dirty-row payload patch, 160x48, p50:
    - row 0: payload 28.9 us, payload+upload 29.5 us
    - row 23: payload 29.2 us, payload+upload 29.5 us
    - sparse rows 0,23: payload 57.1 us, payload+upload 58.0 us
    - sparse rows 0,12,23: payload 85.7 us, payload+upload 86.7 us
    - contiguous 1 row: payload 29.1 us, payload+upload 29.7 us
    - contiguous 5 rows: payload 143.3 us, payload+upload 144.2 us

### 2026-05-31 — M4 slice 3 procedural cells landed in `gpu-work`

- The payload path now carries procedural block/triangle cells through a small
  renderer-neutral `TerminalCellPayload.ProceduralCell` side channel instead of marking
  `.proceduralCell` fallback. This preserves the command-stream skip for local
  interactive GPU-cell payload mode when dirty rows contain `U+2580...U+259F` block
  elements or `U+25E2...U+25E5` fixed triangles.
- `MetalRenderer` consumes those procedural cells by calling the existing
  `BoxDrawing.proceduralCellElementRects` helper and appending the resulting solid
  rects. The command-fed GPU-cell path was already correct because procedural cells
  arrive as ordinary `.rect` commands there; this slice closes the payload CPU-win path.
- `TerminalCellPayload.CapacitySnapshot` now tracks `proceduralCells` capacity so the
  warmed allocation gate covers the new retained array.
- New tests:
  - `GPUCellParityTests.testGPUCellPayloadMatchesClassicForProceduralCells` verifies
    payload-fed GPU-cell procedural blocks/triangles are raw-RGBA identical to classic
    command rendering.
  - `TerminalSurfaceControllerTests.testCellPayloadModeKeepsProceduralCellsOnPayloadPath`
    verifies real local snapshots with procedural cells keep payload mode and omit
    terminal rect/glyph commands.
- Validation:
  - `swift test --filter 'GPUCellParity|TerminalSurfaceControllerTests|TerminalCellPayloadAllocationBench'`
    passed (30 tests).
  - `swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor|GraphemeClustering|TextDecorationLayout|FrameProducer'`
    passed (79 tests).
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter TerminalCellPayloadAllocationBench`
    passed: 10,000 warmed one-dirty-row payload builds reported
    `storageGrowthEvents=0`, `perFrame=2.547 us`, and capacities including
    `proceduralCells: 1`; routed dirty-row p50 was classic commands+M1 scoped `156.1
    us` versus payload fill+GPU patch `28.2 us`.
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
    passed.
- Release benchmark evidence from `MetalFrameTimingBench` after the slice:
  - Classic vs GPU-cell full-frame text path, 160x48, p50/p95/p99 CPU:
    - classic: 6.756 / 7.715 / 8.205 ms, glyphs 6120, cellGlyphs 0, solids 48
    - gpuCell: 6.805 / 7.578 / 7.861 ms, glyphs 0, cellGlyphs 7680, solids 48
  - GPU-cell dirty-row payload patch, 160x48, p50:
    - row 0: payload 27.5 us, payload+upload 27.8 us
    - row 23: payload 28.2 us, payload+upload 28.5 us
    - sparse rows 0,23: payload 55.2 us, payload+upload 55.5 us
    - sparse rows 0,12,23: payload 81.7 us, payload+upload 82.6 us
    - contiguous 1 row: payload 27.7 us, payload+upload 28.0 us
    - contiguous 5 rows: payload 137.7 us, payload+upload 138.8 us

### 2026-05-31 — M4 slice 4 hyperlink visuals landed in `gpu-work`

- The GPU-cell paths now render OSC-8 hyperlink visual state without falling back. The
  renderer still does not receive or use the URI; `FrameProducer`/payload extraction
  resolve the visual treatment (underline bit, underline style, underline colour), and
  URI/click hit testing remains in `TerminalHyperlink` against the live snapshot.
- `FrameProducer.fillTerminalCellPayload` no longer marks `.hyperlink` fallback after it
  records `hasHyperlink` and applies the default link underline visual. `MetalRenderer`
  accepts `hasHyperlink` payload glyphs and command-fed terminal glyph runs with a
  non-nil `hyperlink`, drawing them through the existing glyph + decoration paths.
- New tests:
  - `GPUCellParityTests` verifies command-fed and payload-fed hyperlink visuals are
    raw-RGBA identical to classic rendering.
  - `TerminalSurfaceControllerTests.testCellPayloadModeKeepsHyperlinksOnPayloadPath`
    verifies real OSC-8 local snapshots keep payload mode and carry `hasHyperlink`
    glyphs.
- Validation:
  - `swift test --filter 'GPUCellParity|TerminalSurfaceControllerTests|HyperlinkPlumbingTests'`
    passed (34 tests).
  - `swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor|GraphemeClustering|TextDecorationLayout|FrameProducer|HyperlinkPlumbing'`
    passed (84 tests).
  - `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
    passed.
- Release benchmark evidence from `MetalFrameTimingBench` after the slice:
  - Classic vs GPU-cell full-frame text path, 160x48, p50/p95/p99 CPU:
    - classic: 6.751 / 7.659 / 7.939 ms, glyphs 6120, cellGlyphs 0, solids 48
    - gpuCell: 6.729 / 7.677 / 8.021 ms, glyphs 0, cellGlyphs 7680, solids 48
  - GPU-cell dirty-row payload patch, 160x48, p50:
    - row 0: payload 27.0 us, payload+upload 27.3 us
    - row 23: payload 27.6 us, payload+upload 28.0 us
    - sparse rows 0,23: payload 53.6 us, payload+upload 54.3 us
    - sparse rows 0,12,23: payload 80.5 us, payload+upload 81.2 us
    - contiguous 1 row: payload 27.3 us, payload+upload 27.5 us
    - contiguous 5 rows: payload 134.3 us, payload+upload 136.6 us

## Review Gate

A fresh review agent (no prior context; given this ExecPlan, the milestone under
review, the changed files, and `AGENTS.md`) must verify, per milestone:

- [ ] `GPUCellParityTests` exists, runs, and asserts **identical raw RGBA pixels**
      between the paths claimed complete in the milestone (read the test; confirm it
      decodes to raw RGBA and compares pixel bytes, not PNG bytes and not just shapes;
      PNGs are artifacts only).
- [ ] The path under test is genuinely exercised (overrides actually change the code
      path; confirm the new pipeline/shaders/instance-scoping are used, e.g. by a
      counter or by temporarily breaking the path and seeing parity fail).
- [ ] For M1: the classic damage-scoped rebuild is **byte-identical** to the
      full-rebuild classic path (the scissor already clipped what it now skips), and a
      release microbench shows the win — this is the recorded baseline for M3/M5.
- [ ] For perf milestones (M1, M3, M5): the microbench is **release** (`-c release`)
      and shows a real reduction; debug-only numbers do not count. M3/M5 are measured
      **against the M1 classic baseline**, not the original renderer.
- [ ] Earn-its-keep was applied: every landed sub-change has a release microbench
      showing a net win (or no regression for parity-only work). Any change that did
      not earn its keep was reverted and the reversion is recorded in
      `Surprises & Discoveries` (not silently kept).
- [ ] On a parity failure the test emits the actionable pixel diff (first differing
      `(x,y)` + RGBA, differing-pixel count, and `expected/actual/diff.png`
      artifacts), and the gate is zero-tolerance (a single differing pixel fails).
- [ ] No new per-frame heap allocations in either render path (buffers reused like
      `ensureBuffer`; the GPU cell buffer is persistent; `storageModeShared` writes in
      place).
- [ ] For M3+: the cell payload is extracted in `LabanCore` while the snapshot is
      alive and carried on `TerminalSurfaceFrame` — the renderer does not read the
      libghostty snapshot (which is freed before `makeFrame` returns). The payload is
      **renderer-neutral** (raw cell data); `CellGlyph`/atlas-UV construction lives in
      `MetalRenderer` (it owns `MetalGlyphAtlas`), not in `LabanCore`.
- [ ] For M2 onward: the `[FrameCommand]` cross-backend contract is preserved — GPU-path
      pixel equivalence is proven by `GPUCellParityTests` (Metal flag-on vs off, *not*
      by `CrossBackendBitmapTests`, which never instantiates `MetalRenderer`);
      `CrossBackendBitmapTests` stays green only as evidence the software path +
      `FrameProducer` commands are unchanged; and `/debug/frame-commands` /
      capture-replay command streams are identical flag-on vs flag-off.
- [ ] The GPU path is gated `#available(macOS 26, *)`; on < macOS 26 the GPU option is
      not offered and the classic renderer runs (verify the dual-path compiles and the
      classic path is byte-unchanged).
- [ ] For M2: the cell-path stores the **CPU-computed final `originPx`** in `CellGlyph`
      (same arithmetic as the classic `GlyphInstance` path) and the shader does **not**
      recompute geometry from the grid index; `GPUOriginParityTests` asserts the
      instance fields match bit-for-bit. (A documented bounded tolerance is the only
      alternative and is forbidden for the shipping path.)
- [ ] For M3: the persistent cell buffer is **parameterised by in-flight depth** (N
      slots with per-slot generation + dirty-union replay, or semaphore-gated at the
      current depth 1) — no design that assumes a single in-place buffer is safe at
      depth > 1, and CPU↔GPU safety is by slot-ownership + completion handler (not
      barriers, not residency sets). When depth > 1, target/uniform/sample resources
      are slot-specific too.
- [ ] For M3: the neutral payload type is defined in `LabanRenderer` (or a render-model
      target) and only *populated* by `LabanCore` — not defined in `LabanCore` (which
      would be a dependency cycle, since `LabanCore` → `LabanRenderer`). It carries
      resolved hyperlink **visual** state (not the id/URI), and fg/bg/underline/
      hyperlink resolution is a shared helper extracted from `FrameProducer`, not
      reimplemented.
- [ ] For M3: a `TerminalCellPayloadAllocationBench` shows **zero** per-frame heap
      allocations on 1-dirty-row frames after warm-up (reusable builder + retained
      capacity).
- [ ] For M3+: a `geometryEpoch` covers every input that affects cached
      `originPx`/`sizePx` (scale, font/cell metrics, grid dims, viewport origin,
      `contentYOffset`, transform); a change invalidates all cell-buffer slots and
      forces full rebuild or classic fallback, and `GPUOriginParityTests` includes a
      smooth-scroll / fractional-offset fixture.
- [ ] For M4: non-cell overlays (cursor/selection/find) are carried as `overlayCommands`
      alongside the cell payload; full glyph/background command coalescing stays skipped
      in steady GPU-cell mode.
- [ ] For M5: a proof spike measured the real encode-overhead delta first; the Metal 4
      command-allocator/buffer-reuse + argument-table path shows a release-mode
      encode-CPU **reduction** (overhead, not elimination — draws are re-encoded),
      stays pixel-identical, and is macOS-26-gated. Buffer safety is by slot-ownership +
      completion handler, not residency sets or barriers alone.
- [ ] For M6: **both renderers remain** in the codebase and are user-selectable (GPU
      option macOS-26-only); the head-to-head comparison is recorded; the ADR uses the
      next free number (0016+, not the already-taken 0014), records the two-renderer +
      macOS-26 dual-path + Metal 4 decision, and a matching one-line entry was added to
      the `AGENTS.md` Decision Index. The renderer switch preserves session identity.
- [ ] Existing renderer suites green (or failing only via the known environmental
      daemon timeout, identical to `main`).
- [ ] Records the commit SHA reviewed and a one-line summary; on failure, lists
      concrete file:line findings.

## Surprises & Discoveries

- **The GPU is 0.44% utilized; Laban is CPU-render-bound.** (Metal System Trace,
  commit `15fb668`.) This is the entire justification for the plan.
- **The renderer is already GPU-instanced.** The win is *building fewer instances*
  (classic, M1) and *incremental/persistent buffers* (GPU, M3), not a new shader. Do
  not be misled into writing a clever fragment shader.
- **Debug benchmarks lie.** Always `-c release`. A prior `String` micro-fix looked
  neutral in debug and *regressed* in release; the `FrameProducer` Span change was
  −40% in debug but 5–7× in release. Bench harnesses already gate on
  `LABAN_RUN_PERF_BENCH=1` and assume release.
- **Partial damage already scissors + `.load`s.** Off-scissor instances are already
  clipped — this is exactly what makes the M1 damage-scoped classic fix provably
  pixel-identical, and it is now a shipped milestone (not just a fallback).
- **`damage(snapshot:…)` already emits tight per-row dirty ranges** from
  `snapshot.dirty_rows` (`TerminalSurfaceController.swift:583`). Neither renderer
  needs new dirty-tracking; both consume what exists.
- **Glyph-atlas regrow invalidates the whole cell buffer** (tile origins change on
  reallocation). M3 must rebuild on regrow; missing this would show stale glyphs.
- **Web research — only kitty does incremental cell upload; Ghostty/Alacritty rebuild
  per frame.** kitty keeps a persistent GPU cell buffer and uploads only dirty lines
  (`has_dirty_text`/`is_dirty`; `reload_all_gpu_data` = full refresh). Ghostty (Metal,
  closest comparator) and Alacritty rebuild the full instance set every frame and are
  still fast — which is exactly why we ship the cheap classic-damage fix (M1) *and*
  measure whether the GPU rewrite beats it (M6). Sources: kitty & Ghostty DeepWiki;
  Alacritty PR #4373 / issue #5843.
- **Maths research — the zero-tolerance pixel gate is reachable only with bit-exact
  origin math.** FP non-associativity + Metal FMA contraction + fixed-point sub-pixel
  snapping mean an in-shader origin can differ from the CPU origin by a pixel at edges.
  GLSL/MSL `invariant`/`precise` fix only *same-expression* variance, not divergent
  formulas. Drives the M2 precondition. Sources: Khronos Type Qualifier wiki; Geeks3D
  precise qualifier; randomascii FP-determinism; arXiv 2408.05148 (FP non-associativity);
  NVIDIA IEEE-754 (FMA contraction); scratchapixel rasterization (sub-pixel fixed-point).
- **Apple Metal Best Practices require triple buffering for CPU-write/GPU-read
  buffers.** Drives M3's N-buffered cell buffer. Source: Apple "Metal Best Practices:
  Triple Buffering".
- **Recent-Metal research — Metal 4 (macOS 26) is the encode lever (now M5).** Metal 4's
  long-lived command buffers + argument tables + residency sets are built "to minimise
  CPU overhead" of command encoding — exactly the 15.5% encode slice M0–M4 leave alone.
  ICBs are a poor fit at ~2 draw calls; residency sets alone, mesh shaders, MetalFX, and
  ML-in-shaders are minor or irrelevant here. Sources: Apple WWDC25 "Discover Metal 4";
  Apple "What's New in Metal"; Apple indirect-command-encoding docs.
- **Review (Codex r4) — three corrections folded in.** (1) **Metal 4 has no
  "encode once, replay" for graphics:** command-buffer *objects* are reused via
  `allocator.reset()` + `beginCommandBuffer(allocator:)` + **re-encode**, and
  `MTLResidencySet` manages residency, *not* hazards — so M5 is recast as
  object/allocation/binding-overhead reduction behind a proof spike, not encode
  elimination. (2) **Nothing today skips `FrameProducer.commands`** (`makeFrame` always
  builds them — `TerminalSurfaceController.swift:427`/`:521`; `TerminalBitmapView`
  always renders them — `:1145`), so M3 must add an explicit render-mode +
  consumer-detection contract or its win is illusory. (3) **The neutral payload must
  carry underline style/colour, hyperlink, and wide/spacer** (full `LabanCell`,
  `LabanTerminalCore.h:88`), and GPU-cell mode is **local-session only** because the
  remote `LabandSnapshotCell` (`LabandProtocol.swift:249`) lacks those fields. Sources:
  Apple MTL4CommandBuffer / `beginCommandBuffer(allocator:)` / MTLResidencySet docs.
- **Review (r5) — five blocking edits folded in.** (1) **M2 stores the CPU-computed
  final `originPx` in `CellGlyph`; the shader never recomputes geometry from the grid
  index** — `precise`/`fma`/`preserveInvariance` cannot make two different CPU/GPU
  formulas agree, so they are defensive-only, not the parity mechanism. (2) **The
  neutral payload type lives in `LabanRenderer`, not `LabanCore`** — `LabanCore` →
  `LabanRenderer` (`Package.swift:46-49`), so a `LabanCore`-defined type consumed by
  `MetalRenderer` would be a dependency cycle; `LabanCore` only *populates* it. (3) The
  pixel gate compares **raw RGBA bytes**, not PNG bytes (PNG equality is an encoder
  detail). (4) **M1 scales with the dirty-scissor *union* bounding box, not the raw
  dirty-row count** — sparse rows need a later multi-scissor variant; the bench must
  include sparse dirty sets to expose this. (5) **M5's CPU↔GPU safety is N-slot
  ownership + completion handlers** — Metal 4 barriers order GPU work and residency
  sets manage residency; neither makes a CPU overwrite of an in-flight buffer safe, and
  an argument table snapshots resources at encode time (so swapping a bound buffer by
  mutating the table after an encoded draw does not work). Also: in-flight depth is
  **1 today** (`DispatchSemaphore(value: 1)`), so the N-slot design is forward-looking;
  overlays (cursor/selection/find) ride an `overlayCommands` list so the M3 CPU win is
  not eroded; the payload carries resolved hyperlink *visual* state, not the URI/id; and
  the M6 default decision is gated on predeclared p50/p99/energy thresholds across a
  broad workload matrix. Sources: Apple MTLCompileOptions.preserveInvariance /
  MTL4RenderCommandEncoder.setArgumentTable / Metal Best Practices (Triple Buffering,
  Command Buffers) / residency-sets docs.

## Idempotence and Recovery

Every step is additive and behind a setting/override (the classic renderer is always
available, the GPU path is opt-in and inert on < macOS 26), so the app keeps working
at all times; reverting is selecting Classic or `git checkout` of the renderer files.
Tests and benches can be re-run freely. Because **both renderers stay**, there is no
risky cut-over: if the GPU path (M2–M5) underdelivers in the M6 comparison, the
classic-damage renderer (M1) remains the default and the GPU path stays as an opt-in
option (or is left disabled) — record the decision in `Outcomes & Retrospective`.

## Interfaces and Dependencies

- **M0–M2 and M1 touch only `Sources/LabanRenderer/`** (`MetalRenderer.swift`,
  `Shaders.metal`, possibly `MetalGlyphAtlas.swift` for a stable per-glyph index)
  and new tests under `Tests/LabanRendererTests/`. The classic-damage fix (M1) scopes
  the existing instance build to the dirty scissor — no upstream changes. M2 builds
  its cell buffer from the `[FrameCommand]` the renderer already receives — no upstream
  changes.
- **M3 necessarily crosses the renderer boundary** (see "M3's cell payload crosses
  the renderer boundary" in the M3 scope). The renderer only ever receives
  `[FrameCommand]` + `RenderDamage` via `backend.render` and the libghostty snapshot
  is destroyed (`laban_snapshot_destroy`) before `makeFrame` returns
  (`TerminalSurfaceController.swift:385`), so the renderer *cannot* read snapshot
  cells directly. M3 therefore touches:
  - `Sources/LabanCore/TerminalSurfaceController.swift` — extract the dirty-row
    cell payload **while the snapshot is still alive** (before the `defer
    laban_snapshot_destroy`), reading the libghostty cell struct already consumed by
    `FrameProducer` (`Sources/LabanTerminalCore/include/LabanTerminalCore.h`:
    `LabanCell`, `LabanSnapshot.dirty_rows`).
  - `Sources/LabanRenderer/TerminalCellPayload.swift` (new, or a new `LabanRenderModel`
    target) — define the **renderer-neutral** cell payload structs (raw cell data:
    copied UTF-8 text, colours, `TextAttributes`, **resolved underline style/colour,
    resolved hyperlink *visual* state, wide/spacer state** — the `LabanCell` render
    surface minus the URI/id — and grid position; AppKit/Metal-free, no atlas/`CellGlyph`
    types). The type must live **here, not in `LabanCore`**: the dependency runs
    `LabanCore` → `LabanRenderer` (`Package.swift:46-49`), so a `LabanCore`-defined
    payload could not be a `RendererBackend`/`MetalRenderer` parameter without a cycle.
  - `Sources/LabanCore/TerminalSurfaceController.swift` — add the optional
    `TerminalCellPayload?` field (and the **render-mode** field `cellPayloadOnly` /
    `commands` / `both` the routing needs) to `TerminalSurfaceFrame`, and *populate* the
    payload (via a reusable, retained-capacity builder — zero per-frame allocation after
    warm-up) while the snapshot is alive, using the shared resolution helper extracted
    from `FrameProducer`.
  - `Sources/LabanRenderer/RendererBackend.swift` — **the protocol must grow a new API
    shape (review finding):** today `render(_ commands: [FrameCommand], damage:)` is the
    only entry (`RendererBackend.swift:44`) and `SoftwareBackend` already ignores
    `damage` (`:46`). Add an overload/parameter carrying the optional cell payload, e.g.
    `render(_ commands:, cellPayload:, damage:)`. **`SoftwareBackend` ignores the
    payload (no-op, exactly as it ignores `damage`) and keeps rendering
    `[FrameCommand]`**; only `MetalRenderer` consumes the payload. The
    `render(_ commands:)` convenience stays.
  - `Sources/LabanApp/TerminalBitmapView.swift:1145` — in GPU-cell mode with no command
    consumer, render the payload via the new API instead of `surfaceFrame.commands`;
    otherwise unchanged.
  - `Sources/LabanRenderer/` — do the `MetalGlyphAtlas.entry` lookup, build the
    `CellGlyph`s, and patch the persistent cell buffer (`MetalRenderer.swift`,
    `Shaders.metal`). `CellGlyph` (atlas UVs/metrics) is defined and populated only
    here, never in `LabanCore`.
  - **M6** touches the preferences UI / settings store (the `RendererMode` control)
    and wherever the active renderer is selected for a surface — keeping session
    identity across a switch.
- **Platform: macOS 26 first for the GPU path; classic covers all OSes.** Package
  deployment target stays `macOS .v13` (`Package.swift`). The damage-optimized classic
  renderer (M1) runs on macOS 13+. The entire GPU cell path (M2–M5) is gated
  `#available(macOS 26, *)`; M2–M4 use plain Metal + buffers (which *would* run on
  macOS 13, but the plan does not support or test them there — the gate keeps the
  surface small), and **M5 uses macOS-26-only Metal 4 APIs** (long-lived command
  buffers, `MTL4ArgumentTable`, `MTLResidencySet`). This matches the merged Span work's
  `#available` fast-path + untouched-legacy pattern.
- ADR boundary: per `AGENTS.md`, a change to "rendering architecture" warrants an
  ADR — written in M6 (`docs/adr/0016-…`, next sequential after the existing 0015),
  with the matching `AGENTS.md` Decision Index entry.
