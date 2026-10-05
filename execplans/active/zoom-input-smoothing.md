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
- [ ] M1 present-side trace + `/zoom/trace` + `ZoomTraceSummary` tests.
- [ ] M1 baseline trace on the installed app: wheel and trackpad, LG and built-in.
- [ ] M2 spring + wheel coalescing + tuned wheel step.
- [ ] M2 after-trace on both panels, both devices; compare with baseline.

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
