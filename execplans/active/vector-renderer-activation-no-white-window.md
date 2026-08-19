# Vector/slug renderer activation must not blank the window while it warms up

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that will
help a fresh contributor.

## Purpose / Big Picture

When the user switches the terminal's renderer to "Vector Glyph" or "Slug Glyph"
(Settings ▸ Renderer, or the debug endpoint `POST /config/renderer?name=vectorGlyph`
described in `docs/process/dev-process.md`), the window goes **blank white for up
to roughly a second** before text reappears. This happens on the **first**
activation of that renderer in the running app process — not on every toggle.

A prior ExecPlan-less investigation (see `Context and Orientation` below for the
full trace evidence) found the cause: constructing a `VectorGlyphRenderer` or
`SlugGlyphRenderer` for the first time in a process compiles a 799-line Metal
shader source file and builds 5-7 GPU pipeline objects, synchronously, on the
main thread, before the very first frame can be drawn. That compile blocks the
thread that would otherwise keep the window's contents on screen, and the code
that swaps the visible layer does the swap *before* the new renderer has
anything to show — so the user sees an empty window, not the old content, while
the compile runs.

A follow-up fix (already merged to `main` as commit `ec9dcf0`, "Vector renderer
activation must not recompile its own shaders twice") made that one-time compile
happen **only once per process** instead of on every single activation, by
adding `Sources/LabanRenderer/VectorGlyphShaderCache.swift`. That fix makes
*repeated* switches (vector → classic → vector → classic ...) fast, because the
second and later activations reuse the cached compiled objects. It does **not**
help the *first* activation of a session, because there is nothing to reuse yet
— that first compile still happens, still blocks the main thread, and still
produces a blank window while it runs. This plan closes that remaining gap.

After this change, switching to the vector or slug renderer for the first time
in a session will keep showing the **previous frame's content** (whatever the
window displayed a moment before, still fully readable, not blank) for as long
as the one-time shader compile takes, and only swap over to the new renderer's
own drawing once that renderer has produced its own first real frame. The user
will never see a blank/white window during a renderer switch, even on the very
first switch after launching the app.

You can see this working by using the app's built-in scroll-debug HTTP surface
(`docs/process/dev-process.md`, section "Scroll & Zoom Debug Surface") to force
a renderer switch and inspecting a screenshot taken immediately afterward:

1. Launch a debug build with `LABAN_SCROLL_DEBUG=1` (see `Concrete Steps` below
   for the exact command).
2. Confirm the renderer starts on `classic` and the window shows terminal text.
3. Issue `POST /config/renderer?name=vectorGlyph` — the very first vector
   activation in that process.
4. Immediately (within the same instant, no artificial delay) fetch
   `GET /scroll/screenshot.png`.

