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
  /// Ink-bloom type-in: freshly output text eases dilation + alpha from a
  /// thin/faint state to normal (M1).
  public static let kindInkBloom: UInt32 = 1
  /// Visual bell shake: one critically-damped horizontal swing of the grid
  /// (M2).
  public static let kindBellShake: UInt32 = 2

  /// Seconds an ink-bloom takes to fully settle.
  ///
  /// Kept longer than a keystroke so bloom reads as ease-to-steady, not a
  /// single-frame flash. Mirrored in `VectorGlyphShaders.metal`.
  public static let inkBloomDecaySeconds: Double = 0.280
  /// Seconds a bell shake takes to fully settle.
  public static let bellShakeDecaySeconds: Double = 0.300
  /// Alpha multiplier fresh ink-bloom text starts from (slightly faint),
  /// easing to 1. Must stay clearly above 0 — age-0 alpha near zero was the
  /// "vanish then pop" flicker.
  public static let inkBloomInitialAlpha: Double = 0.72
  /// Dilation multiplier fresh ink-bloom text starts from (slightly thin),
  /// easing to 1. Must stay clearly above 0 — `dilation *= progress` with
  /// progress 0 made glyphs disappear for a frame.
  public static let inkBloomInitialDilation: Double = 0.82
  /// Settle frequency of the critically-damped shake. Chosen so
  /// `omega * bellShakeDecaySeconds == 5`: the residual normalized amplitude
  /// at the decay boundary is `5 * e^-4 ≈ 0.09` of peak, and `isAnimating`
  /// clamps the offset to exactly 0 there (sub-pixel at any sane amplitude).
  public static let bellShakeOmega: Double = 5 / bellShakeDecaySeconds

  /// Settle duration per effect kind; 0 for unknown kinds (never animating).
  public static func decaySeconds(kind: UInt32) -> Double {
    switch kind {
    case kindInkBloom: return inkBloomDecaySeconds
    case kindBellShake: return bellShakeDecaySeconds
    default: return 0
    }
  }

  /// Longest decay of any effect kind: the freshness window during which a
  /// freshly output glyph run keeps its `outputTimestampSeconds` stamp
  /// (after it, age > decay for every kind and re-stamping would be dead
  /// weight).
  public static let maxDecaySeconds: Double = max(inkBloomDecaySeconds, bellShakeDecaySeconds)

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

  /// Ink-bloom progress in [0, 1]: ease-out cubic over the decay window,
  /// exactly 1 at and after decay so settled frames are bit-identical to the
  /// no-effect render.
  public static func inkBloomProgress(age: Double) -> Double {
    guard age > 0 else { return 0 }
    let t = min(age / inkBloomDecaySeconds, 1)
    return 1 - pow(1 - t, 3)
  }

  /// Dilation multiplier for kind `kindInkBloom`: starts at
  /// `inkBloomInitialDilation` (slightly thin) and eases to 1.
  public static func inkBloomDilationScale(age: Double) -> Double {
    let progress = inkBloomProgress(age: age)
    return inkBloomInitialDilation + (1 - inkBloomInitialDilation) * progress
  }

  /// Alpha multiplier for kind `kindInkBloom`: starts at
  /// `inkBloomInitialAlpha` (slightly faint) and eases to 1 (full opacity).
  public static func inkBloomAlphaScale(age: Double) -> Double {
    let progress = inkBloomProgress(age: age)
    return inkBloomInitialAlpha + (1 - inkBloomInitialAlpha) * progress
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
}
