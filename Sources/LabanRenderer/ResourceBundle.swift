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
    return nil
  }()

  private final class BundleFinder {}
}
