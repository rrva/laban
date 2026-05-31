# Extract Metal readback handling

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

`MetalRenderer` should encode terminal frames and present them. The screenshot
and capture path is a separate concern: when capture mode is enabled, copy the
presented drawable into a CPU-readable texture and later encode that texture as
PNG. This change moves that readback texture, optional readback blit, resize
invalidation, and PNG serialization into a small `MetalReadback` helper.

The public renderer behavior should not change. `MetalRenderer.captureMode`
still controls whether the per-frame readback blit runs, and
`MetalRenderer.pngData` still waits for the most recent command buffer before
serializing the last readback texture.

## Progress

- [x] Read the current Metal readback and capture-mode code.
- [x] Add `MetalReadback`.
- [x] Update `MetalRenderer` to delegate readback work.
- [x] Run focused renderer checks.

## Decision Log

- Decision: Keep `captureMode` and `pngData` as `MetalRenderer` API while
  delegating implementation to `MetalReadback`.
  Rationale: AppKit and tests already depend on the renderer surface. The
  extraction should reduce internals without changing caller contracts.
  Date/Author: 2026-05-11 / Codex.

## Context and Orientation

`Sources/LabanRenderer/MetalRenderer.swift` renders into a `CAMetalLayer`.
Screenshots and capture artifacts need CPU-visible bytes, so when capture mode
is active the renderer copies the drawable texture into a shared Metal texture.
`pngData` waits for the latest command buffer, reads the shared texture bytes,
builds a `CGImage`, and passes it to `PNGEncoder`.

## Plan of Work

Add `Sources/LabanRenderer/MetalReadback.swift` with:

- a `captureMode` boolean
- an owned optional readback `MTLTexture`
- `invalidate()` for resize
- `encodeIfNeeded(from:commandBuffer:counterSampleBuffer:counterBlitSupported:)`
  to allocate the texture if needed and encode the drawable-to-readback blit
- `pngData(waitingFor:)` to wait for the latest command buffer and encode PNG

Update `MetalRenderer` to:

- wrap public `captureMode` around the helper
- return `readback.pngData(waitingFor: lastCmdBuf)` from `pngData`
- call `readback.invalidate()` on resize
- call `readback.encodeIfNeeded(...)` during pass 4 and mark
  `passSlots.readbackActive` from its return value
- remove the renderer-local readback texture and PNG method

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/6627/laban`:

```sh
swift test --filter LabanRendererTests
swift format lint --strict Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/MetalReadback.swift Sources/LabanRenderer/MetalDrawableScheduler.swift Sources/LabanRenderer/TextDecorationLayout.swift Tests/LabanRendererTests/TextDecorationLayoutTests.swift
git diff --check
```

Acceptance is all commands exiting 0. `MetalRendererSmokeTests` includes
capture-mode and `pngData` readback assertions.

Completed on 2026-05-11:

```sh
swift test --filter LabanRendererTests
swift format lint --strict Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/MetalReadback.swift Sources/LabanRenderer/MetalDrawableScheduler.swift Sources/LabanRenderer/TextDecorationLayout.swift Tests/LabanRendererTests/TextDecorationLayoutTests.swift
git diff --check
```

All completed commands exited 0. `LabanRendererTests` executed 31 tests with 0
failures.

## Idempotence and Recovery

The change is source-only. If readback behavior regresses, move the texture,
blit, and PNG code back into `MetalRenderer` and rerun the same renderer tests.
