# Move terminal cell rendering onto the GPU (persistent cell buffer, incremental CPU updates)

## Purpose / Big Picture

When an agent (e.g. a Claude or Codex session) streams output into a Laban tab,
Laban burns **~16–23% of one CPU core** continuously. Profiling on the real
(release) build shows this is **CPU-render-bound, not GPU-bound**: the GPU is
**0.44% utilized** while the CPU rebuilds the *entire* on-screen frame — snapshot
→ command list → per-glyph instance list → Metal command-buffer encode — on every
output tick, even though a terminal screen is ~99% unchanged frame-to-frame.

After this change, the per-frame CPU cost of rendering scales with the number of
**cells that actually changed**, not the whole screen. The terminal grid lives in
a **persistent GPU buffer** (one entry per cell) that the GPU re-draws every frame
from its own memory; the CPU only **patches the cells in dirty rows** and issues a
single instanced draw. The idle GPU absorbs the per-frame work it is built for.

**Observable outcome a human can verify:** with an agent streaming a large log,
`~/Laban.app` CPU (Activity Monitor or `ps -o %cpu`) drops materially from the
current ~16–23% toward roughly half of the render portion, *with no visible change
to what is drawn* — proven by a pixel-for-pixel identical-output test and by a
release-mode microbench that shows per-frame render CPU falling as the dirty-row
fraction shrinks.

**Term definitions (plain language, used throughout):**

- **Cell**: one character box in the terminal grid (a column × row position).
- **Glyph atlas**: a single GPU texture holding the rasterized alpha mask of every
  distinct character seen so far. Code: `Sources/LabanRenderer/MetalGlyphAtlas.swift`.
- **Instance / instanced draw**: Metal draws one quad (two triangles) per
  "instance"; the vertex shader is invoked per-instance with `instance_id`. The
  current renderer already builds one instance per glyph on the CPU.
- **FrameCommand**: a flat drawing instruction (a background rect or a run of
  same-styled glyphs). Produced by `FrameProducer`. Code:
  `Sources/LabanRenderer/FrameCommand.swift`.
- **Damage / `RenderDamage`**: which rows changed this frame. `.full` = redraw
  everything; `.partial(yRanges:)` = only these vertical pixel ranges changed.
  Code: `Sources/LabanRenderer/` (the `RenderDamage`/`DirtyYRange` types) and the
  producer `TerminalSurfaceController.computeDamage`
  (`Sources/LabanCore/TerminalSurfaceController.swift:590`).
- **Persistent target texture**: an offscreen GPU texture that survives between
  frames; on partial damage the renderer preserves it (`loadAction = .load`) and
  only redraws the dirty scissor region. Already exists in `MetalRenderer`.
- **Pixel-parity**: two render paths produce byte-for-byte identical output
  bitmaps. Verified via `MetalRenderer.captureMode` + `MetalRenderer.pngData`
  (a CPU readback of the rendered texture), already used by
  `Tests/LabanRendererTests/MetalFrameTimingBench.swift`.

## Progress

- [ ] M0 — Flag + pixel-parity harness (GPU path initially delegates to the current path)
- [ ] M1 — Text-only GPU cell path, whole-buffer rebuild each frame, pixel-identical to current
- [ ] M2 — Persistent cell buffer + dirty-row-only patching (the CPU win)
- [ ] M3 — Feature parity (wide/cluster glyphs, box-drawing rects, decorations, selection/find, cursor, smooth-scroll, faint/inverse)
- [ ] M4 — Make GPU path default; record ADR; remove or demote the flag
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
scratch.** The single highest-leverage move is to stop rebuilding unchanged cells
on the CPU and let the GPU re-draw a persistent grid.

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
     preserved from the previous frame in the persistent target texture.
3. `Sources/LabanRenderer/Shaders.metal` — `solid_vertex/solid_fragment`,
   `glyph_vertex/glyph_fragment`. Quads are unit squares expanded from
   `kQuadVertices`; `GlyphInstance` carries `{origin, size, uvOrigin, uvSize, color}`.
   The atlas is an `r8Unorm` alpha mask sampled and tinted by the instance color.
