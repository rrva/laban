# Gate Rendering During Synchronized Output

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Codex and other terminal user interfaces use synchronized output mode, the DEC
private mode `2026`, to ask the terminal to hold intermediate redraws until a
complete frame has been written. In Laban, those intermediate states are
currently rendered, so the cursor appears to jump around during Codex startup.
After this change, when a foreground terminal session has dirty output while
mode `2026` is active, Laban keeps showing the previous completed frame and
renders the new state after the application sends the matching reset. If the
application never sends the reset, Laban clears the mode after one second and
renders the latest buffered state rather than freezing presentation.

The behavior is visible by running Codex inside Laban: the startup redraw should
no longer show a cursor moving through the intermediate line clears and cursor
moves. It is also testable by feeding `CSI ? 2026 h`, changing the grid, and
asserting that the AppKit frame loop does not render the dirty in-progress
snapshot until `CSI ? 2026 l` arrives.

## Progress

- [x] Inspected `docs/product/mvp.md` and `docs/process/dev-process.md`; this is
  MVP terminal behavior and must be autonomously verifiable.
- [x] Inspected the latest AppKit capture at
  `/Users/dev/Library/Logs/Laban/captures/appkit-2026-05-05T18-47-46Z`.
- [x] Confirmed the capture contains Codex startup output bracketed by
  `CSI ? 2026 h/l`, while Laban records intermediate frames with
  `cursorVisible: true`.
- [x] Confirmed libghostty-vt exposes `GHOSTTY_MODE_SYNC_OUTPUT` through
  `ghostty_terminal_mode_get`.
- [x] Expose synchronized-output state through Laban's session ABI and Swift
  wrapper.
- [x] Gate the AppKit frame loop so dirty active-terminal content is not
  snapshotted or rendered while synchronized output is active.
- [x] Add regression coverage for the C mode query and the AppKit render gate.
- [x] Run targeted tests and the repository-level `./scripts/check` gate.
- [x] Attempt replay of the latest capture and record the unrelated replay
  drift discovered there.
- [x] Researched synchronized-output semantics and added a one-second stuck-mode
  watchdog to match Ghostty's termio behavior.

## Decision Log

- Decision: Gate rendering in the AppKit frame loop instead of rewriting
  captured PTY bytes or hiding only the cursor.
  Rationale: Synchronized output mode means the whole redraw is provisional,
  not just the cursor position. Holding the previous frame until the mode exits
  matches the intent of `CSI ? 2026 h/l` and prevents any intermediate cursor or
  grid state from becoming visible.
  Date/Author: 2026-05-05 / Codex.

- Decision: Reset synchronized output mode after a one-second hold if ESU never
  arrives.
  Rationale: The synchronized-output notes say terminals keep processing input
  while rendering the last state, and explicitly warn implementers to consider
  a timeout. Ghostty's full termio layer uses a 1000 ms reset timer; Laban uses
  only libghostty-vt, so the AppKit frame loop must provide the watchdog.
  Date/Author: 2026-05-05 / Codex.

## Context and Orientation

`Sources/LabanTerminalCore/session.c` owns the libghostty-vt terminal handle and
already queries terminal modes for bracketed paste. `Sources/LabanCore/Session.swift`
wraps that C ABI for Swift. `Sources/LabanApp/TerminalBitmapView.swift` drives
the visible AppKit frame loop: it polls sessions, checks whether the active
terminal is dirty, snapshots the active session, converts the snapshot into
frame commands, renders them, and then calls `session.markRendered()`.

Synchronized output mode is DEC private mode `2026`. A terminal application
enables it with `ESC [ ? 2026 h`, writes a batch of cursor moves, erases, and
text, then disables it with `ESC [ ? 2026 l`. While the mode is enabled, the
terminal should avoid presenting intermediate states to the user. Incoming bytes
are still processed into terminal state while the prior completed frame remains
visible.

## Plan of Work

Add a C ABI function named `laban_session_synchronized_output_active` in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h` and implement it in
`Sources/LabanTerminalCore/session.c` by querying `GHOSTTY_MODE_SYNC_OUTPUT`.
Expose it as `Session.synchronizedOutputActive` in
`Sources/LabanCore/Session.swift`.

In `TerminalBitmapView.advanceFrame()`, after polling and dirty detection but
before snapshot creation, check whether the active session has synchronized
output active and dirty terminal content. If so, return without snapshotting,
rendering, or marking the session rendered. Leaving the dirty state intact is
important: the next tick after `CSI ? 2026 l` must still render the completed
frame. Track the start time for the synchronized-output hold and, if it remains
active for one second without ESU, reset the mode and render the current state
so malformed output cannot hide later updates indefinitely.

Add regression tests. In `Tests/LabanTerminalCoreTests/VTRedrawRegressionTests.swift`,
assert that the new C query tracks `CSI ? 2026 h/l` and that the watchdog reset
helper clears the mode. In an AppKit-facing test, exercise the frame loop with a
fixture session and a synchronized update so the render count stays unchanged
while the mode is active, advances after the watchdog expires, gates a later
synchronized window again, and advances after the mode is reset.

## Surprises & Discoveries

- Observation: The latest AppKit capture did not replay cleanly before using it
  as acceptance evidence for this bug.
  Evidence: `./scripts/replay-capture /Users/dev/Library/Logs/Laban/captures/appkit-2026-05-05T18-47-46Z`
  failed with frame-command hash drift starting at frame 48, before the Codex
  synchronized-output startup section. Comparing frame 48 showed replay was
  recomputing terminal commands with Selenized Dark colors while the capture
  recorded Selenized Light colors. `--mode=renderer` skipped terminal replay
  but still reported a final screenshot hash mismatch. This is capture/replay
  determinism drift, not evidence that the synchronized-output render gate
  failed.

## Concrete Steps

Work from `/Users/dev/.codex/worktrees/befc/laban`. Prefix commands with
`rtk`, per `/Users/dev/.codex/RTK.md`.

1. Edit the C header and implementation to add the synchronized-output mode
   query.
2. Edit the Swift session wrapper and AppKit frame loop to use the query.
3. Add tests for the query and render gate.
4. Run:

   ```sh
   rtk swift test --filter VTRedrawRegressionTests
   rtk swift test --filter TerminalBitmapViewSyncOutputTests
   rtk ./scripts/lint
   rtk swift test
   rtk ./scripts/smoke-runtime
   rtk ./scripts/test-e2e
   rtk ./scripts/check
   ```

## Validation and Acceptance

Acceptance is:

- `testSynchronizedOutputModeQueryTracksBSUESU` fails before the C query exists
  and passes after it is implemented.
- The AppKit render-gate test proves that no new visible frame is rendered while
  synchronized output is active and dirty, that rendering resumes after the
  one-second watchdog, and that rendering resumes after the reset sequence.
- The latest capture has been inspected and replay has been attempted. Existing
  capture/replay theme drift is recorded in `Surprises & Discoveries`; this bug
  is accepted by focused mode-query and AppKit render-gate tests instead.
- Manual observation after starting Codex inside Laban should show the Codex
  startup UI appear as completed frames rather than a cursor jumping through
  intermediate rows.

## Idempotence and Recovery

The changes are additive and can be rerun safely. If `.external/` is missing in
this worktree, recreate it with:

```sh
rtk ln -s /Users/dev/wrk/laban/.external .external
```

If a test leaves build products behind, rerun the same `swift test` command;
no cleanup is required.
