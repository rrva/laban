import Foundation
import XCTest

@testable import LabanCore

/// `GlyphEffectSettings`, `HoverPreviewSettings` and
/// `SpinnerMotionSmoothingSettings` each cache their environment override in a
/// `static let` because `ProcessInfo.processInfo.environment` rebuilds a
/// dictionary of the whole environment on every access, and the zero-argument
/// `enabled` accessors are read on the per-frame render path.
///
/// The caching must not change any answer. The existing per-setting test
/// suites all drive the injectable `enabled(defaults:environment:)` seam, which
/// is deliberately uncached, so they cannot catch a regression in the cached
/// accessor. These tests cover the cached path specifically:
///
///  - it agrees with the uncached seam, and
///  - only the *environment* half is frozen; the UserDefaults half stays live,
///    so an external `defaults write` still takes effect without a relaunch.
final class SettingsEnvironmentCacheTests: XCTestCase {
  /// (label, cached accessor, uncached seam, defaults key)
  private typealias Probe = (
    name: String,
    cached: () -> Bool,
    seam: (UserDefaults, [String: String]) -> Bool,
    key: String
  )

  private var probes: [Probe] {
    [
      (
        "GlyphEffectSettings", { GlyphEffectSettings.enabled },
        { GlyphEffectSettings.enabled(defaults: $0, environment: $1) },
        GlyphEffectSettings.enabledKey
      ),
      (
        "HoverPreviewSettings", { HoverPreviewSettings.enabled },
        { HoverPreviewSettings.enabled(defaults: $0, environment: $1) },
        HoverPreviewSettings.enabledKey
      ),
      (
        "SpinnerMotionSmoothingSettings", { SpinnerMotionSmoothingSettings.enabled },
        { SpinnerMotionSmoothingSettings.enabled(defaults: $0, environment: $1) },
        SpinnerMotionSmoothingSettings.enabledKey
      ),
    ]
  }

  /// The cached accessor and the uncached seam must resolve identically for the
  /// process's real environment and defaults.
  func testCachedAccessorAgreesWithUncachedSeam() {
    let environment = ProcessInfo.processInfo.environment
    for probe in probes {
      XCTAssertEqual(
        probe.cached(), probe.seam(.standard, environment),
        "\(probe.name): cached accessor disagrees with the injectable seam")
    }
  }

  /// Caching the environment must not freeze the UserDefaults half. Writing the
  /// key has to be visible to the cached accessor immediately.
  ///
  /// Skipped for any setting whose env override is actually set in this
  /// process: the override legitimately wins and the defaults value is then
  /// expected to be ignored.
  func testUserDefaultsStaysLiveThroughCachedAccessor() {
    let environment = ProcessInfo.processInfo.environment
    let defaults = UserDefaults.standard
    for probe in probes {
      let envOverridden: Bool
      switch probe.name {
      case "GlyphEffectSettings":
        envOverridden = GlyphEffectSettings.environmentOverride(environment: environment) != nil
      case "HoverPreviewSettings":
        envOverridden = HoverPreviewSettings.environmentOverride(environment: environment) != nil
      default:
        envOverridden =
          SpinnerMotionSmoothingSettings.environmentOverride(environment: environment) != nil
      }
      if envOverridden { continue }

      let original = defaults.object(forKey: probe.key)
      defer {
        if let original {
          defaults.set(original, forKey: probe.key)
        } else {
          defaults.removeObject(forKey: probe.key)
        }
      }

      defaults.set(true, forKey: probe.key)
      XCTAssertTrue(probe.cached(), "\(probe.name): cached accessor missed a true write")
      defaults.set(false, forKey: probe.key)
      XCTAssertFalse(probe.cached(), "\(probe.name): cached accessor missed a false write")
      defaults.removeObject(forKey: probe.key)
      XCTAssertFalse(probe.cached(), "\(probe.name): missing key must default to false")
    }
  }

  /// The cached accessor must be safe to read concurrently: it is reached from
  /// the render and present-link threads, not just the main thread. A
  /// `static let` is initialised once under `swift_once`; this exercises that
  /// path from many threads at once and asserts a single consistent answer.
  func testCachedAccessorIsSafeUnderConcurrentReads() {
    for probe in probes {
      let expected = probe.cached()
      let results = NSMutableArray()
      let lock = NSLock()
      DispatchQueue.concurrentPerform(iterations: 200) { _ in
        let value = probe.cached()
        lock.lock()
        results.add(value)
        lock.unlock()
      }
      XCTAssertEqual(results.count, 200, "\(probe.name): lost concurrent reads")
      for value in results {
        XCTAssertEqual(
          value as? Bool, expected, "\(probe.name): inconsistent value under concurrent reads")
      }
    }
  }
}
