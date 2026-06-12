import Foundation

public enum RendererMode: String, Codable, CaseIterable, Sendable {
  case classic
  case gpuDriven

  public static let defaultsKey = "LabanRendererMode"

  public var isAvailableOnCurrentOS: Bool {
    switch self {
    case .classic:
      return true
    case .gpuDriven:
      if #available(macOS 26, *) {
        return true
      }
      return false
    }
  }

  public static var availableModes: [RendererMode] {
    allCases.filter(\.isAvailableOnCurrentOS)
  }

  /// The mode new users get when no preference is persisted: GPU-driven where
  /// the OS supports it, classic otherwise.
  public static var defaultMode: RendererMode {
    RendererMode.gpuDriven.isAvailableOnCurrentOS ? .gpuDriven : .classic
  }

  public static func persisted(defaults: UserDefaults = .standard) -> RendererMode {
    guard let raw = defaults.string(forKey: defaultsKey),
      let mode = RendererMode(rawValue: raw),
      mode.isAvailableOnCurrentOS
    else {
      return defaultMode
    }
    return mode
  }

  public static func set(_ mode: RendererMode, defaults: UserDefaults = .standard) {
    let resolved = mode.isAvailableOnCurrentOS ? mode : .classic
    defaults.set(resolved.rawValue, forKey: defaultsKey)
  }
}
