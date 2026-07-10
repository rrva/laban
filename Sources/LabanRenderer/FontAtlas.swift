import CoreGraphics
import CoreText
import Foundation

public final class FontAtlas {
  public let font: CTFont
  public let fontPostScriptName: String
  public let pointSize: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let leading: CGFloat
  // Nominal cell size (width = advance of 'M', height = ascent + descent + leading).
  // Stored rather than computed: `font` is immutable per instance (a new
  // FontAtlas is created for every font/size change, see `withPointSize`),
  // so the two CoreText calls this needs only ever have one answer for the
  // lifetime of an instance. Computed once here instead of per glyph run.
  public let cellSize: (width: CGFloat, height: CGFloat)
  private var styledVariantCache:
    [UInt8: (font: CTFont, boldFallback: Bool, italicFallback: Bool)] = [:]

  /// UserDefaults keys for the user's NSFontPanel picks.
  public static let userFontKey = "LabanFontName"
  public static let userFontSizeKey = "LabanFontSize"

  public static let defaultTerminalPointSize: CGFloat = 14.0
  private static let defaultSidebarPointSize: CGFloat = 11.0

  /// Live-zoom bounds (Cmd+= / Cmd+-). Integer point sizes only, so the
  /// prebuilt atlas ladder is finite (8…40 → 33 sizes).
  public static let zoomMinimumPointSize: CGFloat = 8
  public static let zoomMaximumPointSize: CGFloat = 40

  /// Round to the nearest integer point size and clamp into the zoom range.
  /// Fractional persisted sizes (possible via `defaults write`) normalize to
  /// the ladder grid on their first pass through here.
  public static func clampedZoomPointSize(_ size: CGFloat) -> CGFloat {
    min(max(size.rounded(), zoomMinimumPointSize), zoomMaximumPointSize)
  }

  /// Clamp into the zoom range *without* rounding. The vector renderer bakes
  /// glyph masks on demand at any size, so it can honor fractional point sizes
  /// (continuous pinch / Cmd+scroll zoom); the integer-ladder renderers use
  /// `clampedZoomPointSize` instead.
  public static func clampedFractionalZoomPointSize(_ size: CGFloat) -> CGFloat {
    min(max(size, zoomMinimumPointSize), zoomMaximumPointSize)
  }

  /// Sidebar point size derived from a terminal point size, preserving the
  /// default 11/14 ratio (same derivation as `persistedSidebarPointSize`).
  public static func sidebarPointSize(forTerminalPointSize size: CGFloat) -> CGFloat {
    size * (defaultSidebarPointSize / defaultTerminalPointSize)
  }

  /// Terminal point size from UserDefaults, or `defaultTerminalPointSize`.
  public static var persistedTerminalPointSize: CGFloat {
    let stored = UserDefaults.standard.object(forKey: userFontSizeKey) as? Double
    guard let stored, stored > 0 else { return defaultTerminalPointSize }
    return CGFloat(stored)
  }

  /// Sidebar point size scaled to keep the same ratio as the defaults.
  public static var persistedSidebarPointSize: CGFloat {
    persistedTerminalPointSize * (defaultSidebarPointSize / defaultTerminalPointSize)
  }

  public static let didChangeNotification = Notification.Name("LabanFontDidChange")

  public convenience init(pointSize: CGFloat = defaultTerminalPointSize) {
    self.init(
      font: Self.makeFont(
        pointSize: pointSize,
        fontName: UserDefaults.standard.string(forKey: Self.userFontKey)),
      pointSize: pointSize)
  }

  public convenience init(pointSize: CGFloat, fontName: String?) {
    self.init(font: Self.makeFont(pointSize: pointSize, fontName: fontName), pointSize: pointSize)
  }

  private init(font: CTFont, pointSize: CGFloat) {
    self.font = font
    self.fontPostScriptName = Self.postScriptName(of: font)
    self.pointSize = pointSize
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let leading = CTFontGetLeading(font)
    self.ascent = ascent
    self.descent = descent
    self.leading = leading
    var glyph: CGGlyph = 0
    var cp: UniChar = 77  // 'M'
    CTFontGetGlyphsForCharacters(font, &cp, &glyph, 1)
    var advance: CGSize = .zero
    CTFontGetAdvancesForGlyphs(font, .default, &glyph, &advance, 1)
    self.cellSize = (
      width: ceil(advance.width),
      height: ceil(ascent + descent + leading)
    )
  }

  private static func makeFont(pointSize: CGFloat, fontName: String?) -> CTFont {
    // Resolution order:
    //   1. The user's NSFontPanel pick, if any (UserDefaults).
    //   2. The bundled JetBrainsMono TTF (Package resource).
    //   3. Menlo — shipped with macOS since 10.6, guaranteed present.
    //
    // Falling back rather than crashing means a missing bundled font
    // or a since-uninstalled user pick can't brick the terminal.
    if let fontName, !fontName.isEmpty {
      return CTFontCreateWithName(fontName as CFString, pointSize, nil)
    } else if let url = LabanRendererResources.bundle?.url(
      forResource: "JetBrainsMono-Regular", withExtension: "ttf"),
      let provider = CGDataProvider(url: url as CFURL),
      let cgFont = CGFont(provider)
    {
      return CTFontCreateWithGraphicsFont(cgFont, pointSize, nil, nil)
    } else {
      return CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
    }
  }

  public static func postScriptName(of font: CTFont) -> String {
    CTFontCopyPostScriptName(font) as String
  }

  public static func postScriptName(
    forFontName fontName: String?,
    pointSize: CGFloat = defaultTerminalPointSize
  ) -> String? {
    guard let fontName, !fontName.isEmpty else { return nil }
    return postScriptName(of: CTFontCreateWithName(fontName as CFString, pointSize, nil))
  }

  public func matches(fontName: String?) -> Bool {
    guard let candidate = Self.postScriptName(forFontName: fontName, pointSize: pointSize) else {
      return false
    }
    return candidate == fontPostScriptName
  }

  public var cjkFontDiagnostics: TerminalCJKFontDiagnostics {
    TerminalCJKFontPolicy.diagnostics(baseFont: font, cellWidth: cellSize.width)
  }

  public func withPointSize(_ pointSize: CGFloat) -> FontAtlas {
    FontAtlas(
      font: CTFontCreateCopyWithAttributes(font, pointSize, nil, nil),
      pointSize: pointSize)
  }

  public func styledFontVariant(
    bold: Bool,
    italic: Bool
  ) -> (font: CTFont, boldFallback: Bool, italicFallback: Bool) {
    let key = (bold ? UInt8(1) : 0) | (italic ? UInt8(2) : 0)
    if let cached = styledVariantCache[key] {
      return cached
    }
    var desired: CTFontSymbolicTraits = []
    if bold { desired.insert(.traitBold) }
    if italic { desired.insert(.traitItalic) }
    let styled: CTFont
    if desired.isEmpty {
      styled = font
    } else {
      styled =
        CTFontCreateCopyWithSymbolicTraits(font, pointSize, nil, desired, desired)
        ?? font
    }
    let traits = CTFontGetSymbolicTraits(styled)
    let variant = (
      font: styled,
      boldFallback: bold && !traits.contains(.traitBold),
      italicFallback: italic && !traits.contains(.traitItalic)
    )
    styledVariantCache[key] = variant
    return variant
  }
}