4. `Sources/LabanRenderer/MetalGlyphAtlas.swift` — `entry(character:font:boldFallback:
   italicFallback:) -> Entry?` returns the atlas tile for a glyph:
   `{pixelWidth, pixelHeight, originX, originY, logicalOriginX, logicalWidth}` (atlas
   pixel rect + sub-cell layout offsets). The atlas **grows by reallocation** when
   full; when it grows, all tile origins change (relevant to buffer invalidation).
5. Damage source: `Sources/LabanCore/TerminalSurfaceController.swift:590`
   (`computeDamage`) reads `snapshot.dirty_rows` (one byte per row) and emits tight
   per-row `.partial(yRanges:)`. So **precise per-row dirty information already
   exists** and reaches `MetalRenderer.render` via `surfaceFrame.damage`
   (`Sources/LabanApp/TerminalBitmapView.swift:1155`).

### Key insight that shapes the design

The renderer is **already GPU-instanced** — the GPU already expands quads from
CPU-built instances. So "move rendering to the GPU" does **not** mean writing a
fancier shader. It means: **stop rebuilding the instance set on the CPU every
frame.** Keep one instance *per cell* in a persistent GPU buffer indexed by
`row * cols + col`, and each frame only overwrite the cells in dirty rows. The GPU
re-draws the whole grid from its buffer (cheap — it is 99.6% idle). The CPU's
per-frame cost becomes O(changed cells).

## Decision Log

- **Persistent per-cell GPU buffer, not transient damage-scoped instance build.**
  An alternative ("damage-scoped") keeps the current transient instance arrays but
  only builds instances whose Y overlaps the dirty scissor box — provably
  pixel-identical because the scissor already clips the rest. It is lower-risk and
  ~7% absolute CPU. We chose the persistent-buffer approach because it (a) exploits
  the idle GPU more directly, (b) yields a cleaner O(dirty cells) CPU cost without
  the scissor/`.load`/background-rect interactions, and (c) is the architecture GPU
  terminals (kitty, Alacritty, Ghostty) converge on. The damage-scoped variant
  remains a valid fallback if M2 proves too risky; record that pivot here if taken.
- **Correctness contract = pixel-parity (byte-identical readback), not eyeballing.**
  The renderer ships on `main`; any visible regression is unacceptable. We compare
  `MetalRenderer.pngData` of the new path against the current path for a battery of
  frames including scroll, selection, find, resize, clusters, and box-drawing.
- **M1 feeds the cell buffer from existing `FrameCommand`s; M2+ reads the snapshot
  cells directly.** Feeding from `FrameCommand`s in M1 reuses `FrameProducer`'s
  already-correct foreground/background/attribute/cluster logic, so parity is
  achievable before we bypass it. The CPU win requires reading only dirty rows,
  which means going to the snapshot cells directly (M2). Bypassing `FrameProducer`
  is the larger correctness surface, hence staged.
- **Every change must earn its keep via a release microbench, or it is reverted —
  not merged.** This is a hard gate, not advice. Before landing any milestone or
  sub-change, run its microbench `-c release` and compare against the baseline
  captured at the start of that milestone. Keep the change only if it shows a net
  win (for the perf milestone M2) or provably no regression (for parity-only
  milestones M0/M1/M3); otherwise `git checkout` it and record why in
  `Surprises & Discoveries`. This is exactly what happened in the prior session: a
  `String(unsafeUninitializedCapacity:)` micro-fix was implemented, measured in
  release, found to *regress* (text 0.145→0.169 ms), and reverted — it did not
  reach `main`. Do the same here. **All benchmarks run `-c release`.** Debug builds
  do not specialize Swift generics and badly mislead (the merged `FrameProducer`
  Span change measured −40% in debug but is a 5–7× speedup in release; the String
  micro-fix above looked neutral in debug but regressed in release). See Surprises.
- **Ship behind a flag (`MetalRenderer.useGPUCellPath`), default off until M4.**
  Same `nonisolated(unsafe) static var` toggle pattern as the two merged changes,
  so the A/B path and the parity test live in one binary.

## Plan of Work

Each milestone is independently verifiable and leaves the app working with the GPU
path **off by default** until M4. Build the app with `./scripts/build-app`
(debug) or `./scripts/install-app` (profilable release to `~/Laban.app`). Run unit
tests with `swift test`; run release microbenches with
`LABAN_RUN_PERF_BENCH=1 swift test -c release --filter <name>`. Work from the repo
root `/Users/rrj/wrk/laban` (or a git worktree of it).

