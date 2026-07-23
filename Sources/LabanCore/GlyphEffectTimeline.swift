import Foundation

/// Pure timeline for the per-glyph animation channel (execplans/active/
/// per-glyph-animation-channel.md): easing curves, liveness bounds, and the
/// Reduce Motion policy for the effects riding `SlugGlyphGPUInstance`'s
/// `effectKind`/`effectStart` payload.
///
/// AppKit-free and window-free (same pattern as `AttentionPulse`) so the
/// curves are unit-testable without a render loop; the AppKit layer feeds it
/// ages in seconds and gates it on Reduce Motion. The Metal shader duplicates
/// these constants with this file as the documented source of truth (same
/// shared-source pattern as the Slug dilation table): any change here must be
/// mirrored in `VectorGlyphShaders.metal`.
///
/// Every effect eases to exactly its settled state at `decaySeconds` and
/// `isAnimating` flips false there, so a decayed effect is bit-identical to
/// no effect and the display link re-parks (ADR 0018).
public enum GlyphEffectTimeline {
  /// `effectKind` values carried by the animation channel. Kind 0 = none;
  /// the shader must treat it as a bit-identical no-op.
  public static let kindNone: UInt32 = 0
  /// Keystroke impulse type-in: a freshly output glyph arrives horizontally
  /// compressed, slightly tall and tilted, then springs into place (pivot
  /// from ink-bloom; see `gpt-research` and the ExecPlan pivot note).
  public static let kindKeystrokeImpulse: UInt32 = 1
  /// Visual bell shake: one critically-damped horizontal swing of the grid
  /// (M2).
  public static let kindBellShake: UInt32 = 2
  /// Slug-only foreground-color spinner motion: a single analytic glyph
  /// interpolates from its previous resolved color to the new one (M1).
  public static let kindSpinnerForegroundMotion: UInt32 = 3
  /// Slug-only traveling-wave super-sampling: the glyph's foreground is
  /// sampled from a frame-level wave field at fractional cell offsets
  /// (execplans/active/spinner-motion-traveling-wave.md).
  public static let kindSpinnerForegroundWave: UInt32 = 4

  /// Seconds a keystroke impulse takes to fully settle (the *visual* lifetime
  /// of kind 1). Short on purpose: the motion is a directional arrival, not a
  /// linger — 100–140 ms per `gpt-research`. Mirrored in
  /// `VectorGlyphShaders.metal`.
  public static let keystrokeImpulseDecaySeconds: Double = 0.130
  /// Seconds a bell shake takes to fully settle.
  public static let bellShakeDecaySeconds: Double = 0.300
  /// Horizontal scale a fresh impulse glyph starts from (compressed), easing
  /// to 1 with an easeOutBack overshoot to ≈1.045.
  public static let keystrokeImpulseInitialScaleX: Double = 0.55
  /// Vertical scale a fresh impulse glyph starts from (slightly tall), easing
  /// to 1 with an easeOutBack undershoot to ≈0.990.
  public static let keystrokeImpulseInitialScaleY: Double = 1.10
  /// Rotation a fresh impulse glyph starts from (~4°), easing to 0 and
  /// crossing to ≈ −0.4° at the overshoot peak.
  public static let keystrokeImpulseInitialTilt: Double = 0.07
  /// easeOutBack overshoot coefficients (c3 = c1 + 1 by construction).
  public static let easeOutBackC1: Double = 1.70158
  public static let easeOutBackC3: Double = 2.70158
  /// Settle frequency of the critically-damped shake. Chosen so
  /// `omega * bellShakeDecaySeconds == 5`: the residual normalized amplitude
  /// at the decay boundary is `5 * e^-4 ≈ 0.09` of peak, and `isAnimating`
  /// clamps the offset to exactly 0 there (sub-pixel at any sane amplitude).
  public static let bellShakeOmega: Double = 5 / bellShakeDecaySeconds

  /// Settle duration per effect kind; 0 for unknown kinds (never animating).
  public static func decaySeconds(kind: UInt32) -> Double {
    switch kind {
    case kindKeystrokeImpulse: return keystrokeImpulseDecaySeconds
    case kindBellShake: return bellShakeDecaySeconds
    default: return 0
    }
  }

