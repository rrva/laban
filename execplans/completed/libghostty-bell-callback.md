# Add libghostty Bell Callback Plumbing

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban currently lets libghostty-vt parse terminal output and report title,
focus, size, and terminal responses, but it does not observe BEL (`0x07`)
events through libghostty's bell effect callback. After this change, terminal
bell events are observable through the terminal-core C ABI and Swift `Session`
API. A developer can prove the behavior by feeding BEL into a fixture session
and seeing the callback count increment.

This plan intentionally does not add sidebar badges or sound playback. Those are
product behaviors on top of the event; this change only exposes the terminal
event safely.

## Progress

- [x] Inspected existing libghostty callback patterns for title changes,
  terminal responses, and OSC 21337 tab-status callbacks.
- [x] Add C session storage, bell effect callback registration, C ABI functions,
  and tests.
- [x] Add Swift `Session.onBell` plumbing and tests.
- [x] Run focused validation and move this ExecPlan to `execplans/completed/`.

## Decision Log

- Decision: Expose a bell count and callback, but do not mutate tab metadata or
  render a badge in this change.
  Rationale: The user's request was to add the libghostty bell callback. UI
  badges require product choices about active-tab clearing, inactive-tab
  attention, and interaction with existing OSC 21337 indicators.
  Date/Author: 2026-05-21 / Codex.

## Context and Orientation

`Sources/LabanTerminalCore/session_lifecycle.c` creates the libghostty terminal
and registers effect callbacks with `ghostty_terminal_set`. "Effect callback"
means a function libghostty calls when terminal output requests a host-side
action such as writing bytes back to the PTY, reporting size, changing title, or
ringing the bell. `Sources/LabanTerminalCore/terminal_effects.c` implements
these callbacks.

`Sources/LabanTerminalCore/include/LabanTerminalCore.h` is the public C ABI that
Swift imports. Swift must not hold raw libghostty handles. `Sources/LabanCore/Session.swift`
wraps this C ABI and already uses retained `SessionCallbackState` userdata for
capture and tab-status callbacks. Bell callbacks should follow that pattern and
must be cleared before destroying a session.

## Plan of Work

1. In `LabanTerminalCore.h`, add `LabanBellCallback`,
   `laban_session_set_bell_callback`, and `laban_session_bell_count`.
2. In `session_internal.h`, store `bell_count`, `bell_callback`, and
   `bell_userdata` on `LabanSession`, and declare `laban_bell_cb`.
3. In `terminal_effects.c`, implement `laban_bell_cb` to increment the count
   and invoke the optional callback. Implement the public setter and count
   getter under the session lock.
4. In `session_lifecycle.c`, register `GHOSTTY_TERMINAL_OPT_BELL`.
5. In `Session.swift`, add `onBell`, retained callback userdata, callback-state
   storage, clear logic, and a `bellCount()` helper.
6. Add tests in `LabanSessionTests` and `CaptureSessionBridgeTests` proving BEL
   fires the callback/count and that clearing the Swift handler stops delivery.

## Validation and Acceptance

Run from `/Users/dev/wrk/laban`:

```sh
rtk swift test --filter LabanSessionTests
rtk swift test --filter CaptureSessionBridgeTests
rtk ./scripts/check-docs
```

Acceptance:

- Feeding BEL (`0x07`) to a fixture session increments the C bell count.
- The C bell callback receives monotonically increasing counts.
- Swift `Session.onBell` receives counts and stops receiving them after being
  set to `nil`.
- Documentation checks pass.

Validated on 2026-05-21:

- `rtk swift test --filter LabanSessionTests`
- `rtk swift test --filter CaptureSessionBridgeTests`
- `rtk ./scripts/check-docs`

## Idempotence and Recovery

All edits are additive or small local mutations. Re-running the tests is safe.
If a callback test hangs or crashes, clear callback userdata before session
destruction and verify the retained Swift `SessionCallbackState` is released in
the same pattern as capture and tab-status callbacks.
