import XCTest

@testable import LabanCore

final class GlyphEffectTimelineTests: XCTestCase {
  // MARK: - Decay bounds

  func testDecaySecondsMatchesDocumentedConstants() {
    XCTAssertEqual(GlyphEffectTimeline.inkBloomDecaySeconds, 0.280, accuracy: 1e-9)
    XCTAssertEqual(GlyphEffectTimeline.bellShakeDecaySeconds, 0.300, accuracy: 1e-9)
    XCTAssertEqual(
      GlyphEffectTimeline.decaySeconds(kind: GlyphEffectTimeline.kindInkBloom),
      GlyphEffectTimeline.inkBloomDecaySeconds)
    XCTAssertEqual(
      GlyphEffectTimeline.decaySeconds(kind: GlyphEffectTimeline.kindBellShake),
      GlyphEffectTimeline.bellShakeDecaySeconds)
  }

  func testUnknownKindNeverAnimates() {
    XCTAssertEqual(GlyphEffectTimeline.decaySeconds(kind: GlyphEffectTimeline.kindNone), 0)
    XCTAssertEqual(GlyphEffectTimeline.decaySeconds(kind: 99), 0)
    XCTAssertFalse(GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindNone, age: 0))
    XCTAssertFalse(GlyphEffectTimeline.isAnimating(kind: 99, age: 0.01))
  }

  func testSpinnerForegroundMotionKindIsThree() {
    XCTAssertEqual(GlyphEffectTimeline.kindSpinnerForegroundMotion, 3)
  }

  func testMaxDecaySecondsCoversEveryKind() {
    XCTAssertEqual(GlyphEffectTimeline.maxDecaySeconds, 0.300, accuracy: 1e-9)
    for kind in [GlyphEffectTimeline.kindInkBloom, GlyphEffectTimeline.kindBellShake] {
      XCTAssertLessThanOrEqual(
        GlyphEffectTimeline.decaySeconds(kind: kind), GlyphEffectTimeline.maxDecaySeconds)
    }
  }

  // MARK: - Liveness

  func testIsAnimatingInsideDecayWindow() {
    XCTAssertTrue(GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindInkBloom, age: 0))
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindInkBloom, age: 0.075))
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindBellShake, age: 0.299))
  }

  func testIsAnimatingStopsExactlyAtDecay() {
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(
        kind: GlyphEffectTimeline.kindInkBloom,
        age: GlyphEffectTimeline.inkBloomDecaySeconds))
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(
        kind: GlyphEffectTimeline.kindBellShake,
        age: GlyphEffectTimeline.bellShakeDecaySeconds))
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindInkBloom, age: 1.0))
  }

  func testNegativeAgeIsConservativelyAnimating() {
    // A stamp from the future cannot occur with a monotonic clock; if one
    // ever does, keep the link running rather than freezing mid-effect.
    XCTAssertTrue(GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindInkBloom, age: -1))
  }

  // MARK: - Reduce Motion policy

  func testReduceMotionForcesKindNone() {
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(
        kind: GlyphEffectTimeline.kindInkBloom, reduceMotion: true),
      GlyphEffectTimeline.kindNone)
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(
        kind: GlyphEffectTimeline.kindBellShake, reduceMotion: true),
      GlyphEffectTimeline.kindNone)
  }

  func testNoReduceMotionPassesKindThrough() {
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(
        kind: GlyphEffectTimeline.kindInkBloom, reduceMotion: false),
      GlyphEffectTimeline.kindInkBloom)
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(kind: GlyphEffectTimeline.kindNone, reduceMotion: false),
      GlyphEffectTimeline.kindNone)
  }

  // MARK: - Ink-bloom easing

  func testInkBloomEndpointsAreExact() {
    // Exact endpoints are the settle-identical contract: at/after decay the
    // effect multiplies dilation and alpha by exactly 1.
    XCTAssertEqual(GlyphEffectTimeline.inkBloomProgress(age: 0), 0)
    XCTAssertEqual(GlyphEffectTimeline.inkBloomProgress(age: -0.5), 0)
    XCTAssertEqual(
      GlyphEffectTimeline.inkBloomProgress(age: GlyphEffectTimeline.inkBloomDecaySeconds), 1)
    XCTAssertEqual(GlyphEffectTimeline.inkBloomProgress(age: 10), 1)
    XCTAssertEqual(
      GlyphEffectTimeline.inkBloomDilationScale(age: GlyphEffectTimeline.inkBloomDecaySeconds), 1)
    XCTAssertEqual(
      GlyphEffectTimeline.inkBloomAlphaScale(age: GlyphEffectTimeline.inkBloomDecaySeconds), 1)
  }

  func testSpinnerForegroundMotionProgressEndpointsAndSmoothstep() {
    XCTAssertEqual(GlyphEffectTimeline.spinnerForegroundMotionProgress(age: -1, duration: 0.25), 0)
    XCTAssertEqual(GlyphEffectTimeline.spinnerForegroundMotionProgress(age: 0, duration: 0.25), 0)
    let half = GlyphEffectTimeline.spinnerForegroundMotionProgress(
      age: 0.125, duration: 0.25)
    XCTAssertEqual(half, 0.5, accuracy: 1e-9)
    XCTAssertEqual(
      GlyphEffectTimeline.spinnerForegroundMotionProgress(age: 0.25, duration: 0.25), 1)
    XCTAssertEqual(GlyphEffectTimeline.spinnerForegroundMotionProgress(age: 1, duration: 0.25), 1)
  }

  func testInkBloomStartsThinAndFaint() {
    // Age 0 must stay clearly above zero — dilation/alpha 0 was the vanish flicker.
    XCTAssertEqual(
      GlyphEffectTimeline.inkBloomDilationScale(age: 0),
      GlyphEffectTimeline.inkBloomInitialDilation,
      accuracy: 1e-9)
    XCTAssertEqual(
      GlyphEffectTimeline.inkBloomAlphaScale(age: 0),
      GlyphEffectTimeline.inkBloomInitialAlpha,
      accuracy: 1e-9)
    XCTAssertGreaterThan(GlyphEffectTimeline.inkBloomInitialDilation, 0.5)
    XCTAssertGreaterThan(GlyphEffectTimeline.inkBloomInitialAlpha, 0.5)
  }

  func testInkBloomProgressIsMonotonicEaseOut() {
    var previous = 0.0
    for step in 1...10 {
      let age = Double(step) / 10 * GlyphEffectTimeline.inkBloomDecaySeconds
      let progress = GlyphEffectTimeline.inkBloomProgress(age: age)
      XCTAssertGreaterThan(progress, previous)
      // Ease-out: progress at the midpoint is already past half way.
      previous = progress
    }
    XCTAssertGreaterThan(
      GlyphEffectTimeline.inkBloomProgress(age: GlyphEffectTimeline.inkBloomDecaySeconds / 2),
      0.5)
  }

  // MARK: - Bell-shake easing

  func testBellShakeEndpointsAreExactlyZero() {
    XCTAssertEqual(GlyphEffectTimeline.bellShakeNormalizedOffset(age: 0), 0)
    XCTAssertEqual(
      GlyphEffectTimeline.bellShakeNormalizedOffset(
        age: GlyphEffectTimeline.bellShakeDecaySeconds), 0)
    XCTAssertEqual(GlyphEffectTimeline.bellShakeNormalizedOffset(age: 10), 0)
  }

  func testBellShakePeaksAtOneOverOmega() {
    let peak = GlyphEffectTimeline.bellShakeNormalizedOffset(
      age: 1 / GlyphEffectTimeline.bellShakeOmega)
    XCTAssertEqual(peak, 1, accuracy: 1e-9)
    // The peak lands inside the decay window's first half (a snap, not a sway).
    XCTAssertLessThan(
      1 / GlyphEffectTimeline.bellShakeOmega, 0.5 * GlyphEffectTimeline.bellShakeDecaySeconds)
  }

  func testBellShakeDecaysAfterPeak() {
    let peakAge = 1 / GlyphEffectTimeline.bellShakeOmega
    var previous = GlyphEffectTimeline.bellShakeNormalizedOffset(age: peakAge)
    for step in 1...8 {
      let age =
        peakAge
        + Double(step) / 8 * (GlyphEffectTimeline.bellShakeDecaySeconds - peakAge)
      let offset = GlyphEffectTimeline.bellShakeNormalizedOffset(age: age)
      XCTAssertLessThan(offset, previous)
      XCTAssertGreaterThanOrEqual(offset, 0)
      previous = offset
    }
  }
}