### M0 [P0] Flag + pixel-parity harness

**Scope.** Add `nonisolated(unsafe) public static var useGPUCellPath = false` to
`MetalRenderer`. Add a render-path branch in `render(...)` that, when the flag is
on, currently just calls the existing path (no behavior change yet). Add a new test
`Tests/LabanRendererTests/GPUCellParityTests.swift` that renders a battery of frames
through both flag states using `captureMode`/`pngData` and asserts the PNG bytes are
**identical**. With M0's pass-through GPU path, parity is trivially true — this
proves the harness itself is sound and reusable for M1–M3.

**What exists at the end:** a parity harness and a flag; `swift test --filter
GPUCellParityTests` passes; no rendered output changes.

**Acceptance:**
```
swift test --filter GPUCellParityTests
# -> all parity cases pass (PNG bytes identical between flag on/off)
```

### M1 [P0] Text-only GPU cell path (whole-buffer rebuild), pixel-identical

**Scope.** Add a per-cell instance struct and shaders that compute a cell's screen
position from its grid index instead of from a CPU-supplied origin:
- In `Shaders.metal`: a `CellGlyph` struct `{ float2 uvOrigin; float2 uvSize;
  float2 sizePx; float originXPx; uint flags; float4 fg; }` and a `cell_glyph_vertex`
  that reads `instance_id` as a cell index, derives `col = id % cols`,
  `row = id / cols`, computes the pixel origin from grid uniforms
  `{cols, rows, cellAdvancePx, cellHeightPx, originXPx, originYPx}` + the existing
  `Uniforms`, and emits the glyph quad sampling the atlas exactly like
  `glyph_vertex`. A matching `cell_bg_vertex`/reuse of `solid` for per-cell
  backgrounds. Add the new grid uniforms to the `Uniforms` struct (Swift + Metal
  must stay byte-identical in layout).
- In `MetalRenderer`: build pipelines for the new shaders; when `useGPUCellPath`,
  fill a CPU `[CellGlyph]` of size `cols*rows` (empty cells get `flags=0`/zero size)
  **from the current `[FrameCommand]` glyph runs** (expand each run into per-cell
  entries; reuse `MetalGlyphAtlas.entry`), upload it, and draw `instanceCount =
  cols*rows`. Background: a parallel per-cell bg buffer, or keep the existing solid
  background path unchanged (simplest: reuse current backgrounds, only move glyphs
  to the cell path in M1). **Fall back to the current path** for any frame whose
  commands include non-plain-glyph content the cell path does not yet handle
  (procedural box-drawing `.rect`s with `source == .terminal` beyond backgrounds,
  decorations, etc.) so M1 never renders wrong.

**What exists at the end:** a working GPU cell glyph pipeline; for plain-text
frames, output is byte-identical to the current renderer. No CPU win yet (whole
buffer rebuilt each frame).

**Acceptance:**
```
swift test --filter GPUCellParityTests
# -> plain-text fixtures pass with GPU path ON (byte-identical)
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench
# -> GPU path frame CPU is within noise of current (no regression); records baseline
```

### M2 [P1] Persistent cell buffer + dirty-row-only patching — THE CPU WIN

**Scope.** Make the cell buffer **persistent** (a member, indexed `row*cols+col`)
and a CPU mirror alongside it. Each frame:
- On `.full` damage, resize, theme change, or **glyph-atlas regrow** (tile origins
  move), rebuild the whole buffer.
- On `.partial(yRanges)`, map the dirty `yRanges` back to row indices, and for each
  dirty row: clear that row's cells in the buffer, then re-fill them (atlas lookup +
  `CellGlyph` write). Upload only the changed byte range(s) of the buffer
  (`MTLBuffer.contents()` is `storageModeShared`; write in place, no per-frame
  allocation). Draw the whole grid (`instanceCount = cols*rows`).
- Source the per-cell data **directly from the snapshot cells** (bypass
  `FrameProducer` for the cell path) so only dirty rows are read. Reproduce
  `FrameProducer`'s foreground/background/attribute resolution for plain glyphs;
  validate against the `FrameProducer` path via the parity harness.

**What exists at the end:** per-frame render CPU scales with dirty rows. On a mostly
static screen with a few changing lines, `buildInstanceList`-equivalent work drops
~5–20×.

