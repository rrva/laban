# Draw programming-font ligatures in the Slug renderer

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

Programming fonts like the bundled JetBrains Mono ship *ligatures*: joined
glyphs that draw operators such as `->`, `!=`, `===`, `<=>`, `|>`, and `//` as
one connected shape. The MVP drew one plain glyph per character, so `->` always
looked like a hyphen beside a greater-than sign.

After this change, a user on the Slug Glyph renderer (the default renderer,
ADR 0032) sees those operators drawn as ligatures, controlled by **Settings ▸
Rendering ▸ Font ligatures**. Nothing else on screen moves: every character
still occupies exactly one terminal cell, so the cursor, selection, copy, find,
and the text that follows an operator stay where they were. The setting ships
on, applies live without a relaunch, and other renderers ignore it.

To see it working without a display, run the headless agent described under
*Validation and Acceptance*. `/debug/render` reports `"ligatureGlyphs": 9`
for the fixture, and the screenshot shows joined arrows.

## Orientation

A few terms used below:

- **Cell.** One slot of the terminal grid. A *glyph run* is the
  `FrameCommand.glyphRun` command that `Sources/LabanCore/FrameProducer.swift`
  emits for a stretch of same-style cells in one row. Its `text` holds one
  Swift `Character` per cell, and a wide character always ends its run.
- **Glyph id.** A font's internal number for a drawable shape. *Shaping* is
  CoreText (`CTLine`) deciding which glyph ids to draw for a string, including
  substitutions such as ligatures.
- **Slug.** `Sources/LabanRenderer/SlugGlyphRenderer.swift`. It draws each
  glyph from size-independent outline curves. Geometry is cached per
  (PostScript name, glyph id) in `geometryEntry(font:glyph:)`, and each glyph
  instance is placed at its cell origin plus the outline's own bounds, so a
  glyph whose ink reaches left of its cell draws correctly.

How JetBrains Mono ligatures shape (measured with `CTLine`):

    "->"   -> [SPC, hyphen_greater.liga]           liga bounds x = -6..6 at 13pt
    "==="  -> [SPC, SPC, equal_equal_equal.liga]   liga bounds x = -14..6
    "abc"  -> [a, b, c]                            unchanged

The font keeps one glyph per character. Each consumed character becomes an
empty spacer glyph (`SPC`, no outline), and the last character becomes a wide
glyph that reaches back over the spacers. So the grid never needs to change:
draw each cell's *shaped* glyph id at that cell's origin.

## Design

- `Sources/LabanRenderer/FontLigatureSettings.swift` holds the setting:
  - user default `LabanFontLigaturesEnabled` (default on);
  - environment override `LABAN_FONT_LIGATURES` for headless runs; while it
    is set, `setEnabled` refuses writes;
  - `didChangeNotification`.
- `Sources/LabanRenderer/TerminalLigatureShaper.swift` does the shaping.
  - `mayContainLigature(_:)` is the per-frame gate: it returns true when the
    text has two adjacent ASCII punctuation/symbol bytes.
  - `shape(text:font:)` runs `CTLine` once and maps each shaped glyph back to
    a cell through `CTRunGetStringIndices`. It returns one
    `TerminalLigatureCell` per `Character`: `.nominal` (draw as usual),
    `.glyph(id)` (draw this id at the cell origin), or `.empty` (consumed by
    a ligature in a font whose ligature has fewer glyphs than characters).
    It returns `nil` when nothing changed.
  - Only single-ASCII-scalar cells shaped in the run's own font are
    substituted. CoreText x positions are ignored.
- `SlugGlyphRenderer` changes:
  - `appendGlyphRun` asks `ligatureCells(for:...)` for the run.
  - That method caches shaping per (interned font id, text) in
    `ligatureShapeCache`, which is bounded at 4096 entries and cleared
    wholesale when full.
  - Substituted ids resolve through `ensureLigatureGlyph`, cached per
    (font id, glyph id). An id with no outline (`SPC`) draws nothing; it never
    falls back to the raster path, which would wrongly draw the original
    character.
  - The instance-building code was lifted into a local `appendSlugGlyph`
    shared by both paths.
  - `refreshFontLigatures()` re-reads the setting.
  - `RendererStatus.ligatureGlyphs` counts substituted glyphs drawn in the
    last frame's damaged area.
- Wiring:
  - `TerminalBitmapView` observes `FontLigatureSettings.didChangeNotification`,
    calls `refreshFontLigatures()` on a Slug backend, and sets
    `renderInvalidated`, which forces a full-damage repaint.
  - `SettingsWindowController` adds the **Font ligatures** checkbox, enabled
    only when Slug is selected and the env override is unset.
  - `/debug/render` (`Sources/LabanDebug/DebugRenderEndpoints.swift`,
    `schemas/debug/render.schema.json`) gains `ligatureGlyphs`.
  - The headless runtime reads the setting when the renderer is created; the
    env override covers fixture runs.

## Decision Log

