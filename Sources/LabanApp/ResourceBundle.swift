import Foundation

/// Locates the LabanApp resource bundle (`Laban_LabanApp.bundle`, which holds
/// `Localizable.xcstrings`) without invoking SwiftPM's auto-generated
/// `Bundle.module`. That accessor's static initializer calls `fatalError` when
/// the resource bundle is not at `Bundle.main.bundleURL` (the `.app` root) or
/// the absolute build-time path baked in at compile time, which kills a
/// relocated or distributed `.app` whose resources live in `Contents/Resources/`
/// (the standard macOS layout). That was the cold-launch crash in `L10n.tr` /
/// `MenuCommands.setupMenuBar` / `AppDelegate.applicationDidFinishLaunching`:
/// the first localized-string lookup faulted the module accessor and trapped.
/// This mirrors `LabanRendererResources` for the app module.
enum LabanAppResources {
  static let bundle: Bundle = {
    let name = "Laban_LabanApp.bundle"
    let roots: [URL?] = [
      Bundle.main.resourceURL,
      Bundle(for: BundleFinder.self).resourceURL,
      Bundle.main.bundleURL,
      Bundle(for: BundleFinder.self).bundleURL,
    ]
    var containers: [URL] = []
    var seen = Set<String>()
    for root in roots.compactMap({ $0 }) {
      for candidate in [root, root.deletingLastPathComponent()] {
        let path = candidate.standardizedFileURL.path
        guard seen.insert(path).inserted else { continue }
        containers.append(candidate)
      }
    }
    for container in containers {
      if let bundle = Bundle(url: container.appendingPathComponent(name)) {
        return bundle
      }
    }
    // Fall back to the main bundle so a missing resource bundle degrades to
    // untranslated keys instead of trapping on launch.
    return Bundle.main
  }()

  private final class BundleFinder {}
}
