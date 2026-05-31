# Make AppKit Text Rendering Backing-Scale Crisp

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then implement the display-scale fix without relying on prior
conversation.

## Purpose / Big Picture

Laban currently renders terminal text into a CPU bitmap and asks AppKit to show
that bitmap in the window. The window is visible and correctly oriented, but
text can look soft on Retina displays because the AppKit view is sized in
logical points while the bitmap is allocated at that same number of pixels.
On a 2x display, one bitmap pixel is stretched across two backing pixels.

After this change, the AppKit path renders into a bitmap whose pixel dimensions
match the view's actual backing-store dimensions. Terminal layout remains in
logical points, so tab/sidebar layout and terminal rows/columns do not change.
The visible result is the same terminal content, but rasterized at the display's
native pixel density. This should happen before the debug server work so future
`/debug/screenshot` and render-state endpoints describe the final scale model.

## Progress

- [x] (2026-05-03) Identified that
  `Sources/LabanApp/TerminalBitmapView.swift` reallocates `BitmapSurface` from
  `NSView` bounds in logical points, not backing pixels.
- [x] (2026-05-03) Chose to do backing-scale correctness before debug-server
  screenshot endpoints, so screenshots and render probes do not bake in the
  wrong raster model.
- [x] (2026-05-03) Add scale-aware bitmap surface allocation and renderer
  transforms (`BitmapSurface.scale`, `logicalWidth/Height/Size` helpers;
  `SoftwareRenderer.render` applies `ctx.scaleBy` around command loop).
- [x] (2026-05-03) Update AppKit surface ownership so resize and
  backing-scale changes recreate the surface at physical pixel dimensions
  (`TerminalBitmapView.recreateSurface()` called from `viewDidMoveToWindow`,
  `setFrameSize`, `viewDidChangeBackingProperties`; `MainWindowController`
  no longer creates a surface).
- [x] (2026-05-03) Headless fixture rendering stays at scale 1 — all
  existing callers use `BitmapSurface(width:height:)` with the default.
- [x] (2026-05-03) Renderer tests added: `testBitmapSurfaceLogicalSizeHelpers`,
  `testScaledRectPaintsCorrectPhysicalPixels`, `testScaledGlyphProducesNonBackgroundPixels`.
- [x] (2026-05-03) Full verification passed: `swift test --filter LabanRendererSmokeTests`
  (13/13), `./scripts/check` → `check passed`.

## Decision Log

- Decision: Fix backing-scale rendering before implementing the debug server.
  Rationale: `docs/process/dev-process.md` requires screenshots and render
  diagnostics to come from the same rendering path as the product UI. If the
  debug server lands first, agents may build tests around low-resolution
  screenshots that have to be invalidated immediately afterward.
  Date/Author: 2026-05-03 / Codex.

- Decision: Keep terminal geometry in logical points and scale only the raster
  target plus renderer context.
  Rationale: The terminal's row and column count should be determined by the
  AppKit viewport's point size divided by the fixed JetBrains Mono cell size.
  Multiplying rows, columns, cell width, or cell height by backing scale would
  make the same window show a different terminal grid on different displays.
  Date/Author: 2026-05-03 / Codex.

- Decision: Keep headless fixture rendering at scale 1 for this shard.
  Rationale: Headless runs are currently deterministic fixture checks, not
  display-fidelity checks. The upcoming debug-server screenshot contract
  already has a `scale=1|2` shape in `docs/process/dev-process.md`; that plan
  can expose explicit scale selection after the renderer owns scale correctly.
  Date/Author: 2026-05-03 / Codex.

## Context and Orientation

The current app has three relevant layers:

- `Sources/LabanCore/FrameProducer.swift` and
  `Sources/LabanCore/SidebarProducer.swift` produce frame commands. A frame
  command is a backend-neutral drawing instruction such as `rect`, `glyphRun`,
  `cursor`, or `selection`.
- `Sources/LabanRenderer/SoftwareRenderer.swift` consumes frame commands and
  draws them into `Sources/LabanRenderer/BitmapSurface.swift` using
  CoreGraphics and CoreText. CoreText is Apple's text layout and drawing API;
  here it draws JetBrains Mono glyphs into the bitmap.
- `Sources/LabanApp/TerminalBitmapView.swift` owns the visible AppKit view. It
  polls terminal sessions, asks the producers for commands, renders into the
  software surface, caches `surface.cgImage`, and draws that image into the
  view's bounds.

