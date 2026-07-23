# Per-glyph animation channel for the Slug renderer (ink-bloom type-in + bell shake)

This is a living ExecPlan maintained per `PLANS.md` at the repo root. On
approval, the first execution step is to file this document as
`execplans/active/per-glyph-animation-channel.md` and keep its `Progress`
section current as work proceeds.

## Purpose / Big Picture

Today every glyph the Slug renderer draws is frozen within its frame: the CPU
writes `originPx` / `color` / `dilation` per instance and the GPU draws exactly
that. This plan adds a **per-glyph animation channel**: each glyph instance
carries an `effectKind` + `effectStart` payload, a `timeSeconds` uniform drives
evaluation in the vertex shader, and effects ease to exactly zero and stop —
so the terminal returns to fully parked, event-driven frames (ADR 0018) when
nothing animates.

Two first effects ride the channel:

1. **Ink-bloom type-in** — freshly output text eases `dilation` + alpha from a
   thin/faint state to normal over ~150 ms. Text condenses out of ink instead
   of popping. Because Slug coverage is analytic, weight animation is a float
   ease, not a re-rasterization — no raster terminal can copy this crisply.
2. **Visual bell shake** — on BEL, the grid does one critically-damped
   horizontal shake (~300 ms). Laban currently has *no* visual bell at all
   (attention badge only), so this also closes a feature gap.

Both effects are presentation-only offsets over the authoritative cell grid,
ship **default-off** behind a setting (repo opt-in posture, ADR 0017/0022/0027),
respect `reduceMotion`, and are autonomously verifiable headlessly.

How to see it working (once M1/M2 land): enable the setting, run
`printf 'hello\nworld\n'` — new lines bloom in. Run `printf '\a'` — the grid
shakes once. Then let the terminal sit: `idle-counters.jsonl` shows zero
advanceFrames — the display link is parked.

## Context and Orientation

Key terms and landing spots (all paths repo-relative):

- `Sources/LabanRenderer/SlugGlyphRenderer.swift`
  - `SlugGlyphGPUInstance` (:51–61), **64 B stride**, has two free pad words
    (`pad1`, `pad2`, 8 bytes) — enough for `effectKind: UInt32` +
    `effectStart: Float` with **zero stride change**.
  - `SlugGlyphGPUUniforms` (:63–76), **96 B stride**, has `pad1/pad2/pad3`
    (12 free bytes) — enough for `timeSeconds: Float` + two effect param
    floats (e.g. bell amplitude, bell direction), zero stride change.
  - Per-frame instance assembly: `render(_:damage:)` (:1091) →
    `buildInstances(...)` (:1720–1785) → `appendGlyphRun(...)` (:1787–1925);
    per-glyph emission at :1905–1913. Damage filtering happens at
    :1756–1779 via `intersectsDamage(minY:maxY:bands:)` — **a glyphRun that
    passes the damage test is a freshly-output run**; that is where ink-bloom
    marks `effectStart`.
  - Skip logic to defeat while animating: empty effective damage skips the
    encode (:1123–1133); redundant presents skipped by `shouldEncodePresent`
    (:2577).
  - `coverageMask(for:...)` (:1628–1635) — second direct instance
    constructor (test/readback path); must stay in sync with the struct.
- `Sources/LabanRenderer/VectorGlyphShaders.metal`
  - `struct SlugGlyphInstance` (:589–599) and `struct SlugGlyphUniforms`
    (:601–614) — Metal mirrors, must stay byte-identical with the Swift
    structs.
  - `slugGlyphVertex` (:628–646) outputs `glyphPoint`, `color`, `glyphIndex`,
    `dilation`; gesture zoom applied via `slugGlyphApplyGestureZoom` (:624).
    **All effect evaluation goes in this one vertex shader** (it already
    outputs both `color` and `dilation`, so ink-bloom needs no fragment
    change; shake is a position offset). The four fragment entry points
    (:899, :917, :929, :989) stay untouched.
