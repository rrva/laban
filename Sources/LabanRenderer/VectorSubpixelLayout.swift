import Foundation

public struct VectorSubpixelArea: Equatable, Sendable {
  public var min: SIMD2<Float>
  public var max: SIMD2<Float>

  public init?(min: SIMD2<Float>, max: SIMD2<Float>) {
    guard min.x.isFinite, min.y.isFinite, max.x.isFinite, max.y.isFinite,
      max.x > min.x, max.y > min.y
    else { return nil }
    self.min = min
    self.max = max
  }

  public var centerOffsetX: Float {
    ((min.x + max.x) * 0.5) - 0.5
  }

  public var metalBounds: SIMD4<Float> {
    SIMD4<Float>(min.x, min.y, max.x, max.y)
  }
}

public struct VectorSubpixelAreas: Equatable, Sendable {
  public var r: VectorSubpixelArea
  public var g: VectorSubpixelArea
  public var b: VectorSubpixelArea

  public init(r: VectorSubpixelArea, g: VectorSubpixelArea, b: VectorSubpixelArea) {
    self.r = r
    self.g = g
    self.b = b
  }

  public var centerOffsets: SIMD3<Float> {
    SIMD3<Float>(r.centerOffsetX, g.centerOffsetX, b.centerOffsetX)
  }

  public static func fullPixel(offsets: SIMD3<Float>) -> VectorSubpixelAreas {
    VectorSubpixelAreas(
      r: area(minX: offsets.x, maxX: offsets.x + 1),
      g: area(minX: offsets.y, maxX: offsets.y + 1),
      b: area(minX: offsets.z, maxX: offsets.z + 1))
  }

  public static let grayscale = fullPixel(offsets: SIMD3<Float>(0, 0, 0))

  public static let calibratedRGB = horizontalOverlap(
    centerOffsets: SIMD3<Float>(-0.15, 0, 0.15),
    width: 0.92)

  public static let rgbStripe = VectorSubpixelAreas(
    r: area(minX: 0, maxX: 1.0 / 3.0),
    g: area(minX: 1.0 / 3.0, maxX: 2.0 / 3.0),
    b: area(minX: 2.0 / 3.0, maxX: 1))

  public static let bgrStripe = VectorSubpixelAreas(
    r: area(minX: 2.0 / 3.0, maxX: 1),
    g: area(minX: 1.0 / 3.0, maxX: 2.0 / 3.0),
    b: area(minX: 0, maxX: 1.0 / 3.0))

  public static func horizontalOverlap(
    centerOffsets: SIMD3<Float>,
    width: Float
  ) -> VectorSubpixelAreas {
    let halfWidth = max(width, 0.001) * 0.5
    return VectorSubpixelAreas(
      r: area(centerOffset: centerOffsets.x, halfWidth: halfWidth),
      g: area(centerOffset: centerOffsets.y, halfWidth: halfWidth),
      b: area(centerOffset: centerOffsets.z, halfWidth: halfWidth))
  }

  private static func area(centerOffset: Float, halfWidth: Float) -> VectorSubpixelArea {
    let center = 0.5 + centerOffset
    return area(minX: center - halfWidth, maxX: center + halfWidth)
  }

  private static func area(minX: Float, maxX: Float) -> VectorSubpixelArea {
    VectorSubpixelArea(
      min: SIMD2<Float>(minX, 0),
      max: SIMD2<Float>(maxX, 1))!
  }
}

public enum VectorSubpixelLayoutPreset: String, CaseIterable, Sendable {
  case grayscale
  case calibratedRGB
  case rgbStripe
  case bgrStripe

  public static let settingsCases: [VectorSubpixelLayoutPreset] = [
    .grayscale,
    .calibratedRGB,
    .rgbStripe,
  ]

