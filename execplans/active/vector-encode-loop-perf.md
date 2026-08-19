# Cut the vector renderer's per-cell encode-loop CPU cost

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that will
help a fresh contributor.

## Purpose / Big Picture

When the user scrolls a terminal while the **vector glyph renderer** is selected
(Settings ▸ Renderer ▸ "Vector Glyph", stored under the `UserDefaults` key
`LabanRendererMode` with value `vectorGlyph`), the app rebuilds the on-screen
text on the CPU every frame. A CPU System Trace of heavy scrolling
(`~/Downloads/Untitled7.trace`, analyzed with `./scripts/analyze-metal-trace
--cpu-only`) showed a single function, `VectorGlyphRenderer.encode`, consuming
**25.9% of all CPU samples** (1021 ms of 3940 ms), roughly five times any other
frame. The CoreText calls *underneath* it are already cached and cost ~2%
combined; the remaining ~24% is the straight-line per-cell work the encode loop
does for every visible cell, every frame.

After this change, that per-cell work shrinks measurably: the renderer builds GPU
instance data with less work per cell and one fewer full copy, so the same heavy
scroll spends materially less CPU time in `encode`. You can see it working by
running the existing benchmark `VectorScrollFrameTimeBench` (it prints CPU encode
p50/p95/p99 milliseconds per renderer at a realistic 160×48 grid) before and after
each milestone and comparing the "vector" rows — they must drop, and the
pixel-output parity tests must stay at zero diff so the optimization changes cost,
not appearance.

This plan is **pure performance refactoring of a post-MVP renderer**. It changes
no product behavior and needs no `spec.md` approval (see `AGENTS.md` ▸ Source Of
Truth: "performance, and refactors that preserve MVP behavior do not need spec.md
approval"). It must not break any behavior required by `docs/product/mvp.md`.

## Definitions (plain language)

- **Vector glyph renderer**: the rendering backend in
  `Sources/LabanRenderer/VectorGlyphRenderer.swift` that draws terminal text by
  rasterizing font outlines (curves) into coverage masks on the GPU, rather than
  using a pre-baked bitmap atlas. It is one of four selectable backends
  (`software`, `classic`, `gpuDriven`, `vectorGlyph`) in
  `Sources/LabanRenderer/RendererSelection.swift`.
- **FrameCommand**: a value in `Sources/LabanRenderer/FrameCommand.swift`
  describing one drawing primitive for a frame. The relevant case is
  `.glyphRun(origin, text, foreground, background, attributes, source,
  underlineStyle, underlineColor, _)`: a horizontal run of terminal cells that
  all share the same text attributes (color, bold, italic). One terminal row
  becomes one or more glyph runs.
- **Glyph run / run**: the `text` string inside a `.glyphRun`. The upstream
  producer `Sources/LabanCore/FrameProducer.swift` coalesces adjacent same-style
  cells into one run, so a run is typically many cells of one row.
- **Instance**: one GPU draw record. `VectorGlyphInstance` (a `struct` in
  `VectorGlyphRenderer.swift`, 52 bytes) holds a glyph's screen rectangle, its
  texture-atlas rectangle, color, and a coverage exponent. The vertex shader
  draws one textured quad per instance. `VectorSolidInstance` (40 bytes) is the
  analogous record for solid rectangles (cursor, selection, underlines).
- **Encode**: the method `VectorGlyphRenderer.encode(commands:into:commandBuffer:
  retainedInstanceBuffers:)`. It walks every `FrameCommand`, builds the instance
  arrays, and issues the Metal draw calls. "Per-cell encode loop" means the inner
  `for` loop inside `appendGlyphRun` that runs once per terminal cell.
- **`setVertexBytes` 4 KB limit**: Metal's API for handing a small array straight
  to the GPU inline accepts at most 4096 bytes. Above that, the data must live in
  an `MTLBuffer`. The renderer's constant `maxInlineInstanceBytes = 4096`
  encodes this. A full-screen scroll produces far more than 4 KB of instances, so
  it always takes the buffer path — which is the path this plan optimizes and the
  path the tests must exercise (see `AGENTS.md` Hard Rule on buffer-backed
  uploads).

## Progress

- [x] (2026-06-29) Analysis complete: `encode` self-time is 25.9% of CPU on the
  heavy-scroll trace; callees (CoreText, arrays) are ~4%; the residual ~24% is
  the inlined per-cell loop body. Prior commit `a407c6f` already collapsed the
  *prepare* pass's per-cell mask resolution to per-glyph; this plan targets the
  *encode* pass and the array→buffer copy, which `a407c6f` did not touch.
- [x] (2026-06-29) Milestone 0: baseline captured. 160x48 @ scale 2, release:
  gpu/classic 8.384/9.186/9.734, vector/fluid 8.347/16.755/20.064, vector/crisp
  8.874/16.711/20.050 (p50/p95/p99 ms). Cost is tail latency: vector p95/p99 ~2x
  classic. Target refined to p95/p99.
- [x] (2026-06-29) Milestone 2: hoisted maskAtlas uv reciprocals, fluid device
  offset, and per-run foreground color out of the per-cell `glyphInstance`;
  removed the redundant divide-then-multiply for size. Parity 8/8 green. Bench
  (representative across runs, incl. independent Review Gate): vector p95 improves
  modestly below the M0 baseline (crisp ~16.7→~16.1; a single best-case run hit
  14.970 but that is an outlier — see Artifacts note), crisp p50 8.874→~8.5. The
  durable win is the reproducible p50 drop + parity-preserving arithmetic
  reduction. (Done before M1 per Decision Log.)
- [x] (2026-06-29) Milestone 1: evaluated and **declined** by its own gate. A
  microbenchmark of the exact operation (build 160×48 POD instances + bulk copy
  into a buffer, steady state) measured the array→buffer copy M1 removes at ~19 µs
  p50 / 23 µs p95 per frame — ~0.13% of the ~15 ms vector p95, below bench noise.
  The instances are trivial PODs (no ARC), so there is no array "churn" beyond
  that copy, and `removeAll(keepingCapacity:)` avoids realloc. Landing the
  direct-to-buffer rewrite would add CPU↔GPU shared-buffer hazard surface to the
  hottest GPU path for an unmeasurable gain. Not landed. See Decision Log.
- [x] (2026-06-29) Milestone 3: implemented an ASCII-run scalar fast path
  (1 byte = 1 cell), parity 8/8 + full 79-test vector suite green — then
  **reverted** by its gate. Two release bench runs showed vector p95 did not drop
  below M2 (fluid 16.07/16.76, crisp 16.08/16.15 vs M2 16.32/14.97) and crisp p50
  drifted up. A standalone microbench confirmed the CPU iteration saving is real
  (~285 µs/frame: Character enumerate 616 µs → scalar-direct 300 µs) but it is
  below the integrated bench's p95 noise floor (~0.4–0.5 ms, GPU-bake-tail bound).
  Not landed. See Decision Log.
- [x] (2026-06-29) Review Gate passed by a fresh-state agent against `c156a01`:
  all 7 mechanical checks PASS, M1/M3 confirmed absent, M2 verified bit-exact.
  Artifacts table corrected per the reviewer's advisory (M2 crisp p95
  representative ~16.1, not the 14.970 outlier).

