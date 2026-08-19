# Slug-only motion smoothing for ANSI/ASCII spinners

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root. Keep `Progress`, `Surprises & Discoveries`, `Decision
Log`, and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Many terminal programs repaint a small status word at a modest, steady
cadence. Claude Code, for example, can leave the letters of a status verb in
place while a foreground-color ripple moves across them. Laban currently
shows each real update as a discrete color jump.

After this work, a user of the **Slug Glyph** renderer can enable **Smooth
spinner motion** in Settings. When the same undecorated analytic glyphs in a
small, steadily updating region change only foreground color, Slug displays
one copy of each glyph and continuously interpolates its color from the
previous displayed value to the new value. The interpolation runs in linear
light in Slug's vertex shader, before the unchanged analytic-coverage fragment
path. It therefore has constant glyph coverage, no overlapping copies, no
opacity dip, no ghost image, and no CPU-side recoloring of glyph runs on every
animation frame.

This is intentionally a Slug-only capability. Software, classic Metal,
GPU-driven Metal, and Vector Glyph continue to render authoritative terminal
states immediately. Their architectures do not have Slug's per-glyph GPU
effect clock plus analytic single-instance shading, so attempting parity would
make the feature less precise and more expensive. The setting remains visible
but unavailable when the configured renderer is not Slug Glyph, and runtime
eligibility is based on the effective renderer so a Slug initialization
fallback cannot accidentally animate on another backend.

The feature is off by default, and macOS Reduce Motion force-disables it.
Fullscreen TUIs that enable terminal mouse tracking remain eligible; detection
never matches process names or literal output text. When a transition settles,
Slug draws the exact target color once and the existing glyph-effect display
link machinery parks.

The committed visual scope is deliberately narrow:

- the glyph must stay the same and remain on Slug's analytic outline path;
- only foreground color is interpolated;
- background color must stay unchanged;
- underline, strikethrough, or other foreground-derived decoration is not
  eligible;
- character substitution, background motion, raster/color fallback glyphs,
  and layout or attribute changes render the new terminal state immediately.

How to see the result after implementation:

1. Select **Slug Glyph** in Settings > Rendering.
2. Enable **Smooth spinner motion**.
3. Run `fixtures/spinner-motion-smoothing.scenario.json` or a real program that
   repeatedly recolors a fixed status word.
4. The status ripple moves continuously. At the deterministic red-to-blue
   midpoint, a fully covered glyph pixel is approximately `0xBC00BCFF`, the
   encoded-sRGB representation of a 50/50 linear-light mixture; it is not the
   darker encoded-channel midpoint `0x800080FF`.
5. Select another renderer, disable the checkbox, or enable Reduce Motion. The
   next frame displays authoritative terminal colors immediately and no
   spinner-motion frames remain live.

## Context and Orientation

Laban has five renderer selections. `software`, `classic`, `gpuDriven`, and
`vectorGlyph` consume the shared frame-command or cell-payload representation
and have no retained per-glyph effect state. `slugGlyph` is different:

- `Sources/LabanRenderer/SlugGlyphRenderer.swift` converts CoreText outlines
  into size-independent curve geometry and evaluates glyph coverage
  analytically in Metal.
- `Sources/LabanRenderer/VectorGlyphShaders.metal` contains Slug's vertex and
  fragment functions. Despite the filename, the `slugGlyph*` functions belong
  to `SlugGlyphRenderer`.
- The already-landed work tracked by
  `execplans/active/per-glyph-animation-channel.md` gives Slug each analytic
  glyph instance an `effectKind` and `effectStart`, gives each frame a
  `timeSeconds` uniform, re-damages live effect bands, emits a final settle
  repaint, and exposes remaining animation time to AppKit/headless scheduling.
  Effect kind 0 is none, 1 is ink bloom, and 2 is reserved for visual bell.
- `Sources/LabanCore/GlyphEffectTimeline.swift` is the CPU reference for that
  effect registry and for deterministic liveness tests. Metal mirrors the
  formulas and constants that it needs.

Those Slug facilities are the implementation substrate for this plan. The
previous renderer-neutral proposal was based on an incorrect reading of the
live branch: `SlugGlyphGPUInstance` already has effect kind/start fields, the
shader already evaluates time per glyph, and the renderer already owns bounded
effect pumping. This plan claims effect kind **3** for foreground motion.

The existing 64-byte `SlugGlyphGPUInstance` has no room for a start color and
duration. Do not grow it: doing so would charge every static glyph a permanent
bandwidth cost. Do not draw old and new colors as two source-over glyphs:
two half-alpha instances produce 75% combined coverage and an order-biased
mixture. Instead, active motion glyphs use a separate 96-byte
`SlugGlyphMotionGPUInstance` and a dedicated vertex function. Static glyphs
remain byte-for-byte on the existing 64-byte structure and pipelines. The
motion vertex emits the existing `SlugGlyphVertexOut`, so the analytic
coverage, grayscale, subpixel accumulation, translucent composition, and
fragment code remain shared.

Relevant data flow:

- `Sources/LabanCore/FrameProducer.swift` resolves terminal foreground and
  background colors after faint, inverse, theme, transparency, and
  accessibility rules. Detection must compare these resolved values.
- `Sources/LabanCore/TerminalSurfaceController.swift` owns persistent
  per-session state and observes local/remote snapshot generations. It is the
  correct owner for cadence history and transition retargeting across view
  rebuilds.
- `Sources/LabanRenderer/FrameCommand.swift` is the shared render command.
  `glyphRun` already carries optional output-time metadata used only by Slug's
  effects. This plan adds optional semantic foreground-transition metadata;
  it is nil unless effective Slug smoothing is active. Other renderers ignore
  the field and never receive active metadata.
- `Sources/LabanApp/TerminalBitmapView.swift` and
  `Sources/LabanDebug/HeadlessDebugRuntime.swift` know the effective backend.
  They pass renderer eligibility and the cached configured setting into frame
  production. They must not infer eligibility from the requested renderer.
