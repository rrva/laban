# Extract Shared Terminal Surface Control

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

The terminal app and the headless debug server both need to turn application
tabs plus a terminal snapshot into the same renderer frame commands. Today the
AppKit view and the headless runtime each coordinate session polling, metadata
sync, snapshot lifetime, command assembly, and visible-text extraction. After
this change, that shared surface behavior lives in `LabanCore`, so the AppKit
view can stay focused on native events and the debug runtime can stay focused
on HTTP/debug requests. The observable behavior should remain the same: the app
renders terminal frames, the debug runtime renders screenshots and frame
commands, and existing tests continue to pass.

## Progress

- [x] Confirmed `main` is checked out at `/Users/dev/wrk/laban` and clean before edits.
- [x] Read `docs/product/mvp.md`, `PLANS.md`, `AGENTS.md`, and `docs/process/agent-operating-guide.md`.
- [x] Added a shared AppKit-free terminal surface controller and snapshot text helpers in `Sources/LabanCore`.
- [x] Wired `TerminalBitmapView` frame command assembly and dirty-row damage through the shared controller.
- [x] Wired `HeadlessDebugRuntime` frame command assembly, metadata sync, and visible-text extraction through the shared controller.
- [x] Added focused tests for the extracted controller/helper behavior.
- [x] Ran targeted and broader Swift tests.
- [x] Ran `scripts/check` and fixed an ASan-only PTY test readiness race exposed by the check script.

## Outcomes & Retrospective

`Sources/LabanCore/TerminalSurfaceController.swift` now owns shared session
metadata/dirty sync, snapshot lifetime during frame construction, sidebar plus
terminal frame command assembly, capture hooks for terminal snapshots/frame
commands, dirty-row damage calculation, and visible-text extraction modes.
`TerminalBitmapView` remains the AppKit adapter for display link, focus, native
input, scroll animation, capture start/stop, and backend presentation.
`HeadlessDebugRuntime` remains the HTTP/debug adapter for actions, endpoint
responses, software rendering, and artifact endpoints.

The source-level visible-text implementations in `FixtureRunner`,
`CaptureRecorder`, `CaptureReplayRunner`, and `HeadlessDebugRuntime` now route
through `TerminalSnapshotText`; `FixtureRunner` keeps its public convenience
method and replay keeps a private convenience wrapper.

`scripts/check` exposed that
`LabanSessionTests.testControlZSendsSuspendCharacterThroughForegroundPTY` could
send Ctrl-Z before the shell had printed `READY` and entered `read` under ASan.
The test now waits for `READY` in the visible snapshot before sending Ctrl-Z, so
the assertion measures the foreground PTY suspend behavior instead of shell
startup timing.

## Context and Orientation

`Sources/LabanCore/AppModel.swift` owns tabs and sessions. `Sources/LabanCore/FrameProducer.swift`
turns a `LabanSnapshot` into terminal `FrameCommand` values. `Sources/LabanCore/SidebarProducer.swift`
turns the tab list into sidebar `FrameCommand` values. `Sources/LabanApp/TerminalBitmapView.swift`
currently combines AppKit view concerns with frame generation and dirty-row
damage calculation. `Sources/LabanDebug/HeadlessDebugRuntime.swift` currently
builds similar frame commands and visible-text projections for the debug HTTP
server.

A `LabanSnapshot` is a C-owned snapshot of terminal rows, cells, cursor state,
dirty rows, and visible text storage. Callers must destroy snapshots with
`laban_snapshot_destroy` after use. A `FrameCommand` is the renderer-neutral
draw instruction consumed by the software and Metal renderers.

## Plan of Work

Create `Sources/LabanCore/TerminalSurfaceController.swift` with:

- `TerminalSurfaceController`, initialized with an `AppModel`, terminal cell
  size, sidebar geometry, and optional capture sink.
- a metadata/dirty sync method that can either poll sessions for headless mode
  or only observe session dirtiness for AppKit mode.
- a frame-building method that owns snapshot lifetime, records capture hooks,
  assembles sidebar plus terminal frame commands, and returns frame metadata.
- a shared dirty-row damage calculation method.
- `TerminalSnapshotText` helpers that replace duplicated visible-text extraction
  modes while preserving current trimmed-row and full-grid behavior.

Then update `TerminalBitmapView` and `HeadlessDebugRuntime` to call this
controller for the extracted responsibilities. Keep native input, paste,
selection gestures, display links, HTTP action decoding, and screenshot
encoding in their existing adapter files.

## Validation and Acceptance

Run these commands from `/Users/dev/wrk/laban`:

```sh
rtk swift test --filter TerminalSurfaceControllerTests
rtk swift test --filter LabanDebugSmokeTests
rtk swift test --filter TerminalBitmapViewSyncOutputTests
rtk swift test
```

Acceptance is that all relevant tests pass and the diff shows shared terminal
surface code in `LabanCore` with `TerminalBitmapView` and
`HeadlessDebugRuntime` no longer hand-assembling the same frame command path.

Validation completed on 2026-05-10:

```text
rtk swift test --filter TerminalSurfaceControllerTests
  Executed 3 tests, 0 failures.

rtk swift test --filter LabanDebugSmokeTests
  Executed 39 tests, 0 failures.

rtk swift test --filter TerminalBitmapViewSyncOutputTests
  Executed 4 tests, 0 failures.

rtk swift test --filter FixtureRunnerTests
  Executed 5 tests, 0 failures.

rtk swift test --filter CaptureRecorderTests
  Executed 8 tests, 0 failures.

rtk swift test --filter LabanDebugCaptureTests
  Executed 5 tests, 0 failures.

rtk swift test --filter LabanDebugTests.CaptureReplayTests
  Executed 5 tests, 0 failures.

rtk swift test
  Executed 406 tests, 2 skipped, 0 failures.

rtk swift test --sanitize address --filter LabanSessionTests/testControlZSendsSuspendCharacterThroughForegroundPTY
  Executed 1 test, 0 failures.

rtk scripts/check
  check-boundaries passed
  check-docs passed
  check-debug-contract passed
  check-dependencies passed
  swift test: Executed 406 tests, 2 skipped, 0 failures.
  check-sanitize: selected terminal-core tests passed.
  smoke-runtime passed.
  test-e2e passed.
  check passed.
```

`rtk swift-format format -i ...` was attempted but the installed
`swift-format` could not read this repository's `.swift-format` file, so no
formatter changes were applied.

## Idempotence and Recovery

The refactor is additive first: introduce shared helpers, wire one adapter at a
time, and keep tests passing after each slice. If a wiring step regresses, leave
the helper in place and restore only the affected adapter call path while
preserving unrelated user changes.
