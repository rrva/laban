// PROTOTYPE — throwaway. JS port of Sources/LabanCore/GlyphEffectTimeline.swift.
// CONSTANTS MUST MATCH THE SWIFT FILE EXACTLY — it is the documented source of
// truth (same shared-source pattern as the Slug dilation table). The GLSL in
// main.js duplicates the kind-1/kind-2 evaluation; tunable knobs are passed in
// as uniforms per variant, but variant A must equal these values.

export const KIND_NONE = 0;
export const KIND_KEYSTROKE_IMPULSE = 1;
export const KIND_BELL_SHAKE = 2;

// Seconds a keystroke impulse takes to fully settle (visual lifetime of kind 1).
export const keystrokeImpulseDecaySeconds = 0.130;
// Seconds a bell shake takes to fully settle.
export const bellShakeDecaySeconds = 0.300;
// Horizontal scale a fresh impulse glyph starts from (compressed).
export const keystrokeImpulseInitialScaleX = 0.55;
// Vertical scale a fresh impulse glyph starts from (slightly tall).
export const keystrokeImpulseInitialScaleY = 1.10;
// Rotation a fresh impulse glyph starts from (~4°).
export const keystrokeImpulseInitialTilt = 0.07;
// easeOutBack overshoot coefficients (c3 = c1 + 1 by construction).
export const easeOutBackC1 = 1.70158;
export const easeOutBackC3 = 2.70158;
// Critically-damped settle frequency: omega * bellShakeDecaySeconds == 5.
export const bellShakeOmega = 5 / bellShakeDecaySeconds;

export function decaySeconds(kind) {
  if (kind === KIND_KEYSTROKE_IMPULSE) return keystrokeImpulseDecaySeconds;
  if (kind === KIND_BELL_SHAKE) return bellShakeDecaySeconds;
  return 0;
}

// Stamp retention horizon: max over kinds (300 ms).
export const maxDecaySeconds = Math.max(keystrokeImpulseDecaySeconds, bellShakeDecaySeconds);

// True while an effect of `kind`, started `age` seconds ago, still moves pixels.
// Negative age is treated as animating (conservative, mirrors AttentionPulse).
export function isAnimating(kind, age) {
  if (age < 0) return true;
  return age < decaySeconds(kind);
}

// Reduce Motion forces every kind to none.
export function effectiveKind(kind, reduceMotion) {
  return reduceMotion ? KIND_NONE : kind;
}

// easeOutBack over the decay window, single overshoot, exact endpoint branches.
export function keystrokeImpulseProgress(age) {
  if (age <= 0) return 0;
  if (age >= keystrokeImpulseDecaySeconds) return 1;
  const x = age / keystrokeImpulseDecaySeconds;
  const y = x - 1;
  return 1 + easeOutBackC3 * y * y * y + easeOutBackC1 * y * y;
}

export function keystrokeImpulseScaleX(age) {
  const p = keystrokeImpulseProgress(age);
  return keystrokeImpulseInitialScaleX + (1 - keystrokeImpulseInitialScaleX) * p;
}

export function keystrokeImpulseScaleY(age) {
  const p = keystrokeImpulseProgress(age);
  return keystrokeImpulseInitialScaleY + (1 - keystrokeImpulseInitialScaleY) * p;
}

export function keystrokeImpulseTilt(age) {
  return keystrokeImpulseInitialTilt * (1 - keystrokeImpulseProgress(age));
}

// Critically damped impulse x(t) = ωt·e^(1−ωt), peak 1 at t=1/ω, exact 0 outside.
export function bellShakeNormalizedOffset(age) {
  if (!(age > 0 && age < bellShakeDecaySeconds)) return 0;
  const phase = bellShakeOmega * age;
  return phase * Math.exp(1 - phase);
}
