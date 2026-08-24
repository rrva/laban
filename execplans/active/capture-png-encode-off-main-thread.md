# Stop Encoding Capture PNGs On The Main Thread

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

With a capture running, Laban's window stutters: the terminal misses frames and
clicks lag. The cause is not the terminal — it is the capture itself. Every
rendered frame ran a full-surface PNG deflate inline on the main thread, so the
frame loop stopped for tens of milliseconds per frame while libpng compressed a
15 MB image.

After this change the main thread only copies the frame's pixels out of the GPU
and hands them off; the PNG deflate happens on a background queue. Measured on a
2400×1576 surface, the main-thread cost of a captured frame drops from **26.3 ms
to 3.8 ms** — from over a 60 Hz frame budget to well under a 120 Hz one — and
the capture artifact is byte-for-byte identical.

### Terms used here

- **Capture** — Laban's diagnostic recorder (`Sources/LabanCore/CaptureRecorder.swift`),
  started from the app menu. It writes a directory under
  `~/Library/Logs/Laban/captures/` holding the PTY byte streams, a timeline of
  events, and one `frames/frame-NNNNNN.render.json` sidecar per rendered frame
  carrying a `pixelHash` — the sha256 of that frame's PNG bytes.
- **Replay verification** — `Tests/LabanDebugTests/SlugGlyphCaptureReplayTests.swift`
  re-renders a capture and compares its PNG hash against the recorded
  `pixelHash`. That contract is why the encoded bytes must not change.
- **Backend** — the object that draws a frame: `MetalRenderer`,
  `SlugGlyphRenderer`, `VectorGlyphRenderer` (all Metal) or `SoftwareBackend`.

## The bug, with evidence

The main-thread stall watchdog (`~/laban-watchdog/`) recorded 12 stalls between
17:36 and 17:55 on 2026-08-24, 588–952 ms each, every one with the same stack:

    TerminalBitmapView.advanceFrame(wake:)
      VectorGlyphRenderer.pngData.getter
        -[_MTLCommandBuffer waitUntilCompleted]        970 of 1236 samples
        PNGEncoder.encode → libpng deflate              72 of 1236 samples

`pngData` did four things in one synchronous accessor — wait for the GPU, copy
the surface to the CPU, build a `CGImage`, deflate a PNG — and `advanceFrame`
called it for every rendered frame while a capture was active:

    recorder.recordRenderedFrame(
      pngData: recorder.needsRenderedPixelReadback ? backend.pngData : nil, …)

All three GPU backends carried their own near-identical copy of that code.

## What changes

1. **`Sources/LabanRenderer/RenderedPixelSnapshot.swift` (new)** — one frame's
   pixels on the CPU (premultiplied-first BGRA8, sRGB), plus `encodePNG()`.
   `encodePNG()` touches no Metal object, so it is safe on any thread. This also
   collapses three copies of the `CGImage` + PNG boilerplate into one.
2. **`RendererBackend.renderedPixelSnapshot()`** — the cheap half of `pngData`:
   wait only long enough to get the pixels onto the CPU, then hand them back.
   Default implementation returns nil (the software backend already holds a
   realised bitmap); `pngData` on each GPU backend becomes
   `renderedPixelSnapshot()?.encodePNG()`.
3. **`TerminalBitmapView.recordCapturedFrame`** — takes the snapshot inline and
   encodes on a serial `laban.capture.png-encode` queue.
   `drainPendingCaptureEncodes()` runs before `recorder.finish(...)` so the tail
   of a capture cannot be lost.
4. **`CaptureRecorder.recordRenderedFrame` gains `seq:` and `timeNs:`** —
   defaulted to today's stamp-at-write behavior. The frame loop stamps both
   ordering keys when the frame is *rendered* and passes them through, so
   deferring the encode cannot reorder the artifact.

## Why the ordering keys had to move

`CaptureTimelineEvent` stamps `timeNs` at construction and `seq` at write time.
Encoding on a background queue means the event is written later than the frame
was drawn, so without this both keys would describe when the deflate finished
rather than when the frame was rendered — placing the frame after events that
genuinely came after it. Reserving `recorder.nextSequence()` and
`CaptureClock.nowNs()` in the frame loop keeps both keys exact. The replay
contract itself is unaffected either way: it reads the per-frame sidecar keyed
by frame number, not timeline order.

## Non-goals

