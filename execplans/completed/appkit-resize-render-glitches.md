# Diagnose And Fix AppKit Resize Render Glitches

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Resizing the Laban macOS window should not expose unpainted white strips, jumpy
sidebar geometry, or stale dark terminal blocks. This work adds or extends
autonomous AppKit resize observation first, then uses those artifacts to fix the
rendering path. A developer should be able to run one command, resize the real
AppKit window automatically, and inspect machine-readable pixel/frame evidence
without watching the screen manually.

## Progress

- [x] Read `docs/product/mvp.md`, `docs/process/dev-process.md`,
  `docs/process/worktree-isolation.md`, `docs/process/observability.md`, and
  existing resize/debug references.
- [x] Inspect AppKit window layout, resize, surface recreation, and renderer
  damage behavior.
- [x] Add autonomous AppKit resize repro/capture tooling if current tools do
  not expose the issue.
- [x] Reproduce and classify at least one resize artifact with saved evidence.
- [x] Finish the focused fix for the observed resize path. Dropped Metal frames
  now remain dirty in `TerminalBitmapView`; resize-triggered surface changes
  render synchronously even outside AppKit live-resize; and a transient
  resize-only theme-frame backing color covers compositor gaps without
  permanently changing AppKit titlebar chrome.
- [x] Validate with resize repro artifacts and targeted tests.
- [x] Follow up on the sidebar-specific resize report with command-level
  sidebar probes and stressed diagonal screenshots.
- [x] Follow up on height-only fast alternating resize. Metal now presents
  resize frames with top-left native drawable gravity and waits for the
  resize command buffer to complete before returning to AppKit.

## Completed Follow-Through

The final implementation resumed from commit
`39d1c89 Resize artifacts need autonomous AppKit evidence`. The checkpoint had
already changed `RendererBackend.render(_:damage:)` to return `Bool` and made
`MetalRenderer` return `false` when it could not acquire the in-flight frame
gate, drawable, command buffer, or required full-frame content pass.

`Sources/LabanApp/TerminalBitmapView.swift` now uses that result. A failed
backend render leaves `renderInvalidated` true, schedules a main-thread retry,
and returns before incrementing `renderedFrameCount` or calling
`session.markRendered()`. `setFrameSize(_:)` also renders synchronously when the
surface size changes, not only during AppKit's `inLiveResize`, so programmatic
resize automation follows the same path as user resize.

The top-window background is handled with a transient resize-only background on
the AppKit theme-frame backing view, then restored shortly after resize
settles. The `NSWindow.backgroundColor` and CAMetalLayer background are
intentionally not set; see Decision Log.

The resize fallback now starts before a live resize begins, and the automated
resize harness applies the same fallback before each programmatic
`setContentSize` call. `LABAN_FRAME_PROBE_DIR` also records sidebar glyph runs
and sidebar rects so agents can distinguish true sidebar layout movement from
WindowServer presentation timing.

The height-only follow-up found that logical frame commands were already
top-anchored, but CAMetalLayer bottom-left gravity placed a new shorter
drawable at the bottom of a stale taller WindowServer image. `MetalRenderer`
now uses `.topLeft` contents gravity, and `TerminalBitmapView` temporarily
enables `MetalRenderer.waitForFrameCompletion` for resize-triggered frames so
the top-left anchored layer has a completed drawable before AppKit samples it.

`scripts/analyze-resize-repro` gained a faster ImageMagick raw-RGB path when
`magick` is installed, with the standard-library PNG decoder retained as a
fallback. This keeps the AppKit resize repro practical for repeated local runs.

## Decision Log

- Decision: A backend render that returns `false` is not a completed visual
  frame for AppKit state.
  Rationale: The failing artifact had a new `viewBounds`, `layerBounds`, and
  `drawableSize` but an advanced `renderedFrame`; that meant the UI believed a
  resize frame had presented even though Metal had dropped or failed the draw.
  The host view must keep the dirty frame pending until a backend render
  succeeds.
  Date/Author: 2026-05-09 / Codex.

- Decision: Use the AppKit theme-frame backing layer only as a transient resize
  fallback, and do not set `NSWindow.backgroundColor` or
  `CAMetalLayer.backgroundColor`.
  Rationale: Setting the CAMetalLayer background made capture-off Metal window
  screenshots turn fully black, while capture-on and software paths still
  looked correct. Leaving the Metal layer background alone restored normal
  capture-off presentation. Keeping `window.backgroundColor` set permanently
  hid AppKit's traffic-light controls in a rebuilt instance, and even transient
  use made capture-off Metal probes black. The fallback now colors the
  theme-frame backing layer during resize and restores it afterward.
  Date/Author: 2026-05-09 / Codex.

- Decision: Apply the transient theme-frame fallback before resize mutation,
  not only after `setFrameSize(_:)`.
  Rationale: Sidebar command geometry stayed top-anchored, but immediate
  diagonal-shrink screenshots could still show the current smaller content
  composited into the previous larger WindowServer image, exposing white
  titlebar/window backing above and to the right of the app content. Pre-filling
  the theme-frame backing before resize removes that stale-frame flash while
  avoiding `NSWindow.backgroundColor`.
  Date/Author: 2026-05-09 / Codex.

