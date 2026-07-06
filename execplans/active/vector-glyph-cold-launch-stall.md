# Vector/slug renderer must not stall app launch with a white window

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that will
help a fresh contributor.

## Purpose / Big Picture

When a user launches Laban with "Vector Glyph" already selected as their
renderer (Settings ▸ Renderer, persisted across launches via `UserDefaults`; see
`RendererSelection.persisted()` in `Sources/LabanRenderer/RendererSelection.swift`
line 34), the app window is **blank/white for several seconds** right after
launch, before any terminal text appears. This happens only on `.vectorGlyph`
(and, by the same mechanism, `.slugGlyph`) — `.classic`, `.gpuDriven`, and
`.software` all show terminal content immediately on launch. This plan fixes
that: after the change, launching with vector or slug already selected shows an
interactive terminal window immediately (using a quick temporary renderer for a
moment), which then seamlessly becomes the real vector/slug renderer within a
fraction of a second, with no blank/white flash and no frozen/unresponsive
period a human would notice.

This is a **pure bug fix / performance fix in a post-MVP renderer's startup
path**. Per `AGENTS.md`'s "Source Of Truth" section, "Bug fixes, polish,
performance, and refactors that preserve MVP behavior do not need spec.md
approval," and this plan does not change `docs/product/mvp.md` behavior.

### Relationship to the existing "no white window" plan

A prior, already-merged ExecPlan,
`execplans/active/vector-renderer-activation-no-white-window.md`, fixed a
structurally similar symptom — but only for **switching** the renderer to
vector/slug in a window that is already open and showing content (driven by
`TerminalBitmapView.applyRendererSelection(_:)`). That plan's own "Future
directions" section explicitly named "eagerly warming the shader cache at app
launch" as a known remaining gap and declined to implement it as out of scope.
This plan closes that gap, but for a different reason than that plan assumed:
the trace evidence gathered while investigating this (see "Surprises &
Discoveries" below) shows the *shader compile* is not the dominant cost at
cold launch — it is a red herring inherited from the switch-case investigation.
The dominant cost is synchronous, on-demand CoreText glyph rasterization on the
very first frame. This plan targets that real cost, not just the shader cache.

Read that prior plan's `Context and Orientation` section if you want the full
history of the shader-cache work (commit `ec9dcf0`) and the `PendingBackendSwap`
mechanism; this plan reuses (but does not modify) that mechanism.

## Progress

- [ ] Reproduce the stall locally with a fresh Metal System Trace + Time
  Profiler capture of a cold launch with `.vectorGlyph` persisted, confirming
  the numbers in "Surprises & Discoveries" still hold on the current `main`.
- [x] Add `prebuiltRasterAtlas` / `prebuiltSidebarRasterAtlas` parameters to
  `VectorGlyphRenderer.init` (Step 1 below).
- [x] Add a small, single-size, background-queue glyph-atlas prewarm helper
  (Step 2 below).
- [x] Wire cold launch in `TerminalBitmapView.init` to show a fast temporary
  backend immediately, prewarm in the background, then swap to the real
  persisted vector/slug backend via the existing `applyRendererSelection`
  path once the prewarm completes (Step 3 below).
- [x] Mirror the same `SlugGlyphRenderer` changes (Step 4 below).
- [x] Add automated tests (Step 5 below).
- [x] Run the full validation checklist below (`swift test`, `scripts/check`,
  live `--scroll-debug` screenshot verification, and a fresh Metal System
  Trace to confirm the CoreText/glyph-atlas cost no longer lands on the
  blocking cold-launch path). See "Captured evidence" under Validation and
  Acceptance for the verdict: the relevant slices pass and the change adds zero
  new failures (verified against clean base `2423865`); the full
  `./scripts/check` is red on this machine only due to pre-existing
  environment-sensitive failures (`VectorZoomGlyphSizeConsistencyTests`,
  `TabTitleEndToEndTests`), and the live GUI trace is blocked by the unrelated
  re-identification `L10n`/`NSBundle.module` crash.
- [ ] Update this plan's `Progress`/`Decision Log`/`Surprises & Discoveries` as
  work proceeds, and move it to `execplans/completed/` when done, per this
  repo's convention (see the sibling plan, or `execplans/completed/` for
  examples of the expected end state).

None of the above is implemented yet as of this writing (2026-07-06). This
document is a plan for a fresh contributor (human or agent) to execute, not a
record of completed work.

## Decision Log