- Frame scheduling / idle contract (ADR 0018, binding for new code):
  - `Sources/LabanApp/TerminalBitmapView.swift`
    - `FrameWakeSource` enum (:2551) — add `.glyphEffect`.
    - `advanceFrame(wake:)` (:2575) ends with
      `defer { updateDisplayLinkRunState() }` (:2590) — park reconciliation
      is automatic once the policy knows about the new state.
    - `displayLinkPolicyState(now:)` (:2312) → `DisplayLinkPolicyState`
      (:2300) with reason ladder (:2346–2365) — add `"glyphEffect"` rung.
    - One-shot scheduled-wake pattern to copy: `scheduleAttentionPingWake`
      (:2059) with a `…Scheduled` guard flag.
    - `reduceMotion` gating precedent at :2881.
    - Bell hook: `AppModel.applyBellAttention`
      (`Sources/LabanCore/AppModel.swift:2020`) already fires on BEL → add
      grid-shake trigger beside it.
  - `Sources/LabanCore/TerminalIdlePolicy.swift` — pure AppKit-free enum;
    `displayLinkShouldRun(...)` (:45) takes six booleans; add
    `glyphEffectAnimating`. `animationDisplayLinkFramesPerSecond = 30` (:25)
    is the established decorative-animation fps budget — reuse it.
  - `AttentionPulse` (`Sources/LabanCore/TabAttention.swift:108`) — the
    shipped "decays to zero wakeups" pattern: pure timeline functions
    (`markerAlpha(elapsed:)`, `isAnimating(elapsed:)`,
    `delayToNextAnimation(elapsed:)`), AppKit-free, unit-testable.
  - Render journal: `Sources/LabanApp/RenderJournal.swift` `Entry` (:20),
    `DisplayLinkSnapshot` (:81) — add glyph-effect fields.
  - `Sources/LabanApp/IdleCounters.swift` + `idle-counters.jsonl` — evidence
    channel for "zero wakeups when idle".
- Headless/debug verification:
  - `Sources/LabanDebug/HeadlessDebugRuntime.swift` — endpoint-driven frames,
    deterministic timers under `--deterministic` (dev-process.md:1453); the
    animation clock must be injectable/advanceable there.
  - `Sources/LabanControl/ControlRouteCatalog.swift` — route catalog
    (`/debug/state` :69, `/debug/pixel-probe` :288, `/debug/screenshot` :112,
    `/debug/wait` :242). Feature-diagnostics precedent: `GET
    /debug/transparency` with resettable counters (ADR 0028).
  - Scenario fixtures: `fixtures/*.scenario.json`,
    `schemas/debug-script.schema.json`.

### Terms

- **Animation channel** — the per-instance `effectKind`/`effectStart` payload
  plus the `timeSeconds` uniform and the shader-side easing evaluation.
- **Effect start stability** — `effectStart` must be identical across rebuilds
  of the same run, or the effect restarts every frame. Source of truth: a
  monotonic timestamp carried on `FrameCommand.glyphRun`
  (`Sources/LabanRenderer/FrameCommand.swift:140–151`), stamped by
  `TerminalSurfaceController` when the run is first emitted. Old runs re-emitted
  by scroll/selection damage have `age > decay` → no effect. No renderer-side
  start-time table needed.
- **Clock** — monotonic seconds (`mach_absolute_time`-based), converted to a
  renderer-relative float in the uniform. Headless mode substitutes a virtual
  clock.

## Design decisions (made here, not left to the reader)

- **No struct growth.** Instance stays 64 B (`pad1→effectKind`,
  `pad2→effectStart`); uniforms stay 96 B (`pad1→timeSeconds`,
  `pad2/pad3→bell params`). Swift + Metal mirrors updated together.
- **Vertex-only evaluation.** Ink-bloom adjusts `dilation` + `color.a` in
  `slugGlyphVertex`; shake adjusts `position`. Fragment shaders unchanged;
  existing `fwidth` AA handles the animated dilation.
- **Effect liveness lives in one pure policy type** — new
  `Sources/LabanCore/GlyphEffectTimeline.swift` (AppKit-free, AttentionPulse
  style): `static func offset(...)/dilationEase(...)/alphaEase(...)`,
  `isAnimating(age:)`, `decaySeconds` per kind. Unit-tested without a window.
  Shader constants duplicated in Metal with a shared documented source of
  truth (same pattern as `dilationTable`).
- **Frame pumping while animating:** while any effect is live, the controller
  marks the animating bands damaged (defeating the :1123 encode skip) and sets
  `renderInvalidated`; `displayLinkPolicyState` reports
  `glyphEffectAnimating` → link runs at 30 fps; when the last effect decays
  the natural `advanceFrame` reconcile parks the link. Present-skip defeat:
  `shouldEncodePresent` must treat "glyph effect live" as content-changed.
- **Default-off.** Setting `glyphEffectsEnabled` (settings store +
  `LabanGlyphEffectsEnabled` default override), plus `reduceMotion` force-off.
  Promotion to default-on is a separate spec.md decision (per AGENTS.md Source
  Of Truth and the vector-zoom M3 precedent).
- **Follow-ups explicitly out of scope:** zoom-commit spring settle, liquid
  cursor, gradients, the contact-sheet overview lens. The channel is built so
  they slot in later.

## Plan of Work

File this plan at `execplans/active/per-glyph-animation-channel.md`, then
execute milestones M0–M3 in order. Each milestone ends green: `scripts/check`
passes and its acceptance checks are met before the next begins.

