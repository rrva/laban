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
  render synchronously even outside AppKit live-resize; and the window
  background follows the current terminal theme.
- [x] Validate with resize repro artifacts and targeted tests.

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

The top-window background is handled at the window level with
`window.backgroundColor = Theme.current.bg0`. The CAMetalLayer background is
intentionally not set; see Decision Log.

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

- Decision: Theme the AppKit window background, but do not set
  `CAMetalLayer.backgroundColor`.
  Rationale: Setting the CAMetalLayer background made capture-off Metal window
  screenshots turn fully black, while capture-on and software paths still
  looked correct. Leaving the Metal layer background alone restored normal
  capture-off presentation; setting the window background still covers the
  transparent titlebar/top-window area that can otherwise flash white.
  Date/Author: 2026-05-09 / Codex.

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

## Outcomes & Retrospective

The stressed resize repro that previously captured a white region now reports
zero top white pixels across immediate and settled screenshots. The final
aggressive run is `.artifacts/resize-repro/20260509T122240Z`, with
`events=22`, `screenshots=22`, `maxTopWhiteRatio=0.0`, and
`maxNearBlackRatio=0.00032020959173277054`.

The normal Metal run is `.artifacts/resize-repro/20260509T122224Z`, with
`events=14`, `screenshots=14`, `maxTopWhiteRatio=0.0`, and
`maxNearBlackRatio=0.0003154121863799283`.

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
rtk python3 -m py_compile scripts/analyze-resize-repro scripts/resize-torture
rtk git diff --check
rtk ./scripts/lint
rtk ./scripts/check-docs
rtk ./scripts/check
```

Results:

- normal Metal resize repro:
  `.artifacts/resize-repro/20260509T122224Z`, `maxTopWhiteRatio=0.0`;
- stressed Metal resize repro:
  `.artifacts/resize-repro/20260509T122240Z`, `maxTopWhiteRatio=0.0`;
- `TerminalBitmapViewSyncOutputTests`: 4 tests passed;
- `MetalRendererSmokeTests`: 8 tests passed;
- `scripts/lint`, `scripts/check-docs`, and `scripts/check`: passed.

The first `rtk ./scripts/check` run saw one transient full-suite Swift test
failure, but rerunning `rtk swift test` immediately passed and the next full
`rtk ./scripts/check` passed.

## Idempotence and Recovery

Generated artifacts must live under `.artifacts/` and must not be committed.
Environment-only automation must be disabled unless the corresponding
`LABAN_*` variables are set. If a launched AppKit process does not exit, the
runner script must terminate it after a timeout and preserve artifacts for
inspection.