- `Sources/LabanCore/TerminalIdlePolicy.swift` already has the generic
  `glyphEffectAnimating` input. Slug's existing remaining-time and strip-frame
  latch feed it. This plan reuses that path; it does not add a second spinner
  idle-policy boolean or a second frame-pumping implementation.

ADR 0018 requires every animation to have an explicit wake source, bounded
liveness, a settle frame, and complete parking. ADR 0027 permits backend-owned
state when the backend owns the relevant cost model. This work follows both:
core detects semantic cadence, while Slug alone owns time-varying pixels and
reports actual rendered liveness.

The existing ink-bloom detector is not the spinner detector. In
`TerminalSurfaceController.cellContentFingerprint`, foreground, background,
flags, and intensity are intentionally omitted so color pulses do not restart
ink bloom. `stampFreshOutputTimestamps` also suppresses ink bloom while
terminal mouse tracking is active. Spinner motion therefore needs a separate
color-aware observation path that runs before and independently of that
suppression. Ink-bloom behavior and its tests remain unchanged.

### Terms used by this plan

- **Resolved foreground/background**: the exact packed `0xRRGGBBAA` colors
  `FrameProducer` would emit after terminal and accessibility rules.
- **Analytic glyph**: a glyph rendered from Slug curve/band geometry. Raster
  atlas and color-emoji fallback instances are not analytic and are ineligible.
- **Renderer eligible**: the effective renderer reported by the live backend
  is `slugGlyph`. Requested/configured Slug with an effective software/classic
  fallback is not eligible.
- **Observation**: one new local or remote terminal generation and the bounded
  changed cell region derived from resolved cell state.
- **Qualifying region**: one or two adjacent rows, no more than 32 columns
  wide, with no more than 32 changed cells.
- **Cadence run**: consecutive qualifying observations that remain spatially
  near and arrive 0.04...0.60 seconds apart.
- **Transition**: one cell's retained linear-light start foreground, target
  foreground, monotonic start time, and duration.
- **Motion command metadata**: optional `GlyphForegroundTransition` on a
  `FrameCommand.glyphRun`, containing a linear-light start color, start time,
  and duration. The run's normal foreground is the target.
- **Motion instance**: one `SlugGlyphMotionGPUInstance` for one analytic glyph.
  It contains the normal Slug instance fields plus start color and duration.
  One transitioning glyph produces one instance, never two.

## Design Decisions

### Gate behavior and cost on the effective Slug renderer

The effective feature predicate is:

    configuredEnabled && effectiveRenderer == .slugGlyph && !reduceMotion

Only when that predicate is true may the detector retain history, create
transition metadata, prewarm motion pipelines, or keep frames moving. When it
is false, frame commands and GPU cell payloads are identical to the pre-plan
path. Selecting another renderer or entering a renderer fallback clears
history/transitions and requests one authoritative frame if an effect was
live.

The persisted checkbox value is independent of renderer selection. A user may
leave it enabled and switch away from Slug; it becomes effective again only
for future output after Slug is effective. Settings disables the checkbox when
the configured selection is not Slug and explains why. Runtime debug state is
authoritative when configured Slug falls back.

### Interpolate one analytic glyph in linear light

Add `GlyphEffectTimeline.kindSpinnerForegroundMotion = 3`. Active motion cells
are removed from the ordinary `SlugGlyphGPUInstance` array and appended once
to a `SlugGlyphMotionGPUInstance` array. A dedicated `slugGlyphMotionVertex`
reads:

- normal position, outline, target linear foreground, glyph index, and
  dilation;
- effect start time;
- start linear foreground;
- transition duration.

For age `a`, calculate `u = clamp(a / duration, 0, 1)` and cubic smoothstep
`p = u * u * (3 - 2 * u)`. Return start exactly when `u <= 0`, target exactly
when `u >= 1`, and otherwise `mix(start, target, p)` in straight linear-light
RGBA. The target comes from Slug's existing
`SRGBRenderTargetColor.linearizedStraightRGBA`; expose/reuse that conversion
for the core reference sampler rather than duplicating transfer functions.

The motion vertex emits the existing `SlugGlyphVertexOut`. Add lazy motion
variants for every Slug vertex-pipeline shape that can render analytic glyphs:
grayscale alpha, subpixel accumulation, and the subpixel allocation-fallback
coverage/color passes. The existing fragments, analytic coverage math,
blending, and final resolve are unchanged. Prewarm the lazy variants when the
setting first becomes effectively enabled, before a cadence can activate.

At a fully covered pixel, red-to-blue at `p = 0.5` is linear
`(0.5, 0, 0.5, 1)`, which an sRGB target encodes to approximately
`(188, 0, 188, 255)`. Acceptance uses a small readback tolerance because GPU
rounding can differ by one encoded unit. The darker `(128, 0, 128, 255)` value
would prove interpolation happened in encoded space and fails this plan.

### Foreground-only eligibility

A cell creates a transition only when all of these remain identical between
authoritative states: grapheme cluster, display width, resolved background,
attributes, underline metadata, hyperlink identity, and geometry. Its resolved
foreground must change. The cell must be terminal content, not sidebar or
preedit, and must have no underline, strikethrough, or other decoration whose
color would otherwise snap separately.

The core can identify semantic eligibility but not whether Slug will take its
analytic or raster/color fallback. It may attach metadata to an otherwise
eligible run. `SlugGlyphRenderer.appendGlyphRun` moves the glyph into the
motion array only after analytic resolution succeeds. Raster/color fallback
instances ignore the metadata, render the target immediately, do not enter the
live-effect set, and increment a diagnostic fallback counter. Actual renderer
liveness, not requested core transitions, drives the display link.

