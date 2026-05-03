# Add Mouse Input And Scrollback Routing

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then add MVP mouse and scrollback behavior without relying on
prior conversation.

## Purpose / Big Picture

Laban can open a shell, render terminal output, accept keyboard input, expose a
headless debug server, and avoid wasting CPU on idle redraws. The next visible
MVP gap is pointer behavior: wheel input does not scroll terminal scrollback,
and mouse events are not delivered to terminal programs that enable mouse
tracking.

After this change, a user can scroll a normal shell transcript with the mouse
wheel. When a terminal app enables mouse reporting, clicks, drags, and wheel
events are encoded through libghostty's mouse encoder and written to the PTY
instead of starting local text selection or scrolling local scrollback. Agents
can verify both paths through `/debug/actions`, `/debug/sessions`,
`/debug/wait`, and screenshots without desktop automation.

## Progress

- [x] (2026-05-03) Identified mouse and scrollback as the next MVP behavior
  after the debug-server and render-budget shards landed on `main`.
- [x] (2026-05-03) Verified libghostty-vt exposes
  `ghostty_terminal_scroll_viewport`, `GHOSTTY_TERMINAL_DATA_SCROLLBAR`,
  `GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS`,
  `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`, and the mouse encoder APIs in
  `.external/libghostty-vt/include/ghostty/vt/mouse/*.h`.
- [x] Add C session ABI for viewport scrolling, viewport metadata, mouse
  encoding, and mouse event delivery.
- [x] Add Swift wrappers and debug runtime actions for `mouseWheel`, `click`,
  and `scrollViewport`.
- [x] Add AppKit `scrollWheel`, click, release, and drag routing in
  `TerminalBitmapView`.
- [x] Update debug/session state so scrollback rows, viewport offset, and
  mouse-tracking state are real values instead of placeholders.
- [x] Add tests and E2E coverage for normal scrollback and mouse-tracking
  routing.
- [x] Update the umbrella plan and record validation evidence.
- [x] Fix review regressions found after the first mouse-routing patch:
  AppKit/debug mouse positions must be terminal-surface pixels, modifier bits
  must match Ghostty's `shift, ctrl, alt, super` order, and drag motion must
  preserve the held button for DECSET 1002 button-event tracking.
- [x] Add focused tests that fail against the reviewed regression cases and
  pass after the fixes.
- [x] Run focused AppKit, terminal-core, and debug tests plus `./scripts/check`;
  all pass after the review fixes.

## Decision Log

- Decision: Use libghostty-vt for both scrollback viewport changes and mouse
  protocol encoding.
  Rationale: `docs/product/mvp.md` says terminal mouse events should be
  encoded through terminal-core rules when an encoder is available. The checked
  out libghostty-vt headers expose `ghostty_terminal_scroll_viewport` and
  `ghostty_mouse_encoder_setopt_from_terminal`, so Swift should route events
  and provide geometry, not hand-write xterm or SGR mouse escape tables.
  Date/Author: 2026-05-03 / Codex.

- Decision: Keep the first visible scrollback implementation full-frame and
  viewport-based, not a custom Swift scrollback buffer.
  Rationale: Laban already snapshots the libghostty render state and renders
  the visible viewport. Ghostty owns scrollback history and its viewport pin.
  Duplicating scrollback in Swift would risk divergent terminal state and make
  copy, selection, and debug state harder to reason about.
  Date/Author: 2026-05-03 / Codex.

- Decision: Implement direct `scrollViewport` debug action in addition to
  pointer actions.
  Rationale: Direct viewport scrolling gives deterministic headless tests for
  scrollback even when no host OS wheel event exists. Pointer actions still
  prove the route used by AppKit and terminal mouse tracking.
  Date/Author: 2026-05-03 / Codex.

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [ ] Run `./scripts/check` from `/Users/rrj/wrk/laban`; expect exit 0 and
  final output `check passed`.
- [ ] Grep `Sources/LabanTerminalCore/include/LabanTerminalCore.h`; expect
  declarations for `laban_session_scroll_viewport`,
  `laban_session_viewport_state`, `laban_session_encode_mouse`, and
  `laban_session_send_mouse`.
- [ ] Grep `Sources/LabanTerminalCore/session.c`; expect calls to
  `ghostty_terminal_scroll_viewport`,
  `ghostty_mouse_encoder_setopt_from_terminal`, and
  `ghostty_mouse_encoder_encode`.
