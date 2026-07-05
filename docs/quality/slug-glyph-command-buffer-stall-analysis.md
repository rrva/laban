# Slug glyph main-thread stall analysis

**Build:** `862ec88` (built 2026-07-05T17:15:21Z)  
**Investigated:** 2026-07-05  
**Symptom:** ~500–750 ms UI freezes captured by `MainThreadWatchdog`

## Summary

Stalls in build `862ec88` are **real main-thread hangs**, not watchdog false positives. Every capture from the current session (pid 82227) shows the main thread blocked inside `SlugGlyphRenderer.render()` at `queue.makeCommandBuffer()` — Metal's render queue has no free command-buffer slots because too many buffers are still in flight on the GPU.

The root cause is an **architectural gap**: `MetalRenderer` and `VectorGlyphRenderer` serialize render submission through `MetalDrawableScheduler` (non-blocking drop when busy). `SlugGlyphRenderer` has no equivalent guard and blocks synchronously when the command-buffer pool is exhausted.

## Evidence

### Watchdog captures (862ec88 session, pid 82227)

| Time (UTC) | Duration | File |
|---|---|---|
| 18:29:04 | 718 ms | `~/laban-watchdog/inproc-stall-718ms-20260705-202904.668.txt` |
| 18:34:24 | 691 ms | `~/laban-watchdog/inproc-stall-691ms-20260705-203424.450.txt` |
| 18:36:13 | 487 ms | `~/laban-watchdog/inproc-stall-487ms-20260705-203613.622.txt` |
| 19:00:47 | 709 ms | `~/laban-watchdog/inproc-stall-709ms-20260705-210047.848.txt` |
| 19:01:43 | 579 ms | `~/laban-watchdog/inproc-stall-579ms-20260705-210143.021.txt` |
| 19:02:37 | 753 ms | `~/laban-watchdog/inproc-stall-753ms-20260705-210237.898.txt` |

Structured events: `~/Library/Application Support/Laban/events/2026-07-05.jsonl` (`watchdog.stall` entries).  
Watchdog notices: `~/Library/Application Support/Laban/log/2026-07-05.log`.

### Main-thread stack (all six captures)

```
advanceFrame (displayLink or scheduleOutputSettleWake)
  → TerminalBitmapView.advanceFrame(wake:)
    → SlugGlyphRenderer.render(_:damage:)   [SlugGlyphRenderer.swift:796]
      → queue.makeCommandBuffer()
        → _dispatch_semaphore_wait_slow → semaphore_wait_trap
```

Line 796 is exactly where the slug renderer allocates a new Metal command buffer:

```swift
guard let target = commitRingSlot(slot, rebuild: ringRebuild),
  let commandBuffer = queue.makeCommandBuffer()
else { return false }
```

Most stalls enter via `scheduleOutputSettleWake` (PTY output burst → quiet window → render wake). One capture (753 ms) came from the display-link path directly.

### Earlier stalls today (different issue)

Three captures before the pid-82227 session (698/703/560 ms, pid 20144, ~17:49–18:05 UTC) show a **different** stack: blocked in `CA::Layer::prepare_contents` / `CABackingStoreGetFrontTexture` during a Core Animation transaction flush. Those are layer-compositing stalls, not slug Metal encoding.

## Root cause

### SlugGlyphRenderer lacks render-side in-flight serialization

`MetalRenderer` and `VectorGlyphRenderer` gate frame submission through `MetalDrawableScheduler.beginFrame()`, which limits the pipeline to **one frame in flight** and uses a **non-blocking** wait:

```swift
// MetalDrawableScheduler.swift
func beginFrame(needsFullFrame: Bool, dropIfBusy: Bool = false) -> Frame? {
  let timeout: DispatchTime =
    (needsFullFrame && !dropIfBusy) ? .now() + .milliseconds(16) : .now()
  guard frameInFlight.wait(timeout: timeout) == .success else {
    return nil  // drop frame, do not block
  }
  return Frame(scheduler: self)
}
```

