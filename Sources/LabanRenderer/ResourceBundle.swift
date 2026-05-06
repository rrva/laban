import Foundation

/// Locates resources owned by the LabanRenderer module without invoking
/// SwiftPM's auto-generated `Bundle.module`. That accessor's static
/// initializer calls `fatalError` when the resource bundle is not at
/// `Bundle.main.bundleURL` or the build-time path, which kills a
/// distributed `.app` whose resources live in `Contents/Resources/`
/// (the standard macOS layout).
public enum LabanRendererResources {
  public static let bundle: Bundle? = {
    let name = "Laban_LabanRenderer.bundle"
    let containers: [URL?] = [
      Bundle.main.resourceURL,
      Bundle(for: BundleFinder.self).resourceURL,
      Bundle.main.bundleURL,
      Bundle(for: BundleFinder.self).bundleURL,
    ]
    for container in containers.compactMap({ $0 }) {
      if let bundle = Bundle(url: container.appendingPathComponent(name)) {
        return bundle
      }
    }
    return nil
  }()

  private final class BundleFinder {}
}
