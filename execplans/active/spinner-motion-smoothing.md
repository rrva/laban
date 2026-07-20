# Motion-smoothed ANSI/ASCII spinners

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root. Keep `Progress`, `Surprises & Discoveries`, `Decision
Log`, and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Many terminal programs repaint a small status region at a modest, steady
cadence. Claude Code, for example, can leave the letters of a status verb in
place while a foreground-color ripple moves across them. Laban currently
shows each real update as a discrete color jump.

After this work, a user can enable **Smooth spinner motion** in Settings. When
the same glyphs in a small, steadily updating region change foreground or
background color, Laban displays one copy of each current glyph and gradually
interpolates its colors from the previously displayed colors to the new
colors. There is no overlapping old glyph, opacity dip, or ghost image. The
behavior is renderer-neutral: software, classic Metal, GPU-driven Metal,
Vector Glyph, and Slug Glyph consume the same interpolated colors. Fullscreen
TUIs that enable terminal mouse tracking remain eligible; the detector never
matches process names or literal output text.

The setting is off by default, and macOS Reduce Motion force-disables it.
While disabled, both frame commands and `TerminalCellPayload` are byte-for-byte
equivalent to the pre-plan output and spinner detection does not keep the
display link running. When an enabled transition settles, a final target-color
frame is rendered and the display link parks exactly as it does today.

The committed scope is deliberately color-only: the grapheme cluster, display
width, attributes, underline metadata, and hyperlink identity must remain
unchanged. A spinner that substitutes different characters, such as a Braille
sequence, still changes instantly. Different-glyph motion synthesis is
deferred because it requires a separate visual/compositing design rather than
two ordinary source-over glyphs.

How to see the result after implementation:

1. Open Settings > Rendering and enable **Smooth spinner motion**.
2. Run the deterministic scenario in
   `fixtures/spinner-motion-smoothing.scenario.json`, or run a real program
   that repeatedly recolors a fixed status word.
3. During a transition, `/debug/pixel-probe` and
   `/debug/frame-commands` show colors strictly and predictably between the
   previous and new endpoint colors.
4. Disable the checkbox or enable Reduce Motion. The next frame displays the
   authoritative terminal colors immediately, no animation frames remain, and
   the link parks after the ordinary output hold expires.

## Context and Orientation

Laban renders an authoritative terminal snapshot through two equivalent data
paths:

- `Sources/LabanRenderer/FrameCommand.swift` defines the shared command
  language used by software, classic Metal, Vector Glyph, Slug Glyph, debug
  serialization, and capture/replay.
- `Sources/LabanRenderer/TerminalCellPayload.swift` is a renderer-neutral
  acceleration payload used by GPU-driven Metal. It is not a second source of
  truth; `Sources/LabanCore/FrameProducer.swift` derives both paths from the
  same snapshot and resolved terminal-cell visuals.
- `Sources/LabanCore/TerminalSurfaceController.swift` owns persistent,
  per-session render state and constructs `TerminalSurfaceFrame` values. It is
  the correct owner for cadence history and short-lived color transitions
  because it already survives view rebuilds without making a renderer into a
  retained scene graph.
