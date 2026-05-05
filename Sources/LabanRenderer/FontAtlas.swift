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

    // Primary: the JetBrainsMono TTF we bundle as a Package resource.
    // Fallback: Menlo, shipped with macOS since 10.6 — guaranteed to be
    // present on every Mac. We fall back rather than crashing because a
    // missing bundled font (corrupted .app, sandbox quirk) shouldn't
    // brick the whole terminal; Menlo isn't pretty but it works.
    if let url = Bundle.module.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf"),
      let provider = CGDataProvider(url: url as CFURL),
      let cgFont = CGFont(provider)
    {
      self.font = CTFontCreateWithGraphicsFont(cgFont, pointSize, nil, nil)
    } else {
      self.font = CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
    }
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
