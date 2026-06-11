import Foundation

/// User preference for how precise (trackpad/pixel) scroll input moves the
/// scrollback viewport.
///
/// `pixelSmooth` tracks the finger sub-cell and settles onto a whole row at
/// rest; `lineQuantized` is the original behavior where content only ever
/// moves in whole-cell steps. Whole-row alignment at rest is identical in
/// both modes — they differ only while motion is in flight.
public enum ScrollSettings {

  public enum Mode: String, CaseIterable, Sendable {
    case pixelSmooth
    case lineQuantized
  }

  // MARK: - UserDefaults key

  public static let modeKey = "LabanScrollMode"

  // MARK: - Notification

  /// Posted on the main queue whenever the mode changes.
  public static let didChangeNotification = Notification.Name("LabanScrollSettingsDidChange")

  // MARK: - Accessors

  /// The user's preferred scroll mode. Defaults to `.pixelSmooth` when the
  /// key is absent (fresh install or removed key).
  public static var mode: Mode {
    guard let raw = UserDefaults.standard.object(forKey: modeKey) as? String,
      let parsed = Mode(rawValue: raw)
    else { return .pixelSmooth }
    return parsed
  }

  // MARK: - Setters

  public static func setMode(_ mode: Mode) {
    UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
