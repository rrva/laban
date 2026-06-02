import CoreGraphics
import CoreText
import Foundation

enum TerminalGlyphFallback {
  private static let preferredMonospaceFallbackNames = [
    "Menlo-Regular",
    "SFMono-Regular",
    "Monaco",
    "Courier",
  ]

  static func fallbackLine(
    text: String,
    font: CTFont,
    cellAdvance: CGFloat,
    foreground: CGColor? = nil
  ) -> CTLine {
    let resolvedFont =
      preferredMonospaceFallbackFont(for: text, baseFont: font, cellAdvance: cellAdvance) ?? font
    let attrStr = NSMutableAttributedString(string: text)
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.addAttribute(
      kCTFontAttributeName as NSAttributedString.Key,
      value: resolvedFont,
      range: range
    )
    if let foreground {
      attrStr.addAttribute(
        kCTForegroundColorAttributeName as NSAttributedString.Key,
        value: foreground,
        range: range
      )
    }
    return CTLineCreateWithAttributedString(attrStr)
  }

  private static func preferredMonospaceFallbackFont(
    for text: String,
    baseFont: CTFont,
    cellAdvance: CGFloat
  ) -> CTFont? {
    guard cellAdvance.isFinite, cellAdvance > 0,
      text.unicodeScalars.count == 1,
      let scalar = text.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max),
      isSingleCellTerminalUIScalar(scalar)
    else { return nil }

    let pointSize = CTFontGetSize(baseFont)
    let traits = CTFontGetSymbolicTraits(baseFont).intersection([.traitBold, .traitItalic])
    let maxAdvance = cellAdvance * 1.25

    for name in preferredMonospaceFallbackNames {
      let candidateBase = CTFontCreateWithName(name as CFString, pointSize, nil)
      guard CTFontCopyPostScriptName(candidateBase) as String == name else { continue }
      let candidate =
        traits.isEmpty
        ? candidateBase
        : CTFontCreateCopyWithSymbolicTraits(candidateBase, pointSize, nil, traits, traits)
          ?? candidateBase
      guard let advance = glyphAdvance(for: scalar, font: candidate), advance <= maxAdvance else {
        continue
      }
      return candidate
    }
    return nil
  }

  private static func glyphAdvance(for scalar: Unicode.Scalar, font: CTFont) -> CGFloat? {
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else {
      return nil
    }
    var glyphCopy = glyph
    let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, nil, 1)
    guard advance.isFinite, advance > 0 else { return nil }
    return advance
  }

  private static func isSingleCellTerminalUIScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x2190...0x21FF,  // arrows
      0x23B0...0x23CC,  // bracket/control pieces, including U+23BF
      0x23CE,
      0x23F4...0x23F7,
      0x2400...0x243F,  // control pictures
      0x2500...0x259F,  // box drawing and block elements
      0x2800...0x28FF,  // braille patterns
      0xE0A0...0xE0FF,  // Powerline private-use glyphs
      0xF000...0xF8FF:  // Nerd Font private-use glyphs
      return true
    default:
      return false
    }
  }
}
