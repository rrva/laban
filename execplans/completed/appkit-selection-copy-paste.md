# Add Visible Selection And Clipboard Semantics

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then add MVP-visible terminal selection, copy, and paste behavior.

## Purpose / Big Picture

Laban can now run a real terminal session, render text, accept keyboard input,
show tabs, expose a local debug server, avoid idle redraws, and route
scrollback plus terminal mouse reporting through the reviewed libghostty mouse
encoder path. The next MVP gap is basic terminal selection: a user can drag in
the terminal viewport and `Command-C` has a private AppKit-only copy path, but
there is no visible highlight, debug cannot model a local selection, `copy` is
not implemented in headless mode, and paste writes raw text instead of using
terminal paste rules.

After this change, dragging visible terminal text highlights the selected
cells, `Command-C` copies the selected visible text, and `Command-V` pastes
text through the terminal core. In headless mode, an agent can set a visible
selection, query `/debug/selection`, see `selection` frame commands, copy into
the debug clipboard, paste from it, and inspect `/debug/clipboard` without
reading the user's real system clipboard.

## Progress

- [x] (2026-05-03) Merged the initial mouse and scrollback shard
  `e63e6919a02ef2d0a11f6a9e592f34cb3275d55e` into `main`.
- [x] (2026-05-03) Brought the mouse and scrollback baseline current through
  review fixes and follow-ups on `main`: `0433471` fixes pixel coordinates,
  modifier bit order, debug mouse `y`, and drag motion button preservation;
  `6b1cefa` records the mouse/scrollback review as verified; `1ca45c7` keeps
  sidebar-owned drags out of terminal mouse reporting; merge `1b7f51e` is the
  current `main` head at the time this plan refresh was written.
- [x] (2026-05-03) Identified selection/copy/paste as the next MVP work item
  after mouse input and scrollback in `docs/product/mvp.md`.
- [x] (2026-05-03) Verified the current baseline: `TerminalBitmapView` stores
  selection anchors privately and can copy selected visible cells through
  AppKit, while `paste(_:)` still writes raw UTF-8 clipboard text with
  `sendBytes`. `FrameProducer.commands(from:)` never emits selection commands
  and `HeadlessDebugRuntime` returns `"local selection not implemented through
  debug"` for terminal clicks without mouse tracking.
- [x] (2026-05-03) Verified `schemas/debug/selection.schema.json` and
  `schemas/debug/clipboard.schema.json` already define the debug contracts, but
  `DebugHTTPServer` does not route `/debug/selection` or `/debug/clipboard`,
  and `schemas/debug/action.schema.json` does not yet define `setSelection`.
- [x] (2026-05-03) Add shared visible-selection geometry and text extraction
  helpers (`TerminalSelection.swift` with `segments`, `cgRects`,
  `selectedText`; selection dict keyed by `Session.ID` in
  `HeadlessDebugRuntime`).
- [x] (2026-05-03) Render selection highlights in AppKit and headless frame
  commands (`FrameProducer.commands(from:selection:)` restructured to separate
  BG pass → selection rects → glyph pass; `selectionBySession` threaded through
  `renderFrameUnlocked`).
- [x] (2026-05-03) Implement headless selection, copy, paste,
  `/debug/selection`, and `/debug/clipboard` (`setSelection`, `copy` actions
  added; `paste` updated to use `session.writePaste`; routes wired in
  `DebugHTTPServer`; `ClipboardResponse` encodes nil as JSON null).
- [x] (2026-05-03) Add terminal-core paste encoding that honors bracketed paste
  mode (`laban_session_bracketed_paste_enabled`, `laban_session_encode_paste`,
  `laban_session_write_paste` in `session.c`; `Session.writePaste` in Swift;
  `ghostty_paste_encode` + `ghostty_terminal_mode_get` with
  `GHOSTTY_MODE_BRACKETED_PASTE`).
- [x] (2026-05-07) Add terminal-core paste send-and-capture wrappers
  (`laban_session_write_paste_encoded`, `Session.writePasteCapturingBytes`) so
  AppKit and debug observability can record the exact encoded bytes committed
  by libghostty's paste path, including bracketed paste framing.
