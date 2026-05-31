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

**Platform target — macOS 26 first; older OSes stay on the current renderer.**
The GPU-driven cell path is the macOS 26 deliverable and is the thing that lands
first; it is gated `#available(macOS 26, *)`. On macOS 13–25 the flag is inert and
the current (shipped) renderer runs unchanged — those OSes are allowed to stay
slower, by explicit decision (Decision Log). This is the same OS-gated SOTA
dual-path the merged `FrameProducer` Span work uses: a macOS-26 fast path plus an
untouched legacy fallback. Because macOS 26 is the only target for the new path, it
may use macOS-26-only **Metal 4** APIs (M4) for the command-encode win, not just
plain Metal buffers.

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

All milestones gate the GPU path on `#available(macOS 26, *)`; macOS 13–25 keep the
current renderer (Purpose → Platform target).

- [ ] M0 — Flag + pixel-parity harness (GPU path initially delegates to the current path)
- [ ] M1 — Text-only GPU cell path, whole-buffer rebuild each frame, pixel-identical to current
- [ ] M2 — Persistent cell buffer + dirty-row-only patching (the CPU rebuild win)
- [ ] M3 — Feature parity (wide/cluster glyphs, box-drawing rects, decorations, selection/find, cursor, smooth-scroll, faint/inverse)
- [ ] M4 — Metal 4 reusable command buffers + residency sets (the encode win; macOS 26 only)
- [ ] M5 — Make GPU path default on macOS 26; record ADR; remove or demote the flag
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
5. Damage source: `Sources/LabanCore/TerminalSurfaceController.swift:583`
   (`damage(snapshot:…)`) reads `snapshot.dirty_rows` (one byte per row) and emits tight
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

