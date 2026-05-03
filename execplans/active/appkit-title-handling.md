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
titles into tab state. The user-visible gap is that the visible AppKit window
still starts with a fixed `"Laban"` title and title synchronization is not a
deliberate, bounded behavior shared by AppKit and headless debug.

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
  `GHOSTTY_TERMINAL_DATA_TITLE` into `LabanSnapshot.title`;
  `Sources/LabanCore/AppModel.swift` has `updateTitle(_:forTab:)` and a unit
  test proving identity is preserved; `Sources/LabanDebug/HeadlessDebugRuntime.swift`
  updates titles during `/debug/state` but `titleEquals` checks only cached tab
  state; `Sources/LabanApp/MainWindowController.swift` sets `window.title =
  "Laban"` once; `Sources/LabanApp/TerminalBitmapView.swift` does not update
  the AppKit window title or tab titles from render snapshots.
- [ ] Add a shared title policy that bounds, normalizes, and falls back from
  terminal-provided titles.
- [ ] Synchronize titles from session snapshots during AppKit and headless
  polling without relying on unrelated debug reads.
- [ ] Update the AppKit window title whenever the active tab title changes or
  tab selection changes.
- [ ] Add focused unit, debug, and E2E coverage for active and background title
  changes, identity preservation, and bounding.
- [ ] Update the umbrella MVP plan after the implementation lands.

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

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [ ] Run `./scripts/check` from `/Users/rrj/wrk/laban`; expect exit 0 and
  final output `check passed`.
- [ ] Grep `Sources/LabanCore`; expect a shared title helper or policy that
  bounds terminal titles and removes control characters before storing them.
- [ ] Grep `Sources/LabanApp/TerminalBitmapView.swift`; expect title
  synchronization from session snapshots into `AppModel` and an AppKit
  `window?.title` update for the active tab.
- [ ] Grep `Sources/LabanDebug/HeadlessDebugRuntime.swift`; expect title
  synchronization before `titleEquals` checks and debug state/session
  responses.
- [ ] Run `swift test --filter LabanCoreTests`; expect tests proving title
  bounding, empty-title fallback, control-character removal, and identity
  preservation.
- [ ] Run `swift test --filter LabanDebugSmokeTests`; expect tests proving a
  fixture/debug title update changes tab/session state and satisfies
  `titleEquals` without requiring a prior `/debug/state` read.
- [ ] Run `./scripts/test-e2e`; expect a headless flow that emits an OSC title
  and observes the updated title in `/debug/state` or `/debug/sessions`.

Review status: NOT REVIEWED

## Context and Orientation

The product boundary is `docs/product/mvp.md`. The relevant MVP text says:
terminal title changes update the tab label and window title; title updates do
not change tab identity, session identity, focus, or ordering; titles are
constrained so a long title cannot overlap controls or resize the sidebar
unexpectedly; terminal output is untrusted.

The relevant source files are:

- `Sources/LabanTerminalCore/session.c` owns libghostty terminal state and
  copies `GHOSTTY_TERMINAL_DATA_TITLE` into `LabanSnapshot.title` during
  `laban_session_snapshot`.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` exposes
  `LabanSnapshot.title` as an owned string freed by `laban_snapshot_destroy`.
- `Sources/LabanCore/AppModel.swift` owns tabs and sessions. It currently has
  `updateTitle(_:forTab:)`, which changes `Tab.title` while preserving tab ID
  and session ID.
- `Sources/LabanCore/SidebarProducer.swift` renders each tab row as position
  plus `tab.title.prefix(10)`. This prevents gross overlap today, but the
  underlying stored title is not yet bounded by a shared policy.
- `Sources/LabanApp/MainWindowController.swift` creates the AppKit window and
  sets its initial title to `"Laban"`.
- `Sources/LabanApp/TerminalBitmapView.swift` polls sessions and renders the
  active snapshot. It does not currently read `snap.pointee.title` into the
  model or update `window?.title`.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` currently copies snapshot
  titles into the model while building `/debug/state`, but `titleEquals` waits
  against cached `Tab.title`. This makes title waits depend on a previous
  debug-state read.
