# Continuous pinch-zoom: smooth fractional font scaling on the vector renderer

This ExecPlan is a living document maintained in accordance with `PLANS.md` at the
repository root. Keep `Progress` and `Validation and Acceptance` current as work
proceeds. Add optional sections only when they hold information a fresh contributor
needs.

## Purpose / Big Picture

Today Laban (a macOS terminal app) changes its font size only in **whole-point
steps**: Cmd+= grows the text by one point, Cmd+- shrinks it by one, Cmd+0 returns
to 14 pt. There is no trackpad pinch gesture, and every size is an integer point
size because the classic GPU renderer prebuilds a fixed "ladder" of glyph atlases
(one per integer size 8…40).

After this change, a **two-finger pinch on the trackpad smoothly scales the
terminal text** when the **vector glyph renderer** is the active backend. "Smoothly"
means the size tracks the gesture at *fractional* point sizes (e.g. 14.0 → 17.3 →
21.8 pt), not snapping to whole points, because the vector renderer rasterizes
glyph outlines on the GPU at any size on demand — it needs no prebuilt atlas. The
grid (how many columns and rows fit the window) re-fits as the cells grow or
shrink, exactly like a live window resize: running programs receive a window-size
change (the Unix `SIGWINCH` signal) and reflow their output. When the fingers
lift, the final size persists across restarts.

What someone gains: pinch-to-zoom that feels like a native high-end canvas — read
a dense log at 9 pt, then pinch up to 30 pt for a screen-share — with text that
stays crisp at every intermediate size because it is drawn from curves, not scaled
from a bitmap.

How to see it working: build and install (`./scripts/build-app && ./scripts/install-app`),
switch the renderer to "Vector glyph" (Renderer menu), then pinch open/closed on
the trackpad over the terminal. Text should scale continuously and smoothly, the
column/row count should re-fit as you zoom, and releasing should leave the new size
in place (and still there after relaunch). Autonomous gates (XCTest + a headless
HTTP debug route) prove the size-mapping math and the end-to-end size/grid change
without a human hand on the trackpad.

## Scope and non-goals

- **In scope:** a trackpad magnify (pinch) gesture handler; mapping the gesture's
  accumulated magnification to a fractional target point size; applying fractional
  sizes through the **vector** backend live; re-fitting the grid only when the
  integer column/row count actually changes (so `SIGWINCH` is not spammed every
  gesture frame); committing/persisting the size on gesture end; autonomous gates.
- **Non-goals:** changing the **classic** (`MetalRenderer`) or **software**
  backends to render fractional sizes — they keep their integer ladder, so a pinch
  while those backends are active rounds to the nearest whole point (still smooth
  enough, but stepped). "Semantic zoom" (zooming a region, minimaps, presentation
  mode) is a separate future direction, not this plan. Pinch-zoom of images or UI
  chrome is out of scope.

## Context and Orientation

A reader who knows nothing about this repo needs these facts. All paths are
repository-relative from the repo root (`/Users/rrj/wrk/laban`).

### Terms

- **Backend / renderer:** the object that turns a terminal snapshot into pixels.
  Three exist, all conforming to the protocol in
  `Sources/LabanRenderer/RendererBackend.swift`: `MetalRenderer` (the "classic" GPU
  renderer, command and gpu-driven modes), `VectorGlyphRenderer` (the GPU vector
  outline renderer this plan targets), and `SoftwareBackend` (CPU fallback). The
  active backend is the property `backend` on the view
  `Sources/LabanApp/TerminalBitmapView.swift`.
- **FontAtlas:** `Sources/LabanRenderer/FontAtlas.swift` — wraps a CoreText font at
  a specific `pointSize` and exposes cell metrics (`cellSize`, `ascent`, `descent`).
  It already supports arbitrary sizes via `withPointSize(_:)` (returns a new atlas
  at that size) and `init(pointSize:fontName:)`. Two static bounds matter:
  `zoomMinimumPointSize = 8` and `zoomMaximumPointSize = 40`. The helper
  `clampedZoomPointSize(_:)` currently **rounds to the nearest integer** and clamps
  into [8, 40]. Integer-only is a constraint of the *classic* renderer's prebuilt
  atlas ladder, **not** of the vector renderer.