- **Target macOS 26 first; older OSes keep the current renderer (decided).** The
  user's directive: the optimization targets macOS 26 and macOS 26 lands first;
  macOS 13–25 may stay slower. So the whole GPU cell path is gated
  `#available(macOS 26, *)` and the current renderer is the untouched < macOS 26
  fallback (no new work there — it already ships). This is the user's preferred
  OS-gated SOTA dual-path (the merged Span work's pattern). It also brings the
  Metal 4 command-encode win (M4) in-scope, because macOS 26 is the only target for
  the new path — see "Recent-Metal research" in Surprises.
- **Persistent per-cell GPU buffer, not transient damage-scoped instance build.**
  An alternative ("damage-scoped") keeps the current transient instance arrays but
  only builds instances whose Y overlaps the dirty scissor box — provably
  pixel-identical because the scissor already clips the rest. It is lower-risk and
  ~7% absolute CPU. We chose the persistent-buffer approach because it (a) exploits
  the idle GPU more directly, (b) yields a cleaner O(dirty cells) CPU cost without
  the scissor/`.load`/background-rect interactions, and (c) is the architecture
  **kitty** uses (persistent GPU-side cell buffer + per-line dirty-flag upload;
  `reload_all_gpu_data` is its exceptional full-refresh path). **Correction (web
  research):** Ghostty — the closest comparator (Metal + CoreText + a 32-byte
  per-cell `CellText` struct + in-shader `grid_pos`) — and Alacritty instead
  **rebuild the full instance set on the CPU every frame** and are still fast
  (Ghostty is cited ~120 fps). So per-frame rebuild is *not* intrinsically the
  bottleneck; the case for incremental patching rests on Laban's specific profile
  (where the frame is also ticked twice — settle-wake + CADisplayLink). The
  damage-scoped variant, and coalescing that double-tick, remain valid cheaper
  fallbacks if M2 underdelivers; record the pivot here if taken.
- **Correctness contract = pixel-parity (byte-identical readback), not eyeballing.**
  The renderer ships on `main`; any visible regression is unacceptable. We compare
  `MetalRenderer.pngData` of the new path against the current path for a battery of
  frames including scroll, selection, find, resize, clusters, and box-drawing.
- **M1 feeds the cell buffer from existing `FrameCommand`s; M2 reads the snapshot
  cells in `LabanCore`.** Feeding from `FrameCommand`s in M1 reuses `FrameProducer`'s
  already-correct foreground/background/attribute/cluster logic, so parity is
  achievable before we bypass it. The CPU win requires reading only dirty rows, which
  means extracting per-cell data straight from the snapshot — but that extraction
  must run in `LabanCore` (`makeFrame`, snapshot alive), **not** in the renderer (the
  renderer only gets `[FrameCommand]` and the snapshot is freed before `makeFrame`
  returns). The result is a **renderer-neutral** value-type cell payload (raw cell
  data — text, colours, attributes, grid position — *not* Metal `CellGlyph`s; the
  atlas lookup that builds `CellGlyph`s stays in `MetalRenderer`) carried on
  `TerminalSurfaceFrame`. Bypassing `FrameProducer`'s glyph-run coalescing for the
  Metal cell path is the larger correctness surface, hence staged.
- **The GPU cell path is a Metal-only acceleration; `[FrameCommand]` stays the shared
  cross-backend language.** Per `mvp.md`/`dev-process.md`, software/offscreen,
  `/debug/frame-commands`, capture replay, and render trace all consume
  `[FrameCommand]`. The cell payload does not replace it. The software backend keeps
  rendering from commands and stays behavior-equivalent (`CrossBackendBitmapTests`);
  the Metal GPU path's pixel equivalence is the separate `GPUCellParityTests` gate
  (`CrossBackendBitmapTests` never instantiates `MetalRenderer`). Commands keep being
  emitted whenever a capture/debug/trace consumer is attached. Recorded as policy in
  the M5 ADR.
- **Every change must earn its keep via a release microbench, or it is reverted —
  not merged.** This is a hard gate, not advice. Before landing any milestone or
  sub-change, run its microbench `-c release` and compare against the baseline
  captured at the start of that milestone. Keep the change only if it shows a net
  win (for the perf milestones M2 and M4) or provably no regression (for parity-only
  milestones M0/M1/M3); otherwise `git checkout` it and record why in
  `Surprises & Discoveries`. This is exactly what happened in the prior session: a
  `String(unsafeUninitializedCapacity:)` micro-fix was implemented, measured in
  release, found to *regress* (text 0.145→0.169 ms), and reverted — it did not
  reach `main`. Do the same here. **All benchmarks run `-c release`.** Debug builds
  do not specialize Swift generics and badly mislead (the merged `FrameProducer`
  Span change measured −40% in debug but is a 5–7× speedup in release; the String
  micro-fix above looked neutral in debug but regressed in release). See Surprises.
- **Ship behind a flag (`MetalRenderer.useGPUCellPath`), default off until M5, and
  gated `#available(macOS 26, *)`.** Same `nonisolated(unsafe) static var` toggle
  pattern as the two merged changes, so the A/B path and the parity test live in one
  binary. On < macOS 26 the flag is inert (the current path always runs).

## Plan of Work

Each milestone is independently verifiable and leaves the app working with the GPU
path **off by default** until M5 and **gated `#available(macOS 26, *)`** (macOS
13–25 always run the current renderer). Build the app with `./scripts/build-app`
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
- **Pixel-parity precondition — compute the origin bit-for-bit like the current path
  (web/maths research).** The zero-tolerance gate is *not* automatically reachable:
  the current path passes a CPU-computed origin (`FrameProducer` does `originX +
  col*cw` in `Double`/CGFloat, then `MetalRenderer` casts to `Float × scale`), whereas
  this shader recomputes it in `Float` from the grid index. Floating point is
  non-associative and Metal permits **FMA contraction**, so `col*adv + origin` can
  round differently between the two expressions; the rasterizer then snaps the vertex
  to a fixed-point sub-pixel grid (~8 sub-pixel bits), and a sub-ULP difference can
  shift glyph coverage by a whole pixel at edges → a non-identical PNG and a failed
  gate. This is exactly the multi-pass "variance" problem GLSL's `invariant`/`precise`
  exist for (MSL has the equivalents), but those only guarantee *same-expression*
  invariance — they do **not** make two different formulas agree. **So M1 must
  reproduce the current origin arithmetic exactly** — same operand order, same
  `Float`/`Double` widths at each step, FMA-contraction pinned (`fma`/`precise`/
  `-ffp-contract`) consistently on both sides — *or* the team must consciously relax
  the gate to a documented bounded tolerance (max ULP / capped edge-pixel delta),
  which the plan currently forbids. Decide this **before** writing the shader, not at
  the gate. (Sources in Surprises & Discoveries.)
- In `MetalRenderer`: build pipelines for the new shaders; when `useGPUCellPath`,
  fill a CPU `[CellGlyph]` of size `cols*rows` (empty cells get `flags=0`/zero size)
  **from the current `[FrameCommand]` glyph runs** (expand each run into per-cell
  entries; reuse `MetalGlyphAtlas.entry`), upload it, and draw `instanceCount =
  cols*rows`.
- **In M1 only `.glyphRun` commands move to the cell path; every `.rect` stays on
  the existing solid path unchanged.** This matters for a mechanically checkable
  fallback: `FrameCommand.rect` carries only `(CGRect, color, source)`
  (`Sources/LabanRenderer/FrameCommand.swift:99`), so per-cell/run *backgrounds*
  (`FrameProducer.swift:150`) and procedural *box-drawing* rects
  (`FrameProducer.swift:600`) are **both** `.rect(_, color:, source: .terminal)` and
  cannot be told apart from the command alone. M1 does not try to: all `.rect`s
  (backgrounds *and* box-art) render via the unchanged solid path, and a box-art
  cell simply has no glyph entry in the cell buffer. So box-drawing needs no special
  fallback at all.
- **Fall back to the current path for the whole frame** only on a predicate read
  straight off the `.glyphRun` commands the cell path consumes: any `attributes`
  outside the M1-supported set, a non-`.none` `underlineStyle`, a non-nil
  `underlineColor`/`hyperlink`, or a multi-cell cluster (text whose grapheme width
  exceeds one cell). These are all fields on the `glyphRun` case — checkable without
  any new rect-classification metadata — so M1 never renders wrong.

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
- **GPU-in-flight hazard — a single in-place-patched buffer is unsafe (research).**
  Apple's Metal Best Practices require **triple buffering** for a CPU-writable,
  GPU-readable buffer: "an access conflict occurs if CPU writing and GPU reading
  happen at the same time." With one persistent buffer, patching frame N+1's dirty
  rows can corrupt the buffer the GPU is still reading for frame N (the renderer
  already pipelines — note its `onFrameCompleted` completion handler). So the
  "persistent cell buffer" is really **N persistent cell buffers** (N = the
  renderer's in-flight depth, typically 3) cycled per frame, or one buffer behind an
  explicit semaphore. The dirty patch then either replays onto each of the N buffers
  (still O(dirty cells)) or tracks per-buffer dirtiness so a buffer that skipped K
  frames replays the union. Ghostty uses exactly such a multi-frame swap chain +
  semaphore. M4's Metal 4 residency model gives the explicit tools; M2 on the current
  command model must do this by hand. **Do not ship a single in-place buffer.**
- Source the per-cell data from the snapshot cells (the cell path no longer needs
  `FrameProducer`'s glyph-run coalescing) so only dirty rows are read. Reproduce
  `FrameProducer`'s foreground/background/attribute resolution for plain glyphs;
  validate against the `FrameProducer` path via the parity harness.

**M2's cell payload crosses the renderer boundary (interface fix).** The renderer
*cannot* "read the snapshot directly": `MetalRenderer.render` only receives
`[FrameCommand]` + `RenderDamage` (`TerminalBitmapView.swift:1155`), and the
libghostty snapshot is freed by `defer { laban_snapshot_destroy(snap) }` before
`makeFrame` returns (`TerminalSurfaceController.swift:385`). Reading cells in the
renderer would mean keeping that snapshot alive past `makeFrame` — an unsafe
lifetime. So the dirty-row extraction happens **in `LabanCore`, inside `makeFrame`,
while the snapshot is still alive**, and copies a **renderer-neutral** per-cell
payload — for each dirty cell its grapheme/cluster text, resolved foreground and
background colour, `TextAttributes`, and grid `col`/`row`, plus the list of dirty
row indices — onto a new optional field of `TerminalSurfaceFrame`. The payload must
**not** carry `CellGlyph`s: a `CellGlyph` needs atlas UVs, atlas texture size, and
per-glyph tile metrics, all of which come from `MetalGlyphAtlas` — a renderer-owned
resource (`MetalRenderer.swift:153`; UVs are computed from `atlas.textureSize` at
`MetalRenderer.swift:977`) that `LabanCore` neither owns nor can import. So
`LabanCore` does the cell-data resolution (fg/bg/attributes, the part that needs the
live snapshot), and **`MetalRenderer` does the `MetalGlyphAtlas.entry` lookup and
turns those cells into `CellGlyph`s as it patches its persistent buffer.**
`TerminalBitmapView` just forwards the neutral payload to `backend.render`. This is
why M2 is **not** "touches only `Sources/LabanRenderer/`" (corrected in Interfaces
and Dependencies). The neutral payload is an internal acceleration channel — it does
**not** replace the `[FrameCommand]` language (see below).

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
  the `[FrameCommand]` path (the M1 fallback rule), so the contract holds at every
  milestone.

**What exists at the end:** per-frame render CPU scales with dirty rows. On a mostly
static screen with a few changing lines, `buildInstanceList`-equivalent work drops
~5–20×. The `[FrameCommand]` stream remains the authoritative cross-backend language
for software, headless, capture, and debug.

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

### M4 [P2] Metal 4 reusable command buffers — THE ENCODE WIN (macOS 26)

**Scope.** M2 removes the per-frame *rebuild* cost; this milestone removes the
per-frame *encode* cost. `MetalRenderer.render`'s CPU-side command-buffer encode is
the largest single render slice in the profile (**15.5%**) and M0–M3 leave it
untouched. On macOS 26 the renderer adopts the **Metal 4** command model: command
buffers become long-lived, app-allocator-owned objects instead of fire-and-forget
transients recreated each frame, plus `MTL4ArgumentTable` binding and **residency
sets** (`MTLResidencySet`). For a terminal this is an ideal fit: the *draw* is
identical every frame (`instanceCount = cols*rows`, one solid + one glyph pass), so
the command buffer can be **encoded once and replayed**, while only the persistent
cell buffer's contents change (the M2 dirty-patch). The residency/barrier model also
supplies the explicit CPU↔GPU synchronisation the M2 N-buffered cell buffers need.

This milestone is **macOS-26-only by construction** and is *the* reason the plan
targets macOS 26 (Purpose → Platform target). It **composes with M2, it does not
replace it**: keep M2's plain-Metal persistent-buffer path as the macOS-26 baseline,
and < macOS 26 stays on the current renderer regardless.

**Do *not* reach for Indirect Command Buffers here.** ICBs pay off at *thousands* of
draw calls; Laban issues ~2 instanced draws, so the encode cost is render-pass +
buffer setup, not draw-call multiplicity — ICBs would add complexity for little gain
(web research). Metal 4 reusable command buffers attack the actual cost.

**What exists at the end:** on macOS 26, per-frame CPU encode for a mostly-static
screen approaches zero (command buffer reused); the combined M2+M4 path shows both
the rebuild share *and* the encode share of the profile collapse. This is a **perf
milestone** — earn-its-keep: a release microbench must show a net encode-CPU
reduction or it is reverted.

**Acceptance (release mode, macOS 26):**
```
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter <encode microbench>
# -> per-frame encode CPU on a static screen drops materially vs the M2-only path;
#    no regression on full-redraw frames.
swift test --filter GPUCellParityTests
# -> still byte-identical (the reused command buffer draws the same pixels)
```

### M5 [P2] Default on (macOS 26) + ADR

**Scope.** Flip `useGPUCellPath` default to `true` **on macOS 26** (keep the flag as
an escape hatch or remove it; < macOS 26 stays on the current renderer). Write
`docs/adr/0016-gpu-driven-cell-renderer.md` (0014 and
0015 already exist — use the next sequential number; re-check `docs/adr/` at write
time) recording the decision, the profile evidence, the persistent-buffer
architecture, the **macOS-26 `#available` dual-path** (older OSes keep the current
renderer) and the **Metal 4 command model** (M4), **and the frame-command contract
boundary** (see "Frame-command and headless contract" below): the GPU cell path is a
Metal-interactive-only acceleration; the software/offscreen backend,
`/debug/frame-commands`, capture replay, and render trace keep consuming the
`[FrameCommand]` language. Add the
one-line ADR entry to the `AGENTS.md` Decision Index (the `AGENTS.md` "Write a new
ADR" rule requires it). Update `docs/quality/` if it tracks render performance.
Re-run the live before/after.

## Validation and Acceptance

The change is **internal** (same pixels, less CPU), so acceptance is proven four
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
4. **Frame-command contract preserved (M2 onward).** The GPU cell path must not change
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
- [ ] For M2+: the cell payload is extracted in `LabanCore` while the snapshot is
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
- [ ] The GPU path is gated `#available(macOS 26, *)`; on < macOS 26 the flag is inert
      and the current renderer runs (verify the dual-path compiles and the legacy path
      is byte-unchanged).
- [ ] For M1: the cell-path origin is computed bit-for-bit like the current path (same
      operand order/precision, FMA-contraction pinned) — or the zero-tolerance gate was
      consciously relaxed to a documented bounded tolerance.
- [ ] For M2: the persistent cell buffer is N-buffered (or semaphore-gated) to the
      renderer's in-flight depth — no single in-place-patched buffer the GPU may still
      be reading.
- [ ] For M4: the Metal 4 reusable-command-buffer path shows a release-mode encode-CPU
      reduction (earn-its-keep), stays byte-identical, and is macOS-26-gated.
- [ ] For M5: the ADR uses the next free number (0016+, not the already-taken 0014),
      records the macOS-26 dual-path + Metal 4 decision, and a matching one-line entry
      was added to the `AGENTS.md` Decision Index.
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
- **`damage(snapshot:…)` already emits tight per-row dirty ranges** from
  `snapshot.dirty_rows` (`TerminalSurfaceController.swift:583`). M2 does not need new
  dirty-tracking; it needs to consume what exists.
- **Glyph-atlas regrow invalidates the whole cell buffer** (tile origins change on
  reallocation). M2 must rebuild on regrow; missing this would show stale glyphs.
- **Web research — only kitty does incremental cell upload; Ghostty/Alacritty rebuild
  per frame.** kitty keeps a persistent GPU cell buffer and uploads only dirty lines
  (`has_dirty_text`/`is_dirty`; `reload_all_gpu_data` = full refresh). Ghostty (Metal,
  closest comparator) and Alacritty rebuild the full instance set every frame and are
  still fast — so the "convergence" claim was corrected (Decision Log) and the
  rebuild-per-frame fallback noted. Sources: kitty & Ghostty DeepWiki; Alacritty
  PR #4373 / issue #5843.
- **Maths research — the zero-tolerance pixel gate is reachable only with bit-exact
  origin math.** FP non-associativity + Metal FMA contraction + fixed-point sub-pixel
  snapping mean an in-shader origin can differ from the CPU origin by a pixel at edges.
  GLSL/MSL `invariant`/`precise` fix only *same-expression* variance, not divergent
  formulas. Drives the M1 precondition. Sources: Khronos Type Qualifier wiki; Geeks3D
  precise qualifier; randomascii FP-determinism; arXiv 2408.05148 (FP non-associativity);
  NVIDIA IEEE-754 (FMA contraction); scratchapixel rasterization (sub-pixel fixed-point).
- **Apple Metal Best Practices require triple buffering for CPU-write/GPU-read
  buffers.** Drives M2's N-buffered cell buffer. Source: Apple "Metal Best Practices:
  Triple Buffering".
- **Recent-Metal research — Metal 4 (macOS 26) is the encode lever (now M4).** Metal 4's
  long-lived command buffers + argument tables + residency sets are built "to minimise
  CPU overhead" of command encoding — exactly the 15.5% encode slice M0–M3 leave alone.
  ICBs are a poor fit at ~2 draw calls; residency sets alone, mesh shaders, MetalFX, and
  ML-in-shaders are minor or irrelevant here. Sources: Apple WWDC25 "Discover Metal 4";
  Apple "What's New in Metal"; Apple indirect-command-encoding docs.

## Idempotence and Recovery

Every step is additive and behind `useGPUCellPath` (default off, and inert on
< macOS 26), so the app keeps working at all times; reverting is flipping the flag or
`git checkout` of the renderer files. Tests and benches can be re-run freely. If M2's snapshot-direct cell
read proves too risky, fall back to the damage-scoped instance-build variant
(Decision Log) — it reaches a large fraction of the CPU win with provable
pixel-parity and far less surface area — and record the pivot here.

## Interfaces and Dependencies

- **M0/M1 touch only `Sources/LabanRenderer/`** (`MetalRenderer.swift`,
  `Shaders.metal`, possibly `MetalGlyphAtlas.swift` for a stable per-glyph index)
  and new tests under `Tests/LabanRendererTests/`. M1 builds its cell buffer from
  the `[FrameCommand]` the renderer already receives, so it needs no upstream
  changes.
- **M2 necessarily crosses the renderer boundary** (see "M2's cell payload crosses
  the renderer boundary" in the M2 scope). The renderer only ever receives
  `[FrameCommand]` + `RenderDamage` via `backend.render` and the libghostty snapshot
  is destroyed (`laban_snapshot_destroy`) before `makeFrame` returns
  (`TerminalSurfaceController.swift:385`), so the renderer *cannot* read snapshot
  cells directly. M2 therefore touches:
  - `Sources/LabanCore/TerminalSurfaceController.swift` — extract the dirty-row
    cell payload **while the snapshot is still alive** (before the `defer
    laban_snapshot_destroy`), reading the libghostty cell struct already consumed by
    `FrameProducer` (`Sources/LabanTerminalCore/include/LabanTerminalCore.h`:
    `LabanCell`, `LabanSnapshot.dirty_rows`).
  - `Sources/LabanCore/TerminalSurfaceController.swift` — add an optional
    **renderer-neutral** cell payload field to `TerminalSurfaceFrame` (raw cell data:
    text, colours, `TextAttributes`, grid position; AppKit/Metal-free, lives in
    `LabanCore`). No atlas/`CellGlyph` types here — `LabanCore` cannot import
    `MetalGlyphAtlas`.
  - `Sources/LabanApp/TerminalBitmapView.swift:1155` — pass the payload alongside
    `cmds`/`damage` into the render call.
  - `Sources/LabanRenderer/` — do the `MetalGlyphAtlas.entry` lookup, build the
    `CellGlyph`s, and patch the persistent cell buffer (`MetalRenderer.swift`,
    `Shaders.metal`). `CellGlyph` (atlas UVs/metrics) is defined and populated only
    here, never in `LabanCore`.
- **Platform: macOS 26 first.** Package deployment target stays `macOS .v13`
  (`Package.swift`), but the entire GPU cell path is gated `#available(macOS 26, *)`
  and macOS 13–25 keep the current renderer (Purpose → Platform target; Decision Log).
  M0–M3 use plain Metal + buffers (which *would* run on macOS 13, but the plan does
  not support or test them there — the gate keeps the surface small). **M4 uses
  macOS-26-only Metal 4 APIs** (long-lived command buffers, `MTL4ArgumentTable`,
  `MTLResidencySet`). This matches the merged Span work's `#available` fast-path +
  untouched-legacy pattern.
- ADR boundary: per `AGENTS.md`, a change to "rendering architecture" warrants an
  ADR — written in M5 (`docs/adr/0016-…`, next sequential after the existing 0015),
  with the matching `AGENTS.md` Decision Index entry.