- [x] (2026-05-03) Add unit, debug-runtime, schema, and E2E coverage
  (`TerminalSelectionTests.swift` 11 tests; 5 new `LabanDebugSmokeTests`; 5
  new `LabanSessionTests` for paste encoding; `setSelection` added to
  `action.schema.json`; E2E selection+copy+clipboard flow in `scripts/test-e2e`;
  124 tests total, 0 failures, `check passed`).
- [x] (2026-05-03) Update the umbrella plan after the implementation lands.

## Decision Log

- Decision: Implement a simple linear visible selection for the MVP.
  Rationale: `docs/product/mvp.md` permits either linear or rectangular
  selection. Linear selection is closer to normal terminal drag behavior and
  maps cleanly to row-major terminal cells: the first selected row may start
  mid-line, middle rows include all columns, and the last selected row may end
  mid-line.
  Date/Author: 2026-05-03 / Codex.

- Decision: Keep selection as app/debug state, not terminal-core state.
  Rationale: libghostty owns terminal parsing, screen contents, mouse modes,
  scrollback, and paste encoding. The local selection is a Laban UI concern
  over the currently visible snapshot. Keeping it in Swift avoids adding fake
  selection state to `LabanTerminalCore` while still allowing shared text and
  rectangle helpers in `LabanCore`.
  Date/Author: 2026-05-03 / Codex.

- Decision: Add a debug-only `setSelection` action instead of trying to encode
  a drag gesture through the existing `click` action.
  Rationale: The existing debug `click` action represents a press and release
  at one point. A deterministic range selection needs two terminal cell
  coordinates without depending on host pointer timing. `setSelection` is
  product infrastructure for autonomous verification, not a user-facing app
  feature.
  Date/Author: 2026-05-03 / Codex.

- Decision: Use libghostty's paste utilities for paste encoding instead of
  hand-writing bracketed paste sequences in Swift.
  Rationale: `.external/libghostty-vt/include/ghostty/vt/paste.h` exposes
  `ghostty_paste_encode`, and
  `.external/libghostty-vt/include/ghostty/vt/terminal.h` exposes
  `ghostty_terminal_mode_get`. Terminal-core code can query
  `GHOSTTY_MODE_BRACKETED_PASTE` and let libghostty handle unsafe byte
  stripping, newline conversion, and bracketed paste wrapping.
  Date/Author: 2026-05-03 / Codex.

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [x] Run `./scripts/check` from `/Users/dev/wrk/laban`; expect exit 0 and
  final output `check passed`. Verified 2026-05-04: exit 0, final line
  `check passed`, 129 tests with 0 failures across the suite.
- [x] Grep `Sources/LabanCore`; expect a shared selection helper type that can
  compute selected visible text and selection rectangles from a
  `LabanSnapshot`. Verified at `Sources/LabanCore/TerminalSelection.swift`
  exposing `TerminalCellCoordinate`, `TerminalSelection`, `segments`,
  `cgRects`, and `selectedText(from:)`.
- [x] Grep `Sources/LabanCore/FrameProducer.swift`; expect selection input to
  be accepted by the terminal frame producer and emitted as
  `FrameCommand.selection` before terminal glyph commands. Verified:
  `commands(from:selection:)` runs Pass 1 backgrounds, Pass 2 selection
  rects via `Theme.CurrentTheme.selectionBg`, then Pass 3 glyph runs.
- [x] Grep `Sources/LabanDebug/DebugHTTPServer.swift`; expect routes for
  `GET /debug/selection` and `GET /debug/clipboard`. Verified at lines 208
  and 211, dispatching to `runtime.selection()` / `runtime.clipboard()`.
- [x] Grep `schemas/debug/action.schema.json`; expect a `setSelection` action
  with `anchor` and `focus` cell coordinates. Verified `$defs/setSelection`
  requires `["action", "anchor", "focus"]` with `anchor`/`focus` referencing
  the `cell` def.
- [x] Grep `Sources/LabanTerminalCore/session.c`; expect calls to
  `ghostty_terminal_mode_get` with `GHOSTTY_MODE_BRACKETED_PASTE` and
  `ghostty_paste_encode`. Verified at session.c:692, 713 (mode query) and
  724 (`ghostty_paste_encode`).