- Decision: Metal resize presentation uses native top-left drawable gravity,
  with command-buffer completion waits only for resize-triggered frames.
  Rationale: Height-only alternating shrink/grow could capture a newly sized
  shorter drawable bottom-aligned inside the previous taller WindowServer
  image, moving the sidebar tab and row-0 cursor downward by the height delta.
  `.resize` gravity removed the white band but visibly stretched and shifted
  stale frames; `.top` fixed height while centering width-only stale frames.
  `.topLeft` plus a resize-only completion wait preserved native pixels and
  anchored both axes.
  Date/Author: 2026-05-10 / Codex.

## Surprises & Discoveries

- Observation: The first normal resize repro did not catch the top white strip,
  but the stressed repro did.
  Evidence: `.artifacts/resize-repro/20260509T075259Z` reported
  `maxTopWhiteRatio=0.0`, while `.artifacts/resize-repro/20260509T075439Z`
  reported `maxTopWhiteRatio=0.9876543209876543`.

- Observation: The captured white area can persist into a "settled" screenshot
  after the resize step.
  Evidence: `.artifacts/resize-repro/20260509T075439Z/probe/screenshots/011-step-4-settled.png`
  has a large white top/right region even though the probe event for
  `step-4-settled` reports `viewBounds=1288x819`, `layerBounds=1288x819`, and
  `drawableSize=2576x1638`.

- Observation: Setting `CAMetalLayer.backgroundColor` caused capture-off Metal
  probe screenshots to become fully black, while software and capture-on Metal
  screenshots remained visible.
  Evidence: `.artifacts/resize-repro/20260509T120946Z` reported
  `maxNearBlackRatio=1.0`; after removing the layer background assignment,
  `.artifacts/resize-repro/20260509T121836Z` reported
  `maxNearBlackRatio=0.0003154121863799283` with the same capture-off Metal
  path.

- Observation: The original standard-library PNG analyzer was correct but too
  slow on AppKit screenshots with Paeth-filtered rows.
  Evidence: analyzing `.artifacts/resize-repro/20260509T121836Z/probe` took
  about 64 seconds before the ImageMagick fast path and under 10 seconds after
  the direct RGB scan optimization.

- Observation: The sidebar's own layout commands were not jumping during the
  empty-terminal resize report.
  Evidence: `.artifacts/resize-sidebar/20260509T163106Z/frame-probe/frame-probe.ndjson`
  recorded 38 sidebar frames with `tabTop=[28.0]`,
  `titleBaselineTop=[55.5]`, and `cursorTop=[36.0]`.

- Observation: The visible sidebar jump came from stale WindowServer resize
  presentation, not from `SidebarProducer` changing coordinates.
  Evidence: `.artifacts/resize-sidebar/20260509T163106Z` had two immediate
  screenshots with `topWhiteRatio` near `0.987`; the probe event for the same
  sequence had already moved the view to the new smaller bounds while
  `CGWindowListCreateImage` still returned the previous larger window image.
  After pre-filling before resize mutation,
  `.artifacts/resize-sidebar/20260509T163508Z` reported
  `events=74`, `screenshots=74`, and `maxTopWhiteRatio=0.0`.

- Observation: The height-only jump was Metal presentation anchoring, not
  terminal-grid or sidebar command geometry.
  Evidence: `.artifacts/resize-height/20260510T082326Z` captured
  `step-9-settled` with `viewBounds=1200x580` and `drawableSize=2400x1160`,
  but `CGWindowListCreateImage` still returned a `1200x820` image whose
  new content was bottom-aligned under a large white top band. The frame probe
  for the same run kept the tab and cursor top positions stable.

- Observation: The rejected alternatives each failed a different autonomous
  probe. `.topLeft` without waiting could produce all-black Metal window
  screenshots; `.resize` removed the white band but stretched a stale
  height frame; `.top` kept height stable but centered width-only stale
  frames and exposed white side bands.
  Evidence: `.artifacts/resize-height-resizegravity/20260510T161842Z` had
  `maxTopWhiteRatio=0.0` but visibly stretched `009-step-3-settled.png`;
  `.artifacts/resize-width-topgravity/20260510T162145Z` exposed side bands
  with `maxTopWhiteRatio=0.27525252525252525`.

## Outcomes & Retrospective

The stressed resize repro that previously captured a white region now reports
zero top white pixels across immediate and settled screenshots. The final
aggressive run is `.artifacts/resize-repro/20260509T122240Z`, with
`events=22`, `screenshots=22`, `maxTopWhiteRatio=0.0`, and
`maxNearBlackRatio=0.00032020959173277054`.

The normal Metal run is `.artifacts/resize-repro/20260509T122224Z`, with
`events=14`, `screenshots=14`, `maxTopWhiteRatio=0.0`, and
`maxNearBlackRatio=0.0003154121863799283`.

