# Traveling-wave super-sampling for spinner motion

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root. Keep `Progress` and `Validation and Acceptance`
current as work proceeds. Add optional sections only when they contain
information that will help a fresh contributor.

It builds on `execplans/active/spinner-motion-smoothing.md` (checked in),
which defines the spinner-motion detector, the Slug-only smoothing setting,
and the finely sampled bypass this plan extends.

## Purpose / Big Picture

Some terminal applications already animate colors smoothly at the source:
they emit a highlight that travels across a row of text in small, frequent
steps (for example, a sweep that advances one cell roughly every 74 ms).
Today Laban renders such streams authoritatively — the finely sampled bypass
added in commit `37aef6fb` — because interpolating them per-cell only
filtered an already-shaped signal. But "authoritative" still means the
highlight visibly jumps one whole cell at a time.

After this change, when **Smooth spinner motion** is enabled, Laban
recognizes a *traveling wave* — a color pattern that translates across a
single row at a steady velocity — and re-renders it at display rate at
*fractional* cell positions. The visible result: a sweep that previously
teleported one cell every ~74 ms glides continuously. Sources that do not
exhibit a clean traveling wave keep today's behavior exactly (sparse sources
get smoothstep transitions; finely sampled non-wave sources render
authoritatively).

To see it working: run any true-color sweep spinner in a terminal tab (the
repository's own A/B capture in `Surprises & Discoveries` used a
codex-style shimmer), enable Settings → Smooth spinner motion with the Slug
Glyph renderer, and observe the highlight glide instead of stepping. The
E2E scenario `fixtures/spinner-motion-wave.scenario.json` demonstrates the
same behavior deterministically by pixel-probing intermediate colors that a
cell-stepped source never emits.

## Context and Orientation

Repository: a macOS terminal application. Relevant areas:

- `Sources/LabanCore/SpinnerMotion.swift` — `SpinnerMotionDetector`, a pure
  value type that observes resolved terminal cell states once per dirty
  terminal generation, qualifies changed-cell regions, estimates update
  cadence, and produces per-cell foreground transitions
  (`GlyphForegroundTransition`: start color in linear light, start timestamp,
  duration). Since `37aef6fb`, when the observed change cadence falls below
  `finelySampledEnterCadenceSeconds` (0.10 s, exit 0.12 s with hysteresis)
  the detector stops creating transitions and the cells render
  authoritatively. That branch is where this plan hooks in.
- `Sources/LabanCore/TerminalSurfaceController.swift` —
  `spinnerMotionTransitions(for:producer:request:...)` (around line 746)
  owns one detector per session, feeds it one observation per dirty
  generation, and returns the transition map consumed by `FrameProducer`,
  which attaches `foregroundTransition` metadata to `FrameCommand.glyphRun`.
  Timestamps come from `outputStampClock` (`MonotonicClock.seconds`;
  deterministic headless runs substitute a controllable clock).
- `Sources/LabanRenderer/FrameCommand.swift` — frame command model.
  `GlyphForegroundTransition` carries only a *start* color; the renderer
  blends it toward the run's current foreground (the transition has no
  stored target on the GPU path).
- `Sources/LabanRenderer/SlugGlyphRenderer.swift` — Slug Glyph renderer.
  Motion glyphs use a separate 96-byte instance
  (`SlugGlyphMotionGPUInstance`) and pipeline; `resolvedGlyphEffectKind`
  selects effect kind 3 for spinner transitions; live bands, remaining-time
  publication, and settle repaint already exist
  (`unionLiveGlyphEffectBands`, `updateLiveGlyphEffectState`,
  `syncGlyphEffectAnimatingState` in the app layer).
- `Sources/LabanRenderer/VectorGlyphShaders.metal` —
  `slugGlyphMotionVertex` computes
  `color = mix(instance.startColor, instance.color, smoothstep(age/duration))`.
- Debug surface: `GET /debug/spinner-motion` exposes
  `SpinnerMotionDiagnostics`; schemas live under `schemas/debug/`; the E2E
  scenario runner is `scripts/run-scenario` (see an existing scenario,
  `fixtures/spinner-motion-smoothing.scenario.json`, for the op vocabulary:
  `discover`, `action` `feedOutput`/`advanceTime`, `get`, `pixel-probe`).
- Product contract: `docs/product/spec.md` line ~149 defines the Smooth
  spinner motion setting; it must be updated to mention wave
  super-sampling.

Terms used by this plan:

- *Authoritative rendering*: drawing the terminal's current resolved color
  exactly as emitted by the application, with no temporal filtering.
- *Traveling wave*: a per-cell color pattern over a single row that is
  approximately a translated copy of itself between consecutive generations:
  `color[col, t+dt] ≈ color[col − s, t]` for a consistent integer shift `s`.
- *Super-sampling*: rendering the wave at fractional translation offsets
  `v·(t − anchor)` between generations, where `v` is the estimated velocity
  in cells per second.
- *Field*: the region's anchored per-cell color vector (linear-light RGBA),
  re-uploaded once per generation and sampled fractionally by the GPU.
- *Bypass*: the existing finely sampled path that renders finely sampled
  sources authoritatively instead of interpolating them.

## Design Decisions

### Estimation lives in the detector, behind the existing qualification

The wave estimator is a sub-component of `SpinnerMotionDetector`
(`Sources/LabanCore/SpinnerMotion.swift`), reusing its observation feed,
region qualification, and cadence bookkeeping. It never matches process
names, output text, or glyph identities; translation consistency of the
color field is the only signal.

Algorithm (per qualifying observation with `regionRows == 1` and column
span ≥ 6):

1. Build a scalar vector over the region columns from linear-light
   luminance of each cell's resolved foreground
   (`0.2126·r + 0.7152·g + 0.0722·b` on linear RGB).
2. Cross-correlate with the previous observation's vector over the
   overlapping column range (require ≥ 6 overlapping columns) for integer
   shifts `s ∈ {-2, -1, 0, 1, 2}` using normalized correlation.
3. If the best shift scores ≥ 0.90, record a vote `(s, dt)`; velocity
   sample `= s / dt`. Keep the last 5 votes.
4. The wave is *confident* when the last 3 votes agree on the same nonzero
   shift and all scored ≥ 0.90. Velocity is the median of the agreeing
   votes' samples. Confidence and velocity are exposed via diagnostics.
5. Disengage after 2 consecutive failed votes, on any observation timeout
   (`min(2·cadence, 0.8)`), on `regionRows > 1`, or on `reset()`.

Interleaved foreign cells are tolerated by the vote-failure hysteresis:
when an unrelated single cell (for example an independently animated
bullet) joins the region for one round, that round's correlation may fail,
but one failure does not disengage the wave. This mirrors how the real
codex stream interleaves a faster bullet sweep with the word sweep.

### Wave mode engages only inside the finely sampled bypass

Sparse sources (cadence ≥ the bypass exit threshold) keep today's
smoothstep transitions — they work well there and this plan changes
nothing about them. Wave estimation runs only on the bypass branch
(cadence < 0.10/0.12 s hysteresis): confident wave → super-sampled
rendering; no confident wave → authoritative rendering (unchanged).

### GPU-side fractional sampling, one analytic instance per glyph

The renderer contract mirrors the existing motion design (one analytic
glyph, GPU time, linear light):

- `FrameCommand` gains an optional frame-level `waveRegions` array. Each
  entry: `colors: [SIMD4<Float>]` (up to 32 linear-light RGBA entries),
  `anchorTimestampSeconds: Double`, `velocityCellsPerSecond: Float`.
  Cap: 4 regions per frame.
- `FrameCommand.glyphRun` gains optional `foregroundWave` metadata:
  `(regionIndex: UInt32, cellIndexInRegion: UInt32)`. When present (and the
  glyph otherwise qualifies for the analytic path) it selects a new effect
  kind 4 in the motion pipeline, winning over kind 1 ink bloom exactly like
  kind 3 does today.
- Slug uploads one small fields buffer per frame alongside the motion
  instance buffer (≤ 4 regions × (16-byte header + 32 × 16 bytes) ≈ 2.2
  KB), bound at vertex buffer index 2 of the motion pipelines.
- `slugGlyphMotionVertex` kind 4 computes
  `x = cellIndex − velocity·(timeSeconds − anchor)` and samples the field
  bilinearly between `field[floor(x)]` and `field[ceil(x)]`, clamped to the
  field bounds. Sampling stays in linear light; alpha multiplies like
  kind 3.
- Sign convention: a rightward-moving highlight has positive velocity, and
  the color now at cell `i` was at anchor time at `i − v·age`; tests pin
  this convention.

Re-anchoring happens once per generation (new field, new anchor). With a
confident estimate the re-anchored function is continuous up to estimation
error; the 0.90 correlation gate keeps any residual step imperceptible.
Cross-fading between consecutive fields is explicitly *not* in scope; add
it only if captures show visible anchor steps.