- **Atlas ladder:** `Sources/LabanRenderer/GlyphAtlasLadder.swift` — a prebuilt
  collection of glyph atlases, one per integer point size, used by the classic
  renderer so a zoom step is a pointer swap with zero rasterization. The vector
  renderer does **not** use the ladder; it bakes glyph masks on demand at whatever
  size it is given (this is the whole point of the vector backend).
- **Live font zoom (existing):** `TerminalBitmapView.applyFontSize(_ requested:)`
  (around line 3681) is the existing whole-point zoom. It clamps the requested
  size, swaps the `FontAtlas` (ladder entry for classic, `withPointSize` otherwise),
  recomputes cell metrics, tells the active backend to reconfigure fonts, then
  **renegotiates the grid**: it computes `cols`/`rows` from the unchanged viewport
  pixels and the new cell size and calls `model.resize(...)` +
  `sessionCoordinator?.resize(...)`, which is the same path a window resize uses and
  which delivers `SIGWINCH` to the shell. It persists the size to `UserDefaults`
  under `FontAtlas.userFontSizeKey` (a `Double`, so fractional sizes already
  persist) and posts `FontAtlas.didChangeNotification`. It is called today from the
  keyboard handlers (`applyFontSize(fontAtlas.pointSize + 1)` etc., near lines 4081
  and 6269) and the View menu actions (near line 6269).
- **SIGWINCH:** the Unix signal a process receives when its controlling terminal's
  window size changes. In this app it is delivered by `model.resize` /
  `sessionCoordinator.resize` setting the pseudo-terminal (PTY) window size. Running
  programs (shells, `vim`, `top`) reflow when they get it. Sending it on every
  gesture frame would make TUI apps reflow dozens of times a second, which is why
  this plan re-fits the grid only when the integer `cols`/`rows` actually change.
- **magnify(with:):** the AppKit `NSView` callback for a trackpad pinch. The event's
  `magnification` is a *delta* per event (a small signed number, e.g. +0.02); summed
  over a gesture it gives the total relative scale change. There is **no** magnify
  handler in the codebase today (`grep -rn 'func magnify' Sources` returns nothing).
- **Debug control plane:** `Sources/LabanApp/ScrollDebugServer.swift` is a loopback
  HTTP server (enabled by launching with `--scroll-debug`) used for autonomous
  testing. It already routes things like `/scroll/smooth` and `/config/renderer`.
  This plan adds routes to drive and observe zoom without a human gesture. The
  process/agent harness is described in `docs/process/dev-process.md`.

### Key files this plan touches

- `Sources/LabanRenderer/FontAtlas.swift` — add a fractional-clamp helper alongside
  the existing integer `clampedZoomPointSize`.
- `Sources/LabanApp/TerminalBitmapView.swift` — add the `magnify(with:)` handler,
  a magnification accumulator, a fractional-aware apply path, and grid-reflow
  throttling; reuse `applyFontSize`'s reconfigure/reflow/persist logic.
- `Sources/LabanApp/ScrollDebugServer.swift` — add HTTP routes to drive a synthetic
  pinch and read back the effective point size + grid metrics.
- `Tests/LabanRendererTests/` and/or `Tests/LabanAppTests/` — new gates.

## Design decisions (made here, not left to the reader)

1. **Fractional sizes are vector-only.** When `backend is VectorGlyphRenderer`, a
   pinch applies the *fractional* target size directly. For any other backend, the
   target is rounded to the nearest integer point before applying (they need an
   integer ladder atlas; a fractional size would force a synchronous rebuild every
   frame and still look stepped). This keeps the classic/software paths byte-for-byte
   unchanged and confines all new behavior to the vector backend, matching the
   project's "vector backend may depart; classic stays as shipped" stance.

2. **Magnification → size is multiplicative.** A pinch scales relative size, so the
   target point size is `basePointSize * (1 + accumulatedMagnification)`, clamped to
   [8, 40]. `basePointSize` is the size when the gesture began (captured on the first
   magnify event of a gesture). Multiplicative tracking matches how pinch feels on
   every other macOS app (a given finger spread is the same *ratio* regardless of
   starting size).

