# Even Cmd+scroll zoom on 60 Hz displays and notched wheels

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

Holding Cmd and scrolling zooms the terminal font. On a 120 Hz built-in
ProMotion panel this looks smooth. On a 60 Hz external display (measured on an
LG UltraFine 4K at 1920x1080@2x, 60 Hz) a trackpad Cmd+scroll judders, and a
notched mouse wheel (measured on a Contour RollerMouse Pro) is much worse: each
notch is a 7 % jump with a ~20 ms main-thread hitch about 100 ms later, and a
fast spin flies from ~12 pt to the 30 pt maximum in ~220 ms with uneven 3-15 %
per-frame steps.

After this change, Cmd+scroll zoom advances by even per-frame steps on both
panels, notched wheels glide instead of jumping, and a continuous run of notches
pays for one font rebuild at the end instead of one per notch. A new
`/zoom/trace` debug endpoint records exactly what reached the screen at each
vsync, so the improvement is measured, not eyeballed.

Pinch-to-zoom (`magnify(with:)`) is out of scope: it shares the per-event
mechanism and probably the same 60 Hz judder, but was not measured. It can opt
into the same smoothing later with one call-site change once traced.

## Context and Orientation

Terms used here:

- **Zoom gesture**: a run of zoom input. `TerminalBitmapView` (in
  `Sources/LabanApp/TerminalBitmapView.swift`) tracks it with
  `zoomGestureBasePointSize` (font size at gesture start, nil when idle) and
  `zoomGestureAccumulatedMagnification`.
- **Presentation scale**: during a gesture the glyph atlas stays at the base
  size and the renderer scales the whole surface in its vertex projection
  (`setGestureZoomPresentationScale` -> `GestureZoomRenderable.setGestureZoom`).
  Nothing is re-rasterized and the grid is not reflowed while the scale moves.
- **Commit / bake**: when the gesture goes quiet, `commitZoomGestureEnd`
  rebuilds fonts at the final size, reflows the grid (SIGWINCH to the shell),
  persists the size, and resets the presentation scale to 1. Measured cost on
  the M2 Max: 20-22 ms on the main thread.
- **Present link**: the Slug renderer (`Sources/LabanRenderer/SlugGlyphRenderer.swift`,
  the default renderer) renders into an offscreen target, publishes it
  (`publishLatestTarget`, from the GPU completion handler), and a
  `CAMetalDisplayLink` (`Sources/LabanRenderer/VectorPresentDisplayLink.swift`)
  blits the latest published target to the screen once per vsync
  (`presentLatestTarget`). See ADR 0026.
- **Display-link tick**: separate main-thread link driving
  `TerminalBitmapView.advanceFrame`, which is where smooth scrolling integrates
  its critically damped spring toward `targetScrollRows`.

Today's Cmd+scroll path (`handleZoomScroll`, around `TerminalBitmapView.swift:6556`):

- Precise (trackpad) events with a phase envelope map to began/changed/ended
  and call `applyZoomMagnification`, which sets the presentation scale
  immediately per event.
- Phase-less precise streams are coalesced into one gesture with a 0.12 s quiet
  timer.
- Discrete (notched wheel) events: each event is its own began+ended with a
  fixed `zoomScrollDiscreteStep` (0.07) regardless of `deltaY`, and the ended
  schedules the 0.1 s debounced commit.

Measured root causes (2026-10-05, 5 ms polling of `/zoom/state`):

- Trackpad on the 60 Hz display delivers ~60 events/s with 10-24 ms jitter that
  beats against the 60 Hz vsync: 6-31 % of frames during steady motion showed
  no zoom change, others a double step. On the 120 Hz panel events arrive at
  ~120/s, one per frame.
- Notched wheel: notches 160-400 ms apart each crossed the 0.1 s debounce, so
  34 commits happened in 25 s; each blocked the main thread 20-22 ms. Fast
  spins delivered events every 5-12 ms at a fixed 7 % each.

An offline replay of the recorded trackpad event times through a simulated
60 Hz vsync (scratch script, not checked in) compared smoothing filters on
"near-still frames" (step < 25 % of mean) and lag: direct 10.7 % / 0 ms;
critically damped spring with 1/omega = 8 ms 4.3 % / < 1 frame; fixed-delay
resampling 4.4-5.2 % / 11-27 ms. The spring wins and matches the existing
smooth-scroll machinery.

## Plan of Work

### M1: present-side zoom trace

Add a measurement seam before changing behavior.