- [ ] Run `swift test --filter LabanTerminalCoreTests`; expect tests proving
  scrollback can reveal prior lines and mouse encoding returns an SGR mouse
  sequence after enabling mouse tracking.
- [ ] Run `swift test --filter LabanDebugSmokeTests`; expect tests for
  `scrollViewport`, `mouseWheel` normal-mode scrolling, `click` sidebar
  routing, and unsupported/invalid mouse requests.
- [ ] Run `./scripts/test-e2e`; expect checks that normal-mode wheel or direct
  `scrollViewport` changes `/debug/sessions[0].viewportOffset`, and that a
  mouse-tracking fixture records terminal-routed mouse events instead of local
  scrollback changes.
- [ ] Open the AppKit app, produce more output than fits in the viewport, and
  verify the wheel reveals older lines when `mouseTracking` is false.
- [ ] In a terminal app that enables SGR mouse mode, verify mouse wheel or
  click input affects the app rather than local text selection.
- [ ] Run `swift test --filter LabanAppTests`; expect tests proving AppKit
  mouse position helpers return terminal-surface pixels and Ghostty modifier
  bit order.
- [ ] Run `swift test --filter LabanTerminalCoreTests`; expect tests proving
  SGR positions are derived from pixel positions, modifier bits are preserved
  in Ghostty order, and DECSET 1002 drag motion reports the active button.
- [ ] Run `swift test --filter LabanDebugSmokeTests`; expect tests proving
  `/debug/actions` mouse coordinates convert from CG bottom-left `y` to
  top-left terminal-surface `y`.

Review status: NOT REVIEWED

## Context and Orientation

The relevant source files are:

- `Sources/LabanTerminalCore/session.c` owns the C session object,
  libghostty terminal, PTY file descriptor, render state, and snapshot
  extraction. Add low-level mouse and scrollback ABI here.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` is the public C ABI
  used by Swift. Keep Swift out of raw Ghostty types.
- `Sources/LabanCore/Session.swift` wraps C session calls in Swift methods.
- `Sources/LabanApp/TerminalBitmapView.swift` owns AppKit input events and the
  visible terminal bitmap. It already handles keyboard input, local selection,
  sidebar hits, copy, and paste.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` owns headless debug actions
  and state. It currently supports tab, resize, type, paste, screenshot, wait,
  render, and frame-command endpoints. `mouseWheel`, `click`, and
  `scrollViewport` are currently unsupported.
- `schemas/debug/action.schema.json` already defines `mouseWheel`, `click`,
  and `scrollViewport` request shapes.

Definitions used in this plan:

- Scrollback is the terminal history kept above the visible viewport.
  libghostty owns the history and exposes viewport scrolling through
  `ghostty_terminal_scroll_viewport`.
- Viewport is the rows currently visible in the terminal. Scrolling changes
  which historical rows are visible, not the active PTY size.
- Mouse tracking means a terminal mode such as X10, normal, button-event, or
  any-event mouse reporting is enabled by the running terminal app. The
  current boolean is already exposed in `LabanSnapshot.mouse_tracking`.
- Mouse encoder means libghostty's `GhosttyMouseEncoder`, which reads terminal
  mouse mode and format from `ghostty_mouse_encoder_setopt_from_terminal` and
  turns normalized events into terminal escape bytes.
- Surface-space position means x/y coordinates relative to the terminal
  viewport's top-left corner, in the same pixel or logical-pixel units as the
  terminal cell geometry passed to the encoder.

Relevant libghostty-vt APIs in the checked-out dependency:

```c
void ghostty_terminal_scroll_viewport(
  GhosttyTerminal terminal,
  GhosttyTerminalScrollViewport behavior
);

GhosttyResult ghostty_terminal_get(
  GhosttyTerminal terminal,
  GhosttyTerminalData data,
  void *out
);

GhosttyResult ghostty_mouse_encoder_new(
  const GhosttyAllocator *allocator,
  GhosttyMouseEncoder *encoder
);

void ghostty_mouse_encoder_setopt_from_terminal(
  GhosttyMouseEncoder encoder,
  GhosttyTerminal terminal
);

GhosttyResult ghostty_mouse_encoder_encode(
  GhosttyMouseEncoder encoder,
  GhosttyMouseEvent event,
  char *out_buf,
  size_t out_buf_size,
  size_t *out_len
);
```

