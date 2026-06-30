# Renderer session history (mined from prior Claude sessions)

A consolidated map of the substantial vector-glyph / Metal-renderer / scroll-perf
work done across earlier sessions, so future work (and Codex executing the Slug
plan) inherits the context instead of rediscovering it. Built by mining
`~/.claude/projects/-Users-rrj-wrk-laban/*.jsonl` (151 sessions, ranked by
renderer relevance). Sessions are named by their short id.

Honesty note: three sessions below have deep prose summaries (mined by subagents);
the rest are reconstructed from their in-session reason-style commit messages,
which in this repo are themselves dense summaries of *why* each change exists.
Commit SHAs are as recorded in-transcript and may be on feature branches.

## The throughline

The renderer's hard-won property is **120 Hz scroll with no drawable-wait
stall**, reached by separating three concerns that earlier bugs kept entangling:
1. **Scroll motion** — sub-cell pixel-smooth via a PD controller; libghostty
   stays on whole rows, the UI shows fractional `contentYOffset`.
2. **Present** — decoupled from content via a self-presenting `CAMetalDisplayLink`
   (ADR 0026), which removed the per-frame `nextDrawable()` "half-rate basin".
3. **Idle** — the display link parks when quiescent for ~zero CPU, but every
   defer/publish path must wake itself or frames hang (the bug class this current
   session fixed for startup/tab-switch).

## Session 0ddefe71 — render-stall: Claude progress bars freeze until scroll

Not vector-renderer work; a render-stall episode, but the most reusable one.
- **Symptom:** a Claude Code progress bar freezes mid-animation; the terminal
  stays static until the user scrolls.
- **Root cause:** Claude wraps every progress tick in `ESC[?2026h … ?2026l`
  (synchronized output). Laban defers rendering while sync-output is active. The
  150 ms hold / 1.0 s watchdog only fire if `advanceFrame` keeps being called —
  but if the display link parks (blur/occlusion, or `terminalDirty` flips false)
  while a sync-deferred frame is held, nothing re-ticks, so the frame stays
  unpainted until an external wake.
- **Fix:** `SynchronizedOutputDecision` returns a bounded `wakeAfter` on the
  defer path; `advanceFrame` schedules that re-wake. Stall capped at ~1.0 s worst
  case, normally re-woken within the 150 ms hold.
- **Lesson (durable):** any defer path that can outlive the display link's run
  state needs a bounded SELF-wake, not just a watchdog. `TerminalIdlePolicy`
  and `TerminalRenderGate` must agree on who owns the next tick. Use the render
  journal (`LabanRenderJournalEnabled`) for visibility/idle-loop bugs.
- Commits: `36a0107` dirty output must not inherit idle pacing; `94cef65` a
  quiescent focused terminal must not tick the link; `284a701` a parked frame
  loop needs every state change to announce itself; `2577c4b` a sync-output
  defer must re-wake itself so a parked link still reaches the frame.

## Session d875dd18 — pixel-smooth scroll + the scrollbench harness (largest)

- **Work:** built `scrollbench` (ScreenCaptureKit on-glass harness injecting
  constant-velocity scroll, measuring real pixel displacement; Laban vs Chrome on
  identical content). Diagnosed mid-scroll jank in the shipped pixel-smooth mode.
- **Architecture:** `targetScrollRows` (Double desired) → PD controller animates
  `displayedScrollRows` (Double) → `appliedScrollRows` (Int to libghostty); the
  fractional remainder is a pixel shift in the renderer. Precise trackpad deltas
  bypass the smoothing (finger maps directly); momentum goes through the
  controller.
- **The jank bug:** the settle-to-whole-row quiescence timer re-armed on every
  scroll event, so under a slow/resting finger it fired *mid-gesture* and snapped
  to a quantized row. Fix: arm the settle timer only when the input stream is
  inactive (finger lifted). Lesson: settle/fallback timers must gate on input
  PHASE, not time-since-last-event.
- **Half-rate basin (key perf find):** a render per wheel event, or a missed
  catch-up present, lets a ProMotion panel infer a lower rate and lock drawable
  recycling to half. Fixes: pace presents, one catch-up present the moment a
  drawable lands, prefetch the carried drawable's successor.
- Commits: `0237d14` track finger sub-cell, quantize only at rest; `0aecba7`
  resting-finger settle turns smooth into jank; `2443489` escape half-rate basin
  with one catch-up present; `6b6e70f` carried drawable must prefetch successor;
  `290e7c1` a render per wheel event halves a 120 Hz panel; `724eead` judging
  smoothness needs on-glass measurement; `81860e9` dt floor on the resampler.

## Session 48ebfaf1 — vector-renderer PLAN correction pass (pre-implementation)

Planning, not code — a corrective pass over the original vector-glyph ExecPlan +
ADR 0022 before implementation. Decisions that still bind:
- **Slug is NOT patent-encumbered** — dropped the stale "encumbered until ~2035"
  premise; treat Slug shaders as prior art. (This session's correction is *why*
  the current Slug plan could proceed.)