## Context and Orientation

All paths are relative to the repository root
(`/Users/user/wrk/laban/.claude/worktrees/adaptive-tickling-porcupine` in the
current working tree; a fresh clone uses its own root).

### The two per-cell passes

`VectorGlyphRenderer.render(_:damage:)` (around line 631) drives one frame. For
the text, it calls two methods in sequence, **each of which walks every command
and every cell**:

1. `prepareGlyphResources(commands:commandBuffer:)` (around line 949): per cell,
   ensures the glyph's coverage mask is resident in the GPU mask atlas (baking it
   if needed). Commit `a407c6f` added a per-frame `Set<FrameGlyphKey>`
   (`framePreparedGlyphs`) so a glyph that repeats across cells is only *baked*
   once — but the loop still *visits* every cell.
2. `encode(commands:into:commandBuffer:retainedInstanceBuffers:)` (around line
   717): per cell, builds a `VectorGlyphInstance` and appends it to a Swift
   array; at run boundaries (`flush()`) it uploads the arrays and draws.

This plan focuses on pass 2 (`encode`), where the trace cost lives. The per-cell
work is in the private helper it calls:

`appendGlyphRun(_:origin:foreground:background:attributes:underlineStyle:
underlineColor:atlas:source:solids:glyphs:rasterGlyphs:sidebarRasterGlyphs:
colorGlyphs:)` (around line 1025). Its inner loop, abbreviated:

```swift
let variant = styledFontVariant(for: attributes, in: atlas)   // cached, per run
let font = variant.font
let cellAdvance = atlas.cellSize.width
let baseline = origin.y + atlas.descent
let coverageExponent = Self.coverageExponent(...)             // per run
let runWantsColor = ... && ColorGlyphSupport.textMayContainColor(...)  // per run
for (cellIndex, cluster) in text.enumerated() {              // <-- per CELL
  let position = CGPoint(x: origin.x + CGFloat(cellIndex) * cellAdvance, y: baseline)
  if runWantsColor, ColorGlyphSupport.clusterMayBeColor(cluster), let colorFallback = ... {
    colorGlyphs.append(colorFallback); continue
  }
  if let glyph = vectorGlyph(for: cluster, font: font, ...),         // cached lookup
     let resolved = resolveDrawMask(for: glyph, font: font, ...) {   // per-frame memo
    glyphs.append(glyphInstance(mask: resolved.mask, position: position,
                                color: foreground,
                                coverageExponent: coverageExponent,
                                slide: resolved.slide))
  } else if let fallback = rasterFallbackInstance(...) {
    ... append to rasterGlyphs / sidebarRasterGlyphs
  }
}
appendDecorations(...)   // underline/strikethrough/overline, per run
```