### Wave teardown reuses the C0-continuous transition path

When the wave disengages (confidence lost, timeout, region change, Reduce
Motion, eligibility loss), the controller stops publishing `foregroundWave`
metadata. On the disengaging generation it creates ordinary smoothstep
transitions from the *wave-displayed* color at `now` (computed by sampling
the wave function) to each cell's authoritative color, using the existing
retarget machinery fixed in `dbb13fc8`. Liveness is bounded the same way
as today: remaining time is published as at most `min(2·cadence, 0.8)` per
generation, so the present link parks automatically when generations stop,
and a settle repaint renders exact authoritative colors.

### No new setting and no new eligibility surface

Wave super-sampling rides the existing **Smooth spinner motion** setting,
Slug-only gating, and Reduce Motion force-disable. `docs/product/spec.md`
is updated to describe the added behavior. Debug telemetry extends
`SpinnerMotionDiagnostics` (`waveActive`, `waveVelocityCellsPerSecond`,
`waveConfidence`) and `GET /debug/spinner-motion`; schema and dev-process
docs are updated per `docs/process/dev-process.md`.

## Plan of Work

### M0 — Wave estimation in the detector

Add to `Sources/LabanCore/SpinnerMotion.swift`:

- `SpinnerWaveState` (public struct): `row`, `minCol`, `colors`
  (`[SIMD4<Float>]`), `anchorTimestamp`, `velocityCellsPerSecond`,
  `confidence`.
- A private `TravelingWaveEstimator` struct implementing the vote
  algorithm above, owned by `SpinnerMotionDetector`, fed from `observe` on
  every qualifying observation (including bypassed ones), and cleared in
  `reset()`.
- `observe` return type changes from
  `[SpinnerMotionCellKey: GlyphForegroundTransition]` to a small public
  struct `SpinnerMotionFrame { transitions: [SpinnerMotionCellKey:
  GlyphForegroundTransition]; wave: SpinnerWaveState? }`. Update
  `activeTransitions(at:)` call sites accordingly (keep a convenience
  `transitions` accessor so existing tests change minimally).
- In the bypass branch: `wave` is set when the estimator is confident,
  else nil.
- Diagnostics: `waveActive`, `waveVelocityCellsPerSecond`,
  `waveConfidence` on `SpinnerMotionDiagnostics`.

Unit tests in `Tests/LabanCoreTests/SpinnerMotionDetectorTests.swift` (or a
new `SpinnerTravelingWaveTests.swift`): synthetic cosine-band waves at 75
ms cadence engage with velocity ≈ expected; reversed direction engages
with negative velocity; stationary pattern never engages; uncorrelated
(random) colors never engage; a wave that stops (idle gap) disengages
within the timeout; single-round foreign-cell corruption does not
disengage; `reset()` clears wave state. A replay test uses a genericized
7-gray-level staircase derived from the 2026-07-21 capture (cells renamed
generically, no application text) and asserts the estimator engages and
the sampled wave color at mid-interval timestamps lies strictly between
adjacent step levels.

### M1 — Renderer contract and Slug kind-4 sampling

- `Sources/LabanRenderer/FrameCommand.swift`: `GlyphForegroundWave`
  metadata struct; `WaveRegionColors` frame payload; `glyphRun` gains
  optional `foregroundWave`; `FrameCommand` gains optional `waveRegions`.
  Codable as the rest of the frame model.
- `Sources/LabanRenderer/SlugGlyphRenderer.swift`: fields-buffer upload,
  vertex buffer index 2 binding on all three motion pipelines, wave
  instance fields (field base offset, cell index), effect kind 4 selection
  in `resolvedGlyphEffectKind` (wave wins over kind 1 like kind 3),
  liveness/remaining-time handling identical to kind 3.
- `Sources/LabanRenderer/VectorGlyphShaders.metal`: kind-4 branch in
  `slugGlyphMotionVertex` implementing the bilinear fractional field sample
  with bounds clamping, plus the mirror struct for the fields buffer.
- Renderer tests in `Tests/LabanRendererTests/`: a CPU-mirror test of the
  sampling math (mid-interval midpoint equals the bilinear field sample in
  linear light; sign convention pinned; clamps at both ends), plus instance
  layout/size assertions matching the Metal mirror.

### M2 — Controller wiring, diagnostics, E2E, docs, review

