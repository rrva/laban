# Extract theme palette injection and Metal drawable scheduling

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

This change keeps two small but important responsibilities out of large facade
types. `AppModel` should decide when sessions are created and when theme
changes are applied, but the byte-level OSC palette construction belongs in a
theme helper. `MetalRenderer` should encode and present frames, but drawable
timeout handling and one-frame-in-flight coordination belong in a scheduler.

The app behavior should not change. New sessions still start capture before
theme palette bytes are injected, and Metal still drops frames rather than
blocking when a drawable or the previous frame is unavailable.

## Progress

- [x] Read the relevant `Sources/` model and renderer files and nearby tests.
- [x] Add `ThemePaletteInjector` and update `AppModel` to use it.
- [x] Add `MetalDrawableScheduler` and update `MetalRenderer` to use it.
- [x] Add focused tests where useful and run validation.

## Decision Log

- Decision: Extract only theme palette byte injection from `AppModel`, leaving
  capture start and theme notification observation in the model.
  Rationale: Capture ordering and observer lifetime are model lifecycle
  concerns. OSC byte construction and injection are not.
  Date/Author: 2026-05-11 / Codex.

- Decision: Extract drawable acquisition plus frame-in-flight gating together.
  Rationale: These two mechanisms form one scheduling policy: start a frame only
  when the previous shared-texture frame has retired and a drawable can be
  acquired inside the frame budget.
  Date/Author: 2026-05-11 / Codex.

## Context and Orientation

`Sources/LabanCore/AppModel.swift` creates sessions and observes
`Theme.didChangeNotification`. Before this change it also built OSC 4/10/11/12
escape sequences and fed them to the terminal session. OSC means "Operating
System Command", a terminal escape sequence family. OSC 4 sets ANSI palette
slots; OSC 10, 11, and 12 set default foreground, background, and cursor colors.

`Sources/LabanRenderer/MetalRenderer.swift` owns a `CAMetalLayer`. A drawable is
the layer texture for one presented frame. The renderer also uses a persistent
target texture, so only one frame may be in flight at a time; otherwise one GPU
frame could read the target while another writes it.

## Plan of Work

Add `Sources/LabanCore/ThemePaletteInjector.swift` with a small internal helper:

- `injectCurrentTheme(into:)` sets the terminal core's light/dark color scheme
  and feeds OSC palette bytes into the session.
- `paletteBytes(for:)` builds the OSC byte stream from a `ThemeData` value.

Update `AppModel` to call `ThemePaletteInjector.injectCurrentTheme(into:)`
during initial session creation, tab creation, and theme-change reinjection.
Remove the byte-building helpers from `AppModel`.

Add `Sources/LabanRenderer/MetalDrawableScheduler.swift` with a scheduler that:

- serializes shared-texture frames with a one-frame-in-flight semaphore
- acquires `CAMetalDrawable` asynchronously with the existing 8 ms budget
- returns a frame token whose `finish()` method releases the semaphore exactly
  once

Update `MetalRenderer.render` to request a frame token before encoding and to
finish it in failure paths or the command-buffer completion handler.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/6627/laban`:

```sh
swift test --filter AppModelTests
swift test --filter ThemePaletteInjectorTests
swift test --filter LabanRendererTests
swift format lint --strict Sources/LabanCore/AppModel.swift Sources/LabanCore/ThemePaletteInjector.swift Tests/LabanCoreTests/ThemePaletteInjectorTests.swift Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/MetalDrawableScheduler.swift
git diff --check
```

Acceptance is all commands exiting 0. `AppModelTests` covers model lifecycle
behavior, and `LabanRendererTests` covers the Metal smoke paths that depend on
drawable acquisition and frame completion.

Completed on 2026-05-11:

```sh
swift test --filter AppModelTests
swift test --filter ThemePaletteInjectorTests
swift test --filter LabanRendererTests
swift format lint --strict Sources/LabanCore/AppModel.swift Sources/LabanCore/ThemePaletteInjector.swift Tests/LabanCoreTests/ThemePaletteInjectorTests.swift Sources/LabanRenderer/MetalRenderer.swift Sources/LabanRenderer/MetalDrawableScheduler.swift Sources/LabanRenderer/SoftwareRenderer.swift Sources/LabanRenderer/TextDecorationLayout.swift Tests/LabanRendererTests/TextDecorationLayoutTests.swift
git diff --check
```

All completed commands exited 0. `AppModelTests` executed 24 tests,
`ThemePaletteInjectorTests` executed 1 test, and `LabanRendererTests` executed
31 tests.

## Idempotence and Recovery

The change is source-only. If the helper extraction fails, move the small OSC
byte builder or scheduling code back into the original files and rerun the same
validation commands.