- `SlugGlyphRenderer`: an opt-in zoom present trace. While enabled, each frame
  captures its visual point size (`fontAtlas.pointSize * gestureZoom`) at encode
  time and carries it through `publishLatestTarget`. Each present-link callback
  records `(time, visualPointSize of what is on screen, fresh)`; `fresh` is
  false when the callback re-shows the previous frame. Ring-bounded, own lock,
  disabled by default (a lock and a branch per frame when off).
- `GestureZoomRenderable` gains `setZoomPresentTraceEnabled(_:)` and
  `drainZoomPresentTrace()` with no-op defaults.
- `TerminalBitmapView` records zoom inputs (timestamp, source, deltaY,
  scrollingDeltaY, precise, phase) and commits (start time, duration ms) while
  armed.
- Pure value type `ZoomTraceSummary` (GPU-free, unit-tested) splits inputs into
  bursts (gap > 0.4 s) and reports per burst: vsyncs, still vsyncs (visual size
  unchanged, or step < 25 % of the burst's median non-zero step), p50 and max
  per-vsync step percent, and commit count and max duration.
- `GET /zoom/trace[?reset=1]` on the scroll debug server returns raw samples
  plus summary; the first call arms tracing.

### M2: smooth Cmd+scroll zoom

- Pure value type `ZoomPresentationSpring` (closed-form critically damped spring
  in log-scale space, same math as smooth scroll in `advanceFrame`).
- `applyZoomMagnification` gains a smoothing parameter. Cmd+scroll passes
  `.trackpad` (omega 110 rad/s, about 9 ms) or `.wheel` (omega 40 rad/s, about
  120 ms to settle); pinch passes `.none` and keeps today's behavior and tests.
  With smoothing, input only retargets the spring; `advanceFrame` advances it
  and applies the presentation scale; the display-link policy treats an
  unsettled spring like a scroll animation so the link runs at panel rate.
- Notched wheel: coalesce a run of notches into one gesture (began on the first
  notch, changed afterwards) with a 0.35 s quiet timer, so typical 160-400 ms
  notch spacing costs one commit. Step size and speed cap are set from the M1
  trace's recorded `deltaY` values (see Decision Log once measured).
- Commit snaps the spring to rest, so the bake never lands mid-glide.

## Progress

- [x] (2026-10-05) Baseline measured with 5 ms `/zoom/state` polling on both
  panels (numbers in Context).
- [x] (2026-10-05) M1 present-side trace + `/zoom/trace` + `ZoomTraceSummary`
  tests (45a8fb46). Extended with GPU time, link policy, on-glass times and
  display-link target times (db48ac3f, 86d55636, and the commit after it).
- [x] (2026-10-05) M1 baseline trace on the installed app, wheel and
  trackpad, LG and built-in.
- [x] (2026-10-05) GPU zoom tests un-skipped (76085656) and their font-size
  leak fixed (ea6baa39).
- [x] (2026-10-05) M2: display link kept running for the whole gesture
  (bdccaefc), trackpad spring (f430a9db), wheel coalescing + speed cap
  (9466ce0f), re-touch snap-back fix (8c7be854).
- [x] (2026-10-05) M2 after-trace on the LG: wheel max per-vsync step 7-8 % ->
  1.7-3 %, fast spins 18-87 % -> 4-10 %, commits 44 -> 23.
- [ ] Present pacing on the 60 Hz LG: re-measure a fresh Laban launch with the
  LG attached against the minimal repro; the system-side explanation is ruled
  out (see Surprises).
- [ ] Present link degraded to ~60/s after an external-display unplug:
  reproduce by unplugging, then find why the rebuilt link keeps the wrong
  cadence.
- [ ] After-trace of real trackpad/wheel zoom on the built-in panel.

## Validation and Acceptance

- `swift test --filter ZoomTraceSummaryTests` and
  `swift test --filter ZoomPresentationSpringTests` pass.
- `swift test --filter ContinuousZoomTests` passes (pinch behavior unchanged;
  Cmd+scroll tests advance the spring through a debug seam).
- On the installed app, with the window on the 60 Hz display:
  `curl -s 'localhost:8787/zoom/trace?reset=1'`, Cmd+scroll for ~20 s, then
  `curl -s localhost:8787/zoom/trace`. Acceptance: trackpad steady bursts show
  still-vsync share well below the M1 baseline; a wheel run of notches shows one
  commit per run rather than per notch, and no per-vsync step above ~3 %.

## Idempotence and Recovery

Tracing is off unless armed and resets on demand; rerunning a trace is safe.
All behavior changes are confined to the Cmd+scroll path; reverting the M2
commit restores today's behavior with the trace still available.

## Surprises & Discoveries

- Observation: trackpad re-touch mid-zoom (`.ended`, `.mayBegin`, `.began`
  within ~100 ms) restarted the session: `.mayBegin` cancelled the pending
  commit, so `.began` no longer saw a session in flight and reset the scale
  over the uncommitted atlas. One frame showed the gesture-start size.
  Evidence: LG trace, sizes 10.26 -> 8.00 -> 8.35 pt with one-direction input;
  regression test reproduced 22.1 -> 14.05 pt. Fixed in 8c7be854.
- Observation: during continuous fresh frames the Slug present link fires on
  two of every three vsyncs (16.7/33 ms alternation, ~40-45 fresh frames/s on
  the 60 Hz LG). Evidence (synthetic 120 Hz `/zoom/pinch` stream, 2026-10-05):
  link policy `zoom` (running), GPU 0.5 ms p50 / 3.7 ms max, frames waiting.
  Every frame lands exactly on `targetPresentationTimestamp`, which is 49.6 ms
  (three vsyncs) after the callback whatever `preferredFrameLatency` is (1, 2
  and 3 measured) and whether the rate range is 30-120 or pinned to 60. A
  drawable is therefore busy for ~4 vsyncs (3 lead + 1 on glass); with
  `maximumDrawableCount` 3 that caps fresh presents at 3 per 4 vsyncs, and at
  2 drawables throughput halves to ~22/s, confirming the pool is the limit.
  Misses after three consecutive fresh presents: 47 % LG before this plan,
  21 % LG after, 32 % built-in; after a repeated frame 4-5 %. This is not
  zoom specific: any continuous animation (smooth scroll) hits it.
- Observation (correction, 2026-10-05): the drawable-pool explanation above is
  wrong. A minimal app (https://github.com/rrva/metal-display-link-pacing)
  with the same 3-refresh windowed lead and 3 drawables sustains 59-60 fps on
  the LG and 113-119 fps on the built-in panel, including Laban's shape
  (offscreen producer, blit on a second queue, present thread, sRGB,
  screen-sized drawable), fullscreen, Metal capture enabled (`install-app`
  bundles set `MetalCaptureEnabled`), unpresented drawables, per-frame
  `isPaused` reads, per-tick `preferredFrameRateRange` writes, and per-frame
  CA commits. A `sample` of Laban showed the present thread 97 % idle in
  mach_msg: no lock contention or CPU cost. The LG 40-45 fps cause remains
  unexplained and must be re-measured with the LG attached.
- Observation: after the external display is unplugged, Laban's rebuilt present
  link keeps calling back at ~62/s on the 120 Hz built-in panel while the main
  CADisplayLink ticks at 120; neither `/config/present-latency` rebuilds nor
  rate pinning recover it. A fresh launch on the same panel gets 120-121
  callbacks/s. Evidence: present-stats rebuilds 9, stallRepairs 1 before the
  restart; 0 after. Separate display-change bug, not zoom specific.
- Observation: the GPU zoom tests in `ContinuousZoomTests` had been skipping
  since renderer swaps became asynchronous; once running, several persisted
  fractional font sizes into the shared xctest defaults domain and broke
  `FontSizeActionTests`. Evidence: 24.08 pt = 14 x (1 + 120 x 0.006).

## Decision Log

- Decision: smooth only Cmd+scroll; pinch keeps direct per-event scale.
  Rationale: pinch was not measured and its tests assert visual == target per
  event. Date/Author: 2026-10-05, Claude.
- Decision: trackpad omega 70 rad/s (2/omega = 29 ms lag), wheel omega 40.
  Rationale: against a 60 Hz event stream beating on 60 Hz vsync, omega 110
  leaves a 2.7x per-frame step range, 70 about 1.7x, 60 1.5x at 33 ms lag;
  smooth scroll already runs at omega 50. Date/Author: 2026-10-05, Claude.
- Decision: cap wheel zoom by notch spacing (full 7 % step only when 35 ms or
  more after the previous event) instead of scaling by deltaY. Rationale: the
  RollerMouse sends deltaY 0.1 per slow notch but 4.5-9.5 per event during
  spins, with events 5-12 ms apart; a deltaY-proportional step would make
  spins faster, not slower. Date/Author: 2026-10-05, Claude.