If the GPU is still busy, `beginFrame` returns `nil` → `render()` returns `false` with `.previousFrameInFlight` → `TerminalBitmapView` applies GPU backpressure pacing (carry invalidation, park, or display-link-paced retry).

**SlugGlyphRenderer has no equivalent.** It calls `queue.makeCommandBuffer()` directly. When Metal's internal pool is exhausted, `makeCommandBuffer()` **blocks the main thread** on a semaphore instead of returning `false`.

### How command buffers pile up

| Factor | Effect |
|--------|--------|
| Async commit, no wait | Normal path uses `waitForFrameCompletion = false`; buffers stay in flight until GPU completes. |
| 3-slot target ring | `targetRingDepth = 3` rotates textures so up to three encode passes can overlap — by design for the present-link path, but with no render-side cap. |
| Separate present queue at 120 Hz | `VectorPresentDisplayLink` blits/presents on `presentQueue` every vsync; render buffers on `queue` retire only when GPU work completes. |
| Heavy subpixel path | RGB subpixel = accumulate pass + content pass + composite passes → longer GPU time per frame. |
| Multiple wake sources | Display link (~120 Hz), `scheduleOutputSettleWake`, `renderRetry`, session dirty kicks — all call `advanceFrame` independently. |
| No `dropNextFrameWhenBusy` | Scroll coalescing sets this on Metal/Vector only (`TerminalBitmapView`); Slug ignores it entirely. |

Typical trigger: a PTY output burst finishes its output-settle quiet window, `scheduleOutputSettleWake` fires `advanceFrame`, and the render hits a saturated queue while earlier display-link frames are still in flight.

### Backpressure handling does not cover Slug

When `render()` returns `false`, the frame loop only treats GPU backpressure specially for `MetalRenderer`:

```swift
// TerminalBitmapView.swift
let failureReason = (backend as? MetalRenderer)?.lastRenderFailureReason
if failureReason?.isGPUBackpressure == true {
  // carry invalidation, park, display-link-paced retry
}
```

Slug has no `lastRenderFailureReason`. When it **blocks** inside `makeCommandBuffer()`, it never reaches this path — no drop, no park, no paced retry.

## Not caused by 862ec88

Commit `862ec88` ("Fix CJK text and terminal trust gate issues") only changed CJK cell-width counting in `SlugGlyphRenderer` (`TerminalDisplayWidth.cells(of: text)`). It did not change the Metal pipeline or command-buffer lifecycle.

The stalls match a **pre-existing gap**: Slug received the ADR 0026 present-link path (3-ring + dedicated present queue) but not the render-side in-flight serialization that Metal/Vector use via `MetalDrawableScheduler`.

## Recommended fix

Give Slug the same contract as Vector/Metal on the **render queue**:

1. **Non-blocking in-flight gate** before `makeCommandBuffer()` — reuse `MetalDrawableScheduler` or a semaphore (value 1–3, aligned with ring depth), with `.now()` timeout for scroll/burst frames.
2. **Expose a failure reason** (e.g. `.previousFrameInFlight`) so `TerminalBitmapView` backpressure logic applies to Slug.
3. **Wire `dropNextFrameWhenBusy`** for scroll frames on Slug, same as Vector/Metal.

Expected behavior after fix: under GPU pressure, frames **drop and retry on the next tick** (~8 ms) instead of blocking the main thread for hundreds of milliseconds.

## Related files

- `Sources/LabanRenderer/SlugGlyphRenderer.swift` — render path, line 796
- `Sources/LabanRenderer/MetalDrawableScheduler.swift` — in-flight gate used by Metal/Vector
- `Sources/LabanRenderer/VectorPresentDisplayLink.swift` — present-link path (ADR 0026)
- `Sources/LabanApp/TerminalBitmapView.swift` — `advanceFrame`, GPU backpressure, `scheduleOutputSettleWake`
- `Sources/LabanApp/MainThreadWatchdog.swift` — stall detection
- `execplans/active/slug-render-loop-perf-and-aa-quality.md` — slug perf plan (present-link invariants)