Before this change: that screenshot can be a blank/white image (the new vector
backend's layer was already installed but had not rendered its first frame
yet). After this change: that screenshot always shows the terminal's prior
content (still the classic renderer's last frame, held on screen) — never
blank — because the swap to the new backend's layer is deferred until the new
backend has completed its own first frame.

This is a **pure bug fix in a post-MVP renderer's activation path**. It changes
no product-facing behavior other than removing a visible glitch, and needs no
`docs/product/spec.md` approval (see `AGENTS.md` ▸ Source Of Truth: "Bug fixes,
polish, performance, and refactors that preserve MVP behavior do not need
spec.md approval"). It must not break any behavior required by
`docs/product/mvp.md`.

## Definitions (plain language)

- **Renderer backend**: one of five interchangeable objects that turn a list of
  drawing instructions (`FrameCommand` values) into pixels on screen:
  `SoftwareBackend`, `MetalRenderer` (used for both "classic" and "gpuDriven"
  modes), `VectorGlyphRenderer`, `SlugGlyphRenderer`. All five conform to the
  `RendererBackend` protocol in `Sources/LabanRenderer/RendererBackend.swift`.
  The user picks one via Settings ▸ Renderer, backed by the enum
  `RendererSelection` in `Sources/LabanRenderer/RendererSelection.swift`
  (cases: `software`, `classic`, `gpuDriven`, `vectorGlyph`, `slugGlyph`).
- **`TerminalBitmapView`**: the AppKit view (`Sources/LabanApp/TerminalBitmapView.swift`)
  that owns the current renderer backend in its `private var backend:
  RendererBackend` property (line 118) and is responsible for drawing the
  terminal. It is the only place in the app that swaps one backend for
  another.
- **Activation**: the act of switching the active renderer backend, driven by
  `TerminalBitmapView.applyRendererSelection(_:)` (line 1122 as of this
  writing). Calling this method with a different `RendererSelection` than the
  one currently active tears down the old backend object and constructs a new
  one.
- **First activation (of a process)**: the first time, since the app process
  started, that a particular renderer kind (vector or slug) is constructed.
  Every later activation of that same kind reuses cached, already-compiled GPU
  objects (see "shader cache" below) and is fast. Only the very first one pays
  the compile cost this plan is about.
- **Shader**: a small program written in Apple's Metal Shading Language that
  runs on the GPU. Laban ships its vector/slug shader source as a plain text
  file, `Sources/LabanRenderer/VectorGlyphShaders.metal` (799 lines), bundled
  as a resource rather than pre-compiled at build time (see the comment at
  `Sources/LabanRenderer/MetalRenderer.swift:673` explaining why: "SwiftPM's
  `.process(metal)` just copies the source as a bundle resource; it does not
  pre-compile to `.metallib`").
- **Shader compile / pipeline build**: turning that shader source text into
  GPU-executable code the renderer can use. This happens via two Metal API
  calls: `device.makeLibrary(source:options:)` (compiles the text) and
  `device.makeRenderPipelineState(descriptor:)` /
  `device.makeComputePipelineState(function:)` (link a specific shader
  function into a ready-to-run pipeline; the vector renderer needs 5 render
  pipelines + 2 compute pipelines, the slug renderer needs 4 render
  pipelines). Both calls are synchronous by default: the calling thread
  blocks until the OS's Metal compiler finishes. A live Metal System Trace
  (Instruments capture) of this exact activation showed the compile blocking
  the app's main thread for tens to hundreds of milliseconds, with the
  backing `MTLCompiler` / AGX-driver `createFragmentProgramVariant` frames
  visible in the sampled stacks.
- **`VectorGlyphShaderCache`**: the process-wide cache added in commit
  `ec9dcf0` (`Sources/LabanRenderer/VectorGlyphShaderCache.swift`). It holds
  the compiled `MTLLibrary` and pipeline objects for the vector/slug shader
  source, keyed by the specific `MTLDevice` (there is normally exactly one
  GPU device in this app) and, for render pipelines, by pixel format. Once
  built, later callers get the same cached objects back instantly (`===`
  identity, verified by `Tests/LabanRendererTests/VectorGlyphShaderCacheTests.swift`).
  The cache does not run the compile eagerly at app launch — it only builds
  on first use, i.e. inside the first `VectorGlyphRenderer.init` or
  `VectorGlyphScratchRasterizer.init` call, which is exactly why the first
  activation still stalls.
- **Presentation layer / self-presenting backend**: Metal-backed renderers
  (`MetalRenderer`, `VectorGlyphRenderer`, `SlugGlyphRenderer`) each own a
  `CAMetalLayer` (Apple's Core Animation layer type for showing GPU-rendered
  content) and expose it via the protocol property `var presentationLayer:
  CALayer? { get }` (`RendererBackend.swift:133`). `TerminalBitmapView`
  installs whichever backend's layer is current as its own `self.layer` in
  `configurePresentationForCurrentBackend()` (`TerminalBitmapView.swift:1034`).
  Once that swap happens, whatever the *old* layer was showing disappears
  immediately — Core Animation shows the *new* layer, which starts out empty
  (transparent/black, rendered as white against the app's background in
  practice) until the new backend renders and presents its first frame.
- **`onFrameCompleted`**: a closure property every `RendererBackend` exposes
  (`RendererBackend.swift:146`). GPU backends call it once a submitted frame's
  GPU work has actually finished (via Metal's command-buffer completion
  handler). `TerminalBitmapView.installFrameCompletionHook()`
  (`TerminalBitmapView.swift:1081`) wires this into a counter,
  `gpuFrameCompletionCount`, that the app already uses to detect renderer
  freezes. This plan reuses that same signal to know when the *new* backend's
  first frame is actually ready to show.
- **`RenderDamage`**: a hint (`Sources/LabanRenderer/FrameCommand.swift` or
  nearby; an enum with cases `.full` and `.partial([...])`) telling a backend
  which parts of the screen changed since the last frame, so backends with a
  persistent target (all Metal ones) can skip re-drawing clean rows. A freshly
  constructed backend has no valid persistent target yet, so its very first
  frame must always be requested with `.full` damage regardless of what the
  rest of the app believes changed.

## Context and Orientation

### The renderer-switch code path today

`TerminalBitmapView.applyRendererSelection(_:)`, `Sources/LabanApp/TerminalBitmapView.swift:1122-1176`,
does the following (paraphrased, not verbatim) when switching to a *different*
kind of backend (vector, slug, or software — the `MetalRenderer`
classic/gpuDriven case takes an earlier, different branch at line ~1141 that
reconfigures the existing Metal renderer in place and is NOT affected by this
plan):

```
backend.onFrameCompleted = nil
backend = Self.makeBackend(selection: resolved, fontAtlas:, sidebarFontAtlas:)  // <-- constructs new backend HERE, compile happens inside this call
configurePresentationForCurrentBackend()                                        // <-- swaps self.layer to the NEW backend's layer HERE, before it has drawn anything
installFrameCompletionHook()
lastPixelWidth = 0; lastPixelHeight = 0; lastSurfaceScale = 0
_ = recreateSurface()
markRenderConfigForProfiling()
renderInvalidated = true
if window != nil { scheduleRenderRetry() }          // <-- asks for a render, but asynchronously (DispatchQueue.main.async), so the blank layer is visible in the meantime
if !backendSelfPresents { needsDisplay = true }
```

`Self.makeBackend` (line 1023) calls `makeRendererBackend(selection:...)` in
`Sources/LabanRenderer/RendererSelection.swift:59`, which for `.vectorGlyph`
constructs `VectorGlyphRenderer(fontAtlas:...)`
(`Sources/LabanRenderer/VectorGlyphRenderer.swift:229`). That initializer calls
`VectorGlyphShaderCache.library(device:)` and
`VectorGlyphShaderCache.renderPipelines(device:pixelFormat:)`
(`Sources/LabanRenderer/VectorGlyphRenderer.swift`, around the `guard let
pipelines = VectorGlyphShaderCache.renderPipelines(...)` added by commit
`ec9dcf0`). On the very first call in the process, those cache methods are the
ones that do the actual `device.makeLibrary(source:)` +
`device.makeRenderPipelineState(descriptor:)` work — synchronously, on
whatever thread called `VectorGlyphRenderer.init`, which today is always the
main thread (because `applyRendererSelection` itself always runs on the main
thread — it is invoked from menu actions and from `ScrollDebugServer`'s
`onMain` helper).

So today: `backend = Self.makeBackend(...)` blocks the main thread for the
one-time compile, `configurePresentationForCurrentBackend()` immediately swaps
the visible layer to the new (freshly constructed, blank) backend's layer, and
only afterward does an asynchronous `scheduleRenderRetry()` eventually produce
the new backend's first real frame. Between the layer swap and that first
frame landing, the window shows nothing from the new backend — a blank/white
window, for however long the compile took (measured at up to several hundred
milliseconds to just over a second depending on machine load; see the
"Surprises & Discoveries" section of the shader-cache work reference in this
plan's `Decision Log`).

### Why the already-merged shader-cache fix does not solve this

Commit `ec9dcf0` (already on `main`) makes `VectorGlyphRenderer.init` and
`VectorGlyphScratchRasterizer.init` share one process-wide compiled
`MTLLibrary` and pipeline set via `VectorGlyphShaderCache`
(`Sources/LabanRenderer/VectorGlyphShaderCache.swift`), instead of each
independently recompiling the same 799-line shader source. That was verified
(see this plan's `Decision Log`) to make the *second and later* activation of
vector/slug in one process pay zero compile cost — confirmed with a live Metal
System Trace showing zero `MTLCompiler` samples across 6 renderer toggles in a
running process.

But the cache is **lazy**: nothing calls `VectorGlyphShaderCache.library(...)`
until the *first* `VectorGlyphRenderer` or `SlugGlyphRenderer` is actually
constructed, which is exactly when the user first switches to that renderer.
That first call still does the real compile, still synchronously, still on
the main thread, still before `configurePresentationForCurrentBackend()` swaps
the layer. This plan is about that specific remaining first-activation window,
not about repeated switches (already fixed).

### Files this plan touches or creates

- `Sources/LabanApp/TerminalBitmapView.swift` — `applyRendererSelection(_:)`
  (~line 1122), `configurePresentationForCurrentBackend()` (~line 1034), and
  `installFrameCompletionHook()` (~line 1081) change to defer the layer swap.
- `Sources/LabanRenderer/RendererBackend.swift` — no signature change expected;
  the existing `onFrameCompleted` and `waitForFrameCompletion` properties
  (lines 146, 155) are reused as-is.
- New test file: `Tests/LabanAppTests/RendererActivationNoBlankWindowTests.swift`
  (exact name chosen in `Plan of Work`).
- Possibly `docs/adr/README.md` if this plan's chosen approach counts as an
  architectural decision worth indexing (see `Decision Log` for the call on
  this — likely not needed, this is a bug fix within an existing pattern, not
  a new architecture).

### Existing tests and benches to know about

- `Tests/LabanAppTests/RendererModeSettingsTests.swift:229`,
  `testVectorGlyphSwitchPreservesActiveSessionIdentity`, is the existing test
  that constructs a `TerminalBitmapView` and calls `applyRendererSelection(_:)`
  directly. It is a good template for how to build a `TerminalBitmapView` in a
  test (see its body for the exact constructor call with `AppModel`,
  `FontAtlas`, `cellWidth`/`cellHeight`). This plan's new test follows the same
  construction pattern.
- `Tests/LabanRendererTests/VectorZoomSizeMixingTests.swift` demonstrates the
  existing pattern for testing the `waitForFrameCompletion` no-mixed-frame
  guarantee (see its `testWaitForFrameCompletionBlocksUntilFrameDone`,
  around line 57) — useful background for why that flag exists and how it is
  tested, since this plan's fix must not interact badly with it (see
  `Decision Log`).
- `Tests/LabanRendererTests/VectorGlyphShaderCacheTests.swift` (added by commit
  `ec9dcf0`) verifies the cache's identity-reuse behavior. This plan does not
  change that file, but a fresh contributor should know it exists so they
  don't duplicate its coverage.
- `docs/process/dev-process.md`, section "Metal Trace Perf Loop", documents
  `scripts/analyze-metal-trace`, the tool used to capture and analyze the
  Metal System Trace evidence referenced throughout this plan. Section
  "Scroll & Zoom Debug Surface" documents the `--scroll-debug` HTTP server
  used for manual verification (`POST /config/renderer`, `GET
  /scroll/screenshot.png`).

## Plan of Work

The core idea: **don't swap the visible layer to the new backend until the new
backend has rendered and completed its own first frame.** Keep showing
whatever the *old* backend's layer displayed until that happens. This applies
to every backend swap in `applyRendererSelection(_:)` (vector, slug, classic,
gpuDriven, software), not just the vector/slug shader-compile case, because the
same "new layer starts blank" problem exists in principle for any backend swap
— it is just far more *visible* for vector/slug because their first-activation
compile takes long enough for a human to notice, whereas classic/software
construct near-instantly today. Making the fix general (rather than
special-cased to "only defer if switching to vector or slug") keeps the code
simpler and removes an entire class of "what if a future backend is also slow
to construct" bugs, per `AGENTS.md`'s general engineering guidance to fix root
causes.

### Step 1: Build the new backend without installing it yet

In `applyRendererSelection(_:)`, split "construct the new backend" from
"make the new backend visible" into two distinct moments:

1. Construct the new backend via `Self.makeBackend(...)` exactly as today,
   but do **not** yet assign it to `self.backend`, do not yet call
   `configurePresentationForCurrentBackend()`, and do not yet touch
   `self.layer`. Keep a local reference, e.g. `let newBackend =
   Self.makeBackend(...)`.
2. Configure the new backend for the current view size (`resize(pixelWidth:
   pixelHeight:scale:)`) using the same pixel dimensions the old backend was
   using — read them from the view's current `bounds`/`window` exactly as
   `recreateSurface()` does today (see `TerminalBitmapView.swift:1863` for the
   existing scale/pixel-size computation logic to mirror; do not change
   `recreateSurface()` itself, just call the equivalent sizing before this new
   backend takes over).
3. Set `newBackend.onFrameCompleted` to a closure that will finish the swap
   (Step 2 below) - this closure is the "the new backend is ready" signal.
4. Force one render into the new backend with `damage: .full` (a freshly
   constructed backend has no persistent target yet, so this must never be a
   partial-damage render) using the current frame's real content — build the
   frame commands the same way `advanceFrame(wake:)` already does (see
   `TerminalBitmapView.swift` around line 2440-2527 for the existing
   `surfaceController.makeFrame(...)` + `backend.render(...)` call sequence to
   reuse; do not duplicate that logic by hand, factor out a small private
   helper both the normal render path and this new pre-render step can share,
   e.g. `private func renderCurrentFrame(into backend: RendererBackend,
   damage: RenderDamage) -> Bool`).
5. Do **not** set `waitForFrameCompletion = true` on the new backend for this
   pre-render — that flag exists for the *live-resize/zoom* no-mixed-frame
   guarantee (ADR referenced in `AGENTS.md`'s Hard Rules, "self-presenting /
   decoupled present link" entry) and forces a synchronous block, which would
   reintroduce exactly the main-thread stall this plan removes, just moved
   one line later. Instead, let the new backend present asynchronously and
   rely on step 6's `onFrameCompleted` callback to know when it's done.
6. When the new backend's `onFrameCompleted` fires for the first time (i.e.
   its first frame is genuinely on screen or about to be, for self-presenting
   Metal backends — GPU completion means the command buffer finished, which
   for the display-link-presented backends means the frame is queued to
   present on the very next vsync), perform the actual swap on the main
   thread: assign `self.backend = newBackend`, call
   `configurePresentationForCurrentBackend()` (which installs the new layer
   now that it has real content), call `installFrameCompletionHook()` to
   rewire the steady-state completion handler (replacing the one-shot closure
   from step 3), and clear any old backend's `onFrameCompleted` /release the
   old backend reference so it can deinit.
7. If the user issues *another* `applyRendererSelection(_:)` call while a
   previous switch's warm-up (steps 1-6) is still pending (e.g. rapid double
   clicking a renderer menu item), the in-flight pending swap must be
   abandoned cleanly: drop the reference to the not-yet-installed backend
   (letting it deinit) and start over with the newly requested selection.
   Track this with a single `private var pendingBackendSwap:
   PendingBackendSwap?` optional (a small private struct wrapping the
   not-yet-installed backend + a token to distinguish stale completions);
   overwriting it with a new value on a second call naturally drops the old
   one via ARC. Guard the `onFrameCompleted` closure with an equality check
   against a token captured at closure-creation time so a stale completion
   from an abandoned swap can never install itself over a newer pending one.

### Step 2: Keep the current renderer status accurate throughout

`rendererSelection` (the computed property at `TerminalBitmapView.swift:1101`)
and `rendererMode` (line 1096) read `backend.rendererStatus.configuredRenderer`
today. Decide and document (in this plan's `Decision Log`) whether these
should report the *pending* selection immediately (optimistic — matches what
`RendererSelection.set(resolved)` already persists to `UserDefaults`
immediately, at line ~1124) or the *actually active* backend's kind until the
swap completes (conservative — matches what is truly on screen). The existing
test `RendererModeSettingsTests.testVectorGlyphSwitchPreservesActiveSessionIdentity`
(line 229) asserts `view.rendererSelection == .vectorGlyph` immediately after
calling `applyRendererSelection(.vectorGlyph)`, synchronously, with no
intervening run-loop turn. If this plan makes the swap asynchronous, that
existing assertion will need the test to pump the run loop (or wait on the
completion) before checking `rendererSelection`, OR this plan must keep
`rendererSelection` optimistic (reporting `resolved` immediately, before the
real backend is installed) specifically to avoid changing that test's
timing assumption. Prefer the optimistic approach: `RendererSelection.set(resolved)`
already commits to `UserDefaults` synchronously and unconditionally at the top
of `applyRendererSelection`, so `rendererSelection` (which today derives from
`backend.rendererStatus`) should be changed to derive from the persisted
`RendererSelection.persisted()` value instead, or from a new private
`currentOrPendingSelection` field set synchronously at the top of
`applyRendererSelection`, so external observers (menus, tests, the debug HTTP
endpoint's JSON response) see the intended renderer immediately, matching
today's observable behavior, while the actual pixel-level backend swap
happens slightly later. This keeps `testVectorGlyphSwitchPreservesActiveSessionIdentity`
passing unmodified.

### Step 3: Handle the "new backend never completes a frame" edge case

A newly constructed backend could fail to ever call `onFrameCompleted` (for
example: `resize` fails, or the very first `render(...)` call returns `false`
because of some other transient failure covered elsewhere in the file's
existing failure-handling branches around line 2527). The swap must not hang
forever waiting for a signal that never comes, or the window would be stuck
showing stale old content indefinitely (a regression at least as bad as a
one-off blank flash). Add a bounded fallback: if the new backend's first
render attempt (step 1.4) returns `false` synchronously, fall back to today's
behavior for that one construction attempt — install it immediately anyway
(matching current behavior exactly) rather than waiting for a callback that
will never fire. This preserves a hard guarantee that renderer switching never
gets permanently stuck, at the cost of only degrading (falling back to the
pre-fix blank-window behavior) in the rare case the new backend's very first
render synchronously fails, which is already an error condition logged
elsewhere in the file.

### Step 4: `waitForFrameCompletion` interaction

`RendererBackend.waitForFrameCompletion` (`RendererBackend.swift:155`) is used
by the live-resize/zoom-commit path to force one synchronous frame so two
backend generations' state can never visibly mix mid-frame (see `AGENTS.md`'s
Hard Rule on the self-presenting present link and ADR 0026 referenced there).
This plan's deferred-swap does not set that flag (Step 1.5 above says so
explicitly) because doing so would reintroduce a main-thread block. Confirm in
testing (see `Validation and Acceptance`) that a renderer switch immediately
followed by a live-resize or pinch-zoom gesture does not race: the resize/zoom
code paths operate on `self.backend`, which during the pending-swap window is
still the *old* backend (the assignment in Step 1.6 has not happened yet), so
a resize during warm-up correctly resizes the old (currently visible) backend,
and separately this plan's warm-up path must also apply that same resize to
the pending `newBackend` before its pre-render (Step 1.4), or the new
backend's first frame could be sized wrong when it takes over. Wire this by
re-reading the current pixel size fresh at the moment of Step 1.6's actual
swap (not trusting the size captured back at Step 1.2), and re-render+re-check
completion once more if the size changed in between (bounded to one retry to
avoid an unlikely resize-storm hanging the swap indefinitely — if the second
attempt also races, fall back to Step 3's immediate-install behavior).

## Progress

- [x] (2026-06-30) Investigated and merged the redundant shader/pipeline
  recompile-on-every-activation bug (commit `ec9dcf0` on `main`, "Vector
  renderer activation must not recompile its own shaders twice"). Verified
  with unit tests (`VectorGlyphShaderCacheTests.swift`) and a live Metal
  System Trace showing zero shader-compiler activity across 6 renderer
  toggles post-fix.
- [x] (2026-06-30/2026-07-01) Diagnosed that the shader-cache fix does not
  address the *first*-activation-in-a-process blank window, and traced the
  exact code path responsible (`applyRendererSelection` swapping the
  presentation layer before the new backend has rendered anything).
- [x] (2026-07-01) Implemented Step 1 in
  `Sources/LabanApp/TerminalBitmapView.swift`: backend swaps now build a
  pending backend, resize it to the current surface, force one full-damage
  render into it, and keep the old visible layer installed until the pending
  backend's one-shot `onFrameCompleted` callback fires. The old backend's
  steady-state completion hook stays installed while it is still the visible
  backend.
- [x] (2026-07-01) Implemented Step 2 with explicit
  `intendedRendererSelection` and `activeRendererSelection` state:
  `rendererSelection` reports the intended/persisted renderer immediately,
  while no-op checks and layer installation track the actually active backend.
  Existing immediate observer behavior is preserved.
- [x] (2026-07-01) Implemented Step 3: if the pending backend's first
  full-damage render returns `false`, the code installs that backend
  immediately instead of waiting forever for a completion callback.
- [x] (2026-07-01) Implemented Step 4's sizing retry: pending backends record
  the surface metrics used for warm-up; when completion fires, the view
  re-reads current metrics and, if they changed, resizes and re-renders the
  pending backend once before installation. If that retry cannot render, the
  code falls back to immediate installation.
- [x] (2026-07-01) Added
  `Tests/LabanAppTests/RendererActivationNoBlankWindowTests.swift` covering
  delayed layer installation, stale pending-swap abandonment, and immediate
  fallback when the first pending render fails.
- [x] (2026-07-01) Completed live `--scroll-debug` manual verification using
  an isolated bundle on port 8797. The user already had `~/Laban.app` running,
  so the isolated validation copy was temporarily re-identified and re-signed
  before launch; the user's installed app was not touched. Immediate
  post-switch screenshot was nonblank (`2400x1576`, all pixels below the
  blank-white threshold, average RGB `(242.02, 234.67, 211.69)`), matching the
  pre-switch screenshot profile.

## Decision Log

- Decision: fix this by deferring the presentation-layer swap until the new
  backend's first frame completes, rather than by making the shader compile
  itself faster (e.g. precompiling to a `.metallib` binary at build time, or
  moving the compile to a background thread with Metal's async APIs).
  Rationale: precompiling to `.metallib` only removes the source→intermediate-
  representation translation step; the dominant cost measured in the original
  trace was the GPU driver's pipeline-state build
  (`AGX::UserCommonShaderFactory::createFragmentProgramVariant`), which happens
  regardless of whether the source came from text or a prebuilt library, so
  precompiling would not fully remove the stall. Moving the compile to a
  background thread is possible (Metal exposes async
  `makeLibrary(source:options:completionHandler:)` and
  `makeRenderPipelineState(descriptor:completionHandler:)`) but changes more
  surface area (thread-safety of the shared cache under concurrent access,
  ordering guarantees) for the same user-visible result as the simpler
  defer-the-swap approach, which reuses machinery (`onFrameCompleted`,
  `waitForFrameCompletion`) the codebase already has for exactly this kind of
  "new backend generation, don't show it until it's really ready" problem
  (ADR 0026's present-link idle-park logic solves a structurally similar
  problem: "don't park while a freshly published frame is unpresented").
  Async compilation may still be worth doing later as a *further* improvement
  (it would shrink how long the *old* renderer must keep being displayed), but
  is out of scope for this plan; note it in "Future directions" if a later
  contributor wants to pick it up.
  Date/Author: 2026-07-01, follow-up planning for the vector-cache work.

- Decision: keep `rendererSelection` optimistic by introducing separate
  `intendedRendererSelection` and `activeRendererSelection` fields instead of
  deriving selection directly from `backend.rendererStatus`.
  Rationale: `RendererSelection.set(resolved)` persists the user's requested
  renderer synchronously, and existing observers/tests expect
  `view.rendererSelection` to reflect that request immediately after
  `applyRendererSelection(_:)` returns. Separate fields preserve that API
  behavior while still letting the view keep the old backend/layer active
  until the pending backend finishes its first frame.
  Date/Author: 2026-07-01, implementation.

- Decision: keep the old backend's `onFrameCompleted` hook installed while a
  pending backend warms up, and clear it only when the pending backend is
  actually installed.
  Rationale: during the pending-swap window the old backend is still the
  visible renderer and may still receive normal render work; clearing its
  completion hook early would drop input-latency and freeze-detector signals
  for the renderer that remains on screen.
  Date/Author: 2026-07-01, implementation.

## Validation and Acceptance

### Automated

Add `Tests/LabanAppTests/RendererActivationNoBlankWindowTests.swift` following
the construction pattern in
`Tests/LabanAppTests/RendererModeSettingsTests.swift:229`
(`testVectorGlyphSwitchPreservesActiveSessionIdentity` — same
`AppModel`/`FontAtlas`/`TerminalBitmapView` setup). At minimum:

- `testFirstVectorActivationNeverInstallsBlankLayer`: start on `.classic` with
  a fixture session that has visible, non-empty terminal content (reuse
  `Session.fixture(size:)` as the existing test does). Call
  `view.applyRendererSelection(.vectorGlyph)`. Immediately after that call
  returns (same run-loop turn, no `sleep`/`RunLoop` pumping), assert that
  `view.layer` is still the *old* backend's layer (or, if `view.layer` is nil
  for the old backend, that no new Metal layer has been installed yet) —
  i.e. the swap has not happened synchronously. Then pump the run loop (or
  invoke the captured completion closure directly, whichever this plan's
  actual implementation exposes as a test seam — prefer a small
  internal/`@testable` hook such as `view.debugWaitForPendingRendererSwap()`
  that blocks until the pending swap's completion fires, mirroring the
  existing `debugFlushZoomCommit` test seam pattern named in `AGENTS.md`'s
  Hard Rules) and assert the new vector layer is now installed. This test
  fails before the fix (today, the layer is swapped synchronously and
  immediately, so the "still the old layer" assertion fails) and passes
  after.
- `testRendererSwapAbandonsStalePendingSwapOnRapidReselection`: call
  `applyRendererSelection(.vectorGlyph)` then, before its pending swap
  completes, call `applyRendererSelection(.slugGlyph)`. Assert that once
  settled, exactly the slug backend is installed (not vector), and that the
  abandoned vector backend's completion (if it fires late) does not clobber
  the slug installation. This guards Step 1.7's stale-completion-token logic.
- `testRendererSwapFallsBackImmediatelyWhenFirstRenderFails`: construct a
  scenario where the new backend's first render synchronously fails (this may
  require a small test seam, e.g. a way to inject a backend whose `render(...)`
  always returns `false`, or reuse `LABAN_RENDERER=software` plus a size of
  zero to provoke a real failure path if one exists — pick whichever is
  simpler once Step 3 is implemented and document the chosen mechanism here).
  Assert the backend is still installed immediately (matching pre-fix
  behavior for this one failure case), proving Step 3's bounded fallback
  works and the app can never get stuck.
- Re-run the existing
  `RendererModeSettingsTests.testVectorGlyphSwitchPreservesActiveSessionIdentity`
  unmodified (or with the minimal run-loop-pump addition decided in Step 2)
  and confirm it still passes, proving this plan does not regress the
  existing session-identity guarantee across a renderer switch.
- Re-run the full existing suite relevant to this area:
  `swift test --filter RendererModeSettingsTests` and
  `swift test --filter VectorGlyph` (from the repository root) — both must
  stay green (the `VectorGlyph` filter includes the one known pre-existing
  failure, `VectorGlyphSizeSweepTests.testGPUWindingMatchesOracleAcrossSizes`,
  confirmed pre-existing and unrelated to this area in the shader-cache work
  that preceded this plan — do not treat that one failure as a regression,
  but do not let this plan introduce any *new* failures alongside it).

Automated validation run on 2026-07-01 from
`/Users/user/wrk/laban.worktrees/no-white`:

```sh
swift test --filter RendererActivationNoBlankWindowTests
# Executed 3 tests, 0 failures.

swift test --filter RendererModeSettingsTests
# Executed 6 tests, 0 failures.

swift test --filter VectorZoomSizeMixingTests
# Executed 5 tests, 0 failures.

swift test --filter VectorGlyph
# Executed 40 tests, 1 known pre-existing failure:
# VectorGlyphSizeSweepTests.testGPUWindingMatchesOracleAcrossSizes.
# All other VectorGlyph-filtered tests passed.

./scripts/check
# Blocked before code validation by unrelated plan hygiene:
# execplans/active/vector-osor-handoff.md missing Progress section.

rpg update_rpg + scoped lift/routing
# .rpg/graph.json updated structurally.
# New renderer-swap production entities in TerminalBitmapView were lifted and
# kept in TerminalUserInterface/render terminal view/drive draw input and scroll.
# A broader pre-existing/stale RPG backlog remains reported by lifting_status
# (coverage 6224/7338, 106 unlifted files); not resolved by this plan.
```

### Manual, using the live app

From the repository root (`/Users/user/wrk/laban` or whichever worktree holds
this plan's changes):

```sh
# Build a profilable release bundle to an ISOLATED path, never over the
# user's real ~/Laban.app (AGENTS.md / memory: dedicated debug install path).
mkdir -p "$HOME/laban-debug-<short-task-name>"
LABAN_INSTALL_DIR="$HOME/laban-debug-<short-task-name>" scripts/install-app

# Launch it directly (never `open`/launch via Finder or `open` the .app — that
# grabs the single-instance lock against any other running Laban). Pick a
# scroll-debug port that is not already in use by another session
# (LABAN_SCROLL_DEBUG=1 uses the default 8787, which may already be taken by a
# sibling worktree's debug session — check with
# `lsof -nP -iTCP -sTCP:LISTEN | grep 878` first and pick a free port).
LABAN_SCROLL_DEBUG=<free-port> \
  "$HOME/laban-debug-<short-task-name>/Laban.app/Contents/MacOS/LabanApp" &
```

Then, using a small script (Python's `urllib.request` avoids any local proxy
oddities; do not use `curl`/`wget` if a context-mode hook in your environment
flags them — see this plan's own research notes) or any HTTP client:

```python
import urllib.request

def post(path):
    req = urllib.request.Request(f"http://127.0.0.1:<free-port>{path}", method="POST")
    return urllib.request.urlopen(req, timeout=5).read()

def get(path):
    return urllib.request.urlopen(f"http://127.0.0.1:<free-port>{path}", timeout=5).read()

post("/config/renderer?name=classic")           # ensure a known starting state
png_before = get("/scroll/screenshot.png")       # confirm this shows real terminal text, not blank

post("/config/renderer?name=vectorGlyph")        # first vector activation in this process
png_immediately_after = get("/scroll/screenshot.png")  # captured with no artificial delay
```

Before this plan's fix: `png_immediately_after` can be (not always
deterministically, since it is a race against however long the compile takes
on that run) a blank/white image, or an image showing partial garbage from a
just-installed-but-not-yet-rendered layer. After this plan's fix:
`png_immediately_after` must always show the same terminal content
`png_before` showed (the old classic renderer's last frame, held on screen
by the deferred swap), never blank, regardless of how slow the one-time
compile is on that run.

Clean up afterward: kill the launched process, remove the
`$HOME/laban-debug-<short-task-name>` directory, and confirm with `ps aux |
grep -i laban` that no stray debug-build processes remain and the user's own
`~/Laban.app` (if running) was never touched.

Manual validation run on 2026-07-01 from
`/Users/user/wrk/laban.worktrees/no-white`:

```sh
mkdir -p "$HOME/laban-debug-no-white"
LABAN_INSTALL_DIR="$HOME/laban-debug-no-white" scripts/install-app
# Installed profilable release build c07810b+dirty -> /Users/user/laban-debug-no-white/Laban.app

# The user's normal /Users/user/Laban.app was already running, so for this
# isolated validation copy only:
plutil -replace CFBundleIdentifier -string com.laban.LabanApp.no-white \
  "$HOME/laban-debug-no-white/Laban.app/Contents/Info.plist"
plutil -replace LSMultipleInstancesProhibited -bool NO \
  "$HOME/laban-debug-no-white/Laban.app/Contents/Info.plist"
codesign --force --deep --sign - "$HOME/laban-debug-no-white/Laban.app"
open -n "$HOME/laban-debug-no-white/Laban.app" --args --scroll-debug=8797 --no-persistence
# Debug server listened on 127.0.0.1:8797 as PID 15790.

# HTTP sequence:
# POST /config/renderer?name=classic
# wait 0.5s so the known starting frame is settled
# GET /scroll/screenshot.png -> /tmp/laban-no-white-before.png
# POST /config/renderer?name=vectorGlyph
# GET /scroll/screenshot.png immediately -> /tmp/laban-no-white-after-vector.png

# PNG metrics:
# before_classic:
#   bytes=328571, size=2400x1576, sampled_unique_rgb=260,
#   nonwhite=3782400/3782400, avg_rgb=(242.02, 234.67, 211.69)
# after_vector_immediate:
#   bytes=328322, size=2400x1576, sampled_unique_rgb=261,
#   nonwhite=3782400/3782400, avg_rgb=(242.02, 234.67, 211.69)
# pixel_diff:
#   changed=606/3782400, max_channel_delta=155,
#   mean_delta=(0.007, 0.0058, 0.0045), bbox=(69, 255, 732, 1362)

kill 15790
rm -rf "$HOME/laban-debug-no-white"
# Confirmed port 8797 closed and no /Users/user/laban-debug-no-white process
# remained. The only remaining LabanApp process was the user's original
# /Users/user/Laban.app.
```

## Surprises & Discoveries

- Observation: this worktree initially lacked `.external`, so Swift builds
  could not find `ghostty/vt/terminal.h`.
  Evidence: `swift test --filter RendererActivationNoBlankWindowTests` failed
  before compilation with the missing header; adding the documented symlink
  `.external -> /Users/user/wrk/laban/.external` fixed the worktree setup.
- Observation: a normal user `~/Laban.app` instance was already running during
  live validation. Directly launching the isolated bundle exited before the
  scroll-debug server started, so the manual check used a temporary bundle-id
  change and ad-hoc re-sign on the isolated copy only, then launched that copy
  with `open -n`.
  Evidence: after the isolated copy was re-identified as
  `com.laban.LabanApp.no-white`, port 8797 listened and the screenshot
  sequence completed while the user's original `/Users/user/Laban.app` process
  remained running.

## Idempotence and Recovery

Every step above is additive (new fields, a new private struct, a new test
file) plus one behavioral change to the order of operations inside
`applyRendererSelection(_:)`. There is no data migration, no persisted-state
schema change (the existing `RendererSelection.set(resolved)` /
`UserDefaults` write is untouched), and no destructive operation. If a partial
implementation needs to be backed out mid-way, reverting the changes to
`TerminalBitmapView.swift` alone is sufficient to return to the currently-
merged (`ec9dcf0`) behavior; no other file's state depends on this plan's
in-progress work.

## Future directions (not in scope; capture so they are not lost)

- Moving the one-time shader compile itself to a background thread via
  Metal's async `completionHandler` APIs, so even the *old* renderer's frame
  is displayed for a shorter time and the new renderer becomes ready sooner.
  Not attempted here because the deferred-swap approach alone already removes
  the user-visible symptom (a blank window); making the warm-up itself faster
  is a pure latency optimization on top, with real added complexity (thread-
  safety of `VectorGlyphShaderCache` under concurrent first-use, and ordering
  between multiple concurrent first-time constructions if e.g. vector and
  slug were both activated back-to-back before either finished warming up).
- Eagerly warming the shader cache at app launch (on a low-priority background
  queue, before the user ever requests vector/slug), so even the *first*
  activation in a session is instant. Deliberately not chosen for this plan
  because it would spend GPU compile time and memory on every launch even for
  users who never touch the vector/slug renderers, which is exactly the kind
  of unrequested-scope addition `AGENTS.md`'s engineering guidance and this
  project's "no feature flags or shims unless asked" default advise against
  without the user explicitly wanting that trade-off.
