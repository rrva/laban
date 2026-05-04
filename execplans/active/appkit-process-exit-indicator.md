# Surface Process Exit State in AppKit

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then make a child process exit visibly reflected in Laban's tab sidebar
and terminal viewport without breaking tab or session identity.

## Purpose / Big Picture

The MVP requires that "if a child process exits, the tab records that state;
the active terminal view shows a non-destructive exited indicator, including
the exit status when known." The C terminal core already tracks exit state
perfectly — it records the raw status and exit code the moment `waitpid`
returns. But nothing in Swift reads that state and surfaces it to the user.

After this change, when a shell or command exits:

- The tab's sidebar row changes appearance (dimmed text and a stop marker
  prefix "⏹ ") so the user knows that session has ended.
- If that tab is active, the terminal viewport shows a one-row banner at the
  bottom of the content area: "Process exited 0" (or "Process signaled 15",
  etc.) in a muted color, overlaid non-destructively on top of the terminal
  output.
- The debug API's tab status field is populated from the Swift tab model
  rather than from a per-tab render snapshot, eliminating one unnecessary
  allocation per frame.

## Progress

- [x] Create ExecPlan (this file).
- [x] Add `LabanExitState` struct and `laban_session_exit_state()` C ABI to
  `LabanTerminalCore.h` and `session.c`.
- [x] Add `TabStatus` enum in `Tab.swift` and `Tab.status: TabStatus` field.
- [x] Add `Session.exitState() -> TabStatus` in `Session.swift`.
- [x] Add `AppModel.syncExitState(forTab:from:)` in `AppModel.swift`.
- [x] Call `model.syncExitState` for all tabs in
  `TerminalBitmapView.advanceFrame()`.
- [x] Render exit marker in `SidebarProducer` for exited tabs.
- [x] Render exit banner overlay in `FrameProducer` when snapshot status != 0.
- [x] Wire `TabResponse.status` from `tab.status` in
  `HeadlessDebugRuntime.stateUnlocked()` and `sessions()`.
- [x] Write unit tests in `LabanCoreTests`: AppModel, SidebarProducer,
  FrameProducer.
- [x] Write integration test using a real PTY that exits.
- [x] Run `./scripts/check` and confirm `check passed`.

## Decision Log

- Decision: Surface `TabStatus` from a lightweight C function, not from a full
  render snapshot.
  Rationale: `FrameProducer` already takes a snapshot of the active tab for
  rendering. Taking a full snapshot of every background tab per frame just to
  read two integers is wasteful. A small `laban_session_exit_state()` function
  reads `s->status` and `s->exit_status` directly from session storage without
  going through the render pipeline.
  Date/Author: 2026-05-04 / Codex.

- Decision: Use one shared type (`TabStatus`) for both session exit state and
  tab exit state. `Session.exitState()` returns `TabStatus` directly; the
  `Tab.status` field is also `TabStatus`. This eliminates the translation
  switch that would otherwise appear in `syncExitState`.
  Rationale: `SessionStatus` and `TabStatus` would be structurally identical
  enums — the translation between them is pure ceremony. Sharing one type
  localizes the mapping to one file (`Tab.swift`) and keeps `syncExitState`
  to a single assignment.
  Date/Author: 2026-05-04 / Codex.

- Decision: `TabStatus.exitedSignal(signal:)` maps to the debug API string
  `"exited"`, not `"signaled"`.
  Rationale: `snapshotStatus()` in `HeadlessDebugRuntime` already maps C
  `status` values 1 and 2 to "exited". Matching that string in `TabStatus`'s
  mapping avoids breaking existing `sessionStatus` wait conditions in debug
  tests. The human-visible UI banner can still display distinct text
  ("Process signaled N") without altering the programmatic API.
  Date/Author: 2026-05-04 / Codex.

- Decision: Show the exit banner only when the exited tab is the active
  (visible) tab.
  Rationale: The banner is rendered from `FrameProducer.commands(from:)` which
  is only called for the active snapshot. Background tabs that have exited show
  their exit state in the sidebar. The banner requires snapshot access which is
  not available for background tabs in the normal render path.
  Date/Author: 2026-05-04 / Codex.

- Decision: Sidebar shows dimmed label + "⏹ " prefix for exited tabs,
  regardless of whether they are currently active.
  Rationale: The active/inactive distinction remains (blue accent bar for
  active), but the text foreground uses `Theme.CurrentTheme.dim0` for any
  exited tab. The "⏹" glyph is a widely-available Unicode stop symbol that
  fits a single sidebar cell. No sidebar width or layout change is needed.
  Date/Author: 2026-05-04 / Codex.