- **Fallback cascade is layered:** no Metal device → software; Metal present but
  vector pipeline/resource compile fails → classic raster atlas; per-glyph
  fallback (color emoji, ZWJ, missing outlines) is a separate concern from device
  absence.
- **`RendererSelection` lives in `LabanApp`** but `HeadlessDebugRuntime` needs it
  → a shared renderer factory must move lower (LabanCore/shared target). Same
  applies to the Slug backend.
- **Cache keys** must distinguish vector vs fallback glyphs and style variants
  (fake bold/italic), keeping distinct keys even when style extraction fails.
- **Perf gate set here:** `scripts/analyze-metal-trace --record 10 --attach
  Laban` on a 4K static-ASCII screen → vector encode < 0.5 ms p50.
- **Lesson:** run a corrective planning pass against the actual source tree
  before a big renderer project; plans drift from code fast. (This is exactly
  what Codex's `14c24dd` pass did for the Slug plan.)

## Sessions reconstructed from commits only

- **497f943d — partial-damage GPU renderer + render-journal forensics.**
  `7137f91` partial damage must scissor the persistent glyph grid to each dirty
  run, not their union; `238beaf` a partial GPU-cell frame must leave clean rows
  untouched; `4b66db4` a command buffer completing in error can leave a
  half-painted target; `1cab3cd` GPU freezes need automatic render-journal dumps;
  `44ad941` journals need enough state to explain starvation; `36a0107` dirty
  output must not inherit idle pacing.
- **75ffda5a — per-tick AppKit tax during scroll.** `782474c` scrolling must not
  re-solve window Auto Layout every display-link tick; `976cb7b` the scroll pill
  must not pay NSTextField redraw + window-layout taxes per tick; `2e1377d` a
  model-mutation wake must invalidate before it advances or the woken frame
  paints nothing; `58837c1` journal metadata signature is wasted work per tick.
- **5482c85e — vector scroll jank is drawable-blocking.** `ffdddaa` vector scroll
  jank is drawable-blocking, not render cost; `9d9e40a` smooth scroll must pace
  presents to hold 120 Hz; `15e86d4` frame-stats JSON must survive per-config
  capture. (This is the direct precursor to ADR 0026's decoupled present link.)
- **b1ece399 — mask-atlas churn under scroll.** `3deb4fe` churning scroll phases
  need a bounded mask atlas; `81b22b7` steady scroll should not recompute glyph
  geometry each frame.
- **f4b42956 — mostly NOT renderer** (agent-notification/title-timing work).

## Hard-won lessons (the non-obvious traps, symptom → wrong guess → real cause → rule)

Mined specifically for the *surprising / wrong-the-first-time* discoveries. Each
cost real debugging; the "wrong assumption" column is the trap to not re-enter.

**Cadence / present / drawable (the 120 Hz machinery):**
- **Per-event wheel rendering halves the panel.** Smooth synthetic scroll hit
  120 fps but real flicks stuttered at 60. Wrong guess: GPU/display link too slow.
  Cause: each `scrollWheel` did a synchronous full render, sampling an irregular
  3–12 ms event stream instead of vsync. Rule: drive frames from the display link;
  wheel events only mutate state. Render samples the model at vsync, never chases
  input.
- **The half-rate basin is a VRR inference trap, not GPU overload.** After one
  missed frame, scrolling locked to 60 Hz with GPU headroom to spare; catch-up
  wakes couldn't break out. Wrong guess: `nextDrawable` latency / pool exhaustion.
  Cause: ProMotion VRR follows the *observed* present cadence; with no declared
  cadence it inferred 60 Hz from the miss. Rule: `present(drawable,
  afterMinimumDuration: 1/120)` for scroll frames to *declare* the rate.
- **A consumed drawable must prefetch its successor.** Even after pacing, 120 Hz
  wasn't self-sustaining — ticks alternated hit/miss. Cause: consuming the parked
  drawable didn't request the next, so the following tick found the pool empty
  (carry ticks never request, request ticks never have one → stable 60 Hz). Rule:
  on every present, immediately post the next async acquire; carry a late drawable
  forward in `pendingDrawable`, don't drop it (dropping poisons a pool slot).
- **Vector scroll jank was drawable-blocking, not shader cost.** The vector
  renderer felt less smooth; first theory "the vector shader is expensive" was
  wrong. Cause: a blocking `layer.nextDrawable()` in `render()` stalled the main
  thread p99 ~10 ms / max ~51 ms. Rule: give every self-presenting renderer the
  non-blocking `MetalDrawableScheduler` (drop-don't-block + miss-recovery wake)
  BEFORE optimizing its pipeline. Use `lastRequestLatencyMs` to tell the classes
  apart: ~16.7 ms = recycling locked at half rate; ~9–12 ms = GPU frame is the
  bottleneck.

**Partial damage on a persistent target (every pass must agree):**
- **A spinner made the whole screen shimmer.** Wrong guess: persistent-target
  optimization broken. Cause: the *background* pass was scissored to dirty rows
  but the *glyph* pass still drew the entire grid, so clean rows' AA edges
  re-blended over an uncleared background and accumulated. Rule: if ONE pass is
  damage-scoped, ALL passes must be — and scissor to each contiguous dirty *run*,
  not the bounding union (clean rows between two dirty blocks flicker otherwise).
- **A command buffer completing in `.error` leaves a half-painted target.**
  Partial damage then composites over garbage → persistent corruption. Rule:
  record completion status off-main; after any `.error`, force the next frame to
  full `.clear` before trusting damage again.

**Idle / wake ordering (parked link + dirty state = frozen screen):**
- **"Stalls that only clear on scroll" = the link parked while dirty.** Wrong
  guess: drawable timeout / GPU / stale glyph cache. Cause: `terminalOutputActive`
  was gated on `windowVisibleToUser`; on blur/occlusion the link parked while
  `terminalDirty` stayed true, and a scroll wake un-parked it to flush. Rule:
  separate "has new output" from "link should run"; every output-affecting state
  change must announce itself so the link can unpark and drain.
- **Synchronized-output defer must re-wake the link itself.** Claude progress
  bars (`?2026h/l`) froze until scroll: the defer held a frame but the idle policy
  had already parked the link, so the settle-wake never reached `advanceFrame`.
  Rule: any defer that *holds* a frame must schedule its own wake; a parked link
  is the default quiescent state, not an edge case.
- **A model-mutation wake must invalidate BEFORE it advances.** Tab open/close/
  select coalesced into an `advanceFrame()` without setting `renderInvalidated`
  first; those mutations bump no dirty generation, so the gated render
  early-returned and painted stale state — a wake that never repaints. Rule: the
  first tick after a model mutation must carry an invalidation flag.

**Cost hides where you don't look:**
- **Scroll's worst CPU was the lines-back PILL, not the GPU.** `setStringValue:` +
  `systemLayoutSizeFittingSize` on an `NSTextField` ran every tick, dragging a
  window-wide Auto Layout pass into each CA commit (~10% of scroll CPU vs the
  renderer's ~12%). Rule: cosmetic overlays must be out of Auto Layout
  (`CATextLayer`, cached size, set text only on change) and rate-limited to their
  design rate; animation state mutates cached output in place, never bypasses the
  memo (a pulsing sidebar dot forced full sidebar rebuilds at 120 fps).
- **Full-frame GPU builds can be CPU-bound on atlas lookups.** Re-hashing atlas
  entries per cell per frame dominated GPU work. Rule: cache atlas lookups within
  a single frame build, even on GPU paths.

**Instrumentation is not free, and can BE the bug:**
- **A "regression" was a stale armed debug env var.** Smooth for a day, then all
  tabs lagged — not a code change: `LABAN_SCROLL_DEBUG`/render-journal flags
  survive relaunches and sat in the PTY-reader path multiplying per-frame load.
  Rule: verify a suspected regression against a fully clean process (no armed
  debug surfaces) before profiling code. (Mirrors the build-stamp rule.)
- **Diagnostics traced intent, masking an inverted-sign bug.** A two-row
  scroll sawtooth persisted because `contentYOffset` had the wrong sign, but the
  trace logged the *intended* position so the state looked correct while the glass
  was wrong. Rule: test rendering invariants on the actual framebuffer, not only
  the state model.
- **Render-journal forensics need the *why*, parsed by collapsing runs.** Raw
  frame lists hide the stall; the signal is the distribution of `wakeSource` /
  `displayLink.reason`. Rule: each entry records decision inputs (modelChanged,
  metadata signature, visibility/occlusion, drop-type); parse in a sandbox and
  collapse consecutive identical `(terminalDirty, snapshotDirty, visibleTextHash,
  wakeSource)` frames — look for `parked` while dirty.

**Test at live scale, with closed-form math:**
- **Headless fixtures miss Metal-scale and address-aliasing bugs.** The 4 KB
  `setVertexBytes` inline limit is only exceeded at live terminal scale, and
  address-keyed caches only alias when real `CTFont`s recycle at varying sizes.
  Rule: replay real PTY output through the live Metal path; buffer-back any batch
  >4 KB; key glyph caches on visual identity. The regression gate verifies the
  *mechanism* headlessly; the *result* (≈0% jank) needs `profile-scroll-renderers`
  on real ProMotion hardware — both are required.
- **A naive Euler scroll follower diverges; use closed-form.** High-stiffness PD
  resamplers "exploded positions." Rule: prefer an exact critically-damped
  closed-form integrator for timing-critical followers; add tests that
  intentionally trap divergence.

## Cross-session durable lessons (now also in AGENTS.md Hard Rules)

- Cache on visual font identity, never `ObjectIdentifier(font)` (address aliasing
  → mixed glyph sizes).
- The decoupled present link's "rendered but not shown" failure class: honor
  `waitForFrameCompletion` on every present path; don't park with an unpresented
  frame; defer/sync paths must self-wake.
- Measure on-glass / with the render journal before theorizing a visual artifact.
- Settle/fallback timers gate on input phase, not elapsed time.
- Pace presents and prefetch the next drawable to stay out of the half-rate basin.