- `Sources/LabanApp/TerminalBitmapView.swift` owns AppKit display-link policy.
  `Sources/LabanCore/TerminalIdlePolicy.swift` is its pure, GPU-free decision
  function. ADR 0018 requires every animation to have an explicit wake source,
  a bounded liveness signal, a final settle frame, and complete parking after
  the animation ends.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` is the headless equivalent
  of the visible app path. It must receive the same effective setting, clock,
  detector, transition, frame-command, and payload behavior.

The existing per-glyph ink-bloom channel on branch
`per-glyph-animation-channel` is not the implementation substrate for this
feature. It is useful precedent for deterministic virtual time, animation
liveness, and the trailing settle-frame latch, but its shader payload cannot
represent this design:

- `FrameCommand.glyphRun` carries only `outputTimestampSeconds`, not an effect
  kind or duration.
- `SlugGlyphGPUInstance` has no spare duration field.
- two ordinary source-over instances at half alpha produce 75% combined
  coverage and an order-biased mixture, not a true color interpolation.
- Slug ignores `glyphRun.background` while building glyph instances, so that
  mechanism cannot interpolate cell backgrounds.

This plan therefore adds no spinner effect kinds and makes no spinner changes
to `SlugGlyphGPUInstance`, `SlugGlyphGPUUniforms`, or
`Sources/LabanRenderer/VectorGlyphShaders.metal`.

The existing ink-bloom diff is also not the spinner detector. In
`TerminalSurfaceController.cellContentFingerprint`, foreground, background,
flags, and intensity are intentionally omitted so color pulses do not restart
ink-bloom. `stampFreshOutputTimestamps` additionally suppresses ink-bloom when
terminal mouse tracking is active. Both behaviors remain correct for
ink-bloom. Spinner motion needs a separate color-aware observation path that
runs before and independently of that suppression.

### Terms used by this plan

- **Cell**: one terminal row/column position and its grapheme cluster, display
  width, resolved foreground/background colors, renderable attributes,
  underline metadata, and hyperlink identity.
- **Resolved colors**: the exact packed RGBA values that `FrameProducer` would
  emit after inverse, faint, explicit-background opacity, accessibility, and
  theme rules have been applied. Interpolation operates on these values so
  command and payload paths cannot disagree.
- **Observation**: one new terminal generation and the bounded set of visible
  cells whose resolved render state changed from the previous generation.
- **Qualifying region**: one or two adjacent rows, no more than 32 columns
  wide, containing no more than 32 changed cells. This is the explicit meaning
  of “small” in this plan.
- **Cadence run**: consecutive qualifying observations whose regions remain
  spatially near one another and whose arrival gaps remain within the allowed
  timing band.
- **Transition**: one cell’s retained displayed start colors, authoritative
  target colors, monotonic start time, and duration. A transition changes only
  colors; it never retains or redraws an old glyph.
- **Color override**: the current interpolated foreground/background pair for
  a cell. `FrameProducer` consumes the same override while producing both
  frame commands and `TerminalCellPayload`.

## Design Decisions

### Renderer-neutral, single-glyph interpolation

Do not add `crossfadeIn` or `crossfadeOut` shader kinds. Instead, compute a
single interpolated foreground/background pair per transitioning cell before
`FrameProducer` emits either output path. `FrameProducer` still emits one
current glyph and the normal background run. Its existing run coalescing
naturally splits when adjacent cells have different interpolated colors.

This preserves the renderer contract and fixes the mathematical flaw in the
superseded two-instance proposal. It also covers the GPU-driven cell payload
without forcing a renderer fallback.

### Exact color math

Add a pure `SpinnerMotionColor.interpolate(from:to:progress:)` helper. Packed
RGBA uses `0xRRGGBBAA`. Clamp `progress` to 0...1, linearly interpolate all
four encoded 8-bit channels independently, and round each channel to the
nearest integer. The endpoints are exact: progress 0 returns `from` without
arithmetic and progress 1 returns `to` without arithmetic. The midpoint from
`0xFF0000FF` to `0x0000FFFF` is therefore exactly `0x800080FF`.

The values are already resolved renderer inputs. Do not decode/re-encode
colors in individual renderers, and do not multiply glyph alpha to simulate a
color change.

### Independent color-aware history

Do not change `cellContentFingerprint` or `freshnessFromCellDiff`; their
ink-bloom semantics are regression contracts on this branch. Add a separate
spinner cell-state extraction path in `FrameProducer` that reuses the same
`resolvedVisuals` logic used by commands and payloads.

`TerminalSurfaceController` retains at most four recently changed rows per
session, with a full row of `SpinnerCellState` values in each retained entry.
The active detector’s one or two anchor rows are pinned; the remaining rows
are least-recently-used. This bounded cache is populated on every new
generation, including the first two qualifying observations before detection
becomes active. That makes the previous endpoint available on the third
observation, rather than starting history too late.

Clear detector history and transitions when session identity disappears,
snapshot dimensions change, a remote incarnation changes, a tab/session cache
is invalidated, or the setting/Reduce Motion becomes ineffective.

### Cadence qualification

The detector is pure and contains no process-name, output-text, mouse-tracking,
AppKit, renderer, or settings logic.

- A spatial observation qualifies when it affects one row, or two adjacent
  rows; spans at most 32 columns; and changes at most 32 cells.
- Consecutive observations belong to one run when their row ranges overlap or
  are one row apart, their column ranges overlap or are within four columns,
  and their timestamp gap is 0.04...0.60 seconds inclusive.
- An observation outside those spatial or timing bounds starts a new run of
  length one. It does not preserve the old run.
- Detection becomes active on the third consecutive qualifying observation.
- `estimatedCadenceSeconds` is the arithmetic mean of at most the last four
  qualifying gaps, clamped to 0.04...0.60 seconds.
- Detection becomes inactive after `min(2 * estimatedCadenceSeconds, 0.8)`
  seconds without another qualifying observation.

Mouse-tracking state is diagnostic metadata only. It never suppresses a
spinner observation. Add an explicit regression test with mouse tracking on.

### Continuous retargeting under cadence jitter

When an eligible update arrives and detection is active, create a transition
from the colors currently displayed at that instant to the new authoritative
colors. If the cell already has a live transition, sample that transition at
the new update time and use the sampled colors as the next start colors. Do
not restart from the prior terminal endpoint. This makes early or irregular
updates continuous instead of producing a mid-ease jump.

The duration is the detector’s estimated cadence, clamped to 0.04...0.60
seconds. For age `a`, compute normalized time
`u = clamp(a / duration, 0, 1)` and visual progress
`u * u * (3 - 2 * u)` (cubic smoothstep), then feed that progress to the
channel-wise color interpolator. At or after the duration, return the target
colors exactly and remove the transition only after the target-color settle
frame has been requested. The cached current terminal cell state remains
available while the detector is active; removing a completed transition must
not remove the observation baseline needed by the next tick.

If text, width, attributes, underline metadata, hyperlink identity, or cell
geometry changes, cancel any transition for that cell and render the new state
immediately. Different-glyph changes may still qualify the region’s cadence,
but they never create an M1 transition.

### Effective setting owns animation cost

The pure detector may update diagnostics while the feature is disabled, but
only live transitions created under
`configuredEnabled && !reduceMotion` may:

- produce color overrides;
- union animation rows into render damage;
- report `spinnerMotionAnimating` to `TerminalIdlePolicy`; or
- keep the display link running.

Disabling the setting or enabling Reduce Motion mid-transition clears all
transitions, invalidates the affected rows, wakes one authoritative settle
frame, and then parks. A disabled detector must never cause decorative frames.

### Cached live setting and real UI

`SpinnerMotionSmoothingSettings` follows the repository’s notification-based
settings contract. `TerminalBitmapView`, `HeadlessDebugRuntime`, and
`SettingsWindowController` read and cache the configured value at
initialization; the render callers combine that cache with live Reduce Motion
to derive the effective value. Writes post `didChangeNotification`; observers
update the cached configured value and explicitly invalidate/wake. No
per-frame render or glyph-build path reads `UserDefaults` or
`ProcessInfo.processInfo.environment`.

The Rendering settings tab contains a checkbox labeled **Smooth spinner
motion**. It is available for every renderer because interpolation occurs
before the renderer boundary. The environment override remains useful for
headless runs and wins over UserDefaults; when present, the debug action
returns the effective value and reports that persistence was not applied.

## Plan of Work

### M0 — Separate color-aware observations and cadence detection

Goal: detect a small, steady color-changing region without changing pixels or
frame scheduling.

1. Add `Sources/LabanCore/SpinnerMotion.swift` with pure value types for
   `SpinnerCellKey`, `SpinnerCellState`, `SpinnerMotionObservation`,
   `SpinnerMotionDetector`, detector diagnostics, transition sampling, and
   packed-RGBA interpolation. Keep the file AppKit-free.
2. In `Sources/LabanCore/FrameProducer.swift`, factor the existing resolved
   cell visual calculation so `commands`, `fillTerminalCellPayload`, and a new
   internal `spinnerCellStates(...)` helper use one implementation. A state
   contains the actual grapheme text/bytes and display width plus resolved
   foreground/background, attributes, underline style/color, and hyperlink
   identity. Provide equivalent extraction for local `LabanSnapshot` and
   remote `LabandSnapshotResponse` cells. The remote protocol currently
   carries text, flags, foreground, and background but not separate underline
   style/color or hyperlink identity; use the same defaulted metadata the
   existing remote `FrameProducer.commands(from:)` path renders, rather than
   expanding the daemon protocol in this plan.
3. In `Sources/LabanCore/TerminalSurfaceController.swift`, add per-session
   spinner history keyed by `Session.ID`. Observe a local snapshot exactly once
   for each nonzero `session.dirtyGeneration()`. Extend the remote `makeFrame`
   overload to accept the `LabandSnapshotFrame.generation` token and observe
   each remote generation exactly once; also bind history to
   `snapshot.incarnationId`.
4. Build observations from spinner cell states, not from
   `GlyphEffectFreshness`. Run this before and independently of
   `stampFreshOutputTimestamps` and its mouse-tracking suppression. Preserve
   all current ink-bloom behavior and tests unchanged.
5. Extend `invalidateSessionSyncCache()` to clear spinner histories and
   transitions. Reset a session on dimension/incarnation changes.
6. Add `SpinnerMotionDetectorTests` and focused
   `TerminalSurfaceControllerTests` for the thresholds, third-observation
   activation, reset behavior, rolling cadence, decay, cache-before-active,
   local generation deduplication, remote generation/incarnation handling,
   and mouse-tracking eligibility.

M0 acceptance: tests can drive a same-glyph color ripple to active detection
with mouse tracking both off and on. `TerminalIdlePolicy` receives no new input
yet, frame commands and payloads are unchanged, and no visual or wake behavior
changes.

### M1 — Single-instance color interpolation and bounded frame pumping

Goal: enabled eligible cells interpolate through the shared producer, all
renderers see the same values, and only live transitions keep frames moving.

1. Add `spinnerMotionConfiguredEnabled: Bool = false` to
   `TerminalSurfaceFrameRequest`. The caller passes the cached configured
   value; the controller derives the effective value as
   `spinnerMotionConfiguredEnabled && !request.reduceMotion` and never reads
   settings itself. Keeping configured and effective state distinct makes the
   debug response and Reduce Motion behavior unambiguous.
2. Add the transition map described above to each session’s spinner state. On
   a qualifying third-or-later observation, create or retarget transitions for
   same-glyph/same-layout cells whose resolved foreground or background
   changed. Cap live transitions at 64 cells (two 32-cell rows); if an input
   exceeds the cap, render it immediately and increment an overflow diagnostic
   instead of allocating without bound.
3. Sample live transitions from the same monotonic clock already exposed as
   `TerminalSurfaceController.outputStampClock`. Headless deterministic mode
   already replaces this clock; do not add a second time domain.
4. Add an optional, compact color-override map to `FrameProducer.commands`,
   `FrameProducer.fillTerminalCellPayload`, and their local/remote helpers.
   Apply an override after normal visual resolution and before background/glyph
   run coalescing. The nil/default path must take a single fast branch and emit
   byte-identical output. Do not extend `FrameCommand`,
   `TerminalCellPayload.Glyph`, or any GPU struct.
5. Compute transition liveness before payload dirty-row selection. Union the
   affected rows into `RenderDamage` and into the payload’s included rows so a
   display-link frame with no new terminal generation still rebuilds the
   interpolated cells. Leave unrelated rows and overlays on their existing
   damage path.
6. Add `SpinnerMotionFrameState` to `TerminalSurfaceFrame`: configured/effective
   enabled, detector active, animating, active row/column bounds, estimated
   cadence, transition count, remaining seconds, and affected damage bands.
   This is plain state used by AppKit, headless, journals, and debug projection.
7. Add `spinnerMotionAnimating: Bool = false` to both
   `TerminalIdlePolicy` functions at the same 30 fps decorative tier as
   `glyphEffectAnimating`. In `TerminalBitmapView`, add
   `FrameWakeSource.spinnerMotion`, a deadline synchronized from
   `SpinnerMotionFrameState.remainingSeconds`, and an
   `spinnerMotionWasAnimating` trailing-frame latch. Only `animating`, never
   detector activity, feeds the policy.
8. Mirror the exact scheduling and settle behavior in
   `HeadlessDebugRuntime`. On disabling/Reduce Motion, reset transitions,
   invalidate their rows, request one frame, then report inactive.
9. Add tests:
   - `SpinnerMotionColorTests`: endpoints, clamping, alpha, and exact red/blue
     midpoint `0x800080FF`.
   - `SpinnerMotionTransitionTests`: normal progress, exact settle, early
     retargeting from the currently displayed color, cubic-smoothstep samples,
     and baseline retention after transition eviction.
   - `SpinnerMotionFrameProducerTests`: exact foreground and background
     overrides in both frame commands and `TerminalCellPayload`; command/payload
     parity; nil/disabled byte identity; wide glyph and attribute changes snap.
   - `SpinnerMotionRendererRoutingTests`: with an opaque full-cell background,
     each `RendererSelection.allCases` backend consumes the midpoint override;
     GPU-driven reports payload routing rather than a classic fallback.
   - `TerminalIdlePolicyTests`: transition-only selects 30 fps; output still
     wins with 120 fps; detector-active/transition-inactive parks; disabled and
     Reduce Motion park after the settle frame.
   - AppKit/headless tests for the strip-frame latch and reset/wake behavior.

M1 acceptance: every renderer receives one current glyph with interpolated
colors; GPU-driven Metal remains on the payload path; an exact midpoint is the
defined RGBA lerp rather than a source-over approximation; disabled output is
unchanged; and the link parks after the final target frame.

### M2 — Settings UI, diagnostics, deterministic E2E, docs, and review

Goal: users can control the feature, agents can prove it, and CI exercises the
real path including fullscreen-TUI mouse tracking.

1. Add `Sources/LabanCore/SpinnerMotionSmoothingSettings.swift` with:
   - UserDefaults key `LabanSpinnerMotionSmoothingEnabled`;
   - environment override `LABAN_SPINNER_MOTION_SMOOTHING_ENABLED`;
   - default `false`;
   - `didChangeNotification`;
   - `configuredEnabled(...)`, `effectiveEnabled(reduceMotion:...)`, and
     `setEnabled(...)` helpers;
   - a write result that distinguishes persisted from environment-locked.
2. Add **Smooth spinner motion** to the Rendering tab in
   `Sources/LabanApp/SettingsWindowController.swift`, wire its target/action,
   refresh it from the cached setting, and add localization entries in
   `Sources/LabanApp/Resources/Localizable.xcstrings`. When the environment
   override is present, show the effective state but disable the checkbox and
   expose an explanatory help/accessibility string so the UI cannot imply a
   write will win. Add a Settings test that toggles it, observes the
   notification/effective state, and pins the environment-locked UI.
3. Add one cached configured-setting field and observer to
   `TerminalBitmapView`; install the cached value on initialization and live
   backend/view rebuilds. The observer resets active transitions, invalidates,
   and wakes. Extend the existing accessibility-display-options refresh so a
   Reduce Motion change uses the same reset/settle path.
4. Mirror the cache and notification behavior in `HeadlessDebugRuntime`.
   `setSpinnerMotionSmoothingEnabled` accepts `enabled: Bool` and returns
   `{configuredEnabled, effectiveEnabled, persisted, environmentOverride}`.
   Register it in every intent catalog, decode/dispatch, discovery, and schema
   location required by the debug framework.
5. Add `GET /debug/spinner-motion` plus
   `resetSpinnerMotionDiagnostics`. Counters are: observations, detections
   started, transitions started, retargets, interpolated frames, overflow
   fallbacks, wakes, settle frames, and parks restored. Add a `spinnerMotion`
   block to `/debug/state` for every renderer; inactive values are zero/false,
   never `null`.
6. Extend `RenderJournal.Entry` with an optional
   `spinnerMotion: SpinnerMotionSnapshot?` and
   `DisplayLinkSnapshot` with optional `spinnerMotionAnimating`. Old dumps must
   decode with nil fields. Update `scripts/render-journal-summary` to report
   detection, transition, and park counts.
7. Create `fixtures/spinner-motion-smoothing.scenario.json` and its fixture
   data. Pin the fixture to an opaque terminal background, run under
   `--deterministic`, and exercise this exact sequence:
   - leave the setting off, enable terminal mouse tracking with DECSET output,
     send three 100 ms same-glyph color updates, and prove detector diagnostics
     can become active while transition/wake counts stay zero and endpoint
     colors remain exact;
   - enable the setting through the debug action and assert the returned
     effective value;
   - reset diagnostics, repeat three 100 ms updates with mouse tracking still
     active, advance virtual time 50 ms, and assert the command foreground and
     a full-cell background pixel are the defined midpoint values;
   - deliver an early fourth update and assert the next transition starts from
     the sampled displayed midpoint rather than the prior terminal endpoint;
   - advance through settlement and assert exact target colors, zero live
     transitions, one settle frame, and restored parking; save the final
     `/debug/state` response as `final-state.json` and the final
     `/debug/spinner-motion` response as `final-diagnostics.json`;
   - disable the setting and prove subsequent output remains exact with no
     spinner wake.
8. Wire the scenario into `scripts/test-e2e`. Update debug schemas/catalogs,
   `docs/process/dev-process.md`, `docs/product/spec.md`, and the renderer safety
   section of `docs/process/agent-operating-guide.md`. Document that this is a
   renderer-neutral, default-off color interpolation and that different-glyph
   substitution is deferred. Leave AGENTS.md unchanged.
9. Execute the Review Gate below with a fresh agent. The plan is not complete
   until the full gate passes against one named commit.

## Progress

- [x] (2026-07-20) Initial plan filed.
- [x] (2026-07-20) Plan revised after review: replaced the unrepresentable
  dual-instance Slug effect with renderer-neutral color overrides; separated
  spinner detection from ink-bloom; added effective-setting gating, UI,
  mouse-tracking coverage, exact color math, and mechanical review checks.
- [ ] M0 — color-aware observations and cadence detector.
- [ ] M1 — renderer-neutral transitions, payload/command parity, and bounded
  frame pumping.
- [ ] M2 — setting/UI, observability, deterministic E2E, docs, and CI wiring.
- [ ] Review Gate passed against a named commit.

## Surprises & Discoveries

- Observation: the existing cell fingerprint intentionally ignores color and
  intensity, despite an older nearby comment saying it includes style.
  Evidence: `TerminalSurfaceController.cellContentFingerprint` hashes wide
  identity and UTF-8 only, and
  `testCellFingerprintIgnoresColorOnlyChanges` pins that behavior. The spinner
  detector therefore needs its own state comparison.
- Observation: the ink-bloom stamp path suppresses mouse-tracking TUIs before
  freshness classification. Evidence: `stampFreshOutputTimestamps` returns
  `.suppressedTUI` when `snapshot.mouse_tracking != 0`. Spinner detection must
  run independently because fullscreen Claude is a primary scenario.
- Observation: the existing command and GPU-instance payloads cannot carry a
  cadence-derived duration and separate in/out kinds without extension.
  Evidence: `FrameCommand.glyphRun` has only `outputTimestampSeconds`, and
  `SlugGlyphGPUInstance` has only `effectKind` and `effectStart` in its former
  pad words.
- Observation: two half-alpha source-over glyphs are not a true dissolve.
  With full glyph coverage they yield 0.75 combined alpha and an order-biased
  color. Slug also discards `glyphRun.background` in `appendGlyphRun`.
  Single-instance resolved-color interpolation avoids both defects.

## Decision Log

- Decision: Perform color interpolation before the renderer boundary and emit
  one current glyph, rather than adding Slug effect kinds 3/4.
  Rationale: this is mathematically exact, handles foreground and background,
  works through both frame commands and the GPU-driven payload, preserves GPU
  struct layouts, and avoids ghosting/opacity dips.
  Date/Author: 2026-07-20 / Codex

- Decision: Preserve the ink-bloom fingerprint and add a separate
  color-aware spinner history.
  Rationale: changing the existing fingerprint would regress the branch’s
  explicit “color pulses do not restart ink-bloom” contract.
  Date/Author: 2026-07-20 / Codex

- Decision: Use a maximum two-row, 32-column, 32-changed-cell region and three
  observations within 40-600 ms for detection.
  Rationale: “small” must be mechanically bounded for memory, false-positive,
  and review purposes; the bounds cover status words and compact progress
  indicators without treating broad TUI redraws as spinners.
  Date/Author: 2026-07-20 / Codex

- Decision: Retarget from the currently displayed interpolated color when a
  new update arrives early.
  Rationale: restarting from the prior terminal endpoint creates a visible
  discontinuity under cadence jitter.
  Date/Author: 2026-07-20 / Codex

- Decision: Detector activity is diagnostic; only an effective live
  transition may drive the display link.
  Rationale: default-off and Reduce Motion must impose no decorative wake or
  rendering cost.
  Date/Author: 2026-07-20 / Codex

- Decision: Cache the setting via notifications and expose a real Rendering
  checkbox.
  Rationale: repository renderer rules prohibit per-frame UserDefaults reads,
  and an opt-in product setting must be reachable without shell defaults or a
  debug endpoint.
  Date/Author: 2026-07-20 / Codex

- Decision: Defer different-glyph smoothing; do not retain the old optional M2
  cross-fade prototype.
  Rationale: source-over copies are already proven to be the wrong primitive,
  and character-shape interpolation needs a separate design and visual gate.
  Date/Author: 2026-07-20 / Codex

## Review Gate

A fresh agent must run every item against the completed implementation. On
failure, record exact file/line findings here, fix them, and rerun the entire
gate. Stop after three failures of the same item and escalate per `PLANS.md`.

- [ ] Run
  `rtk rg -n "crossfadeIn|crossfadeOut|spinner.*effectKind" Sources/LabanRenderer Sources/LabanCore`.
  Expect zero hits: spinner motion owns no shader effect kind.
- [ ] Run
  `rtk git diff 551cbaff -- Sources/LabanRenderer/SlugGlyphRenderer.swift Sources/LabanRenderer/VectorGlyphShaders.metal`.
  Expect no spinner-motion changes to either file and no GPU struct-layout
  changes.
- [ ] Run
  `rtk swift test --filter SpinnerMotionDetectorTests` and expect exit 0,
  including the mouse-tracking-eligible and third-observation cases.
- [ ] Run `rtk swift test --filter SpinnerMotionColorTests` and expect exit 0,
  including exact `0xFF0000FF -> 0x0000FFFF @ 0.5 == 0x800080FF`.
- [ ] Run
  `rtk swift test --filter SpinnerMotionTransitionTests` and expect exit 0,
  including early-retarget continuity and baseline-after-eviction cases.
- [ ] Run
  `rtk swift test --filter SpinnerMotionFrameProducerTests` and expect exit 0,
  including command/payload parity, foreground/background overrides,
  nil/disabled byte identity, and attribute/different-glyph snap behavior.
- [ ] Run
  `rtk swift test --filter SpinnerMotionRendererRoutingTests` and expect exit
  0, including an opaque midpoint background through every
  `RendererSelection.allCases` backend and payload routing for GPU-driven.
- [ ] Run `rtk swift test --filter TerminalIdlePolicyTests` and expect exit 0,
  including transition-only 30 fps, output precedence at 120 fps, and
  detector-active/transition-inactive parking.
- [ ] Run
  `rtk swift test --filter SpinnerMotionSettingsTests` and
  `rtk swift test --filter SettingsWindowControllerTests` and expect exit 0,
  including environment-lock response and checkbox notification behavior.
- [ ] Run
  `rtk ./scripts/run-debug-script fixtures/spinner-motion-smoothing.scenario.json --artifacts=.artifacts/review/spinner-motion-smoothing`.
  Expect exit 0 and stdout ending `debug script passed`; the report’s `ok`
  field must be true and its steps must contain the exact disabled endpoint,
  enabled midpoint, early-retarget, mouse-tracking, settle, and park assertions
  described in M2.
- [ ] Run
  `rtk rg -n "spinner-motion-smoothing.scenario.json" scripts/test-e2e` and
  expect one executable scenario invocation, not only a comment or filename.
- [ ] Run `rtk ./scripts/test-e2e` and expect exit 0.
- [ ] Run
  `rtk rg -n "Smooth spinner motion|spinnerMotion" Sources/LabanApp/SettingsWindowController.swift Sources/LabanApp/Resources/Localizable.xcstrings docs/product/spec.md docs/process/dev-process.md`.
  Expect hits in all four files.
- [ ] Run `rtk ./scripts/check` and expect exit 0.
- [ ] Run
  `rtk jq -e '.spinnerMotion.animating == false and .spinnerMotion.transitionCount == 0' .artifacts/review/spinner-motion-smoothing/final-state.json`
  and
  `rtk jq -e '.settleFrames == 1 and .parksRestored >= 1' .artifacts/review/spinner-motion-smoothing/final-diagnostics.json`.
  Expect both commands to exit 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

_(empty)_

## Concrete Steps

Work from `/Users/rrj/wrk/laban`. Use the repository-required `rtk` prefix.

After M0:

    rtk swift test --filter SpinnerMotionDetectorTests
    rtk swift test --filter TerminalSurfaceControllerTests

Expect both commands to exit 0. The existing
`testCellFingerprintIgnoresColorOnlyChanges` must remain green.

After M1:

    rtk swift test --filter SpinnerMotionColorTests
    rtk swift test --filter SpinnerMotionTransitionTests
    rtk swift test --filter SpinnerMotionFrameProducerTests
    rtk swift test --filter SpinnerMotionRendererRoutingTests
    rtk swift test --filter TerminalIdlePolicyTests

Expect zero failures. The midpoint transcript must include:

    from=FF0000FF to=0000FFFF progress=0.5 actual=800080FF

After M2:

    rtk swift test --filter SpinnerMotionSettingsTests
    rtk swift test --filter SettingsWindowControllerTests
    rtk ./scripts/run-debug-script fixtures/spinner-motion-smoothing.scenario.json
    rtk ./scripts/test-e2e

Expect the scenario to exit 0, print `debug script passed`, write a report with
`ok: true`, and save its state, diagnostics, frame-command, pixel-probe, and
screenshot artifacts under `.artifacts/runs/`.

Before review/ship:

    rtk ./scripts/check
    rtk git status --short

Expect the check to exit 0. Inspect status and keep unrelated user files out of
the changeset. Commit milestones as focused, single-reason commits.

## Validation and Acceptance

The implementation is accepted only when all of the following are true:

1. With the setting off, local and remote detector diagnostics may observe a
   cadence, but commands, cell payloads, rendered pixels, display-link wake
   counts, and parking behavior match the pre-plan tree.
2. With the setting enabled, the third qualifying same-glyph color update
   starts interpolation. At exact virtual midpoint, both foreground command
   color and a full-cell background pixel equal the defined channel-wise RGBA
   midpoint.
3. A fourth update arriving before settlement starts from the currently
   displayed color, with no discontinuity back to a prior terminal endpoint.
4. Mouse tracking can remain enabled for the whole scenario and does not
   suppress detection or interpolation.
5. Different glyphs, widths, attributes, underline metadata, hyperlinks,
   resize/incarnation changes, and overflow regions snap immediately to the
   authoritative current state.
6. Software, classic Metal, GPU-driven Metal, Vector Glyph, and Slug Glyph
   receive equivalent interpolated colors. GPU-driven stays on
   `TerminalCellPayload`; no hidden classic fallback is used.
7. Disabling the setting or enabling Reduce Motion during a transition renders
   one target-color settle frame, clears liveness, and restores parking.
8. After normal completion, `idle-counters.jsonl` records zero
   `advanceFrames` during a subsequent five-second focused, cursor-blink-off
   idle window.
9. The setting is visible and operable in Settings > Rendering, defaults off,
   updates live, and is localized.
10. The deterministic scenario is invoked by `scripts/test-e2e`, the full
    `scripts/check` gate passes, and the fresh Review Gate passes against the
    named implementation commit.

## Idempotence and Recovery

The setting defaults off. M0 changes only diagnostics/state and is safe without
M1. M1’s optional override input defaults to nil/false, preserving existing
callers and output. Re-running tests and scenarios is safe; scenario artifacts
use normal run-scoped directories.

If implementation stops mid-transition work, set
`LabanSpinnerMotionSmoothingEnabled` to false, clear any environment override,
and relaunch. The disabled path must render authoritative terminal colors with
no transition state. Each milestone is a focused changeset and can be reverted
independently with `git revert <commit>`.

Never recover by changing the ink-bloom fingerprint, disabling mouse tracking,
or forcing GPU-driven rendering onto a different backend. Those would hide the
bug rather than restore the specified contract.

## Interfaces and Dependencies

End-state interfaces that must exist:

- `Sources/LabanCore/SpinnerMotion.swift`: pure detector, cell/observation
  types, transition sampler, and packed-RGBA interpolation.
- `FrameProducer.spinnerCellStates(...)`: local and remote state extraction
  through the same resolved-visual logic as normal production.
- `FrameProducer.commands(..., spinnerColorOverrides: ... = nil)` and
  `fillTerminalCellPayload(..., spinnerColorOverrides: ... = nil)`: one shared
  optional override contract with byte-identical nil behavior.
- `TerminalSurfaceFrameRequest.spinnerMotionConfiguredEnabled: Bool = false`:
  cached configured caller input; the controller combines it with
  `request.reduceMotion` to derive effective state.
- `TerminalSurfaceFrame.spinnerMotion: SpinnerMotionFrameState?`: detector and
  transition liveness/diagnostics for AppKit, headless, journal, and debug.
- Remote `TerminalSurfaceController.makeFrame` input includes the remote frame
  generation and binds retained state to `incarnationId`.
- `TerminalIdlePolicy.displayLinkShouldRun(...)` and
  `preferredDisplayLinkFramesPerSecond(...)` include
  `spinnerMotionAnimating: Bool = false` at the decorative 30 fps tier.
- `FrameWakeSource.spinnerMotion` plus the trailing settle-frame latch in
  `TerminalBitmapView` and its headless equivalent.
- `SpinnerMotionSmoothingSettings`: notification-based, default-off,
  environment-overridable setting with explicit effective/persisted result.
- Settings > Rendering checkbox **Smooth spinner motion**.
- Debug action `setSpinnerMotionSmoothingEnabled`, reset action
  `resetSpinnerMotionDiagnostics`, `GET /debug/spinner-motion`, and non-null
  `/debug/state.spinnerMotion` for every renderer.
- `fixtures/spinner-motion-smoothing.scenario.json`, invoked from
  `scripts/test-e2e`.

No new package dependency is required. No spinner effect kind, GPU-instance
field, shader uniform, renderer-specific settings read, process-name match, or
literal-text match is permitted.