Background changes, decorated text, attribute/layout changes, different
glyphs, and fallback glyphs snap. Do not add motion fields to
`SlugSolidInstance`, `SlugTextureInstance`, `TerminalCellPayload`, software,
classic Metal, GPU-driven Metal, or Vector Glyph.

### Independent color-aware cadence history

Do not change `cellContentFingerprint`, `freshnessFromCellDiff`, or mouse-
tracking suppression; they are ink-bloom regression contracts. Add a separate
spinner cell-state extraction in `FrameProducer` that reuses the same resolved
visual calculation used by commands.

`TerminalSurfaceController` retains the previous resolved cell grid per session
so any changed row can be compared against its same-glyph baseline. The grid is
bounded by the terminal dimensions and cheap to retain. Populate the cache on
each new generation while the effective feature predicate is true, including the
first two qualifying observations. Observe a local generation once per nonzero
`session.dirtyGeneration()`. Observe a remote generation once per
`LabandSnapshotFrame.generation` and bind remote state to `incarnationId`.

Clear history and transitions when eligibility becomes false, session identity
disappears, dimensions change, a remote incarnation changes, or
`invalidateSessionSyncCache()` runs.

### Cadence qualification

The detector is a pure AppKit-free value type with no process-name, literal-
text, mouse-tracking, renderer-object, or settings lookup.

- A spatial observation qualifies when it affects one row or two adjacent
  rows, spans at most 32 columns, and changes at most 32 cells.
- Consecutive observations stay in one run when row ranges overlap or are one
  row apart, column ranges overlap or are within four columns, and the gap is
  0.04...0.60 seconds inclusive.
- An out-of-bounds observation starts a new run of length one.
- Detection becomes active on the third consecutive qualifying observation.
- Estimated cadence is the arithmetic mean of at most the last four gaps,
  clamped to 0.04...0.60 seconds.
- Detection becomes inactive after `min(2 * cadence, 0.8)` seconds without
  another qualifying observation.

Mouse-tracking state is diagnostic metadata only. Add an explicit test and E2E
step with DECSET mouse tracking active throughout.

### Continuous retargeting

On an eligible third-or-later update, start from the foreground actually being
displayed at that instant. If a prior transition is live, sample its
linear-light curve using the same CPU reference formula and use that float
color as the new start. Do not quantize through packed sRGB and do not restart
from the prior terminal endpoint. The new authoritative packed foreground
becomes the target after conversion to linear light.

Duration is the detector's estimated cadence, clamped to 0.04...0.60 seconds.
At or after duration, commands omit motion metadata and carry the ordinary
target foreground. Slug's previous live-band union guarantees that this
static target frame is the settle repaint. Retain observation baseline
separately from transitions so evicting a completed transition does not make
the next tick look new.

Cap retained transitions at 64 cells. If a candidate exceeds the cap, snap it
and increment an overflow counter.

### Reuse Slug's existing effect scheduling

Extend Slug's live-effect record with an explicit duration. Kinds 1 and 2 use
their existing fixed durations; kind 3 uses command metadata. Motion instances
join `liveGlyphEffects`, the previous live bands are unioned into damage, and
`glyphEffectAnimatingRemainingSeconds` continues to drive the existing
`glyphEffectAnimating` idle-policy rung and strip-frame latch at 30 fps.

Do not add `spinnerMotionAnimating` to `TerminalIdlePolicy`, do not add
`FrameWakeSource.spinnerMotion`, and do not create another renderer pumping
loop. Detector activity alone never wakes or pumps. If metadata resolves only
to fallback glyphs, Slug reports no live effect and the link parks.

Spinner metadata takes precedence over ink bloom on the same glyph. Ineligible
cells retain current ink-bloom behavior. Effect kind 3 must work whether the
separate ink-bloom setting is on or off.

### Cached setting and UI

`SpinnerMotionSmoothingSettings` follows the notification-driven settings
contract. `TerminalBitmapView`, `HeadlessDebugRuntime`, and
`SettingsWindowController` cache the configured value and renderer selection;
writes post a notification and observers update cached state. No per-frame
render/glyph-build path reads `UserDefaults` or environment variables.

The Rendering tab contains **Smooth spinner motion** with help text
**Available with Slug Glyph; smooths foreground-color spinner ripples.** The
checkbox is disabled while configured renderer selection is not Slug. An
environment override disables editing and explains that persistence is
locked. The debug action reports configured, renderer-eligible, Reduce Motion,
effective, persisted, effective renderer, and ineligibility reason rather than
blindly returning success.

## Plan of Work

### M0 — Slug-gated color observations and transition metadata

Goal: detect eligible foreground ripples and describe transitions without
changing pixels or scheduling.

1. Add `Sources/LabanCore/SpinnerMotion.swift` with pure detector, observation,
   session-state, diagnostics, and linear-light transition sampler types.
2. Make the existing sRGB-to-linear straight-RGBA helper in
   `Sources/LabanRenderer/SRGBRenderTargetColor.swift` a reusable public API
   for `LabanCore`; add the inverse encoded-sRGB helper only for tests/debug
   readback expectations. Pin standard transfer-function values.
3. Add public `GlyphForegroundTransition` in
   `Sources/LabanRenderer/FrameCommand.swift` with
   `startLinearRGBA: SIMD4<Float>`, `startTimestampSeconds: Double`, and
   `durationSeconds: Double`. Add optional `foregroundTransition` to
   `glyphRun`, default nil. Update exhaustive matches, debug serialization,
   and capture/replay so nil old artifacts remain valid.
4. In `FrameProducer`, factor resolved cell visuals once for normal commands
   and spinner state extraction. Add an optional per-cell transition map to
   local and remote command production. Split runs only at transition metadata
   boundaries. Do not add the map to `TerminalCellPayload`.
5. In `TerminalSurfaceController`, add per-session generation-deduplicated
   state, bounded row history, detector, continuous-retarget transition map,
   and reset rules. Add request inputs for cached configured enabled and
   effective-renderer eligibility; combine them with Reduce Motion.