- `Sources/LabanCore/TerminalSurfaceController.swift`: carry the
  detector's wave state into `TerminalSurfaceFrame`, publish
  `foregroundWave` per cell, emit teardown transitions on disengagement,
  clear wave state alongside `spinnerMotionDetectors` on eligibility loss,
  dimension change, and incarnation change.
- Debug: extend `/debug/spinner-motion` with wave diagnostics; update
  `schemas/debug/` and `docs/process/dev-process.md` references; extend
  `RenderJournal` plumbing if it carries diagnostics.
- E2E: new `fixtures/spinner-motion-wave.fixture.json` (static colored
  row) and `fixtures/spinner-motion-wave.scenario.json`: feed a scripted
  traveling band at ~75 ms steps in deterministic mode; assert
  `GET /debug/spinner-motion` reports `waveActive: true` and a plausible
  velocity; pixel-probe a mid-interval frame and assert at least one cell
  shows a color strictly between the source's adjacent step levels;
  advance past the final step and assert pixel-exact settlement and
  display-link parking. Update `scripts/` wiring only if scenarios are
  enumerated somewhere (check how `spinner-motion-smoothing.scenario.json`
  is registered).
- Docs: update `docs/product/spec.md` (setting description), this
  ExecPlan, and ADR `docs/adr/0030-spinner-motion-is-a-slug-capability.md`
  with a one-paragraph amendment noting wave super-sampling as a second
  Slug-only capability of the same feature.
- Run the Review Gate below.

## Progress

- [x] (2026-07-21) Plan filed. Prior state: `37aef6fb` (finely sampled
  bypass) and `dbb13fc8` (C0 retarget fix) are committed; the bypass was
  visually verified identical to smoothing-off on a codex-style shimmer.
- [x] (2026-07-21) M0 — wave estimation in the detector.
  `TravelingWaveEstimator` (integer-shift Pearson cross-correlation, vote
  ring, two-failure hysteresis, hard disengage on stale observations) lives
  in `Sources/LabanCore/SpinnerMotion.swift`; the detector feeds it on
  qualifying single-row regions with span ≥ 6 and publishes
  `lastWave: SpinnerWaveState?` only inside the finely sampled bypass
  branch. `SpinnerWaveState.sample(col:at:)` is the CPU mirror of the
  future shader sampling. Diagnostics expose `waveActive`,
  `waveVelocityCellsPerSecond`, `waveConfidence`. Deviation from the filed
  plan: `observe` keeps its return type; wave state is published via the
  `lastWave` property instead of a new `SpinnerMotionFrame` return value
  (smaller diff, identical information). `lastWave` clears whenever the
  detector is inactive so stale fields never publish after a timeout.
  Tests: new `Tests/LabanCoreTests/SpinnerTravelingWaveTests.swift`, 10
  tests green; `SpinnerMotionDetectorTests` 15/15,
  `SpinnerMotionTransitionTests` 6/6, `SpinnerMotionCommandTests` 2/2.
- [x] (2026-07-21) M1 — renderer contract and Slug kind-4 sampling.
  `FrameCommand` gained `GlyphForegroundWave { regionIndex;
  cellIndexInRegion }`, a frame-level `.waveRegion(colors:
  anchorTimestampSeconds:velocityCellsPerSecond:)` case, and optional
  `glyphRun.foregroundWave`; every exhaustive consumer was updated
  (no-op everywhere except Slug, which collects regions). Slug uploads one
  fixed-stride `SlugWaveRegionGPU` fields buffer (528 B/region, cap 4) at
  vertex buffer index 2 of all three motion encoder sites, routes wave runs
  to `SlugGlyphMotionGPUInstance` with new `waveRegionIndex`/`waveCellIndex`
  fields, and selects effect kind 4 in `resolvedGlyphEffectKind` (wins over
  ink bloom like kind 3). `slugGlyphMotionVertex` gained the kind-4 branch
  mirroring `SpinnerWaveState.sample` (x = cellIndex − velocity·age,
  clamped bilinear, linear light) with index/count guards falling back to
  the instance color. Liveness rides the kind-3 path (nil duration → zero
  liveness until the controller publishes a horizon). Tests:
  `SlugSpinnerMotionRendererTests` 4/4 (new: GPU mid-interval bilinear
  sample, instance/region stride assertions, `GlyphForegroundWave` Codable
  round-trip), `DebugFrameCommandSerializerTests` wave-region serialization
  test added; `SpinnerMotionDetectorTests` 15/15,
  `SpinnerTravelingWaveTests` 10/10, `LabanRendererTests` green.
- [ ] M2 — controller wiring, diagnostics, E2E, docs, review gate.

