import CoreGraphics
import CoreText
import Foundation

public final class FontAtlas {
  public let font: CTFont
  public let pointSize: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let leading: CGFloat

  /// UserDefaults key holding the user's chosen font face name. The size
  /// is whatever the caller passed in (14 for terminal, 11 for sidebar)
  /// — picking a font only changes the face, not the metrics, so the
  /// quad-height tab layout stays balanced regardless of choice.
  public static let userFontKey = "LabanFontName"

  public init(pointSize: CGFloat = 14.0) {
    self.pointSize = pointSize

    // Resolution order:
    //   1. The user's NSFontPanel pick, if any (UserDefaults).
    //   2. The bundled JetBrainsMono TTF (Package resource).
    //   3. Menlo — shipped with macOS since 10.6, guaranteed present.
    //
    // Falling back rather than crashing means a missing bundled font
    // or a since-uninstalled user pick can't brick the terminal.
    if let userName = UserDefaults.standard.string(forKey: Self.userFontKey),
      !userName.isEmpty
    {
      self.font = CTFontCreateWithName(userName as CFString, pointSize, nil)
    } else if let url = LabanRendererResources.bundle?.url(
      forResource: "JetBrainsMono-Regular", withExtension: "ttf"),
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
