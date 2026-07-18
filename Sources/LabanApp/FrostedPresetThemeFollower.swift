import AppKit
import LabanRenderer

/// Keeps the Frosted preset's canvas tint in step with the active theme.
/// Frosted is theme-aware: its opacity is defined per theme brightness, so a
/// theme swap or a system-appearance flip re-resolves the persisted opacity
/// through one atomic requested-settings write. Custom and opaque
/// configurations are never touched.
///
/// Not MainActor-isolated so AppDelegate can hold it as a stored property;
/// theme notifications arrive on `.main` and `Theme` is main-thread state,
/// so reconciliation assumes the main actor there and in `reconcileNow`.
final class FrostedPresetThemeFollower {
  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private var themeObserver: NSObjectProtocol?

  init(
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    themeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reconcileOnMainActor()
      }
    }
  }

  deinit {
    if let themeObserver {
      NotificationCenter.default.removeObserver(themeObserver)
    }
  }

  /// Applies the active theme's Frosted opacity when the requested controls
  /// derive to Frosted. Safe to call at launch after persisted theme choices
  /// load; a no-op for opaque and custom configurations.
  @MainActor
  func reconcileNow() {
    reconcileOnMainActor()
  }

  @MainActor
  private func reconcileOnMainActor() {
    TerminalTransparencySettings.reresolveFrostedOpacityIfNeeded(
      themeIsDark: Theme.current.isDark,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }
}
