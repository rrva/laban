# Motion-smoothed ANSI/ASCII spinners (detect steady small-region redraws, interpolate between them)

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root. Keep `Progress` and `Validation and Acceptance`
current as work proceeds.

## Purpose / Big Picture

Modern TVs run "motion interpolation" (marketed as TruMotion, MotionFlow,
Auto Motion Plus, etc.): they synthesize extra frames between the ones a
24-30fps source actually provides, so motion looks buttery instead of
juddery. It is famous for two things: making things look noticeably
smoother, and the "soap opera effect" that makes film purists reach for the
remote to turn it off. Both properties are relevant here.

Many terminal programs animate a small part of the screen at a modest,
steady rate: a spinner character cycling, a status word pulsing through
different brightness levels, a progress bar's fill color shifting. A
concrete example already visible in this repo's own daily use: Claude Code
prints a verb like "Zigzagging" while it works, and a brightness ripple runs
left-to-right across the letters, redrawn every time the underlying app
writes a new frame (roughly every 100ms for that kind of spinner, though the
exact rate is app-specific and this plan never hardcodes it). Today Laban
redraws that word exactly as fast as the app writes it and no faster — there
is no synthesis, so the ripple looks exactly as chunky as the source data.

After this plan, Laban notices *any* small region of the grid that keeps
being rewritten at a steady, spinner-like cadence — this works for any
program's spinner or pulsing status text, not just Claude Code's, and Laban
never inspects the running program's name or output text to decide — and
smooths the transitions between the real states it receives, the same way a
TV smooths between real film frames. Concretely, for a cell whose character
does not change but whose color does (the "Zigzagging" ripple case), instead
of snapping straight from color A to color B the moment new PTY output
arrives, Laban eases the displayed color from A to B continuously over the
gap between updates, so the ripple reads as a continuous wave instead of a
strobe. This is opt-in and off by default (see Design decisions below) — the
"turn off the soap opera effect" toggle for anyone who finds smoothed
terminal output distracting.

How to see it working (once M1 lands): enable the setting, run a program
that repaints a spinner in place (or the synthetic scenario fixture this
plan adds), and watch the color transitions read as a continuous ripple
instead of discrete jumps. Disable the setting (the default) and output is
pixel-identical to today. Either way, once the spinner stops, the display
link parks exactly as it does today — `idle-counters.jsonl` shows zero
`advanceFrames` over a subsequent idle window.

## Context and Orientation

This section assumes no prior context beyond a checkout of this repository.

**Relationship to `execplans/active/per-glyph-animation-channel.md`.** A
separate, already-partially-shipped ExecPlan (three commits landed on branch
`per-glyph-animation-channel` as of this writing: `46cd1b6b`, `b6358251`,
`467158fd`) built a **per-glyph animation channel**: a way for the GPU
renderer to animate individual glyphs over time. That plan's first consumer
was an "ink-bloom" type-in effect (freshly typed text eases in) and a
planned-but-unbuilt "visual bell shake". This plan **reuses that channel's
substrate** (the per-instance `effectKind`/`effectStart` payload, the
`timeSeconds` uniform, the vertex-shader evaluation hook — all described
below) but is **independent of and does not require** that plan's ink-bloom
effect or bell shake to ship, stay, or be removed. The two plans share one
resource that needs explicit coordination: the `effectKind` integer values
each new effect uses (0 = none, 1 = ink-bloom already shipped, 2 = bell
shake reserved-but-unbuilt by the sibling plan). This plan claims **3** and
**4** (defined below) and must not collide with those. The fate of
ink-bloom itself (kind 1) is a separate, still-open product question for the
user and is out of scope for this plan to decide.

**Key terms, defined plainly:**

- **Cell** — one character position in the terminal grid: a row/column pair
  holding one grapheme cluster (visible character(s)), a foreground color, a
  background color, and style flags (bold, underline, etc.).
- **Generation** — a monotonically increasing integer Laban's PTY layer
  (`libghostty-vt`, wrapped by `Session`) bumps every time new terminal
  output changes any cell. `session.dirtyGeneration()` reads it.
- **Glyph run** — one `FrameCommand.glyphRun` value (defined at
  `Sources/LabanRenderer/FrameCommand.swift:158`): a horizontal run of
  adjacent cells sharing color/attributes, rendered as one text string. The
  renderer never draws individual cells directly; it draws runs.
- **Cross-fade** — this plan's core mechanic: rendering the *old* cell
  content and the *new* cell content as two overlapping instances at the
  same position, one fading out (alpha 1→0) and one fading in (alpha 0→1),
  so the transition between them reads as a smooth blend instead of an
  instant swap. This is exactly what a video cross-dissolve does with two
  frames; here it is done per-cell with two colors (or, in the deferred M2,
  two different glyphs).
