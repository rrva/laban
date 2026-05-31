# Share renderer text decoration geometry

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Terminal text decorations should render consistently no matter which backend
draws a frame. Before this change, `SoftwareRenderer` and `MetalRenderer`
separately computed underline, curly underline, dotted underline, dashed
underline, strikethrough, and overline geometry. That duplication risks backend
drift: a captured software frame can disagree with a live Metal frame for the
same `FrameCommand` list.

After this change, both renderers ask one renderer-neutral helper for decoration
geometry. The observable behavior is unchanged except that Metal now uses the
glyph run's active atlas metrics for sidebar decorations too.

## Progress

- [x] Read `docs/product/mvp.md`, `PLANS.md`, and the relevant model/renderer
  files under `Sources/`.
- [x] Validate the refactor advice against current code.
- [x] Add a renderer-neutral text decoration layout helper.
- [x] Update `SoftwareRenderer` and `MetalRenderer` to consume the helper.
- [x] Run focused renderer tests and formatting checks.

## Decision Log

- Decision: Implement the renderer-neutral decoration helper first, not the
  larger AppModel or full Metal subsystem split.
  Rationale: The AppModel advice is partly stale because `SessionRegistry` and
  `TabMetadataSynchronizer` already exist. The full Metal split is still valid
  but broad. Shared decoration geometry is current, small, and directly guards
  against visual drift between the test backend and production backend.
  Date/Author: 2026-05-11 / Codex.

## Context and Orientation

`Sources/LabanRenderer/FrameCommand.swift` defines `FrameCommand.glyphRun`,
`TextAttributes`, and `UnderlineStyle`. A glyph run can request underline,
strikethrough, or overline rendering. The software backend in
`Sources/LabanRenderer/SoftwareRenderer.swift` draws these decorations with
CoreGraphics. The Metal backend in `Sources/LabanRenderer/MetalRenderer.swift`
turns the same decorations into solid quad instances.

The helper introduced by this plan should not know about CoreGraphics drawing
state, Metal devices, command buffers, textures, or glyph atlases. It should
only compute rectangles and curly underline points in CoreGraphics coordinate
space, where frame commands are already expressed.

## Plan of Work

Add `Sources/LabanRenderer/TextDecorationLayout.swift` with an internal
`TextDecorationLayout` value. It should expose a static `make` function that
accepts the glyph run origin, cell count, text attributes, underline style,
cell advance, cell height, font descent, and surface scale. It should return:

- shared thickness
- underline rectangles for single, double, dotted, and dashed styles
- curly underline points for curly style
- optional strikethrough and overline rectangles

Update `SoftwareRenderer.drawDecorations` to call this helper and render the
returned shapes using CoreGraphics. Update `MetalRenderer.emitDecorations` to
call the same helper and append solid instances for the returned shapes. For
curly underline, Metal should continue approximating the path with small solid
rectangles between consecutive helper points.

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/6627/laban`:

```sh
swift test --filter LabanRendererTests
swift format lint --strict Sources/LabanRenderer/SoftwareRenderer.swift Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/TextDecorationLayout.swift Tests/LabanRendererTests/TextDecorationLayoutTests.swift
git diff --check
```

Acceptance is all three commands exiting 0. The renderer tests exercise the
software and Metal decoration/readback paths; the format and whitespace checks
keep the source clean.

Completed on 2026-05-11:

```sh
swift test --filter LabanRendererTests
swift format lint --strict Sources/LabanRenderer/SoftwareRenderer.swift Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/TextDecorationLayout.swift Tests/LabanRendererTests/TextDecorationLayoutTests.swift
git diff --check
```

All completed commands exited 0. The selected renderer test run executed 31
tests with 0 failures.

## Idempotence and Recovery

The change is source-only. If the helper causes rendering drift or compile
failures, restore the previous renderer-local decoration functions and rerun the
same renderer tests. The helper file can be safely deleted if no renderer calls
it.
