import Foundation
import LabanCore

/// Persists the user's requested transparency configuration. Temporary
/// accessibility, full-screen, renderer, and session constraints belong in
/// `TerminalTransparencyPolicy` and must not overwrite these values.
enum TerminalTransparencySettings {
  static let backgroundOpacityKey = "LabanTerminalBackgroundOpacity"
  static let applyToExplicitCellBackgroundsKey =
    "LabanTerminalApplyOpacityToExplicitCellBackgrounds"
  static let backdropStyleKey = "LabanTerminalBackdropStyle"

  static let didChangeNotification = Notification.Name(
    "LabanTerminalTransparencySettingsDidChange")

  static var requestedConfiguration: TerminalTransparencyConfiguration {
    requestedConfiguration(defaults: .standard)
  }

  static func requestedConfiguration(
    defaults: UserDefaults = .standard
  ) -> TerminalTransparencyConfiguration {
    let opacity = (defaults.object(forKey: backgroundOpacityKey) as? NSNumber)?.doubleValue ?? 1
    let applyToExplicitCellBackgrounds =
      (defaults.object(forKey: applyToExplicitCellBackgroundsKey) as? Bool) ?? false
    let backdropStyle =
      defaults.string(forKey: backdropStyleKey)
      .flatMap(TerminalBackdropStyle.init(rawValue:)) ?? .none

    return TerminalTransparencyConfiguration(
      backgroundOpacity: opacity,
      applyToExplicitCellBackgrounds: applyToExplicitCellBackgrounds,
      backdropStyle: backdropStyle)
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

  /// Writes all requested fields as one logical change and posts at most one
  /// notification. Equal, already-clamped slider updates are no-ops, which
  /// prevents redundant full redraws during live UI input.
  static func setRequestedConfiguration(
    _ requested: TerminalTransparencyConfiguration,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    let previous = requestedConfiguration(defaults: defaults)
    let normalized = TerminalTransparencyConfiguration(
      backgroundOpacity: requested.backgroundOpacity,
      applyToExplicitCellBackgrounds: requested.applyToExplicitCellBackgrounds,
      backdropStyle: requested.backdropStyle)

    // Normalize missing or malformed persisted values even when their resolved
    // meaning matches the requested configuration. Such normalization is not a
    // user-visible change and therefore does not emit a redraw notification.
    if persistedOpacity(defaults: defaults) != normalized.backgroundOpacity {
      defaults.set(normalized.backgroundOpacity, forKey: backgroundOpacityKey)
    }
    if persistedExplicitCellSetting(defaults: defaults)
      != normalized.applyToExplicitCellBackgrounds
    {
      defaults.set(
        normalized.applyToExplicitCellBackgrounds,
        forKey: applyToExplicitCellBackgroundsKey)
    }
    if defaults.string(forKey: backdropStyleKey) != normalized.backdropStyle.rawValue {
      defaults.set(normalized.backdropStyle.rawValue, forKey: backdropStyleKey)
    }

    guard normalized != previous else { return }
    notificationCenter.post(name: didChangeNotification, object: nil)
  }

  private static func persistedOpacity(defaults: UserDefaults) -> Double? {
    (defaults.object(forKey: backgroundOpacityKey) as? NSNumber)?.doubleValue
  }

  private static func persistedExplicitCellSetting(defaults: UserDefaults) -> Bool? {
    defaults.object(forKey: applyToExplicitCellBackgroundsKey) as? Bool
  }
}

/// Trailing-edge persistence for the continuous Appearance slider. The UI
/// updates its numeric label on every AppKit action, while a burst of drag
/// events becomes one requested-setting write and therefore one full redraw.
@MainActor
final class TerminalTransparencyLivePersistence {
  nonisolated static let defaultDelay: TimeInterval = 0.05

  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private let delay: TimeInterval
  private var pendingOpacity: Double?
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

  func flush() {
    generation &+= 1
    pendingWork?.cancel()
    pendingWork = nil
    guard let pendingOpacity else { return }
    self.pendingOpacity = nil
    TerminalTransparencySettings.setBackgroundOpacity(
      pendingOpacity,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }
}
