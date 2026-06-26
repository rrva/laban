import Foundation

public enum VectorSubpixelLayoutPreset: String, CaseIterable, Sendable {
  case rgbStripe
  case bgrStripe

  public var layout: VectorSubpixelLayout {
    switch self {
    case .rgbStripe: return .rgbStripe
    case .bgrStripe: return .bgrStripe
    }
  }
}

public struct VectorSubpixelLayout: Equatable, Sendable {
  public static let defaultsKey = "LabanVectorSubpixelLayout"
  public static let didChangeNotification = Notification.Name(
    "LabanVectorSubpixelLayoutDidChange")

  public var name: String
  public var offsets: SIMD3<Float>

  private struct CustomStorage: Codable {
    var name: String?
    var offsets: [Double]
  }

  public init(name: String, offsets: SIMD3<Float>) {
    self.name = name
    self.offsets = offsets
  }

  public static let rgbStripe = VectorSubpixelLayout(
    name: "rgbStripe",
    offsets: SIMD3<Float>(-1.0 / 3.0, 0, 1.0 / 3.0))

  public static let bgrStripe = VectorSubpixelLayout(
    name: "bgrStripe",
    offsets: SIMD3<Float>(1.0 / 3.0, 0, -1.0 / 3.0))

  public static func custom(
    name: String = "custom",
    offsets: SIMD3<Float>
  ) -> VectorSubpixelLayout? {
    guard offsets.x.isFinite, offsets.y.isFinite, offsets.z.isFinite else { return nil }
    let resolvedName = name.isEmpty ? "custom" : name
    return VectorSubpixelLayout(name: resolvedName, offsets: offsets)
  }

  public static func persistedPreset(
    defaults: UserDefaults = .standard
  ) -> VectorSubpixelLayoutPreset {
    guard let raw = defaults.string(forKey: defaultsKey),
      let preset = VectorSubpixelLayoutPreset(rawValue: raw)
    else { return .rgbStripe }
    return preset
  }

  public static func persisted(defaults: UserDefaults = .standard) -> VectorSubpixelLayout {
    guard let raw = defaults.string(forKey: defaultsKey) else { return .rgbStripe }
    if let preset = VectorSubpixelLayoutPreset(rawValue: raw) {
      return preset.layout
    }
    return customLayout(from: raw) ?? .rgbStripe
  }

  public static func setPersistedPreset(
    _ preset: VectorSubpixelLayoutPreset,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(preset.rawValue, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  public static func setPersisted(
    _ layout: VectorSubpixelLayout,
    defaults: UserDefaults = .standard
  ) {
    if layout == .rgbStripe {
      defaults.set(VectorSubpixelLayoutPreset.rgbStripe.rawValue, forKey: defaultsKey)
    } else if layout == .bgrStripe {
      defaults.set(VectorSubpixelLayoutPreset.bgrStripe.rawValue, forKey: defaultsKey)
    } else {
      let storage = CustomStorage(
        name: layout.name,
        offsets: [
          Double(layout.offsets.x),
          Double(layout.offsets.y),
          Double(layout.offsets.z),
        ])
      if let data = try? JSONEncoder().encode(storage),
        let raw = String(data: data, encoding: .utf8)
      {
        defaults.set(raw, forKey: defaultsKey)
      }
    }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  private static func customLayout(from raw: String) -> VectorSubpixelLayout? {
    guard let data = raw.data(using: .utf8),
      let storage = try? JSONDecoder().decode(CustomStorage.self, from: data),
      storage.offsets.count == 3
    else { return nil }
    return custom(
      name: storage.name ?? "custom",
      offsets: SIMD3<Float>(
        Float(storage.offsets[0]),
        Float(storage.offsets[1]),
        Float(storage.offsets[2])))
  }
}