- [x] Run `swift test --filter LabanCoreTests`; expect tests proving selected
  text and selection rectangles for the colored-boxes fixture. Verified
  via `./scripts/check`; `TerminalSelectionTests` ships 11 tests including
  `testSelectedTextHelloMvpFromFixture`, `testSelectionFrameCommandsAppearsInProducerOutput`,
  and `testSelectionCommandsAppearBetweenBgAndGlyphs`.
- [x] Run `swift test --filter LabanDebugSmokeTests`; expect tests for
  `setSelection`, `/debug/selection`, `copy`, `/debug/clipboard`, and
  selection frame commands. Verified via `./scripts/check`; smoke tests
  cover `testSetSelectionActionSetsActiveSelection`,
  `testDebugSelectionEndpointReflectsSetSelection`,
  `testCopyActionPopulatesDebugClipboard`,
  `testPasteActionRecordsDebugClipboardState`,
  `testSelectionFrameCommandsAppearsWithSourceFilter`, plus
  `testRuntimeClickWithoutMouseTrackingSetsLocalSelection`.
- [x] Run `swift test --filter LabanTerminalCoreTests`; expect tests for plain
  paste encoding and bracketed paste encoding after enabling mode `2004`.
  Verified via `./scripts/check`; `LabanSessionTests` cover
  `testBracketedPasteDisabledByDefault`,
  `testBracketedPasteEnabledAfterEscapeSequence`,
  `testEncodePastePlainModeConvertsNewlinesToCR`,
  `testEncodePasteBracketedModeAddsWrappingSequences`, and
  `testWritePasteInFixtureModeSucceeds`.
- [x] Run `./scripts/test-e2e`; expect a headless fixture flow that selects
  `hello mvp`, observes a non-empty selection highlight command, copies
  `hello mvp`, and sees `/debug/clipboard.lastCopyText == "hello mvp"`.
  Verified via `./scripts/check` (`test-e2e passed`); script lines 348–373
  drive `setSelection` with anchor `{1,2}`/focus `{1,10}`, assert
  `selection.text == "hello mvp"`, then `copy` and assert
  `/debug/clipboard.lastCopyText == "hello mvp"`.

Review status: REVIEWED — PASSED 2026-05-04 by review agent. All ten gate
items verified against worktree head `ddfd631 AppKit copy and paste must use
the same selection and paste helpers as the headless path`. Plan ready to be
moved to `execplans/completed/`.

## Context and Orientation

The product boundary is `docs/product/mvp.md`. The relevant MVP text says
selection may be primitive, linear or rectangular, and only needs to cover
visible text. It does not need semantic word selection, search integration,
scroll-drag extension, or alternate-screen special behavior. The same document
says paste should wrap text in bracketed paste sequences when the active
terminal has bracketed paste enabled and terminal state exposes that mode.

The relevant source files are:

- `Sources/LabanApp/TerminalBitmapView.swift` owns AppKit input events,
  `Command-C`, `Command-V`, and the bitmap frame loop. It currently stores
  `selectionAnchor` and `selectionFocus` as private row/column tuples,
  extracts text directly in `copy(_:)`, and pastes by writing raw UTF-8 bytes
  from `NSPasteboard` through `sendBytes`.
- `Sources/LabanCore/FrameProducer.swift` converts a `LabanSnapshot` into
  terminal `FrameCommand` values. It currently emits terminal background
  rectangles, glyph runs, and the cursor, but no selection commands.
- `Sources/LabanRenderer/FrameCommand.swift` already has
  `FrameCommand.selection(CGRect, color:)`, and
  `Sources/LabanRenderer/SoftwareRenderer.swift` already draws that command.
- `Sources/LabanCore/Session.swift` wraps the C session ABI. It currently has
  `write(_:)`, mouse methods, viewport methods, and snapshot methods, but no
  paste-specific wrapper.
- `Sources/LabanTerminalCore/session.c` owns libghostty, PTY writes, terminal
  snapshots, mouse encoding, scrollback, title, and exit state. Paste encoding
  belongs here because it depends on terminal mode state.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` is the C ABI used by
  Swift. Do not expose raw Ghostty handles here.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` owns deterministic debug
  actions and frame production. It currently implements `paste` by writing raw
  debug clipboard bytes, does not implement `copy`, has no selection state,
  and returns an error for terminal-area clicks when mouse tracking is off.
