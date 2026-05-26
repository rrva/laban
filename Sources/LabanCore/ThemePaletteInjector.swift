import Foundation
import LabanRenderer

public enum ThemePaletteInjector {
  public static func injectCurrentTheme(into session: Session) {
    let theme = Theme.current
    session.setColorScheme(theme.isDark ? .dark : .light)
    session.feedOutput(paletteBytes(for: theme))
  }

  public static func paletteBytes(for theme: ThemeData) -> [UInt8] {
    var bytes: [UInt8] = []
    for (index, color) in theme.ansi16.enumerated() {
      bytes += oscSequence(4, index: index, rgba: color)
    }
    bytes += oscSequence(10, rgba: theme.fg0)
    bytes += oscSequence(11, rgba: theme.bg0)
    bytes += oscSequence(12, rgba: theme.cursor)
    return bytes
  }

  private static func oscSequence(_ code: Int, index: Int? = nil, rgba: UInt32) -> [UInt8] {
    let red = (rgba >> 24) & 0xFF
    let green = (rgba >> 16) & 0xFF
    let blue = (rgba >> 8) & 0xFF
    let hex = String(format: "%02x%02x%02x", red, green, blue)
    let sequence =
      index.map { "\u{1B}]\(code);\($0);#\(hex)\u{07}" }
      ?? "\u{1B}]\(code);#\(hex)\u{07}"
    return Array(sequence.utf8)
  }
}
