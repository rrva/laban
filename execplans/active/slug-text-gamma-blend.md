# Slug Text Gamma Blend

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

The Slug renderer (`slugGlyph`, the default renderer since ADR 0032) drew text
whose weight depended on its colors. Dark text on a light theme looked thin and
washed out next to the same text in Terminal.app or Laban's own CoreText
renderer. Light text on a dark theme looked bold and smeared, especially on 1x
external displays at small sizes. After this change, Slug text weighs the same
as CoreText's in both polarities, at 1x and 2x, from 9 to 24 pt.

How to see it: run the parity test below, or render the same line of text with
`slugGlyph` and `software` in light and dark themes and compare them. Before the
change, the light theme's Slug text was visibly lighter. After it, the two
match.

## Context and Orientation

- `Sources/LabanRenderer/SlugGlyphRenderer.swift` is the Slug backend. It builds
  Metal pipelines in `init` and in `ensureMotionPipelines()` (spinner motion
  glyphs, ADR 0030), and it encodes frames in `render(_:damage:)`.
- `Sources/LabanRenderer/VectorGlyphShaders.metal` holds the Slug shaders.
  `slugGlyphCoverageRGB` computes analytic per-pixel coverage (0 to 1) of a
  glyph outline. `slugGlyphAlphaFragment` turns coverage into premultiplied
  source-over color.
- The render target is `bgra8Unorm_srgb`. Metal decodes it to linear values
  before blending and encodes the result back, so fixed-function blending runs
  in **linear light**, meaning physically proportional intensity.
- `SoftwareBackend` draws text with CoreText into an sRGB bitmap. It blends the
  glyph mask in the encoded, gamma-compressed values. That backend is the
  project's quality reference.
- **Ink** is the sum over all pixels of |pixel luma minus background luma|.
  "Ink ratio" is Slug's ink divided by the software renderer's ink for the same
  text. A ratio of 1.0 means equal visual weight.
- **Dilation** (stem darkening) grows glyph outlines by a fraction of a pixel.
  Its per-size table is `SlugGlyphRenderer.dilationTable`. See
  `execplans/active/slug-text-weight-geometric-dilation.md`.
- **Framebuffer fetch** (programmable blending) lets a fragment shader read the
  current destination pixel through a `[[color(0)]]` argument. Every Apple GPU
  supports it (`device.supportsFamily(.apple1)`), and Intel/AMD Mac GPUs do not.

## The problem, measured

The sweep rendered "Hglo08B/N weight il|mw" at 9/11/13/16/20/24 pt, at scale 1
and 2, with five color pairs: theme dark-on-light (0x18222A on 0xF6EEDB), black
on white, white on black, mid-gray (0x808080 on 0x202020), and solarized
(0x839496 on 0x002B36). For each cell it computed the ink ratio and the mean
absolute luma error over the text footprint. Text weight was 1.0, grayscale.

Linear-light blend, before (selected rows):

    s2  9pt darkOnLight 0.86   blackOnWhite 0.82   lightOnDark 1.04   midGray 1.13
    s1  9pt darkOnLight 0.84   blackOnWhite 0.76   lightOnDark 1.31   midGray 1.41
    s1 13pt darkOnLight 0.81   blackOnWhite 0.75   lightOnDark 1.06   midGray 1.15
    all cells: mean |ln ratio| 0.112, mean abs error 27.9, worst 1.44 (s1 9pt solarized)

Dark text is always under-inked, and light text is over-inked. Dilation is
color independent, so it cannot fix both. The dilation plan recorded this
split as an inherent limit.

Raw ink shows the cause. With an encoded-space prototype, Slug's black-on-white
ink equals its white-on-black ink (1018 vs 1018 at 9 pt@2x), but CoreText's
are 973 vs 1171. CoreText therefore blends in a space between linear light and
full sRGB encoding.

## Decision Log

- Decision: blend opaque Slug text through a power curve with exponent 1.8,
  using framebuffer fetch. Measured alternatives (mean |ln ratio|, mean abs
  error): linear 1.0 gives 0.112/27.9; 1.4 gives 0.059/24.6; 1.6 gives
  0.046/23.7; 1.8 gives 0.040/23.4; 2.2 gives 0.052/24.2. The rejected options
  were a per-instance background color, which is wrong under selection, cursor,
  and overlays, and a foreground-luminance contrast hack, which only guesses at
  the background. Framebuffer fetch reads the actual destination.
- Decision: keep linear light on GPUs without framebuffer fetch, by compiling
  the fetch fragments only under `LABAN_SLUG_FRAMEBUFFER_FETCH`. If they were
  always compiled, the whole Slug library would fail to build on Intel and the
  renderer would fall back to classic.
- Decision: keep translucent surfaces and the coverage-cache fallback linear
  (see ADR 0038 Consequences).
- Decision: recalibrate only the small-size end of the dilation table. Under the
  1.8 blend, sweeping the dilation scale 0.25 to 1.5 found the existing table
  already optimal from 13 px per em up. 9 px per em wanted 0.5x and 11 px per em
  wanted 0.75x the clamped 0.16 px. New entries: (9, 0.08), (11, 0.12),
  (14, 0.16).

## Progress

- [x] Measure baseline ink ratios across sizes, scales, and polarities.
- [x] Prototype the encoded-space blend via framebuffer fetch and sweep its
      exponent.
- [x] Implement `slugGlyphGammaBlendFragment` and
      `subpixelCompositeGammaFragment`, and wire them into the static, motion,
      and subpixel-composite paths with the Intel fallback.
- [x] Report `TextCompositeModel.gammaBlend` in `RendererStatus`.
- [x] Recalibrate small-size dilation.
- [x] Add the sweep gate to `SlugWeightCoreTextParityTests` and confirm it fails
      under linear light (at exponent 1.0, 9 cells fail: 9 pt@1x black on white
      0.62, mid-gray 1.24).
- [x] ADR 0038.
- [x] Frame-time bench against `main`. `swift test -c release` fails to build
      on this machine for both trees ("unable to open dependencies file", which
      is environmental), so the bench ran as a debug build. The GPU work is
      identical either way because shaders are compiled at runtime. Full-screen
      frame time at three point sizes, two alternating rounds:
      this branch 17.6/22.8/22.3 and 18.2/22.4/22.7 ms, `main`
      17.2/22.3/21.9 and 17.3/22.5/23.0 ms. That is within run-to-run noise.
- [ ] `./scripts/check` green.

## Validation and Acceptance

From the repository root:

    swift test --filter SlugWeightCoreTextParityTests
    swift test --filter SlugGlyphAAFidelityTests
    swift test --filter "Slug|Spinner|HoverPreview|Ligature|Transparency"
    ./scripts/check

`testSlugInkTracksCoreTextAcrossSizesScalesAndPolarities` requires every ink
ratio for 9/13/20 pt at 1x and 2x, in four color pairs, to fall within
0.85 to 1.15. After the change, the full sweep (grayscale) measures:

    all cells 0.88-1.10, mean |ln ratio| 0.031, mean abs error 23.1
    s1  9pt darkOnLight 0.95   blackOnWhite 0.93   lightOnDark 0.96   midGray 1.08
    s2 16pt darkOnLight 0.99   blackOnWhite 0.99   lightOnDark 0.96   midGray 0.98

RGB-subpixel (`rgbStripe`) sweep: mean |ln ratio| went from 0.086 to 0.034, and
the worst cell from 1.34 to 0.87.
