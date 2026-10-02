# 38. Slug Text Blends in Gamma Space

Date: 2026-10-02

## Status

Accepted. Reverses the linear-light text composite that ADR 0027's
implementation plan (`execplans/active/slug-glyph-renderer.md` M2) adopted for
Slug as "gamma-correct compositing". Solids, images, color emoji, raster
fallback glyphs, and the translucent-surface path are unchanged. Implementation
and measurements are in `execplans/active/slug-text-gamma-blend.md`.

## Context

Slug computes exact area coverage for each pixel and composited it with
ordinary source-over in linear light (the target is `bgra8Unorm_srgb`, so the
fixed-function blend runs on linearized values). Linear-light blending is
physically correct for opaque surfaces, but text is perceived thinner on
light backgrounds and heavier on dark ones when its antialiased edges are
mixed that way. CoreText, the project's reference (`SoftwareBackend`, reported
as `nativePlatformReference`), blends its glyph masks in an encoded space, so
its text keeps the same weight in both polarities.

Measured against `SoftwareBackend` at text weight 1.0 (ink = total luma
deviation from the background, Slug divided by CoreText, grayscale):

- Dark text was 0.75 to 0.95 of CoreText's ink at every size and scale.
- Light and mid-gray text on dark backgrounds was up to 1.44 at 1x, 9 pt.

The stem-darkening dilation added in
`execplans/active/slug-text-weight-geometric-dilation.md` is color
independent, so it could only trade one polarity against the other. That plan
recorded this as an inherent limit. It was really the blend space.

## Decision

On GPUs with programmable blending (every Apple GPU family), Slug's opaque
text pipelines read the destination with framebuffer fetch and blend in a
fixed power space:

    out = decode(mix(encode(dst), encode(fg), coverage)),
    encode(x) = x^(1/1.8), decode(x) = x^1.8

- The exponent `kSlugTextBlendGamma` is 1.8, a measured best fit across
  9 to 24 pt at 1x and 2x and five foreground/background pairs. 1.0 is the old
  linear-light behavior. 2.2 (approximately sRGB) over-inks dark text.
- Grayscale text uses `slugGlyphGammaBlendFragment` with blending disabled.
  Spinner-motion glyphs use the same fragment. The RGB-subpixel path replaces
  its darken + additive composite pair with a single
  `subpixelCompositeGammaFragment` pass over the same accumulation textures.
  Zero-coverage pixels return the destination unchanged.
- The two fragments compile only when `SlugGlyphRenderer` defines
  `LABAN_SLUG_FRAMEBUFFER_FETCH`. Other GPUs (Intel/AMD Macs) keep the
  linear-light pipelines.
- `RendererStatus.textCompositeModel` reports the new `gammaBlend` case when
  the gamma pipelines are active and `linearLight` otherwise.
- The dilation table gains entries below 18 px per em (9 px: 0.08, 11 px: 0.12,
  14 px: 0.16), recalibrated under the new blend. Only gamma-blended text
  uses them: linear-light text (Intel, translucent surfaces) keeps the old
  clamp to the 18 px entry. Entries from 18 px up are unchanged because they
  were already the best fit.

## Consequences

- Text weight is consistent across polarity and display density. Every
  measured cell lands within 0.88 to 1.10 of CoreText (it was 0.75 to 1.44),
  and mean per-pixel error on the text footprint drops from 27.9 to 23.1 luma
  levels. `SlugWeightCoreTextParityTests` now gates the size/scale/polarity
  sweep.
- Intel Macs render Slug text as before. Their text is lighter on light
  backgrounds than on Apple silicon, and `textCompositeModel` says which path
  is running.
- The translucent-surface path (ADR 0028) still blends text in linear light
  into its premultiplied `rgba16Float` working target. Gamma blending
  a partially transparent destination needs a defined unpremultiply rule, and
  that is separate work.
- The two-pass coverage-cache fallback, used only when the accumulation
  textures cannot be allocated, stays linear.

## Applies To New Code

A new Slug pipeline that composites glyph coverage over an opaque target must
use the gamma-blend fragments when `glyphGammaBlendPipeline` is non-nil,
because a linear-light glyph pass would draw visibly lighter or heavier text
than its neighbors. Keep `kSlugTextBlendGamma` and the dilation table
calibrated together. Changing either one means re-running the sweep in the
ExecPlan.