### M0 — Animation channel substrate (no user-visible effect yet)

1. `SlugGlyphRenderer.swift`: rename instance pads to `effectKind` /
   `effectStart`; rename uniform pads to `timeSeconds` / `bellAmplitudePx` /
   `bellDirection`; populate `timeSeconds` from a monotonic clock injected at
   `render()` entry (default `mach_absolute_time`; settable for tests).
2. `VectorGlyphShaders.metal`: mirror the struct field renames; add
   `slugGlyphEvaluateEffect(...)` helper called from `slugGlyphVertex`
   (kind 0 = none = bit-identical output to today).
3. `FrameCommand.glyphRun`: add `outputTimestampSeconds: Double?` (nil = not
   fresh). `TerminalSurfaceController` stamps it when a run is first emitted
   after PTY output.
4. `buildInstances`/`appendGlyphRun`: when a run with a non-nil timestamp
   passes damage intersection, write `effectKind`/`effectStart` onto its
   instances.
5. `TerminalIdlePolicy`: add `glyphEffectAnimating` input to
   `displayLinkShouldRun` + `preferredDisplayLinkFramesPerSecond` (30 fps
   rung); extend compatibility shims. Unit tests.
6. `TerminalBitmapView`: `FrameWakeSource.glyphEffect` case,
   `glyphEffectAnimatingUntil` state, `"glyphEffect"` reason rung in
   `displayLinkPolicyState`, render-journal fields.
7. New `GlyphEffectTimeline` pure type + unit tests (easing curves, decay
   bounds, reduceMotion policy function).
8. Update `coverageMask(for:)` constructor and `SlugGlyphSpike` if it touches
   the shared struct (spike uses its own `SlugSpikeInstance` — verify only).

M0 acceptance: full test suite green; a debug-only trigger (loopback endpoint
or env flag) can fire a synthetic effect on demand; with kind 0 everywhere,
rendered output is pixel-identical to the pre-change tree (screenshot
comparison in a scenario fixture).

### M1 — Ink-bloom type-in

1. Shader: kind 1 = ink-bloom; ease `dilation` from thin and `color.a` from
   ~0.35 over 150 ms with ease-out curve; clamp at 0 offset.
2. Controller: while any bloom is live, damage the affected bands each frame
   and drive the display link at 30 fps via M0 plumbing; park on decay.
3. Setting `glyphEffectsEnabled` (default off) + `reduceMotion` gate.
4. Headless: virtual-clock hook so `/debug` scenarios can stamp an effect and
   advance time deterministically; expose
   `glyphEffects: {active, liveCount, lastKind, wakeCount}` in `/debug/state`.
5. Scenario fixture: script output → probe pixels of a fresh glyph at t=0
   (thin/faint), t≈75 ms (mid), t≥200 ms (settled, bit-identical to
   no-effect render) → assert via `/debug/pixel-probe`.
6. Idle proof: after decay, `IdleCounters` shows zero advanceFrames over a
   5 s idle window.

### M2 — Visual bell shake

1. Uniform params: `bellAmplitudePx`, `bellDirection` (uniform-level; grid-wide
   effect, no per-instance params needed).
2. Trigger: `AppModel.applyBellAttention` → surface sets grid-wide
   `effectStart` + `glyphEffectAnimatingUntil` → wake `.glyphEffect`.
3. Shader: kind 2 = critically-damped horizontal shake, ~300 ms, amplitude
   from uniform; respects `reduceMotion` (no-op).
4. `/debug/state` bell-effect fields; scenario: `printf '\a'` → screenshots at
   t=0/peak/settled; settled frame identical to pre-bell.

### M3 — Observability, E2E, docs, review gate

1. `/debug/glyph-effects` endpoint (ADR 0028 `/debug/transparency` shape):
   resettable counters — effects started, effect frames rendered, wake count,
   park-restored count.
2. `observability.md`-required wiring: render-journal fields verified,
   metrics event `render.glyphEffect.*`.
3. E2E scenario fixture under `fixtures/` + `schemas/debug-script.schema.json`
   conformance; add to CI E2E set per dev-process.md §End-To-End Agent Tests.
4. Docs: line in `docs/product/spec.md` describing the (default-off) glyph
   effects channel; AGENTS.md untouched (no convention changes); note in
   `docs/process/agent-operating-guide.md` renderer safety rules: instance
   layout now carries effect payload; Swift/Metal mirror rule reaffirmed.
5. Review Gate (below) executed by a fresh agent.

## Progress

- [x] Plan filed at `execplans/active/per-glyph-animation-channel.md`
- [x] M0 — animation channel substrate
- [x] M1 — ink-bloom type-in
- [ ] M2 — visual bell shake
- [ ] M3 — observability, E2E, docs
- [ ] Review Gate passed