  /// Stamp retention/re-apply horizon: how long a freshly output glyph run
  /// keeps its `outputTimestampSeconds` stamp. Distinct from any kind's
  /// *visual* lifetime (130 ms impulse vs 300 ms horizon): an expired stamp
  /// may still reach the shader after its effect settled, so every kind must
  /// no-op exactly at and after its own decay.
  public static let maxDecaySeconds: Double = max(keystrokeImpulseDecaySeconds, bellShakeDecaySeconds)

  /// True while an effect of `kind`, started `age` seconds ago, still moves
  /// pixels. A negative age cannot happen (stamps are monotonic) but is
  /// treated as animating, mirroring `AttentionPulse`'s conservative stance:
  /// an effect whose clock looks wrong keeps the link running instead of
  /// freezing mid-animation.
  public static func isAnimating(kind: UInt32, age: Double) -> Bool {
    guard age >= 0 else { return true }
    return age < decaySeconds(kind: kind)
  }

  /// Reduce Motion policy: glyph effects are decorative motion, so Reduce
  /// Motion forces every kind to none — no animation frames are scheduled at
  /// all and output renders in its settled state immediately.
  public static func effectiveKind(kind: UInt32, reduceMotion: Bool) -> UInt32 {
    reduceMotion ? kindNone : kind
  }

  /// Keystroke-impulse progress: easeOutBack over the decay window with an
  /// intentional single overshoot (peak ≈1.100 at age ≈ 0.580103 × decay).
  /// Deliberately **not** monotonic. Endpoint branches are explicit (not
  /// polynomial evaluations) so settled frames are bit-exact: exactly 0 at
  /// and before age 0, exactly 1 at and after decay.
  public static func keystrokeImpulseProgress(age: Double) -> Double {
    if age <= 0 { return 0 }
    if age >= keystrokeImpulseDecaySeconds { return 1 }
    let x = age / keystrokeImpulseDecaySeconds
    let y = x - 1
    return 1 + easeOutBackC3 * y * y * y + easeOutBackC1 * y * y
  }

  /// Horizontal scale for kind `kindKeystrokeImpulse`: compressed
  /// (`keystrokeImpulseInitialScaleX`) at arrival, springing to exactly 1.
  public static func keystrokeImpulseScaleX(age: Double) -> Double {
    let progress = keystrokeImpulseProgress(age: age)
    return keystrokeImpulseInitialScaleX + (1 - keystrokeImpulseInitialScaleX) * progress
  }

  /// Vertical scale for kind `kindKeystrokeImpulse`: slightly tall
  /// (`keystrokeImpulseInitialScaleY`) at arrival, springing to exactly 1.
  public static func keystrokeImpulseScaleY(age: Double) -> Double {
    let progress = keystrokeImpulseProgress(age: age)
    return keystrokeImpulseInitialScaleY + (1 - keystrokeImpulseInitialScaleY) * progress
  }

  /// Tilt (radians) for kind `kindKeystrokeImpulse`:
  /// `keystrokeImpulseInitialTilt` at arrival, springing to exactly 0
  /// (crossing negative at the overshoot peak).
  public static func keystrokeImpulseTilt(age: Double) -> Double {
    keystrokeImpulseInitialTilt * (1 - keystrokeImpulseProgress(age: age))
  }

  /// Horizontal offset for kind `kindBellShake`, normalized to a peak of 1 —
  /// the shader multiplies it by `bellAmplitudePx * bellDirection`.
  /// Critically damped impulse `x(t) = ωt·e^(1−ωt)`: exactly 0 at t=0, a
  /// single peak of 1 at t=1/ω, decaying toward 0; clamped to exactly 0 at
  /// and after the decay window.
  public static func bellShakeNormalizedOffset(age: Double) -> Double {
    guard age > 0, age < bellShakeDecaySeconds else { return 0 }
    let phase = bellShakeOmega * age
    return phase * exp(1 - phase)
  }

  /// Cubic smoothstep for kind `kindSpinnerForegroundMotion`.
  /// Returns 0 when `age <= 0`, 1 when `age >= duration`, and a
  /// smooth `u^2(3-2u)` interpolation in between. The duration is
  /// per-transition; the caller is responsible for clamping liveness.
  public static func spinnerForegroundMotionProgress(age: Double, duration: Double)
    -> Double
  {
    guard duration > 0 else { return 1 }
    guard age > 0 else { return 0 }
    let u = min(1, age / duration)
    return u * u * (3 - 2 * u)
  }
}
