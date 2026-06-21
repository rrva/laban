import CoreGraphics
import CoreText
import Foundation

enum ColorGlyphSupport {
  static func shouldRenderColor(
    text: String,
    font: CTFont,
    cellAdvance: CGFloat,
    mode: EmojiRenderingMode = EmojiRenderingSettings.current()
  ) -> Bool {
    guard mode == .color else { return false }
    return containsColorGlyph(text: text, font: font, cellAdvance: cellAdvance)
  }

  static func containsColorGlyph(
    text: String,
    font: CTFont,
    cellAdvance: CGFloat
  ) -> Bool {
    guard !text.isEmpty else { return false }
    let line = TerminalGlyphFallback.fallbackLine(
      text: text,
      font: font,
      cellAdvance: cellAdvance,
      foreground: nil)
    return lineContainsColorGlyph(line, text: text)
  }

  /// Cheap, allocation-free pre-filter. A scalar can only contribute a color
  /// glyph if it is the emoji presentation selector, sits in the emoji/
  /// pictograph/dingbat blocks, or has the Unicode Emoji_Presentation property.
  /// Anything below U+203C (all ASCII and Latin text) is rejected with a single
  /// integer compare, so plain-text scrolling pays nothing. This is a superset
  /// of the cases where `containsColorGlyph` can return true, so callers that
  /// skip the CoreText path when this is false do not change the final result.
  @inline(__always)
  static func scalarMayBeColor(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    if v < 0x203C { return false }
    if v == 0xFE0F { return true }
    if (0x1F000...0x1FAFF).contains(v) || (0x2600...0x27BF).contains(v) { return true }
    return s.properties.isEmojiPresentation
  }

  @inline(__always)
  static func clusterMayBeColor(_ cluster: Character) -> Bool {
    for s in cluster.unicodeScalars where scalarMayBeColor(s) { return true }
    return false
  }

  /// Cheap per-run gate: true if any cluster in the run could be a color glyph.
  /// Superset of `containsColorGlyph`, so a false result safely skips the
  /// per-cluster CoreText decision for the whole run.
  @inline(__always)
  static func mayContainColorGlyph(text: String, font: CTFont) -> Bool {
    if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return true }
    for s in text.unicodeScalars where scalarMayBeColor(s) { return true }
    return false
  }

  static func logicalTileWidth(
    text: String,
    typographicWidth: CGFloat,
    cellAdvance: CGFloat
  ) -> CGFloat {
    let width = max(typographicWidth, 0)
    if containsEmojiPresentationScalar(text) || width > cellAdvance * 1.5 {
      return cellAdvance * 2
    }
    return max(cellAdvance, width)
  }

  static func typographicWidth(_ line: CTLine) -> CGFloat {
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    return max(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)), 0)
  }

  static func containsEmojiPresentationScalar(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0xFE0F,  // emoji presentation variation selector
        0x1F000...0x1FAFF,  // emoji, pictographs, symbols, flags
        0x2600...0x27BF:  // misc symbols and dingbats that may color-fallback
        return true
      default:
        continue
      }
    }
    return false
  }

  private static func lineContainsColorGlyph(_ line: CTLine, text: String) -> Bool {
    let runs = CTLineGetGlyphRuns(line) as NSArray
    for case let run as CTRun in runs {
      let attrs = CTRunGetAttributes(run) as NSDictionary
      guard let rawFont = attrs[kCTFontAttributeName] else { continue }
      let runFont = rawFont as! CTFont
      if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) {
        return true
      }
      if containsEmojiPresentationScalar(text), runContainsBitmapGlyph(run, font: runFont) {
        return true
      }
    }
    return false
  }

  private static func runContainsBitmapGlyph(_ run: CTRun, font: CTFont) -> Bool {
    let count = CTRunGetGlyphCount(run)
    guard count > 0 else { return false }
    var glyphs = [CGGlyph](repeating: 0, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    for glyph in glyphs where glyph != 0 {
      if CTFontCreatePathForGlyph(font, glyph, nil) == nil {
        return true
      }
    }
    return false
  }
}
