import Foundation
import LabanCore

/// URL-free reference to a private, app-managed image asset. The later image
/// store resolves `identifier` only inside Laban's Application Support child.
struct TerminalManagedBackgroundImage: Equatable, Sendable {
  let identifier: String
  let displayName: String

  init?(identifier: String, displayName: String) {
    guard Self.isSafeIdentifier(identifier), Self.isSafeDisplayName(displayName) else {
      return nil
    }
    self.identifier = identifier
    self.displayName = displayName
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 255, value != ".", value != ".." else {
      return false
    }
    return value.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57)
        || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122)
        || byte == 45 || byte == 46 || byte == 95
    }
  }

  private static func isSafeDisplayName(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 255, value != ".", value != ".." else {
      return false
    }
    return !value.contains("/") && !value.contains("\\") && !value.contains("\0")
  }
}

struct TerminalTransparencyRequestedSettings: Equatable, Sendable {
  var configuration: TerminalTransparencyConfiguration
  var managedBackgroundImage: TerminalManagedBackgroundImage?
}

/// Derived presentation state for the Appearance preset popup. `custom` is
/// deliberately not persisted: it follows from the exact requested controls,
/// so future controls cannot leave a stale preset name behind.
enum TerminalTransparencyPreset: CaseIterable, Equatable, Sendable {
  case opaque
  case frosted
  case custom

  /// Terminal.app-like canvas tint for the Frosted convenience bundle. The
  /// private window blur carries background detail without a material tint, so
  /// both appearances can use the same mostly-opaque canvas.
  static let frostedBackgroundOpacityDark = 0.80
  static let frostedBackgroundOpacityLight = 0.80

  /// Terminal.app-like light blur radius for Frosted. The AppKit window layer
  /// maps this unit value to radius 20.
  static let frostedBackgroundBlur = 0.20

  /// Keep the theme-aware seam while the tint-free blur uses the same canvas
  /// opacity in both appearances.
  static func frostedBackgroundOpacity(themeIsDark: Bool) -> Double {
    themeIsDark ? frostedBackgroundOpacityDark : frostedBackgroundOpacityLight
  }

  static func derive(
    from configuration: TerminalTransparencyConfiguration
  ) -> TerminalTransparencyPreset {
    if configuration.backgroundOpacity == 1,
      configuration.backgroundBlur == 0,
      configuration.backdropStyle == .none,
      !configuration.applyToExplicitCellBackgrounds
    {
      return .opaque
    }
    // Either brightness's Frosted value derives to Frosted so the preset
    // survives a theme or system-appearance flip until the theme follower
    // re-resolves the persisted opacity to the new theme's value.
    if configuration.backdropStyle == .systemBlur,
      !configuration.applyToExplicitCellBackgrounds,
      configuration.backgroundBlur == frostedBackgroundBlur,
      configuration.backgroundOpacity == frostedBackgroundOpacityDark
        || configuration.backgroundOpacity == frostedBackgroundOpacityLight
    {
      return .frosted
    }
    return .custom
  }
}

/// Persists the user's requested transparency configuration. Temporary
/// accessibility, full-screen, renderer, and session constraints belong in
/// `TerminalTransparencyPolicy` and must not overwrite these values.
enum TerminalTransparencySettings {
  static let backgroundOpacityKey = "LabanTerminalBackgroundOpacity"
  static let backgroundBlurKey = "LabanTerminalBackgroundBlur"
  static let applyToExplicitCellBackgroundsKey =
    "LabanTerminalApplyOpacityToExplicitCellBackgrounds"
  static let backdropStyleKey = "LabanTerminalBackdropStyle"
  static let backgroundImageScalingKey = "LabanTerminalBackgroundImageScaling"
  static let backgroundImageIdentifierKey = "LabanTerminalBackgroundImageIdentifier"
  static let backgroundImageDisplayNameKey = "LabanTerminalBackgroundImageDisplayName"

  static let didChangeNotification = Notification.Name(
    "LabanTerminalTransparencySettingsDidChange")

  static var requestedConfiguration: TerminalTransparencyConfiguration {
    requestedConfiguration(defaults: .standard)
  }

