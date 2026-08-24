# Stop A Failing Vector Frame From Pinning The Main Thread

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban's terminal window sometimes stops repainting and becomes sluggish: after
the app has been idle for a while, clicking a background tab does nothing for
several seconds, and "warming up" every tab makes switching feel fast again.
The window is not deadlocked — it is *starved*. The main thread is spending
almost all of its time inside a render loop that retries a frame the GPU
backend keeps refusing, and every mouse click has to queue behind that loop.

After this change, a render that the backend refuses is classified (why did it
fail?) and either parked or retried at a bounded rate, so the main thread stays
free to service input. A user can leave Laban idle for minutes, click a
background tab, and see it activate immediately.

### Terms used here

- **Backend** — the object that actually draws a frame with Metal.  Three ship
  today: `MetalRenderer`, `SlugGlyphRenderer`, and `VectorGlyphRenderer`, all
  in `Sources/LabanRenderer/`. Which one runs is a user setting; existing
  installs default to `VectorGlyphRenderer` (`vectorGlyph`).
- **Display link** — a timer driven by the display's refresh. Laban *parks*
  (pauses) it when the terminal is idle so an idle window costs no CPU
  (ADR 0018). While parked, frames only happen when something explicitly asks
  for one.
- **Render retry** — `TerminalBitmapView.scheduleRenderRetry()` in
  `Sources/LabanApp/TerminalBitmapView.swift`. It posts one
  `DispatchQueue.main.async` block that calls `advanceFrame(wake: .renderRetry)`.
  It exists because with the display link parked, marking the screen dirty is
  not enough — nothing would repaint until an unrelated wake arrived.
- **Backpressure** — the GPU has not finished the previous frame yet. Not an
  error; the right response is to wait, not to retry in a tight loop.

## The bug, with evidence

Two render-journal dumps taken during a live reproduction on 2026-08-24 are the
primary evidence (`~/Library/Logs/Laban/render-journal/2026-08-24T112652807Z`
and `.../2026-08-24T112701574Z`, process 47805, renderer `vectorGlyph`).

The second dump ends with **291 consecutive journal entries for the same frame
number (6394)**, every one of them `event: renderFailed`,
`reason: backendRenderReturnedFalse`, spread over five seconds at roughly 57
attempts per second:

    11:26:55 n=57 rend=0 skip=0 fail=57 frames 6394..6394
    11:26:56 n=57 rend=0 skip=0 fail=57 frames 6394..6394
    11:26:57 n=58 rend=0 skip=0 fail=58 frames 6394..6394
    11:26:58 n=58 rend=0 skip=0 fail=58 frames 6394..6394
    11:26:59 n=57 rend=1 skip=0 fail=56 frames 6394..6394

57 attempts per second is ~17.5 ms per attempt, which matches the 16 ms
timeout in `MetalDrawableScheduler.beginFrame` (`Sources/LabanRenderer/
MetalDrawableScheduler.swift`): each attempt blocks the main thread on
`frameInFlight.wait(timeout: .now() + .milliseconds(16))`, fails, and posts an
immediate retry that blocks again. The main thread is unavailable ~16 ms out of
every 17 ms — which is why a tab click takes seconds to be serviced, and why
main-thread stall samples in `~/laban-watchdog/` show the main thread sitting in
`mach_msg` (a semaphore wait *is* a `mach_msg` trap) rather than in Laban code.

The loop should not have been possible. `TerminalBitmapView.advanceFrame`
already has an anti-amplification policy for exactly this: when the backend
reports a *backpressure* failure it consults
`TerminalRenderGate.backpressureInvalidationDecision(...)` and parks instead of
"sustaining a no-progress render loop". The policy never ran, because the
failure reason is read through a chain of concrete casts:

    let failureReason =
      (backend as? MetalRenderer)?.lastRenderFailureReason
      ?? (backend as? SlugGlyphRenderer)?.lastRenderFailureReason

`VectorGlyphRenderer` is not in that chain, and it never had a
`lastRenderFailureReason` property at all — so for the renderer that existing
installs actually run, `failureReason` is always `nil`, `isGPUBackpressure` is
always false, and every failure takes the "unknown failure" branch:
`renderInvalidated = true` plus an immediate, unpaced `scheduleRenderRetry()`.
The same cast chain appears a second time in `sampleGPUFreezeDetector`, so the
GPU-freeze detector is blind to vector failures too.

The cast chain is the root defect: a backend opts out of the host's render
policy simply by not being named in it, silently and at runtime.

## What changes

