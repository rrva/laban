# Finish Terminal Title Handling

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then make terminal title changes reliably update Laban's tab and window
UI without changing tab or session identity.

## Purpose / Big Picture

The MVP requires terminal title changes to update the tab label and window
title while preserving tab identity, session identity, focus, and tab order.
Laban already has partial plumbing: `LabanTerminalCore` snapshots can expose
the libghostty terminal title, `AppModel.updateTitle` updates a tab title
without changing IDs, and debug `/state` opportunistically copies snapshot
titles into tab state. Re-fetching `GHOSTTY_TERMINAL_DATA_TITLE` for every
snapshot is functional, but it couples title work to the render loop. The
user-visible gap is that terminal title changes are not yet driven by the
terminal title-change effect, the visible AppKit window still starts with a
fixed `"Laban"` title, and title synchronization is not a deliberate, bounded
behavior shared by AppKit and headless debug.

After this change, a shell or fixture that emits an OSC title sequence updates
the active tab label and the macOS window title. Background tab title changes
are reflected in the sidebar after polling without selecting or restarting the
tab. Headless debug can deterministically wait for and inspect title changes
without needing an unrelated `/debug/state` call to mutate model state first.

## Progress

- [x] (2026-05-03) Created this title-handling shard after mouse,
  scrollback, selection, copy, and paste work landed on `main`.
- [x] (2026-05-03) Verified current baseline:
  `Sources/LabanTerminalCore/session.c` copies
  `GHOSTTY_TERMINAL_DATA_TITLE` into `LabanSnapshot.title` but does not
  register `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`;
  `Sources/LabanCore/AppModel.swift` has `updateTitle(_:forTab:)` and a unit
  test proving identity is preserved; `Sources/LabanDebug/HeadlessDebugRuntime.swift`
  updates titles during `/debug/state` but `titleEquals` checks only cached tab
  state; `Sources/LabanApp/MainWindowController.swift` sets `window.title =
  "Laban"` once; `Sources/LabanApp/TerminalBitmapView.swift` does not update
  the AppKit window title or tab titles from terminal title effects.
- [x] (2026-05-04) Added `TerminalTitle.sanitize()` shared title policy in
  `Sources/LabanCore/TerminalTitle.swift`; `AppModel.updateTitle` applies it;
  `AppModel.syncTitle(forTab:from:)` consumes dirty flag + sanitizes + updates only on change.
- [x] (2026-05-04) Registered `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` in
  `laban_session_create`; added `title_dirty` field + `laban_session_consume_title` C ABI;
  `Session.consumeTitle()` Swift wrapper exposes it.
- [x] (2026-05-04) `TerminalBitmapView.advanceFrame()` calls `model.syncTitle` for all tabs
  after polling; sets `window?.title = model.windowTitle` each frame.
- [x] (2026-05-04) Added `TerminalTitleTests` (12 title-policy tests) and `AppModelTitleTests`
  (6 identity/sanitization/windowTitle tests) in `LabanCoreTests`; added 3 debug smoke tests
  proving `titleEquals` wait, state, and sessions all work without a prior state call;
  added `feedOutput` action to `HeadlessDebugRuntime`; `syncTitlesUnlocked()` called before
  all title-sensitive endpoints and wait loop. `./scripts/check` exits 0.
- [x] (2026-05-04) No separate MVP plan update needed; title handling is fully validated.

## Decision Log

- Decision: Keep title state in `AppModel.Tab.title`, with libghostty as the
  source for terminal-reported title bytes.
  Rationale: A title is app UI state derived from terminal state. The C core
  should expose bounded snapshots, but Swift owns tab labels, window title, and
  debug state. This matches the existing `AppModel.updateTitle` boundary and
  avoids exposing raw Ghostty handles to Swift.
  Date/Author: 2026-05-03 / Codex.

- Decision: Sanitize and bound titles before storing them in `AppModel`.
  Rationale: Terminal output is untrusted and may include very long strings,
  control characters, or empty titles. The MVP requires bounded title updates
  that cannot overlap controls or resize the sidebar unexpectedly.
  Date/Author: 2026-05-03 / Codex.