  static func preset(
    defaults: UserDefaults = .standard
  ) -> TerminalTransparencyPreset {
    TerminalTransparencyPreset.derive(from: requestedConfiguration(defaults: defaults))
  }

  /// Applies a named preset as one requested-settings publication. Imported
  /// image metadata and scaling remain untouched so the user can switch back
  /// to Image without reimporting or reconfiguring it. Frosted writes the
  /// canvas tint for the active theme's brightness; the theme follower
  /// re-resolves it on later theme changes.
  static func applyPreset(
    _ preset: TerminalTransparencyPreset,
    themeIsDark: Bool,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    guard preset != .custom else { return }
    var requested = requestedSettings(defaults: defaults)
    switch preset {
    case .opaque:
      requested.configuration.backgroundOpacity = 1
      requested.configuration.backgroundBlur = 0
      requested.configuration.backdropStyle = .none
      requested.configuration.applyToExplicitCellBackgrounds = false
    case .frosted:
      requested.configuration.backgroundOpacity =
        TerminalTransparencyPreset.frostedBackgroundOpacity(themeIsDark: themeIsDark)
      requested.configuration.backgroundBlur = TerminalTransparencyPreset.frostedBackgroundBlur
      requested.configuration.backdropStyle = .systemBlur
      requested.configuration.applyToExplicitCellBackgrounds = false
    case .custom:
      return
    }
    setRequestedSettings(
      requested,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  /// Re-resolves the Frosted canvas tint after a theme change. No-op unless
  /// the requested controls still derive to Frosted, so custom and opaque
  /// configurations are never rewritten; an already-matching opacity is also
  /// a no-op and emits no notification.
  static func reresolveFrostedOpacityIfNeeded(
    themeIsDark: Bool,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    let requested = requestedConfiguration(defaults: defaults)
    guard TerminalTransparencyPreset.derive(from: requested) == .frosted else { return }
    let opacity = TerminalTransparencyPreset.frostedBackgroundOpacity(
      themeIsDark: themeIsDark)
    guard requested.backgroundOpacity != opacity else { return }
    setBackgroundOpacity(
      opacity,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  static func requestedConfiguration(
    defaults: UserDefaults = .standard
  ) -> TerminalTransparencyConfiguration {
    requestedSettings(defaults: defaults).configuration
  }

  static func requestedSettings(
    defaults: UserDefaults = .standard
  ) -> TerminalTransparencyRequestedSettings {
    let opacity = (defaults.object(forKey: backgroundOpacityKey) as? NSNumber)?.doubleValue ?? 1
    let blur = (defaults.object(forKey: backgroundBlurKey) as? NSNumber)?.doubleValue ?? 0
    let applyToExplicitCellBackgrounds =
      (defaults.object(forKey: applyToExplicitCellBackgroundsKey) as? Bool) ?? false
    let backdropStyle =
      defaults.string(forKey: backdropStyleKey)
      .flatMap(TerminalBackdropStyle.init(rawValue:)) ?? .none
    let imageScaling =
      defaults.string(forKey: backgroundImageScalingKey)
      .flatMap(TerminalBackgroundImageScaling.init(rawValue:)) ?? .default
    let managedBackgroundImage: TerminalManagedBackgroundImage?
    if let identifier = defaults.string(forKey: backgroundImageIdentifierKey),
      let displayName = defaults.string(forKey: backgroundImageDisplayNameKey)
    {
      managedBackgroundImage = TerminalManagedBackgroundImage(
        identifier: identifier,
        displayName: displayName)
    } else {
      managedBackgroundImage = nil
    }

    return TerminalTransparencyRequestedSettings(
      configuration: TerminalTransparencyConfiguration(
        backgroundOpacity: opacity,
        applyToExplicitCellBackgrounds: applyToExplicitCellBackgrounds,
        backdropStyle: backdropStyle,
        backgroundImageScaling: imageScaling,
        backgroundBlur: blur),
      managedBackgroundImage: managedBackgroundImage)
  }

  static func setBackgroundOpacity(
    _ opacity: Double,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var requested = requestedConfiguration(defaults: defaults)
    requested.backgroundOpacity = opacity
    setRequestedConfiguration(
      requested, defaults: defaults, notificationCenter: notificationCenter)
  }

  static func setBackgroundBlur(
    _ blur: Double,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var requested = requestedConfiguration(defaults: defaults)
    requested.backgroundBlur = blur
    setRequestedConfiguration(
      requested, defaults: defaults, notificationCenter: notificationCenter)
  }

  static func setApplyToExplicitCellBackgrounds(
    _ enabled: Bool,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var requested = requestedConfiguration(defaults: defaults)
    requested.applyToExplicitCellBackgrounds = enabled
    setRequestedConfiguration(
      requested, defaults: defaults, notificationCenter: notificationCenter)
  }

  static func setBackdropStyle(
    _ backdropStyle: TerminalBackdropStyle,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var requested = requestedConfiguration(defaults: defaults)
    requested.backdropStyle = backdropStyle
    setRequestedConfiguration(
      requested, defaults: defaults, notificationCenter: notificationCenter)
  }

  static func setBackgroundImageScaling(
    _ scaling: TerminalBackgroundImageScaling,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var requested = requestedConfiguration(defaults: defaults)
    requested.backgroundImageScaling = scaling
    setRequestedConfiguration(
      requested, defaults: defaults, notificationCenter: notificationCenter)
  }

  static func setManagedBackgroundImage(
    _ image: TerminalManagedBackgroundImage?,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var requested = requestedSettings(defaults: defaults)
    requested.managedBackgroundImage = image
    setRequestedSettings(
      requested, defaults: defaults, notificationCenter: notificationCenter)
  }

  /// Writes all requested fields as one logical change and posts at most one
  /// notification. Equal, already-clamped slider updates are no-ops, which
  /// prevents redundant full redraws during live UI input.
  static func setRequestedConfiguration(
    _ requested: TerminalTransparencyConfiguration,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    var state = requestedSettings(defaults: defaults)
    state.configuration = requested
    setRequestedSettings(state, defaults: defaults, notificationCenter: notificationCenter)
  }

  /// Atomically persists configuration plus the URL-free managed image
  /// reference. The image store uses this after a replacement is validated so
  /// observers never see half of a source transition.
  static func setRequestedSettings(
    _ requested: TerminalTransparencyRequestedSettings,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    let previous = requestedSettings(defaults: defaults)
    let normalized = TerminalTransparencyRequestedSettings(
      configuration: TerminalTransparencyConfiguration(
        backgroundOpacity: requested.configuration.backgroundOpacity,
        applyToExplicitCellBackgrounds:
          requested.configuration.applyToExplicitCellBackgrounds,
        backdropStyle: requested.configuration.backdropStyle,
        backgroundImageScaling: requested.configuration.backgroundImageScaling,
        backgroundBlur: requested.configuration.backgroundBlur),
      managedBackgroundImage: requested.managedBackgroundImage)

    // Normalize missing or malformed persisted values even when their resolved
    // meaning matches the requested configuration. Such normalization is not a
    // user-visible change and therefore does not emit a redraw notification.
    if persistedOpacity(defaults: defaults) != normalized.configuration.backgroundOpacity {
      defaults.set(normalized.configuration.backgroundOpacity, forKey: backgroundOpacityKey)
    }
    if persistedBlur(defaults: defaults) != normalized.configuration.backgroundBlur {
      defaults.set(normalized.configuration.backgroundBlur, forKey: backgroundBlurKey)
    }
    if persistedExplicitCellSetting(defaults: defaults)
      != normalized.configuration.applyToExplicitCellBackgrounds
    {
      defaults.set(
        normalized.configuration.applyToExplicitCellBackgrounds,
        forKey: applyToExplicitCellBackgroundsKey)
    }
    if defaults.string(forKey: backdropStyleKey)
      != normalized.configuration.backdropStyle.rawValue
    {
      defaults.set(normalized.configuration.backdropStyle.rawValue, forKey: backdropStyleKey)
    }
    if defaults.string(forKey: backgroundImageScalingKey)
      != normalized.configuration.backgroundImageScaling.rawValue
    {
      defaults.set(
        normalized.configuration.backgroundImageScaling.rawValue,
        forKey: backgroundImageScalingKey)
    }
    if let image = normalized.managedBackgroundImage {
      if defaults.string(forKey: backgroundImageIdentifierKey) != image.identifier {
        defaults.set(image.identifier, forKey: backgroundImageIdentifierKey)
      }
      if defaults.string(forKey: backgroundImageDisplayNameKey) != image.displayName {
        defaults.set(image.displayName, forKey: backgroundImageDisplayNameKey)
      }
    } else {
      defaults.removeObject(forKey: backgroundImageIdentifierKey)
      defaults.removeObject(forKey: backgroundImageDisplayNameKey)
    }

    guard normalized != previous else { return }
    notificationCenter.post(name: didChangeNotification, object: nil)
  }

  private static func persistedOpacity(defaults: UserDefaults) -> Double? {
    (defaults.object(forKey: backgroundOpacityKey) as? NSNumber)?.doubleValue
  }

  private static func persistedBlur(defaults: UserDefaults) -> Double? {
    (defaults.object(forKey: backgroundBlurKey) as? NSNumber)?.doubleValue
  }

  private static func persistedExplicitCellSetting(defaults: UserDefaults) -> Bool? {
    defaults.object(forKey: applyToExplicitCellBackgroundsKey) as? Bool
  }
}

/// Trailing-edge persistence for the continuous Appearance sliders. The UI
/// updates its numeric labels on every AppKit action, while a burst of drag
/// events becomes one requested-setting write and therefore one full redraw.
@MainActor
final class TerminalTransparencyLivePersistence {
  nonisolated static let defaultDelay: TimeInterval = 0.05

  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private let delay: TimeInterval
  private var pendingOpacity: Double?
  private var pendingBlur: Double?
  private var pendingWork: DispatchWorkItem?
  private var generation: UInt64 = 0

  init(
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    delay: TimeInterval = TerminalTransparencyLivePersistence.defaultDelay
  ) {
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    self.delay = max(0, delay)
  }

  func scheduleBackgroundOpacity(_ opacity: Double) {
    pendingOpacity = opacity
    scheduleFlush()
  }

  func scheduleBackgroundBlur(_ blur: Double) {
    pendingBlur = blur
    scheduleFlush()
  }

  func flush() {
    let pending = takePendingValues()
    guard pending.opacity != nil || pending.blur != nil else { return }
    var requested = TerminalTransparencySettings.requestedConfiguration(defaults: defaults)
    if let opacity = pending.opacity {
      requested.backgroundOpacity = opacity
    }
    if let blur = pending.blur {
      requested.backgroundBlur = blur
    }
    TerminalTransparencySettings.setRequestedConfiguration(
      requested,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  /// Folds in-flight slider values into another control edit and publishes the
  /// resulting configuration once.
  func updateRequestedConfiguration(
    _ update: (inout TerminalTransparencyConfiguration) -> Void
  ) {
    let pending = takePendingValues()
    var requested = TerminalTransparencySettings.requestedSettings(defaults: defaults)
    if let opacity = pending.opacity {
      requested.configuration.backgroundOpacity = opacity
    }
    if let blur = pending.blur {
      requested.configuration.backgroundBlur = blur
    }
    update(&requested.configuration)
    TerminalTransparencySettings.setRequestedSettings(
      requested,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  /// Named presets replace pending slider values instead of first publishing
  /// them, keeping the preset selection to one atomic notification. Frosted
  /// needs the active theme's brightness to pick its canvas tint.
  func applyPreset(_ preset: TerminalTransparencyPreset, themeIsDark: Bool) {
    _ = takePendingValues()
    TerminalTransparencySettings.applyPreset(
      preset,
      themeIsDark: themeIsDark,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  private func scheduleFlush() {
    pendingWork?.cancel()
    generation &+= 1
    let scheduledGeneration = generation
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == scheduledGeneration else { return }
        self.flush()
      }
    }
    pendingWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func takePendingValues() -> (opacity: Double?, blur: Double?) {
    generation &+= 1
    pendingWork?.cancel()
    pendingWork = nil
    let values = (pendingOpacity, pendingBlur)
    pendingOpacity = nil
    pendingBlur = nil
    return values
  }
}