- The GPU wait stays on the main thread (3.8 ms of the original 26.3 ms: a
  `waitUntilCompleted` plus a 15 MB copy). The copy genuinely cannot be deferred
  — the vector backend's 3-slot target ring is overwritten by later frames —
  but the wait could be removed by taking the snapshot inside the frame's own
  GPU completion handler, before the frame-in-flight slot is released. See
  `Surprises & Discoveries` for why that matters more than 3.8 ms suggests.
- `HeadlessDebugRuntime` keeps encoding synchronously. It is a batch harness
  driven by an explicit step loop with no responsiveness requirement, and
  synchronous encoding keeps its CI artifacts deterministic without a drain step
  that could silently truncate them if missed.

## Progress

- [x] Read the stall samples and identified `pngData` in `advanceFrame` as the
      stack, common to all three GPU backends.
- [x] Added `RenderedPixelSnapshot` and the `renderedPixelSnapshot()` hook;
      rewrote `pngData` on `VectorGlyphRenderer`, `SlugGlyphRenderer`,
      `MetalReadback`/`MetalRenderer` in terms of it.
- [x] Moved the capture encode to a serial background queue with a drain before
      `finish()`, and threaded the ordering keys through `recordRenderedFrame`.
- [x] Added tests: byte-for-byte equality of `renderedPixelSnapshot()?.encodePNG()`
      and `pngData` for every GPU backend, the software backend's opt-out that
      the host's fallback depends on, and the recorder's ordering-key handling
      (supplied and defaulted).
- [x] Measured the split and ran the full suite.

## Decision Log

- Decision: split `pngData` rather than making it asynchronous. `pngData` has
  several one-off callers (debug screenshot endpoints, render-journal dumps,
  capture finalization) for which blocking is correct and simplest. Only the
  per-frame path needed to change, so the synchronous accessor stays and gains a
  cheaper sibling.
- Decision: a serial encode queue, not a concurrent one. Frames stay in order,
  only one full-surface image is alive at a time, and the drain is a single
  `sync {}` barrier.
- Decision: pass the ordering keys through rather than letting the deferred
  write stamp them. See "Why the ordering keys had to move".

## Surprises & Discoveries

- The stall magnitudes (588–952 ms) are inflated by the build, not
  representative of a release build. `scripts/build-app` sets
  `MetalCaptureEnabled` in the Info.plist for `--profile` builds — which is what
  `scripts/install-app` produces — so every locally installed build loads
  `GPUToolsCapture` and wraps every Metal object (`-[CaptureMTLCommandBuffer
  waitUntilCompleted]` is visible in the samples). That is deliberate (the key
  has to be armed before launch for `gpucapture` to attach), but it means GPU
  timings measured on an installed build are not release timings.
- That inflation lands on the half this change does NOT move: the GPU wait was
  970 of 1236 samples. In a clean build the split removes 86% of the
  main-thread cost (26.3 ms → 3.8 ms); in a `--profile` build the residual wait
  still dominates. Removing it needs the completion-handler snapshot described
  under Non-goals.
- All three GPU backends had byte-identical `CGImage` construction — same
  bitmap info, same sRGB tagging, same comment about wide-gamut oversaturation —
  duplicated three times. The shared snapshot type removes the duplication, and
  the equality test pins the result so a future divergence is caught.

## Validation and Acceptance

Run from the repository root:

    swift build
    swift test --filter RenderedPixelSnapshotTests
    swift test --filter CaptureRecorderTests
    swift test --filter CaptureReplayTests

Expected: all pass, zero failures. (`swift test` with no filter also surfaces
two pre-existing `CJKFontSettingsTests` failures caused by a test-isolation bug
unrelated to this change — they pass when that suite runs alone.)

The measurement above is reproducible with a throwaway test that renders a
2400×1576 frame and times `renderedPixelSnapshot()`, `encodePNG()`, and
`pngData` separately; the median split was 3.8 ms inline / 22.6 ms deferred
against 26.3 ms for the original combined accessor.

Behavioral acceptance, in the running app:

1. `./scripts/install-app && scripts/restart-app`
2. Start a capture from the app menu, type for a while, stop the capture.
3. The window must stay responsive while the capture runs.
4. `ls ~/Library/Logs/Laban/captures/<newest>/frames/` must contain a
   `frame-NNNNNN.render.json` for every rendered frame including the last ones
   (this is what the drain protects), each with a `pixelHash`.