- **Instance** — one `SlugGlyphGPUInstance` (Swift,
  `Sources/LabanRenderer/SlugGlyphRenderer.swift:56`) / `SlugGlyphInstance`
  (Metal mirror, `Sources/LabanRenderer/VectorGlyphShaders.metal:594`): the
  fixed-size (64 bytes) struct the GPU reads once per drawn glyph. Today one
  cell in one glyph run produces exactly one instance; this plan's M1 makes
  actively-transitioning cells produce **two** instances (old + new) for the
  duration of their cross-fade, and one instance again once it settles.

**Existing diffing machinery this plan builds on** (all in
`Sources/LabanCore/TerminalSurfaceController.swift`, already exercised and
verified correct for its current purpose by a prior review of this exact
branch):

- `TerminalSurfaceController.cellFingerprints(snapshot:rows:)` (line 1173)
  computes one hash per cell (character bytes + style) per row, used to tell
  "this cell changed" from "this cell is unchanged" cheaply.
- `TerminalSurfaceController.freshness(snapshot:cellWidth:cellHeight:originX:
  originY:previousFingerprints:)` (line 1331) and its helper
  `freshnessFromCellDiff(dirtyRows:...)` classify each generation's change as
  one of: `cellDiff` (one dirty row, a small contiguous span of changed
  columns — exactly the shape of a spinner or a shimmering word), `wholeRun`
  (multi-row or near-full-row rewrite — a bulk TUI redraw, e.g. `btop`; never
  a spinner), `cursorCell`, or none.
- `TerminalSurfaceController.stampFreshOutputTimestamps` (private, line
  1682) is called once per frame from `makeFrame` (public overloads at lines
  703 and 917) and currently only *mutates the `outputTimestampSeconds`
  field* on existing `FrameCommand.glyphRun` values already built earlier in
  `makeFrame` (via `Sources/LabanCore/FrameProducer.swift`, a `struct` — see
  line 34 — that turns the raw grid snapshot into glyph runs). This plan's
  M1 extends this step to *also insert new synthetic glyph-run commands*
  (the fading-out "old" instance) alongside the real ones — see Plan of
  Work.

**Important limitation of the current fingerprint hash:** it combines
character bytes and style into one hash, so today's code can tell "this cell
changed" but not "did only the color change, or did the character change
too." M1 must add a way to compare the actual old vs. new character
separately from color, described in Plan of Work.

