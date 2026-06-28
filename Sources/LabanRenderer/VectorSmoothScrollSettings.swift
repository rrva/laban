import Foundation

/// How the vector glyph renderer renders sub-cell (smooth) scroll positions.
///
/// Both modes scroll at true sub-pixel precision; they differ in how the
/// fractional position is realized:
///
/// - `.fluid` — one mask per glyph, placed at the true fractional device-pixel
///   position with bilinear sampling. Motion is perfectly continuous (any
///   fraction, every frame) and cheap (no per-phase rasterization). Text softens
///   a hair while in motion and snaps pixel-crisp at rest. The smoothest option.
/// - `.perPhase` — OSOR per-phase masks: the glyph is rasterized and cached per
///   quantized sub-pixel phase and placed on the pixel grid. Sharper subpixel-AA
///   in motion (the AA is recomputed for each phase), at the cost of a small
///   amount of per-frame rasterization and quantized (quarter-pixel) steps.
public enum VectorSmoothScrollMode: String, CaseIterable {
  case fluid
  case perPhase
}

public enum VectorSmoothScrollSettings {
  public static let defaultsKey = "LabanVectorSmoothScrollMode"
  public static let didChangeNotification = Notification.Name(
    "LabanVectorSmoothScrollModeDidChange")

  /// Default to the smoothest, cheapest mode.
  public static let defaultMode: VectorSmoothScrollMode = .fluid

  public static func current(defaults: UserDefaults = .standard) -> VectorSmoothScrollMode {
    guard let raw = defaults.string(forKey: defaultsKey),
      let mode = VectorSmoothScrollMode(rawValue: raw)
    else { return defaultMode }
    return mode
  }

  public static func setCurrent(
    _ mode: VectorSmoothScrollMode,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(mode.rawValue, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