`GhosttyTerminalScrollViewportValue.delta` uses negative values to scroll up
toward older history and positive values to scroll down toward the active
bottom. libghostty's mouse encoder maps wheel buttons to buttons four and
five; the upstream `mouse_encode.zig` tests identify button four as code 64
and button five as code 65.

## Milestones

### Milestone 1: Terminal Core Scroll And Mouse ABI

Add C ABI that keeps terminal-specific behavior in `LabanTerminalCore`.

Implementation requirements:

- Include the needed Ghostty headers in `Sources/LabanTerminalCore/session.c`:
  `ghostty/vt/mouse.h` or the specific mouse event and encoder headers.
- Extend `struct LabanSession` with a persistent `GhosttyMouseEncoder` and a
  boolean/int tracking whether any mouse button is currently pressed. Free the
  encoder in `free_ghostty_resources`.
- In `LabanTerminalCore.h`, add a small public shape for viewport state:

  ```c
  typedef struct {
      int total_rows;
      int scrollback_rows;
      int viewport_offset;
      int viewport_rows;
      int mouse_tracking;
  } LabanViewportState;
  ```

- Add:

  ```c
  int laban_session_scroll_viewport(LabanSession *session, int delta_rows);
  int laban_session_viewport_state(LabanSession *session, LabanViewportState *out_state);
  ```

  `laban_session_scroll_viewport` should call
  `ghostty_terminal_scroll_viewport` with
  `GHOSTTY_SCROLL_VIEWPORT_DELTA`, mark render state dirty enough for the next
  UI frame, and return `0` for valid sessions. `delta_rows < 0` means older
  history; `delta_rows > 0` means newer history or the active bottom.

  `laban_session_viewport_state` should read
  `GHOSTTY_TERMINAL_DATA_SCROLLBAR`,
  `GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS`, and
  `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`. Map
  `GhosttyTerminalScrollbar.total`, `offset`, and `len` into signed `int`
  values with clamping if needed.

- In `LabanTerminalCore.h`, add mouse event ABI that does not expose Ghostty
  handles:

  ```c
  typedef enum {
      LABAN_MOUSE_ACTION_PRESS = 0,
      LABAN_MOUSE_ACTION_RELEASE = 1,
      LABAN_MOUSE_ACTION_MOTION = 2
  } LabanMouseAction;

  typedef enum {
      LABAN_MOUSE_BUTTON_NONE = 0,
      LABAN_MOUSE_BUTTON_LEFT = 1,
      LABAN_MOUSE_BUTTON_MIDDLE = 2,
      LABAN_MOUSE_BUTTON_RIGHT = 3,
      LABAN_MOUSE_BUTTON_WHEEL_UP = 4,
      LABAN_MOUSE_BUTTON_WHEEL_DOWN = 5
  } LabanMouseButton;

  typedef struct {
      LabanMouseAction action;
      LabanMouseButton button;
      float x;
      float y;
      int screen_width;
      int screen_height;
      int cell_width;
      int cell_height;
      int modifiers;
  } LabanMouseEvent;
  ```

- Add:

  ```c
  int laban_session_encode_mouse(
      LabanSession *session,
      const LabanMouseEvent *event,
      uint8_t *out_bytes,
      size_t out_capacity,
      size_t *out_len
  );

  int laban_session_send_mouse(LabanSession *session, const LabanMouseEvent *event);
  ```

  `encode_mouse` should configure the persistent encoder from the terminal,
  set size from the event geometry, set button state and motion dedupe options,
  create a Ghostty mouse event, map buttons, encode into the caller buffer,
  and return `0` on success. It may return `0` with `out_len == 0` when
  terminal modes say nothing should be reported.

  `send_mouse` should call `encode_mouse` into a bounded stack buffer and
  write produced bytes through the existing session write path. In PTY mode
  that means writing to the PTY master. In fixture mode, tests should prefer
  `encode_mouse`; do not pretend fixture mode has a child process that can
  receive mouse reports.