- Decision: Exit state is monotonic — `Tab.status` only advances from
  `.running` to an exited state, never backward.
  Rationale: A child process cannot un-exit. `syncExitState` short-circuits
  when `tab.status != .running`, so a stale poll result cannot reset a
  recorded exit state.
  Date/Author: 2026-05-04 / Codex.

- Decision: The exit banner at `y = originY` intentionally overlays the last
  terminal row.
  Rationale: When a child exits the terminal content is static — no further
  output arrives. The last row is typically a final prompt or blank line.
  Overlaying it with the exit message is "non-destructive" in the sense that
  terminal state (scrollback, cells) is untouched; the visual occlusion is
  acceptable. Reserving a row by shrinking the terminal dimensions or placing
  the banner outside the terminal area would require plumbing that adds
  complexity out of proportion to the MVP goal.
  Date/Author: 2026-05-04 / Codex.

- Decision: `AppModel.syncExitState` is tested via an integration test using
  a real PTY (`/bin/sh -c "exit 7"`), not via a synthetic state-injection
  helper.
  Rationale: Fixture sessions never exit, so the only way to exercise the
  full `poll → exit detection → syncExitState` chain without a real PTY is to
  add test-only state setters that would leak into the production API. The
  integration test pattern already exists in `LabanSessionTests.swift`
  (`testRealShellSmokeOkOutput`). That pattern is the right vehicle.
  Date/Author: 2026-05-04 / Codex.

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. See the "Review gate and review-fix loop"
section in `PLANS.md` for the full process.

- [ ] Run `./scripts/check` from `/Users/rrj/wrk/laban`; expect exit 0 and
  `check passed` in stdout.
- [ ] `LabanTerminalCore.h` declares `LabanExitState` struct (two `int` fields:
  `status`, `exit_status`) and `laban_session_exit_state()`; `session.c`
  implements it reading `s->status` and `s->exit_status` directly.
- [ ] `Sources/LabanCore/Tab.swift` defines `TabStatus` with three cases:
  `.running`, `.exited(code: Int)`, `.exitedSignal(signal: Int)`; `Tab.status`
  defaults to `.running`; `Session.exitState()` returns `TabStatus` (same type,
  no translation enum).
- [ ] `Sources/LabanCore/AppModel.swift` defines `syncExitState(forTab:from:)`
  that short-circuits when `tab.status != .running`.
- [ ] `Sources/LabanCore/SidebarProducer.swift` uses `dim0` foreground for
  exited tabs and prepends "⏹ " to their label text.
- [ ] `Sources/LabanCore/FrameProducer.swift` appends a banner rect at
  `y = originY` and a glyph run showing exit text when
  `snap.pointee.status != 0`.
- [ ] `Sources/LabanDebug/HeadlessDebugRuntime.swift` `stateUnlocked()` and
  `sessions()` populate `TabResponse.status` from `tab.status` converted to a
  string, removing the per-tab snapshot taken solely for status.
- [ ] `swift test --filter LabanCoreTests` passes; new tests cover:
  `AppModel.syncExitState` updates status and is monotonic; `SidebarProducer`
  commands for an exited tab use dim color and include "⏹"; `FrameProducer`
  commands include a banner when snapshot `status != 0` and no banner when 0.
- [ ] At least one integration test using a real PTY (pattern from
  `testRealShellSmokeOkOutput` in `LabanTerminalCoreTests`) runs a shell that
  exits and verifies that `AppModel.tabs[0].status != .running` after polling.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Context and Orientation

The product boundary is `docs/product/mvp.md`. Relevant MVP text:

- "If a child process exits, the tab records that state. The active terminal
  view shows a non-destructive exited indicator, including the exit status when
  known."
- "A tab is app-level state. It has a stable ID, title, status, and a
  reference to one terminal session."

Definitions used in this plan:

- **Terminal core** means the C layer in `Sources/LabanTerminalCore/`. It owns
  the PTY, the libghostty terminal parser, and the render snapshot. It is
  compiled as a separate Swift package target and exposed to Swift via a narrow
  C ABI declared in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`.
- **Session (Swift)** means `Sources/LabanCore/Session.swift`. It wraps the C
  terminal core handle and guards all C calls behind an `isClosed` flag.
- **AppModel** means `Sources/LabanCore/AppModel.swift`. It owns the tab
  array and the session map. It is the single source of truth for tab ordering,
  active tab, and tab titles.
- **Frame command** means a value of type `FrameCommand` (an enum in
  `Sources/LabanRenderer/`). Commands describe drawing operations — rects and
  glyph runs — that a renderer (Metal or software) converts to pixels. Producers
  such as `SidebarProducer` and `FrameProducer` translate model state into
  frame commands.
- **Snapshot** means a `LabanSnapshot` struct that the C layer fills with a
  point-in-time copy of the terminal's visible cells, cursor position, colors,
  and exit state. The Swift layer calls `laban_session_snapshot()` to obtain
  one, and must call `laban_snapshot_destroy()` when done.
- **Render loop** means `TerminalBitmapView.advanceFrame()` in
  `Sources/LabanApp/TerminalBitmapView.swift`. It runs at roughly 30 fps,
  polls all sessions, syncs titles, snapshots the active session, builds frame
  commands, and submits them to the renderer.

The relevant source files are:

- `Sources/LabanTerminalCore/session.c` — `laban_session_poll()` calls
  `waitpid()` and sets `s->status` (0=running, 1=exited normally,
  2=exited by signal) and `s->exit_status` when the child exits.
  `laban_session_snapshot()` copies `s->status` and `s->exit_status` into
  `snap->status` and `snap->exit_status`.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` — declares
  `LabanSnapshot` with `int status` and `int exit_status` fields.
  The comment block above those fields documents the three status values.
  Does not yet have a lightweight exit-state query.
- `Sources/LabanCore/Session.swift` — wraps the C handle, has `poll()`,
  `snapshot()`, `consumeTitle()`, and related methods. All methods guard with
  `isClosed`. Does not yet have `exitState()`.
- `Sources/LabanCore/Tab.swift` — defines `AppError` and `Tab`. `Tab` has
  `id`, `position`, `title`, `isActive`, and `sessionId`. Does not yet have
  a `status` field.
- `Sources/LabanCore/AppModel.swift` — has `syncTitle(forTab:from:)` as a
  model of the pattern to follow. `syncExitState` does not yet exist.
- `Sources/LabanCore/SidebarProducer.swift` — at line ~81 builds each tab
  label as `"\(tab.position) \(tab.title.prefix(10))"` using `fg` (which is
  already `dim0` for inactive tabs). Does not check `tab.status`.
- `Sources/LabanCore/FrameProducer.swift` — `commands(from:selection:)` builds
  the terminal grid from a snapshot. Does not yet add an exit banner.
- `Sources/LabanApp/TerminalBitmapView.swift` — `advanceFrame()` polls
  sessions, calls `model.syncTitle` for each tab, then snapshots and renders
  the active tab. Does not yet call `model.syncExitState`.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` — `stateUnlocked()` (line
  ~376) and `sessions()` (line ~774) currently take a full snapshot per tab to
  populate `TabResponse.status`. `snapshotStatus()` (line 289) maps status
  1 and 2 to the string `"exited"` and 0 to `"running"`.
- `Sources/LabanDebug/DebugModels.swift` — `TabResponse` has
  `status: String`; `SessionResponse` has `status: String` and
  `exitStatus: Int?`.
- `Sources/LabanRenderer/Theme.swift` — `Theme.CurrentTheme.dim0` is
  `0x72898FFF` (muted teal); `Theme.CurrentTheme.bg1` is `0x174956FF`
  (slightly lighter than the terminal background); `Theme.CurrentTheme.red` is
  `0xFA5750FF`.
- `Tests/LabanCoreTests/AppModelTests.swift` — follow the existing
  `makeModel()` / fixture factory pattern for new AppModel tests.
- `Tests/LabanCoreTests/SidebarProducerTests.swift` — constructs `Tab` structs
  directly and calls `p.commands(tabs:activeTabId:height:)`.
- `Tests/LabanCoreTests/FrameProducerTests.swift` — uses real fixture sessions
  and snapshots; pattern: create session, write bytes, snapshot, inspect
  commands.
- `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` — `testRealShellSmokeOkOutput`
  runs `/bin/sh -lc "printf 'ok\n'"`, polls until `s.pointee.status != 0`
  with a deadline, then checks `s.pointee.status == 1`. Reuse this pattern for
  an integration test through `AppModel`.

## Plan of Work

### Step 1 — Lightweight C exit-state query

Add to `Sources/LabanTerminalCore/include/LabanTerminalCore.h` a new struct
`LabanExitState` and a function `laban_session_exit_state`:

```c
typedef struct LabanExitState {
  int status;      /* same values as LabanSnapshot.status */
  int exit_status; /* same values as LabanSnapshot.exit_status */
} LabanExitState;