- `Sources/LabanDebug/DebugHTTPServer.swift` routes debug endpoints. It already
  routes health, state, screenshots, actions, sessions, render, frame commands,
  render trace, wait, and events, but not selection or clipboard.
- `schemas/debug/selection.schema.json` and
  `schemas/debug/clipboard.schema.json` already define the intended debug
  response shapes.
- `fixtures/colored-boxes.fixture.json` writes three visible lines. The second
  visible row contains `hello mvp` at row `1`, columns `2...10` in an 80 by 24
  fixture session.

Definitions used in this plan:

- A terminal cell coordinate is `{row, col}` where row `0` is the top visible
  terminal row and column `0` is the left visible terminal column.
- A visible selection is two cell coordinates, `anchor` and `focus`, tied to a
  session ID. Anchor is where the drag started. Focus is the current or final
  drag position. The normalized selection sorts them in row-major order.
- A selection segment is one selected range on one visible row. For example,
  selecting from row 1 column 2 to row 3 column 4 creates one segment on row 1
  from column 2 to the last column, one full-row segment on row 2, and one
  segment on row 3 from column 0 to column 4.
- Bracketed paste is terminal mode `2004`. When enabled, pasted text is wrapped
  by terminal control sequences so full-screen terminal programs can treat it
  as paste input instead of typed input.

## Plan of Work

First, add shared selection helpers in `LabanCore`. Create a new file such as
`Sources/LabanCore/TerminalSelection.swift` with public value types:

```swift
public struct TerminalCellCoordinate: Codable, Equatable, Sendable {
  public var row: Int
  public var col: Int
}

public struct TerminalSelection: Codable, Equatable, Sendable {
  public var sessionId: Session.ID
  public var anchor: TerminalCellCoordinate
  public var focus: TerminalCellCoordinate
}
```

Add helper methods that clamp the selection to a snapshot's visible rows and
columns, produce row segments, compute `CGRect` highlights for a given cell
size and origin, and extract selected text from `LabanSnapshot.cells` plus
`LabanSnapshot.utf8_storage`. Preserve interior spaces. For each selected row,
trim trailing terminal padding before adding a newline. This keeps selecting a
line from copying dozens of invisible spaces while still preserving meaningful
spaces inside commands and output.

Next, thread the selection helpers into rendering. Change
`FrameProducer.commands(from:)` to accept an optional `TerminalSelection`, for
example:

```swift
public func commands(
  from snap: UnsafePointer<LabanSnapshot>,
  selection: TerminalSelection? = nil
) -> [FrameCommand]
```

Emit selection rectangles with `Theme.SelenizedLight.selectionBg` after
terminal background rectangles and before glyph runs. This ordering keeps the
highlight visible without covering glyphs. Keep the default argument so
callers that do not care about selection do not need disruptive changes.

Then update AppKit behavior in `TerminalBitmapView`. Replace the private
`selectionAnchor` and `selectionFocus` tuples with selection state tied to the
active session ID. A dictionary keyed by `Session.ID` is acceptable if it keeps
selection stable when switching tabs; otherwise a single active selection is
acceptable only if it is cleared deliberately when the selected tab changes.
When mouse tracking is inactive, `mouseDown` starts local selection,
`mouseDragged` updates focus, and `mouseUp` finalizes focus. The frame loop
passes the active selection to `FrameProducer`. `copy(_:)` uses the shared
selected-text helper and writes only non-empty text to `NSPasteboard.general`.
`paste(_:)` reads only `.string` data from the system pasteboard and sends it
through the new paste wrapper on `Session`.

Add paste-specific C ABI in `Sources/LabanTerminalCore/include/LabanTerminalCore.h`
and implement it in `Sources/LabanTerminalCore/session.c`. Use these exact
shapes unless a compile-time issue forces a small adjustment:

```c
typedef struct {
    int bracketed;
    size_t bytes_written;
} LabanPasteResult;

int laban_session_bracketed_paste_enabled(LabanSession *session, int *out_enabled);
int laban_session_encode_paste(
    LabanSession *session,
    const uint8_t *bytes,
    size_t len,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len,
    int *out_bracketed
);
int laban_session_write_paste(
    LabanSession *session,
    const uint8_t *bytes,
    size_t len,
    LabanPasteResult *out_result
);
```

`laban_session_bracketed_paste_enabled` calls
`ghostty_terminal_mode_get(session->terminal, GHOSTTY_MODE_BRACKETED_PASTE,
&enabled)`. `laban_session_encode_paste` copies the input bytes into a mutable
temporary buffer, calls `ghostty_paste_encode`, and reports whether bracketed
mode was used. `laban_session_write_paste` encodes first, then writes the
encoded bytes through the same PTY path as `laban_session_write`. In fixture
mode, preserve the existing no-PTY behavior: encoded bytes may be fed into the
VT parser only where current fixture semantics already do that, and tests
should prefer `encode_paste` for byte-level assertions.

Wrap the C paste ABI in `Sources/LabanCore/Session.swift` with:

```swift
public struct PasteWriteResult: Equatable, Sendable {
  public let bracketed: Bool
  public let bytesWritten: Int
}

public func bracketedPasteEnabled() -> Bool
public func encodePaste(_ text: String) -> (bytes: [UInt8], bracketed: Bool)?
@discardableResult
public func writePaste(_ text: String) -> PasteWriteResult?
```

Next, implement deterministic debug selection and clipboard behavior in
`Sources/LabanDebug/HeadlessDebugRuntime.swift`. Add private state for the
current selection and safe clipboard summaries:

```swift
private var selectionBySession: [Session.ID: TerminalSelection] = [:]
private var lastCopyText: String?
private var lastPasteText: String?
private var lastPasteUsedBracketedPaste: Bool?
private var lastPasteIgnoredNonText: Bool?
```

Extend the debug action schema and request decoder with:

```json
{
  "action": "setSelection",
  "sessionId": "optional-session-id",
  "anchor": {"row": 1, "col": 2},
  "focus": {"row": 1, "col": 10}
}
```

In `applyAction`, `setSelection` stores a clamped selection for the target
session and renders one frame. `click` in terminal content without mouse
tracking should no longer return the old "selection not implemented" error; it
should set a one-cell local selection and return `ok: true`. Keep mouse
tracking behavior unchanged: if terminal mouse tracking is active, clicks are
encoded and sent to the terminal app instead of changing local selection.

Implement `copy` in `applyAction`: extract selected visible text from the
active session snapshot, store it in `debugClipboard` and `lastCopyText`, append
a `clipboard.copied` event with route `selection`, and return `ok: true`. If no
selection exists, return `ok: false` with a clear error and leave the clipboard
unchanged. Update `paste` to call `session.writePaste(debugClipboard)` and set
`lastPasteText`, `lastPasteUsedBracketedPaste`, and
`lastPasteIgnoredNonText = false`.

Add runtime methods and HTTP routes:

- `HeadlessDebugRuntime.selection() -> DebugResponse`
- `HeadlessDebugRuntime.clipboard() -> DebugResponse`
- `GET /debug/selection`
- `GET /debug/clipboard`

The `/debug/selection` response must conform to
`schemas/debug/selection.schema.json`. The `text` field is bounded to selected
visible text from the active snapshot. The `/debug/clipboard` response must
conform to `schemas/debug/clipboard.schema.json` and must not read or expose
the user's real macOS clipboard.

Update tests and E2E scripts last. Convert the existing debug test and E2E
expectations for "click without mouse tracking" from `ok:false` to `ok:true`
with an active one-cell selection. Add tests that use the colored-boxes fixture
to set selection from row `1`, col `2` to row `1`, col `10`, then assert:

- `/debug/selection.active == true`
- `/debug/selection.text == "hello mvp"`
- `/debug/frame-commands?source=selection` returns at least one command
- `POST /debug/actions {"action":"copy"}` succeeds
- `/debug/clipboard.lastCopyText == "hello mvp"`