- Add focused `LabanTerminalCoreTests`:
  - scrollback fixture: create a small fixture terminal, write enough lines to
    push a known line into scrollback, confirm it is not visible, call
    `laban_session_scroll_viewport(session, negativeDelta)`, snapshot, and
    confirm the known line is visible;
  - viewport state: confirm `scrollback_rows` grows after enough output and
    `viewport_offset` changes after scrolling;
  - mouse encoding: write `ESC[?1000h ESC[?1006h` to enable normal SGR mouse
    mode, build a left-button press event inside the terminal viewport, call
    `laban_session_encode_mouse`, and assert the bytes start with `ESC[<`;
  - wheel encoding: with SGR mouse enabled, encode wheel-up and wheel-down
    events and assert they produce different non-empty sequences.

### Milestone 2: Swift Wrappers And Debug Runtime Actions

Make headless debug actions drive the same C paths AppKit will use.

Implementation requirements:

- In `Sources/LabanCore/Session.swift`, add wrappers:

  ```swift
  public struct ViewportState { ... }
  public enum MouseAction { case press, release, motion }
  public enum MouseButton { case none, left, middle, right, wheelUp, wheelDown }
  public struct MouseEvent { ... }

  public func scrollViewport(deltaRows: Int) -> Int32
  public func viewportState() -> ViewportState?
  public func encodeMouse(_ event: MouseEvent) -> [UInt8]?
  public func sendMouse(_ event: MouseEvent) -> Int32
  ```

- Update `Sources/LabanDebug/HeadlessDebugRuntime.swift`:
  - `mouseWheel`: if the target point is inside the sidebar, ignore terminal
    routing and return `ok:true` with a `mouse.sidebar` event. If inside the
    terminal and the active session reports mouse tracking, send wheel events
    through `sendMouse`. If mouse tracking is false, call
    `scrollViewport(deltaRows:)`.
  - `click`: if the point is inside the sidebar, reuse the same hit-test rules
    as AppKit for new/select/close tab. If inside the terminal and mouse
    tracking is true, send press and release mouse events. If mouse tracking
    is false, use click for debug-local selection only if this shard implements
    debug selection; otherwise return `ok:false` with a bounded message that
    local selection is not implemented through debug yet.
  - `scrollViewport`: call `Session.scrollViewport(deltaRows:)` on the named
    `sessionId` if provided, otherwise the active session. Render one frame and
    return `ok:true`.
  - append explicit events such as `mouse.scrolled`, `mouse.sent`,
    `mouse.sidebar`, and `viewport.scrolled`.

- Update session debug responses in `HeadlessDebugRuntime.sessions()` so
  `scrollbackLines`, `viewportOffset`, and `mouseTracking` come from
  `Session.viewportState()` plus snapshots. Stop hardcoding
  `scrollbackLines: 0` and `viewportOffset: 0`.

- Update `/debug/wait` if needed so `condition.kind == "mouseTracking"` or an
  event-kind wait can verify mouse-routed behavior without reading unbounded
  terminal output. If adding a new wait kind, update schemas and tests in the
  same shard.

- Add `LabanDebugSmokeTests`:
  - `scrollViewport` advances the frame and changes session `viewportOffset`
    after scrollback exists;
  - `mouseWheel` in normal mode changes viewport state;
  - `mouseWheel` with mouse tracking enabled records `mouse.sent` and does not
    change viewport offset;
  - `click` in the sidebar new-tab row still creates a tab;
  - invalid mouse coordinates outside window bounds return bounded failures or
    no-op successes consistently.

### Milestone 3: AppKit Mouse And Wheel Routing

Wire visible AppKit events to the same session behavior.

Implementation requirements:

- In `TerminalBitmapView`, add `override func scrollWheel(with event:
  NSEvent)`.
  - Convert the event location to view coordinates.
  - If the point is inside the sidebar, consume it locally and do not send it
    to the terminal.
  - If outside the terminal viewport, ignore it.
  - If the active snapshot or viewport state reports mouse tracking, convert
    the event into wheel-up or wheel-down mouse events and call
    `session.sendMouse`.
  - If mouse tracking is false, convert wheel magnitude to integer rows and
    call `session.scrollViewport(deltaRows:)`, then set `renderInvalidated =
    true`.

- In `mouseDown`, `mouseDragged`, and `mouseUp`, check active mouse tracking
  before starting or extending local selection:
  - sidebar hits remain local and must never reach the terminal;
  - when mouse tracking is true, send press/motion/release events and suppress
    local selection;
  - when mouse tracking is false, keep the existing visible-text selection
    behavior.

