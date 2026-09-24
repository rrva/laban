import Foundation

/// User-facing emoji rendering policy.
///
/// `color` (the default) draws detected emoji/color-font glyphs as color
/// bitmaps while leaving ordinary outline glyphs on the monochrome path, which
/// matches what every other macOS terminal shows. `monochrome` routes emoji
/// through the R8-alpha-atlas plus foreground tint path instead.
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
    else { return .color }
    return parsed
  }

  public static func set(_ mode: EmojiRenderingMode, defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
