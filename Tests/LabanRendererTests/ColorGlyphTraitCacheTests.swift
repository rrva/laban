import CoreText
import XCTest

@testable import LabanRenderer

/// The vector renderer caches each styled font's color-glyph trait alongside the
/// font variant, so the per-frame encode path uses `textMayContainColor(text:
/// fontHasColorTrait:)` instead of probing `CTFontGetSymbolicTraits` per run.
/// These tests pin that the cached-trait gate is equivalent to the original
/// CoreText-probing `mayContainColorGlyph`, so the hoist changed cost, not
/// behavior.
final class ColorGlyphTraitCacheTests: XCTestCase {
  private let monoFont = CTFontCreateWithName("Menlo" as CFString, 14, nil)
  private let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, 14, nil)

  func testCachedTraitMatchesCoreTextProbeForMonochromeFont() {
    let trait = ColorGlyphSupport.fontHasColorGlyphTrait(monoFont)
    XCTAssertFalse(trait, "Menlo is not a color-glyph font")
    for text in ["", "0/0", "12/3400", "abcDEF", "→ ✓ ░", "😀"] {
      XCTAssertEqual(
        ColorGlyphSupport.textMayContainColor(text: text, fontHasColorTrait: trait),
        ColorGlyphSupport.mayContainColorGlyph(text: text, font: monoFont),
        "cached-trait gate must equal the CoreText-probing gate for \(text.debugDescription)")
    }
  }

  func testCachedTraitMatchesCoreTextProbeForColorFont() {
    let trait = ColorGlyphSupport.fontHasColorGlyphTrait(emojiFont)
    // Apple Color Emoji carries the color-glyph trait, so every run short-circuits
    // to true regardless of content — including plain digits.
    XCTAssertTrue(trait, "Apple Color Emoji must report the color-glyph trait")
    for text in ["", "12/3400", "😀"] {
      XCTAssertTrue(
        ColorGlyphSupport.textMayContainColor(text: text, fontHasColorTrait: trait),
        "a color-glyph font gates every run as may-be-color")
      XCTAssertEqual(
        ColorGlyphSupport.textMayContainColor(text: text, fontHasColorTrait: trait),
        ColorGlyphSupport.mayContainColorGlyph(text: text, font: emojiFont))
    }
  }

  func testTraitFalseDefersToScalarPrefilter() {
    // With the trait known false, the gate must reduce to the cheap scalar
    // pre-filter: plain text is rejected, an emoji scalar is admitted.
    XCTAssertFalse(
      ColorGlyphSupport.textMayContainColor(text: "487 / 2205", fontHasColorTrait: false),
      "plain digits in a monochrome font must not trip the color path")
    XCTAssertTrue(
      ColorGlyphSupport.textMayContainColor(text: "load: 😀", fontHasColorTrait: false),
      "an emoji scalar must still admit the run even when the font trait is false")
  }
}