6. Add detector, linear-color, local/remote generation, incarnation, mouse-
   tracking, transition-retarget, run-splitting, nil-identity, and renderer-
   gate tests. Iterate every `RendererSelection`: only effective `slugGlyph`
   may produce non-nil transition metadata.

M0 acceptance: deterministic tests activate on the third same-glyph,
foreground-only update under Slug eligibility, including with mouse tracking.
Non-Slug, disabled, Reduce Motion, background-changing, decorated, or
different-glyph inputs emit nil metadata and unchanged commands/payloads. No
new display-link input exists yet.

### M1 — Single-instance Slug shader interpolation and bounded pumping

Goal: Slug turns transition metadata into a visually superior one-glyph GPU
interpolation and reuses its existing effect scheduler.

1. Claim `GlyphEffectTimeline.kindSpinnerForegroundMotion = 3`. Preserve
   kinds 0/1/2 and do not add the dynamic duration to
   `maxDecaySeconds`, which remains the output-stamp window for fixed effects.
2. In `SlugGlyphRenderer.swift`, add a flattened, 96-byte
   `SlugGlyphMotionGPUInstance` and a separate motion array/buffer. Keep
   `SlugGlyphGPUInstance` exactly 64 bytes. Add explicit layout tests for both
   Swift structs and Metal mirrors.
3. In `VectorGlyphShaders.metal`, add the 96-byte mirror and
   `slugGlyphMotionVertex`. Implement endpoint branches, smoothstep, and
   linear-light straight-RGBA mix. Return the existing vertex output and reuse
   all fragment functions.
4. Add lazily created/prewarmed motion vertex-pipeline variants for grayscale,
   subpixel accumulation, and subpixel fallback coverage/color. Refactor buffer
   readiness so a frame containing only motion glyphs still renders. Draw
   static and motion arrays through their corresponding vertex pipelines in
   every opaque/translucent and grayscale/subpixel path.
5. In `appendGlyphRun`, attempt normal analytic resolution before routing an
   annotated cell to the motion array. Fallback glyphs snap, do not enter live
   state, and increment diagnostics. One eligible glyph creates exactly one
   motion instance and zero ordinary instances.
6. Extend `LiveGlyphEffect` with duration, use metadata duration for kind 3,
   and keep existing live-band union, remaining-time publication, settle
   repaint, 30 fps policy, and strip-frame latch. Spinner metadata wins over
   ink bloom only on the annotated glyph.
7. Prewarm motion pipelines when effective enablement changes false-to-true.
   Disabling, Reduce Motion, or backend switch clears core transition metadata,
   invalidates affected bands, renders one target frame, and lets existing
   liveness fall to zero.
8. Add renderer tests covering shader/CPU curve parity, approximate
   `0xBC00BCFF` red/blue midpoint at a fully covered pixel, exact endpoints,
   early-retarget continuity, constant opaque-glyph coverage, one-instance
   count, grayscale, RGB subpixel accumulation, subpixel allocation fallback,
   nonopaque composition, all-motion/no-static frames, fallback snapping,
   simultaneous ink-bloom setting, settle repaint, and parking.
9. Add a focused `SlugSpinnerMotionBench` with 16 analytic motion glyphs at
   the 30 fps tier. Record baseline and feature results; reject any design that
   duplicates glyph instances or changes static-instance stride.

M1 acceptance: Slug alone renders the deterministic midpoint as the expected
linear-light color with one analytic instance and unchanged coverage. Other
renderers snap. Static Slug frames retain their original structure, and the
display link parks after the target settle frame.

### M2 — Settings, diagnostics, E2E, docs, and review

Goal: expose the capability honestly, prove the rendered result, and preserve
the renderer boundary in product/architecture documentation.

1. Add `SpinnerMotionSmoothingSettings` with UserDefaults key
   `LabanSpinnerMotionSmoothingEnabled`, environment override
   `LABAN_SPINNER_MOTION_SMOOTHING_ENABLED`, default false, change
   notification, cached read helpers, and a persistence result.
2. Add the Rendering checkbox/help/accessibility/localization strings. Update
   enablement immediately when renderer selection changes. Tests pin Slug-only
   availability, environment lock, default off, and cached notification flow.
3. Wire cached configured setting and effective backend eligibility through
   `TerminalBitmapView` and `HeadlessDebugRuntime`. Setting/Reduce Motion/
   backend changes wake exactly one reset frame when needed.
4. Add debug action `setSpinnerMotionSmoothingEnabled`, reset action
   `resetSpinnerMotionDiagnostics`, `GET /debug/spinner-motion`, and a non-null
   `/debug/state.spinnerMotion` block. Report configured/effective renderer,
   renderer eligibility, Reduce Motion, effective enabled, detector state,
   requested transitions, analytic motion instances, fallback snaps, effect
   kind, remaining time, frames, settle frames, and parks restored.
5. Extend render journals with optional backward-compatible spinner-motion
   state and update `scripts/render-journal-summary`.
6. Create `fixtures/spinner-motion-smoothing.scenario.json`, pinned to
   `renderer: slugGlyph`, opaque background, deterministic time, and mouse
   tracking on. Exercise disabled exact output, third-observation activation,
   50% linear-light midpoint pixel, early retarget, exact target settlement,
   one-instance diagnostics, and restored parking. Save endpoint/midpoint/final
   screenshots, final state, and final diagnostics.
7. Add a non-Slug gating test/scenario that selects classic, leaves the
   configured checkbox true, and proves effective false, nil transition
   metadata, endpoint pixels, zero motion instances, and zero effect wakes.
8. Wire scenarios into `scripts/test-e2e`. Update debug schemas/catalogs,
   `docs/process/dev-process.md`, `docs/product/spec.md`, and renderer safety
   guidance.
