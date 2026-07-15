import AppKit
import LabanCore

/// Read-only window policy state shared with tests and the debug/control
/// adapter. Requested values are always the persisted user intent; effective
/// values include temporary accessibility, full-screen, and session-policy
/// overrides.
struct TerminalWindowTransparencyStatus: Equatable, Sendable {
  var requested: TerminalTransparencyConfiguration
  var effective: EffectiveTerminalTransparency
  var snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability
  var reduceTransparency: Bool
  var nativeFullscreen: Bool

  /// Direct opacity deliberately creates no AppKit backdrop-effect host.
  var backdropSubviewCount: Int { 0 }
}

struct TerminalTransparencyDiagnostics: Equatable, Sendable {
  var accessibilityRefreshCount: Int
  var effectiveTransparencyApplyCount: Int
  var transparencyRenderWakeCount: Int
  var rendererPresentCount: Int
  var presentIntervalDeadlineMisses: Int
}

/// The single MainActor owner of effective transparency policy for one
/// terminal window. It observes requested settings and native full-screen
/// transitions, accepts cached accessibility/session inputs from the terminal
/// view, configures the NSWindow before presentation, and applies only resolved
/// state to rendering.
@MainActor
final class TerminalWindowTransparencyCoordinator {
  private weak var window: NSWindow?
  private weak var terminalView: TerminalBitmapView?
  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private var observerTokens: [NSObjectProtocol] = []

  private var requested: TerminalTransparencyConfiguration
  private var effective: EffectiveTerminalTransparency
  private var reduceTransparency: Bool
  private var nativeFullscreen: Bool
  private var snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability

  init(
    window: NSWindow,
    terminalView: TerminalBitmapView,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    reduceTransparency: Bool,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability
  ) {
    self.window = window
    self.terminalView = terminalView
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    self.requested = TerminalTransparencySettings.requestedConfiguration(defaults: defaults)
    self.reduceTransparency = reduceTransparency
    self.nativeFullscreen = window.styleMask.contains(.fullScreen)
    self.snapshotBackgroundCapability = snapshotBackgroundCapability
    self.effective = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      headless: false)

    terminalView.transparencyCoordinator = self
    installObservers(for: window)
    applyResolvedState(wake: false, force: true)
  }

  deinit {
    for token in observerTokens {
      notificationCenter.removeObserver(token)
    }
  }

  var status: TerminalWindowTransparencyStatus {
    TerminalWindowTransparencyStatus(
      requested: requested,
      effective: effective,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen)
  }

  /// Cached accessibility input from TerminalBitmapView's sole workspace
  /// observer. `wake: false` lets that observer coalesce all display-option
  /// changes into its one invalidation/wake.
  func updateReduceTransparency(_ enabled: Bool, wake: Bool = true) {
    guard reduceTransparency != enabled else { return }
    reduceTransparency = enabled
    resolveAndApply(wake: wake)
  }

  /// Capability for the active session. Call before producing the session's
  /// first selection frame so a legacy writer can never render translucent.
  func updateSnapshotBackgroundCapability(
    _ capability: TerminalSnapshotBackgroundCapability,
    wake: Bool = true
  ) {
    guard snapshotBackgroundCapability != capability else { return }
    snapshotBackgroundCapability = capability
    resolveAndApply(wake: wake)
  }

  /// Debug/control entrypoint used by the later adapter. Persistence and
  /// notification semantics are exactly the same as the Appearance controls.
  func setRequestedConfiguration(_ configuration: TerminalTransparencyConfiguration) {
    TerminalTransparencySettings.setRequestedConfiguration(
      configuration,
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  private func installObservers(for window: NSWindow) {
    observerTokens.append(
      notificationCenter.addObserver(
        forName: TerminalTransparencySettings.didChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.requested = TerminalTransparencySettings.requestedConfiguration(
            defaults: self.defaults)
          self.resolveAndApply(wake: true)
        }
      })
    observerTokens.append(
      notificationCenter.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setNativeFullscreen(true)
        }
      })
    observerTokens.append(
      notificationCenter.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setNativeFullscreen(false)
        }
      })
  }

  private func setNativeFullscreen(_ enabled: Bool) {
    guard nativeFullscreen != enabled else { return }
    nativeFullscreen = enabled
    resolveAndApply(wake: true)
  }

  private func resolveAndApply(wake: Bool) {
    let resolved = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      headless: false)
    guard resolved != effective else {
      // Requested state is still significant to read-only status even when a
      // temporary force-opaque policy leaves effective rendering unchanged.
      return
    }
    effective = resolved
    applyResolvedState(wake: wake, force: false)
  }

  private func applyResolvedState(wake: Bool, force: Bool) {
    guard let window, let terminalView else { return }
    // Keep the permanent AppKit surface clear. The renderer is the sole owner
    // of the themed tint in both opaque and translucent modes.
    window.backgroundColor = .clear
    window.isOpaque = effective.isSurfaceOpaque
    terminalView.applyTransparency(
      requested: requested,
      effective: effective,
      wake: wake,
      force: force)
  }
}
