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
  var backgroundImageAvailability: TerminalBackgroundImageAvailability
  var backgroundImageIdentifier: String?
  var backgroundImagePixelWidth: Int?
  var backgroundImagePixelHeight: Int?
  var backgroundImageContentDigest: String?
  var backgroundImageImportCount: Int
  var backgroundImageDecodeCount: Int
  var backgroundImageFileReadCount: Int
  var backgroundImageApplyCount: Int
  var backgroundImageRedrawCount: Int
  var backdropSubviewCount: Int
  var backdropSubviewKind: TerminalBackdropStyle
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
  private weak var backgroundEffectHost: TerminalBackgroundEffectHost?
  private let backgroundImageStore: TerminalBackgroundImageStore?
  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private var observerTokens: [NSObjectProtocol] = []

  private var requested: TerminalTransparencyConfiguration
  private var effective: EffectiveTerminalTransparency
  private var reduceTransparency: Bool
  private var nativeFullscreen: Bool
  private var backgroundImageAvailability: TerminalBackgroundImageAvailability
  private var backgroundImageAsset: TerminalResolvedBackgroundImage?
  private var backgroundImageManagedReference: TerminalManagedBackgroundImage?
  private var snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability

  init(
    window: NSWindow,
    terminalView: TerminalBitmapView,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    reduceTransparency: Bool,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability,
    backgroundImageAvailability: TerminalBackgroundImageAvailability = .none,
    backgroundImageStore: TerminalBackgroundImageStore? = nil,
    backgroundEffectHost: TerminalBackgroundEffectHost? = nil
  ) {
    self.window = window
    self.terminalView = terminalView
    self.backgroundEffectHost = backgroundEffectHost
    self.backgroundImageStore = backgroundImageStore
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    let requestedSettings = TerminalTransparencySettings.requestedSettings(defaults: defaults)
    self.requested = requestedSettings.configuration
    self.reduceTransparency = reduceTransparency
    self.nativeFullscreen = window.styleMask.contains(.fullScreen)
    self.backgroundImageManagedReference = requestedSettings.managedBackgroundImage
    if let backgroundImageStore {
      let resolution = backgroundImageStore.resolveManagedImage(
        requestedSettings.managedBackgroundImage)
      self.backgroundImageAvailability = resolution.availability
      self.backgroundImageAsset = resolution.asset
      try? backgroundImageStore.cleanupOrphans(keeping: requestedSettings.managedBackgroundImage)
    } else {
      self.backgroundImageAvailability = backgroundImageAvailability
      self.backgroundImageAsset = nil
    }
    self.snapshotBackgroundCapability = snapshotBackgroundCapability
    self.effective = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      supportsBehindWindowBlur: backgroundEffectHost?.supportsBehindWindowBlur == true,
      backgroundImageAvailability: self.backgroundImageAvailability,
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
    let storeDiagnostics = backgroundImageStore?.diagnostics
    return TerminalWindowTransparencyStatus(
      requested: requested,
      effective: effective,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      backgroundImageAvailability: backgroundImageAvailability,
      backgroundImageIdentifier: backgroundImageManagedReference?.identifier,
      backgroundImagePixelWidth: backgroundImageAsset?.image.width,
      backgroundImagePixelHeight: backgroundImageAsset?.image.height,
      backgroundImageContentDigest: backgroundImageAsset?.contentDigest,
      backgroundImageImportCount: storeDiagnostics?.importCount ?? 0,
      backgroundImageDecodeCount: storeDiagnostics?.decodeCount ?? 0,
      backgroundImageFileReadCount: storeDiagnostics?.fileReadCount ?? 0,
      backgroundImageApplyCount: backgroundEffectHost?.backgroundImageApplyCount ?? 0,
      backgroundImageRedrawCount: backgroundEffectHost?.backgroundImageRedrawCount ?? 0,
      backdropSubviewCount: backgroundEffectHost?.backdropSubviewCount ?? 0,
      backdropSubviewKind: backgroundEffectHost?.backdropSubviewKind ?? .none)
  }

  func resetBackgroundImageDiagnostics() {
    backgroundImageStore?.resetDiagnostics()
    backgroundEffectHost?.resetBackgroundImageDiagnostics()
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

  /// URL-free availability supplied by the future managed image store. A
  /// missing or corrupt image fails closed through pure policy without
  /// exposing a filesystem location to this coordinator or debug state.
  func updateBackgroundImageAvailability(
    _ availability: TerminalBackgroundImageAvailability,
    wake: Bool = true
  ) {
    let removedAsset = availability != .available && backgroundImageAsset != nil
    if availability != .available {
      backgroundImageAsset = nil
    }
    guard backgroundImageAvailability != availability || removedAsset else { return }
    backgroundImageAvailability = availability
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
          let settings = TerminalTransparencySettings.requestedSettings(
            defaults: self.defaults)
          self.requested = settings.configuration
          self.refreshBackgroundImageAvailability(
            managedImage: settings.managedBackgroundImage,
            cleanupOrphans: true)
          self.resolveAndApply(wake: true)
        }
      })
    observerTokens.append(
      notificationCenter.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let backgroundImageStore = self.backgroundImageStore else { return }
          let managedImage = TerminalTransparencySettings.requestedSettings(
            defaults: self.defaults
          ).managedBackgroundImage
          self.backgroundImageManagedReference = managedImage
          let resolution = backgroundImageStore.resolveManagedImage(managedImage)
          guard self.backgroundImageResolutionChanged(resolution) else { return }
          self.backgroundImageAvailability = resolution.availability
          self.backgroundImageAsset = resolution.asset
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

  private func refreshBackgroundImageAvailability(
    managedImage: TerminalManagedBackgroundImage?,
    cleanupOrphans: Bool
  ) {
    guard let backgroundImageStore else { return }
    backgroundImageManagedReference = managedImage
    let resolution = backgroundImageStore.resolveManagedImage(managedImage)
    backgroundImageAvailability = resolution.availability
    backgroundImageAsset = resolution.asset
    if cleanupOrphans {
      try? backgroundImageStore.cleanupOrphans(keeping: managedImage)
    }
  }

  private func backgroundImageResolutionChanged(
    _ resolution: TerminalBackgroundImageResolution
  ) -> Bool {
    guard resolution.availability == backgroundImageAvailability else { return true }
    switch (resolution.asset, backgroundImageAsset) {
    case (nil, nil):
      return false
    case (let next?, let current?):
      return next.managedImage.identifier != current.managedImage.identifier
        || next.image !== current.image
    case (.some, nil), (nil, .some):
      return true
    }
  }

  private func resolveAndApply(wake: Bool) {
    let resolved = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      supportsBehindWindowBlur: backgroundEffectHost?.supportsBehindWindowBlur == true,
      backgroundImageAvailability: backgroundImageAvailability,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      headless: false)
    guard resolved != effective else {
      // Requested state is still significant to read-only status even when a
      // temporary force-opaque policy leaves effective rendering unchanged.
      applyResolvedBackdrop()
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
    applyResolvedBackdrop()
    terminalView.applyTransparency(
      requested: requested,
      effective: effective,
      wake: wake,
      force: force)
  }

  private func applyResolvedBackdrop() {
    backgroundEffectHost?.apply(
      effective.backdropStyle,
      imageAsset: effective.backdropStyle == .image ? backgroundImageAsset : nil,
      imageScaling: requested.backgroundImageScaling)
  }
}