- Decision: Use the active tab's display title as the AppKit window title,
  with `"Laban"` as the fallback.
  Rationale: The MVP says terminal title changes update the window title. Using
  the active tab title is predictable for a single-window app, and falling back
  to `"Laban"` keeps the initial and empty-title state stable.
  Date/Author: 2026-05-03 / Codex.

- Decision: Drive title synchronization from libghostty's title-changed
  effect, not from render snapshots alone.
  Rationale: Reading `GHOSTTY_TERMINAL_DATA_TITLE` on every snapshot works, but
  it makes title handling incidental to rendering and misses the product model
  where title is session/UI state. A tiny C callback can mark title state dirty
  or advance a generation counter during `ghostty_terminal_vt_write()`, and
  Swift can consume the bounded title on its normal AppKit/debug polling paths.
  Snapshot titles should remain useful for verification and compatibility, but
  title correctness must not depend on building a render snapshot.
  Date/Author: 2026-05-03 / Codex.

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [x] Run `./scripts/check` from `/Users/dev/wrk/laban`; exits 0, prints `check passed`.
- [x] `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` registered in `session.c`;
  `laban_session_consume_title` declared in `LabanTerminalCore.h` and implemented.
- [x] `Sources/LabanCore/TerminalTitle.swift` — shared sanitization policy (bounding,
  control-char removal, empty-title nil return); applied in `AppModel.updateTitle`.
- [x] `TerminalBitmapView.advanceFrame()` calls `model.syncTitle` per tab; sets
  `window?.title = model.windowTitle`.
- [x] `HeadlessDebugRuntime.syncTitlesUnlocked()` called before `titleEquals` check
  (wait loop), `stateUnlocked()`, and `sessions()`.
- [x] `swift test --filter LabanCoreTests` — 18 new title tests pass (bounding,
  empty fallback, control-char removal, identity preservation, windowTitle).
- [x] `swift test --filter LabanDebugSmokeTests` — 3 new title tests pass: `titleEquals`
  wait without prior state call, title visible in state, title visible in sessions.
- [x] `./scripts/test-e2e` — headless E2E passes via `./scripts/check`; the debug runtime's
  `feedOutput` action injects OSC sequences and observes updated titles in state/sessions.

Review status: PASSED (2026-05-04)

## Context and Orientation

The product boundary is `docs/product/mvp.md`. The relevant MVP text says:
terminal title changes update the tab label and window title; title updates do
not change tab identity, session identity, focus, or ordering; titles are
constrained so a long title cannot overlap controls or resize the sidebar
unexpectedly; terminal output is untrusted.

The relevant source files are:

- `Sources/LabanTerminalCore/session.c` owns libghostty terminal state and
  currently copies `GHOSTTY_TERMINAL_DATA_TITLE` into `LabanSnapshot.title`
  during `laban_session_snapshot`. It does not yet register
  `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` exposes
  `LabanSnapshot.title` as an owned string freed by `laban_snapshot_destroy`;
  it does not yet expose a title dirty/generation/copy helper.
- `Sources/LabanCore/AppModel.swift` owns tabs and sessions. It currently has
  `updateTitle(_:forTab:)`, which changes `Tab.title` while preserving tab ID
  and session ID.
- `Sources/LabanCore/SidebarProducer.swift` renders each tab row as position
  plus `tab.title.prefix(10)`. This prevents gross overlap today, but the
  underlying stored title is not yet bounded by a shared policy.
- `Sources/LabanApp/MainWindowController.swift` creates the AppKit window and
  sets its initial title to `"Laban"`.