## Surprises & Discoveries

- **`FrameCommand.glyphRun` arity ripple (M0 step 3).** Adding
  `outputTimestampSeconds: Double? = nil` as an 11th associated value broke
  every positional `.glyphRun(...)` case pattern in the tree (Swift requires
  full arity once a pattern uses parentheses): 103 sites across 11 source
  files and 22 test files, all mechanically extended with a trailing `_`.
  Construction sites were untouched thanks to the default value. Capture /
  debug serialization formats were deliberately left unchanged — the
  timestamp is runtime-transient and decodes as nil.
- **Stamp gating lives in `TerminalSurfaceController`, not the view (M0/M1).**
  M0 kept a per-session generation→stamp map; M1 found two precision bugs and
  fixed both:
  1. *Adjacent-row false freshness.* Stamping originally reused the renderer
     damage filter's ±1 cell expansion, so the clean row above/below a dirty
     one was stamped and re-bloomed. Stamping now uses the exact cell extent
     (bands and runs are both row-aligned; the expansion is only correct for
     over-inclusive pixel filtering, never for freshness).
  2. *Headless dirty-row accumulation.* `HeadlessDebugRuntime` never called
     `session.markRendered()`, so snapshot dirty rows accumulated across
     frames and stamp bands grew to cover old rows. Headless now marks the
     active session rendered after each frame, mirroring
     `TerminalBitmapView.advanceFrame` (feature-parity rule).
- **Stamp shape (M1).** The per-session record is
  `(generation, stamp, bands)` where bands are the *natural* (unforced)
  snapshot damage at stamp time — computed separately from the frame's
  damage so `forceFullDamage` frames still stamp precisely. nil bands =
  full-damage-at-stamp-time → stamp all terminal runs (documented coarse
  case: a full-damage frame coinciding with new output blooms the whole grid
  once). The same stamp is re-applied to the same bands while
  `GlyphEffectTimeline.maxDecaySeconds` is open (effectStart stability), then
  stamping stops so re-emitted runs can never restart an effect.
- **Remote (laband) decision (M1): bloom is local-only.** The remote
  `makeFrame(_:remoteSnapshot:)` path is deliberately not stamped — the
  daemon's dirty ranges arrive already band-shaped and could feed the same
  record, but M1 keeps the semantic minimal. M2/M3 must decide whether the
  remote path gets stamping (bell shake is grid-wide and does not need it).
- **Frame pumping is renderer-self-managed (M1).** The Slug renderer tracks
  live effects per frame (run-level bands in `RenderDamage`'s CG-point y-up
  space), unions the previous frame's bands into incoming damage at
  `render()` entry (defeating the empty-effective-damage skip and giving the
  settle repaint one more pass), and exposes
  `glyphEffectAnimatingRemainingSeconds`. The view converts that into
  `glyphEffectAnimatingUntil` after each successful render; the M0 policy
  rung drives the link at 30 fps and the existing `advanceFrame` reconcile
  parks it. Decayed-but-still-stamped runs are filtered out of the live set
  by age so pumping stops at the kind's decay (150 ms), not the 300 ms
  stamping window. `shouldEncodePresent` needed **no change**: every pumped
  frame publishes a new frame version, which is exactly the "content
  changed" signal the present path keys on.
- **Intent catalog gate (M1).** New debug actions need four registrations:
  `DebugActionIntentID.knownActionNames` + `intentID(forAction:)`, an
  `IntentCatalog` descriptor (fixture-only, headless-only), the `DebugAction`
  decode/dispatch chain, and the discovery list. `IntentCatalogTests` pins
  the fixture descriptor id set — update the pin when adding fixture
  intents. Missing the descriptor surfaces as `{"error":"unsupported action"}`
  from `missingDescriptorResponse`, not from the action dispatcher.
- **Headless pixel probes read the software surface (M1).**
  `/debug/pixel-probe` sampled only `BitmapSurface`, which stays blank under
  GPU backends. It now samples the Slug target-texture readback
  (`SlugGlyphRenderer.readbackBGRA`, same pixels as `pngData` without the PNG
  round-trip) in the same 0xRRGGBBAA / y-up CG convention.
- **Deterministic time (M1).** Headless `--deterministic` runs drive the
  effect channel from a virtual clock: `HeadlessDebugRuntime.
  virtualTimeSeconds` feeds both `TerminalSurfaceController.outputStampClock`
  (new injection point) and `SlugGlyphRenderer.glyphEffectClock`, advanced
  only by the new `advanceTime` debug action (renders a frame after
  advancing). Non-deterministic runs fall back to `MonotonicClock`.