3. **Reflow only on integer grid-boundary crossings.** The cell size changes
   continuously, but `cols = termWidthPx / cellWidthPx` and `rows = termHeightPx /
   cellHeightPx` are integers that change only at discrete sizes. The apply path
   recomputes `cols`/`rows` every gesture frame but calls `model.resize` /
   `sessionCoordinator.resize` (the `SIGWINCH`-bearing step) **only when `cols` or
   `rows` differ from the last applied values**. Between crossings it just swaps the
   atlas and redraws. This bounds `SIGWINCH` to the number of column/row boundaries
   the gesture sweeps (a 14→28 pt pinch crosses on the order of ten), which is the
   honest, correct terminal behavior for a live resize.

4. **Persist on gesture end, not per frame.** The live gesture updates the atlas and
   grid in memory; the size is written to `UserDefaults` and
   `FontAtlas.didChangeNotification` is posted once, when the gesture ends
   (`NSEvent.Phase.ended`/`.cancelled`). This avoids hammering `UserDefaults` and the
   notification observers dozens of times a second.

5. **The size-mapping math is a pure, testable function.** A free function maps
   `(basePointSize, accumulatedMagnification, isVector)` to a final point size
   (fractional for vector, rounded otherwise, always clamped). It has no UIKit/AppKit
   dependency so it is unit-testable headlessly and is the same function the gesture
   handler and the debug route call.

## Milestones

### M1 — Fractional vector sizing + the pinch gesture (the core)

Scope: make a trackpad pinch scale the vector renderer's text at fractional point
sizes, live.

What will exist that didn't: a `magnify(with:)` handler on `TerminalBitmapView`; a
magnification accumulator and captured base size; a pure size-mapping function; and
a fractional-aware apply path that reuses `applyFontSize`'s reconfigure/reflow/persist
work but does not force integer rounding for the vector backend.

Approach:
- Add to `FontAtlas` a fractional clamp:
  `clampedFractionalZoomPointSize(_ size: CGFloat) -> CGFloat` that clamps to
  `[zoomMinimumPointSize, zoomMaximumPointSize]` **without rounding**. Leave the
  existing integer `clampedZoomPointSize` untouched (classic path still uses it).
- Add a pure mapping function (free function or static on the view, in
  `TerminalBitmapView.swift`):
  ```swift
  static func zoomPointSize(
    base: CGFloat, accumulatedMagnification: CGFloat, fractional: Bool) -> CGFloat
  ```
  returning `FontAtlas.clampedFractionalZoomPointSize(base * (1 + accumulatedMagnification))`
  when `fractional`, else `FontAtlas.clampedZoomPointSize(base * (1 + accumulatedMagnification))`.
- Add gesture state to the view: `private var pinchBasePointSize: CGFloat?` and
  `private var pinchAccumulatedMagnification: CGFloat = 0`.
- Implement `override func magnify(with event: NSEvent)`:
  - On `event.phase == .began` (or first event where `pinchBasePointSize == nil`):
    set `pinchBasePointSize = fontAtlas.pointSize`, `pinchAccumulatedMagnification = 0`.
  - Always: `pinchAccumulatedMagnification += event.magnification`; compute
    `let fractional = backend is VectorGlyphRenderer`; compute target via
    `Self.zoomPointSize(base: pinchBasePointSize!, accumulatedMagnification: pinchAccumulatedMagnification, fractional: fractional)`;
    call the apply path with `persist: false`.
  - On `event.phase == .ended || .cancelled`: call the apply path once more with
    `persist: true`, then clear `pinchBasePointSize`.
- Refactor `applyFontSize` minimally so the live path can reuse it without
  persisting every frame. Either add a parameter
  `applyFontSize(_ requested: CGFloat, quantize: Bool = true, persist: Bool = true)`
  or extract the reconfigure+reflow body into a private helper that both the keyboard
  path (quantize+persist) and the pinch path (vector: no quantize; persist only on
  end) call. When `quantize` is true, use `clampedZoomPointSize` (integer); when
  false, use `clampedFractionalZoomPointSize`. When `persist` is false, skip the
  `UserDefaults.set` and the `didChangeNotification` post. **Keep the keyboard/menu
  callers on `quantize: true, persist: true` so their behavior is byte-identical.**

