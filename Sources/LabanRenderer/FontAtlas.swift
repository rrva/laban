import CoreGraphics
import CoreText
import Foundation

public final class FontAtlas {
  public let font: CTFont
  public let pointSize: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let leading: CGFloat

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

  public init(pointSize: CGFloat = defaultTerminalPointSize) {
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