- `fixtures/colored-boxes.fixture.json` already exercises OSC 0 title setting
  through `FixtureRunner`, which writes `ESC ] 0 ; title BEL` bytes.

Definitions used in this plan:

- OSC title sequence means terminal output such as `ESC ] 0 ; My Title BEL`.
  libghostty parses that sequence and stores it as terminal title state.
- Cached tab title means `Tab.title` in `AppModel`. It is what the sidebar and
  debug tab response should use after synchronization.
- Display title means the sanitized, bounded string shown in the sidebar and
  window title. It should be nonempty; if the terminal title is empty or
  unusable, use the existing fallback tab title or `"Laban"` for the window.
- Title synchronization means polling or snapshotting sessions, reading
  `LabanSnapshot.title`, applying the title policy, and calling
  `AppModel.updateTitle` only when the stored value changes.

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

Then add one reusable synchronization helper in Swift, either in `AppModel` or
as a small private helper in each runtime if the public API would be premature.
The helper should accept a tab ID and a snapshot, read `snapshot.title`, apply
the title policy, and update the model only when the resulting title differs
from the cached title. It must not select tabs, reorder tabs, recreate
sessions, close sessions, or mark sessions rendered.

Update AppKit behavior in `TerminalBitmapView.advanceFrame()`. The frame loop
already polls all sessions and snapshots the active session for rendering.
After snapshotting the active session, synchronize its title into `AppModel`
before building sidebar commands, so the current frame's sidebar uses the new
title. For background tabs, after polling, if a background session is dirty or
has just produced output, snapshot it only enough to synchronize title state;
do not call `markRendered()` on background sessions. After selecting a tab or
updating a title, set `window?.title` to the active tab display title, falling
back to `"Laban"`. Keep `renderInvalidated` true when a title change affects
visible UI.

Update headless debug behavior in `HeadlessDebugRuntime`. Add a private
`syncTitlesUnlocked()` that polls or snapshots sessions consistently before
state responses, session responses, `titleEquals` waits, and actions that may
advance frames. This avoids the current state where `/debug/state` mutates
titles but `titleEquals` can read stale `Tab.title`.

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

Run all commands from `/Users/rrj/wrk/laban`.

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

3. Wire AppKit title synchronization and window title updates:

   ```sh
   swift test --filter LabanAppTests
   ```

   If no AppKit unit can exercise the window title path directly, keep the
   title formatting helper tested and rely on the E2E/debug fixture for
   runtime title updates.

4. Wire headless debug title synchronization and tests:

   ```sh
   swift test --filter LabanDebugSmokeTests
   ```

   Expect title changes to be observable by `/debug/state`, `/debug/sessions`,
   and `/debug/wait` without relying on an unrelated state read first.

5. Run the full gate:

   ```sh
   ./scripts/check
   ```

   Expect `check passed`.

## Validation and Acceptance

This plan is complete when:

- An OSC title sequence updates the active AppKit tab label and macOS window
  title on the next render/poll cycle.
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
handling seems stale in debug, inspect whether the code path calls the shared
title synchronization helper before reading `Tab.title`. If AppKit title
updates do not appear, verify `TerminalBitmapView.advanceFrame()` actually
sets `window?.title` after synchronizing the active title and that a title
change invalidates rendering. If a long title still overlaps controls, adjust
the shared bound or sidebar display cap and update tests accordingly.

Do not implement shell integration markers, OSC 133, profile mutation,
terminal-driven clipboard writes, or window automation in this shard.

## Interfaces and Dependencies

Use existing repository dependencies only. The implementation should rely on:

- libghostty-vt title parsing exposed through `LabanSnapshot.title`;
- `AppModel.updateTitle` and `Tab.title` for app-owned cached title state;
- `SidebarProducer` for tab label rendering;
- AppKit `NSWindow.title` for the active window title;
- existing debug state/session/wait endpoints for headless verification.

No new package dependency, database, or persistent title store is required.