**Frame scheduling / idle contract this plan must respect (binding for new
code, per `docs/adr/0018-event-driven-frame-production.md`, "frame
production is event-driven ... the display link is a transient animation
timer that fully parks on a quiescent, focused window"):**

- `Sources/LabanCore/TerminalIdlePolicy.swift` (134 lines, pure, no AppKit
  import — verified by reading the whole file) defines three named rates:
  `idleDisplayLinkFramesPerSecond = 8`, `activeDisplayLinkFramesPerSecond =
  120`, `animationDisplayLinkFramesPerSecond = 30`. `displayLinkShouldRun(...)`
  (line 49) takes seven booleans (`windowVisibleToUser, scrollAnimating,
  attentionAnimating, terminalOutputActive, cursorBlinkActive,
  idleFloorEnabled, glyphEffectAnimating`) and ORs the last six together,
  gated by `windowVisibleToUser` (scroll always wins outright).
  `preferredDisplayLinkFramesPerSecond(...)` (line 86) picks 120 if
  `scrollAnimating || terminalOutputActive`, else 30 if `attentionAnimating
  || glyphEffectAnimating`, else 8. Both functions default
  `glyphEffectAnimating` to `false` so existing 6-argument call sites keep
  compiling.
- `Sources/LabanApp/TerminalBitmapView.swift`: `FrameWakeSource` (line 2605)
  is a `String`-backed enum with cases including `.glyphEffect`;
  `displayLinkPolicyState(now:)` (line 2357) computes the same booleans,
  calls the two policy functions, and separately builds a human-readable
  `reason` string via its own `if/else` ladder (lines 2397-2418), currently
  ending `...→ attentionAnimating → terminalOutputActive → glyphEffectAnimating
  ("glyphEffect") → !windowVisibleToUser → cursorBlinkActive → idleFloorEnabled
  → "parked"`.
- `terminalOutputActive` (used above) is a fixed 150ms hold window
  (`terminalOutputDisplayLinkHoldSeconds = 0.150`, line 496), **not** a
  cadence/frequency measurement — confirmed by reading the whole file: no
  code anywhere in `Sources/LabanCore/` or `Sources/LabanApp/` currently
  tracks how often output arrives, only whether it arrived "recently" against
  a fixed timeout. This plan is the first thing in the repo to need real
  cadence tracking (see Plan of Work, M0).
- `Sources/LabanApp/RenderJournal.swift`: `DisplayLinkSnapshot` (line 84) has
  an optional `glyphEffectAnimating: Bool? = nil` field — the established
  pattern for adding an optional field so old journal dumps still decode.

## Design decisions (made here, not left to the reader)

- **The elevated frame rate reuses the existing 30fps "decorative animation"
  tier, not the 120fps "active" tier.** A naive "boost the framerate" reading
  would push straight to 120fps. Rejected: color/brightness interpolation
  does not need 120fps to read as smooth to a human eye (unlike on-screen
  motion of edges or text position, which is far more demanding); and unlike
  the sibling plan's ink-bloom (bounded to a ~300ms burst per keystroke), a
  spinner can run for the full duration of a long-running command — tens of
  seconds to minutes for something like an LLM "thinking" indicator. Holding
  the display link at 120fps for minutes at a time on a laptop is a real,
  avoidable battery/thermal cost for a purely cosmetic feature. 30fps is
  already a 3.75x lift over the 8fps idle floor and is plenty smooth for
  color-only motion.
- **Cross-fade via two overlapping instances, not new GPU struct fields.**
  `SlugGlyphGPUInstance` is 64 bytes and `SlugGlyphGPUUniforms` is 96 bytes,
  with **zero spare bytes** left after the sibling plan's `effectKind`/
  `effectStart`/`timeSeconds`/`bellAmplitudePx`/`bellDirection` additions
  (confirmed: both pad-word budgets are fully consumed). Growing either
  struct is exactly the kind of change that, if the Swift and Metal mirrors
  drift even slightly, corrupts GPU memory silently rather than failing to
  compile — the single riskiest category of bug in this renderer (see
  `docs/adr/0026-display-synced-drawable-acquisition.md` and the renderer
  safety rules in `docs/process/agent-operating-guide.md`). Rendering the
  cross-fade as two ordinary instances (the "old" cell's real content fading
  out, the "new" cell's real content fading in) needs zero new fields — it
  reuses the alpha channel and the `effectKind`/`effectStart` mechanism the
  sibling plan already built and proved out, so this plan inherits none of
  the struct-parity risk.
- **New effect kinds 3 (`crossfadeIn`) and 4 (`crossfadeOut`), not a reuse of
  kind 1 (ink-bloom).** Ink-bloom's curve also eases `dilation` (glyph
  weight, thin→normal). This feature only ever wants to ease alpha/color, not
  weight — reusing kind 1 would silently couple this feature's visual
  correctness to ink-bloom's unrelated tuning. `crossfadeIn`/`crossfadeOut`
  hold `dilation` constant and only ease `color.a` (in of 0→1, out 1→0).
- **MVP scope is same-glyph, color/attribute-changed cells only** (exactly
  the "Zigzagging" ripple: character identity is unchanged, only color
  changes). Different-glyph substitution (e.g. a rotating Braille spinner
  `⠋→⠙→⠹...`, a genuinely different Unicode codepoint each tick) is
  deliberately **not** in this plan's committed scope — it is a materially
  harder visual problem (two overlapping different glyph shapes blended by
  alpha can read as muddy/ghosted rather than smooth, the way fast motion on
  a real TV with interpolation on produces visible ghosting artifacts) and
  needs its own visual-quality validation before committing to it. It is
  captured as an explicitly optional, prototype-first milestone (M2) per
  PLANS.md's guidance for challenging/uncertain designs — implement it,
  screenshot-compare it, and decide whether to keep it, rather than assuming
  it ships.
- **Detection is generic — no process-name or literal-text matching.** The
  detector operates purely on the shape and cadence of grid changes (small
  region, steady inter-tick interval), never on which program is in the
  foreground or what text it prints. This is deliberate: it is meant to
  "carry to many ANSI/ASCII spinners" (the user's own framing) — Claude
  Code's verb-shimmer is this plan's concrete demo case, not its target.
  Laban does expose the foreground process name generically (`laban status
  --json` reports a `process.foregroundProcess` field), but keying detection
  to a literal program name would be fragile (broken by wrapper scripts,
  aliases, or the target app changing its spinner UI) and defeats the
  generality goal, so this plan does not use it.
- **Cross-fade duration is derived per-detection from the observed cadence,
  not a fixed constant.** Ink-bloom eases toward a fixed final state over a
  fixed 280ms regardless of what happens next. This feature must instead
  finish easing *approximately when the next real update arrives* — too
  short and the display holds a settled frame waiting for the next tick
  (looks like it paused); too long and the next real tick arrives mid-ease
  and the color visibly jumps ("double-motion", the same artifact real TV
  motion interpolation shows on fast pans). The duration is therefore
  `clamp(rollingAverageIntervalSeconds, 0.04, 0.6)` — the same 40ms-600ms
  band used to qualify a run as spinner-like in the first place (defined
  below), recomputed from the last few observed ticks. A single unusually
  fast or slow tick cannot swing it outside that band.
- **Default off, `reduceMotion` forces off.** Same opt-in posture as the
  sibling plan (ADR 0017/0022/0027), and the same escape hatch this plan's
  premise explicitly calls for: a toggle for anyone who does not want their
  terminal doing TV-style motion smoothing on principle. Promotion to
  default-on is a separate `docs/product/spec.md` decision, not part of this
  plan.
- **The debug toggle action must echo the value it actually applied, not a
  blind `{"ok": true}`.** A prior review of the sibling ink-bloom plan's
  `setGlyphEffectsEnabled` debug action found it always reports success even
  when the `LABAN_GLYPH_EFFECTS_ENABLED` environment variable silently
  overrides the write it just made, producing a false-success response. This
  plan's equivalent action (`setSpinnerMotionSmoothingEnabled`, M3) must
  return the resulting *effective* enabled state (after considering any env
  override) in its response body, not merely whether the write call was
  issued, so this exact bug class cannot recur here.

## Plan of Work

### M0 — Cadence detector and idle-policy plumbing (no visual change yet)

Goal: Laban can tell, in real time, "a small region of the grid is being
rewritten at a steady spinner-like cadence right now," and the display link
responds to that signal — before any pixel looks different.

1. **New pure type** `Sources/LabanCore/SpinnerMotionDetector.swift`
   (AppKit-free, unit-testable without a window — mirrors the existing
   `GlyphEffectTimeline.swift` and `Sources/LabanCore/TabAttention.swift`'s
   `AttentionPulse` pattern of pure timeline functions plus a small piece of
   retained state). It consumes, once per generation, the `cellDiff`
   classification `TerminalSurfaceController.freshnessFromCellDiff` already
   computes (row, `stripColMin`/`stripColMax`, timestamp) and maintains, per
   session:
   - A short ring of the last 5 qualifying observations (row, column range,
     arrival timestamp).
   - **Qualifying** means: same row as the previous observation (or within 1
     row, to tolerate a two-line status block), column range overlapping the
     previous one or within 4 columns of it, and the gap since the previous
     observation between 0.04s and 0.6s. Any observation outside those bounds
     resets the run to length 1 (starts over) rather than aborting detection
     outright, so an occasional missed/coalesced tick does not permanently
     disqualify a genuine spinner.
   - **Active** once the run reaches length 3 (matches the sibling plan's
     precedent of requiring multiple consecutive confirmations before
     triggering anything visible, avoiding one-off false positives from
     ordinary prompt redraws).
   - Exposes `isActive`, `estimatedCadenceSeconds` (rolling average of the
     last observed gaps, clamped 0.04-0.6 as decided above), and
     `anchorRow`/`columnRange` for the currently-active run.
   - **Decays** (goes inactive) once `2 × estimatedCadenceSeconds` has
     elapsed with no new qualifying observation, capped at an absolute 0.8s
     ceiling — mirrors the "decays to zero wakeups" shape already
     established by `AttentionPulse` and the sibling plan's
     `GlyphEffectTimeline`, so a spinner that simply stops does not leave
     anything running.
2. **`TerminalIdlePolicy.swift`**: add a `spinnerMotionActive: Bool = false`
   parameter to both `displayLinkShouldRun(...)` and
   `preferredDisplayLinkFramesPerSecond(...)`, OR'd into exactly the same
   position as the existing `glyphEffectAnimating` (i.e. it joins the 30fps
   tier, per the Design decision above, not a new tier). Update both
   compatibility shims. Unit tests: mirror the existing
   `testGlyphEffectWithActiveOutputPrefersActiveFrameRate`-style test for
   the new boolean (asserts `terminalOutputActive` still wins the 120fps
   tier over `spinnerMotionActive`), plus an explicit park-on-decay test
   (`spinnerMotionActive: false` and every other input false →
   `displayLinkShouldRun == false`) — the sibling plan's equivalent test for
   `glyphEffectAnimating` was found missing during review; do not repeat that
   gap here.
3. **`TerminalBitmapView.swift`**: add `FrameWakeSource.spinnerMotion`
   (exactly one new case), a `spinnerMotionActiveUntil` state field mirroring
   `glyphEffectAnimatingUntil` (line 358), a `"spinnerMotion"` rung inserted
   into the `displayLinkPolicyState` reason ladder next to `"glyphEffect"`
   (same priority slot), and a `spinnerMotionStripFrame`/
   `spinnerMotionWasAnimating` latch pair mirroring the existing
   `glyphEffectStripFrame`/`glyphEffectWasAnimating` pair in the
   `advanceFrame` early-return guard (around line 2950) — the sibling plan's
   review found that without this exact latch shape, the display link can
   tick forever without ever calling the renderer again once the ordinary
   output frame's `renderInvalidated` clears; the fix there is the template
   to copy here, not a new mechanism to invent.
4. **`RenderJournal.swift`**: add an optional `spinnerMotion: SpinnerMotionSnapshot?`
   field to `Entry` and an optional `spinnerMotionActive: Bool? = nil` field
   to `DisplayLinkSnapshot`, following the exact optional-field pattern
   `glyphEffectAnimating` already established (old dumps decode these as
   `nil`).

M0 acceptance: `SpinnerMotionDetectorTests` cover the qualifying/reset/decay
rules directly (no window, no renderer); `TerminalIdlePolicyTests` cover the
new boolean's precedence and park-on-decay; a synthetic scripted sequence of
qualifying cell-diffs (fed via the headless `/debug` surface, see M3) can be
observed in the render journal's new `spinnerMotion` field going active then
decaying — but no pixel changes yet (M0 deliberately produces no visual
effect, matching the sibling plan's own M0 precedent of "substrate only").

### M1 — Same-glyph color cross-fade (the actual visual smoothing)

Goal: when `SpinnerMotionDetector` is active and the setting is enabled, a
cell whose character is unchanged but whose color changed eases between the
two colors instead of snapping.

1. **Track enough history to build the "old" instance.** The existing
   `lastCellFingerprints` (hash-only) is not enough — this needs the actual
   previous character and color for cells inside the currently-detected hot
   region, not just a hash proving *something* changed. Add a small, bounded
   companion cache (bounded because the hot region is small by construction
   — a handful of cells) keyed by `(sessionId, row, column)`, storing the
   prior grapheme cluster, foreground color, and background color, populated
   whenever `SpinnerMotionDetector` is active and evicted for a cell as soon
   as its cross-fade completes or the detector goes inactive.
2. **Classify each changed cell in the hot region** by comparing its new
   character against the cached prior character:
   - **Same character, different color** → this milestone's target case.
     Continue to step 3.
   - **Different character** → out of scope for M1 (deferred to M2). Render
     exactly as today (instant swap, no cross-fade) — this must be a
     deliberate, tested fallback, not an accident of the code not handling
     it.
3. **Inject a synthetic "old" glyph run.** In
   `TerminalSurfaceController.stampFreshOutputTimestamps` (or an immediately
   adjacent step in `makeFrame`, whichever proves cleaner once the
   surrounding code is in front of you — this is the one place in the plan
   deliberately left to the executing agent's judgment, since the exact
   splice point depends on details of `FrameProducer`'s output shape not
   worth over-specifying here), for each cell entering a color cross-fade,
   emit one extra `FrameCommand.glyphRun` carrying the cell's *prior*
   character and color, `effectKind = 4` (`crossfadeOut`), and `effectStart`
   set to now. The normal glyph run for that cell (already built with the
   *new* character and color) gets `effectKind = 3` (`crossfadeIn`),
   `effectStart` set to the same timestamp. Both ride the existing
   `outputTimestampSeconds` stamping path already built by the sibling plan.
4. **Shader**: in `Sources/LabanRenderer/VectorGlyphShaders.metal`'s
   `slugGlyphEvaluateEffect` (or the equivalent current name — read the
   function the sibling plan added before editing it), add cases for kind 3
   and kind 4: both compute `age = uniforms.timeSeconds - instance.effectStart`
   and `t = clamp(age / durationSeconds, 0, 1)` exactly as the existing
   ink-bloom case does, but only write `color.a *= t` (kind 3) or
   `color.a *= (1 - t)` (kind 4); `dilation` is left untouched in both cases
   (Design decision above). `durationSeconds` for a given pair of instances
   is the cross-fade duration computed in step 3 above (from
   `SpinnerMotionDetector.estimatedCadenceSeconds`, clamped 0.04-0.6) —
   thread it through the same way `effectStart` is threaded through today
   (per-instance, since different concurrently-animating cells across
   different sessions/tabs could have different estimated cadences).
5. **Setting**: new `Sources/LabanCore/SpinnerMotionSmoothingSettings.swift`,
   mirroring `GlyphEffectSettings.swift` field-for-field (UserDefaults key
   `LabanSpinnerMotionSmoothingEnabled`, environment override
   `LABAN_SPINNER_MOTION_SMOOTHING_ENABLED`, default `false`), consulted live
   per frame together with `reduceMotion` (no observer needed, same
   rationale as the sibling plan: the flag is only read while building
   instances).
6. **Idle proof**: after the spinner stops and both instances finish easing,
   `IdleCounters` shows zero `advanceFrames` over a subsequent 5s idle
   window, same method as the sibling plan's M1 idle proof.

M1 acceptance: with the setting enabled, a scripted synthetic same-glyph
color-changing sequence (fixture, see M3) shows via `/debug/pixel-probe`
that a frame captured strictly between two real updates has a color
*between* the two real colors (proving genuine interpolation, not just a
faster identical redraw); with the setting disabled (default) or
`reduceMotion` on, output is pixel-identical to the pre-plan tree.

### M2 — Different-glyph cross-fade (optional, prototype-first)

Explicitly optional and explicitly a prototype per PLANS.md's guidance for
challenging/uncertain designs. Goal: generalize M1's mechanism to a spinner
that cycles through genuinely different characters (e.g. a rotating Braille
spinner). Mechanically this is the same "old instance fades out, new
instance fades in" shape as M1 — the *old* instance's glyph is now a
different codepoint than the *new* instance's, not just a different color —
so no new renderer mechanism is needed, only relaxing M1 step 2's
"same-character" gate for a specific, separately-flagged sub-mode.

1. Build the relaxed classifier behind its own separate setting default
   (**not** enabled by turning on M1's setting alone), so it can ship, be
   evaluated, and be reverted independently of the color-only case.
2. Capture side-by-side screenshots (spinner-motion off vs. on) for at least
   two visually distinct spinner styles (e.g. a Braille-dot spinner and a
   block-character spinner) and inspect them for the ghosting/muddiness risk
   named in Design decisions.
3. **Go/no-go**: if the cross-faded transition reads as smoother than a hard
   cut in both cases, promote the sub-mode to a normal (still default-off)
   setting and fold it into M3's Review Gate. If it reads as muddy/ghosted,
   record that finding in Surprises & Discoveries, leave the sub-mode behind
   a debug-only trigger (not user-facing), and stop — this milestone is
   explicitly allowed to end in "built a prototype, decided not to ship it."

### M3 — Observability, settings wiring, E2E, docs, review gate

1. **Debug actions**: `setSpinnerMotionSmoothingEnabled` (payload:
   `enabled: Bool`), registered through all four places a new debug action
   needs registration in this codebase (a gotcha the sibling plan's own
   Surprises section documents and this plan's own review confirmed still
   holds): `DebugActionIntentID.knownActionNames` +
   `intentID(forAction:)` (`Sources/LabanCore/Intents/DebugRequestPayloads.swift`),
   an `IntentCatalog` descriptor (`Sources/LabanCore/Intents/IntentCatalog.swift`),
   the decode/dispatch chain (`Sources/LabanDebug/DebugRuntimeRequests.swift`,
   `Sources/LabanDebug/DebugRuntimeActions.swift`), and the discovery list
   (`Sources/LabanDebug/DebugDiscoveryEndpoints.swift`). Update
   `IntentCatalogTests`'s fixture-id pin to include it. Per the Design
   decision above, its response must echo the resulting effective enabled
   state (post any environment override), not a blind `{"ok": true}`.
2. **`GET /debug/spinner-motion`**: resettable counters, following the exact
   shape of `GET /debug/transparency` (ADR 0028,
   `docs/adr/0028-terminal-background-transparency.md`; response type
   `Sources/LabanCore/Intents/DebugRequestPayloads.swift:456`,
   `TerminalTransparencyDebugResponse`): detections started, crossfades
   rendered, wake count, park-restored count, resettable via a
   `{"action":"resetSpinnerMotionDiagnostics"}` debug action.
3. **`/debug/state`**: add a `spinnerMotion: {active, row, colMin, colMax,
   estimatedCadenceMs, crossfadeCount, wakeCount}` block, following the
   `glyphEffects` block's exact shape and response-model file
   (`Sources/LabanCore/Projections/ControlResponseModels.swift`). Populate it
   in `HeadlessDebugRuntime` regardless of which renderer backend a scenario
   selects (the sibling plan's review found its `glyphEffects` block is
   `nil`, not zeroed, unless `--renderer=slugGlyph` is explicit — do not
   repeat that trap; this block should read as a real zeroed/inactive state
   for any renderer, not `null`).
4. **Scenario fixture** `fixtures/spinner-motion-smoothing.scenario.json`,
   following `fixtures/glyph-effects-ink-bloom.scenario.json`'s shape
   (top-level `name/description/fixture/renderer/deterministic/steps`,
   `expectJson` assertions). Script a synthetic same-glyph, alternating-color
   write sequence at a fixed ~100ms cadence via the deterministic virtual
   clock (`advanceTime` debug action, already built by the sibling plan and
   confirmed wired to both `TerminalSurfaceController`'s stamp clock and the
   renderer's `timeSeconds`), and assert: (a) `spinnerMotion.active` becomes
   `true` after 3 qualifying ticks, (b) a pixel probe strictly between two
   ticks shows a blended color, (c) `spinnerMotion.active` returns to `false`
   after the decay window with no further ticks, (d) with the setting left
   at its default (off), the same script's pixel probes are byte-identical
   to a captured no-smoothing baseline. **Wire this fixture into
   `scripts/test-e2e`** (add a `run-debug-script
   fixtures/spinner-motion-smoothing.scenario.json` step alongside the
   existing ones there) — the sibling plan's own ink-bloom fixture was found
   during review to exist but never actually run in CI; do not repeat that
   gap.
5. **Docs**: one line in `docs/product/spec.md` describing the (default-off)
   spinner motion-smoothing setting; a note in
   `docs/process/agent-operating-guide.md`'s renderer safety rules
   acknowledging effect kinds 3/4 now exist and what they own (parallel to
   the sibling plan's own required note about kinds 1/2); AGENTS.md
   untouched (no convention changes).
6. **Review Gate** (below), executed by a fresh agent.

## Progress

- [x] Plan filed at `execplans/active/spinner-motion-smoothing.md`
- [ ] M0 — cadence detector and idle-policy plumbing
- [ ] M1 — same-glyph color cross-fade
- [ ] M2 — different-glyph cross-fade (optional, prototype-first; may end in "decided not to ship")
- [ ] M3 — observability, settings wiring, E2E, docs
- [ ] Review Gate passed

## Decision Log

- Decision: Elevated frame rate reuses the existing 30fps decorative tier
  (`animationDisplayLinkFramesPerSecond`), not a new/max-fps tier.
  Rationale: color-only motion does not need 120fps to look smooth, and a
  spinner can run far longer than the sibling plan's bounded ink-bloom
  bursts — sustaining max fps for a multi-minute "thinking" spinner is a
  real, avoidable battery/thermal cost.
  Date/Author: 2026-07-20 / Claude

- Decision: Cross-fade renders as two overlapping GPU instances (old fading
  out, new fading in) instead of adding fields to `SlugGlyphGPUInstance` /
  `SlugGlyphGPUUniforms`.
  Rationale: both structs have zero spare bytes left after the sibling
  plan's additions; growing them risks silent GPU memory corruption if the
  Swift/Metal mirrors drift. Reusing the existing alpha-ease mechanism needs
  no struct change and inherits none of that risk.
  Date/Author: 2026-07-20 / Claude

- Decision: New effect kinds 3 (`crossfadeIn`) / 4 (`crossfadeOut`) rather
  than reusing kind 1 (ink-bloom).
  Rationale: ink-bloom's curve also eases `dilation`, which this feature
  does not want; reuse would couple two unrelated features' visual tuning.
  Date/Author: 2026-07-20 / Claude

- Decision: MVP (M1) covers same-character/color-changed cells only;
  different-glyph substitution is a separate, optional, prototype-first
  milestone (M2), not assumed to ship.
  Rationale: color interpolation between two known RGB values is
  unambiguous; blending two different glyph shapes is a genuinely different
  and riskier visual problem that needs its own quality checkpoint before
  committing to it.
  Date/Author: 2026-07-20 / Claude

- Decision: Detection is purely shape/cadence-based; it never inspects the
  foreground process name or terminal text content.
  Rationale: the goal is to generalize across any ANSI/ASCII spinner style,
  not to special-case one program; name-based matching would be fragile and
  defeats that goal.
  Date/Author: 2026-07-20 / Claude

- Decision: This plan depends on `per-glyph-animation-channel.md`'s M0
  substrate (already merged) but not on its M1 (ink-bloom) or M2 (bell
  shake); it claims effect kinds 3/4, leaving kind 2 reserved for that
  plan's still-unbuilt bell shake.
  Rationale: avoid a numbering collision between two ExecPlans sharing one
  GPU enum's value space; keep this plan executable regardless of what the
  user ultimately decides about ink-bloom.
  Date/Author: 2026-07-20 / Claude

## Review Gate

- [ ] `git grep -n "crossfadeIn\|crossfadeOut" Sources/LabanRenderer/VectorGlyphShaders.metal`
      and `git grep -n "crossfadeIn\|crossfadeOut" Sources/LabanRenderer/SlugGlyphRenderer.swift`
      — both hit; kind numbering (3, 4) matches in both files and does not
      collide with kind 1 or 2.
- [ ] `git diff main -- Sources/LabanRenderer/SlugGlyphRenderer.swift
      Sources/LabanRenderer/VectorGlyphShaders.metal` shows no new stored
      property added to `SlugGlyphGPUInstance`/`SlugGlyphInstance` or
      `SlugGlyphGPUUniforms`/`SlugGlyphUniforms` (struct sizes stay 64B/96B).
- [ ] `git grep -n "spinnerMotionActive" Sources/LabanCore/TerminalIdlePolicy.swift`
      — hits in both `displayLinkShouldRun` and
      `preferredDisplayLinkFramesPerSecond`, in the same precedence tier as
      `glyphEffectAnimating`.
- [ ] `git grep -n "case spinnerMotion" Sources/LabanApp/TerminalBitmapView.swift`
      — exactly one hit in `FrameWakeSource`.
- [ ] `swift test --filter SpinnerMotionDetector` — 0 failures.
- [ ] `swift test --filter TerminalIdlePolicy` — 0 failures, including an
      explicit park-on-decay case for `spinnerMotionActive`.
- [ ] `swift test --filter SlugWeightCoreTextParity` — 0 failures (confirms
      the struct-untouched claim above did not perturb existing rendering).
- [ ] `swift test --filter Slug` — 0 failures.
- [ ] With `LabanSpinnerMotionSmoothingEnabled` unset (default), the M3
      scenario fixture's pixel probes are byte-identical to its recorded
      no-smoothing baseline.
- [ ] With the setting enabled, the M3 scenario fixture's mid-tick pixel
      probe is neither equal to the pre-tick nor the post-tick color
      (proves real interpolation, not a coincidental match).
- [ ] `git grep -n "spinner-motion" Sources/LabanControl/ControlRouteCatalog.swift`
      — hits.
- [ ] `git grep -n "spinner-motion-smoothing.scenario.json" scripts/test-e2e`
      — hits (fixture is actually wired into CI, not merely present on disk).
- [ ] `git grep -n "spinnerMotion" docs/product/spec.md` — hits.
- [ ] `setSpinnerMotionSmoothingEnabled`'s response body contains the
      resulting effective enabled value (not merely `{"ok": true}`) —
      confirmed by reading `Sources/LabanDebug/DebugWindowActions.swift`.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

_(empty)_

## Validation and Acceptance

1. `scripts/check` passes; the full swift test suite passes.
2. With the setting enabled, a program that repaints a same-character,
   color-changing spinner in place (the M3 fixture, or a real one such as
   Claude Code's own status line) shows a continuous color ripple; with the
   setting disabled (default) or `reduceMotion` on, output is pixel-identical
   to the pre-plan tree.
3. The M3 scenario fixture proves real interpolation occurred (mid-tick
   probe strictly between the two real endpoint colors), not merely a faster
   identical-content redraw.
4. After spinner activity stops, the display link parks:
   `idle-counters.jsonl` records zero `advanceFrames` over a subsequent 5s
   idle window.
5. The M3 scenario fixture fails on the pre-plan tree (the new debug action
   and `/debug/state` block do not exist) and passes after, and is actually
   invoked by `scripts/test-e2e` in CI, not merely present under `fixtures/`.
6. Review Gate passes with a fresh review agent (max 3 review-fix loops per
   `PLANS.md`, then escalate to a human).

## Idempotence and Recovery

Every milestone is independently revertible (`git revert` of its changeset).
M0 alone produces no visual change, so a partial tree (M0 without M1/M2) is
safe to leave in. The feature is default-off; recovery from any runtime
misbehavior is unsetting `LabanSpinnerMotionSmoothingEnabled` (or never
having set it). M2 is explicitly allowed to be built, evaluated, and then
left disabled/unshipped without that being a plan failure.

## Interfaces and Dependencies

End-state interfaces that must exist:

- `Sources/LabanCore/SpinnerMotionDetector.swift`: pure type exposing
  `isActive`, `estimatedCadenceSeconds`, `anchorRow`, `columnRange`, fed by
  `TerminalSurfaceController.freshnessFromCellDiff` classifications.
- `TerminalIdlePolicy.displayLinkShouldRun(...)` /
  `preferredDisplayLinkFramesPerSecond(...)`: additional
  `spinnerMotionActive: Bool` input (default `false`), same precedence tier
  as `glyphEffectAnimating`.
- `FrameWakeSource.spinnerMotion`; `"spinnerMotion"` reason rung in
  `displayLinkPolicyState`.
- Effect kinds 3 (`crossfadeIn`) and 4 (`crossfadeOut`) in
  `SlugGlyphGPUInstance.effectKind` / `SlugGlyphInstance.effectKind` and
  their Metal evaluation in `slugGlyphEvaluateEffect`: ease `color.a` only,
  `dilation` untouched, duration threaded per-instance from
  `SpinnerMotionDetector.estimatedCadenceSeconds` (clamped 0.04-0.6s).
- `Sources/LabanCore/SpinnerMotionSmoothingSettings.swift`: `enabled`
  (UserDefaults `LabanSpinnerMotionSmoothingEnabled` + environment override
  `LABAN_SPINNER_MOTION_SMOOTHING_ENABLED`, default `false`).
- Debug action `setSpinnerMotionSmoothingEnabled` (echoes effective
  resulting state); `GET /debug/spinner-motion` resettable counters;
  `spinnerMotion` block in `/debug/state`.
- New scenario fixture `fixtures/spinner-motion-smoothing.scenario.json`,
  wired into `scripts/test-e2e`.
