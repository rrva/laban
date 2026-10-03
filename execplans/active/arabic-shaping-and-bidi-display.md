# Arabic Joining and Right-to-Left Display

This ExecPlan is a living document. Keep `Progress`, `Decision Log`, and
`Surprises & Discoveries` current as work proceeds. Follow `PLANS.md`.

## Purpose

Before this change Laban drew every terminal cell on its own and always left to
right. Arabic text therefore showed each letter in its isolated form (`سلام`
read as four separate letters) and in logical order, so Arabic and Hebrew words
appeared backwards. After this change, a line containing right-to-left text is
displayed in visual order using the Unicode Bidirectional Algorithm ("BiDi":
the rules that decide which stretches of a mixed line read right to left), and
Arabic letters inside those stretches join into their contextual forms. The
cursor, selection, find highlights, and mouse clicks follow the visual layout.

To see it: run Laban (Slug renderer, the default) and `printf 'abc سلام 123 שלום\n'`.
Before: `abc ﺱ ﻝ ﺍ ﻡ 123 ש ל ו ם` (isolated, logical order). After: `abc` on
the left, then `שלום` and `سلام` mirrored into right-to-left order with the
Arabic letters joined, and `123` in its natural left-to-right order between
them as BiDi dictates.

## Terms

- Logical order: the order characters were written to the terminal; this is
  what the terminal engine (libghostty-vt, see `docs/adr/0001-*`) stores per
  row, one grapheme per cell.
- Visual order: the left-to-right order in which cells appear on screen.
- RTL run: a maximal stretch of a row whose cells BiDi resolves to an odd
  embedding level (right to left). Its cells are drawn mirrored.
- Implicit BiDi: the terminal reorders each row for display on its own; the
  application keeps writing logical text. This is the default mode recommended
  for terminal emulators (VTE does the same). Applications that do their own
  BiDi can be served by turning the setting off.
- Glyph run: `FrameCommand.glyphRun` in `Sources/LabanRenderer/FrameCommand.swift`,
  a string of cells drawn left to right from `origin`, one Swift `Character`
  per engine cell (see `FrameProducer` engine-column invariant).

## Orientation

- `Sources/LabanCore/FrameProducer.swift` turns a terminal snapshot into frame
  commands: background rects (Pass 1), selection/find rects, glyph runs
  (`appendFastTerminalGlyphRuns` on macOS 26, `appendLegacyTerminalGlyphRuns`
  otherwise), procedural box/block rects, and the cursor. A second overload
  handles remote (laband ring) snapshots (`LabandSnapshotResponse`).
- Renderers draw glyph runs: Slug (`SlugGlyphRenderer.appendGlyphRun`, the
  default), software (`SoftwareRenderer`), classic Metal (`MetalRenderer`).
  Each places `Character` i at `origin.x + i * cellWidth`.
- Mouse-to-cell conversion: `TerminalSelectionInput.terminalCell(at:geometry:)`
  in `Sources/LabanApp/TerminalSelectionInput.swift`.

## Design

1. `Sources/LabanCore/TerminalBidi.swift` (new): given one row's cells in
   logical order (start column, width, text), returns, for every column, the
   visual column it is drawn at and whether it is in an RTL run. It builds a
   CoreText line (`CTLine`) for the row text with a left-to-right base
   paragraph direction, walks the line's runs in visual order, and assigns
   visual columns cumulatively by cell width; RTL runs list their cells in
   reverse logical order. Rows without any strong right-to-left character
   (Hebrew, Arabic, Syriac, Thaana, N'Ko, and their presentation forms) are
   skipped with a cheap byte-level gate. Layouts are cached by row content.
2. `TextAttributes.rightToLeft` (new bit 15): a layout attribute set only by
   `FrameProducer` on glyph runs whose cells are mirrored. A renderer places
   `Character` i of such a run at `origin.x + (count - 1 - i) * cellWidth`.
   FrameProducer guarantees every cell of an RTL run is one column wide (a wide
   cell becomes its own run).
3. FrameProducer, for rows that need BiDi: background rects, glyph runs,
   procedural cells and the cursor use visual columns; selection and find
   rects are re-cut per cell at visual columns.
4. Slug joining: for an RTL run containing joining-script letters (Arabic,
   Syriac, N'Ko, Mongolian), Slug shapes the whole run with CoreText (the
   fallback cascade picks an Arabic font), and draws the shaped glyphs at their
   CoreText positions scaled horizontally so the run exactly fills its cells.
   CoreText already lays an RTL line out right to left, so joins connect.
5. Mouse: `TerminalSurfaceController` keeps the last frame's per-row
   visual→logical maps; `TerminalSelectionInput` converts a clicked visual
   column to its logical column before selecting.
6. Setting: `BidiDisplaySettings` (UserDefaults key `LabanBidiDisplay`,
   default on), read when the frame producer is built; off restores the old
   strictly left-to-right display.

## Progress

- [x] TerminalBidi layout + tests (`TerminalBidiTests`)
- [x] TextAttributes.rightToLeft; producer RTL rows (local + remote): backgrounds, runs, procedural, cursor (`FrameProducerBidiTests`)
- [x] Renderers: mirrored placement (Slug, software, Metal); Slug joining for Arabic RTL runs (`testSlugJoinsArabicLettersInRightToLeftRun`, headless screenshot)
- [x] Selection/find visual rects; mouse visual→logical (`testLogicalColumnForClickOnBidiRow`)
- [x] Setting (Settings > Rendering checkbox, live observer)
- [ ] `./scripts/check`, PR, review

## Decision Log

- Implicit BiDi with a left-to-right base paragraph direction, on by default,
  as VTE does; a checkbox turns it off for programs that reorder text
  themselves. Mouse reports to applications are not remapped.
- Joining is done only for right-to-left runs, by shaping the run as one
  CoreText line squeezed into its cells. Without BiDi the letters would join
  on the wrong sides, so per-cell drawing is kept when the setting is off.
- The GPU-cell renderer path (`overlayCommands`, not the default) is not
  BiDi-aware.

## Surprises & Discoveries

- CoreText returns a line's runs in visual order with a right-to-left status
  per run, which is all the row layout needs; no separate BiDi library is
  required.

## Validation and Acceptance

- `swift test --filter TerminalBidiTests`: layout of `abc שלום 123` puts `abc`
  at columns 0-2, the Hebrew letters mirrored, digits left to right.
- `swift test --filter FrameProducerTests`: an RTL row emits a
  `.rightToLeft` run at the visual origin, the cursor at the visual column, and
  backgrounds at visual columns.
- Slug test: `سلام` drawn as an RTL run has fewer, wider ink components than
  the same letters drawn isolated (letters connect).
- Headless Slug screenshot of `printf 'abc سلام 123 שלום'` shows joined,
  mirrored Arabic and mirrored Hebrew.
- `./scripts/check` passes.