1. `RenderFailureReason.swift` gains a `RenderFailureReporting` protocol
   (`var lastRenderFailureReason: RenderFailureReason? { get }`). All three GPU
   backends adopt it. `TerminalBitmapView` reads the reason through the
   protocol in both places, so a future backend cannot silently opt out.
2. `VectorGlyphRenderer.render` records a reason at each of its `return false`
   paths (previous frame in flight, target textures unavailable, command buffer
   unavailable, content pass could not be encoded) and clears it on entry.
3. A failure that *keeps* failing stops being retried immediately. A new pure
   decision, `TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures:)`,
   gives the first two failures the existing next-main-loop-turn retry and
   drops everything after that to the idle display cadence (8 Hz). Even a
   failure class the backpressure policy does not park (a persistently
   unavailable target texture, say) then costs ~12% of the main thread instead
   of ~100%, and input stays responsive.

Item 1 alone fixes the observed five-second freeze: with a real
`.previousFrameInFlight` reason, the second consecutive failure satisfies
`backpressureInvalidationDecision`'s park condition and the loop ends after two
attempts instead of 291. Item 3 bounds the failure classes that legitimately do
retry.

## Non-goals

- The display-link park policy is unchanged. Parking on idle is correct
  (ADR 0018); the bug is what happens on a failed frame, not when to park.
- `VectorPresentDisplayLink` is unchanged. Its stall watchdog (commit
  `ff19178c`) handles a different failure — a present link bound to a dead
  vsync source — and does not address a render that never succeeds.
- The 139-entry burst of *successful* full-surface repaints at 11:26:02 in the
  first dump (link parked, nothing dirty, all woken by `renderRetry`) is a
  second, distinct no-progress loop. Its re-arming source is not established by
  the available evidence and is deliberately left out of this change; see
  `Surprises & Discoveries`.

## Progress

- [x] Read the two render-journal dumps and established the failure signature
      (291 identical `backendRenderReturnedFalse` entries, ~57/s, one frame).
- [x] Traced the cast chain in `TerminalBitmapView.advanceFrame` and
      `sampleGPUFreezeDetector` and confirmed `VectorGlyphRenderer` has no
      `lastRenderFailureReason`.
- [x] Added `RenderFailureReporting` and adopted it in all three GPU backends.
- [x] Recorded failure reasons at every `return false` in
      `VectorGlyphRenderer.render`.
- [x] Replaced both cast chains with the protocol lookup.
- [x] Added `renderFailureRetryDelay` and the consecutive-failure counter.
- [x] Added tests: a device-backed regression test that every refusal from a
      real `VectorGlyphRenderer` carries a reason and a rendered frame clears
      it (`Tests/LabanRendererTests/VectorRenderFailureReasonTests.swift`), a
      type-level check that every GPU backend conforms to
      `RenderFailureReporting`, and pure tests for the retry pacing
      (`Tests/LabanAppTests/TerminalRenderFailureRetryTests.swift`).
- [x] Confirmed red-green: with the `.previousFrameInFlight` assignment removed,
      `VectorRenderFailureReasonTests` fails with
      `XCTAssertEqual failed: ("nil") is not equal to
      ("Optional(...previousFrameInFlight)")`; with it, the suite passes.
- [x] Ran `swift build`, `./scripts/lint`, `./scripts/build-app`, the affected
      filters, and the whole `swift test` suite. Every bundle passes except two
      pre-existing `CJKFontSettingsTests` failures unrelated to this change; see
      `Surprises & Discoveries`.

## Decision Log

- Decision: read the failure reason through a protocol rather than adding
  `VectorGlyphRenderer` to the existing cast chain. Alternative considered:
  a one-line `?? (backend as? VectorGlyphRenderer)?.lastRenderFailureReason`.
  Rejected because it reproduces the defect for the next backend — the chain
  gives no signal when a backend is missing from it. The protocol makes the
  requirement explicit and lets a test assert every backend conforms.
- Decision: classify a failed `encode(...)` as `.fullRedrawProducedNoContent`
  rather than adding a new reason. It is the existing reason for "the content
  pass produced nothing", its retry behavior (retry, do not park) is what a
  missing translucent pipeline or a render encoder that could not be created
  needs, and the `gpuCellCommandFallbackPending` side effect it can trigger is
  unreachable on this path (`canRequestCellPayload` requires a `MetalRenderer`
  in `gpuDriven` mode, so a vector frame never carries a cell payload).
- Decision: pace the repeated-failure retry at the idle display-link floor
  (`TerminalIdlePolicy.idleDisplayLinkFramesPerSecond`, 8 Hz) rather than
  stopping it. Stopping risks a permanently stale window if the failure clears
  on its own with no other wake; 8 Hz keeps a repair path alive at a cost the
  main thread does not notice.
