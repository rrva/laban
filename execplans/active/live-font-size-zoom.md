# Live font-size zoom (Cmd+= / Cmd+-) with a prebuilt atlas ladder

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

Today the terminal font size is fixed at app launch. Changing it (Settings ▸
Font ▸ Change…) persists a new value to UserDefaults and shows an alert:
"Restart Laban to apply." There is no way to make text bigger or smaller while
working.

After this change, pressing **Cmd+=** (or Cmd+Shift+= , i.e. Cmd+plus) makes
the terminal text one point larger, **Cmd+-** makes it one point smaller, and
**Cmd+0** returns to the default size (14 pt). The change is instant — no
restart, no flash of garbled or blank content — and behaves like a window
resize from the running programs' point of view: the shell and any TUI app
receive a window-size change (SIGWINCH) and reflow, because a bigger font in
the same window means fewer columns and rows. The chosen size persists across
restarts. Matching menu items appear under **View** (Bigger Text, Smaller
Text, Default Text Size).

The performance design decision (made by the project owner) is to **prebuild
glyph atlases for every reachable zoom size at startup**, in the background,
so that a zoom step never rasterizes glyphs on the hot path. A zoom step is
then: swap a pointer to a prebuilt atlas, renegotiate the grid size with the
terminal engine and PTY (the same code path a window resize already uses), and
redraw. The set of reachable sizes is made finite by clamping zoom to integer
point sizes in **8…40 pt** — we call the prebuilt collection the **atlas
ladder**.

## Progress

- [x] (2026-06-12) Plan drafted; codebase mapped; external designs surveyed
      (Alacritty resets its glyph cache lazily and reloads ASCII; Ghostty
      keeps reference-counted per-size font grids created on demand; neither
      precomputes — Laban deliberately goes further and prebuilds, trading
      bounded memory for guaranteed zero raster work per step).
- [ ] M1: live zoom mechanics end-to-end (synchronous atlas build, no ladder
      yet); Cmd+= / Cmd+- / Cmd+0 work; persistence; menu items.
- [ ] M2: prebuilt atlas ladder + ASCII prewarm + rasterization counter;
      perf acceptance met.
- [ ] M3: headless/debug parity (`setFontSize` action, persisted size read),
      schema updates, tests green, capture/replay sanity.
- [ ] Review Gate passed.

## Decision Log

