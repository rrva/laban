# Render Fallback Script Glyphs In Metal

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Users who paste Arabic presentation-form characters such as `ﺱ` or Hangul text such as `니은` should see the characters, not blank cells. The terminal core already preserves the text in `FrameCommand.glyphRun`; this change makes the Metal glyph atlas draw characters that the primary JetBrains Mono font does not contain by using Core Text fallback shaping instead of skipping them.

## Progress

- [x] Read `MetalRenderer` glyph-run batching and `MetalGlyphAtlas` cache/rasterization.
- [x] Read software renderer fallback behavior for Core Text-drawn clusters.
- [x] Add a Metal regression test where Arabic/Hangul text changes the rendered PNG.
- [x] Replace scalar-only atlas lookup with character-cluster atlas entries.
- [x] Use Core Text line drawing for clusters or missing-glyph scalars so macOS font fallback can supply Arabic, Hangul, non-BMP, combining, and ZWJ glyphs.
- [x] Stop caching failed atlas entries as permanent blanks.
- [x] Run focused renderer tests and the full package suite.

## Context and Orientation

`Sources/LabanCore/FrameProducer.swift` emits visible terminal text as `FrameCommand.glyphRun` values. A glyph run carries a Swift `String`, and iterating that string by `Character` yields user-perceived clusters such as one Hangul syllable, one Arabic presentation-form character, or one emoji ZWJ sequence. `Sources/LabanRenderer/MetalRenderer.swift` consumes those runs and asks `Sources/LabanRenderer/MetalGlyphAtlas.swift` for one atlas tile per character. Before this change, the Metal path only accepted clusters with exactly one Unicode scalar, rejected scalars above `UInt16.max`, and cached `nil` atlas entries. That made unsupported glyphs render as spaces forever. The software renderer already falls back to `CTLineDraw` for clusters the primary font cannot draw.

## Plan of Work

Add a focused Metal smoke test in `Tests/LabanRendererTests/MetalRendererSmokeTests.swift` that renders a plain background, captures the PNG, then renders the same background plus `ﺱ니은` and asserts the PNG changes. This test fails when Metal skips all fallback glyphs.

Change `MetalGlyphAtlas` so its cache key is a `String` character cluster rather than a single scalar. Keep the fast path for a single BMP scalar present in the selected font, but fall back to a Core Text line for missing glyphs and multi-scalar clusters. The fallback line is drawn into the same alpha atlas texture and tinted by the existing Metal glyph shader. Store only successful entries in the cache; a failed pack or draw should be retried after atlas rebuilds instead of becoming a permanent blank.

Update `MetalRenderer` to pass each `Character` to the atlas. Existing cell positioning stays anchored to `FrameProducer` run origins and per-cell advances.

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter MetalRendererSmokeTests
rtk swift test
```

Acceptance: the new Metal smoke test proves `ﺱ니은` changes the rendered PNG from a blank background on systems with Metal. The full suite remains green.

Validated on 2026-05-05:

```sh
rtk swift test --filter MetalRendererSmokeTests/testMetalRendererDrawsFallbackArabicAndHangulGlyphs
rtk swift test --filter MetalRendererSmokeTests
rtk swift test --filter LabanRendererTests
rtk swift test
```
