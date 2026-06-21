# 25. CJK Font Pairing Uses Explicit System Fallback With Fixed Cell Metrics

Date: 2026-06-21

## Status

Accepted. Implementation tracked in
`execplans/active/chinese-text-and-terminal-trust-gate.md` Milestone 2.

## Context

Laban's terminal cell metrics come from the primary terminal font, currently the
user-selected font or bundled JetBrains Mono. That is correct for Latin
monospace text, but JetBrains Mono does not cover Chinese/Japanese/Korean (CJK)
ideographs. Before this ADR, CJK glyphs reached CoreText's implicit cascade in
the software fallback path and in `MetalGlyphAtlas`. That made the chosen CJK
font and its natural advance invisible to `/debug/atlas`, and it gave the Metal
atlas no explicit policy for keeping a proportional CJK fallback inside the two
terminal columns assigned by the terminal core.

ADR 0021 remains the width authority: libghostty decides whether a grid glyph is
one or two terminal cells. This ADR does not add a Swift width model. It only
chooses the font used when the primary terminal font lacks CJK coverage and
defines how renderers fit that glyph inside the cells the engine already
assigned.

Candidate CJK pairings considered for simplified Chinese developer workflows:

- PingFang SC: system font on macOS, available without bundling, high-quality
  Hanzi rendering, not monospaced.
- Noto Sans Mono CJK SC: terminal-friendly and monospaced, but not installed by
  default and large to bundle.
- Sarasa Term/Mono/Gothic SC: terminal-friendly and designed for Latin/CJK
  pairing, but not installed by default and large to bundle.

## Decision

Laban uses an explicit CJK fallback cascade shared by the software and Metal
renderers:

1. primary terminal font;
2. available CJK candidates in this order: PingFang SC, Noto Sans Mono CJK SC,
   Sarasa Term SC, Sarasa Mono SC, Sarasa Gothic SC;
3. CoreText's remaining cascade as a final fallback.

The default shipped policy relies on system PingFang SC. Laban does not bundle a
CJK font and does not add a CJK font picker in this milestone.

The Metal glyph atlas treats a single CJK `Character` as a two-cell tile when it
rasterizes the glyph. The tile's logical width is exactly `2 * cellWidth`; if a
fallback font's natural layout or ink bounds exceed that width, the atlas scales
the glyph horizontally down to fit. It does not scale narrower CJK glyphs up, so
system glyph shape stays crisp. Baseline remains the primary terminal font's
baseline because the atlas still draws at the same renderer descent.

`GET /debug/atlas` reports the selected CJK font, candidate list, fallback
order, glyph availability, natural advance, target two-cell width, and any
horizontal scale factor. This makes font pairing and metric drift observable in
headless tests.

## Consequences

- Chinese text no longer silently depends on CoreText's default cascade. The
  fallback order is deterministic and shared by software, classic Metal, and
  GPU-driven cell rendering.
- Non-CJK primary-font behavior is unchanged. ASCII and terminal UI fallback
  symbols continue through the existing primary/monospaced-symbol policy.
- PingFang SC is proportional, so some Hanzi ink can be narrower than two
  terminal cells. Laban preserves that shape rather than stretching it; the
  terminal core's two-cell occupancy remains authoritative.
- Bundling Noto or Sarasa is deferred until evidence shows PingFang SC is not
  good enough. Adding a user-selectable CJK font is product/settings scope and
  needs a separate plan.

## Applies To New Code

- Renderer code that needs a fallback line for CJK must use
  `TerminalGlyphFallback`/`TerminalCJKFontPolicy`, not a separate CoreText
  cascade.
- New glyph atlas paths must preserve the engine-assigned terminal cell count:
  CJK fallback ink may be clipped or scaled down to fit the assigned cells, but
  it must not expand the terminal grid or create a second width truth.
- Debug surfaces that report font metrics should include the CJK pairing when
  the primary terminal font lacks CJK coverage.