9. Add `docs/adr/0030-spinner-motion-is-a-slug-capability.md` and index it in
   `docs/adr/README.md`. Record that Slug-only linear-light analytic
   interpolation is intentional; renderer parity would require a future ADR
   backed by an equally capable backend substrate.
10. Execute the Review Gate below with a fresh agent. The plan is not complete
    until the full gate passes against one named implementation commit.

## Progress

- [x] (2026-07-20) Initial plan filed.
- [x] (2026-07-20) First review revision replaced an invalid two-instance
  cross-fade with renderer-neutral CPU color overrides.
- [x] (2026-07-20) Plan corrected after inspecting the live Slug effect
  channel: selected a Slug-only, one-analytic-instance, linear-light GPU path;
  removed renderer-neutral parity and duplicate scheduling requirements.
- [x] (2026-07-20) M0 — Slug-gated color observations and transition metadata.
- [x] (2026-07-20) M1 — single-instance Slug motion pipelines and bounded effect pumping.
- [x] (2026-07-20) M2 — gated UI, diagnostics, deterministic E2E, ADR/docs, and CI wiring.
- [x] (2026-07-20) Review Gate passed against commit under test.
- [x] (2026-07-20) Bug fix: `stampFreshOutputTimestamps` preserves `foregroundTransition` metadata when stamping output; `SpinnerMotionDetector` retains the full grid baseline instead of an LRU row cap so top-row spinners qualify correctly.
- [x] (2026-07-20) Bug fix: opening Settings no longer parks Slug motion in a
  still-visible terminal. Animation visibility now follows app activity plus
  actual terminal-window visibility instead of key-window ownership;
  application activation has its own wake. The focused wake/visibility suite
  passes with explicit Settings-window, inactive, hidden, miniaturized,
  occluded, and reactivation coverage.
- [x] (2026-07-21) Bug fix: retarget sampling now matches what the renderer
  actually blends toward. After a cadence/region reset the cell can snap past
  a stale, settled transition whose stored target no longer represents the
  displayed color; sampling that stale target produced an instantaneous drop
  plus smooth re-rise at sweep tails (the "Working" `n`/`g` arrhythmia).
  Retargets now sample the existing transition toward the cell's current
  authoritative foreground. Regression tests:
  `testRetargetAfterResetStartsFromDisplayedColorNotStaleSettledTarget` and
  `testRetargetAfterResetSamplesLiveTransitionTowardCurrentColor` (both red
  on the old code, green on the fix).
- [x] (2026-07-21) Finely sampled bypass: sources whose observed change
  cadence falls below 100 ms (exit hysteresis at 120 ms) render
  authoritatively; interpolation is reserved for sparse, discrete jumps.
  Capture analysis showed finely sampled true-color sweepers (Codex's ~74 ms
  shimmer, ~50 ms class sources) already read as smooth, so interpolation
  only filtered an already time-shaped signal. `testCadenceClampedToMinimum`
  became `testMinimumCadenceEngagesFinelySampledBypass`; new coverage:
  `testFinelySampledSourceIsRenderedAuthoritatively`,
  `testSparseSourceDoesNotEngageFinelySampledBypass`,
  `testFinelySampledBypassHysteresis`. Diagnostics expose
  `finelySampledBypass`.
- [x] (2026-07-24) Removed the Settings-window checkbox and the
  `docs/product/spec.md` entry to take the feature off the current product
  surface ahead of merging this branch; everything else this plan built
  (detector, renderer/shader pipeline, traveling-wave amendment, env-var
  override, debug endpoints) is untouched — see ADR 0030's 2026-07-24
  amendment.

## Surprises & Discoveries

- (2026-07-24) An independent external review, run while preparing this
  branch for merge (after the UI checkbox was already removed), found two
  pre-existing issues in the capability this plan kept latent. Verified
  against the code, not taken on faith; not fixed here — both are inside
  detector/remote-snapshot internals well outside what was asked for
  (remove the product surface, question always-on costs), and the feature
  is unreachable from the UI regardless of these bugs.
  - **Remote (laband) spinner motion is effectively one-shot.**
    `spinnerMotionTransitions` (`TerminalSurfaceController.swift`) only
    re-observes cell state on the remote path when
    `spinnerMotionLastRemoteDirty[sessionID] != remote.dirty` changes,
    mirroring the local path's `dirtyGeneration` check. But
    `LabandSnapshotRingLayout.swift:930` hardcodes `dirty: true`
    unconditionally on every remote snapshot response, so after the first
    observation the stored value is permanently `true` and the comparison
    never flips again — every later frame takes the `activeTransitions(at:)`
    branch instead of observing new state. A fix needs a real
    generation/sequence signal on `LabandSnapshotResponse` (mirroring
    `Session.dirtyGeneration()`), not a sticky bool.
  - **Full-grid cell-state cost when actually enabled.** Each dirty
    generation calls `producer.spinnerCellStates(from:)`
    (`FrameProducer.swift`), which visits every cell of the grid and builds a
    full `[SpinnerMotionCellKey: SpinnerMotionCellState]` dictionary
    (`reserveCapacity(rows * cols)`) before the detector narrows to the
    qualifying region; the detector also retains a full-grid
    `previousCells` copy. On a large grid at spinner cadence this is real
    per-generation allocation and UTF-8 decoding, though it only runs at all
    when the (now UI-unreachable) setting is on.
- Observation: the live Slug instance already has `effectKind` and
  `effectStart`, and Slug already owns a `timeSeconds` uniform, live-band
  damage, remaining-time publication, and a settle-frame pump.
  Evidence: `SlugGlyphGPUInstance`, `SlugGlyphGPUUniforms`,
  `unionLiveGlyphEffectBands`, and `updateLiveGlyphEffectState` in
  `Sources/LabanRenderer/SlugGlyphRenderer.swift`, plus
  `slugGlyphEvaluateEffect` in `VectorGlyphShaders.metal`.
