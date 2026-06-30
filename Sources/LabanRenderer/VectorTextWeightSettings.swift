import Foundation

/// User preference for how much the vector glyph renderer thickens text
/// ("stem darkening"). Geometric coverage alone renders thinner than the
/// CoreText-based renderers, which bake stem darkening into their glyph masks.
/// This is a matter of taste — some prefer the lighter, more faithful look — so
/// it is a live setting, not a constant.
///
/// The value is a 0...2 weight:
/// - `0.0` — no stem darkening: pure geometric coverage (the thinnest, most
///   shape-faithful look).
/// - `1.0` — full stem darkening: weight tuned to match the CoreText-based
///   renderers (the default, familiar to macOS users).
/// - `2.0` — extra-heavy: twice the CoreText stem darkening, for users who want
///   text bolder than the system default.
public enum VectorTextWeightSettings {
  public static let defaultsKey = "LabanVectorTextWeight"
  public static let didChangeNotification = Notification.Name(
    "LabanVectorTextWeightDidChange")

  /// Default to a CoreText-matched weight so first-run text looks familiar.
  public static let defaultWeight: Double = 1.0

  /// Heaviest selectable weight (twice the CoreText-matched darkening).
  public static let maxWeight: Double = 2.0

  public static func current(defaults: UserDefaults = .standard) -> Double {
    guard defaults.object(forKey: defaultsKey) != nil else { return defaultWeight }
    return clamp(defaults.double(forKey: defaultsKey))
  }

  public static func setCurrent(_ weight: Double, defaults: UserDefaults = .standard) {
    defaults.set(clamp(weight), forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  private static func clamp(_ value: Double) -> Double {
    min(max(value, 0), maxWeight)
  }
}