For paste encoding tests, feed `ESC [ ? 2004 h` into a fixture session before
calling `encodePaste("hello\n")`; expect the returned bytes to start with the
bracketed paste start sequence `ESC [ 200 ~`, end with `ESC [ 201 ~`, and
report `bracketed == true`. With mode `2004` off, expect newlines to be encoded
as carriage returns and `bracketed == false`.

## Concrete Steps

Run all commands from `/Users/dev/wrk/laban`.

1. Confirm the current baseline:

   ```sh
   git status --short --branch
   git log -1 --oneline
   ```

   Expected baseline is `main` at or after:

   ```text
   e63e691 Terminal programs need mouse events and users need scrollback navigation
   ```

2. Add the shared selection model and tests:

   ```sh
   swift test --filter LabanCoreTests
   ```

   Before rendering and debug integration, this should at least prove selection
   text and rectangle math.

3. Add terminal-core paste ABI and Swift wrappers:

   ```sh
   swift test --filter LabanTerminalCoreTests
   ```

   Expect tests covering both plain and bracketed paste encoding.

4. Thread selection into `FrameProducer`, `TerminalBitmapView`, and
   `HeadlessDebugRuntime`:

   ```sh
   swift test --filter LabanDebugSmokeTests
   swift test --filter LabanRendererTests
   ```

5. Update schemas and the E2E script:

   ```sh
   ./scripts/test-e2e
   ```

6. Run the full repository gate:

   ```sh
   ./scripts/check
   ```

   Expected final line:

   ```text
   check passed
   ```

## Validation and Acceptance

The implementation is accepted when all of the following are true:

- In the AppKit app, dragging across terminal text creates a visible selection
  highlight. Releasing the mouse leaves the highlight visible. Switching away
  from the tab and back either preserves the selection for that session or
  clears it deliberately; it must not show a selection for the wrong session.
- `Command-C` with an active selection copies the selected visible text to the
  macOS clipboard. `Command-C` with no selection does not crash and does not
  write arbitrary fallback text.
- `Command-V` reads only text clipboard data and writes paste input through
  terminal-core paste encoding.
- When terminal mouse tracking is active, clicks, drags, and wheel events are
  still routed to the terminal app and do not start local selection.
- `GET /debug/selection` returns a schema-valid selection response.
- `GET /debug/clipboard` returns a schema-valid clipboard summary without
  reading arbitrary system clipboard contents.
- `POST /debug/actions` supports `setSelection`, `copy`, and paste summaries.
- `GET /debug/frame-commands?source=selection` exposes selection commands after
  setting a selection.
- `./scripts/check` exits 0.

## Idempotence and Recovery

All implementation steps are additive and can be retried. If selection math is
wrong, fix the shared helper first and rerun `swift test --filter
LabanCoreTests`; AppKit and debug should both consume the same corrected logic.
If paste encoding fails to link, verify `session.c` includes
`ghostty/vt/paste.h`, `ghostty/vt/modes.h`, and `ghostty/vt/terminal.h`, then
rerun `./scripts/fetch-libghostty-vt` only if the `.external/libghostty-vt`
checkout or archive is missing.

Do not read or mutate `.env`. Do not expose the macOS system clipboard through
debug endpoints. Debug clipboard state should remain private to the current
headless runtime process.

## Interfaces and Dependencies

Use existing repository dependencies only:

- AppKit `NSPasteboard` for interactive copy and paste in
  `TerminalBitmapView`.
- libghostty-vt C APIs for terminal paste mode and encoding:
  `ghostty_terminal_mode_get`, `GHOSTTY_MODE_BRACKETED_PASTE`, and
  `ghostty_paste_encode`.
- Existing Laban frame commands and software renderer for highlight drawing:
  `FrameCommand.selection` and `Theme.SelenizedLight.selectionBg`.
- Existing debug schemas under `schemas/debug/`; update
  `schemas/debug/action.schema.json` for `setSelection` and keep
  `selection.schema.json` and `clipboard.schema.json` as the response
  contracts.

At the end of this plan, the C ABI must expose paste helpers without exposing
raw Ghostty handles, Swift `Session` must expose paste wrappers, `LabanCore`
must expose reusable visible-selection helpers, AppKit must render and copy
selection through those helpers, and headless debug must make selection and
clipboard behavior autonomously verifiable.