- **Scenario runner extensions (M1).** `run-debug-script` gained a top-level
  `renderer` key (passed as `--renderer=`) and `expectJson` comparators
  `lessThan`, `greaterThanPath`, `lessThanPath`, `equalsPath`,
  `notEqualsPath` (path-to-path comparisons inside one response);
  `schemas/debug-script.schema.json` documents both.
- **`wakeCount` semantics (M1).** In headless `/debug/state`,
  `glyphEffects.wakeCount` is the renderer's count of frames rendered with at
  least one live effect (the pumping evidence counter). The app-side
  display-link wake counter (`TerminalBitmapView.glyphEffectWakeCount`)
  exists but is not yet exposed — M3's `/debug/glyph-effects` endpoint
  surfaces both.
- **No Settings-window checkbox (M1).** The setting is
  `GlyphEffectSettings` (UserDefaults `LabanGlyphEffectsEnabled`, default
  false) + `LABAN_GLYPH_EFFECTS_ENABLED` env override, read live every frame
  (`GlyphEffectSettings.enabled && !reduceMotion` fed into the renderer per
  render pass — no observer needed since the flag is only consulted while
  building instances). A Settings-window toggle is a product-surface
  decision left for the spec.md discussion.
- **Pre-existing LabanAppTests failures (M1).** Five file-picker UI tests
  (`TerminalBackgroundSourceSettingsUITests`,
  `ThemeMenuControllerImportTests`) fail on this machine on the *pristine*
  tree too (verified via stash) — open-panel/UTType environment issue,
  unrelated to this plan.
- **Idle-proof environment pollution (M1).** A visible proof run on this
  machine is contaminated: `open -F` resolves the bundle id to the user's
  installed `~/Laban.app` (not the repo build), and that app reattaches to
  the user's live laband daemon with 8 chatty agent sessions. The clean
  evidence came from a CLI-launched repo build with `LABAN_TERMINAL_BACKEND=
  in-process`, `ZDOTDIR=<empty>`, workspace.json temporarily set aside, and
  output injected by writing to the session's tty. All state was restored
  afterwards (workspace files back, `LabanRendererMode` default deleted,
  launchctl env cleared).
- **Grid-wide ink-bloom flicker (post-M1) — Bug A.** Live PTY capture
  (`.tmp/blink-capture/appkit-2026-07-19T18-38-22Z`) + render journals
  showed every keystroke/settle burst flashing the *entire* scrollback
  faint for one frame (mean 234.5→240.8, dark-fraction collapse; dilation→0
  at age 0). Root cause: `stampFreshOutputTimestamps` treated
  `RenderDamage.full` as `bands = nil` = stamp every terminal run. That
  collapse is correct for Metal redraw safety (`dirty != 0` with no row
  bits → full redraw) but is **not** a freshness signal. Fix: stamp from
  new `freshnessBands(snapshot:)` (row-local bits only); unknown/ambiguous
  dirty → stamp nothing. `forceFullDamage` redraws no longer re-bloom
  settled scrollback. Evidence: journals `2026-07-19T183829946Z`…
  `T183838402Z`, flash frames correlate with `damage: full` settleWakes.
- **Effect pump never reached the renderer — Bug B.** Journals showed
  `glyphEffectAnimating: true` with hundreds of `event: skipped`
  displayLink ticks. Separate from the 120 fps `terminalOutputActive`
  reason (chatty sessions keep the output-hold refreshed — policy
  correctly outranks the 30 fps glyphEffect rung; see
  `testGlyphEffectWithActiveOutputPrefersActiveFrameRate`). The real
  pump bug: `advanceFrame`'s early-return guard had an
  `attentionStripFrame` latch but no glyph-effect equivalent, so once
  the output frame cleared `renderInvalidated`, subsequent link ticks
  returned before calling Slug `render()` — bloom froze on its first
  faint frame and `syncGlyphEffectAnimatingState` never observed decay.
  Fix: `glyphEffectStripFrame` / `glyphEffectWasAnimating` mirroring
  attention, and clear `glyphEffectAnimatingUntil` when remaining hits 0.
