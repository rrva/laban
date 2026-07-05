import CoreText
import CoreText
import Foundation

/// User-selected CJK fallback font. The primary terminal font still governs cell
/// metrics; this choice only reorders the explicit CJK cascade when the primary
/// font lacks Hanzi coverage.
public enum CJKFontPreference: String, Codable, Sendable {
  case pingFangSC = "PingFang SC"
  case notoSansMonoCJKSC = "Noto Sans Mono CJK SC"
  case sarasaTermSC = "Sarasa Term SC"
  case sarasaMonoSC = "Sarasa Mono SC"
  case sarasaGothicSC = "Sarasa Gothic SC"
  case custom = "__custom__"

  public var displayName: String { rawValue }

  /// Curated presets shown in Settings; custom fonts use the font panel.
  public static let presetCases: [CJKFontPreference] = [
    .pingFangSC,
    .notoSansMonoCJKSC,
    .sarasaTermSC,
    .sarasaMonoSC,
    .sarasaGothicSC,
  ]
}

public enum CJKFontSettings {
  public static let defaultsKey = "LabanCJKFontPreference"
  public static let customPostScriptNameKey = "LabanCJKFontCustomPostScriptName"

  public static let didChangeNotification = Notification.Name(
    "LabanCJKFontSettingsDidChange")

  public static func current(defaults: UserDefaults = .standard) -> CJKFontPreference {
    guard let raw = defaults.string(forKey: defaultsKey),
      let parsed = CJKFontPreference(rawValue: raw)
    else { return .pingFangSC }
    return parsed
  }

  public static func customPostScriptName(defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: customPostScriptNameKey)
  }

  public static func set(_ preference: CJKFontPreference, defaults: UserDefaults = .standard) {
    defaults.set(preference.rawValue, forKey: defaultsKey)
    if preference != .custom {
      defaults.removeObject(forKey: customPostScriptNameKey)
    }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  public static func setCustom(
    postScriptName: String,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(CJKFontPreference.custom.rawValue, forKey: defaultsKey)
    defaults.set(postScriptName, forKey: customPostScriptNameKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  public static func currentDisplayName(
    baseFont: CTFont,
    defaults: UserDefaults = .standard
  ) -> String {
    if current(defaults: defaults) == .custom,
      let postScriptName = customPostScriptName(defaults: defaults),
      !postScriptName.isEmpty
    {
      let pointSize = CTFontGetSize(baseFont)
      let font = CTFontCreateWithName(postScriptName as CFString, pointSize, nil)
      let family = CTFontCopyFamilyName(font) as String
      if !family.isEmpty { return family }
      return CTFontCopyDisplayName(font) as String? ?? postScriptName
    }
    return current(defaults: defaults).displayName
  }
}