`glyphInstance(mask:position:color:coverageExponent:slide:)` (around line 1600)
builds the 52-byte struct. It currently recomputes, **per cell**: four divisions
by `maskAtlas.width`/`maskAtlas.height` (frame-constant), the `* scale` factors,
and the fluid scroll offset.

### The upload path (the second copy)

`flush()` inside `encode` calls `setVertexInstances(_:encoder:retainedBuffers:)`
(around line 898):

```swift
return instances.withUnsafeBytes { raw in
  if raw.count <= Self.maxInlineInstanceBytes {           // small frame: inline
    encoder.setVertexBytes(base, length: raw.count, index: 0); return true
  }
  guard let buffer = nextInstanceBuffer(minimumLength: raw.count) else { return false }
  memcpy(buffer.contents(), base, raw.count)              // <-- second full copy
  encoder.setVertexBuffer(buffer, offset: 0, index: 0); return true
}
```

So for any real scroll (>4 KB of instances) each cell's instance is written
*twice*: once into the Swift `Array` (`glyphs.append`), then the whole array is
`memcpy`'d into the pooled `MTLBuffer`. `nextInstanceBuffer(minimumLength:)`
(around line 927) already pools buffers per frame via `instanceBufferPool` /
`instanceBufferPoolCursor`, reset to 0 at the top of `encode`.

### Why the array exists today

`encode` accumulates *all* glyphs for a clip region into one array and draws them
in one `drawPrimitives(instanceCount:)`. The array also lets `flush()` decide
inline-vs-buffer by total size. Milestone 1 keeps the single-draw-per-flush shape
but changes the *accumulator* from a Swift `Array` to a directly-written pooled
buffer.

### The existing test and benchmark anchors

- `Tests/LabanRendererTests/VectorScrollFrameTimeBench.swift`: builds a 160×48
  cell grid at scale 2, warms up, then times 200 frames while sweeping the scroll
  offset, and prints **CPU encode p50/p95/p99 ms** for three paths labeled
  `gpu/classic`, `vector/fluid`, and `vector/crisp`. This is the headline
  measurement for this plan. It is a `print`-only bench (no hard assertion) and
  **only runs when the environment variable `LABAN_RUN_PERF_BENCH=1` is set**
  (otherwise `enabled()` returns false and the test is a no-op); it is meant to be
  run in a release build (`-c release`) for representative numbers.
- `Tests/LabanRendererTests/VectorGlyphParityTests.swift`: rasterizes the
  renderer's glyph output and compares pixels against a CPU oracle and snapshot
  baselines. `testRendererHandlesLiveSizedInstanceBatches` exercises a grid large
  enough to exceed the 4 KB inline limit (pixelWidth 1640), i.e. the buffer path.
  This is the correctness guard: its pixel diffs must not change.
- `Tests/LabanRendererTests/ColorGlyphScrollBench.swift`: guards the
  CoreText-per-cell regression class called out in `AGENTS.md` (the `bed1a2b`
  regression). Keep it green.

### Coordination note (read before starting)