**Acceptance (must show the win, release mode):**
```
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter <new dirty-row microbench>
# -> "1 dirty row" frame CPU is dramatically lower than "full screen" frame CPU,
#    and lower than the current renderer's per-frame CPU on the same dirty set.
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

### M3 [P1] Feature parity — remove the fallback

**Scope.** Extend the cell path to every terminal feature, each validated
pixel-identical via the parity harness before enabling it (add a fixture per
feature): wide/CJK and combining/ZWJ clusters (a cluster spans one wide cell +
spacer-tail; the cell entry must carry the composed glyph), **procedural
box-drawing rects** (currently CPU-emitted `.rect`s in `FrameProducer` /
`BoxDrawing`; the gnarliest case — either emit them as extra per-cell instances or
keep a small CPU side-channel), decorations (underline styles, strikethrough,
overline; currently `TextDecorationLayout`), selection / find highlights, the
cursor overlay (already a separate pass — keep it), smooth-scroll `contentYOffset`,
and faint/inverse. Remove the M1 fallback only when all fixtures pass with the GPU
path on.

**Acceptance:** every fixture in `GPUCellParityTests` passes with the fallback
removed; the existing suites stay green:
```
swift test --filter 'GPUCellParity|MetalRendererSmoke|MetalRendererClearColor|GraphemeClustering|TextDecorationLayout|FrameProducer'
```

### M4 [P2] Default on + ADR

**Scope.** Flip `useGPUCellPath` default to `true` (keep the flag as an escape
hatch or remove it). Write `docs/adr/0014-gpu-driven-cell-renderer.md` recording the
decision, the profile evidence, and the persistent-buffer architecture. Update
`docs/quality/` if it tracks render performance. Re-run the live before/after.

## Validation and Acceptance

The change is **internal** (same pixels, less CPU), so acceptance is proven three
ways, all reproducible from a clean checkout:

1. **Pixel-parity (correctness).** `swift test --filter GPUCellParityTests` renders
   a battery of frames (plain text, colored backgrounds, wide/CJK, emoji clusters,
   box-drawing, underline/strike/overline, hyperlinks, selection, find, cursor,
   scroll, resize, a row-by-row streaming sequence that exercises partial damage)
   through both the current and GPU paths via `captureMode`/`pngData` and asserts
   the PNG bytes are identical. **On any mismatch the test must emit an actionable
   pixel diff, not just "failed":** decode both PNGs to raw RGBA and report (a) the
   fixture name and grid size, (b) the first differing pixel as `(x, y)` with its
   expected vs actual RGBA values, (c) the total count of differing pixels and the
   maximum per-channel delta, and (d) write `<fixture>.expected.png`,
   `<fixture>.actual.png`, and `<fixture>.diff.png` (the diff highlighting differing
   pixels, e.g. magenta on black) to `LABAN_ARTIFACTS` (default `.artifacts/`) for
   inspection. "Identical" means **zero** differing pixels — there is no tolerance
   threshold; a single differing pixel fails the gate. This is the gate for every
   milestone that enables new GPU coverage.
2. **Performance (the point), release only.**
   `LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench`
   and a new dirty-row microbench must show per-frame render CPU falling with the
   dirty-row fraction, and not regressing on full-screen frames. Numbers are printed
   (mean/p50/p99 ms per frame); record them in `Outcomes & Retrospective`.
3. **Live before/after.** Build `./scripts/install-app`, relaunch `~/Laban.app`,
   stream a large file in a tab, and capture an Instruments Time Profiler
   (`xcrun xctrace record --template "Time Profiler" --attach <pid> --time-limit 18s`).
   `FrameProducer.commands` + `buildInstanceList` + `MetalRenderer.render` encode
   share must drop substantially versus the `15fb668` baseline in this plan, with
   GPU utilization staying near 0.4% (Metal System Trace).

The existing renderer test suites must stay green at every milestone:
`MetalRendererSmokeTests`, `MetalRendererClearColorTests`,
`CrossBackendBitmapTests` (note: these spawn `laband`/`labpty` daemons and may
time out in sandboxed CI — they fail the same way on `main`, so treat a daemon
`ETIMEDOUT` as environmental, not a regression), `GraphemeClusteringTests`,
`TextDecorationLayoutTests`.

## Review Gate

A fresh review agent (no prior context; given this ExecPlan, the milestone under
review, the changed files, and `AGENTS.md`) must verify, per milestone:

- [ ] `GPUCellParityTests` exists, runs, and asserts **byte-identical** PNG output
      between the current and GPU paths for the fixtures claimed complete in the
      milestone (read the test; confirm it compares bytes, not just shapes).
- [ ] The GPU path is genuinely exercised (flag flips actually change the code path;
      confirm the new pipeline/shaders are used, e.g. by a counter or by temporarily
      breaking the GPU path and seeing parity fail).
- [ ] For M2+: the dirty-row microbench is **release** (`-c release`) and shows a
      real reduction; debug-only numbers do not count.
- [ ] Earn-its-keep was applied: every landed sub-change has a release microbench
      showing a net win (or no regression for parity-only work). Any change that did
      not earn its keep was reverted and the reversion is recorded in
      `Surprises & Discoveries` (not silently kept).
- [ ] On a parity failure the test emits the actionable pixel diff (first differing
      `(x,y)` + RGBA, differing-pixel count, and `expected/actual/diff.png`
      artifacts), and the gate is zero-tolerance (a single differing pixel fails).
- [ ] No new per-frame heap allocations in the GPU path (buffers reused like
      `ensureBuffer`; cell buffer is persistent; `storageModeShared` writes in place).
- [ ] Existing renderer suites green (or failing only via the known environmental
      daemon timeout, identical to `main`).
- [ ] Records the commit SHA reviewed and a one-line summary; on failure, lists
      concrete file:line findings.

## Surprises & Discoveries

- **The GPU is 0.44% utilized; Laban is CPU-render-bound.** (Metal System Trace,
  commit `15fb668`.) This is the entire justification for the plan.
- **The renderer is already GPU-instanced.** The win is *incremental/persistent
  buffers*, not a new shader. Do not be misled into writing a clever fragment
  shader; write a persistent cell buffer with dirty-row patching.
- **Debug benchmarks lie.** Always `-c release`. A prior `String` micro-fix looked
  neutral in debug and *regressed* in release; the `FrameProducer` Span change was
  −40% in debug but 5–7× in release. Bench harnesses already gate on
  `LABAN_RUN_PERF_BENCH=1` and assume release.
- **Partial damage already scissors + `.load`s.** Off-scissor instances are already
  clipped, which is why the lower-risk "damage-scoped" alternative (Decision Log)
  would be provably pixel-identical. Keep it in pocket as a fallback for M2.
- **`computeDamage` already emits tight per-row dirty ranges** from
  `snapshot.dirty_rows` (`TerminalSurfaceController.swift:590`). M2 does not need new
  dirty-tracking; it needs to consume what exists.
- **Glyph-atlas regrow invalidates the whole cell buffer** (tile origins change on
  reallocation). M2 must rebuild on regrow; missing this would show stale glyphs.

## Idempotence and Recovery

Every step is additive and behind `useGPUCellPath` (default off), so the app keeps
working at all times; reverting is flipping the flag or `git checkout` of the
renderer files. Tests and benches can be re-run freely. If M2's snapshot-direct cell
read proves too risky, fall back to the damage-scoped instance-build variant
(Decision Log) — it reaches a large fraction of the CPU win with provable
pixel-parity and far less surface area — and record the pivot here.

## Interfaces and Dependencies

- Touches only `Sources/LabanRenderer/` (`MetalRenderer.swift`, `Shaders.metal`,
  possibly `MetalGlyphAtlas.swift` for a stable per-glyph index) and new tests under
  `Tests/LabanRendererTests/`. M2's snapshot-direct read also reads the libghostty
  cell struct already consumed by `FrameProducer`
  (`Sources/LabanTerminalCore/include/LabanTerminalCore.h`: `LabanCell`,
  `LabanSnapshot.dirty_rows`).
- Deployment target is `macOS .v13` (`Package.swift`), but the merged Span work uses
  macOS-26 APIs behind `#available`; this plan uses no macOS-26-only APIs (plain
  Metal + buffers), so no availability gating is required.
- ADR boundary: per `AGENTS.md`, a change to "rendering architecture" warrants an
  ADR — written in M4 (`docs/adr/0014-…`).
