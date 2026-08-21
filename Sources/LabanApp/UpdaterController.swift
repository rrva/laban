import AppKit
import Sparkle

/// Update-availability gate — pure decision logic with no Sparkle dependency,
/// so it stays testable without the framework. Release builds
/// (`scripts/package-zip`) stamp `SUFeedURL` and `SUPublicEDKey` into
/// Info.plist; dev builds (version 0.0.0, worktrees) never get them and must
/// not contact the release feed.
enum SparkleUpdatePolicy {
  static let feedURLBundleKey = "SUFeedURL"
  static let publicKeyBundleKey = "SUPublicEDKey"

  static func isConfigured(bundle: Bundle = .main) -> Bool {
    isConfigured(infoValue: { bundle.object(forInfoDictionaryKey: $0) as? String })
  }

  static func isConfigured(infoValue: (String) -> String?) -> Bool {
    func present(_ key: String) -> Bool {
      guard let value = infoValue(key) else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return present(feedURLBundleKey) && present(publicKeyBundleKey)
  }
}

/// Sparkle-backed updater. `SPUStandardUpdaterController` drives the whole
/// flow — scheduled background checks (Sparkle's default interval), download,
/// EdDSA verification, and the install-and-relaunch prompt. When the bundle
/// carries no feed keys (dev builds), the controller stays nil and every
/// entry point is a no-op. All Sparkle imports live in this file.
final class UpdaterController: NSObject {
  static let shared = UpdaterController()

  private lazy var controller: SPUStandardUpdaterController? = {
    guard SparkleUpdatePolicy.isConfigured() else { return nil }
    return SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil)
  }()

  var isConfigured: Bool { SparkleUpdatePolicy.isConfigured() }

  /// Force the lazy controller into existence; `startingUpdater: true` starts
  /// Sparkle's scheduler, which performs the launch-time check on its own.
  func startIfConfigured() {
    _ = controller
  }

  @objc func checkForUpdates(_ sender: Any?) {
    controller?.checkForUpdates(sender)
  }

  var automaticallyChecksForUpdates: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set { controller?.updater.automaticallyChecksForUpdates = newValue }
  }
}