- Decision: keep the first two failures on the immediate retry. A single
  transient miss must still repaint on the next main-loop turn — that is the
  latency path for a keystroke that lands while the link is parked — and the
  observed loop needs only two attempts to be classified and parked.

## Surprises & Discoveries

- The first dump contains a second no-progress loop with the opposite shape:
  139 consecutive entries at 11:26:02–11:26:03, every one a *successful* full
  damage render (`event: rendered`, `damage: full`, `renderInvalidated: true`),
  all woken by `renderRetry`, with the display link parked, the terminal not
  dirty, nothing animating, and an unchanging `visibleTextHash`. Something
  re-invalidated and re-armed a retry after each successful frame at ~70 Hz.
  Static tracing did not identify the source: the per-frame invalidation sites
  inside `advanceFrame` are all hover-preview related and throttled to 10 Hz
  (`hoverPreviewSnapshotRetryDelay = 0.1`), and the only unthrottled
  `scheduleRenderRetry()` calls inside `advanceFrame` are in the failure
  branch, which these frames did not take. Reproducing it needs a journal entry
  that records *why* a retry was scheduled; that instrumentation does not exist
  yet.
- `MetalDrawableScheduler.beginFrame` blocks the *main thread* for up to 16 ms
  on every non-scroll frame that finds the pipeline busy. That is by design
  (non-scroll frames "never drop"), but it means the cost of a retry loop on
  this path is a blocked main thread, not merely wasted CPU.
- The GPU freeze detector reads the failure reason through the same cast chain,
  so it was blind to vector failures too. Fixing the lookup was not enough on its
  own: `GPURenderFreezeDetector.sample` also early-returned unless
  `sample.gpuDriven`, and only `MetalRenderer` in `gpuDriven` mode ever sets
  `effectiveRenderer == "gpuDriven"` — so the detector built to catch this exact
  no-progress loop was disabled for `classic`, `vectorGlyph`, and `slugGlyph`
  alike. Widened to "any GPU backend" in a follow-up commit; see
  `Follow-up: freeze-detector coverage` below.
- `swift test` reports two failures in `CJKFontSettingsTests`
  (`testDefaultPreferenceIsPingFangSC`, `testSetPresetClearsCustomPostScriptName`)
  that predate this change and are unrelated to it. They are a test-isolation
  bug: `CJKFontMetricsTests` calls `UserDefaults.standard.register(defaults:)`,
  whose registration domain is process-global, and `CJKFontSettingsTests` reads
  through a `UserDefaults(suiteName:)` that still falls back to it. The suite
  passes alone (`swift test --filter CJKFontSettingsTests` — 6/6) and fails only
  when run with its neighbour (`--filter CJKFont` — 13 tests, 2 failures). Left
  for a separate changeset; it has its own behavioral reason.
- The installed `~/Laban.app` used for the reproduction was built from
  `d89fb285` (2026-08-17) and predates `ff19178c`. That commit was the leading
  hypothesis before the journal was read; it is unrelated — it repairs a
  present link that never fires, whereas here the present link is irrelevant
  because `render()` never succeeds far enough to publish a target.

## Validation and Acceptance

Run from the repository root:

    swift build
    swift test --filter RenderFailureReasonTests
    swift test --filter TerminalRenderGateParkedFrameTests
    swift test --filter RendererSelectionRoutingTests

    swift test --filter VectorRenderFailureReasonTests
    swift test --filter TerminalRenderFailureRetryTests

Expected: all pass, zero failures. (`swift test` with no filter also surfaces
two pre-existing `CJKFontSettingsTests` failures; see
`Surprises & Discoveries`.)

Behavioral acceptance, in the running app:

1. `./scripts/install-app && scripts/restart-app`
2. `defaults write com.laban.LabanApp LabanRenderJournalEnabled -bool YES` and
   restart, then leave the app idle for several minutes with more than one tab
   open.
3. Click a background tab. It must activate immediately.
4. Dump the render journal from the app menu and inspect the newest directory
   under `~/Library/Logs/Laban/render-journal/`. Acceptance: no run of more
   than a handful of consecutive `backendRenderReturnedFalse` entries carrying
   the same `frame` number. Before this change the same reproduction produced
   291 of them across five seconds.

The pre-change failure is also directly visible in the archived dumps named
above, which remain the regression reference for this signature.

## Follow-up: freeze-detector coverage