- Add helpers in `TerminalBitmapView` instead of duplicating coordinate math:
  - `terminalPoint(from viewPoint:) -> CGPoint?` returning top-left terminal
    coordinates;
  - `mouseEvent(...) -> Session.MouseEvent` or equivalent;
  - `wheelRows(from event:) -> Int` with clamping so one wheel event cannot
    jump thousands of rows because of a bad device delta.

- Preserve damage-driven rendering. Mouse or scroll actions that change
  terminal state must set `renderInvalidated = true`; events ignored by the
  terminal should not force full redraws.

- Keep native selection and copy behavior working when mouse tracking is
  false. Do not implement semantic word selection or a draggable scrollbar in
  this shard.

### Milestone 4: E2E Coverage And Plan Updates

Strengthen autonomous verification so future agents cannot regress the route.

Implementation requirements:

- Add a fixture under `fixtures/` if needed to produce enough deterministic
  scrollback. The fixture should be small, textual, and bounded.
- Update `scripts/test-e2e` with checks:
  - create or load scrollback content;
  - record `/debug/sessions` viewport fields;
  - post `{"action":"scrollViewport","deltaRows":-N}`;
  - verify viewport offset changes and screenshot/frame advances;
  - post `mouseWheel` while not tracking and verify the same scroll path;
  - enable SGR mouse tracking with `typeText` or fixture bytes such as
    `ESC[?1000h ESC[?1006h`;
  - post `mouseWheel` and `click` in terminal coordinates;
  - verify `mouse.sent` events are present and viewport offset does not change
    for terminal-routed wheel events.

- Update `execplans/active/swiftpm-appkit-software-renderer-mvp.md` to point
  the mouse/scrollback progress bullet at this plan and mark it complete only
  when this plan passes.

- Update `docs/quality/quality.md` or `docs/quality/tech-debt.md` only if the
  implementation intentionally leaves a known gap such as missing AppKit
  manual verification on a machine without a pointing device.

## Concrete Steps

Work from the repository root:

```sh
cd /Users/rrj/wrk/laban
```

Inspect the relevant files before editing:

```sh
sed -n '1,130p' Sources/LabanTerminalCore/include/LabanTerminalCore.h
sed -n '1,520p' Sources/LabanTerminalCore/session.c
sed -n '1,130p' Sources/LabanCore/Session.swift
sed -n '320,390p' Sources/LabanApp/TerminalBitmapView.swift
sed -n '385,490p' Sources/LabanDebug/HeadlessDebugRuntime.swift
sed -n '1,140p' schemas/debug/action.schema.json
sed -n '165,255p' .external/libghostty-vt/include/ghostty/vt/terminal.h
sed -n '1,220p' .external/libghostty-vt/include/ghostty/vt/mouse/encoder.h
sed -n '1,210p' .external/libghostty-vt/include/ghostty/vt/mouse/event.h
```

Implement in milestone order. Run focused tests after each milestone:

```sh
swift test --filter LabanTerminalCoreTests
swift test --filter LabanDebugSmokeTests
swift test --filter LabanAppTests
```

Run the full gate at the end:

```sh
./scripts/check
```

Expected final output:

```text
check passed
```

Build and open the local app for manual verification:

```sh
./scripts/build-app
open .build/laban/Laban.app
```

Manual smoke:

1. Run a command that prints more lines than fit in the viewport, such as
   `seq 1 200`.
2. Scroll up with the wheel. Older numbered lines should appear.
3. Scroll down. The active bottom should return.
4. Run a TUI that enables mouse tracking, or feed a known mouse-tracking
   enable sequence from a fixture/debug path. Wheel/clicks should route to the
   terminal app, not local selection.

## Validation and Acceptance

This plan is complete when:

- `./scripts/check` exits 0 and prints `check passed`.
- C terminal-core tests prove viewport scrolling changes visible snapshot
  content and exposes nonzero scrollback metadata.
- C terminal-core tests prove mouse encoding uses libghostty and produces
  non-empty SGR mouse bytes when terminal mouse tracking is enabled.
- Debug runtime tests prove `scrollViewport`, normal-mode `mouseWheel`, and
  mouse-tracking `mouseWheel` follow distinct routes.
- `scripts/test-e2e` covers both normal scrollback and mouse-tracking routing.
- AppKit wheel input scrolls shell output when mouse tracking is inactive.
- AppKit mouse events are sent to terminal apps when mouse tracking is active,
  and local text selection remains available when mouse tracking is inactive.