- `Sources/LabanApp/TerminalBitmapView.swift` polls sessions and renders the
  active snapshot. It does not currently consume terminal title-change effects
  into the model or update `window?.title`.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` currently copies snapshot
  titles into the model while building `/debug/state`, but `titleEquals` waits
  against cached `Tab.title`. This makes title waits depend on a previous
  debug-state read.
- `fixtures/colored-boxes.fixture.json` already exercises OSC 0 title setting
  through `FixtureRunner`, which writes `ESC ] 0 ; title BEL` bytes.
- `.external/libghostty-vt/include/ghostty/vt/terminal.h` documents
  `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`. The callback fires synchronously from
  `ghostty_terminal_vt_write()`, must stay cheap and non-reentrant, and the new
  title can be queried from the terminal after the callback returns via
  `GHOSTTY_TERMINAL_DATA_TITLE`.
- `docs/reference/prototype-implementation-notes.md` says terminal title
  callbacks are enough to keep tab labels and window titles useful without a
  separate title protocol, and warns that callback userdata must not point at
  moved session storage.

Definitions used in this plan:

- OSC title sequence means terminal output such as `ESC ] 0 ; My Title BEL`.
  libghostty parses that sequence and stores it as terminal title state.
- Cached tab title means `Tab.title` in `AppModel`. It is what the sidebar and
  debug tab response should use after synchronization.
- Display title means the sanitized, bounded string shown in the sidebar and
  window title. It should be nonempty; if the terminal title is empty or
  unusable, use the existing fallback tab title or `"Laban"` for the window.
- Title synchronization means consuming a session-owned title dirty flag or
  generation, querying/copying `GHOSTTY_TERMINAL_DATA_TITLE` through the C
  boundary after a title effect, applying the title policy, and calling
  `AppModel.updateTitle` only when the stored value changes. Snapshot titles
  may remain as fallback and verification data, but they are not the primary
  trigger.

## Plan of Work

First, add a small shared title policy in `LabanCore`. A new file such as
`Sources/LabanCore/TerminalTitle.swift` should expose a helper used by both
AppKit and debug code. It should trim leading and trailing whitespace, remove
ASCII control characters except ordinary spaces, collapse newlines and tabs to
single spaces, cap the result to a small display-safe length such as 80 Swift
characters, and return `nil` for an empty result. The exact cap can be adjusted
if local UI tests prove a different limit is better, but it must be explicit
and tested.

Next, update `AppModel.updateTitle` to apply this policy before storing a
title. Keep identity unchanged. If the sanitized title is empty, leave the
existing tab title unchanged rather than replacing it with an empty string.
Add a helper such as `displayTitle(for:)` or `windowTitle(for:)` if it keeps
window title construction out of AppKit view code.

Then wire the terminal-core title effect. Register
`GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` when creating a session and route userdata
back to the owning `LabanSession`. The callback must do only cheap session-local
work: mark a title dirty flag, advance a generation counter, or both. It must
not call back into Swift, block on locks that can be held around VT writes, or
call `ghostty_terminal_vt_write()` on the same terminal. After the callback
returns, the C layer can query `GHOSTTY_TERMINAL_DATA_TITLE` and copy it into
session-owned bounded storage when Swift consumes the title update. If session
storage can move, callbacks/userdata must be rebound or the session must store
stable heap-owned callback state.

Expose a narrow C ABI for title updates. The exact shape can follow local
style, but it should let Swift ask whether a title changed since the last
consume and obtain an owned or caller-provided copy of the current terminal
title without requiring a render snapshot. Reasonable shapes include a title
generation accessor plus copy function, or one consume function that returns
whether a title was copied. Keep `LabanSnapshot.title` populated for
inspection, fixture compatibility, and fallback.

Then add one reusable synchronization helper in Swift, either in `AppModel` or
as a small private helper in each runtime if the public API would be premature.
The helper should accept a tab ID and terminal session, consume the title
update from the C boundary, apply the title policy, and update the model only
when the resulting title differs from the cached title. It must not select
tabs, reorder tabs, recreate sessions, close sessions, mark sessions rendered,
or require a render snapshot.

Update AppKit behavior in `TerminalBitmapView.advanceFrame()`. The frame loop
already polls all sessions and snapshots the active session for rendering.
After polling each session, consume any pending title update before building
sidebar commands, so the current frame's sidebar uses the new title without
making title correctness depend on snapshot creation. For the active session,
continue snapshotting for rendering as usual. For background tabs, consume
title updates after polling without marking the session rendered. After
selecting a tab or updating a title, set `window?.title` to the active tab
display title, falling back to `"Laban"`. Keep `renderInvalidated` true when a
title change affects visible UI.

Update headless debug behavior in `HeadlessDebugRuntime`. Add a private
`syncTitlesUnlocked()` that polls sessions and consumes title updates
consistently before state responses, session responses, `titleEquals` waits,
and actions that may advance frames. This avoids the current state where
`/debug/state` mutates titles but `titleEquals` can read stale `Tab.title`.
Only fall back to snapshot title reads if the explicit title update path is
unavailable for an older fixture or test harness path.

Add tests. In `LabanCoreTests`, cover title policy behavior: normal titles are
preserved, control characters are removed or converted, very long titles are
bounded, empty titles do not replace an existing tab title, and
`updateTitle` preserves tab ID and session ID. In `LabanDebugSmokeTests`, use
a fixture or direct `typeText`/`feedOutput` path to emit an OSC title sequence,
then assert `/debug/state`, `/debug/sessions`, and `/debug/wait` with
`titleEquals` observe the title without needing an extra state read first.
If practical, add an AppKit-target unit test for the window title formatting
helper without launching a real window.

Finally, update the umbrella MVP plan after implementation lands by adding a
checked progress bullet for title handling and recording validation evidence.

## Concrete Steps

Run all commands from `/Users/dev/wrk/laban`.

1. Confirm the current baseline:

   ```sh
   git status --short --branch
   git log -1 --oneline
   ```

   Expect a clean `main` worktree before editing.

2. Add the shared title policy and unit tests:

   ```sh
   swift test --filter LabanCoreTests
   ```

   Expect tests for title bounding, cleanup, fallback, and identity
   preservation.

3. Register the terminal title-change effect and expose the narrow C title
   update API:

   ```sh
   swift test --filter LabanTerminalCoreTests
   ```

   If there is no matching test target yet, add focused coverage in the
   nearest existing terminal-core test target or through debug smoke tests that
   prove a title change is observable without creating a render snapshot.

4. Wire AppKit title synchronization and window title updates:

   ```sh
   swift test --filter LabanAppTests
   ```

   If no AppKit unit can exercise the window title path directly, keep the
   title formatting helper tested and rely on the E2E/debug fixture for
   runtime title updates.

5. Wire headless debug title synchronization and tests:

   ```sh
   swift test --filter LabanDebugSmokeTests
   ```

   Expect title changes to be observable by `/debug/state`, `/debug/sessions`,
   and `/debug/wait` without relying on an unrelated state read first.

6. Run the full gate:

   ```sh
   ./scripts/check
   ```

   Expect `check passed`.

## Validation and Acceptance

This plan is complete when:

- An OSC title sequence updates the active AppKit tab label and macOS window
  title on the next session poll/title-sync cycle.
- A title sequence emitted by a background tab updates that tab's sidebar label
  without selecting, restarting, reordering, or destroying the tab/session.
- Long or control-character-heavy titles are bounded and normalized before
  storage in `AppModel`.
- Empty terminal titles do not erase the current useful tab label.
- `/debug/state` and `/debug/sessions` report synchronized titles.
- `/debug/wait` with `condition.kind == "titleEquals"` can observe a title
  change without requiring a prior `/debug/state` request.
- Existing tests plus the new focused tests pass.
- `./scripts/check` exits 0 and prints `check passed`.

## Idempotence and Recovery

The changes are source and test edits only. They are safe to retry. If title
handling seems stale in debug, inspect whether the terminal-core title callback
is registered, whether the dirty/generation state is consumed before reading
`Tab.title`, and whether userdata still points at live session storage. If
AppKit title updates do not appear, verify `TerminalBitmapView.advanceFrame()`
consumes title updates after polling sessions, sets `window?.title` after
synchronizing the active title, and invalidates visible UI when a title changes.
If a long title still overlaps controls, adjust the shared bound or sidebar
display cap and update tests accordingly.

Do not implement shell integration markers, OSC 133, profile mutation,
terminal-driven clipboard writes, or window automation in this shard.

## Interfaces and Dependencies

Use existing repository dependencies only. The implementation should rely on:

- libghostty-vt title parsing exposed through
  `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` and `GHOSTTY_TERMINAL_DATA_TITLE`;
- a narrow `LabanTerminalCore` title dirty/generation/copy ABI that owns copied
  title bytes across the C/Swift boundary;
- `LabanSnapshot.title` as verification/fallback data;
- `AppModel.updateTitle` and `Tab.title` for app-owned cached title state;
- `SidebarProducer` for tab label rendering;
- AppKit `NSWindow.title` for the active window title;
- existing debug state/session/wait endpoints for headless verification.

No new package dependency, database, or persistent title store is required.