Acceptance (autonomous):
- New unit test for `zoomPointSize`: at `base = 14`, `accumulatedMagnification = 0.25`,
  `fractional = true` → `17.5` exactly (within 1e-9); with `fractional = false` →
  `18.0` (rounded). Clamps: a huge positive accumulation → `40`; a large negative →
  `8`. Monotonic in the accumulator.
- `swift test --filter VectorGlyph` and the existing zoom tests stay green (the
  keyboard/menu path is unchanged).
- Manual (recorded as an artifact): pinch over the vector backend scales text
  smoothly and fractionally; over the classic backend it steps by whole points.

### M2 — Reflow throttling (don't spam SIGWINCH)

Scope: ensure the grid renegotiation (the `SIGWINCH`-bearing `model.resize` /
`sessionCoordinator.resize`) fires only when the integer `cols`/`rows` actually
change during a continuous gesture, not every gesture frame.

What will exist that didn't: the apply path computes `cols`/`rows` and short-circuits
the resize call when they equal the last applied values; only the atlas swap + redraw
happen on a no-grid-change frame.

Approach:
- In the apply path (shared helper from M1), after computing `cols`/`rows` from the
  unchanged viewport pixels and new cell size, compare against `lastAppliedCols` /
  `lastAppliedRows` (already tracked by `applyFontSize`). Call `model.resize` +
  `sessionCoordinator?.resize` **only** when they differ. Always swap the atlas,
  update cell metrics on the backend, and request a redraw.
- Keep the synchronous "one frame so no present mixes old atlas + new grid" behavior
  (the `renderingResizeFrame` path) for frames that *do* reflow; a pure atlas-swap
  frame still needs a redraw but not a forced full grid reconcile.

Acceptance (autonomous):
- A headless test (via the M3 debug route or a direct view-method test) drives a
  monotonic pinch from 14 → 28 pt in many small steps and asserts the number of
  grid renegotiations equals the number of distinct `(cols, rows)` pairs crossed,
  **not** the number of steps. (Count resize calls via a test seam / counter on the
  model or coordinator, or by observing `cols`/`rows` change events.)

### M3 — Headless drive + observe (autonomous verification)

Scope: make pinch-zoom mechanically verifiable without a trackpad, per the project's
autonomous-verification rule.

What will exist that didn't: HTTP debug routes to (a) drive a synthetic pinch by an
accumulated magnification and (b) read back the effective point size and grid metrics.

Approach:
- In `Sources/LabanApp/ScrollDebugServer.swift`, add:
  - `POST /zoom/pinch?magnification=<delta>&phase=<began|changed|ended>` — feeds the
    same accumulator/apply path the real `magnify(with:)` uses (factor the gesture
    body into a method like `debugApplyPinch(magnification:phase:)` on the view so the
    route and the gesture share one implementation).
  - Extend an existing debug-state route (or add `GET /zoom/state`) to report
    `effectivePointSize` (the live `fontAtlas.pointSize`, fractional for vector),
    `cols`, `rows`, and `backend` (effective renderer name).
- Document the routes in `docs/process/dev-process.md` (where the other debug routes
  are listed).

Acceptance (autonomous + observable):
- Headless via `laban-agent`/`--scroll-debug`: select the vector renderer
  (`POST /config/renderer?name=vectorGlyph`), then `POST /zoom/pinch` a sequence and
  assert `GET /zoom/state` reports a **fractional** `effectivePointSize` (e.g.
  17.5) and updated `cols`/`rows`, and a `phase=ended` call persists it (a
  subsequent `GET` after a simulated relaunch, or reading `UserDefaults`, shows the
  size). Repeat with `name=classic` and assert `effectivePointSize` is an integer.
- A screenshot at a fractional size renders without crashing and shows visibly
  larger text than at base.

## Progress

- [x] M1 — fractional vector sizing + pinch gesture (pure `zoomPointSize` fn,
  `magnify(with:)` handler, fractional clamp, shared apply helper with
  `quantize`/`persist` flags; keyboard/menu path byte-identical). Also added a
  laptop-friendly **Cmd+scroll** zoom (`handleZoomScroll`) sharing the same
  `applyZoomMagnification` driver, since pinch is awkward on a built-in trackpad.
