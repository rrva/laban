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