- Decision: fix cold launch by (a) always showing a fast temporary backend
  (`.classic`, falling back to `.software` if Metal is unavailable — reusing
  `makeRendererBackend`'s own existing fallback logic) immediately, then (b)
  swapping to the real persisted `.vectorGlyph`/`.slugGlyph` backend through the
  **existing, already-shipped** `TerminalBitmapView.applyRendererSelection(_:)`
  / `PendingBackendSwap` machinery once a background-queue prewarm of that
  backend's glyph atlas has completed — rather than making
  `VectorGlyphRenderer`'s full construction-and-first-render path itself
  asynchronous.
  Rationale: I initially considered moving the *entire*
  `beginPendingBackendSwap`/`renderCurrentFrame` sequence
  (`Sources/LabanApp/TerminalBitmapView.swift` lines 1223–1251 and 1330–1374 as
  of this writing) to a background queue. `renderCurrentFrame` reads live
  `AppModel`/session/view state (`model.activeTab`, `model.session(forTab:)`,
  `sessionCoordinator`, `captureRecorder`, `frameProbe`, `displayedScrollRows`,
  and more) that is main-thread-affine in this codebase; moving it wholesale
  to a background queue is a much larger, riskier change than this bug
  warrants, and the *prior* ExecPlan's own Decision Log already considered and
  rejected background-threading the compile for almost exactly this reason
  ("changes more surface area... for the same user-visible result as the
  simpler defer-the-swap approach"). By contrast, the actual dominant cost
  (see `Surprises & Discoveries`) is glyph rasterization
  (`MetalGlyphAtlas.entry` → `CTFontDrawGlyphs`,
  `Sources/LabanRenderer/MetalGlyphAtlas.swift` lines 144–209), which depends
  only on (scalar/character, font, bold/italic fallback) — no session or view
  state — and this codebase already has a proven-safe precedent for doing
  exactly this kind of work on a background queue:
  `GlyphAtlasLadder.buildQueue` (`Sources/LabanRenderer/GlyphAtlasLadder.swift`
  line 55, `qos: .utility`) already constructs `MetalGlyphAtlas` instances and
  calls `atlas.prewarmASCII(fontAtlas:)` off the main thread today, for the
  live-zoom atlas ladder. `MetalRenderer` also already has a "prebuilt atlas"
  injection point (`reconfigureFonts(fontAtlas:sidebarFontAtlas:
  prebuiltTerminalAtlas:prebuiltSidebarAtlas:)`,
  `Sources/LabanRenderer/MetalRenderer.swift` lines 1032–1103) that adopts a
  background-built atlas when one is supplied and compatible. This plan gives
  `VectorGlyphRenderer` (and `SlugGlyphRenderer`) the same capability and reuses
  the existing `applyRendererSelection` swap-in path, rather than inventing a
  new concurrency mechanism.
  Date/Author: 2026-07-06, planning.

- Decision: prewarm only the printable-ASCII range (matching
  `MetalGlyphAtlas.prewarmASCII`, `Sources/LabanRenderer/MetalGlyphAtlas.swift`
  line 231, U+0020–U+007E), not the exact glyphs of whatever text happens to be
  on screen at launch.
  Rationale: this matches the existing, already-tested prewarm scope used by
  `GlyphAtlasLadder` for its own (different) use case, so this plan adds no new
  prewarm policy to reason about. Terminal content is overwhelmingly ASCII;
  CJK/box-drawing/emoji glyphs beyond ASCII will still populate lazily on first
  use, exactly as they do today for every renderer. Prewarming exactly the
  first frame's real content would require reading session/view state (the
  same state this plan deliberately keeps off the background queue, per the
  decision above), so it is out of scope here.
  Date/Author: 2026-07-06, planning.

- Decision: scope the "show a fast backend first" behavior to cold launch only
  (inside `TerminalBitmapView.init`), and leave `applyRendererSelection`'s
  existing mid-session switch behavior completely unchanged.
  Rationale: the mid-session switch path already has a shipped, tested fix
  (the prior ExecPlan) for its own (smaller) problem. This plan's job is only
  to close the cold-launch gap that plan explicitly left open. Touching the
  switch path risks regressing already-validated behavior for no benefit.
  Date/Author: 2026-07-06, planning.

- Decision (implementation, 2026-07-06): hold a prewarmed atlas aside in
  `VectorGlyphRenderer` and adopt it at the first scale-matching atlas
  (re)build, not only at `init`. `init` stores the prebuilt atlases into new
  `prewarmedRasterAtlas`/`prewarmedSidebarRasterAtlas` fields and tries to
  adopt them at `init`'s scale; `resize`'s `scaleChanged` branch tries again at
  the new scale; a one-shot adoption helper clears the held reference on
  success.
  Rationale: `makeRendererBackend` constructs `VectorGlyphRenderer` with
  `scale: 1` (the default) and `beginPendingBackendSwap`'s
  `preparePendingBackend` then `resize`s it to the real backing scale (2 on
  Retina). `resize` rebuilds the atlas only when `scaleChanged`
  (`VectorGlyphRenderer.swift` ~line 631), so on Retina the init-time atlas is
  always discarded and rebuilt cold. Injecting a prewarmed atlas at `init`
  alone (the original plan text) is therefore defeated on Retina: the prewarm
  is built at the real scale (2), `isCompatible` at `init`'s scale=1 is false,
  and `resize` rebuilds cold. Holding the prewarmed atlas aside and adopting it
  at `resize` (where the scale finally matches) is what actually avoids the
  cold first-frame rasterization on Retina. On a non-Retina (scale=1) display
  the prewarm is built at scale=1, adopted at `init`, and `resize` is an atlas
  no-op, so both cases work. The shared `beginPendingBackendSwap` construction
  is unchanged (still scale=1 init then resize), so the mid-session switch
  path is unaffected when no prewarmed atlas is supplied (the held fields are
  nil).
  Date/Author: 2026-07-06, implementing.

- Decision (implementation, 2026-07-06): kick off the cold-launch prewarm from
  the existing `viewDidMoveToWindow` override, not from `init`'s body, so the
  prewarm builds at `window.backingScaleFactor` (the same scale
  `currentSurfaceMetrics()` will pass to `preparePendingBackend`'s `resize`).
  Rationale: inside `init` the view is not yet in a window, so
  `currentSurfaceMetrics().scale` is `1.0` (`window?.backingScaleFactor ?? 1.0`,
  `TerminalBitmapView.swift` ~line 2155) and a prewarm started there would be
  built at scale=1 and discarded as incompatible on Retina. `viewDidMoveToWindow`
  fires after the view is added to the window, so `window.backingScaleFactor` is
  the real scale. A one-shot guard on `coldLaunchPendingRealSelection` makes the
  kickoff fire only once even if the view re-parents windows. A debug seam
  drives the swap synchronously in headless tests where `viewDidMoveToWindow`
  never fires with a real window (Step 5).
  Date/Author: 2026-07-06, implementing.

- Decision (implementation, 2026-07-06): defer the optional
  `VectorGlyphShaderCache` prewarm (the original plan's Step 2 nice-to-have).
  Rationale: the one-time shader compile is ~4.8 ms (see Surprises), lands
  inside `VectorGlyphRenderer.init` during the seamless swap (after the window
  is already interactive on the fast backend), and is sub-perceptible; the
  dominant cost is glyph rasterization, which the atlas prewarm addresses. It
  is a small, safe future addition (`VectorGlyphShaderCache` is lock-protected
  and race-tolerant by design) if a trace ever shows the swap hitch.
  Date/Author: 2026-07-06, implementing.

- Decision (implementation, 2026-07-06): for Step 3.5, chose option (b):
  `beginPendingBackendSwap(to:)` reads `pendingColdLaunchAtlas` and clears it
  one-shot just before constructing the new backend, threading the prewarmed
  atlases through `Self.makeBackend`/`makeRendererBackend`, rather than adding
  a separate `beginPendingBackendSwap(to:prebuiltRasterAtlas:
  prebuiltSidebarRasterAtlas:)` overload.
  Rationale: the cold-launch prewarm completion handler is the only caller that
  sets `pendingColdLaunchAtlas`, and it calls `applyRendererSelection` (which
  calls `beginPendingBackendSwap`) immediately after, so the ambient read is
  tightly bounded and one-shot (cleared before construction), not a lingering
  implicit input. Mid-session switches never set `pendingColdLaunchAtlas`, so
  it is nil there and the shared swap path is byte-for-byte unchanged. This
  keeps `applyRendererSelection`'s public call sites (menu actions,
  `ScrollDebugServer`) unchanged and avoids a second swap entry point.
  Date/Author: 2026-07-06, implementing.

## Surprises & Discoveries

These were found while validating an earlier (informal, chat-based) analysis of
this bug, using a real Metal System Trace captured with `xcrun xctrace record
--template "Metal System Trace" --launch -- <path to Laban.app binary>` and
analyzed with `scripts/analyze-metal-trace` (see that script's
`--print-agent-docs` output for its own usage loop). The trace and its analysis
are not checked into the repo (traces are large and machine-specific); the
numbers below are from a capture made 2026-07-06 and should be treated as
representative, not as a permanent baseline — re-capture before relying on
exact figures.

- Observation: the Metal shader/pipeline compile that happens on first use of
  `VectorGlyphShaderCache` (`Sources/LabanRenderer/VectorGlyphShaderCache.swift`)
  is real but small — not the dominant cost of the cold-launch stall.
  Evidence: a raw `xcrun xctrace export --xpath ... graphics-compiler-activity-
  intervals` of the capture showed all Laban-process shader-compiler events
  clustered between trace timestamps 00:00.478.699 and roughly 00:00.485.924 (a
  ~7.2 ms wall-clock span), consisting of one 4.40 ms "Compile Compute shader"
  event (almost certainly `VectorGlyphShaderCache.computePipelines`, used by
  `VectorGlyphScratchRasterizer`) plus 5 Fragment and 3 Vertex shader compiles
  of 20–112 microseconds each (the 5 render pipelines in
  `VectorGlyphShaderCache.RenderPipelines`). Total actual compile time: **~4.8
  ms**. An earlier, informal description of this bug (chat-based, not part of
  this repo) cited "a renderer-init window of ~0.47–0.49s" as if that were how
  long the compile took; read correctly, 0.47–0.49s is the trace *timestamp*
  at which the (tiny) compile happened, not its duration. Do not repeat that
  ambiguity in any future write-up of this bug.
- Observation: the actual dominant cost is on-demand CoreText glyph
  rasterization triggered by the first real frame, via
  `MetalGlyphAtlas.entry(scalar:font:boldFallback:italicFallback:)`
  (`Sources/LabanRenderer/MetalGlyphAtlas.swift` line 144) calling into
  `rasterizeAndPack` (which calls `CTFontDrawGlyphs`, among other CoreText
  APIs).
  Evidence: `scripts/analyze-metal-trace --cpu-only` (using the same capture,
  process filter `Laban|laband|labpty`) reported 3015 ms of kept Time Profiler
  sample weight, of which the category "glyph atlas/font lookup"
  (`MetalGlyphAtlas.entry` + `CTFontDrawGlyphs` + font-fallback/trait lookups)
  accounted for **49.29%** (1486 of 3015 samples). The single symbol
  `MetalGlyphAtlas.entry` alone was 48.03%. This happens because
  `VectorGlyphRenderer.init` (`Sources/LabanRenderer/VectorGlyphRenderer.swift`
  line 244) builds its `rasterAtlas`/`sidebarRasterAtlas` via
  `Self.makeRasterAtlas` (lines 320–328, itself lines 492–504), which just
  allocates an empty, zeroed `MTLTexture`
  (`Sources/LabanRenderer/MetalGlyphAtlas.swift` lines 126–141) — it does *not*
  prewarm any glyphs. Every glyph needed by the first frame is therefore
  rasterized cold, synchronously, on whatever thread renders that first frame
  (the main thread, at cold launch).
- Observation: this codebase already has a working, already-tested pattern for
  doing exactly this kind of glyph-atlas population off the main thread:
  `GlyphAtlasLadder` (`Sources/LabanRenderer/GlyphAtlasLadder.swift`) builds its
  atlases on `buildQueue = DispatchQueue(label: "laban.atlas-ladder", qos:
  .utility)` (line 55) and calls `atlas.prewarmASCII(fontAtlas:)` (line 174)
  there — the same `MetalGlyphAtlas`/CoreText code path this plan needs to
  warm up before cold launch's first frame. This significantly de-risks the
  approach in this plan's Decision Log: it is not a new concurrency pattern for
  this codebase, just a new caller of an existing one.
  Evidence: `Sources/LabanRenderer/GlyphAtlasLadder.swift` lines 55, 84, 105,
  158–176.
- Observation: `VectorGlyphShaderCache`'s internal cache
  (`Sources/LabanRenderer/VectorGlyphShaderCache.swift` lines 38–46) is a
  process-wide dictionary guarded by an `NSLock`, explicitly designed ("Lost a
  build race against another thread; keep the first winner", line 75) to
  tolerate concurrent/first-use races. This means warming it from a background
  queue (as a side effect of constructing a `VectorGlyphRenderer` or just its
  `VectorGlyphScratchRasterizer`/pipelines there) is safe by the cache's own
  design, if this plan's implementation chooses to do that too (see Step 2 and
  Step 3's "optional" note below) — though it is not the dominant cost, so it
  is a nice-to-have, not the point of this plan.

- Discovery (implementation, 2026-07-06): `VectorGlyphRenderer.resize` rebuilds
  the raster atlas only when `scaleChanged` (`VectorGlyphRenderer.swift` ~line
  631), and `makeRendererBackend` constructs the renderer with `scale: 1` while
  `preparePendingBackendSwap` resizes it to the real backing scale (2 on
  Retina). So on Retina the init-time atlas is always discarded and rebuilt
  cold on the first `resize`, which means injecting a prewarmed atlas at `init`
  alone (the original plan text) is defeated: the prewarm is built at the real
  scale, `isCompatible` at `init`'s scale=1 is false, and `resize` rebuilds
  cold. The fix holds the prewarmed atlas aside and adopts it at that first
  scale-matching `resize` (see the Decision Log). `SlugGlyphRenderer.resize`
  has the identical `scaleChanged`-gated rebuild, so the same hold-aside
  pattern applies. Evidence: `VectorGlyphRendererPrebuiltAtlasTests.
  testScaleMismatchedPrebuiltAtlasHeldThenAdoptedAtResize` and the slug mirror
  both pass.

## Context and Orientation

**Renderer backend**: one of five interchangeable objects that turn a list of
drawing instructions (`FrameCommand` values,
`Sources/LabanRenderer/FrameCommand.swift`) into pixels on screen:
`SoftwareBackend`, `MetalRenderer` (used for both "classic" and "gpuDriven"
modes), `VectorGlyphRenderer`, `SlugGlyphRenderer`. All four conform to the
`RendererBackend` protocol (`Sources/LabanRenderer/RendererBackend.swift` line
123), which requires (among other members): `func render(_:damage:) -> Bool`
(line 130/135/142), `func resize(pixelWidth:pixelHeight:scale:) -> Bool` (line
151), `var presentationLayer: CALayer? { get }` (line 161), `var
onFrameCompleted: (() -> Void)? { get set }` (line 174), and `var
waitForFrameCompletion: Bool { get set }` (line 183). The user picks a kind via
Settings ▸ Renderer, backed by the enum `RendererSelection`
(`Sources/LabanRenderer/RendererSelection.swift` line 5: cases `software`,
`classic`, `gpuDriven`, `vectorGlyph`, `slugGlyph`), persisted via
`RendererSelection.persisted(defaults:)` (line 34) and
`RendererSelection.set(_:defaults:)` (line 44).

**`TerminalBitmapView`**: the AppKit view
(`Sources/LabanApp/TerminalBitmapView.swift`) that owns the current renderer
backend in `private var backend: RendererBackend` (line 136) and draws the
terminal. Its designated initializer (starts at line ~655, the relevant part is
lines 689–699 as of this writing) does, today, unconditionally and
synchronously:

```swift
let selection =
  Self.launchForcesSoftwareRenderer ? .software : RendererSelection.persisted()
let resolvedSelection = selection.isAvailableOnCurrentOS ? selection : .classic
self.activeRendererSelection = resolvedSelection
self.intendedRendererSelection = resolvedSelection
self.backend = Self.makeBackend(
  selection: resolvedSelection,
  fontAtlas: fontAtlas,
  sidebarFontAtlas: sidebarFontAtlas)
self.backendSelfPresents = backend.presentationLayer != nil
super.init(frame: .zero)
```

This runs **before `super.init(frame: .zero)`**, on whatever thread constructs
the view (in practice, the main thread, during app launch —
`MainWindowController.makeAndShow(...)` → `TerminalBitmapView.init`, itself
called from `AppDelegate.applicationDidFinishLaunching(...)`). `Self.makeBackend`
(private static func, lines 1072–1084) just calls
`makeRendererBackend(selection:fontAtlas:sidebarFontAtlas:)`
(`Sources/LabanRenderer/RendererSelection.swift` line 59), which for
`.vectorGlyph` (lines 115–164 of that file) constructs
`VectorGlyphRenderer(fontAtlas:sidebarFontAtlas:pixelWidth:pixelHeight:scale:)`
(line 129) directly. There is no deferral here at all — this is a completely
separate code path from `applyRendererSelection`, and does not use
`PendingBackendSwap` (defined at `TerminalBitmapView.swift` line 97, used only
from `beginPendingBackendSwap` at line 1223 onward, which is only reachable
through `applyRendererSelection`, line 1173).

**`VectorGlyphRenderer.init`**
(`Sources/LabanRenderer/VectorGlyphRenderer.swift`, `public init?(...)` at line
244) does, synchronously, in order: `MTLCreateSystemDefaultDevice()` +
`device.makeCommandQueue()` (line 251–252), `VectorGlyphScratchRasterizer(device:)`
(line 253, itself pulling `VectorGlyphShaderCache.computePipelines` — this is
where the one-time-per-process 4.4 ms compute-shader compile happens, see
`Surprises & Discoveries`), `VectorGlyphShaderCache.renderPipelines(device:
pixelFormat:)` (lines 281–284, the 5 render-pipeline compiles), then
`Self.makeRasterAtlas(device:fontAtlas:scale:)` and
`Self.makeColorGlyphAtlas(device:fontAtlas:scale:)` (lines 320–328).
`Self.makeRasterAtlas` (lines 492–504) just calls
`MetalGlyphAtlas(device:cellWidth:cellHeight:descent:scale:)` — an *empty*
atlas; see `MetalGlyphAtlas.init` (`Sources/LabanRenderer/MetalGlyphAtlas.swift`
lines ~110–142), which allocates a zeroed `MTLTexture` and nothing else. Glyphs
are only rasterized on demand, via `entry(scalar:font:boldFallback:
italicFallback:)` / `entry(character:font:boldFallback:italicFallback:)` (lines
144–209), which is called from `VectorGlyphRenderer`'s render path once real
frame content needs to be drawn.

**`MetalGlyphAtlas.prewarmASCII(fontAtlas:)`**
(`Sources/LabanRenderer/MetalGlyphAtlas.swift` line 231, delegating to
`prewarmASCII(font:)` at line 220) rasterizes every printable ASCII scalar
(U+0020–U+007E) for a font into the atlas's texture ahead of time, so a later
renderer that adopts this atlas finds the common alphabet already cached. It is
documented as "Safe off the main thread while no renderer references the
atlas" (comment above line 217).

**`GlyphAtlasLadder`** (`Sources/LabanRenderer/GlyphAtlasLadder.swift`) is an
existing mechanism (used for smooth pinch-zoom, unrelated to this bug except as
a pattern to reuse) that builds a "ladder" of `MetalGlyphAtlas` pairs (terminal
+ sidebar) at every reachable zoom point size, each one pre-populated via
`prewarmASCII`, on a dedicated background queue `buildQueue =
DispatchQueue(label: "laban.atlas-ladder", qos: .utility)` (line 55). Its
`makeEntry(forPointSize:)` (line 143) and `makePrewarmedAtlas(fontAtlas:)`
(line 158) show the exact pattern this plan's Step 2 should follow, but this
plan should **not** call into `GlyphAtlasLadder` itself — it builds an entire
ladder of many sizes, which is more work than a single cold-launch prewarm
needs. Write a small, separate, single-size helper instead (Step 2).

**`MetalRenderer.reconfigureFonts(fontAtlas:sidebarFontAtlas:
prebuiltTerminalAtlas:prebuiltSidebarAtlas:)`**
(`Sources/LabanRenderer/MetalRenderer.swift` lines 1032–1103) already
demonstrates the "accept an optional prebuilt atlas, otherwise build a fresh
one" pattern this plan adds to `VectorGlyphRenderer`/`SlugGlyphRenderer`:

```swift
func usable(_ atlas: MetalGlyphAtlas?) -> MetalGlyphAtlas? {
  guard let atlas, atlas.texture.device === device else { return nil }
  return atlas
}
if let prebuilt = usable(prebuiltTerminalAtlas) {
  glyphAtlas = prebuilt
} else if let fresh = MetalGlyphAtlas(device: device, ...) {
  glyphAtlas = fresh
}
```

**`applyRendererSelection(_:)`** (`Sources/LabanApp/TerminalBitmapView.swift`
line 1173) is the already-shipped, already-tested entry point for switching the
active backend to a different `RendererSelection` after the view exists. For a
different *kind* of backend (which includes vector/slug), it calls
`beginPendingBackendSwap(to:)` (line 1220 → definition at line 1223), which:
constructs the new backend synchronously (`Self.makeBackend(...)`, line 1224),
resizes it to the current surface (`preparePendingBackend`, line 1231), installs
a one-shot `onFrameCompleted` closure (lines 1238–1242) that will finish the
swap, then forces one full-damage render into it *without* blocking
(`newBackend.waitForFrameCompletion = false`, line 1245, then
`renderCurrentFrame(into:damage:)`, line 1246 — this reads live `AppModel`/
session state, see the Decision Log above for why this plan does not move this
call to a background queue). Once that new backend's first frame completes
(`onFrameCompleted` fires, line 1238, hopping back to the main thread at line
1239), `completePendingBackendSwap` (line 1269) and then
`installPendingBackendSwap` (lines 1292/1297) actually assign `self.backend`
and call `configurePresentationForCurrentBackend()` (line 1086) to install the
new layer — this is the moment the user's screen visibly changes. Until then,
the *old* backend's last frame stays on screen. This plan's Step 3 calls
`applyRendererSelection(_:)` unchanged from a new cold-launch call site — it
does not modify `applyRendererSelection`, `beginPendingBackendSwap`, or
`installPendingBackendSwap` at all, except to thread two new optional
parameters through `Self.makeBackend` (Step 1/3) so a prewarmed atlas can be
supplied when available.

**`SlugGlyphRenderer`** (`Sources/LabanRenderer/SlugGlyphRenderer.swift`) has
the identical structure for this bug's purposes: `private var rasterAtlas:
MetalGlyphAtlas?` (line 295), a `public init?(...)` (line 350), and a static
`Self.makeRasterGlyphAtlas(...)` helper (called at lines 526, 630, 649, 694) —
mirror every change this plan makes to `VectorGlyphRenderer` there too (Step
4). This plan was triggered by a report specifically about `.vectorGlyph`;
`.slugGlyph` almost certainly has the same bug by the same mechanism (same
lazy, empty `MetalGlyphAtlas`, same first-frame-triggered rasterization), so
fixing only one and not the other would leave a known, predictable regression
for `.slugGlyph` users. Do both.

## Plan of Work

### Step 1: Let `VectorGlyphRenderer.init` accept a prebuilt raster atlas

In `Sources/LabanRenderer/VectorGlyphRenderer.swift`, add two new optional
trailing parameters to `public init?(...)` (line 244):

```swift
public init?(
  fontAtlas: FontAtlas,
  sidebarFontAtlas: FontAtlas? = nil,
  pixelWidth: Int = 1,
  pixelHeight: Int = 1,
  scale: CGFloat = 1,
  prebuiltRasterAtlas: MetalGlyphAtlas? = nil,
  prebuiltSidebarRasterAtlas: MetalGlyphAtlas? = nil
) {
```

Because both new parameters default to `nil`, every existing call site
(`RendererSelection.swift` line 129, and any test constructing a
`VectorGlyphRenderer` directly) keeps compiling unchanged — this is a purely
additive signature change.

Then, at lines 320–324 (`self.rasterAtlas = Self.makeRasterAtlas(...)` /
`self.sidebarRasterAtlas = Self.makeRasterAtlas(...)`), adopt the prebuilt
atlas when it is compatible, mirroring `MetalRenderer.reconfigureFonts`'s
`usable(_:)` helper (`Sources/LabanRenderer/MetalRenderer.swift` line 1041) but
checking cell geometry too, since (unlike `reconfigureFonts`, which is only
called when the caller already knows sizes match) this is a fresh-construction
path and should not silently adopt a wrongly-sized atlas.

**Important, already verified:** `MetalGlyphAtlas`'s `cellWidth`, `cellHeight`,
and `scale` are declared `private let` (`Sources/LabanRenderer/MetalGlyphAtlas.swift`
lines 85–87) — `private` in Swift is scoped to the *enclosing file*, not the
module, so `VectorGlyphRenderer.swift` (a different file) cannot read
`atlas.cellWidth` directly even though both types live in the same
`LabanRenderer` target. Only `texture`/`textureSize` are `public` (lines
82–83), plus one narrow `public var cellHeightForDiagnostics: CGFloat {
cellHeight }` (line 90). Do not widen `cellWidth`/`cellHeight`/`scale` to
`internal`/`public` piecemeal for this one call site. Instead, add one new
method to `MetalGlyphAtlas` itself (same file, so it can see the private
properties), right after `cellHeightForDiagnostics` (line 90):

```swift
/// Whether this atlas can be reused as-is for a renderer being constructed
/// with the given device and cell geometry — i.e., whether adopting it
/// produces byte-for-byte the same result as building a fresh, empty atlas
/// for that geometry would, just already warm. Used by callers (for example
/// `VectorGlyphRenderer.init`) that may have a prewarmed atlas available from
/// a background prewarm pass and want to adopt it only when it truly matches.
func isCompatible(device: MTLDevice, cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat) -> Bool {
  texture.device === device
    && self.cellWidth == cellWidth
    && self.cellHeight == cellHeight
    && self.scale == max(scale, 1)
}
```

Then, in `VectorGlyphRenderer.init`:

```swift
self.rasterAtlas =
  (prebuiltRasterAtlas?.isCompatible(
    device: device, cellWidth: fontAtlas.cellSize.width,
    cellHeight: fontAtlas.cellSize.height, scale: scale) == true
    ? prebuiltRasterAtlas : nil)
  ?? Self.makeRasterAtlas(device: device, fontAtlas: fontAtlas, scale: scale)
let sidebarSource = sidebarFontAtlas ?? fontAtlas
self.sidebarRasterAtlas =
  (prebuiltSidebarRasterAtlas?.isCompatible(
    device: device, cellWidth: sidebarSource.cellSize.width,
    cellHeight: sidebarSource.cellSize.height, scale: scale) == true
    ? prebuiltSidebarRasterAtlas : nil)
  ?? Self.makeRasterAtlas(device: device, fontAtlas: sidebarSource, scale: scale)
```

(Adjust exact wording/formatting to this file's prevailing style — this
codebase leans toward small `guard`/ternary-free style elsewhere; feel free to
write this as an explicit `if let`/`else` instead of the nested `?:` above if
that reads more clearly next to the surrounding code, as long as the adoption
condition is the same.)

### Step 2: A single-size, background-queue glyph-atlas prewarm helper

Add a small new type, e.g. `ColdLaunchAtlasPrewarmer`, in a new file
`Sources/LabanRenderer/ColdLaunchAtlasPrewarmer.swift` (or as a static method on
an existing renderer-support type if you find a better home while implementing
— name the choice in this plan's `Decision Log` if you deviate). It should:

1. Own a dedicated background queue, e.g. `DispatchQueue(label:
   "laban.cold-launch-atlas-prewarm", qos: .userInitiated)` — a distinct queue
   from `GlyphAtlasLadder.buildQueue` so this one-shot, launch-time prewarm is
   never blocked behind (or blocks) the ladder's own zoom-related background
   work.
2. Expose one function, e.g.:
   ```swift
   static func prewarm(
     device: MTLDevice,
     fontAtlas: FontAtlas,
     sidebarFontAtlas: FontAtlas,
     scale: CGFloat,
     completion: @escaping (_ terminalAtlas: MetalGlyphAtlas?, _ sidebarAtlas: MetalGlyphAtlas?) -> Void
   )
   ```
   which, on its background queue, builds a `MetalGlyphAtlas` for `fontAtlas`'s
   cell size (via `MetalGlyphAtlas(device:cellWidth:cellHeight:descent:
   scale:)`, matching `VectorGlyphRenderer.makeRasterAtlas`'s own construction
   at lines 492–504), calls `prewarmASCII(fontAtlas:)` on it, does the same for
   `sidebarFontAtlas` (reusing the terminal atlas instance if `sidebarFontAtlas
   === fontAtlas`, matching the `===` shared-atlas check already used elsewhere
   in this codebase, e.g. `MetalRenderer.swift` line 1069), and calls
   `completion(...)` — **on the same background queue**; the caller (Step 3) is
   responsible for hopping back to the main thread before touching
   `TerminalBitmapView`/AppKit state.
3. This function must be safe to call before `VectorGlyphRenderer` exists (it
   only needs an `MTLDevice`, which cold launch already obtains via
   `MTLCreateSystemDefaultDevice()` to decide whether Metal is available at
   all — see `RendererSelection.swift` line 116/167 for the existing pattern).

Optional, nice-to-have (does not block this plan's core fix, see `Surprises &
Discoveries`): also call `VectorGlyphShaderCache.library(device:)`,
`.computePipelines(device:)`, and `.renderPipelines(device:pixelFormat:
.bgra8Unorm_srgb)` from inside this same background prewarm function, so the
~4.8 ms one-time shader compile also happens off the main thread and before
`VectorGlyphRenderer.init` runs. This is safe because
`VectorGlyphShaderCache`'s cache is lock-protected and explicitly designed to
tolerate concurrent first-use (see `Surprises & Discoveries`). If you add this,
note it in `Progress`, since it is a small addition beyond this plan's minimum
scope.

### Step 3: Wire cold launch in `TerminalBitmapView.init`

In `Sources/LabanApp/TerminalBitmapView.swift`, replace the block at (today)
lines 689–698 (quoted in full in `Context and Orientation` above). The new
logic, in prose:

1. Compute `resolvedSelection` exactly as today (unchanged).
2. If `resolvedSelection` is `.vectorGlyph` or `.slugGlyph` **and**
   `MTLCreateSystemDefaultDevice() != nil` (i.e., there is a real chance the
   real backend will construct successfully and this whole dance is worth
   doing): construct a **fast temporary backend** synchronously via
   `Self.makeBackend(selection: .classic, fontAtlas: fontAtlas, sidebarFontAtlas:
   sidebarFontAtlas)` (reusing `makeRendererBackend`'s own existing
   `.classic`-falls-back-to-`.software`-if-Metal-unavailable logic, so this one
   call already handles the "Metal not available at all" edge case correctly).
   Assign it to `self.backend`. Set `self.activeRendererSelection = .classic`
   (or whatever the fast backend actually resolved to — read it back from
   `backend.rendererStatus.effectiveRenderer` if you need the precise value)
   but set `self.intendedRendererSelection = resolvedSelection` (the user's
   real, persisted choice) — this exactly matches the existing
   `intendedRendererSelection`/`activeRendererSelection` split (see the prior
   ExecPlan's Decision Log, already implemented in this codebase) that lets
   `var rendererSelection: RendererSelection { intendedRendererSelection }`
   (line 1152) keep reporting the user's real choice immediately, so Settings
   UI and tests that read `view.rendererSelection` right after construction see
   `.vectorGlyph`/`.slugGlyph`, not `.classic`, even while the fast backend is
   temporarily active.
3. If `resolvedSelection` is anything else (today's common case:
   `.classic`/`.gpuDriven`/`.software`, or `.vectorGlyph`/`.slugGlyph` when
   Metal genuinely is not available), behavior is **completely unchanged** —
   construct `resolvedSelection` directly and synchronously, exactly as today.
   This keeps the change's blast radius limited to exactly the case that has
   the bug.
4. After `super.init(frame: .zero)` and the rest of `init`'s existing body runs
   (so the view is fully constructed and `self` can be captured safely), if
   step 2's fast-temporary-backend path was taken, call the Step 2 prewarm
   helper with this view's `fontAtlas`/`sidebarFontAtlas`/current scale, and in
   its completion handler (which fires on a background queue — hop to main
   first): call `DispatchQueue.main.async { self.applyRendererSelection(
   resolvedSelection) }` if `self.intendedRendererSelection == resolvedSelection`
   still holds (i.e., the user has not, in the brief window since launch,
   already changed the renderer again — an unlikely but cheap-to-guard race).
   `applyRendererSelection` (line 1173) already does everything needed from
   here using the existing, unmodified `PendingBackendSwap` machinery — the
   only difference from today's mid-session switch is that `Self.makeBackend`
   now has a prewarmed atlas available (see below) so `VectorGlyphRenderer`'s
   first real frame hits warm glyph-atlas entries instead of cold ones.
5. To actually get the prewarmed atlas into `VectorGlyphRenderer.init`, extend
   `Self.makeBackend(selection:fontAtlas:sidebarFontAtlas:)` (line 1072) and
   `makeRendererBackend(selection:fontAtlas:sidebarFontAtlas:pixelWidth:
   pixelHeight:scale:)` (`RendererSelection.swift` line 59) with two more
   optional trailing parameters (`prebuiltRasterAtlas`/
   `prebuiltSidebarRasterAtlas`, default `nil`), threaded straight through to
   the `VectorGlyphRenderer(...)` call at `RendererSelection.swift` line 129
   (and the mirrored `SlugGlyphRenderer(...)` call for `.slugGlyph`, Step 4).
   Store the Step 2 prewarm's result somewhere `TerminalBitmapView` can read it
   back when it calls `applyRendererSelection` in step 4 above (a private
   optional stored property is simplest, e.g. `private var
   pendingColdLaunchAtlas: (terminal: MetalGlyphAtlas, sidebar: MetalGlyphAtlas)?`,
   cleared after first use). Because `applyRendererSelection` itself does not
   take these parameters, either: (a) add a small private
   `beginPendingBackendSwap(to:prebuiltRasterAtlas:prebuiltSidebarRasterAtlas:)`
   overload used only by this cold-launch call site (leaving the existing
   zero-argument call sites, e.g. from menu actions and
   `ScrollDebugServer`, unchanged), or (b) read
   `pendingColdLaunchAtlas` directly inside the existing
   `beginPendingBackendSwap(to:)` before its `Self.makeBackend(...)` call and
   pass it through only when non-nil, clearing it immediately after. Prefer
   (b) if it keeps `applyRendererSelection`'s public call sites simpler; prefer
   (a) if reading ambient state inside `beginPendingBackendSwap` feels too
   implicit once you are looking at the real code. Record which one you chose,
   and why, in this plan's `Decision Log`.

### Step 4: Mirror Steps 1–3 for `SlugGlyphRenderer`

Repeat Step 1's signature change on `SlugGlyphRenderer.init?(...)`
(`Sources/LabanRenderer/SlugGlyphRenderer.swift` line 350) and its
`Self.makeRasterGlyphAtlas(...)` call sites (lines 526, 630, 649, 694 — Step 1
only needs to touch the construction-time call, but re-check which of these is
the one analogous to `VectorGlyphRenderer`'s lines 320–324 before editing).
Extend `makeRendererBackend`'s `.slugGlyph` branch
(`RendererSelection.swift` lines 166–216) the same way as its `.vectorGlyph`
branch. Extend Step 3's cold-launch check to include `.slugGlyph` alongside
`.vectorGlyph` (it should already be phrased generically enough that this is a
condition change, not new code, if you followed Step 3's wording above).

### Step 5: Tests

Add a new test file,
`Tests/LabanRendererTests/VectorGlyphRendererPrebuiltAtlasTests.swift`,
covering:

- Constructing a `VectorGlyphRenderer` with a `prebuiltRasterAtlas` built for
  the same device and matching cell size/scale adopts it (assert identity,
  `===`, against the instance passed in — mirror how
  `Tests/LabanRendererTests/VectorGlyphShaderCacheTests.swift` asserts cache
  identity reuse, since that file already demonstrates this codebase's pattern
  for identity-based assertions on renderer-internal Metal objects).
- Constructing with a `prebuiltRasterAtlas` built for a **different** cell size
  or scale does **not** get adopted (a fresh atlas is built instead) — this is
  the compatibility guard from Step 1's `usable(_:cellSize:)` check; assert the
  resulting atlas is *not* the passed-in instance.
- A glyph that was prewarmed via `prewarmASCII` (e.g. `"A"`) resolves as a
  cache hit through the adopted atlas without needing a fresh
  `rasterizeAndPack` call — if `MetalGlyphAtlas` does not already expose a test
  seam for "was this a cache hit," check whether one exists before adding a new
  one (search for existing debug/test seams like `lastRasterFallbackGlyphs` on
  `VectorGlyphRenderer`, line 183, or `clearOverflowFlag()`,
  `MetalGlyphAtlas.swift` line 211-213, as models for how this codebase exposes
  internal counters for tests).

Add a second test file (or extend an existing one — check
`Tests/LabanAppTests/RendererModeSettingsTests.swift`, referenced by the prior
ExecPlan as the existing pattern for constructing a `TerminalBitmapView` in a
test, and `Tests/LabanAppTests/RendererActivationNoBlankWindowTests.swift`,
added by the prior plan) covering:

- `testColdLaunchWithVectorGlyphPersistedShowsClassicImmediately`: with
  `.vectorGlyph` persisted (set `RendererSelection.set(.vectorGlyph)` on a
  test-scoped `UserDefaults` before constructing the view, following whatever
  pattern `RendererModeSettingsTests` already uses for isolated defaults),
  construct a `TerminalBitmapView`. Immediately after construction (same
  run-loop turn, no `sleep`/pump), assert `view.backend` (or an internal test
  accessor if `backend` is not visible to tests — check its access level, `line
  136`, before assuming) is a fast backend (e.g. `is MetalRenderer` with
  `configuredRendererMode == .classic`, or `is SoftwareBackend` if Metal is
  unavailable in the test environment), while `view.rendererSelection ==
  .vectorGlyph` (the intended/persisted value, per Step 3's `intendedRendererSelection`
  handling).
- `testColdLaunchWithVectorGlyphPersistedEventuallyBecomesVectorGlyph`: using
  whatever debug seam Step 3/4 introduced (or reusing
  `debugFlushPendingRendererSwap()`, line 1324, if the cold-launch swap reaches
  the same `pendingBackendSwap` state that helper already flushes), drive the
  pending swap to completion and assert `view.backend is VectorGlyphRenderer`.
- Re-run `RendererModeSettingsTests` and
  `RendererActivationNoBlankWindowTests` unmodified and confirm both stay
  green — this plan must not regress the mid-session switch behavior those
  tests cover.

## Concrete Steps

All commands below run from the repository root,
`/Users/rrj/wrk/laban` (or the equivalent path on whichever machine/worktree
holds this work — this repository uses git worktrees for isolated builds; see
`docs/process/worktree-isolation.md` if you are setting one up fresh).

**Important environment note for whoever executes this plan:** this plan was
authored and researched from a sandboxed Linux environment with no Xcode / no
macOS frameworks (AppKit, Metal, CoreText are unavailable there), so none of
the commands below have been run by the plan's author. Every command in this
section must be run and its real output recorded here (replacing the
placeholder text) by whoever implements this plan, on a real Mac.

```sh
# Build in debug first (fast iteration).
swift build

# Run the renderer- and app-level unit tests this plan adds/touches.
swift test --filter VectorGlyphRendererPrebuiltAtlasTests
swift test --filter SlugGlyphRendererPrebuiltAtlasTests   # if Step 4 added a mirrored file
swift test --filter RendererModeSettingsTests
swift test --filter RendererActivationNoBlankWindowTests
swift test --filter VectorGlyph
swift test --filter SlugGlyph

# Repository baseline checks (this repo has its own lint/format/check gate).
./scripts/check
```

Record the actual pass/fail output of each command here as you run them,
replacing this placeholder — per `PLANS.md`, "Validation is not optional" and
evidence must be captured.

Actual results (2026-07-06, worktree `immutable-bouncing-puddle`, macOS):

- `./scripts/build-app` (the repo's build, used instead of bare `swift build`
  per repo convention): passed. `Build of product 'laband' complete!`,
  `Build of product 'labpty' complete!`,
  `build-app: .build/laban/Laban.app/Contents/MacOS/LabanApp` (codesigned
  ad-hoc). Confirms Steps 1-4 compile and link.
- `swift test --filter VectorGlyphRendererPrebuiltAtlasTests`: 4 tests, 0
  failures (compatible-at-init adoption, scale-mismatch hold-then-adopt-at-
  resize, wrong-cell-size rejection, prewarmed-ASCII cache hit via
  `rasterizedGlyphCount`).
- `swift test --filter SlugGlyphRendererPrebuiltAtlasTests`: 3 tests, 0
  failures (mirrored adoption contract for the slug renderer's single raster
  atlas).
- `swift test --filter ColdLaunchFastBackendTests`: 4 tests, 0 failures
  (vector cold launch shows the fast Metal backend immediately with
  `rendererSelection == .vectorGlyph`; eventually becomes `.vectorGlyph` after
  the synchronous prewarm seam; same for `.slugGlyph`; a classic cold launch
  does not defer).
- `swift test --filter RendererModeSettingsTests` and `swift test --filter
  RendererActivationNoBlankWindowTests`: both passed unmodified (part of the
  same targeted run, 20 tests total, 0 failures) — the mid-session switch path
  this plan deliberately left unchanged is not regressed.
- `swift test --filter VectorGlyph --filter SlugGlyph`: 105 tests, 0 failures.
  This includes `VectorGlyphSizeSweepTests.testGPUWindingMatchesOracleAcrossSizes`,
  which passes on current `main`; the "known pre-existing failure" the prior
  ExecPlan noted is no longer failing, so it is not a blocker here.
- Light `scripts/check` subsets (`./scripts/format`, `./scripts/lint`,
  `./scripts/check-boundaries`, `./scripts/check-docs`,
  `./scripts/check-debug-contract`): all passed. (`./scripts/format` was run
  first to normalize the hand-written additions; `./scripts/lint --strict` then
  passed clean.)
- Full `swift test` and the remaining `./scripts/check` steps (the headless
  `smoke-runtime`/`test-e2e`, the self-skipping TLA+/CBMC/coverage steps): see
  the Validation and Acceptance section for the final captured verdict.

For the live, human-observable check (mirroring the prior plan's manual
validation exactly, since it is the established pattern in this repo for
proving a renderer-startup fix works):

```sh
mkdir -p "$HOME/laban-debug-cold-launch-vector"
LABAN_INSTALL_DIR="$HOME/laban-debug-cold-launch-vector" scripts/install-app

# Persist .vectorGlyph as the renderer for THIS isolated debug bundle only —
# check docs/process/dev-process.md's "Scroll & Zoom Debug Surface" section for
# the exact defaults domain this debug bundle uses (it is re-identified with a
# distinct bundle ID during install, per the prior plan's manual-validation
# transcript, so its UserDefaults are already isolated from your real
# ~/Laban.app).

# Launch with a capture running so you get both the visible behavior and a
# fresh trace in one shot:
xcrun xctrace record --template "Metal System Trace" --time-limit 15s \
  --output /tmp/laban-cold-launch-vector-glyph-after-fix \
  --launch "$HOME/laban-debug-cold-launch-vector/Laban.app/Contents/MacOS/LabanApp"

# While/after that runs, watch the window: it must show terminal text
# immediately (no blank/white window), and remain responsive to input from the
# first moment it appears (try typing right away).

./scripts/analyze-metal-trace /tmp/laban-cold-launch-vector-glyph-after-fix \
  --cpu-only --max-rows 50000

kill any leftover debug process (`ps aux | grep -i laban`), then:
rm -rf "$HOME/laban-debug-cold-launch-vector"
```

## Validation and Acceptance

Before this fix: launching Laban fresh with `.vectorGlyph` persisted (e.g. via
`defaults write <bundle id> LabanRendererSelection vectorGlyph`, or by picking
it in Settings and relaunching) shows a blank/white window for several seconds,
during which the app does not respond to input, before terminal text appears.
A Metal System Trace of that launch shows ~49% of kept Time Profiler sample
weight in `MetalGlyphAtlas.entry`/`CTFontDrawGlyphs` (category "glyph
atlas/font lookup"), all attributable to the main thread's first synchronous
`VectorGlyphRenderer` frame.

After this fix: the same launch shows terminal content (rendered by the fast
temporary `.classic`/`.software` backend) immediately — no blank/white window,
and the window responds to input immediately. Within roughly the time it takes
the Step 2 prewarm to complete (expect well under 100 ms on the printable-ASCII
range, based on `MetalGlyphAtlas.entry`'s ~1 ms-per-sample cost observed in the
trace above and ~95 printable ASCII characters), the view seamlessly becomes
the real `VectorGlyphRenderer` — `view.backend is VectorGlyphRenderer` becomes
true, with no visible flash or frozen period a human would notice. A fresh
Metal System Trace of this launch should show the "glyph atlas/font lookup"
category's *wall-clock-attributable-to-a-blocking-main-thread-window* shrink
to near zero (the work still happens — cache-hit `MetalGlyphAtlas.entry` calls
for prewarmed glyphs are cheap, and any glyph outside the ASCII prewarm range
still rasterizes lazily on the real renderer's own first frame, same as every
other renderer today — but it no longer happens synchronously on the thread
that is also responsible for making the window appear).

Acceptance is: `swift test --filter VectorGlyph` and `swift test --filter
SlugGlyph` (including this plan's new tests) pass; `RendererModeSettingsTests`
and `RendererActivationNoBlankWindowTests` still pass unmodified; the live
`--scroll-debug` (or plain visual) check above shows no blank window and no
input-unresponsive period on a cold launch with `.vectorGlyph` persisted; and a
fresh trace comparison (before/after, using `scripts/analyze-metal-trace
--baseline`) shows the glyph-atlas category no longer dominating the launch
window. Record the actual before/after numbers here once captured — do not
mark this plan complete on unverified claims; this plan's own author could not
run any of these commands from its authoring environment.

### Captured evidence (2026-07-06, worktree `immutable-bouncing-puddle`)

- `./scripts/build-app` (debug): passes; Steps 1-4 compile and link, codesigned
  ad-hoc.
- New tests pass: `VectorGlyphRendererPrebuiltAtlasTests` (4),
  `SlugGlyphRendererPrebuiltAtlasTests` (3), `ColdLaunchFastBackendTests` (4).
  `ColdLaunchFastBackendTests.testColdLaunchWithVectorGlyphPersistedShowsFastBackendImmediately`
  is the unit-level proof of this plan's goal: with `.vectorGlyph` persisted,
  the active backend immediately after `init` is the fast Metal/classic backend
  (`usesMetalBackend == true`, `debugBackendEffectiveRenderer != .vectorGlyph`)
  while `rendererSelection == .vectorGlyph` is already reported, so the window
  shows content immediately instead of blank.
- Regression suites unmodified and green: `RendererModeSettingsTests`,
  `RendererActivationNoBlankWindowTests` (20-test targeted run, 0 failures).
- `swift test --filter VectorGlyph --filter SlugGlyph`: 105 tests, 0 failures
  (includes `VectorGlyphSizeSweepTests.testGPUWindingMatchesOracleAcrossSizes`,
  which passes on current `main`; the prior plan's "known failure" is no longer
  failing).
- Light `scripts/check` subsets pass: `format`, `lint`, `check-boundaries`,
  `check-docs`, `check-debug-contract`.
- Full `swift test`: two suites fail, BOTH pre-existing on clean `main`
  (verified by `git switch --detach 2423865` and re-running them on base):
  `VectorZoomGlyphSizeConsistencyTests.testGlyphSizesStaySingleAcrossZoomCommits`
  ("renderer never produced a non-dropped frame", 6 sizes; the vector renderer
  cannot acquire a drawable in this headless test environment while the user's
  real `~/Laban.app` is running) and
  `TabTitleEndToEndTests.testTitleClearedAfterOwnerExits` (a labpty E2E
  title-clear timing/path test). They reproduce identically on base `2423865`
  (`BASE_TEST_EXIT=1`), so this plan introduces zero new failures. The full
  `./scripts/check` gate is red on this machine for the same pre-existing
  reasons; it is expected to be green in a clean CI environment.
- Live GUI validation: blocked by an environment issue unrelated to this fix.
  The re-identified debug bundle (`com.laban.LabanApp.coldlaunch-debug`, used to
  isolate UserDefaults from the user's running `~/Laban.app`) crashes on launch
  in `NSBundle.module` / `L10n.tr` during `MenuCommands.setupMenuBar` (the
  `L10n` localization-forwarding change in `2423865` makes a re-identified
  bundle fail to resolve its module resource bundle). This crash reproduces
  independent of this plan's renderer changes and is the same crash reported in
  the session's first message. A same-bundle-ID launch is not safe here because
  the user's real `~/Laban.app` is running (shared `dev.laban.laband` daemon,
  shared UserDefaults domain). The cold-launch fix is instead verified at the
  code level by `ColdLaunchFastBackendTests`, which construct the real
  `TerminalBitmapView` with the real `MetalRenderer` and `VectorGlyphRenderer`,
  persist `.vectorGlyph`, and assert (a) the fast Metal/classic backend is
  active immediately after `init` while `rendererSelection == .vectorGlyph`,
  and (b) after the synchronous prewarm seam the backend becomes
  `VectorGlyphRenderer`. A live trace can be captured by a user with a free
  `~/Laban.app` (quit Laban, `LABAN_INSTALL_DIR=$HOME scripts/install-app`,
  pick Vector Glyph, relaunch) — the fix is in the build. Note: the plan's
  authored `xctrace record --launch <binary>` syntax needs `--launch --
  <binary>` on current xctrace (the `--` separator); the "log archive is
  corrupt" xctrace warning is benign (the `.trace` bundle still analyzes).

## Idempotence and Recovery

Every change in this plan is additive: new optional constructor parameters
(default `nil`, so all existing callers keep compiling), a new file
(`ColdLaunchAtlasPrewarmer.swift`), a new private stored property on
`TerminalBitmapView`, and a change to the *order and content* of
`TerminalBitmapView.init`'s existing renderer-selection block (not a change to
any other type's public API). If a partial implementation needs to be backed
out, reverting the edits to `TerminalBitmapView.init`,
`RendererSelection.makeRendererBackend`, `VectorGlyphRenderer.init`,
`SlugGlyphRenderer.init`, and removing the new prewarm file is sufficient to
return to today's (buggy but well-understood) cold-launch behavior. No
persisted state, migration, or schema is touched — `RendererSelection.set`/
`.persisted()` (`UserDefaults`) are read exactly as today.

## Interfaces and Dependencies

- `Metal` (`MTLDevice`, `MTLCommandQueue`, `MTLTexture`, `MTLRenderPipelineState`,
  `MTLComputePipelineState`) — already a dependency of this whole area; no new
  framework.
- `CoreText`/`CoreGraphics` (`CTFontDrawGlyphs` and friends, via
  `MetalGlyphAtlas.rasterizeAndPack`) — already a dependency; this plan does
  not call any new CoreText API, only moves *when* and *on which thread*
  already-used calls happen.
- `Dispatch` (`DispatchQueue`) — already used elsewhere in this exact area
  (`GlyphAtlasLadder.buildQueue`); this plan adds one more dedicated queue,
  matching that existing style (a `label:`ed queue with an explicit `qos:`,
  not the global concurrent queue).
- No new third-party dependencies, no `Package.swift` changes expected.
- Types this plan adds or changes the signature of:
  - `VectorGlyphRenderer.init?(fontAtlas:sidebarFontAtlas:pixelWidth:
    pixelHeight:scale:prebuiltRasterAtlas:prebuiltSidebarRasterAtlas:)` (2 new
    optional parameters).
  - `SlugGlyphRenderer.init?(...)` (mirrored, exact parameter names to be
    chosen for consistency with `VectorGlyphRenderer`'s during implementation).
  - `makeRendererBackend(selection:fontAtlas:sidebarFontAtlas:pixelWidth:
    pixelHeight:scale:)` in `RendererSelection.swift` (2 new optional trailing
    parameters, threaded through only on the `.vectorGlyph`/`.slugGlyph`
    branches).
  - New type `ColdLaunchAtlasPrewarmer` (or equivalent — name finalized during
    implementation, recorded in `Decision Log` if it differs from this name).
  - `TerminalBitmapView` gains one new private stored property (name your
    choice, e.g. `pendingColdLaunchAtlas`) and changes the body of its
    designated initializer plus (per Step 3.5) either a new private overload of
    `beginPendingBackendSwap` or a read of that stored property inside the
    existing one.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. See `PLANS.md`'s "Review gate and review-fix
loop" for the process.

- [ ] `git grep -n "prebuiltRasterAtlas" Sources/` shows the parameter added to
  both `VectorGlyphRenderer.init` and `SlugGlyphRenderer.init`, both defaulted
  to `nil`, and both `RendererSelection.swift`'s `.vectorGlyph` and
  `.slugGlyph` branches passing a value through (not silently dropped).
- [ ] `git grep -n "self.backend = Self.makeBackend" Sources/LabanApp/
  TerminalBitmapView.swift` still shows exactly the fast-backend
  (`.classic`/`.software`-resolving) call site for the vector/slug cold-launch
  case — i.e., no code path constructs `VectorGlyphRenderer`/
  `SlugGlyphRenderer` directly and synchronously inside `TerminalBitmapView.init`
  anymore when Metal is available.
- [ ] `swift test --filter RendererModeSettingsTests` and `swift test --filter
  RendererActivationNoBlankWindowTests` both report 0 failures (unmodified
  from before this plan, per its Decision Log's "leave the switch path
  unchanged" decision).
- [ ] `swift test --filter VectorGlyph` and `swift test --filter SlugGlyph`
  both report 0 new failures relative to the pre-existing known failure noted
  in the prior ExecPlan (`VectorGlyphSizeSweepTests.
  testGPUWindingMatchesOracleAcrossSizes`) — that one failure is pre-existing
  and unrelated; no other failure should appear.
- [ ] The live validation transcript in this plan's `Concrete Steps` section
  has been filled in with real command output (not placeholder text), and
  includes a before/after `scripts/analyze-metal-trace` comparison showing the
  glyph-atlas category no longer dominating a cold-launch trace window.
  BLOCKED on the implementing machine: the re-identified debug bundle crashes
  in `L10n`/`NSBundle.module` (unrelated to this fix; see Captured evidence),
  and the user's `~/Laban.app` is running. The cold-launch mechanism is
  verified instead by `ColdLaunchFastBackendTests`; a reviewer with a free
  `~/Laban.app` can capture the trace by quitting Laban, running
  `LABAN_INSTALL_DIR=$HOME scripts/install-app`, picking Vector Glyph, and
  relaunching under `xcrun xctrace record --template "Metal System Trace"
  --launch -- <binary>` (note the `--` separator).
- [ ] `./scripts/check` passes. On the implementing machine this is red only
  due to pre-existing, environment-sensitive failures
  (`VectorZoomGlyphSizeConsistencyTests`, `TabTitleEndToEndTests`) that
  reproduce identically on clean base `2423865` and are unrelated to this
  plan; the light subsets (`format`/`lint`/`check-boundaries`/`check-docs`/
  `check-debug-contract`) pass, and the plan adds zero new test failures.
  Expected green in a clean CI environment.

Review status: READY FOR REVIEW

Review findings (filled in by the review agent):

(none yet)