- [x] M2 — reflow throttling (grid renegotiation only on `cols`/`rows` change),
  via `applyFontSize(throttleReflow:)` and the `debugGridReflowCount` seam.
- [x] M3 — headless drive/observe debug routes (`POST /zoom/pinch`,
  `GET /zoom/state` in `ScrollDebugServer`, sharing `debugApplyPinch`) + gates
  (`ContinuousZoomTests`); dev-process.md updated.

## Decision Log

- Decision: Fractional point sizes are applied only when the vector renderer is
  active; other backends round to integer.
  Rationale: the vector renderer rasterizes from curves at any size with no ladder,
  so fractional is free and looks crisp; the classic/software backends depend on a
  prebuilt integer-size atlas ladder, where a fractional size would force a
  per-frame synchronous rebuild and still look stepped. Confining fractional to
  vector keeps the shipped classic path unchanged.
  Date/Author: 2026-06-28 / initial plan.
- Decision: The grid is renegotiated (SIGWINCH delivered) only when the integer
  `cols`/`rows` change, not every gesture frame.
  Rationale: continuous per-frame `SIGWINCH` would make TUI apps reflow dozens of
  times a second; grid boundaries are discrete, so reflowing on crossings is both
  correct (matches live window resize) and bounded.
  Date/Author: 2026-06-28 / initial plan.
- Decision: Size persists once on gesture end, not per frame.
  Rationale: avoid hammering UserDefaults and `didChangeNotification` observers;
  the in-memory atlas/grid already reflect the live size during the gesture.
  Date/Author: 2026-06-28 / initial plan.
- Decision: Add Cmd+scroll as a second zoom gesture alongside trackpad pinch.
  Rationale: pinch is awkward on a laptop's built-in trackpad; Cmd+scroll
  (hold Cmd, two-finger scroll) is easy on any trackpad and reuses the exact
  fractional apply path. Cmd (not Ctrl) avoids the macOS accessibility
  Ctrl+scroll screen-zoom. Both gestures feed one `applyZoomMagnification`
  driver, so the accumulate/throttle/persist behavior is identical.
  Date/Author: 2026-06-29 / user request during M1.

## Validation and Acceptance

Baseline commands (run from the repo root, `/Users/rrj/wrk/laban`):

- `swift test --filter VectorGlyph` — vector backend stays green.
- `swift test --filter Zoom` (or the new test's filter) — the new `zoomPointSize`
  and throttling gates fail before the change and pass after.
- `./scripts/build-app && ./scripts/install-app` — bundle builds, installs; quit &
  relaunch Laban, switch to the vector renderer, pinch to confirm smooth fractional
  scaling, then relaunch to confirm the size persisted.
- Headless per `docs/process/dev-process.md`: `--scroll-debug`, then `POST /zoom/pinch`
  + `GET /zoom/state` to confirm fractional sizing (vector) vs integer (classic) and
  grid re-fit, plus a `/debug/screenshot` at a fractional size.

A milestone is done only when its new test(s) fail before the change and pass after,
and the baseline filters stay green.

## Idempotence and Recovery

All steps are additive. The font-size persistence key (`FontAtlas.userFontSizeKey`)
is already a `Double`, so a persisted fractional size round-trips with no migration.
If a fractional size is later loaded under a non-vector backend, the existing apply
path (`clampedZoomPointSize`) rounds it to the ladder grid on first use, so there is
no broken state. Reverting this plan's commits restores whole-point zoom; earlier
behavior is unaffected because the keyboard/menu path is kept byte-identical.

## Interfaces and Dependencies

Must exist at completion:
- `FontAtlas.clampedFractionalZoomPointSize(_:) -> CGFloat` (clamp, no rounding),
  alongside the unchanged `clampedZoomPointSize`.
- `TerminalBitmapView.zoomPointSize(base:accumulatedMagnification:fractional:) -> CGFloat`
  (pure, testable).
- `TerminalBitmapView.magnify(with:)` plus the shared apply helper accepting
  `quantize` and `persist` flags; the keyboard/menu callers remain
  `quantize: true, persist: true`.
- `ScrollDebugServer` routes `POST /zoom/pinch` and `GET /zoom/state`, sharing the
  gesture body via a `debugApplyPinch(...)` view method.