final class GlyphEffectSettingsTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "GlyphEffectSettingsTests.\(UUID().uuidString)")
  }

  override func tearDown() {
    if let suite = defaults?.dictionaryRepresentation().keys {
      for key in suite { defaults.removeObject(forKey: key) }
    }
    defaults = nil
    super.tearDown()
  }

  func testDefaultsToOffWhenKeyAbsent() {
    XCTAssertFalse(
      GlyphEffectSettings.enabled(defaults: defaults, environment: [:]))
  }

  func testUserDefaultsEnablesWithoutEnv() {
    XCTAssertTrue(GlyphEffectSettings.setEnabled(true, defaults: defaults, environment: [:]))
    XCTAssertTrue(GlyphEffectSettings.enabled(defaults: defaults, environment: [:]))
    XCTAssertTrue(GlyphEffectSettings.setEnabled(false, defaults: defaults, environment: [:]))
    XCTAssertFalse(GlyphEffectSettings.enabled(defaults: defaults, environment: [:]))
  }

  func testEnvironmentOverrideWinsAndLocksSetEnabled() {
    let env = [GlyphEffectSettings.enabledEnvironmentKey: "1"]
    XCTAssertTrue(GlyphEffectSettings.enabled(defaults: defaults, environment: env))
    // Writing UserDefaults must refuse — otherwise debug actions claim success
    // while `enabled` keeps returning the env value.
    XCTAssertFalse(GlyphEffectSettings.setEnabled(false, defaults: defaults, environment: env))
    XCTAssertTrue(
      GlyphEffectSettings.enabled(defaults: defaults, environment: env),
      "env must still win after a refused setEnabled(false)")
    XCTAssertNil(
      defaults.object(forKey: GlyphEffectSettings.enabledKey),
      "refused write must not touch UserDefaults")
  }

  func testFalsyEnvironmentOverrideForcesOff() {
    let env = [GlyphEffectSettings.enabledEnvironmentKey: "0"]
    defaults.set(true, forKey: GlyphEffectSettings.enabledKey)
    XCTAssertFalse(GlyphEffectSettings.enabled(defaults: defaults, environment: env))
    XCTAssertFalse(GlyphEffectSettings.setEnabled(true, defaults: defaults, environment: env))
  }
}