`GPURenderFreezeDetector` exists to notice exactly the loop this plan fixes: a
streak of frames that have visible work pending, do not render, and fail with a
no-progress reason. It never fired during the reproduction because
`TerminalBitmapView.sampleGPUFreezeDetector` gated it on

    rendererStatus.effectiveRenderer == RendererMode.gpuDriven.rawValue

and only `MetalRenderer` in `gpuDriven` mode ever reports that string. The
`classic`, `vectorGlyph`, and `slugGlyph` backends were all outside the gate.
The gate came from the detector's origin (`execplans/active/`
`gpu-render-freeze-journal-diagnostic.md`, which was written for a freeze
specific to the opt-in `gpuDriven` renderer), but the loop it detects belongs to
the host's retry policy, not to any one glyph path.

The gate is now `backend is RenderFailureReporting` — exactly the set of
backends that supply the two pieces of evidence the detector consumes (a
render-failure reason and a GPU frame-completion count). `SoftwareBackend`
renders synchronously, never reports those reasons, and stays outside the gate;
`RenderFailureReasonTests` asserts both halves of that so the gate cannot drift.
`Sample.gpuDriven` was renamed to `Sample.gpuBackend` to stop the field's name
implying the narrower meaning.

This ordering matters: widening the gate before the failure reasons existed
would have achieved nothing, because `isNoProgressFailure(nil)` is `false`, so a
vector failure would have reset the streak on every sample.

## Follow-up: the journal could not see presentation

Three fixes later the reported symptom — slow tab switching — was still present,
and the evidence said the render path was innocent:

- Zero main-thread stalls in 37 minutes of use (`~/laban-watchdog/`), against 12
  in a 20-minute window before the fixes.
- Zero `Hangs` and zero `hang-risks` rows in an Instruments trace of the live
  process, with the time profiler putting Laban at 0.37% CPU.
- Every tab-switch frame in two journal dumps rendered *immediately*, on the
  `modelMutation` wake, in the same second as the switch.
- GPU work trivial: `present-blit` p50 0.095 ms, drawable waits max 0.64 ms,
  encoding p95 2.96 ms.

Two blind spots explain why none of that could confirm or deny the complaint:

1. **The journal never described the present link.** Its `displayLink` block is
   the host's main `CADisplayLink` — the link that decides when to *produce* a
   frame. Laban's GPU backends present through a second, renderer-owned
   `CAMetalDisplayLink` (`VectorPresentDisplayLink`), and a frame recorded as
   `rendered` is not necessarily on screen: the main link parks by design after
   a one-shot content change such as a tab switch, so whether the pixels landed
   depends entirely on the second link. `PresentLinkLiveness` now records its
   paused state, host intent, pending-present budget, callback and present
   counts, rebuilds, and stall repairs on every journal entry. Read across
   entries, `pendingPresentBudget > 0` with `callbacks` not advancing is a
   published frame waiting on a link that is not firing, and `stallRepairs > 0`
   means the watchdog already had to rebuild a link that stalled unpaused.
2. **Tab activation was never timed.** `pendingInputAt`, which feeds the
   input-to-photon samples, was armed only in `keyDown` — so the one interaction
   users call slow produced no latency number anywhere. It is now armed in
   `selectTabPreservingSelection`, which every activation route funnels through.

Deliberately cheap: `presentLinkLiveness()` avoids `presentIntervalStats`, which
sorts a ring of up to 4096 samples and is far too expensive per journaled frame.

### Ruled out along the way

- **Glyph-mask eviction.** The leading theory from the original triage (masks
  aging out at `maskEvictionTTLFrames = 240` and re-baking at
  `maxMaskBakeDispatchesPerFrame = 24`) does not survive reading or measurement:
  the dispatch cap only applies while `scrollPhaseOffset != .zero`, so a tab
  switch at rest is not throttled at all. A probe rendering a cold screen after
  a warm one measured ~20 ms per frame and the same bake count whether cold,
  warm, or after more than 240 frames of other content.
- **Synchronized-output holds.** `synchronizedOutputMaxHoldSeconds` is 1.0, so a
  TUI mid-update could plausibly stall a frame for a second, but both dumps
  contain only two `synchronizedOutputDefer` entries and neither is near a tab
  switch.

### Still open

The user reports that switching the renderer away and back to `slugGlyph`
resolves the phenomenon. That points at `vectorGlyph` specifically — the backend
this install runs only because it predates `5dcfc118`, which made Slug the
default for new installs. A probe of a *static* vector screen measured ~20 ms per
frame with a non-zero new-mask bake count on every frame, which would mean masks
are not being reused across frames; that measurement is from a synthetic harness
and is not yet confirmed against the real app, so it is recorded as a lead, not
a finding.
