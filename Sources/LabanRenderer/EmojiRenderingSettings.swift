import Foundation

/// User-facing emoji rendering policy.
///
/// `monochrome` preserves the existing R8-alpha-atlas plus foreground tint path
/// used by the Metal renderers. `color` enables color/bitmap glyph drawing for
/// detected emoji/color-font glyphs while leaving ordinary outline glyphs on
/// the existing monochrome path.
public enum EmojiRenderingMode: String, CaseIterable, Codable, Sendable {
  case monochrome
  case color
}

public enum EmojiRenderingSettings {
  public static let defaultsKey = "LabanEmojiRenderingMode"

  public static let didChangeNotification = Notification.Name(
    "LabanEmojiRenderingSettingsDidChange")

  public static func current(defaults: UserDefaults = .standard) -> EmojiRenderingMode {
    guard let raw = defaults.string(forKey: defaultsKey),
      let parsed = EmojiRenderingMode(rawValue: raw)
    else { return .monochrome }
    return parsed
  }

  public static func set(_ mode: EmojiRenderingMode, defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