- **All-rows-dirty keystroke flash — Bug C.** Post-A/B capture
  `appkit-2026-07-19T18-58-19Z` + journals `T185827291Z`…`T185844411Z`:
  every `keyboard` wake reports `dirtyRowsSetCount == 32` (full grid)
  while the following `settleWake` correctly has `setCount == 1`.
  `freshnessBands` stamped the whole grid on the keystroke force-full
  frame → age-0 bloom flash of scrollback, then settle. Interim fix
  stamped cursor row + row above; that still bloomed the whole prompt
  line. Approach 1 (cursor-cell on coarse dirty only) still failed live:
  zsh synchronized updates dirty the prompt row precisely, FrameProducer
  coalesces prompt+input into one glyph run, and whole-run stamping
  re-bloomed the entire line on every keystroke (capture
  `appkit-2026-07-19T21-21-55Z`). **Approach 2 (current):** per-row cell
  content fingerprints + diff → X-strip stamp of only changed columns
  (split coalesced runs); multi-row / near-full-row rewrites still
  whole-run. Soften age-0 curve (~0.82/0.72 over 280 ms). Escalate to
  per-cell FrameCommand stamps (3) only if diff still mis-attributes.
- **Render-journal `glyphEffect` stamp summary.** Each journal entry now
  carries `glyphEffect: {mode, dirtyRows, stripColMin/Max, changedCells,
  stampedRuns, stampedGlyphs, stampAgeMs, generation, liveCount,
  animatingRemainingMs}` so dumps can prove cellDiff vs wholeRun without a
  PTY capture. `scripts/render-journal-summary` prints a mode/strip histogram.

## Artifacts and Notes

M0 verification (2026-07-19, on top of the confirmed-green baseline):

```
swift build                                        → Build complete! (19.27s)
swift test --filter TerminalIdlePolicy             → 30 tests, 0 failures
swift test --filter GlyphEffectTimeline            → 13 tests, 0 failures
swift test --filter SlugWeightCoreTextParity       → 1 test, 0 failures
swift test --filter Slug                           → 76 tests (2 skipped), 0 failures
```

Full suite, per test target (all 0 failures): LabanCoreTests 835,
LabanRendererTests 342, LabanDebugTests 240, LabanAppTests 667,
LabanTerminalCoreTests 169, LabanControlTests 183, LabanCLITests 101,
LabandTests 20, LabptyTests 117 — 2674 tests total.

Kind-0 pixel identity: `slugGlyphEvaluateEffect` returns before any
arithmetic for kind 0 and both structs kept their exact sizes (64 B / 96 B;
renames only, `UInt32`→`Float` is size-preserving), so default rendering is
bit-identical to the pre-change tree. The `SlugWeightCoreTextParity` and
`Slug` suites pass unchanged as the automated witness.

M1 verification (2026-07-19):

```
swift build                                        → Build complete!
swift test --filter TerminalIdlePolicy|GlyphEffectTimeline|SlugWeightCoreTextParity
                                                   → 45 tests, 0 failures
swift test --filter Slug                           → 76 tests (2 skipped), 0 failures
swift run LabanControlGen --check                  → check passed
Full suite per target: LabanCoreTests 837, LabanRendererTests 342,
  LabanDebugTests 240, LabanAppTests 667 (5 pre-existing env failures,
  see Surprises), LabanTerminalCoreTests 169, LabanControlTests 183,
  LabanCLITests 101, LabandTests 20, LabptyTests 117 — all 0 new failures
```

M1 scenario transcript — `fixtures/glyph-effects-ink-bloom.scenario.json`
(18 steps, slugGlyph, deterministic; artifacts in
`.artifacts/runs/glyph-effects-ink-bloom-*/`):

```
scripts/run-debug-script fixtures/glyph-effects-ink-bloom.scenario.json
  step 1..18: all ok → "debug script passed"
  probe transcript (region averages [R,G,B,A], 198x15 px over the same text):
    settled baseline : control [48,85,94,255]  fresh (empty) [22,65,76,255]
    age 0            : control [48,85,94,255]  fresh [32,70,81,255]  ← fainter
                       nonBackground 794 vs 784                      ← thinner
    age 40 ms        : control [48,85,94,255]  fresh [47,83,93,255]  ← easing
    age 240 ms       : fresh == control exactly [48,85,94,255], 794 == 794
    post-idle (3 more frames): still exactly equal; state active=false
  /debug/state glyphEffects: age0 {active:true, liveCount:1, lastKind:1,
    wakeCount:4} → settled {active:false, liveCount:0, lastKind:1,
    wakeCount:5} (wakeCount = effect-live frames, stops growing after decay)
  Pre-change failure mode: step 1 discovery requires the advanceTime and
  setGlyphEffectsEnabled actions, which do not exist pre-change.
```

M1 idle proof (real app, repo build, effects enabled via
`LABAN_GLYPH_EFFECTS_ENABLED=1`, slug renderer, in-process backend, quiet
shell, clean workspace):

```
Run A (window not frontmost, 90 s): advanceFrames = 0 in every 1 s
  idle-counters.jsonl snapshot (seq 1–90) — no effect-driven wake loop.
Run B (window visible; output injected via the session tty):
  seq 29: advanceFrames=99, displayLinkTicks=58   ← output + bloom pumping
  seq 30: advanceFrames=0,  displayLinkTicks=0    ← decayed, link parked
Both: ~/Library/Logs/Laban/idle-counters.jsonl (transcripts preserved in
this section; environment restored after measurement).
```