- Observation: Slug converts packed terminal colors to straight linear-light
  RGBA before shader blending. This makes a shader transition materially
  better than the prior encoded-channel CPU interpolation: the red/blue
  midpoint encodes near `0xBC00BCFF`, not `0x800080FF`.
  Evidence: `SRGBRenderTargetColor.linearizedStraightRGBA` and Slug's sRGB or
  linear-float render targets.
- Observation: the existing cell fingerprint intentionally ignores color and
  intensity, and ink-bloom stamping suppresses mouse-tracking TUIs. Spinner
  detection must remain a separate resolved-color path.
  Evidence: `testCellFingerprintIgnoresColorOnlyChanges` and the
  `.suppressedTUI` return in `stampFreshOutputTimestamps`.
- Observation: Slug ignores `glyphRun.background` while building glyph
  instances; terminal backgrounds are separate solid commands. Foreground-only
  scope preserves the one-analytic-instance advantage without adding a second
  shader system for solids.
- Observation: two half-alpha source-over glyphs are not a dissolve. They
  produce 75% combined coverage and an order-biased color. A single shader
  color mix is required.
- Observation: the Settings window becoming key caused the terminal's
  `didResignKey` observer and per-frame policy to classify the still-visible
  terminal as hidden. That set both Slug's present link and the main display
  link to parked, leaving only one authoritative render per spinner update and
  no interpolation frames. Closing Settings restored key status and therefore
  appeared to make smoothing start working.
  Evidence: all four animation visibility checks in `TerminalBitmapView`
  required `window.isKeyWindow`; the symptom stopped immediately when Settings
  closed.
- Observation: settled transitions are never evicted from the detector's
  `transitions` map, and the Slug motion shader blends a transition's start
  color toward the run's *current* foreground — not toward the target stored
  in the transition. While the detector stays active the two coincide, but
  real spinner sources (verified against `codex-rs/tui/src/shimmer.rs`) emit
  interleaved change-bursts at independent cadences (a word sweep every
  ~74 ms plus a bullet sweep every ~95 ms), so the qualifying run resets
  regularly: change-gaps below the 40 ms floor when bursts land close
  together, and `regionsAreNear` failures when a bullet-only region follows a
  tail word-region. During inactive windows cells snap authoritatively; on
  reactivation the old retarget sampled the stale settled transition and
  jumped the cell to its long-dead target before easing to the new one.
  Evidence: composite A/B captures
  (`~/Library/Logs/Laban/captures/appkit-2026-07-21T17-56-24Z` smoothing on,
  `...T17-56-50Z` off) with identical PTY streams; window-grab luminance
  showed a one-frame 0.91→0.55 drop plus re-rise exactly when the highlight
  leaves the word, absent with smoothing off; a Python port of source +
  detector + renderer reproduced the mismatch events.

## Decision Log

- Decision: Gate spinner smoothing on the effective Slug Glyph renderer.
  Rationale: Slug uniquely combines an analytic one-glyph path, per-glyph GPU
  time, and bounded effect pumping. Other backends would require CPU command
  recoloring or duplicate glyph composition and would deliver a worse feature.
  Date/Author: 2026-07-20 / user and Codex

- Decision: Use a separate 96-byte motion instance/pipeline and keep the
  ordinary 64-byte instance unchanged.
  Rationale: active glyphs need start color and duration, but charging all
  static glyphs extra bandwidth would regress Slug's normal path.
  Date/Author: 2026-07-20 / Codex

- Decision: Interpolate straight RGBA in linear light inside the motion vertex
  shader and render one analytic glyph.
  Rationale: this preserves coverage and alpha semantics, avoids ghosting, and
  matches Slug's existing linear-light composition model.
  Date/Author: 2026-07-20 / Codex

- Decision: Limit committed behavior to undecorated analytic glyphs whose only
  visual change is foreground color.
  Rationale: backgrounds are solids, raster/color fallbacks use a different
  pipeline, and different glyph shapes or decoration motion need separate
  visual designs.
  Date/Author: 2026-07-20 / Codex

- Decision: Preserve ink-bloom fingerprints/suppression and add a separate
  color-aware cadence history.
  Rationale: color pulses intentionally do not restart ink bloom, while
  fullscreen mouse-tracking TUIs are a primary spinner scenario.
  Date/Author: 2026-07-20 / Codex

- Decision: Reuse Slug's `glyphEffectAnimating` scheduler rather than add a
  spinner-specific idle-policy input or wake loop.
  Rationale: actual analytic instances, not detector intent, must determine
  liveness; the existing channel already satisfies ADR 0018.
  Date/Author: 2026-07-20 / Codex

- Decision: Retarget from the currently displayed linear-light float color.
  Rationale: restarting from a terminal endpoint or quantizing through packed
  sRGB creates a visible discontinuity under cadence jitter.
  Date/Author: 2026-07-20 / Codex

- Decision: Sample retargets toward the cell's current authoritative
  foreground instead of the transition's stored target.
  Rationale: this is what the renderer actually blends toward
  (`GlyphForegroundTransition` carries no target; the shader mixes start color
  into the run foreground). It is behavior-identical while the detector
  remains active and restores C0 continuity exactly after cadence/region
  resets, which is where the stale-target drop/re-rise artifact lived.
  Velocity (C1) discontinuity at retargets remains a known, smaller term.
  Date/Author: 2026-07-21 / Kimi (user-directed)

- Decision: Bypass interpolation entirely for finely sampled sources
  (observed change cadence < 100 ms, exit > 120 ms with hysteresis).
  Rationale: capture A/B of the real Codex shimmer showed the OFF path is
  already perceptually smooth — the source emits a spatially cosine-shaped
  band at ~74 ms per-cell cadence — so interpolation had no upside there and
  only added filtering artifacts. Smoothing's value is confined to sparse,
  discrete jumps; cadence is the product-neutral classifier (no process,
  text, or glyph identity). The run/cadence bookkeeping stays live while
  bypassed so the bypass can disengage when a source slows down.
  Date/Author: 2026-07-21 / Kimi (user-directed)