Definitions for this plan:

- Logical points are AppKit layout units. A view that is 1200 by 760 points can
  be 1200 by 760 pixels on a 1x display or 2400 by 1520 pixels on a 2x display.
- Backing scale is the multiplier from logical points to physical backing
  pixels for a view or window. Retina screens normally use scale 2.
- Physical pixel dimensions are the actual bitmap width and height in pixels.
  A crisp 1200 by 760 point terminal on a 2x display needs a 2400 by 1520 pixel
  bitmap.
- `BitmapSurface.pixel(x:y:)` reads a physical pixel using CoreGraphics
  coordinates, where `(0, 0)` is the bottom-left corner. The underlying
  `CGBitmapContext` stores row 0 at the top, so the helper maps y internally.

The current orientation fix must be preserved. `TerminalBitmapView.draw(_:)`
must not add a manual y-flip. AppKit's backing-store presentation already maps
the image into the window correctly when the image is drawn into `bounds`.

## Plan of Work

First, make `BitmapSurface` carry scale explicitly without breaking existing
tests. Keep `width` and `height` as physical pixel counts. Add a public
`scale: CGFloat` with default value `1`, plus logical-size helpers such as
`logicalWidth`, `logicalHeight`, or `logicalSize`. Reject non-finite,
non-positive scales with a precondition. Existing callers that pass only width
and height should continue to mean "physical pixels at scale 1."

Next, update `SoftwareRenderer.render(_:)` so frame commands remain expressed
in logical points. At the start of each render call, save the graphics state,
scale the context by `surface.scale`, draw all commands normally, and restore
the graphics state before returning. For a scale 2 surface, a logical rect at
`x: 10, y: 10, width: 4, height: 4` should paint physical pixels around
`x: 20...27, y: 20...27`. Text drawn with the same `FontAtlas(pointSize: 14)`
should become 28 backing pixels tall-ish on a 2x surface because the context
transform scales CoreText drawing.

Then, move AppKit surface allocation to a single helper in
`TerminalBitmapView`. That helper should:

- compute the current backing scale from the view or window, falling back to
  scale 1 when the view is not yet attached to a window;
- compute pixel width and height as `ceil(bounds.width * scale)` and
  `ceil(bounds.height * scale)`, clamped to at least 1;
- allocate `BitmapSurface(width: pixelWidth, height: pixelHeight,
  scale: scale)`;
- rebuild `SoftwareRenderer(surface:fontAtlas:)`;
- avoid reallocating if pixel width, pixel height, and scale are unchanged.

Call that helper from `viewDidMoveToWindow()`, `setFrameSize(_:)`,
`viewDidChangeBackingProperties()`, and before rendering a frame. `setFrameSize`
should still call `model.resize(...)` using logical point dimensions and fixed
cell metrics. Do not multiply `cellWidth`, `cellHeight`, terminal rows,
terminal columns, sidebar width, or frame-command coordinates by backing scale.

`MainWindowController` should stop guessing the initial bitmap scale if that
keeps the code simpler. A good shape is for the controller to pass the model,
font atlas, and cell metrics to `TerminalBitmapView`, while the view owns
surface creation based on its current bounds and backing scale. If keeping the
existing initializer is less disruptive, ensure the first `viewDidMoveToWindow`
or `advanceFrame` replaces any placeholder 1x surface before visible output is
used.

Keep `Sources/LabanAgent/main.swift`,
`Tests/LabanCoreTests/FixtureRunnerTests.swift`, and `scripts/run-headless` at
scale 1 for now. They may continue to construct `BitmapSurface(width:height:)`.
If the implementation adds a shared helper for scale calculation, use it in
headless only with an explicit scale argument of `1`.

## Concrete Steps

Work from the repository root:

```sh
cd /Users/dev/wrk/laban
```

Inspect the relevant files before editing:

```sh
sed -n '1,220p' Sources/LabanRenderer/BitmapSurface.swift
sed -n '1,220p' Sources/LabanRenderer/SoftwareRenderer.swift
sed -n '1,220p' Sources/LabanApp/TerminalBitmapView.swift
sed -n '1,120p' Sources/LabanApp/MainWindowController.swift
sed -n '1,240p' Tests/LabanRendererTests/LabanRendererSmokeTests.swift
```

Implement the renderer changes in this order:

