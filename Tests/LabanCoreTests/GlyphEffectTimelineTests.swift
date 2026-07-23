import XCTest

@testable import LabanCore

final class GlyphEffectTimelineTests: XCTestCase {
  // MARK: - Decay bounds

  func testDecaySecondsMatchesDocumentedConstants() {
    XCTAssertEqual(GlyphEffectTimeline.keystrokeImpulseDecaySeconds, 0.130, accuracy: 1e-9)
    XCTAssertEqual(GlyphEffectTimeline.bellShakeDecaySeconds, 0.300, accuracy: 1e-9)
    XCTAssertEqual(
      GlyphEffectTimeline.decaySeconds(kind: GlyphEffectTimeline.kindKeystrokeImpulse),
      GlyphEffectTimeline.keystrokeImpulseDecaySeconds)
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
    for kind in [GlyphEffectTimeline.kindKeystrokeImpulse, GlyphEffectTimeline.kindBellShake] {
      XCTAssertLessThanOrEqual(
        GlyphEffectTimeline.decaySeconds(kind: kind), GlyphEffectTimeline.maxDecaySeconds)
    }
  }

  // MARK: - Liveness

  func testIsAnimatingInsideDecayWindow() {
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindKeystrokeImpulse, age: 0))
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindKeystrokeImpulse, age: 0.075))
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindBellShake, age: 0.299))
  }

  func testIsAnimatingStopsExactlyAtDecay() {
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(
        kind: GlyphEffectTimeline.kindKeystrokeImpulse,
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds))
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(
        kind: GlyphEffectTimeline.kindBellShake,
        age: GlyphEffectTimeline.bellShakeDecaySeconds))
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindKeystrokeImpulse, age: 1.0))
  }

  func testNegativeAgeIsConservativelyAnimating() {
    // A stamp from the future cannot occur with a monotonic clock; if one
    // ever does, keep the link running rather than freezing mid-effect.
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(kind: GlyphEffectTimeline.kindKeystrokeImpulse, age: -1))
  }

  // MARK: - Reduce Motion policy

  func testReduceMotionForcesKindNone() {
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(
        kind: GlyphEffectTimeline.kindKeystrokeImpulse, reduceMotion: true),
      GlyphEffectTimeline.kindNone)
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(
        kind: GlyphEffectTimeline.kindBellShake, reduceMotion: true),
      GlyphEffectTimeline.kindNone)
  }

  func testNoReduceMotionPassesKindThrough() {
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(
        kind: GlyphEffectTimeline.kindKeystrokeImpulse, reduceMotion: false),
      GlyphEffectTimeline.kindKeystrokeImpulse)
    XCTAssertEqual(
      GlyphEffectTimeline.effectiveKind(kind: GlyphEffectTimeline.kindNone, reduceMotion: false),
      GlyphEffectTimeline.kindNone)
  }

  // MARK: - Keystroke-impulse easing

  func testKeystrokeImpulseEndpointsAreExact() {
    // Exact endpoints are the settle-identical contract: the shader
    // early-returns at/after decay, and progress must be bit-exact 1 there
    // (and 0 at/before age 0) — branch results, not polynomial evaluations.
    XCTAssertEqual(GlyphEffectTimeline.keystrokeImpulseProgress(age: 0), 0)
    XCTAssertEqual(GlyphEffectTimeline.keystrokeImpulseProgress(age: -0.5), 0)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseProgress(
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds), 1)
    XCTAssertEqual(GlyphEffectTimeline.keystrokeImpulseProgress(age: 10), 1)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseScaleX(
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds), 1)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseScaleY(
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds), 1)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseTilt(
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds), 0)
  }

  func testKeystrokeImpulseStartsCompressedTallAndTilted() {
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseScaleX(age: 0),
      GlyphEffectTimeline.keystrokeImpulseInitialScaleX,
      accuracy: 1e-9)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseScaleY(age: 0),
      GlyphEffectTimeline.keystrokeImpulseInitialScaleY,
      accuracy: 1e-9)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseTilt(age: 0),
      GlyphEffectTimeline.keystrokeImpulseInitialTilt,
      accuracy: 1e-9)
    // Arrival must stay a substantial, readable pose: clearly compressed but
    // not crushed, and only slightly tall/tilted.
    XCTAssertGreaterThan(GlyphEffectTimeline.keystrokeImpulseInitialScaleX, 0.4)
    XCTAssertLessThan(GlyphEffectTimeline.keystrokeImpulseInitialScaleX, 0.8)
    XCTAssertGreaterThan(GlyphEffectTimeline.keystrokeImpulseInitialScaleY, 1.0)
    XCTAssertLessThan(GlyphEffectTimeline.keystrokeImpulseInitialScaleY, 1.3)
    XCTAssertLessThan(GlyphEffectTimeline.keystrokeImpulseInitialTilt, 0.15)
  }

  func testKeystrokeImpulseProgressInteriorSamples() {
    // easeOutBack reference values (c1 = 1.70158, c3 = 2.70158); tolerance
    // for interior samples, exact equality only at the branched endpoints.
    let decay = GlyphEffectTimeline.keystrokeImpulseDecaySeconds
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.25 * decay), 0.8174097, accuracy: 1e-6)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.50 * decay), 1.0876975, accuracy: 1e-6)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.580103 * decay),
      1.1000041,
      accuracy: 1e-6)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.75 * decay), 1.0641366, accuracy: 1e-6)
  }

  func testKeystrokeImpulseProgressHasSingleOvershoot() {
    // The curve is deliberately non-monotonic: one overshoot peak near
    // 0.580103 × decay, then it settles back to 1. Do NOT assert
    // monotonicity here — the overshoot is the elastic settle.
    let decay = GlyphEffectTimeline.keystrokeImpulseDecaySeconds
    let half = GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.50 * decay)
    let peak = GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.580103 * decay)
    let threeQuarter = GlyphEffectTimeline.keystrokeImpulseProgress(age: 0.75 * decay)
    XCTAssertGreaterThan(half, 1)
    XCTAssertGreaterThan(peak, half)
    XCTAssertLessThan(threeQuarter, peak)
    XCTAssertGreaterThan(threeQuarter, 1)
  }

  func testKeystrokeImpulseTransformOvershootMagnitudes() {
    // At the progress peak (≈1.100): width overshoots ~4.5%, height
    // undershoots ~1%, tilt crosses to ≈ −0.4°.
    let peakAge = 0.580103 * GlyphEffectTimeline.keystrokeImpulseDecaySeconds
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseScaleX(age: peakAge), 1.045, accuracy: 1e-3)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseScaleY(age: peakAge), 0.990, accuracy: 1e-3)
    XCTAssertEqual(
      GlyphEffectTimeline.keystrokeImpulseTilt(age: peakAge), -0.007, accuracy: 1e-3)
  }

  func testKeystrokeImpulseIsAnimatingBoundary() {
    XCTAssertTrue(
      GlyphEffectTimeline.isAnimating(
        kind: GlyphEffectTimeline.kindKeystrokeImpulse,
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds.nextDown))
    XCTAssertFalse(
      GlyphEffectTimeline.isAnimating(
        kind: GlyphEffectTimeline.kindKeystrokeImpulse,
        age: GlyphEffectTimeline.keystrokeImpulseDecaySeconds))
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