## Review Gate

Review status: NOT REVIEWED

## Pivot (2026-07-22): ink-bloom → keystroke impulse

Kind 1's evaluation is replaced; everything else in this plan (stamping,
channels, parking) stands. Rationale: user feedback on capture
`appkit-2026-07-22T21-02-31Z` — the faint/thin alpha+dilation wobble read as
flicker, not motion (it was also frame-starved to ~4 steps at the 30 fps
decorative budget). `gpt-research` (repo root) ranks a directional
"keystroke impulse" as the highest-payoff terminal glyph effect.

Final contract: a freshly stamped glyph arrives at scaleX 0.55 / scaleY 1.10
/ tilt 0.07 rad (full alpha, normal dilation) and springs to identity over
130 ms with a single easeOutBack overshoot (c1 = 1.70158, c3 = 2.70158; peak
progress ≈1.100 at ≈75 ms → scaleX ≈1.045, scaleY ≈0.990, tilt ≈ −0.4°),
pivoted on the glyph quad's center. The shader early-returns at
`age >= decay` before any arithmetic so settled frames are bit-identical to
kind 0 (the 300 ms stamp-retention horizon outlives the 130 ms visual
lifetime). Live effects ride the active (panel) display rate instead of the
30 fps decorative budget; they still park on decay. Constants mirrored in
`GlyphEffectTimeline.swift` ↔ `VectorGlyphShaders.metal`; transform ordering
verified (effect applies to the raw quad before `vector_to_ndc`; instance
`dilation` only feeds the fragment coverage threshold). Damage envelope: the
existing live-effect band (`origin.y − cellHeight … 3 × cellHeight`) covers
the ≤1.5 px worst-case spill; the reworked scenario
(`fixtures/glyph-effects-keystroke-impulse.scenario.json`, renamed from
`glyph-effects-ink-bloom.*`) proves settle pixel-identity including the gap
rows, and `SlugKeystrokeImpulseRendererTests` proves expired-stamp pixel
identity GPU-side. Setting renamed to "Keystroke impulse effect"; the
persisted key `LabanGlyphEffectsEnabled` is unchanged.


Gate items (all mechanical; run by a fresh review agent per PLANS.md):

- [ ] `git grep -n "effectStart" Sources/LabanRenderer/VectorGlyphShaders.metal`
      and `git grep -n "effectStart" Sources/LabanRenderer/SlugGlyphRenderer.swift`
      — both hit; field order/offsets identical in both struct definitions.
- [ ] `git grep -n "glyphEffectAnimating" Sources/LabanCore/TerminalIdlePolicy.swift`
      — hits in both `displayLinkShouldRun` and
      `preferredDisplayLinkFramesPerSecond`.
- [ ] `git grep -n "case glyphEffect" Sources/LabanApp/TerminalBitmapView.swift`
      — exactly one hit in `FrameWakeSource`.
- [ ] `swift test --filter TerminalIdlePolicy` — 0 failures.
- [ ] `swift test --filter GlyphEffectTimeline` — 0 failures.
- [ ] `swift test --filter SlugWeightCoreTextParity` — 0 failures (struct
      change did not perturb existing rendering).
- [ ] `swift test --filter Slug` — 0 failures.
- [ ] With `LabanGlyphEffectsEnabled` unset, headless scenario
      `fixtures/<new>.scenario.json` passes; its settled-frame pixel probes
      match the no-effect baseline probes recorded in the fixture.
- [ ] `git grep -n "glyph-effects" Sources/LabanControl/ControlRouteCatalog.swift`
      — hits.
- [ ] `git grep -n "glyph" docs/product/spec.md` — hits the new effects entry.

Review findings (filled in by the review agent):

_(empty)_

## Concrete Steps

From the repo root (`/Users/rrj/wrk/laban`):

```
# Baseline (must be green before starting)
swift test --filter Slug 2>&1 | tail -5
scripts/check

# During M0–M3 (after each edit batch)
swift build 2>&1 | tail -20
swift test --filter TerminalIdlePolicy
swift test --filter GlyphEffectTimeline
swift test --filter SlugWeightCoreTextParity
scripts/check

# Headless verification (M1+): run the new scenario fixture headlessly per
# dev-process.md §End-To-End Agent Tests, then inspect:
#   /debug/state → glyphEffects block
#   /debug/pixel-probe transcripts recorded by the fixture
#   .artifacts/.../idle-counters.jsonl → zero advanceFrames after decay
```