1. Update `BitmapSurface` with the scale property and logical-size helpers.
2. Update `SoftwareRenderer.render(_:)` to apply `surface.scale` around command
   drawing and restore the graphics state when finished.
3. Add tests in `Tests/LabanRendererTests/LabanRendererSmokeTests.swift`:
   a scaled `rect` test, a scaled glyph non-background test, and any logical
   size helper test introduced with `BitmapSurface`.
4. Update AppKit allocation in `TerminalBitmapView` and
   `MainWindowController`.
5. Build the app and run checks.

Run focused tests while iterating:

```sh
swift test --filter LabanRendererSmokeTests
```

Expected result: SwiftPM reports the renderer tests passed. The scaled rect
test should fail before the renderer applies the backing-scale transform and
pass afterward.

Run the full gate:

```sh
./scripts/check
```

Expected result:

```text
check passed
```

Build the local app bundle:

```sh
./scripts/build-app
```

Expected result includes:

```text
build-app: .build/laban/Laban.app/Contents/MacOS/LabanApp
```

Open a separate copy for visual inspection:

```sh
open -n .build/laban/Laban.app
```

Expected visual result: terminal output is upright, not mirrored, and text is
rendered at the display backing scale rather than stretched from a 1x bitmap.
The exact antialiasing style may still be improved later, but the bitmap
dimensions should now match the screen's native pixel density.

## Validation and Acceptance

**Status: complete as of 2026-05-03.** All criteria verified.

This ExecPlan is complete when all of the following are true:

- `BitmapSurface(width:height:)` remains source-compatible and creates a scale
  1 surface.
- A scale 2 `BitmapSurface` exposes physical `width` and `height`, plus
  logical dimensions equal to physical dimensions divided by 2.
- `SoftwareRenderer` draws frame commands in logical coordinates onto scaled
  physical pixels. The renderer test must prove that a small scaled rect paints
  an expected inside physical pixel and leaves a nearby outside physical pixel
  unchanged.
- A renderer glyph test proves scaled text still produces at least one
  non-background physical pixel.
- `TerminalBitmapView` creates or recreates its surface using AppKit backing
  scale on initial attachment, resize, and backing-property changes.
- `AppModel.resize(...)` continues to receive logical terminal viewport
  dimensions. Moving the same point-sized window between 1x and 2x displays
  must not change the terminal row/column count solely because scale changed.
- `TerminalBitmapView.draw(_:)` still draws the cached `CGImage` into `bounds`
  without a manual coordinate flip.
- `swift test --filter LabanRendererSmokeTests` passes.
- `./scripts/check` passes.
- `./scripts/build-app` succeeds and `open -n .build/laban/Laban.app` shows an
  upright terminal whose text is no longer a 1x bitmap stretched over a Retina
  backing store.

## Idempotence and Recovery

The implementation should be safe to rerun. Recreating `BitmapSurface` on view
resize or backing-scale changes must release the previous surface through Swift
ownership and must not leak the terminal session or restart the shell.

If a changed initializer causes broad call-site churn, keep the old initializer
as a compatibility wrapper and add the new scale-aware initializer as an
overload. If a scaled-renderer test is difficult to make exact around glyph
edges, keep exact pixel assertions for rectangles and use "non-background pixel
exists" assertions for glyphs.

Generated app bundles, `.build/`, `.external/`, `.artifacts/`, and `.tmp/`
are build or run outputs. Do not commit generated screenshots or app bundles
unless a later golden-image plan explicitly asks for them.

## Interfaces and Dependencies

Use the existing dependencies only:

- AppKit in `Sources/LabanApp` for view size and backing scale.
- CoreGraphics in `Sources/LabanRenderer` for bitmap contexts, transforms,
  colors, and `CGImage` creation.
- CoreText in `Sources/LabanRenderer` for glyph drawing through the existing
  `FontAtlas`.
- SwiftPM and XCTest for builds and tests.

Recommended public surface at completion:

```swift
public final class BitmapSurface {
  public let width: Int        // physical pixels
  public let height: Int       // physical pixels
  public let scale: CGFloat    // physical pixels per logical point

  public init(width: Int, height: Int, scale: CGFloat = 1)

  public var logicalWidth: CGFloat { get }
  public var logicalHeight: CGFloat { get }
  public var logicalSize: CGSize { get }
}
```

The exact helper names may vary if the implementation finds a clearer local
pattern, but the semantics must remain: physical pixels are explicit, logical
points are derived, and frame commands stay in logical coordinates.
