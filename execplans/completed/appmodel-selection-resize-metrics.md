# Preserve AppModel Active Tab And Resize Metrics

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

The application model owns tab selection and session resizing. After this change, a bad tab identifier from debug tooling, capture replay, or sidebar plumbing cannot leave the app with no active tab, and resize calls carry the pixel and cell metrics that terminal programs can query through XTWINOPS size reports. The observable result is that stale selection requests are ignored and terminal size replies report the same geometry the app just applied.

## Progress

- [x] Read `Sources/LabanCore/AppModel.swift` selection and resize code.
- [x] Confirm `Sources/LabanTerminalCore/session.c` uses `cell_width` and `cell_height` when encoding size reports and `pixel_width` and `pixel_height` for PTY winsize.
- [x] Make stale `selectTab` requests no-ops.
- [x] Populate rows, columns, pixel dimensions, and cell dimensions in `AppModel.resize`.
- [x] Add regression tests for stale selection and XTWINOPS resize metric replies.
- [x] Run focused core tests and the full package suite.

## Outcomes & Retrospective

`selectTab(_:)` now validates the target id before mutating tab state, so stale debug or sidebar ids leave the existing active tab untouched. `resize(viewportWidth:viewportHeight:cellWidth:cellHeight:)` now sends rows, columns, viewport pixels, and cell pixels to each session, clamping malformed zero cell dimensions before division. The AppModel regression tests prove both behaviors and verify terminal size reports through captured XTWINOPS replies.

## Context and Orientation

`Sources/LabanCore/AppModel.swift` stores tabs and maps each tab to a `Session`. `selectTab(_:)` currently loops through every tab and writes `isActive = tabs[i].id == tabId`; if the id is stale, every tab becomes inactive. `resize(viewportWidth:viewportHeight:cellWidth:cellHeight:)` computes terminal rows and columns, but currently creates a `LabanTerminalSize` with only `rows` and `cols` set. The C session layer in `Sources/LabanTerminalCore/session.c` passes `cell_width` and `cell_height` to libghostty's resize call and uses those values when responding to XTWINOPS queries such as `CSI 14 t`, `CSI 16 t`, and `CSI 18 t`.

## Plan of Work

Change `selectTab(_:)` so it first finds the target tab index. If no tab matches, return without mutating tabs or recording a selection event. For a valid tab, update active flags and activity metadata as before.

Change `resize(viewportWidth:viewportHeight:cellWidth:cellHeight:)` so the `LabanTerminalSize` sent to every session includes nonzero cell width and height plus the viewport pixel width and height. Guard against zero cell dimensions before dividing so a malformed resize request cannot crash the model.

Add AppModel tests in `Tests/LabanCoreTests/AppModelTests.swift`. One test creates multiple tabs, sends a stale id to `selectTab`, and asserts the previous active tab remains active. Another test resizes to a known viewport and cell size, sends XTWINOPS size queries to the fixture session, and asserts the captured terminal responses include the expected pixel area, cell size, and character grid.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter AppModelTests
rtk swift test
```

Acceptance: the new stale-selection test fails before the `selectTab` change and passes after it. The new size-report test fails before the resize metric change because the pixel and cell-size replies are zeroed, then passes with replies like `ESC[4;540;900t`, `ESC[6;18;9t`, and `ESC[8;30;100t`.