- Decision: Persist the setting but make effective enablement depend on Slug
  and Reduce Motion, with explicit unavailable UI/debug reasons.
  Rationale: the feature must be discoverable without implying unsupported
  behavior on another or fallback renderer.
  Date/Author: 2026-07-20 / Codex

- Decision: Separate terminal input focus from animation visibility.
  Rationale: PTY focus must follow the key terminal window, but renderer work
  depends on whether pixels can be seen. A same-app Settings key window changes
  the former without changing the latter; whole-app deactivation is observed
  separately so background animation still parks.
  Date/Author: 2026-07-20 / Codex

## Review Gate

A fresh agent must run every item against the completed implementation. On
failure, record exact file/line findings here, fix them, and rerun the entire
gate. Stop after three failures of the same item and escalate per `PLANS.md`.

- [ ] Run
  `rtk rg -n "kindSpinnerForegroundMotion|SlugGlyphMotionGPUInstance|slugGlyphMotionVertex" Sources/LabanCore/GlyphEffectTimeline.swift Sources/LabanRenderer/SlugGlyphRenderer.swift Sources/LabanRenderer/VectorGlyphShaders.metal`.
  Expect all three concepts in their named files and effect kind 3.
- [ ] Run
  `rtk rg -n "spinnerMotion|foregroundTransition" Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/VectorGlyphRenderer.swift`.
  Expect zero hits: non-Slug GPU renderers own no spinner behavior.
- [ ] Run `rtk swift test --filter SpinnerMotionDetectorTests` and expect exit
  0, including third-observation, reset, bounds, cadence, and mouse-tracking
  cases.
- [ ] Run `rtk swift test --filter SpinnerMotionTransitionTests` and expect
  exit 0, including linear-light transfer values, exact endpoints, smoothstep,
  early-retarget continuity, and no packed-sRGB requantization.
- [ ] Run `rtk swift test --filter SpinnerMotionCommandTests` and expect exit
  0, including local/remote run splitting, nil byte identity, background/
  decoration/different-glyph snap, and capture compatibility.
- [ ] Run `rtk swift test --filter SpinnerMotionRendererGateTests` and expect
  exit 0. It must iterate every renderer selection and prove only an effective
  Slug backend emits transition metadata; configured-Slug fallback is false.
- [ ] Run `rtk swift test --filter SlugGlyphGPUContractTests` and expect exit
  0, including ordinary instance stride 64, motion instance stride 96, Metal
  mirror offsets, and kind values 0/1/2/3.
- [ ] Run `rtk swift test --filter SlugSpinnerMotionRendererTests` and expect
  exit 0, including approximately `0xBC00BCFF` red/blue midpoint (and an
  explicit not-`0x800080FF` assertion), one instance per glyph, unchanged
  coverage, every Slug pipeline shape, fallback snap, settle, and park.
- [ ] Run `rtk swift test --filter SlugSpinnerMotionBench` and expect exit 0
  with output reporting `motionInstances=16 ordinaryInstances=0` and no change
  to static instance stride.
- [ ] Run
  `rtk swift test --filter SpinnerMotionSettingsTests` and
  `rtk swift test --filter SettingsWindowControllerTests`; expect exit 0 with
  Slug-only availability and environment-lock coverage.
- [ ] Run
  `rtk ./scripts/run-debug-script fixtures/spinner-motion-smoothing.scenario.json --artifacts=.artifacts/review/spinner-motion-smoothing`.
  Expect exit 0 and `debug script passed`; the report must contain mouse-
  tracking, linear-light midpoint, early-retarget, one-instance, settle, and
  park assertions.
- [ ] Run the non-Slug gating scenario/test and expect configured true,
  renderer eligible false, effective false, zero motion instances, zero motion
  frames, and exact target pixels.
- [ ] Run
  `rtk rg -n "spinner-motion-smoothing.scenario.json" scripts/test-e2e` and
  expect one executable invocation.
- [ ] Run
  `rtk rg -n "Smooth spinner motion|Slug Glyph" Sources/LabanApp/SettingsWindowController.swift Sources/LabanApp/Resources/Localizable.xcstrings docs/product/spec.md docs/adr/0030-spinner-motion-is-a-slug-capability.md`.
  Expect hits in all four files.
- [ ] Run `rtk ./scripts/test-e2e` and expect exit 0.
- [ ] Run `rtk ./scripts/check` and expect exit 0.
- [ ] Run
  `rtk jq -e '.spinnerMotion.effectiveEnabled == true and .spinnerMotion.rendererEligible == true and .spinnerMotion.motionInstanceCount == 0' .artifacts/review/spinner-motion-smoothing/final-state.json`
  and
  `rtk jq -e '.midpointLinearLightPassed == true and .settleFrames == 1 and .parksRestored >= 1' .artifacts/review/spinner-motion-smoothing/final-diagnostics.json`.
  Expect both commands to exit 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

_(empty)_

## Concrete Steps

Work from `/Users/user/wrk/laban`. Prefix repository commands with `rtk`.

After M0:

    rtk swift test --filter SpinnerMotionDetectorTests
    rtk swift test --filter SpinnerMotionTransitionTests
    rtk swift test --filter SpinnerMotionCommandTests
    rtk swift test --filter SpinnerMotionRendererGateTests
    rtk swift test --filter TerminalSurfaceControllerTests

Expect zero failures. Existing
`testCellFingerprintIgnoresColorOnlyChanges` must remain green.

After M1:

    rtk swift test --filter SlugGlyphGPUContractTests
    rtk swift test --filter SlugSpinnerMotionRendererTests
    rtk swift test --filter SlugSpinnerMotionBench
    rtk swift test --filter TerminalIdlePolicyTests

