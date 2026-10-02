# 37. Font Ligatures Are a Slug Capability

Date: 2026-10-01

## Status

Accepted; amended 2026-10-01 to ship the setting on by default.
Implementation tracked in `execplans/active/font-ligatures.md`.

## Context

The MVP rendered one nominal glyph per cell with no shaping (`mvp.md`). Users
of programming fonts expect operators such as `->`, `!=`, and `===` to draw as
the font's ligature glyphs.

Programming fonts implement these ligatures as `calt` contextual alternates
that keep one glyph per character at the font's fixed advance. Shaping
JetBrains Mono with CoreText turns `->` into `[SPC, hyphen_greater.liga]`: an
empty spacer glyph, then a glyph whose outline has a negative left bearing of
about one advance, so it reaches back over the spacer's cell. `===` becomes
`[SPC, SPC, equal_equal_equal.liga]` with a two-advance overhang. So a
ligature never needs the grid to move. Each cell can keep its slot and simply
draw a different glyph id.

Every backend resolves glyphs per `Character`, and no backend shapes runs.
Adding ligatures means caching shaped glyph ids per run and drawing them by
glyph id:

- Slug's geometry is already keyed by (PostScript name, glyph id), and its
  instances are positioned from outline bounds, so negative bearings are
  free.
- Classic and GPU-cell Metal key their atlases by text and font object. Their
  GPU-cell path also rejects glyphs wider than 2.5 cells, which a 3-cell
  `===` exceeds.
- Software is a rarely used fallback.

ADR 0030 and ADR 0031 set the precedent: a capability that is cheap on Slug
and costly elsewhere ships as Slug-only rather than being forced into every
backend.

## Decision

Font ligatures are a Slug-only capability, on by default.

- **Setting.** `FontLigatureSettings` (`LabanFontLigaturesEnabled`, default
  on, so new and existing installs get ligatures until the user unchecks the
  setting; `LABAN_FONT_LIGATURES` environment override for headless fixtures).
  `SlugGlyphRenderer` caches the value and refreshes it on
  `didChangeNotification`. It never reads UserDefaults per frame.
- **Shaping.** `TerminalLigatureShaper` shapes a run once with `CTLine` and
  maps each shaped glyph back to its cell through the glyph's string index.
  Each cell gets one of three outcomes:
  - nominal: draw it as usual.
  - substituted glyph: draw it at the cell's own origin.
  - empty: the cell was consumed by a ligature that has fewer glyphs than
    characters.

  CoreText's x positions are ignored, so the grid is authoritative. Only
  cells holding a single ASCII scalar in the run's own font can be
  substituted.
- **Gate.** A run is shaped only when it has two adjacent ASCII
  punctuation/symbol characters. That excludes letter ligatures such as `fi`
  and keeps CoreText off the common path. Results are cached per (interned
  font identity, run text) in a bounded dictionary. Ligature glyph geometry
  is cached per (interned font identity, glyph id).
- **Scope.** Ligatures apply to `.terminal` and `.sidebarPreview` runs. They
  never apply to sidebar text, preedit, or spinner-motion runs, which animate
  per cell.
- **Observability.** `RendererStatus.ligatureGlyphs` and `/debug/render`
  `ligatureGlyphs` count the substituted glyphs drawn in the last frame.
  Other backends report `nil`.

## Consequences

- Slug's default output now differs from the MVP wherever an operator
  appears; the MVP "no ligatures" look is one checkbox away, and the other
  renderers keep it.
- With the setting off, Slug's output is byte-identical to before
  (`SlugLigatureTests.testRunsWithoutLigaturesRenderIdenticallyWhenEnabled`
  guards the "nothing to ligate" case even with it on).
- Classic, GPU-cell, and software renderers keep MVP glyph behavior.
  Switching renderer drops ligatures, much as it drops spinner smoothing and
  the hover preview.
- A ligature is laid out against the font's own advance, while the cell is
  `ceil(advance)` wide. At 14pt the overhang falls about 0.6pt per spanned
  cell short of the first cell's left edge. That is not visible in practice
  and is left as is.
- Ligatures split wherever the producer splits runs: at style changes,
  hyperlinks, and wide characters. They are not yet broken at the cursor cell.

## Applies To New Code

A new per-run text transformation in Slug must:

- cache CoreText work by visual font identity and text,
- keep one cell per `Character`, and
- never route an empty-outline glyph to a raster fallback.