- `/debug/sessions` reports real `scrollbackLines`, `viewportOffset`, and
  `mouseTracking` values.

## Idempotence and Recovery

All planned edits are source, test, fixture, schema, and script changes. They
are safe to rerun. `./scripts/check` already fetches libghostty-vt
idempotently.

If mouse encoding fails in C, first run the encode-only unit test and compare
against `.external/libghostty-vt/example/c-vt-encode-mouse/src/main.c`. Do not
replace the encoder with hand-written SGR strings.

If AppKit wheel direction feels inverted, adjust only the AppKit conversion
helper and keep debug `scrollViewport` semantics stable: negative rows reveal
older history, positive rows return toward the active bottom.

If a terminal app does not enable mouse tracking, local scrolling and selection
must remain active. Do not special-case a program name; trust terminal mode
state.

If debug `click` support for local selection becomes too large, keep sidebar
clicks and terminal-routed clicks in this shard and document debug-local
selection as a later test-surface gap. AppKit local selection must still work.

## Artifacts and Notes

Important source evidence:

```text
.external/libghostty-vt/include/ghostty/vt/terminal.h
  ghostty_terminal_scroll_viewport
  GHOSTTY_TERMINAL_DATA_SCROLLBAR
  GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS
  GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING

.external/libghostty-vt/include/ghostty/vt/mouse/encoder.h
  ghostty_mouse_encoder_setopt_from_terminal
  ghostty_mouse_encoder_encode

.external/libghostty-vt/src/input/mouse_encode.zig
  wheel-style buttons four and five map to button codes 64 and 65
```

Current gaps this plan closes:

```text
Sources/LabanDebug/HeadlessDebugRuntime.swift
  mouseWheel, click, and scrollViewport currently fall into the unsupported action path.

Sources/LabanDebug/HeadlessDebugRuntime.swift
  /debug/sessions currently reports scrollbackLines: 0 and viewportOffset: 0.

Sources/LabanApp/TerminalBitmapView.swift
  mouseDown/mouseDragged/mouseUp currently always start or extend local selection in terminal content.
  There is no scrollWheel override.
```

Review-fix validation evidence from 2026-05-03:

```text
swift test --filter LabanAppTests
  Executed 14 tests, with 0 failures.

swift test --filter LabanTerminalCoreTests
  Executed 18 tests, with 0 failures.

swift test --filter LabanDebugSmokeTests
  Executed 22 tests, with 0 failures.

./scripts/check
  check passed
```

## Interfaces and Dependencies

Do not add package dependencies. Use existing SwiftPM targets and the pinned
libghostty-vt static library.

Required C ABI at completion:

```c
typedef struct {
    int total_rows;
    int scrollback_rows;
    int viewport_offset;
    int viewport_rows;
    int mouse_tracking;
} LabanViewportState;

typedef enum {
    LABAN_MOUSE_ACTION_PRESS = 0,
    LABAN_MOUSE_ACTION_RELEASE = 1,
    LABAN_MOUSE_ACTION_MOTION = 2
} LabanMouseAction;

typedef enum {
    LABAN_MOUSE_BUTTON_NONE = 0,
    LABAN_MOUSE_BUTTON_LEFT = 1,
    LABAN_MOUSE_BUTTON_MIDDLE = 2,
    LABAN_MOUSE_BUTTON_RIGHT = 3,
    LABAN_MOUSE_BUTTON_WHEEL_UP = 4,
    LABAN_MOUSE_BUTTON_WHEEL_DOWN = 5
} LabanMouseButton;

typedef struct {
    LabanMouseAction action;
    LabanMouseButton button;
    float x;
    float y;
    int screen_width;
    int screen_height;
    int cell_width;
    int cell_height;
    int modifiers;
} LabanMouseEvent;

int laban_session_scroll_viewport(LabanSession *session, int delta_rows);
int laban_session_viewport_state(LabanSession *session, LabanViewportState *out_state);
int laban_session_encode_mouse(
    LabanSession *session,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);
int laban_session_send_mouse(LabanSession *session, const LabanMouseEvent *event);
```

Swift wrappers may use Swifty type names, but they must preserve these
semantics:

- negative scroll rows reveal older history;
- positive scroll rows return toward the active bottom;
- terminal mouse tracking suppresses local AppKit selection and local
  scrollback scrolling for terminal-content pointer events;
- sidebar pointer input is always consumed by the sidebar.