Expect zero failures. The renderer transcript must include:

    start=FF0000FF target=0000FFFF progress=0.5 encoded≈BC00BCFF instances=1

After M2:

    rtk swift test --filter SpinnerMotionSettingsTests
    rtk swift test --filter SettingsWindowControllerTests
    rtk ./scripts/run-debug-script fixtures/spinner-motion-smoothing.scenario.json
    rtk ./scripts/test-e2e

Expect the Slug scenario to print `debug script passed`, save endpoint,
midpoint, retarget, and final screenshots, and report one motion instance per
eligible glyph. Expect the non-Slug gate to report effective false and zero
motion frames.

Before review/ship:

    rtk ./scripts/check
    rtk git status --short

Inspect status and keep unrelated user files out of changesets. Commit
milestones as focused, single-reason commits.

## Validation and Acceptance

The implementation is accepted only when all of the following are true:

1. With effective Slug and the setting enabled, the third qualifying
   same-glyph foreground-only update starts motion; mouse tracking may remain
   enabled for the entire run.
2. At deterministic midpoint, a fully covered red-to-blue glyph pixel reads
   approximately `0xBC00BCFF`, not `0x800080FF`, and one analytic motion glyph
   is represented by exactly one GPU instance.
3. Opaque glyph coverage/alpha does not dip or grow during the transition, and
   no old/target glyph copies overlap.
4. A fourth update arriving before settlement starts from the currently
   displayed linear-light float color without a jump or encoded-sRGB
   requantization.
5. Background changes, decorations, different glyphs/widths/attributes,
   raster/color fallbacks, resize/incarnation changes, and overflow regions
   snap to authoritative current state.
6. Software, classic, GPU-driven, and Vector Glyph always snap. Configured
   Slug that falls back to another effective backend also snaps and reports an
   explicit renderer-ineligible reason.
7. With the setting off or Reduce Motion on, commands, payloads, rendered
   pixels, display-link wakes, and parking match the pre-plan path.
8. Disabling the setting, enabling Reduce Motion, or switching away from Slug
   during motion produces one exact target settle frame, clears actual Slug
   liveness, and restores parking.
9. Ink bloom remains unchanged. Spinner kind 3 works with ink bloom configured
   either on or off and takes precedence only for annotated cells.
10. The UI states Slug-only availability, defaults off, updates live with
    renderer selection, and never implies an environment-locked write applied.
11. The deterministic Slug and non-Slug gate scenarios run in
    `scripts/test-e2e`; rendered artifacts, diagnostics, `scripts/check`, and
    the fresh Review Gate all pass against one named commit.
12. Opening Settings while a qualifying spinner runs does not interrupt Slug
    interpolation in the visible terminal. Deactivating Laban or hiding,
    minimizing, or fully occluding the terminal still parks animation, and
    reactivating Laban explicitly wakes the frame loop.

## Idempotence and Recovery

The setting defaults off and the ordinary 64-byte Slug instance/pipelines stay
unchanged. M0 adds only nil-default metadata and gated state. M1 motion
pipelines are lazy and can be retried after allocation or compilation failure;
failure must snap to target, clear live motion, and report a fallback reason,
never leave a glyph frozen mid-transition.

Re-running tests/scenarios is safe; artifacts use run-scoped directories. If
implementation stops mid-feature, set `LabanSpinnerMotionSmoothingEnabled` to
false, clear the environment override, and relaunch. The disabled path renders
authoritative colors without transition metadata. Revert focused milestone
commits with `git revert <commit>`; do not alter ink-bloom fingerprints, disable
mouse tracking, or route another renderer through Slug as recovery.

## Interfaces and Dependencies

End-state interfaces that must exist:

- `Sources/LabanCore/SpinnerMotion.swift`: pure detector, bounded session
  state, diagnostics, and linear-light transition sampler.
- Public reusable sRGB/linear straight-RGBA conversion in
  `Sources/LabanRenderer/SRGBRenderTargetColor.swift`.
- `GlyphForegroundTransition` with linear start color, monotonic start, and
  duration; optional `FrameCommand.glyphRun.foregroundTransition` defaults nil.
- `FrameProducer` local/remote command functions accept an optional per-cell
  transition map; `TerminalCellPayload` has no motion field.
- `TerminalSurfaceFrameRequest` carries cached configured enablement and
  effective-renderer eligibility; the controller combines them with Reduce
  Motion and owns generation/incarnation-bound transition state.
- `GlyphEffectTimeline.kindSpinnerForegroundMotion == 3`; existing fixed-effect
  stamp window remains unchanged.
- `SlugGlyphMotionGPUInstance`/Metal mirror at 96 bytes and dedicated
  `slugGlyphMotionVertex` pipeline variants; ordinary Slug instances remain 64
  bytes.
- Slug live-effect records accept dynamic duration for kind 3 and reuse
  `glyphEffectAnimatingRemainingSeconds`, live-band damage, settle repaint, and
  existing AppKit/headless scheduling.
- `SpinnerMotionSmoothingSettings`: notification-based, default-off,
  environment-overridable persisted setting.
- Settings > Rendering checkbox **Smooth spinner motion**, enabled only for
  configured Slug and accompanied by Slug-only help text.
- Debug action `setSpinnerMotionSmoothingEnabled`, reset action
  `resetSpinnerMotionDiagnostics`, `GET /debug/spinner-motion`, non-null
  `/debug/state.spinnerMotion`, and optional journal state.
- Slug and non-Slug deterministic scenarios wired into `scripts/test-e2e`.
- ADR 0030 recording the intentional Slug-only capability boundary.

No new package dependency is required. No spinner behavior, GPU field, shader,
or retained transition state is permitted in software, classic Metal,
GPU-driven Metal, or Vector Glyph.
