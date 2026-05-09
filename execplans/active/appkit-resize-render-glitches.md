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
- [ ] Inspect AppKit window layout, resize, surface recreation, and renderer
  damage behavior.
- [ ] Add autonomous AppKit resize repro/capture tooling if current tools do
  not expose the issue.
- [ ] Reproduce and classify at least one resize artifact with saved evidence.
- [ ] Implement a focused fix for the observed resize path.
- [ ] Validate with resize repro artifacts and targeted tests.

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

Acceptance requires both a targeted automated repro and code-level tests where
practical:

```sh
cd /Users/rrj/wrk/laban
rtk <resize repro command to be added or existing debug command>
rtk swift test --filter <targeted tests>
rtk ./scripts/lint
rtk ./scripts/check-docs
```

The resize repro should write artifacts under `.artifacts/` and report zero
detected top unpainted rows, zero sidebar geometry jumps not explained by
window size changes, and zero stale dark-block detections in the terminal area.

## Idempotence and Recovery

Generated artifacts must live under `.artifacts/` and must not be committed.
Environment-only automation must be disabled unless the corresponding
`LABAN_*` variables are set. If a launched AppKit process does not exit, the
runner script must terminate it after a timeout and preserve artifacts for
inspection.