LabanExitState laban_session_exit_state(LabanSessionHandle handle);
```

Implement in `Sources/LabanTerminalCore/session.c`:

```c
LabanExitState laban_session_exit_state(LabanSessionHandle handle) {
  LabanSession *s = (LabanSession *)handle;
  LabanExitState r = { s->status, s->exit_status };
  return r;
}
```

This function reads two integers. It does not render, does not allocate, and
does not require the Swift caller to free anything.

### Step 2 — TabStatus enum (shared by Session and Tab)

In `Sources/LabanCore/Tab.swift`, add `TabStatus` before the `Tab` struct.
This one enum is used for both `Session.exitState()` return values and
`Tab.status` storage — no translation between two identical types is needed.

```swift
public enum TabStatus: Equatable {
  case running
  case exited(code: Int)
  case exitedSignal(signal: Int)

  public var debugString: String {
    switch self {
    case .running: return "running"
    case .exited: return "exited"
    case .exitedSignal: return "exited"
    }
  }
}
```

Add `public var status: TabStatus = .running` to `Tab`. Because `Tab` is a
struct, existing call sites that name all fields explicitly will need
`status: .running`; sites that rely on the memberwise initializer's default
will compile unchanged. Check `Tests/` for explicit `Tab(` constructions and
add the default or named argument as needed.

### Step 3 — Session.exitState() returning TabStatus

In `Sources/LabanCore/Session.swift`, add a method (alongside `poll()`,
`consumeTitle()`, etc.):

```swift
public func exitState() -> TabStatus {
  guard !isClosed, let h = handle else { return .running }
  let raw = laban_session_exit_state(h)
  switch raw.status {
  case 1: return .exited(code: Int(raw.exit_status))
  case 2: return .exitedSignal(signal: Int(raw.exit_status))
  default: return .running
  }
}
```

When `isClosed` is true, returning `.running` is safe because
`AppModel.syncExitState` short-circuits on the monotonic guard before calling
`exitState()` on a closed session.

### Step 4 — AppModel.syncExitState

In `Sources/LabanCore/AppModel.swift`, add a method parallel to `syncTitle`:

```swift
/// Read exit state from the session and record it in the tab.
/// Returns true if the tab status changed.
/// Exit state is monotonic: once exited, this method is a no-op.
@discardableResult
public func syncExitState(forTab tabId: Tab.ID, from session: Session) -> Bool {
  guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
  guard tabs[idx].status == .running else { return false }
  let s = session.exitState()
  guard s != .running else { return false }
  tabs[idx].status = s
  return true
}
```

### Step 5 — Wire advanceFrame()

In `Sources/LabanApp/TerminalBitmapView.swift`, in the section of
`advanceFrame()` that polls each session and calls `model.syncTitle`, add:

```swift
model.syncExitState(forTab: tab.id, from: session)
```

Place it immediately after `model.syncTitle(forTab:from:)` for each tab. The
render-invalidated flag should be set to `true` when the call returns `true`
(a status change affects sidebar appearance and possibly the terminal banner).

### Step 6 — SidebarProducer exit marker

In `Sources/LabanCore/SidebarProducer.swift`, change the label-building block
for each tab row. Currently:

```swift
let label = "\(tab.position) \(tab.title.prefix(10))"
```

Change to:

```swift
let prefix = tab.status == .running ? "" : "⏹ "
let label = "\(tab.position) \(prefix)\(tab.title.prefix(10))"
```

Also change the foreground color selection so that any exited tab uses `dim0`
regardless of active/inactive state:

```swift
let fg: UInt32 = tab.status != .running
  ? Theme.CurrentTheme.dim0
  : (isActive ? Theme.CurrentTheme.fg0 : Theme.CurrentTheme.dim0)
```

Note: inactive tabs already use `dim0`; only active tabs with running status
get `fg0`. The active blue accent bar still renders for the selected tab.

### Step 7 — FrameProducer exit banner

In `Sources/LabanCore/FrameProducer.swift`, at the end of
`commands(from:selection:)`, append a banner when `snapshot.status != 0`.
The banner is one row tall, placed at the bottom of the terminal area
(`y = originY`), spanning the full width. The text is centered or
left-aligned at a small left inset.

```swift
if snapshot.status != 0 {
  let bannerY = originY
  let bannerW = CGFloat(cols) * cw
  let bannerH = ch
  cmds.append(.rect(
    CGRect(x: originX, y: bannerY, width: bannerW, height: bannerH),
    color: Theme.CurrentTheme.bg1,
    source: .terminal
  ))
  let exitText: String
  switch snapshot.status {
  case 1: exitText = "Process exited \(snapshot.exit_status)"
  case 2: exitText = "Process signaled \(snapshot.exit_status)"
  default: exitText = "Process exited"
  }
  cmds.append(.glyphRun(
    origin: CGPoint(x: originX + 4, y: bannerY + 2),
    text: exitText,
    foreground: Theme.CurrentTheme.dim0,
    background: Theme.CurrentTheme.bg1,
    source: .terminal
  ))
}
```

The banner is non-destructive: it overlays the last terminal row visually but
does not alter the snapshot cells or scrollback state.

### Step 8 — Debug server: TabResponse.status from tab model

In `Sources/LabanDebug/HeadlessDebugRuntime.swift`, update `stateUnlocked()`
and `sessions()` to populate `TabResponse.status` from `tab.status.debugString`
instead of taking a full snapshot per tab. The `SessionResponse.status` and
`exitStatus` fields still require a snapshot and remain unchanged.

In `stateUnlocked()`, replace the snapshot-per-tab block:

```swift
// Before:
var statusStr = "running"
if let session = model.session(forTab: tab.id),
  let snap = session.snapshot()
{
  defer { laban_snapshot_destroy(snap) }
  statusStr = snapshotStatus(UnsafePointer(snap))
} else {
  statusStr = "failed"
}
return TabResponse(id: tab.id, index: i, title: tab.title,
  active: tab.isActive, status: statusStr, sessionId: tab.sessionId)

// After:
let tabStatus = model.session(forTab: tab.id) != nil
  ? tab.status.debugString
  : "failed"
return TabResponse(id: tab.id, index: i, title: tab.title,
  active: tab.isActive, status: tabStatus, sessionId: tab.sessionId)
```

Apply the same change in the `sessions()` method for `TabResponse`.

Note: `SessionResponse` still reads status from a snapshot. That is correct
because `SessionResponse` includes `exitStatus: Int?` which requires a
snapshot.

After this change, `snapshotStatus()` is used only by the `SessionResponse`
path and the `sessionStatus` wait condition. Do not remove it.

### Step 9 — Tests

**AppModel monotonicity test** (add to `Tests/LabanCoreTests/AppModelTests.swift`):

The monotonic guard is the one AppModel property worth a pure unit test.
Because fixture sessions always return `.running` from `exitState()`, directly
testing `syncExitState` requires either a real PTY (see integration test below)
or a small internal setter. Add one `internal func forceExitState(forTab tabId: Tab.ID, status: TabStatus)` (not public) in `AppModel.swift` for test use, then mark it `@testable` accessible:

- `testSyncExitStateIsMonotonic`: Call `model.forceExitState(forTab:status:.exited(code:0))`,
  then verify a subsequent `syncExitState(forTab:from:)` with a real fixture
  session returns `false` and `tab.status` is still `.exited(code: 0)`.

**SidebarProducer tests** (in `Tests/LabanCoreTests/SidebarProducerTests.swift`):

- `testExitedTabUsesdimForeground`: Build a `Tab` with `status: .exited(code: 0)`
  and verify the glyph run foreground color equals `Theme.CurrentTheme.dim0`.
- `testExitedTabLabelHasStopPrefix`: Verify the glyph run text contains "⏹".
- `testRunningActiveTabUsesNormalForeground`: Verify a running active tab uses
  `Theme.CurrentTheme.fg0`.

**FrameProducer tests** (in `Tests/LabanCoreTests/FrameProducerTests.swift`):

- `testNoBannerWhenRunning`: Produce commands from a running snapshot
  (`status = 0`) and verify no command has a `glyphRun` containing "exited"
  or "signaled".
- `testBannerWhenExitedNormal`: Produce commands from a snapshot with
  `status = 1, exit_status = 0`. Verify the command list contains a `.rect`
  at `y = originY` and a `.glyphRun` with text containing "Process exited 0".
- `testBannerWhenExitedSignal`: Same but `status = 2, exit_status = 15`.
  Verify text contains "Process signaled 15".

Constructing a synthetic snapshot for FrameProducer tests: initialize a
`LabanSnapshot` value with `status = 1` (or 2) and the other fields set to
safe defaults (null cells pointer, rows/cols = 0 is acceptable since the
banner code runs after the cells loop).

**Integration test** (in `Tests/LabanTerminalCoreTests/` or
`Tests/LabanCoreTests/`):

Follow the pattern from `testRealShellSmokeOkOutput` in
`LabanTerminalCoreTests/LabanSessionTests.swift`:

```swift
func testAppModelRecordsExitState() throws {
  // Use the real PTY path with a short-lived command.
  // AppModel.init with a real-session factory (not fixture).
  // After polling, tab.status must be .exited(code:).
}
```

Because `AppModel` uses a session factory closure, you can pass the real
`Session.init(size:shellPath:)` factory. Run `/bin/sh -c "exit 7"` (or
equivalent), poll until the session exits (with deadline), then assert
`model.tabs[0].status == .exited(code: 7)`.

## Concrete Steps

Run all commands from `/Users/rrj/wrk/laban`.

1. Confirm baseline:

   ```sh
   git status --short --branch
   ./scripts/check
   ```

   Expect clean worktree and `check passed`.

2. Add C ABI in `LabanTerminalCore.h` and `session.c`, then build:

   ```sh
   swift build 2>&1 | tail -5
   ```

   Expect zero errors.

3. Add `SessionStatus` + `Session.exitState()`, then build:

   ```sh
   swift build 2>&1 | tail -5
   ```

4. Add `TabStatus` + `Tab.status`, then build:

   ```sh
   swift build 2>&1 | tail -5
   ```

5. Add `AppModel.syncExitState`, then run existing model tests:

   ```sh
   swift test --filter LabanCoreTests 2>&1 | tail -10
   ```

   Expect all existing tests pass.

6. Wire `TerminalBitmapView.advanceFrame()`, then build:

   ```sh
   swift build 2>&1 | tail -5
   ```

7. Update `SidebarProducer` and add sidebar exit-marker tests:

   ```sh
   swift test --filter LabanCoreTests 2>&1 | tail -10
   ```

8. Update `FrameProducer` and add banner tests:

   ```sh
   swift test --filter LabanCoreTests 2>&1 | tail -10
   ```

9. Update `HeadlessDebugRuntime` debug server; add integration test:

   ```sh
   swift test 2>&1 | tail -20
   ```

10. Run the full gate:

    ```sh
    ./scripts/check
    ```

    Expect `check passed`.

## Validation and Acceptance

This plan is complete when:

- A shell command that exits (e.g., via `exit 7`) causes `AppModel` to record
  `tab.status == .exited(code: 7)` after the next frame poll.
- The sidebar row for an exited tab shows "⏹ " prefix and `dim0` foreground.
- The active terminal view shows "Process exited N" (or "Process signaled N")
  in a `bg1` banner at the bottom of the terminal content area.
- The banner does not appear when the session is still running.
- `TabResponse.status` in debug API responses reflects the model's tab status
  without requiring a per-tab render snapshot in `stateUnlocked()`.
- `syncExitState` is idempotent: a second call with the same or a different
  status does not change `tab.status` once it is non-running.
- `./scripts/check` exits 0 and prints `check passed`.
- New tests: at least 3 SidebarProducer tests, 3 FrameProducer tests,
  1 AppModel integration test with a real PTY.

## Idempotence and Recovery

All changes are source edits only. They are safe to retry. If the banner
appears when the session is running, verify that `snap.pointee.status != 0`
is the guard condition (not `!= 1`). If the sidebar does not show the stop
marker, verify that `tab.status` is being set by `syncExitState` in
`advanceFrame()` before `SidebarProducer.commands` is called. If debug tests
regress, verify that `TabResponse.status` uses `tab.status.debugString` and
that the mapping matches `snapshotStatus()` ("exited" for both status 1 and 2).

Do not add shell integration markers, close confirmations, or multi-window
handling in this plan.

## Interfaces and Dependencies

Use existing repository dependencies only:

- `laban_session_exit_state()` — new narrow C ABI; no render, no allocation.
- `Session.exitState() -> SessionStatus` — Swift wrapper; returns `.running`
  when closed.
- `Tab.status: TabStatus` — stored app-layer exit state; defaults `.running`.
- `AppModel.syncExitState(forTab:from:)` — monotonic update from session
  to tab; returns Bool.
- `Theme.CurrentTheme.dim0`, `Theme.CurrentTheme.bg1` — Selenized colors for
  banner and exited tab label.
- `FrameCommand.rect` and `FrameCommand.glyphRun` — existing frame command
  types; no new command types needed.
- `TabStatus.debugString` — maps to `"running"` / `"exited"` for debug API
  backward compatibility.