## Decision Log

- Decision: Estimate motion by integer-shift cross-correlation of the
  region's luminance vector rather than per-cell optical flow.
  Rationale: whole-region translation is the common case, the estimator is
  ~40 lines with a clear confidence signal, and mixed-velocity cells only
  cost a tolerated failed vote instead of a wrong per-cell velocity.
  Date/Author: 2026-07-21 / Kimi (user-directed)

- Decision: Engage wave mode only inside the finely sampled bypass branch.
  Rationale: sparse sources are already handled well by smoothstep
  transitions; restricting wave mode keeps the change additive and leaves
  the proven path untouched.
  Date/Author: 2026-07-21 / Kimi (user-directed)

- Decision: Sample the wave on the GPU from a per-frame fields buffer
  rather than recomputing colors on the CPU per frame.
  Rationale: preserves the established one-analytic-instance, GPU-time,
  linear-light design (ADR 0030, ADR 0018); CPU recoloring would add
  per-frame command churn and a second composition model.
  Date/Author: 2026-07-21 / Kimi (user-directed)

- Decision: Re-anchor the field per generation without cross-fading.
  Rationale: with a confident estimate the re-anchored function is already
  continuous up to sub-perceptual error; cross-fade is a follow-up only if
  captures show anchor steps.
  Date/Author: 2026-07-21 / Kimi (user-directed)

- Decision: Ship the wave region as a `FrameCommand.waveRegion` case
  rather than an optional `waveRegions` array on the enum, and let the
  Slug instance stride be 112 B instead of the planned 104 B.
  Rationale: `FrameCommand` is a case-per-command enum with no place for a
  frame-level payload other than a case; a case also preserves command
  ordering (regions precede their runs) for free. The 104 B figure ignored
  alignment: the 16-byte-aligned `float4 startColor` sits at offset 80, so
  the appended wave coordinates end at byte 104 and both Swift and MSL
  round the stride to 112 — the mirrors stay byte-identical, which is what
  the layout test pins.
  Date/Author: 2026-07-21 / Kimi (user-directed)

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. See PLANS.md for the review-fix loop.

- [ ] `grep -riE "codex|claude|Working" Sources/LabanCore/SpinnerMotion.swift Sources/LabanRenderer/FrameCommand.swift` returns zero hits (product-neutral detection: no application, process, or text matching).
- [ ] New fixtures `fixtures/spinner-motion-wave.*` contain no literal
  activity text from any real application (grep for `Working`, `codex`,
  `claude`; expect zero hits).
- [ ] `rtk swift test --filter SpinnerMotionDetectorTests` passes with the
  pre-bypass test count plus the new wave tests; every new wave test fails
  when `SpinnerMotion.finelySampledEnterCadenceSeconds` is temporarily set
  to `0.0` (estimation unreachable) and passes after revert.