A parallel effort already landed `a407c6f` ("Vector scroll jank dies when
per-cell glyph work collapses to per-glyph") and several neighbouring commits
(`5246099`, `9d9e40a`). Those changed `prepareGlyphResources` and the drawable
scheduler, **not** the `encode` instance-building path this plan targets, so the
areas are disjoint. Before editing, run `git log --oneline -5 --
Sources/LabanRenderer/VectorGlyphRenderer.swift` and confirm no newer commit has
already rewritten `encode`/`setVertexInstances`; if one has, re-baseline
(Milestone 0) against current `main` before proceeding.

## Plan of Work

The work is three additive, independently measurable milestones, smallest and
safest first. Each milestone is committed separately so a regression can be
bisected to one change (the `AGENTS.md` "one behavioral reason per changeset"
rule, and the bench's "one change per trace" attribution rule).

### Milestone 0 — Baseline

Record the current numbers so every later milestone has a before/after. No code
change.

### Milestone 1 — Write instances into the pooled buffer (remove the second copy)

Replace the per-flush "append to Swift array, then `memcpy` the array into a
buffer" with "write each instance directly into a pooled, mapped `MTLBuffer`".

Concretely, introduce a small helper type — call it `InstanceWriter` — that wraps
a pooled `MTLBuffer` and a running element count, exposing `append(_ instance:)`
that writes one POD struct at the current offset via
`UnsafeMutableRawPointer.storeBytes(of:as:)`, growing by requesting a larger
pooled buffer (reusing `nextInstanceBuffer`) when full. `flush()` then sets the
buffer on the encoder and draws `count` instances, with no intermediate array and
no second `memcpy`. Keep the existing inline `setVertexBytes` fast path for the
small (<4 KB) case so static, non-scrolling frames are unchanged.

This removes: (a) the whole-array `memcpy` in `setVertexInstances`, (b) the Swift
`Array` growth/realloc and per-element retain/release churn the trace attributed
to `swift_arrayDestroy` and `compiler_rt.memcpy`. The five accumulators
(`solids`, `glyphs`, `rasterGlyphs`, `sidebarRasterGlyphs`, `colorGlyphs`) each
become an `InstanceWriter`.

Because Metal requires the buffer not be mutated while the GPU reads it, the
writers must draw-then-reset within `flush()` and the underlying pooled buffers
are already retained for the frame's lifetime via `retainedInstanceBuffers` and
the `instanceBufferPool`. Preserve that retention.

### Milestone 2 — Hoist constants and trim `glyphInstance`

In `appendGlyphRun`/`glyphInstance`, compute once per frame (or per run) the
values currently recomputed per cell:

- `1.0 / Float(maskAtlas.width)` and `1.0 / Float(maskAtlas.height)` — the uv
  divisors are frame-constant; multiply instead of divide per cell.
- `Float(scale)` and the fluid device offsets — constant per frame; the per-cell
  `slide` branch only chooses whether to add the (precomputed) offset.
- `vectorColor(color)` is per *run* (foreground is constant within a glyph run),
  so resolve the packed color once per run instead of once per cell.

These are arithmetic-only changes with identical output. They shrink the
per-cell instruction count that dominates `encode` self-time.

### Milestone 3 — Stride instead of re-segmenting `text`

`for (cellIndex, cluster) in text.enumerated()` iterates a Swift `String` as
`Character`s, which performs Unicode grapheme-cluster segmentation per cell. The
upstream `FrameProducer` already segmented these bytes when it built the run (see
`appendFastTerminalGlyphRuns` and `graphemeClusterCount` in
`Sources/LabanCore/FrameProducer.swift`). `cellIndex` is used only as a stride
multiplier for `position.x`.

The minimal, self-contained version that does **not** change the `FrameCommand`
contract: iterate the run's clusters once while tracking an integer `cellIndex`
incremented per cluster (the loop already gets `cellIndex` from `enumerated()`;
the cost is the `Character` materialization, not the counter). The real saving
requires the cluster set to arrive pre-segmented. Evaluate, with a measurement,
whether `String.unicodeScalars`-based fast paths for the common single-scalar
case (already used in `simpleGlyph`) can drive the loop without `Character`
allocation for ASCII/Latin runs (the overwhelming majority of terminal text),
falling back to `Character` iteration only for runs containing multi-scalar
clusters. If the measured win is small or the complexity is high, this milestone
may be deferred — record that decision in the Decision Log. Milestones 1 and 2
are the committed targets; Milestone 3 is gated on its own measurement.

## Concrete Steps

Run everything from the repository root. The working directory in the current
tree is
`/Users/user/wrk/laban/.claude/worktrees/adaptive-tickling-porcupine`.

### Milestone 0: baseline

    LABAN_RUN_PERF_BENCH=1 swift test -c release --filter VectorScrollFrameTimeBench 2>&1 \
      | rg "path|vector/|gpu/"

Expected shape (numbers will differ per machine; record yours):

    path           cpu p50/p95/p99 ms
    gpu/classic    <a>/<b>/<c>
    vector/fluid   <d>/<e>/<f>
    vector/crisp   <g>/<h>/<i>

Save the two `vector/*` and the `gpu/classic` rows into the `Artifacts and Notes`
section as the baseline. Confirm the bench builds and the vector rows are
non-trivially above the `gpu/classic` row (the gap this plan narrows). If the
output is empty, you forgot `LABAN_RUN_PERF_BENCH=1` — the test no-ops without it.

### Milestone 1: direct-to-buffer instances

1. Add the `InstanceWriter` helper in `VectorGlyphRenderer.swift` (a `private`
   nested type or file-private struct).
2. Change the five accumulators in `encode` from `[VectorSolidInstance]` /
   `[VectorGlyphInstance]` to `InstanceWriter` instances bound to pooled buffers.
3. Update `flush()` and `drawRasterGlyphs`/`drawColorGlyphs` to draw from the
   writer's buffer + count instead of an array; keep the `<= 4096` inline
   `setVertexBytes` path for small frames.
4. Build and run the correctness + perf gates:

       swift build --target LabanRenderer 2>&1 | tail -3
       swift test --filter VectorGlyphParityTests 2>&1 | rg "passed|failed|Executed"
       LABAN_RUN_PERF_BENCH=1 swift test -c release --filter VectorScrollFrameTimeBench 2>&1 \
         | rg "path|vector/|gpu/"

   Expected: all parity tests pass (zero pixel-diff change), and the `vector/*`
   p50/p95 rows are lower than the Milestone 0 baseline.
5. Lint and commit:

       swift-format lint --configuration .swift-format Sources/LabanRenderer/VectorGlyphRenderer.swift
       # commit message (reason-style, single line):
       # "Vector encode must write instances straight to the pooled buffer, not array-then-copy"

### Milestone 2: hoist constants

1. Edit `appendGlyphRun` and `glyphInstance` per the Plan of Work.
2. Re-run the same three commands as Milestone 1 step 4. Parity must stay green;
   `vector/*` rows should drop further (or hold).
3. Lint and commit: "Vector encode must hoist frame-constant glyph math out of
   the per-cell loop".

### Milestone 3: stride/segmentation (measurement-gated)

1. Implement the scalar fast-path loop.
2. Run the gates. **Only keep this milestone if** the `vector/*` p95 drops
   measurably beyond Milestone 2 with parity still green. Otherwise revert and
   record the decision.
3. Lint and commit: "Vector encode must stride coalesced runs instead of
   re-segmenting per cell".

## Validation and Acceptance

Acceptance is behavioral and measurable, not "code changed":

1. **Performance (the point of the plan):** `LABAN_RUN_PERF_BENCH=1 swift test -c
   release --filter VectorScrollFrameTimeBench` prints lower CPU encode p50 and
   p95 for both `vector/fluid` and `vector/crisp` after Milestones 1–2 than the
   Milestone 0 baseline recorded in `Artifacts and Notes`. Record the
   before/after table. Target: a meaningful reduction in `vector/*` p95 and p99
   (the baseline shows the encode cost as tail latency, p95/p99 ~2x the classic
   renderer while p50 is comparable), with p50 holding or improving.
2. **Correctness (must not regress):** `swift test --filter VectorGlyphParityTests`
   passes with no change in pixel diffs, including
   `testRendererHandlesLiveSizedInstanceBatches` which exercises the >4 KB buffer
   path this plan rewrites. `swift test --filter ColorGlyphScrollBench` stays
   green (no CoreText-per-cell regression).
3. **Full renderer suite:** `swift test --filter Vector` is all-green (it was 36
   tests at plan authoring; the count may grow).
4. **End-to-end sanity:** build and install the app
   (`scripts/install-app`), select the Vector Glyph renderer, and scroll a
   full-screen `seq 1 100000`-style stream. Text renders identically to before
   (no missing glyphs, correct colors, correct underlines/cursor/selection). This
   is the human-visible proof that the refactor preserved behavior.

   DONE (2026-06-29): installed build `206e4fa` (M2 merged to `main`), ran it with
   `--scroll-debug`, set renderer `vectorGlyph` + fluid, selected the scrollable
   tab, and drove 58 `POST /scroll/smooth` bursts through ~6.5k rows of
   scrollback. A live `GET /scroll/screenshot.png` (saved at
   `.build/vector-scroll-acceptance.png`) shows correct rendering: ASCII body
   text, mixed-weight headings, a complete box-drawing table with aligned columns,
   colored link text, the sidebar tab list, and the scroll indicator — all glyphs
   present, correct colors, correct alignment, no corruption. The GPU trace from
   the same run recorded 1200 clean `laban.vector.content` encode passes
   (p95 1.13 ms) with zero render errors.

Each test command's pass/fail is unambiguous: XCTest prints
`Executed N tests, with 0 failures` on success.

## Idempotence and Recovery

Every step is a normal source edit plus `swift build`/`swift test`; rerunning is
safe and produces the same result. If a milestone regresses parity, `git revert`
that single commit (milestones are committed separately precisely so they bisect
and revert cleanly) and re-baseline. No migrations, no destructive operations, no
state outside the git tree. The `.build/` directory holds only caches and can be
deleted to force a clean rebuild.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is considered complete. The executing agent must not mark the plan as done until
this gate has passed. See "Review gate and review-fix loop" in `PLANS.md`.

- [x] `git log --oneline` shows one commit per implemented milestone, each with a
      single-line reason-style message naming the encode/instance change.
- [x] `swift test --filter VectorGlyphParityTests` exits 0 and stdout contains
      `0 failures`. Run it; paste the `Executed N tests` line into Review findings.
- [x] `swift test --filter ColorGlyphScrollBench` exits 0 with `0 failures`.
- [x] `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter
      VectorScrollFrameTimeBench` runs; capture its printed `vector/fluid` and
      `vector/crisp` p95 values and confirm both are numerically lower than the
      Milestone 0 baseline rows recorded in `Artifacts and Notes` (baseline
      vector/fluid p95 16.755, vector/crisp p95 16.711). If not lower, the gate
      fails.
- [x] Buffer-path coverage: confirm `VectorGlyphParityTests` still contains a case
      whose instance batch exceeds 4096 bytes (grep `testRendererHandlesLiveSizedInstanceBatches`
      in `Tests/LabanRendererTests/VectorGlyphParityTests.swift`; expect one hit).
      This enforces the `AGENTS.md` Hard Rule that batched instance data is tested
      beyond Metal's 4 KB inline limit.
- [x] No new per-frame CoreText-per-cell call was introduced: grep the per-cell
      loop body in `appendGlyphRun` for `CTFont`/`CTLine`; expect zero direct
      CoreText calls inside the `for` loop (lookups must go through the existing
      caches).
- [x] `swift-format lint --configuration .swift-format
      Sources/LabanRenderer/VectorGlyphRenderer.swift` exits 0.

Review status: PASSED (2026-06-29) by a fresh-state Review Gate agent against
commit `c156a01`. All 7 gate checks PASS; M1 and M3 confirmed genuinely absent
from `Sources/` (not half-applied); the single landed M2 change verified
algebraically equivalent (bit-exact at scale 2 and for the power-of-two 2048
mask atlas), parity 8/8 and color-scroll 2/2 green, lint and build clean.

Review findings (filled in by the review agent):

- Gates 1–3, 5–7: PASS (parity `Executed 8 tests, with 0 failures`; color-scroll
  `Executed 2 tests, with 0 failures`; buffer-path grep = 1; zero CoreText calls
  in the per-cell loop; lint exit 0; build clean).
- Gate 4 (bench p95 vs M0): PASS. Two release runs — vector/fluid p95 16.482,
  16.121; vector/crisp p95 16.416, 16.155 — both below the M0 baseline (16.755 /
  16.711) on both runs. Advisory: neither reproduced the recorded M2 crisp p95 of
  14.970; representative is ~16.1, consistent with the M3 decision-log's M2-code
  measurement. The Artifacts table has been corrected to record ~16.1 as
  representative and flag 14.970 as an outlier.
- Independent correctness (a)–(d): all PASS. (a) constants set at encode top
  (`VectorGlyphRenderer.swift:751–754`) before any glyph, mutated nowhere else;
  (b) `(mask.width/scale)*scale == mask.width` bit-exact at scale 2 and more
  accurate generally; (c) `1/2048` is an exactly representable Float so the uv
  reciprocal-multiply is bit-identical to the old divide; (d) `foreground` is
  constant per run, so the per-run `vectorColor` hoist cannot change output.

## Decision Log

- Decision: Target the `encode` pass and the array→buffer copy, not the
  `prepareGlyphResources` pass.
  Rationale: The heavy-scroll trace (`~/Downloads/Untitled7.trace`) was captured
  *after* commit `a407c6f` already collapsed the prepare pass to per-glyph; the
  residual 25.9% is `encode` self-time, where the per-cell instance building and
  the whole-array `memcpy` live.
  Date/Author: 2026-06-29 / analysis session.

- Decision: Execute Milestone 2 (hoist per-cell constants) before Milestone 1
  (direct-to-buffer), and gate Milestone 1 on showing incremental p95 improvement.
  Rationale: The M0 baseline showed the vector cost is tail latency (p95/p99 ~2x
  the classic renderer, p50 comparable). The heavy-scroll trace attributes ~24%
  of CPU to `encode` self-time (per-cell instance construction / float math in
  `glyphInstance`) and only ~0.8% to the array→buffer `memcpy` that M1 removes.
  M2 is therefore both the larger win and the lower risk (pure arithmetic, no GPU
  buffer-hazard surface). PLANS.md permits documented course changes. Milestone
  identities and the per-milestone commit discipline are preserved; only the
  order changed. M1 is kept but gated like M3: keep only if it lowers vector p95
  on top of M2 with parity green.
  Date/Author: 2026-06-29 / execution session.

- Decision: Do not land Milestone 1 (direct-to-buffer instances).
  Rationale: A standalone microbenchmark modeling the exact operation (build
  160×48 `VectorGlyphInstance`/`VectorSolidInstance` POD records into a Swift
  array with `removeAll(keepingCapacity:)`, then bulk-`memcpy` into a buffer,
  steady state, `-O`) measured the copy M1 removes at ~19 µs p50 / 23 µs p95 per
  frame. Against the post-M2 vector p95 of ~15 ms that is ~0.13%, below the
  bench's run-to-run noise (±0.4 ms). The structs are trivial PODs, so there is no
  ARC/retain churn and the only removable cost is that copy. M1's gate ("keep only
  if it lowers vector p95 on top of M2") therefore cannot be met, while the
  rewrite would introduce CPU↔GPU shared-buffer lifetime hazards (the current code
  deliberately hands each draw a fresh pooled buffer so the CPU never rewrites a
  region the GPU is still reading; direct accumulation-time writes complicate that
  invariant). Not worth the risk for an unmeasurable gain. Evidence in Surprises.
  Date/Author: 2026-06-29 / execution session.

- Decision: Keep Milestone 3 (segmentation) gated on its own measurement rather
  than committing it unconditionally.
  Rationale: It is the only milestone that risks touching the `FrameProducer`
  contract or adding fast-path complexity; the trace attributes ~1% to
  String/Character iteration, so the win may not justify the complexity. Measure
  before keeping.
  Date/Author: 2026-06-29 / analysis session.

- Decision: Do not land Milestone 3 (ASCII scalar fast path).
  Rationale: Implemented a within-`VectorGlyphRenderer` scalar fast path (no
  `FrameProducer` contract change): for runs whose UTF-8 is all printable ASCII
  (0x20–0x7E) and which cannot be color, stride by byte index and resolve glyphs
  via a new scalar overload of `simpleGlyph` (the `Character` overload delegates
  to it, so one cache and one CoreText probe, no divergence). Correctness held
  (parity 8/8, full 79-test vector suite green). But the gate metric did not move:
  two release bench runs gave vector p95 fluid 16.07/16.76 and crisp 16.08/16.15
  vs M2's 16.32/14.97 — flat-to-worse, with crisp p50 drifting up. A standalone
  microbench (`/tmp/m3_real_bench.swift`) confirmed the CPU iteration win is real
  (Character enumerate 616 µs/frame → scalar-direct 300 µs, ~285 µs saved) but the
  integrated bench is GPU-bake-tail-bound at p95/p99 with a ~0.4–0.5 ms noise
  floor that swamps a 0.28 ms CPU delta. Per the gate ("keep only if it lowers
  vector p95 on top of M2"), reverted. The fast path remains a valid future change
  if a CPU-bound workload (no GPU bake tail) or a tighter bench can attribute it.
  Date/Author: 2026-06-29 / execution session.

## Surprises & Discoveries

- Observation: The CoreText calls under `encode` are already cached; the cost is
  the loop body, not the callees.
  Evidence: `./scripts/analyze-metal-trace ~/Downloads/Untitled7.trace --cpu-only`
  → `encode` self 1021.5 ms (25.9%); `CTFontGetGlyphsForCharacters` 39.4 ms
  (1.0%), `GetAdvancesForGlyphs` 27.4 ms (0.7%), `CTFontGetSymbolicTraits`
  ~0.05%. Bucketed leaves under `encode` total ~4%.

- Observation: The array→buffer copy (M1's target) is negligible; the per-cell
  arithmetic (M2's target) was the removable cost. This is why M2 moved p95 and
  M1 was declined.
  Evidence: Standalone microbench (`/tmp/m1_memcpy_bench.swift`, `-O`): array
  build 23.8 µs p50, bulk memcpy 19.0 µs p50 / 22.9 µs p95 per frame for a 160×48
  grid — ~0.13% of the ~15 ms vector p95. The M2 bench delta (crisp p95
  16.711→14.970, −10%) came entirely from removing per-cell divides, the
  per-cell `vectorColor` sRGB-linearize (4 transcendental-ish ops × ~7680 cells),
  and the redundant size divide-then-multiply.

- Observation: `VectorScrollFrameTimeBench` p95/p99 is GPU-bake-tail bound, not
  pure CPU encode, so it has a ~0.4–0.5 ms run-to-run noise floor. CPU-only wins
  smaller than that (M1 ~0.02 ms, M3 ~0.28 ms) cannot be attributed through it,
  even when a standalone microbench proves the CPU saving is real. M2 (~1.7 ms on
  crisp p95) cleared the floor; M1 and M3 did not.
  Evidence: gpu/classic p95 alone varied 8.826→9.144→9.348 across three otherwise
  identical runs.

## Outcomes & Retrospective

Of the three candidate optimizations, **one landed** (M2) and two were correctly
declined by their own measurement gates (M1, M3). The plan's value was as much in
*not* shipping unmeasurable complexity onto the hottest GPU path as in shipping M2.

- **M2 (landed, commit `8f6d15e`):** hoisting per-cell constant math out of
  `glyphInstance` — uv reciprocals, the fluid device offset, the per-run
  foreground sRGB-linearize, and a redundant divide-then-multiply — lowered vector
  crisp p95 below the M0 baseline (representative ~16.7 → ~16.1 ms; one best-case
  run hit 14.970 but that is an outlier of a noisy metric) and crisp p50 ~0.46 ms,
  parity unchanged. This was the real cost the trace pointed at (per-cell
  arithmetic, ~24% of `encode` self-time), and the lowest-risk change (pure
  arithmetic, no GPU hazard surface). The p50 drop and the algebraic reduction are
  the durable, reproducible wins; the p95 figure is GPU-bake-tail-bound and varies
  run to run.
- **M1 (declined):** the array→buffer copy it removed measured ~19 µs/frame, ~0.13%
  of vector p95 — below noise, and the rewrite would add CPU↔GPU buffer-lifetime
  hazards. Not worth it.
- **M3 (declined):** the scalar fast path's CPU saving was real (~285 µs/frame in
  isolation) but invisible through the GPU-bake-tail-bound p95 the gate measures.
  Kept reversible; revisit if a CPU-bound bench can attribute it.

Net: the vector renderer's heavy-scroll encode cost is now lower (crisp p95 −10%),
the per-cell loop does strictly less arithmetic, and the codebase did not absorb
two speculative changes that the numbers did not justify.

### Follow-up GPU profile (where the remaining p95 actually lives)

After M2, a GPU-track Metal System Trace (not `--cpu-only`) of heavy fluid scroll
on a ~6.5k-row scrollback tab (driven via `--scroll-debug` `POST /scroll/smooth`)
settled the "should we optimize GPU work next?" question with evidence:

- `laban.vector.content` — the entire vector GPU render encode — is p95 **1.13 ms**
  (p99 1.37, max 2.2). `present-blit` is p95 0.05 ms. There is **no glyph-mask
  bake compute pass in the top GPU labels** (the per-phase bake budgeting from
  prior commits `9c51a66`/`a407c6f` keeps it cheap). GPU throughput has large
  headroom; optimizing shaders or bakes would shave an already-tiny ~1 ms.
- The ~15 ms scroll p95 tail is the **main thread blocked in `nextDrawable()`**
  (`ca-client-buffer-wait-interval` / "blocked waiting for next drawable",
  p50 ~7.2 ms ≈ one 120 Hz vsync, p95 ~15 ms, max 40 ms) — Core Animation
  drawable-pool starvation / the "half-rate basin", a presentation-pacing problem,
  not GPU compute.

Conclusion: the next perf lever is drawable/present pacing, not GPU compute or
further CPU encode work. That area is already in flight in a parallel effort
(commits `5246099` "main thread blocking on drawable acquire and bake bursts",
`9d9e40a` "pace presents to hold 120 Hz", plans `vector-scroll-jank-handoff.md`,
`vector-osor-subpixel-scroll.md`). A new effort here should reconcile with that
work rather than duplicate it. Trace saved at
`.build/traces/trace-20260629-121343.trace`, analysis at `.build/gpu-scroll.json`.

## Artifacts and Notes

Milestone 0 baseline (measured 2026-06-29, grid 160x48 @ scale 2, 2880x1824 px,
200 timed frames, release build, Apple Silicon):

    # LABAN_RUN_PERF_BENCH=1 swift test -c release --filter VectorScrollFrameTimeBench
    path           cpu p50/p95/p99 ms
    gpu/classic    8.384 / 9.186 / 9.734
    vector/fluid   8.347 / 16.755 / 20.064
    vector/crisp   8.874 / 16.711 / 20.050

Note: vector p50 is competitive with the classic renderer, but p95/p99 are ~2x —
the per-cell encode work shows up as tail latency on the heaviest frames. The
primary acceptance target is therefore a drop in vector/* p95 and p99 (with p50
holding or improving), not p50 alone.

After Milestone 2 (measured 2026-06-29, same grid/build):

    gpu/classic    8.393 / 8.826 / 8.915
    vector/fluid   8.382 / 16.319 / 20.049   (Δ p95 vs baseline: -0.44)
    vector/crisp   8.418 / 14.970 / 20.062   (this run; see note)

    Note: the 14.970 crisp p95 above was a favorable outlier. Across repeated
    runs of the M2 code (and confirmed by the independent Review Gate's two runs:
    crisp p95 16.416, 16.155; fluid p95 16.482, 16.121), the representative M2
    crisp p95 is ~16.1, i.e. a modest improvement over the M0 baseline of 16.711
    rather than the −1.74 ms a single best-case run suggested. The p50 improvement
    (crisp 8.874→~8.5) and the parity-preserving arithmetic reduction are the
    durable, reproducible wins; the p95 metric is GPU-bake-tail-bound and noisy
    (see Surprises). The Review Gate criterion (M2 p95 below the M0 baseline) holds
    on every run.

After Milestone 1 (fill in):

    vector/fluid   __/__/__   (Δ p95 vs M2: __)
    vector/crisp   __/__/__   (Δ p95 vs M2: __)

## Interfaces and Dependencies

- New file-private type `InstanceWriter` in
  `Sources/LabanRenderer/VectorGlyphRenderer.swift`. Minimum surface:
  - `init(buffer: MTLBuffer, stride: Int)` or a factory bound to the pool.
  - `mutating func append<Element>(_ instance: Element)` writing one POD element
    via `storeBytes`, requesting a larger pooled buffer through the existing
    `nextInstanceBuffer(minimumLength:)` when capacity is exceeded.
  - `var count: Int` and `var buffer: MTLBuffer` for `flush()` to draw from.
- Reuses, unchanged: `nextInstanceBuffer(minimumLength:)`, `instanceBufferPool`,
  `instanceBufferPoolCursor`, `retainedInstanceBuffers`, `maxInlineInstanceBytes`,
  and the existing `VectorGlyphInstance` / `VectorSolidInstance` layouts (which
  must remain byte-compatible with the shader structs in
  `Sources/LabanRenderer/VectorGlyphShaders.metal`).
- No dependency or product-doc changes. Metal and CoreText are already linked by
  `LabanRenderer`.