  public var layout: VectorSubpixelLayout {
    switch self {
    case .grayscale: return .grayscale
    case .calibratedRGB: return .calibratedRGB
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
  public var areas: VectorSubpixelAreas

  public var offsets: SIMD3<Float> { areas.centerOffsets }
  public var rBounds: SIMD4<Float> { areas.r.metalBounds }
  public var gBounds: SIMD4<Float> { areas.g.metalBounds }
  public var bBounds: SIMD4<Float> { areas.b.metalBounds }

  private struct CustomStorage: Codable {
    var name: String?
    var offsets: [Double]?
    var areas: [[Double]]?
  }

  public init(name: String, offsets: SIMD3<Float>) {
    self.init(name: name, areas: VectorSubpixelAreas.fullPixel(offsets: offsets))
  }

  public init(name: String, areas: VectorSubpixelAreas) {
    self.name = name
    self.areas = areas
  }

  public static let grayscale = VectorSubpixelLayout(
    name: "grayscale",
    areas: .grayscale)

  public static let calibratedRGB = VectorSubpixelLayout(
    name: "calibratedRGB",
    areas: .calibratedRGB)

  public static let rgbStripe = VectorSubpixelLayout(
    name: "rgbStripe",
    areas: .rgbStripe)

  public static let bgrStripe = VectorSubpixelLayout(
    name: "bgrStripe",
    areas: .bgrStripe)

  public static func custom(
    name: String = "custom",
    offsets: SIMD3<Float>
  ) -> VectorSubpixelLayout? {
    guard offsets.x.isFinite, offsets.y.isFinite, offsets.z.isFinite else { return nil }
    let resolvedName = name.isEmpty ? "custom" : name
    return VectorSubpixelLayout(name: resolvedName, offsets: offsets)
  }

  public static func custom(
    name: String = "custom",
    areas: VectorSubpixelAreas
  ) -> VectorSubpixelLayout {
    let resolvedName = name.isEmpty ? "custom" : name
    return VectorSubpixelLayout(name: resolvedName, areas: areas)
  }

  public static func persistedPreset(
    defaults: UserDefaults = .standard
  ) -> VectorSubpixelLayoutPreset {
    guard let raw = defaults.string(forKey: defaultsKey),
      let preset = VectorSubpixelLayoutPreset(rawValue: raw)
    else { return .grayscale }
    return preset
  }

  public static func persisted(defaults: UserDefaults = .standard) -> VectorSubpixelLayout {
    guard let raw = defaults.string(forKey: defaultsKey) else { return .grayscale }
    if let preset = VectorSubpixelLayoutPreset(rawValue: raw) {
      return preset.layout
    }
    return customLayout(from: raw) ?? .grayscale
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
    if layout == .grayscale {
      defaults.set(VectorSubpixelLayoutPreset.grayscale.rawValue, forKey: defaultsKey)
    } else if layout == .calibratedRGB {
      defaults.set(VectorSubpixelLayoutPreset.calibratedRGB.rawValue, forKey: defaultsKey)
    } else if layout == .rgbStripe {
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
        ],
        areas: [
          [
            Double(layout.areas.r.min.x), Double(layout.areas.r.min.y),
            Double(layout.areas.r.max.x), Double(layout.areas.r.max.y),
          ],
          [
            Double(layout.areas.g.min.x), Double(layout.areas.g.min.y),
            Double(layout.areas.g.max.x), Double(layout.areas.g.max.y),
          ],
          [
            Double(layout.areas.b.min.x), Double(layout.areas.b.min.y),
            Double(layout.areas.b.max.x), Double(layout.areas.b.max.y),
          ],
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
      let storage = try? JSONDecoder().decode(CustomStorage.self, from: data)
    else { return nil }
    if let areas = customAreas(from: storage.areas) {
      return custom(name: storage.name ?? "custom", areas: areas)
    }
    guard let offsets = storage.offsets, offsets.count == 3 else { return nil }
    return custom(
      name: storage.name ?? "custom",
      offsets: SIMD3<Float>(
        Float(offsets[0]),
        Float(offsets[1]),
        Float(offsets[2])))
  }

  private static func customAreas(from rawAreas: [[Double]]?) -> VectorSubpixelAreas? {
    guard let rawAreas, rawAreas.count == 3, rawAreas.allSatisfy({ $0.count == 4 }) else {
      return nil
    }
    guard
      let r = area(from: rawAreas[0]),
      let g = area(from: rawAreas[1]),
      let b = area(from: rawAreas[2])
    else { return nil }
    return VectorSubpixelAreas(r: r, g: g, b: b)
  }

  private static func area(from values: [Double]) -> VectorSubpixelArea? {
    VectorSubpixelArea(
      min: SIMD2<Float>(Float(values[0]), Float(values[1])),
      max: SIMD2<Float>(Float(values[2]), Float(values[3])))
  }
}