- Decision: Prebuild atlases for all reachable sizes at startup (the "atlas
  ladder") instead of building lazily on first use of a size.
  Rationale: Project owner's explicit requirement: zoom must be "super fast".
  Lazy building (what Alacritty/Ghostty do) costs ~1–3 ms of CoreText
  rasterization on the first frame at a new size; prebuilding moves that cost
  to background work at startup and makes every step's atlas cost zero. The
  ladder is bounded (33 sizes), so "all sizes" is finite and memory stays
  within budget (see Interfaces; measured target ≤ 48 MB).
  Date/Author: 2026-06-12 / owner + agent.
- Decision: Zoom range is integer point sizes 8…40, step 1 pt; Cmd+0 resets
  to `FontAtlas.defaultTerminalPointSize` (14).
  Rationale: Bounds the ladder; covers practical use. Fractional persisted
  values (possible via `defaults write`) are clamped/rounded on the first
  zoom step. Reset targets the built-in default because zoom persists into
  the same UserDefaults key as Settings (single source of truth, no separate
  "base size" key).
  Date/Author: 2026-06-12 / agent.
- Decision: Zoom is global (all tabs/sessions in the window) and persists
  to UserDefaults (`LabanFontSize`) on every step.
  Rationale: `AppModel.resize` already fans out to all sessions. Ghostty's
  per-surface zoom is a documented UX trap (new tabs inherit zoom, "reset"
  resets to the wrong baseline). Persisting each step makes Cmd+= literally
  "the Settings font size, live".
  Date/Author: 2026-06-12 / agent.
- Decision: The sidebar (tab column) font zooms together with the terminal,
  keeping today's proportional derivation (`sidebar = terminal × 11/14`).
  Rationale: Restart semantics already scale the sidebar with the persisted
  terminal size. Zooming only the terminal live, while persisting the size,
  would make the next launch look different from the live state. Consistency
  wins; the sidebar atlas swap rides the same mechanism.
  Date/Author: 2026-06-12 / agent.
- Decision: Settings font panel changes apply live when only the size
  changed; a family change still shows the restart alert.
  Rationale: The user accepted restart-on-family-change. Family changes
  invalidate fallback-font discovery and metrics in ways size changes do
  not (same family at a new point size is a trivially derived CTFont).
  Date/Author: 2026-06-12 / owner + agent.
- Decision: Ladder entries are built entirely off the main thread and handed
  over immutable; the active-atlas swap happens on the main thread between
  frames. Prebuilt atlases are never mutated while a renderer might read
  them.
  Rationale: Ghostty has chased use-after-free bugs from growing an atlas
  in place while the render thread reads it. Laban's existing pattern
  (replace the whole `MetalGlyphAtlas` object on backing-scale change)
  avoids that class of bug; the ladder keeps the pattern.
  Date/Author: 2026-06-12 / agent.

## Context and Orientation

Laban is a macOS terminal app built with SwiftPM. Three products are built by
`./scripts/build-app`: the AppKit app (`LabanApp`), a daemon (`laband`), and a
PTY helper (`labpty`). The pieces this plan touches:

- **`FontAtlas`** (`Sources/LabanRenderer/FontAtlas.swift`) — despite the
  name, this is *font metrics*, not a texture. It wraps a CoreText font
  (`CTFont`) at a point size and exposes `cellSize` (the pixel width of the
  glyph 'M', rounded up, by the line height `ascent+descent+leading` rounded
  up), `ascent`, `descent`, `leading`. UserDefaults keys: `LabanFontName`,
  `LabanFontSize` (default 14 pt; static `defaultTerminalPointSize`). The
  sidebar uses a second `FontAtlas` at `persistedSidebarPointSize` =
  terminal size × 11/14. `FontAtlas.didChangeNotification` is posted when the
  font panel saves; today only the Settings UI listens.
- **`MetalGlyphAtlas`** (`Sources/LabanRenderer/MetalGlyphAtlas.swift`) — the
  actual GPU texture cache: a single-channel (`r8Unorm`) Metal texture (2048²
  by default, configurable via the `textureSize:` init parameter, max 16384)
  into which glyph bitmaps are packed with a shelf packer (rows of equal
  height filled left to right). Glyphs are rasterized **lazily**: the first
  time the renderer asks for a character (`entry(scalar:font:...)`), CoreText
  draws it into the texture and the cache remembers the tile. Cell pixel
  dimensions, descent, and backing scale are **fixed at init**. When the
  texture fills up, `MetalRenderer.growGlyphAtlas(forSidebar:)`
  (`Sources/LabanRenderer/MetalRenderer.swift:1272`) replaces it with an
  empty atlas at double the texture size.
- **`MetalRenderer`** (`Sources/LabanRenderer/MetalRenderer.swift`) — owns
  two atlases (terminal + sidebar), cell metrics copies (`glyphCellAdvance`,
  `glyphCellHeight`, `sidebarCellAdvance`, `sidebarCellHeight`), and several
  derived caches: `scalarEntryCache*` / `defaultASCIIEntryCache*` (per-frame
  glyph-lookup caches invalidated by bumping `scalarEntryCacheGeneration`,
  see line ~409), and the GPU-cell path's `cellGlyphs` /
  `cellGlyphGridGeometry`. There is an existing **backing-scale change**
  branch in `resize(pixelWidth:pixelHeight:scale:)` (around line 852) that
  rebuilds both atlases and clears all of these — it is the template for the
  font-size swap, with one difference: it keeps cell dimensions, we change
  them.
- **`SoftwareRenderer` / `SoftwareBackend`**
  (`Sources/LabanRenderer/SoftwareRenderer.swift`) — the CPU fallback
  renderer rasterizes text every frame straight from its `FontAtlas`; it has
  no GPU atlas. Zoom there is just "new `FontAtlas`, recreate renderer".
- **`TerminalBitmapView`** (`Sources/LabanApp/TerminalBitmapView.swift`) —
  the NSView hosting everything. Holds `private let cellWidth/cellHeight`
  (line ~34) and `private let fontAtlas/sidebarFontAtlas` — **immutable
  today; this plan makes them `private(set) var`**. Window resize flows
  through `setFrameSize` (~line 3146): recompute the terminal viewport,
  derive `cols = termW / cellWidth`, call `AppModel.resize`, clear selection
  when columns change, defer find rescans during live resize, render
  synchronously. Keyboard: `keyDown` builds a `TerminalKeyDescriptor`
  (`Sources/LabanApp/TerminalInputView.swift`), whose `routeCommand()`
  (line ~153) maps Cmd-chords to `AppCommand` enum cases (same file, line 7);
  unmapped Cmd-chords are swallowed (not sent to the PTY), so Cmd+= / Cmd+- /
  Cmd+0 are free. `executeAppCommand(_:)` in `TerminalBitmapView` (~line
  3455) dispatches the cases. Cmd+1…8 select tabs, Cmd+9 selects the last
  tab — Cmd+0 is unused.
- **`TerminalSurfaceController`**
  (`Sources/LabanCore/TerminalSurfaceController.swift`) — builds each frame;
  holds its own `cellWidth/cellHeight/sidebarCellWidth/sidebarCellHeight`
  set at init. Per-frame `FrameProducer` / `SidebarProducer` instances are
  constructed from those values, so once they update, frames are correct.
- **Resize plumbing** — `AppModel.resize(viewportWidth:viewportHeight:cellWidth:cellHeight:...)`
  (`Sources/LabanCore/AppModel.swift:1546`) computes rows/cols by integer
  division and calls `Session.resize` for every session, which reaches
  `laban_session_resize` (`Sources/LabanTerminalCore/session_lifecycle.c:765`):
  `ghostty_terminal_resize(terminal, cols, rows, cell_width, cell_height)`
  reflows the grid, then `ioctl(pty_fd, TIOCSWINSZ, ...)` notifies the child
  process (this is what delivers SIGWINCH). **Font zoom needs no new code
  here** — cell pixel dimensions are already first-class parameters.
- **Menus** — `Sources/LabanApp/MenuCommands.swift` builds the main menu in
  code; the View menu exists (line ~160, currently only "Enter Full
  Screen"). Menu items target `@objc` methods on `TerminalBitmapView` via
  the responder chain (see "Select Last Tab" → `selectLastTab(_:)` for the
  pattern).
- **Headless harness** — `Sources/LabanDebug/HeadlessDebugRuntime.swift`
  drives the same `AppModel`/`TerminalSurfaceController` stack without
  AppKit, using `SoftwareRenderer`, behind an HTTP debug server
  (`Sources/LabanDebug/DebugHTTPServer.swift`, actions dispatched via
  `DebugRuntimeRequests.swift` / `DebugWindowActions.swift`, discoverable at
  `/debug/actions`). It currently **hardcodes** `FontAtlas(pointSize: 14)`
  (line ~148). AGENTS.md requires feature parity between this runtime and
  the real window. Schemas for debug payloads live in `schemas/debug/`.
- **Regression contract** — `docs/product/mvp.md` requires that terminal
  session identity survives resize and UI refresh. Font zoom is a resize
  variant: sessions must keep their PTYs, scrollback, and tab identity
  through a zoom step.

Term used throughout: **atlas ladder** — a precomputed map from integer point
size (8…40) to a ready-to-use bundle of {terminal `FontAtlas`, sidebar
`FontAtlas`, terminal `MetalGlyphAtlas`, sidebar `MetalGlyphAtlas`}, with the
printable ASCII range (U+0020…U+007E) already rasterized into the textures
("prewarmed"), built on a background queue shortly after the first frame.

## Plan of Work

### Milestone 1 — live zoom mechanics (no ladder yet)

Scope: everything needed for Cmd+= / Cmd+- / Cmd+0 to work correctly, with
the atlas for the new size built synchronously on the spot (a few ms — fast,
correct, but not yet "super fast"). This isolates the risky plumbing
(mutability, invalidation, resize orchestration) from the performance work
and is independently shippable.

1. **`FontAtlas` zoom constants** (`Sources/LabanRenderer/FontAtlas.swift`):
   add `static let zoomMinimumPointSize: CGFloat = 8`,
   `zoomMaximumPointSize: CGFloat = 40`, and
   `static func clampedZoomPointSize(_ size: CGFloat) -> CGFloat` (round to
   nearest integer, clamp to range). Existing default stays 14.
2. **Renderer reconfigure API**: add to `MetalRenderer` a method

       func reconfigureFonts(
         fontAtlas: FontAtlas,
         sidebarFontAtlas: FontAtlas,
         prebuiltTerminalAtlas: MetalGlyphAtlas? = nil,
         prebuiltSidebarAtlas: MetalGlyphAtlas? = nil)

   modeled on the scale-change branch of `resize` (~line 852): replace both
   `MetalGlyphAtlas` instances (use the prebuilt ones when supplied,
   otherwise construct fresh ones from the new metrics), update
   `glyphCellAdvance/glyphCellHeight/sidebarCellAdvance/sidebarCellHeight`
   and the stored `fontAtlas`/`sidebarFontAtlas` references, bump
   `scalarEntryCacheGeneration`, clear `cellGlyphs`,
   `cellGlyphGridGeometry`, glyph upload state, and force a full-target
   redraw. For `SoftwareBackend`, recreate the `SoftwareRenderer` with the
   new `FontAtlas` (mirroring what `applyRendererSelection` already does
   when switching renderers).
3. **Surface controller update**: add
   `TerminalSurfaceController.updateCellMetrics(cellWidth:cellHeight:sidebarCellWidth:sidebarCellHeight:)`
   so per-frame producers pick up the new geometry.
4. **View orchestration**: in `TerminalBitmapView`, change `fontAtlas`,
   `sidebarFontAtlas`, `cellWidth`, `cellHeight`, `sidebarCellWidth`,
   `sidebarCellHeight` from `let` to `private(set) var`, and add
   `func applyFontSize(_ requested: CGFloat)`:
   - clamp via `FontAtlas.clampedZoomPointSize`; no-op if equal to current;
   - build the new terminal and sidebar `FontAtlas` (ladder lookup in M2;
     direct construction in M1) and integer cell metrics;
   - call the renderer reconfigure (step 2) and surface-controller update
     (step 3);
   - call `model.resize` with the **unchanged** viewport pixels and the new
     cell dimensions (this renegotiates cols/rows and fires TIOCSWINSZ for
     every session — the inverse of a window resize, where cell size is
     fixed and viewport changes);
   - run the same interaction invalidation `setFrameSize` performs when the
     column count changes: clear selection state, update `lastAppliedCols`,
     trigger a find rescan;
   - persist to UserDefaults (`FontAtlas.userFontSizeKey`) and post
     `FontAtlas.didChangeNotification`;
   - render one frame synchronously (`waitForFrameCompletion = true`, the
     live-resize pattern) so no frame ever mixes old atlas with new grid.
5. **Keyboard + commands**: extend `AppCommand`
   (`Sources/LabanApp/TerminalInputView.swift:7`) with `increaseFontSize`,
   `decreaseFontSize`, `resetFontSize`; map in `routeCommand()`:
   `.equal` → increase (covers Cmd+= and Cmd+Shift+=), `.minus` → decrease,
   `.digit0` → reset. Handle the new cases in
   `TerminalBitmapView.executeAppCommand` by calling `applyFontSize` with
   current+1, current−1, and `FontAtlas.defaultTerminalPointSize`. Add the
   three cases to `TerminalInputCaptureMetadata.swift` (capture names:
   `increaseFontSize`, `decreaseFontSize`, `resetFontSize`).
6. **Menu items** (`Sources/LabanApp/MenuCommands.swift`, View menu): add
   "Bigger Text" (key equivalent `=`, Cmd), "Smaller Text" (`-`, Cmd),
   "Default Text Size" (`0`, Cmd), targeting new `@objc` wrappers on
   `TerminalBitmapView` (pattern: `selectLastTab(_:)` at ~line 5640).
7. **Settings live-apply**: in `TerminalBitmapView`, observe
   `FontAtlas.didChangeNotification`; on fire, read the persisted font name
   and size — if the name matches the current font, call
   `applyFontSize(persistedSize)`; if the name changed, do nothing (restart
   still required). In `AppDelegate.changeFont`
   (`Sources/LabanApp/AppDelegate.swift:294`), only show the restart alert
   when the family changed.

Milestone 1 acceptance: in a running app, Cmd+- twice then `tput cols` shows
more columns than before; Cmd+0 restores; quit/relaunch keeps the size;
selection made before zooming is gone after (grid coordinates are invalid
after reflow, matching window-resize behavior).

### Milestone 2 — the prebuilt atlas ladder (performance)

Scope: eliminate all rasterization and atlas-construction work from the zoom
step for ladder sizes. New file
`Sources/LabanRenderer/GlyphAtlasLadder.swift`:

    public final class GlyphAtlasLadder {
      public struct Entry {
        public let fontAtlas: FontAtlas          // terminal metrics
        public let sidebarFontAtlas: FontAtlas   // terminal × 11/14
        public let terminalAtlas: MetalGlyphAtlas
        public let sidebarAtlas: MetalGlyphAtlas
      }
      public init(device: MTLDevice, scale: CGFloat, fontName: String?)
      public func beginPrebuild(excluding activeSize: Int)  // background queue
      public func entry(forPointSize: Int) -> Entry?        // nil until built
      public var totalTextureBytes: Int { get }
    }

Behavior:

1. `beginPrebuild` walks sizes 8…40 (skipping the active size, which already
   has a live atlas) on a `DispatchQueue(label:"laban.atlas-ladder",
   qos:.utility)`. For each size: build both `FontAtlas` instances, compute
   cell metrics, choose a texture size (smallest of 512/1024/2048 whose area
   is ≥ 3× the estimated prewarm area — 95 glyphs × cellW×scale ×
   cellH×scale; the existing overflow-grow path covers underestimates), and
   construct both `MetalGlyphAtlas` instances. **Prewarm** by requesting
   `entry(scalar:font:)` for every scalar in U+0020…U+007E on both atlases.
   Publish the finished `Entry` into a lock-protected dictionary. CPU-side
   CoreText drawing and `MTLTexture.replaceRegion` uploads are safe off-main
   for textures no renderer references yet.
2. Rebuild on backing-scale change: the view already detects scale changes
   in `setFrameSize`/`recreateSurface`; on a scale change, discard the
   ladder and `beginPrebuild` again for the new scale (the active size is
   rebuilt synchronously by the existing scale-change branch, as today).
3. `TerminalBitmapView` owns the ladder, creates it after the first frame
   (defer with `DispatchQueue.main.async` from `viewDidMoveToWindow` or the
   first `advanceFrame`) using the renderer's `MTLDevice`
   (`MTLCreateSystemDefaultDevice()` when on the software backend — the
   ladder still serves `FontAtlas` metrics there; GPU atlases are simply
   unused). `applyFontSize` consults `ladder.entry(forPointSize:)` and
   passes the prebuilt atlases to `reconfigureFonts`; on a miss (prebuild
   not finished yet, or fractional legacy size), it falls back to the M1
   synchronous build — correctness never depends on the ladder.
4. **Observability**: add `private(set) var rasterizedGlyphCount: Int` to
   `MetalGlyphAtlas`, incremented in `rasterizeAndPack`. Log one line at
   prebuild completion: `atlas-ladder: built N sizes in T ms, M MB`. This is
   the hook both the perf test and the Review Gate use.

Milestone 2 acceptance: after prebuild completes, a zoom step performs zero
rasterization (`rasterizedGlyphCount` of the incoming atlas unchanged by the
swap; only genuinely new non-ASCII glyphs rasterize later), and the ladder's
`totalTextureBytes` ≤ 48 MB at 2× scale.

### Milestone 3 — headless parity, schemas, tests

1. `HeadlessDebugRuntime` reads `FontAtlas.persistedTerminalPointSize`
   instead of hardcoding 14 (tests that rely on 14 must set the default
   explicitly or be verified unaffected — UserDefaults in test runners is
   clean by default).
2. New debug action `setFontSize` (`{"action":"setFontSize","pointSize":16}`):
   add a request type in `DebugRuntimeRequests.swift`, dispatch in
   `DebugWindowActions.swift` (pattern: `resizeWindow`), implement on the
   runtime: new `FontAtlas` pair, update `cellWidth/cellHeight`, recreate
   `SoftwareRenderer`, update the surface controller, call `model.resize`
   with unchanged viewport pixels. Register in
   `DebugDiscoveryEndpoints.swift`; update `schemas/debug/action.schema.json`
   (and the discovery list) accordingly.
3. Tests (see Validation). Update `docs/process/dev-process.md` only if it
   enumerates debug actions (check; add `setFontSize` to any such list).

## Concrete Steps

All commands run from the repository root `/Users/rrj/wrk/laban`.

1. Build and test cycle used throughout:

       ./scripts/build-app            # assembles .build/laban/Laban.app
       swift test --filter LabanRendererTests
       swift test --filter LabanAppTests
       swift test --filter LabanDebugTests

2. Implement M1 (edits listed above), then verify by hand: launch the built
   app (quit any running Laban first — single-instance lock; never `open`
   the bundle from a shell, launch via Finder/Dock), run `tput cols` in the
   shell, press Cmd+- twice, run `tput cols` again — expect a larger number.
   Press Cmd+0 — expect the original. Quit, relaunch, confirm the size
   stuck.
3. Implement M2; confirm the prebuild log line appears shortly after launch:

       atlas-ladder: built 32 sizes in <T> ms, <M> MB

   with M ≤ 48.
4. Implement M3; verify headless (binary path may differ; `laband`/debug
   server startup is described in `docs/process/dev-process.md`):

       curl -s localhost:<debugport>/debug/actions \
         -d '{"action":"setFontSize","pointSize":20}'
       curl -s localhost:<debugport>/debug/atlas | jq .fontSize   # → 20

5. Run the full test suite and fix fallout (capture metadata enums and
   replay fixtures are the likely places).

## Validation and Acceptance

Automated:

- `Tests/LabanRendererTests/GlyphAtlasLadderTests.swift` (new; skip when
  `MTLCreateSystemDefaultDevice()` is nil, following
  `MetalRendererSmokeTests.swift`):
  - building a ladder entry for size 16 yields cell metrics equal to
    `FontAtlas(pointSize: 16).cellSize` rounded up;
  - after prewarm, requesting every ASCII scalar entry leaves
    `rasterizedGlyphCount` unchanged (everything was already rasterized);
  - `totalTextureBytes` for the full 8…40 ladder at scale 2 is ≤ 48 MB.
- `Tests/LabanRendererTests/MetalRendererSmokeTests.swift`: extend with a
  `reconfigureFonts` test — render a frame at 14 pt, reconfigure to 20 pt,
  render again; expect no crash, new `glyphCellAdvance` matches the 20 pt
  `FontAtlas`, and a forced full redraw occurred.
- Input routing unit test (alongside existing `TerminalInputView` tests in
  `Tests/LabanAppTests`): Cmd+`=`/`-`/`0` descriptors route to the three new
  `AppCommand` cases; Cmd+9 still routes to `selectLastTab`.
- `Tests/LabanDebugTests`: `setFontSize` action returns success, and a
  subsequent `/debug/atlas` reports the new `fontSize` while `/debug` state
  shows a column count consistent with `viewportWidth / newCellWidth`.

Behavioral (manual or scripted via headless harness):

- Zoom in (Cmd+=) from 14→20 in a window showing `vim`: text grows, vim
  redraws to fewer columns/rows without artifacts; session identity (tab,
  scrollback, running process) is preserved — this is the `docs/product/mvp.md`
  regression bar.
- Performance: with the ladder built, hold Cmd+= from 8 to 40; every step
  renders within one frame budget. Evidence: prebuild log line plus the
  ladder test asserting zero rasterization on swap; optionally an
  Instruments capture per `docs/process/dev-process.md` §Metal Trace Perf
  Loop if regressions are suspected.

## Idempotence and Recovery

Every step is additive and re-runnable; `applyFontSize` no-ops when the
clamped size equals the current size. If prebuild is interrupted or slow,
zoom still works via the M1 synchronous fallback — the ladder is purely an
accelerator. To reset state during testing:
`defaults delete <bundle-id> LabanFontSize`. If a zoom step ever renders a
corrupt frame, the synchronous-frame ordering in `applyFontSize` (reconfigure
→ resize → waited frame) is the first suspect: verify no async frame can
interleave between atlas swap and grid resize.

## Interfaces and Dependencies

- No new external dependencies. CoreText (`CTFontDrawGlyphs`) and Metal
  (`MTLTexture.replaceRegion`) are already in use.
- New public surface in `LabanRenderer`: `GlyphAtlasLadder` (+ `Entry`),
  `MetalRenderer.reconfigureFonts(...)`,
  `MetalGlyphAtlas.rasterizedGlyphCount`, `MetalGlyphAtlas.prewarmASCII(font:)`,
  `FontAtlas.clampedZoomPointSize(_:)` and the zoom min/max constants.
- New `LabanCore` surface: `TerminalSurfaceController.updateCellMetrics(...)`.
- New `AppCommand` cases: `increaseFontSize`, `decreaseFontSize`,
  `resetFontSize`.
- New debug action: `setFontSize` (schema in `schemas/debug/action.schema.json`).
- Memory budget: ladder ≤ 48 MB of `r8Unorm` textures at 2× scale (33 sizes;
  estimate: sizes ≤16 fit 512² = 0.25 MB, mid sizes 1024² = 1 MB, largest
  sizes at most 2048² = 4 MB). `totalTextureBytes` is the measured truth;
  if the budget is exceeded, shrink per-size textures, not the range.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete.

- [ ] `rg "FontAtlas\(pointSize: 14\)" Sources/LabanDebug/HeadlessDebugRuntime.swift`
      returns no matches (persisted size is read instead).
- [ ] `rg "increaseFontSize|decreaseFontSize|resetFontSize" Sources/LabanApp/TerminalInputView.swift`
      shows all three as `AppCommand` cases and all three mapped in
      `routeCommand()`.
- [ ] `swift test --filter GlyphAtlasLadderTests` exits 0 (or reports the
      documented Metal-unavailable skip).
- [ ] `swift test --filter MetalRendererSmokeTests` exits 0.
- [ ] Start the headless harness; POST
      `{"action":"setFontSize","pointSize":20}` to `/debug/actions`; GET
      `/debug/atlas`; expect `fontSize` 20 and a smaller column count than
      before the POST.
- [ ] `rg "Bigger Text" Sources/LabanApp/MenuCommands.swift` returns a match
      in the View menu construction.
- [ ] The prebuild completion log line reports total texture memory ≤ 48 MB.
- [ ] `git log --oneline` for this work shows single-line reason-statement
      messages per AGENTS.md.

Review status: NOT REVIEWED
