import CoreText
import Foundation

/// What one terminal cell of a ligature-shaped run draws.
enum TerminalLigatureCell: Equatable {
  /// Shaping left this cell's glyph unchanged; draw it the usual way.
  case nominal
  /// Shaping substituted this glyph; draw it at the cell origin. Programming
  /// fonts draw the joined shape here with a negative left bearing that
  /// reaches back over the preceding cells of the ligature.
  case glyph(CGGlyph)
  /// Shaping consumed this cell into a neighbouring ligature glyph (a font
  /// whose ligature has fewer glyphs than characters); draw nothing.
  case empty
}

/// Maps CoreText's contextual shaping of a glyph run back onto terminal cells
/// (execplans/active/font-ligatures.md).
///
/// Programming fonts such as JetBrains Mono implement ligatures with `calt`
/// substitutions that keep one glyph per character at the font's fixed
/// advance: `->` shapes to `[SPC, hyphen_greater.liga]`, an empty spacer
/// followed by a wide glyph whose outline extends one cell to the left. So a
/// substituted glyph is placed at the origin of the cell it came from and the
/// grid never moves; CoreText's own glyph positions are deliberately ignored.
///
/// Only single-ASCII-scalar cells shaped in the run's own font are ever
/// substituted. Everything else (wide, CJK, emoji, fallback-font clusters)
/// stays `.nominal` and keeps its existing render path.
enum TerminalLigatureShaper {
  /// Cheap per-run gate, safe to call every frame: true when the run has two
  /// adjacent ASCII punctuation/symbol characters, which is where every
  /// programming-font ligature lives (`->`, `!=`, `::`, `//`, `<=>`, ...).
  /// Letter ligatures such as `fi` are intentionally not candidates.
  static func mayContainLigature(_ text: String) -> Bool {
    var previousWasSymbol = false
    for byte in text.utf8 {
      let isSymbol = isLigatureSymbol(byte)
      if isSymbol, previousWasSymbol { return true }
      previousWasSymbol = isSymbol
    }
    return false
  }

  /// Shape `text` in `font` and return one entry per `Character` (cell), or
  /// `nil` when shaping substituted nothing. This runs CoreText, so callers
  /// must cache the result rather than call it per frame.
  static func shape(text: String, font: CTFont) -> [TerminalLigatureCell]? {
    let characters = Array(text)
    guard characters.count > 1 else { return nil }

    var cellForUTF16Offset: [Int] = []
    cellForUTF16Offset.reserveCapacity(text.utf16.count)
    var asciiScalarForCell: [UniChar?] = []
    asciiScalarForCell.reserveCapacity(characters.count)
    for (cellIndex, character) in characters.enumerated() {
      for _ in 0..<character.utf16.count { cellForUTF16Offset.append(cellIndex) }
      let scalars = character.unicodeScalars
      if scalars.count == 1, let scalar = scalars.first, scalar.isASCII {
        asciiScalarForCell.append(UniChar(scalar.value))
      } else {
        asciiScalarForCell.append(nil)
      }
    }

    guard
      let attributed = CFAttributedStringCreate(
        nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)
    else { return nil }
    let line = CTLineCreateWithAttributedString(attributed)
    let basePostScriptName = CTFontCopyPostScriptName(font)

    var cells = [TerminalLigatureCell](repeating: .nominal, count: characters.count)
    var changed = false
    for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
      let runAttributes = CTRunGetAttributes(run) as NSDictionary
      guard let runFontValue = runAttributes[kCTFontAttributeName] else { continue }
      let runFont = runFontValue as! CTFont
      // A fallback font substituted for missing characters: not ours to shape.
      guard CFEqual(CTFontCopyPostScriptName(runFont), basePostScriptName) else { continue }

      let glyphCount = CTRunGetGlyphCount(run)
      guard glyphCount > 0 else { continue }
      var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
      var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
      CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
      CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

      let stringRange = CTRunGetStringRange(run)
      var cellHasGlyph = Set<Int>()
      for index in 0..<glyphCount {
        let utf16Offset = stringIndices[index]
        guard utf16Offset >= 0, utf16Offset < cellForUTF16Offset.count else { continue }
        let cellIndex = cellForUTF16Offset[utf16Offset]
        guard cellHasGlyph.insert(cellIndex).inserted else { continue }
        guard var unit = asciiScalarForCell[cellIndex] else { continue }
        let shaped = glyphs[index]
        guard shaped != 0 else { continue }
        var nominal = CGGlyph()
        let mapped = CTFontGetGlyphsForCharacters(font, &unit, &nominal, 1)
        if !mapped || nominal != shaped {
          cells[cellIndex] = .glyph(shaped)
          changed = true
        }
      }

      // ASCII cells inside this run's range that received no glyph were
      // swallowed by a ligature glyph emitted for an earlier cell.
      let rangeEnd = min(stringRange.location + stringRange.length, cellForUTF16Offset.count)
      guard stringRange.location >= 0, stringRange.location < rangeEnd else { continue }
      var cellIndex = cellForUTF16Offset[stringRange.location]
      let lastCell = cellForUTF16Offset[rangeEnd - 1]
      while cellIndex <= lastCell {
        if !cellHasGlyph.contains(cellIndex), asciiScalarForCell[cellIndex] != nil {
          cells[cellIndex] = .empty
          changed = true
        }
        cellIndex += 1
      }
    }
    return changed ? cells : nil
  }

  /// ASCII punctuation and symbols: `!` through `/`, `:` through `@`, `[`
  /// through `` ` ``, and `{` through `~`. Space, digits, and letters excluded.
  private static func isLigatureSymbol(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
      return true
    default:
      return false
    }
  }
}
