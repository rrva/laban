# Fix SGR Attributes And Triangle Rendering

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban currently parses color output from Ghostty render state, but it drops
cell text attributes such as bold, dim, italic, underline, reverse video,
strikethrough, and overline before drawing. It also renders geometric triangle
glyphs such as `◢◣◤◥` through the fallback font path, which can overlap
adjacent terminal cells. After this change, running `~/scripts/render-test`
inside Laban should visibly match Ghostty for the SGR attributes section and
the rightmost triangle shapes in the "Box drawing & block elements" section.

## Progress

- [x] (2026-05-04T20:25:13Z) Created this focused ExecPlan before implementation.
- [x] (2026-05-04T20:26:34Z) Preserve Ghostty SGR style flags in `LabanCell.flags`;
      C bridge now reads `GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE` and swaps
      fg/bg at the snapshot layer when `style.inverse` is set.
- [x] (2026-05-04T22:48:00Z) Threaded `TextAttributes` through `FrameCommand.glyphRun`,
      `FrameProducer` coalescing, `CapturedFrameCommand`, `FrameCommandResponse`,
      and `TraceCommand`. Capture JSON serializes attribute names (`bold`,
      `italic`, etc.) so diffs stay readable.
- [x] (2026-05-04T22:48:00Z) `SoftwareRenderer` now styles bold/italic via
      CoreText symbolic traits with second-pass bold and shear italic fallback,
      blends faint, drops invisible, and paints underline/strikethrough/overline
      lines. `BoxDrawing.proceduralCellElementRects` now covers `◢◣◤◥`
      (U+25E2..U+25E5) so triangles never overflow their cell.
- [x] (2026-05-04T22:49:00Z) Added focused tests: SGR attributes propagate,
      inverse swaps fg/bg, runs split when attributes change, triangles render
      as procedural rects, capture replay round-trips attributes, and a
      renderer pixel test for underline strokes. `./scripts/check` passes.

## Context and Orientation

The C terminal bridge in `Sources/LabanTerminalCore/session.c` owns Ghostty
terminal and render-state objects. `laban_session_snapshot` converts Ghostty
render-state cells into the public `LabanSnapshot` and `LabanCell` ABI declared
in `Sources/LabanTerminalCore/include/LabanTerminalCore.h`.

`Sources/LabanCore/FrameProducer.swift` converts a `LabanSnapshot` into backend
neutral `FrameCommand` values from `Sources/LabanRenderer/FrameCommand.swift`.
`Sources/LabanRenderer/SoftwareRenderer.swift` draws those commands into a
bitmap. The debug runtime and capture replay serialize frame commands through
`Sources/LabanDebug/HeadlessDebugRuntime.swift` and
`Sources/LabanDebug/CaptureRecorder.swift`.

The worktree must have `.external` linked to `/Users/rrj/wrk/laban/.external`
before build/test commands that depend on libghostty-vt can pass.

## Plan of Work

1. Add named bit constants for `LabanCell.flags`, then populate them from
   `GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE` during snapshot extraction.
   Swap foreground/background colors in the snapshot when Ghostty reports
   inverse video. Keep blink parsed but not animated in this shard.
2. Add `TextAttributes` in `LabanRenderer` and include it on
   `FrameCommand.glyphRun`. Update all producers and all pattern matches.
3. Split terminal glyph runs by foreground, background, and attributes. Blend
   dim/faint foreground toward the cell background. Drop invisible glyphs.
4. Draw text attributes in the software renderer with deterministic fallback:
   CoreText symbolic traits for bold/italic where possible, second-pass bold
   and shear italic fallback where needed, and line rects for underline,
   strikethrough, and overline.
5. Add procedural fixed-cell geometry for U+25E2-U+25E5 so `◢◣◤◥` render
   within their terminal cells and do not use fallback font metrics.
6. Extend frame-command debug/capture JSON with optional attributes and make
   capture replay restore them.
7. Add tests for the C snapshot flags, frame command attributes and triangles,
   renderer pixels, and capture/debug serialization.

## Validation and Acceptance

Run the focused tests while developing:

```sh
swift test --filter LabanSessionTests
swift test --filter FrameProducerTests
swift test --filter LabanRendererSmokeTests
swift test --filter CaptureReplayTests
```

Then run the project check:

```sh
./scripts/check
```

Acceptance is that the tests pass, frame-command/capture JSON round-trips text
attributes, and a manual `~/scripts/render-test` run in Laban visibly shows
the SGR attributes and `◢◣◤◥` without overlap.

## Artifacts and Notes

The latest local capture found during planning is:

```text
/Users/rrj/Library/Logs/Laban/captures/appkit-2026-05-04T20-20-57Z
```

It contains terminal bytes and screenshots, so use it locally only and do not
paste its contents into reports.