## Validation and Acceptance

Observable behavior, end state:

1. `scripts/check` passes; the full swift test suite passes.
2. With effects enabled, `printf 'a\nb\nc\n'` in a headful window shows new
   lines blooming in over ~150 ms; with effects disabled (or `reduceMotion`
   on), output appears exactly as before this plan.
3. `printf '\a'` with effects enabled shakes the grid once (~300 ms) and
   settles; settled pixels are identical to the pre-bell frame.
4. After any effect decays and output stops, the display link parks:
   `idle-counters.jsonl` records zero advanceFrames over a 5 s idle window
   (bench-idle-cpu evidence attached in Artifacts and Notes).
5. The M1 scenario fixture fails on the pre-change tree (endpoint missing) and
   passes after; its settled-frame probes equal the no-effect baseline.
6. Review Gate passes with a fresh review agent (max 3 review-fix loops, then
   escalate per PLANS.md).

## Idempotence and Recovery

Every milestone is independently revertible (`git revert` of its changeset);
M0 with kind-0-only output is pixel-identical to baseline, so a partial tree
(M0 without M1/M2) is safe to leave in. If the struct-mirror rule is violated
the failure mode is immediate (Metal argument/stride mismatch at first render
or failing parity tests), not silent corruption. The feature is default-off;
recovery from any runtime misbehavior is unsetting `glyphEffectsEnabled`.

## Artifacts and Notes

_(to be filled during execution: bench transcripts, idle-counters excerpts,
scenario transcripts, review-gate results)_

## Interfaces and Dependencies

End-state interfaces that must exist:

- `SlugGlyphGPUInstance` (Swift) / `SlugGlyphInstance` (Metal): fields
  `effectKind: UInt32`, `effectStart: Float` replacing `pad1`/`pad2`;
  stride unchanged at 64 B.
- `SlugGlyphGPUUniforms` (Swift) / `SlugGlyphUniforms` (Metal): fields
  `timeSeconds: Float`, `bellAmplitudePx: Float`, `bellDirection: Float`
  replacing `pad1/pad2/pad3`; stride unchanged at 96 B.
- `FrameCommand.glyphRun`: `outputTimestampSeconds: Double?`.
- `TerminalIdlePolicy.displayLinkShouldRun(...)` /
  `preferredDisplayLinkFramesPerSecond(...)`: additional
  `glyphEffectAnimating: Bool` input (shims updated; the input has a `false`
  default so pre-existing 6-argument call sites stay source-compatible).
- `FrameWakeSource.glyphEffect`; `DisplayLinkPolicyState` reason rung
  `"glyphEffect"`.
- `MonotonicClock` (mach_absolute_time-based seconds) shared by the stamp and
  the renderer's `timeSeconds`; `SlugGlyphRenderer.glyphEffectClock`
  injection point for tests/headless.
- Debug-only trigger `SlugGlyphRenderer.debugGlyphEffectKind` /
  `LABAN_GLYPH_EFFECT_DEBUG_TRIGGER` env var to fire a synthetic kind≠0
  effect on freshly stamped runs.
- `Sources/LabanCore/GlyphEffectTimeline.swift`: pure easing/liveness
  functions per effect kind, with `decaySeconds` constants.
- `TerminalSurfaceController.outputStampClock` injection point; per-session
  `(generation, stamp, bands)` stamp record re-applied while
  `GlyphEffectTimeline.maxDecaySeconds` is open. Freshness bands come from
  `freshnessBands(snapshot:)` (row-local dirty bits); ambiguous/global dirty
  without row bits skips stamping rather than blooming the whole grid.
- `SlugGlyphRenderer.glyphEffectsEnabled` (live per frame, reduceMotion
  pre-applied by the view) and live-state outputs
  `glyphEffectLiveCount` / `lastGlyphEffectKind` /
  `glyphEffectAnimatingRemainingSeconds` / `glyphEffectFrameCount`;
  `readbackBGRA()` for headless pixel probes.
- Debug actions `advanceTime` (deterministic virtual clock + render) and
  `setGlyphEffectsEnabled`; `glyphEffects` block in headless `/debug/state`.
- Scenario runner: top-level `renderer` key and `expectJson` comparators
  `lessThan`, `greaterThanPath`, `lessThanPath`, `equalsPath`,
  `notEqualsPath`.
- `GET /debug/glyph-effects`: resettable counters (started, frames, wakes,
  parkRestores); `glyphEffects` block in `/debug/state`.
- Setting `glyphEffectsEnabled` (default false), honored together with
  `reduceMotion`.
- New scenario fixture `fixtures/glyph-effects-*.scenario.json` validating
  bloom + bell + settle-identical + idle-park behavior.
