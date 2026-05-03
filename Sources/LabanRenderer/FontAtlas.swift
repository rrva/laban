import CoreGraphics
import CoreText
import Foundation

public final class FontAtlas {
  public let font: CTFont
  public let pointSize: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let leading: CGFloat

  public init(pointSize: CGFloat = 14.0) {
    self.pointSize = pointSize

    guard let url = Bundle.module.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf"),
      let provider = CGDataProvider(url: url as CFURL),
      let cgFont = CGFont(provider)
    else {
      preconditionFailure(
        "LabanRenderer: bundled font JetBrainsMono-Regular.ttf not found — "
          + "verify the resources entry in Package.swift"
      )
    }

    self.font = CTFontCreateWithGraphicsFont(cgFont, pointSize, nil, nil)
    self.ascent = CTFontGetAscent(self.font)
    self.descent = CTFontGetDescent(self.font)
    self.leading = CTFontGetLeading(self.font)
  }

  // Nominal cell size (width = advance of 'M', height = ascent + descent + leading).
  public var cellSize: (width: CGFloat, height: CGFloat) {
    var glyph: CGGlyph = 0
    var cp: UniChar = 77  // 'M'
    CTFontGetGlyphsForCharacters(font, &cp, &glyph, 1)
    var advance: CGSize = .zero
    CTFontGetAdvancesForGlyphs(font, .default, &glyph, &advance, 1)
    return (
      width: ceil(advance.width),
      height: ceil(ascent + descent + leading)
    )
  }
}