- [ ] `rtk swift test --filter SpinnerMotionTransitionTests --filter SlugSpinnerMotionRendererTests --filter SpinnerMotionCommandTests` passes.
- [ ] `scripts/run-scenario fixtures/spinner-motion-wave.scenario.json`
  (or the repository's canonical scenario runner invocation) exits 0; its
  transcript contains a passing pixel-probe step asserting an intermediate
  color.
- [ ] `rtk swift test --filter TerminalIdlePolicyTests --filter PresentParkDecisionTests --filter TerminalBitmapViewWakeTests` passes (parking/wake non-regression).
- [ ] `swift format lint --strict` on all touched Swift files exits 0 and
  `git diff --check` is clean.
- [ ] `rtk ./scripts/check` completes with no failures other than the
  pre-existing `LabanControlServerTests.testRouteCatalogCoversLegacyDebugSurfaceAndDescriptors`
  count mismatch (51 actual vs 50 expected at `71b1cb8f`); any other
  failure blocks completion.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Surprises & Discoveries

- Observation: the codex-style shimmer quantizes its highlight position to
  whole cells (`pos_f as usize` in its source), advancing one cell every
  ~74 ms; per cell it emits a fixed 7-level cosine staircase
  (128/138/167/202/231/242). Laban renders that stream losslessly; the
  visible one-cell teleportation is entirely source-side.
  Evidence: PTY-stream reconstruction of captures
  `~/Library/Logs/Laban/captures/appkit-2026-07-21T17-56-24Z` (smoothing
  on) and `appkit-2026-07-21T17-56-50Z` (off); both streams are
  byte-equivalent in structure with a steady ~32 ms write cadence and
  ~65–104 ms per-cell change intervals.
- Observation: the same capture pair showed pre-bypass smoothing produced a
  one-frame 0.91→0.55 drop plus re-rise at sweep tails; root cause was
  retargeting from stale settled transitions (fixed in `dbb13fc8`), and the
  bypass (in `37aef6fb`) made smoothing-on identical to smoothing-off for
  this source class — confirmed by the user on 2026-07-21.
- Observation: the stream interleaves two independent sweep velocities
  (a word at ~13.5 cells/s and a bullet at ~10.5 cells/s), so some
  generations contain a mixed-velocity region; single-round correlation
  failures must not disengage the wave.
  Evidence: per-column PTY color timelines from the captures above.

## Concrete Steps

All commands run from the repository root `/Users/rrj/wrk/laban`.

1. M0: edit `Sources/LabanCore/SpinnerMotion.swift` as described; add
   tests; run `rtk swift test --filter SpinnerMotionDetectorTests` and
   expect all tests to pass, including the new wave tests.
2. M1: edit `FrameCommand.swift`, `SlugGlyphRenderer.swift`,
   `VectorGlyphShaders.metal`; add renderer tests; run
   `rtk swift test --filter SlugSpinnerMotionRendererTests`.
3. M2: wire the controller, debug surface, scenario, and docs; run
   `scripts/run-scenario fixtures/spinner-motion-wave.scenario.json` and
   the focused suites listed in the Review Gate; then `rtk ./scripts/check`.
4. Formatting and hygiene after each milestone:
   `swift format lint --strict <touched Swift files>` and
   `git diff --check`.

## Validation and Acceptance

- Unit: `rtk swift test --filter SpinnerMotionDetectorTests` passes; the
  new wave tests fail on the pre-M0 code and pass after.
- Renderer: `rtk swift test --filter SlugSpinnerMotionRendererTests`
  passes, including kind-4 midpoint sampling assertions.
- E2E: `scripts/run-scenario fixtures/spinner-motion-wave.scenario.json`
  exits 0 and its pixel-probe step proves an intermediate, sub-cell color
  that the cell-stepped source never emitted; the final step proves
  pixel-exact settlement and parking.
- Human: with Smooth spinner motion enabled on the Slug renderer, a
  true-color sweep spinner glides instead of stepping one cell per ~74 ms;
  with the setting off, output is byte-identical behavior to before.
- Full gate: `rtk ./scripts/check` shows no failures beyond the known
  pre-existing route-count mismatch.

## Idempotence and Recovery

All changes are additive behind the existing off-by-default setting;
disabling the setting (or Reduce Motion) restores exact prior behavior.
Every milestone is independently testable and committable. If M1/M2 must be
abandoned, M0 alone is inert (no renderer consumer) and can remain without
behavioral effect; revert commits individually if needed.

## Interfaces and Dependencies

- `SpinnerMotionDetector.observe` keeps its signature
  (`[SpinnerMotionCellKey: GlyphForegroundTransition]`); wave state is
  published via `SpinnerMotionDetector.lastWave: SpinnerWaveState?`, sticky
  across observations that do not feed the estimator and cleared on
  disengagement, inactivity, non-qualifying regions, and `reset()`.
- `SpinnerWaveState`: `row: Int`, `minCol: Int`,
  `colors: [SIMD4<Float>]` (≤ 32), `anchorTimestamp: Double`,
  `velocityCellsPerSecond: Double`, `confidence: Double`; plus
  `sample(col:at:) -> SIMD4<Float>` (bilinear, clamped), mirrored by the
  Slug kind-4 shader branch in M1.
- `FrameCommand.waveRegions: [WaveRegionColors]?` with
  `WaveRegionColors { colors: [SIMD4<Float>]; anchorTimestampSeconds:
  Double; velocityCellsPerSecond: Float }` (≤ 4 entries);
  `GlyphForegroundWave { regionIndex: UInt32; cellIndexInRegion: UInt32 }`
  as optional `glyphRun.foregroundWave`.
- Metal: fields buffer bound at vertex index 2 of the motion pipelines;
  effect kind 4 in `slugGlyphMotionVertex`; mirror structs kept
  byte-identical between Swift and Metal (asserted by tests).
- Diagnostics: `SpinnerMotionDiagnostics.waveActive: Bool`,
  `waveVelocityCellsPerSecond: Double?`, `waveConfidence: Double?`,
  surfaced on `GET /debug/spinner-motion` with schema updates under
  `schemas/debug/`.
- No new third-party dependencies.