- Decision: Slug-only and opt-in (default off).
  Rationale: Slug already keys geometry by glyph id and places glyphs by
  outline bounds. Classic and GPU-cell Metal key atlases by text and font
  object, and GPU-cell rejects glyphs wider than 2.5 cells, which `===`
  exceeds. Default-off follows the opt-in posture of ADR 0030 and ADR 0031 and
  keeps the MVP rendering contract (`mvp.md`: "no ligatures") as the shipped
  default. Recorded in `docs/adr/0037-font-ligatures-are-a-slug-capability.md`.
  Date/Author: 2026-10-01 / Claude.
- Decision: Flip the default to on (supersedes the default-off half above).
  Rationale: After shipping, the user asked for ligatures as the default look.
  The setting still turns them off, and non-Slug renderers are unaffected.
  Date/Author: 2026-10-01 / Claude, at the user's request.
- Decision: Place substituted glyphs at their own cell origin and ignore
  CoreText positions.
  Rationale: Cells are `ceil(advance)` wide (9pt for an 8.4pt advance at
  14pt), so CoreText positions drift from the grid by 0.6pt per cell. Cell
  placement keeps every glyph, ligature or not, on the same grid. The cost is
  that a ligature's left end stops about 0.6pt per spanned cell short of the
  first cell's left edge, which is invisible at normal sizes.
  Date/Author: 2026-10-01 / Claude.
- Decision: Gate shaping on adjacent ASCII punctuation; letter ligatures
  (`fi`, `www`) are out of scope.
  Rationale: Every JetBrains Mono ligature is punctuation. The gate keeps
  CoreText and the cache lookup off ordinary text, honoring the rule that the
  per-frame encode path must not run `CTLine` work per cell
  (`docs/process/agent-operating-guide.md`).
  Date/Author: 2026-10-01 / Claude.

## Progress

- [x] (2026-10-01) Measured JetBrains Mono shaping with a CoreText probe:
  `calt` keeps one glyph per character, spacer plus wide glyph.
- [x] (2026-10-01) `FontLigatureSettings` and `TerminalLigatureShaper`, with
  unit tests.
- [x] (2026-10-01) Slug integration (`ligatureCells`, `ensureLigatureGlyph`,
  shared `geometryEntry`, `ligatureGlyphs` status), with pixel tests.
- [x] (2026-10-01) Live settings observer, Settings checkbox, `/debug/render`
  field and schema.
- [x] (2026-10-01) Headless debug-server verification with
  `fixtures/font-ligatures.fixture.json`.
- [x] (2026-10-01) Docs: ADR 0037, `spec.md` §19, `mvp.md` note, fixture
  index.
- [ ] Break a ligature at the cursor cell (ghostty-style) so a block cursor
  over `-` of `->` shows the plain characters. Not required for the
  first version.

## Validation and Acceptance

Unit and pixel tests (expect all to pass; the Slug tests skip without Metal):

    cd /Users/rrj/wrk/laban   # repository root
    swift build --build-tests
    swift test --skip-build --filter "SlugLigatureTests|TerminalLigatureShaperTests|FontLigatureSettingsTests"
    # Executed 12 tests, with 0 failures

They check four things:

- `->` draws exactly one ligature glyph that covers both cells and nothing
  beyond them.
- A run with nothing to ligate (`hello, world - > fi`) renders a
  byte-identical PNG with the setting on and off.
- The cached frame reproduces the cold frame.
- `refreshFontLigatures()` toggles a live renderer.

The whole renderer suite must stay green:

    swift test --skip-build --filter LabanRendererTests
    # Executed 402 tests, with 3 tests skipped and 0 failures

End-to-end through the headless runtime, on Slug, with the setting on via the
env override. Start the agent from the repository root after
`swift build --build-tests`:

    LABAN_FONT_LIGATURES=1 .build/debug/laban-agent --headless --debug-server \
      --fixture=fixtures/font-ligatures.fixture.json --artifacts=/tmp/lig \
      --temp-dir=/tmp/lig/tmp --renderer=slugGlyph
    # stdout: {"debugServer":"<sock>","debugToken":"<tok>",...}
    curl -s --unix-socket <sock> -H "Authorization: Bearer <tok>" http://localhost/debug/render
    # ... "effectiveRenderer":"slugGlyph", "ligatureGlyphs":9 ...
    curl -s --unix-socket <sock> -H "Authorization: Bearer <tok>" http://localhost/debug/screenshot -o shot.png
    # shot.png shows joined arrows, != as a slashed equals, === as one bar group

Running the same command with `LABAN_FONT_LIGATURES=0` reports
`"ligatureGlyphs":0`.

In the app, go to Settings ▸ Rendering with Slug Glyph selected; **Font
ligatures** is checked by default and `a -> b != c` shows joined operators.
Unchecking reverts them live, and rechecking restores them.

## Outcomes & Retrospective

Shipped behind an off-by-default setting on Slug. The grid model needed no
changes, because programming fonts already keep one glyph per character; the
work was caching shaping and resolving by glyph id. The open follow-up is
splitting a ligature at the cursor cell.
