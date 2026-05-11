# Reconcile Scroll Input With Authoritative Viewport State

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Scrolling should respond to the physical gesture the user made and should recover immediately at scrollback edges. After this change, precise trackpad wheel events in mouse-reporting mode still reach terminal programs even when legacy `deltaY` is zero, and local smooth-scroll state is reconciled with libghostty's clamped viewport so overscroll does not make reverse scrolling feel swallowed.

## Progress

- [x] Read `Sources/LabanApp/TerminalBitmapView.swift` wheel and smooth-scroll paths.
- [x] Read `Sources/LabanApp/TerminalScrollInput.swift` and existing scroll tests.
- [x] Route mouse-reporting wheel direction through precise `scrollingDeltaY` when available.
- [x] Reconcile smooth-scroll counters with `Session.viewportState()` after scroll application and tab switches.
- [x] Add focused regression tests for precise wheel direction and viewport clamp math.
- [x] Run focused App tests and the full package suite.

## Outcomes & Retrospective

Mouse-reporting wheel handling now derives direction from precise `scrollingDeltaY` when AppKit marks the event as precise, so trackpad wheel events with legacy `deltaY == 0` are no longer dropped. Smooth-scroll state now uses libghostty's viewport offset to express applied rows relative to the active bottom, and resets the local target/display/velocity when a requested scroll is clamped at an edge. Regression tests cover precise mouse direction and clamped viewport reconciliation.

## Context and Orientation

`TerminalBitmapView.scrollWheel(with:)` has two paths. When terminal mouse tracking is active, it encodes wheel events as mouse button 4 or 5 and sends them to the PTY. When mouse tracking is off, it scrolls the local viewport through `Session.scrollViewport(deltaRows:)`. AppKit's legacy `deltaY` can be zero for precise trackpad events even when `scrollingDeltaY` contains real motion, so the mouse-tracking path currently drops those gestures. The local smooth-scroll path stores requested scroll rows in Swift counters, but libghostty clamps the actual viewport at the top and bottom of scrollback; the counters must be synchronized to that actual state after scrolls.

## Plan of Work

Add small helpers to `TerminalScrollInput`: one to resolve a mouse-reporting wheel direction from precise or legacy deltas, and one to convert a `ViewportState`-style `viewportOffset`, `totalRows`, and `viewportRows` into the relative applied-scroll row used by `TerminalBitmapView`. Update `TerminalBitmapView.scrollWheel(with:)` to use the direction helper in mouse-tracking mode. Add a private view helper that reads `session.viewportState()` after `scrollViewport(deltaRows:)`; if libghostty clamped the request, snap `targetScrollRows`, `displayedScrollRows`, and `appliedScrollRows` to the authoritative value and clear velocity.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter TerminalScrollInputTests
rtk swift test
```

Acceptance: precise events with `deltaY == 0` and nonzero `scrollingDeltaY` produce a wheel direction for mouse-reporting mode, and viewport-offset reconciliation reports clamping when a requested applied row goes past the scrollback edge.