The sidebar follow-up found stable command geometry and removed a stale
WindowServer white-frame flash in the diagonal stress harness. The final
sidebar stress artifact is `.artifacts/resize-sidebar/20260509T163508Z`, with
`events=74`, `screenshots=74`, `maxTopWhiteRatio=0.0`, and
`maxNearBlackRatio=0.0003154121863799283`.

The height-only follow-up artifact after the Metal anchoring fix is
`.artifacts/resize-height-topleft-wait/20260510T162347Z`, with `events=42`,
`screenshots=42`, `maxTopWhiteRatio=0.0`, and
`maxNearBlackRatio=0.0002933333333333333`. The width-only guard run is
`.artifacts/resize-width-topleft-wait/20260510T162310Z`, with `events=22`,
`screenshots=22`, and `maxTopWhiteRatio=0.0`.

## Context and Orientation

`Sources/LabanApp/TerminalBitmapView.swift` owns the AppKit terminal view,
including surface resize, frame-command production, and calls to the active
renderer. The renderer is usually `MetalRenderer`, which self-presents through
a `CAMetalLayer`; the software path blits a CG image in `draw(_:)`.

The previous spinner investigation added `LABAN_FRAME_PROBE_DIR`, which records
frame commands without enabling full capture readback. That probe can explain
logical frame commands, but it cannot see OS-level resize presentation gaps
unless we also capture rendered pixels during live AppKit resizing.

The user reports three visual symptoms during diagonal window resizing:

- a white line at the very top of the window, suggesting a region outside the
  terminal/sidebar background is exposed;
- jumpy sidebar positioning;
- transient dark blocks in terminal output, likely stale render-target pixels
  or cursor overlay/content damage mismatch during rapid surface size changes.

## Plan of Work

First inspect how the AppKit window embeds `TerminalBitmapView`, how the view
responds to frame/bounds changes, how sessions are resized, and how
`MetalRenderer` reallocates and repaints its persistent target. If existing
debug actions can drive AppKit resize and collect screenshots, use them. If not,
add environment-only automation similar to the spinner repro: a script to launch
Laban with a deterministic terminal workload, programmatic window-resize steps,
and a pixel probe that saves frame screenshots or rendered PNGs around each
resize.

Then run the repro with Metal and, if useful, software rendering. Classify the
artifact by comparing frame commands, surface size, layer/view bounds, and
pixel probes for top-row non-background pixels, sidebar x/y movement, and dark
blocks in the terminal area. Implement the smallest fix that addresses the
captured cause, then rerun the same repro and relevant tests.

## Validation and Acceptance

Acceptance required both a targeted automated repro and code-level tests. These
commands were run from `/Users/rrj/wrk/laban`:

```sh
rtk scripts/run-resize-repro --seconds 8 --renderer metal
rtk env LABAN_RESIZE_CAPTURE_DELAY_MS=1 \
  LABAN_RESIZE_STEPS='1200x788,930x615,1337x861,910x604,1288x819,960x640,1350x870,900x620,1260x818,940x630' \
  scripts/run-resize-repro --seconds 8 --renderer metal --no-build
rtk swift test --filter TerminalBitmapViewSyncOutputTests
rtk swift test --filter MetalRendererSmokeTests
rtk swift test --filter SidebarProducerTests
rtk python3 -m py_compile scripts/analyze-resize-repro scripts/resize-torture
rtk git diff --check
rtk ./scripts/lint
rtk ./scripts/check-docs
rtk ./scripts/check
```

Additional follow-up repros were run with the environment-only resize harness
using `LABAN_RESIZE_AUTOMATION=1`, `LABAN_RESIZE_PROBE_DIR`,
`LABAN_FRAME_PROBE_DIR`, and explicit alternating height/width
`LABAN_RESIZE_STEPS`.

Results:

- normal Metal resize repro:
  `.artifacts/resize-repro/20260509T122224Z`, `maxTopWhiteRatio=0.0`;
- stressed Metal resize repro:
  `.artifacts/resize-repro/20260509T122240Z`, `maxTopWhiteRatio=0.0`;
- `TerminalBitmapViewSyncOutputTests`: 4 tests passed;
- `MetalRendererSmokeTests`: 8 tests passed;
- `SidebarProducerTests`: 20 tests passed after adding
  `testTopTabGeometryStaysTopAnchoredAcrossResizeHeights`;
- `scripts/lint`, `scripts/check-docs`, and `scripts/check`: passed.
- height-only alternating Metal resize after the follow-up fix:
  `.artifacts/resize-height-topleft-wait/20260510T162347Z`,
  `maxTopWhiteRatio=0.0`;
- width-only alternating Metal resize guard after the follow-up fix:
  `.artifacts/resize-width-topleft-wait/20260510T162310Z`,
  `maxTopWhiteRatio=0.0`.

The first `rtk ./scripts/check` run saw one transient full-suite Swift test
failure, but rerunning `rtk swift test` immediately passed and the next full
`rtk ./scripts/check` passed.

## Idempotence and Recovery

Generated artifacts must live under `.artifacts/` and must not be committed.
Environment-only automation must be disabled unless the corresponding
`LABAN_*` variables are set. If a launched AppKit process does not exit, the
runner script must terminate it after a timeout and preserve artifacts for
inspection.
