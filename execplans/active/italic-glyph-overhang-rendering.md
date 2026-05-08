# Fix Italic Glyph Overhang Rendering

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Italic terminal text should look like normal terminal text with a slanted face,
not like cropped or damaged glyphs. Laban already preserves SGR italic state in
frame commands. The remaining problem is in renderer glyph geometry: italic
glyphs can have ink that extends slightly left or right of the fixed cell
advance. The Metal glyph atlas must allocate that ink area and place the quad
so the glyph baseline still starts at the terminal cell.

## Progress

- [x] Reproduced with a fresh headless debug server started from the current
      build. Injected SGR italic output through `/debug/actions` and confirmed
      `/debug/frame-commands` emits `attributes: ["italic"]` and
      `["bold", "italic"]`.
- [x] Found that the fresh headless process uses the software renderer, so the
      debug screenshot proves attribute plumbing but not the production Metal
      glyph atlas behavior.
- [x] Inspected CoreText metrics for the current JetBrains Mono italic face:
      some italic glyphs, such as `%`, have negative left ink and right ink
      beyond the 9 px fixed cell.
- [x] Add renderer regression coverage for Metal atlas italic overhangs. The
      test failed before the fix with `entry.pixelWidth == 9`.
- [x] Patch Metal glyph atlas entries to carry a logical x offset and reserve
      left/right ink slop.
- [x] Patch fake italic shear direction so deterministic fallback leans right.
- [x] Run focused renderer tests and a fresh process smoke check.
- [x] Run the repository check gate.

## Outcomes & Retrospective

Metal atlas entries now reserve ink that extends outside the fixed terminal
cell and carry a logical x offset so the wider tile is positioned relative to
the original cell origin. Fake italic fallback now leans right in both renderer
backends. `./scripts/check` passes after the change.

## Surprises & Discoveries

- Observation: `CTFontCreateCopyWithSymbolicTraits` can resolve the bundled
  regular JetBrains font to installed user fonts such as
  `~/Library/Fonts/JetBrainsMonoNerdFont-Italic.ttf`.
  Evidence: a local CoreText probe returned `JetBrainsMonoNF-Italic` with that
  file path when asking for italic traits from the bundled regular font.
- Observation: the attribute pipeline is not the bug. Fresh debug-server output
  showed separate terminal glyph runs for plain, italic, and bold-italic text,
  with the expected attribute arrays.

## Context and Orientation

`Sources/LabanRenderer/SoftwareRenderer.swift` draws software/headless glyphs
directly with CoreText. `Sources/LabanRenderer/MetalGlyphAtlas.swift`
rasterizes one character cluster into an alpha texture, and
`Sources/LabanRenderer/MetalRenderer.swift` places the atlas tile at the
terminal cell origin. A terminal cell is fixed-width, but a glyph's visible ink
can extend outside that width. The atlas entry therefore needs both a tile size
and a logical x offset saying where to place that tile relative to the cell.

## Plan of Work

Add a Metal atlas regression test that creates a real italic CoreText font,
asks the atlas for an overhanging glyph, and asserts the atlas entry is wider
than the fixed cell and starts before the cell origin. Then update
`MetalGlyphAtlas.Entry` to include `logicalOriginX`, compute simple glyph ink
bounds with `CTFontGetBoundingRectsForGlyphs`, allocate left and right slop,
draw the glyph shifted inside the tile, and make `MetalRenderer.appendGlyph`
apply the entry's x offset. Finally, change fake italic shear from left-leaning
to right-leaning in both renderers so fallback italic has normal visual
direction.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk swift test --filter MetalRendererSmokeTests
rtk swift test --filter LabanRendererSmokeTests
rtk ./scripts/check
```

Acceptance is that the new Metal atlas test fails before the code change and
passes after it, existing renderer smoke tests remain green, and a fresh
debug-server run still shows italic SGR attributes in frame commands.
