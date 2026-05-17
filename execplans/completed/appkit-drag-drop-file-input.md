# Drag And Drop Files Into Terminal Sessions

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor must be able to implement the behavior from this file alone.

## Purpose / Big Picture

A user reported: "Cmd-v för att få in filer i laban funkar inte så bra, jag
vill ha drag and drop, jag tar ofta screenshots som jag vill skicka in till
claude." In English: Command-V is not good enough for getting files into Laban;
the user wants drag and drop, especially for screenshots they want to send to
Claude.

After this change, a user can drag a Finder file, a saved screenshot, or the
macOS floating screenshot thumbnail onto the active Laban terminal viewport.
Laban resolves the dropped content to one or more local file paths, materializes
temporary screenshot/image content when necessary, and inserts those paths into
the active terminal session. In a Claude Code tab, the user should be able to
drop a screenshot and submit the prompt without manually finding or copying the
file path.

This plan is only for drag and drop. It must not implement OSC 52 clipboard
support, terminal-initiated clipboard reads/writes, or a broader clipboard
transport. "OSC 52" means an escape sequence printed by a terminal program to
ask the terminal emulator to read or write the host clipboard; that is a
terminal-output side effect and is a separate feature.

## Progress

- [x] (2026-05-14) Researched existing Laban clipboard, paste, input capture,
  and debug-action paths.
- [x] (2026-05-14) Confirmed `TerminalBitmapView` has `Cmd+V` paste handling
  and a Claude Code image-paste compatibility path, but no AppKit drag
  destination methods.
- [x] (2026-05-14) Confirmed the debug harness requires visible behavior to be
  observable without manual OS interaction.
- [x] (2026-05-14) Authored this active ExecPlan.
- [x] (2026-05-15) Added an AppKit drop resolver for file URLs, file promises, and raw image
  drops.
- [x] (2026-05-15) Added a shared path-text formatter in `LabanCore` so AppKit and debug
  actions use the same terminal text.
- [x] (2026-05-15) Wired `TerminalBitmapView` as a drop destination for terminal content only.
- [x] (2026-05-15) Added debug actions that exercise the same terminal path-insertion behavior
  without desktop automation.
- [x] (2026-05-15) Added unit and debug-runtime tests for formatting, materialization, and
  terminal input delivery.
- [x] (2026-05-15) Updated product/debug documentation for drag/drop file input.
- [x] (2026-05-15) Ran focused tests and the repository check gate.
- [x] (2026-05-15) Passed the fresh-agent Review Gate after the final duplicate-path
  regression fix.
- [x] (2026-05-15) User smoke-tested dragging an image into a Claude Code
  session running in the new app build; the path insertion worked.

## Decision Log

- Decision: Implement dropped files/screenshots by inserting local file paths
  into the active terminal, not by serializing file or image bytes into PTY
  input.
  Rationale: Terminal input is byte-oriented text. Claude Code already accepts
  image paths in prompts, and ordinary terminal emulators usually handle file
  drops by inserting paths. This is predictable, inspectable, and avoids a
  Laban-specific file-transfer protocol.
  Date/Author: 2026-05-14 / Codex

- Decision: Materialize raw image drops and promised screenshot files under a
  Laban-owned drop cache before inserting paths.
  Rationale: A drag may arrive as a normal file URL, as a "file promise" where
  macOS creates the file only after the destination accepts the drop, or as raw
  image data. Claude Code needs a readable local file path, so non-file inputs
  must become files first.
  Date/Author: 2026-05-14 / Codex

- Decision: Use the existing paste send path for final terminal delivery.
  Rationale: `Session.writePasteCapturingBytes(_:)` already honors bracketed
  paste mode, captures committed encoded bytes, and feeds the debug/capture
  logs. Direct `session.write(_:)` would bypass those safety and observability
  hooks.
  Date/Author: 2026-05-14 / Codex

- Decision: Reject drops over the sidebar.
  Rationale: The sidebar owns tab selection and close/new-tab hit testing.
  Pointer input there must not leak to the active terminal session.
  Date/Author: 2026-05-14 / Codex

- Decision: Do not change `Sources/LabanTerminalCore` for this work.
  Rationale: Drag and drop is an AppKit host UI concern. Terminal core owns PTY,
  parsing, paste encoding, snapshots, and terminal input primitives, but it does
  not own macOS drag sessions or host file materialization.
  Date/Author: 2026-05-14 / Codex

## Review Gate

A separate fresh-state agent must verify these checks before this ExecPlan is
considered complete. The executing agent must not mark the plan complete until
the gate passes.

- [x] Run `rtk git diff --name-only -- Sources/LabanTerminalCore` from the repo
  root. Expected output is empty; this drag/drop feature must not modify the C
  terminal core.
- [x] Run `rtk swift test --filter TerminalDropTextTests`. Expected result:
  exit 0.
- [x] Run `rtk swift test --filter TerminalDropTests`. Expected result: exit 0.
- [x] Run the new debug-runtime drop-file test by exact filter once it exists,
  for example `rtk swift test --filter LabanDebugSmokeTests/testDropFilesActionPastesEscapedPaths`.
  Expected result: exit 0 and the test asserts a `dropFiles` action writes the
  formatted path text through the captured paste path.
- [x] Run `rtk rg -n "OSC|osc|52|read_clipboard|write_clipboard" Sources/LabanApp/TerminalDrop.swift Sources/LabanCore/TerminalDropText.swift Sources/LabanDebug/DebugDropActions.swift Tests/LabanAppTests/TerminalDropTests.swift Tests/LabanCoreTests/TerminalDropTextTests.swift`
  after those files exist. Expected result: no output; the drag/drop
  implementation files must not introduce OSC clipboard behavior.
- [x] Run `rtk ./scripts/check-docs` and `rtk ./scripts/check`. Expected result:
  both exit 0.

Review status: PASSED on 2026-05-15. A separate fresh-state agent reran the
full gate after the final fix and reported: terminal-core diff empty;
`TerminalDropTextTests` passed with 4 tests; `TerminalDropTests` passed with 5
tests, including
`testResolvePrefersFileURLWhenPasteboardAlsoContainsImageData`; both
debug-runtime drop tests passed; the OSC/clipboard grep produced no output and
exited 1 as expected; `scripts/check-docs` and a clean `scripts/check` rerun
exited 0. The first reviewer `scripts/check` attempt failed because concurrent
SwiftPM lock-wait text contaminated capture replay output, but the reviewer
reran `rtk ./scripts/check` by itself and it completed with `check passed`.

## Surprises & Discoveries

- Observation: Laban already has a Claude Code image clipboard compatibility
  path.
  Evidence: `Sources/LabanApp/TerminalBitmapView.swift` checks for image data on
  `NSPasteboard.general` during `paste(_:)`; if the active tab looks like
  Claude Code, it sends terminal `Ctrl+V` instead of reading image bytes.

- Observation: Laban does not currently register as an AppKit drag destination.
  Evidence: repository search found no `registerForDraggedTypes`,
  `draggingEntered`, `draggingUpdated`, `performDragOperation`, or
  `NSDraggingDestination` implementation in `Sources/LabanApp`.

## Context and Orientation

Laban is a macOS terminal application. The visible AppKit terminal view is
`Sources/LabanApp/TerminalBitmapView.swift`. It is an `NSView`, which means it
can become an AppKit drag destination by registering pasteboard types and
overriding drag destination methods. A "drag pasteboard" is the AppKit data
container used during a drag session; it can contain file URLs, image data, or
file promises.

The existing input path is:

- `Sources/LabanApp/TerminalBitmapView.swift` owns AppKit keyboard, mouse,
  selection, copy, paste, and capture recording.
- `Sources/LabanApp/TerminalClipboard.swift` owns pasteboard text preflight,
  image detection, and Claude Code tab recognition for `Cmd+V`.
- `Sources/LabanCore/Session.swift` owns Swift wrappers for terminal input. Its
  `writePasteCapturingBytes(_:)` method sends pasted text to the terminal and
  returns the exact encoded bytes committed by the terminal core.
- `Sources/LabanApp/TerminalBitmapView.swift` records user input in capture
  artifacts through `recordInput(...)`.

The existing debug path is:

- `docs/process/dev-process.md` requires every visible behavior to be
  observable and testable without manual UI automation.
- `schemas/debug/action.schema.json` defines allowed `/debug/actions` request
  shapes.
- `Sources/LabanDebug/DebugRuntimeRequests.swift` decodes debug actions.
- `Sources/LabanDebug/DebugDiscoveryEndpoints.swift` lists available debug
  actions.
- `Sources/LabanDebug/DebugClipboardActions.swift` currently implements copy,
  paste, and debug clipboard text actions. Drag/drop should use a new
  `DebugDropActions.swift` or similarly named file so clipboard behavior stays
  separate.

Important terms used in this plan:

- **PTY**: the pseudo-terminal file descriptor connected to the child shell or
  terminal app. Terminal input eventually becomes bytes written to the PTY.
- **Bracketed paste**: a terminal mode where pasted text is wrapped with start
  and end escape sequences so an app can distinguish paste from typing. Laban
  already handles this in `writePasteCapturingBytes(_:)`.
- **File URL drop**: a drag pasteboard item whose value is an existing local
  file or directory URL.
- **File promise**: an AppKit drag item where the source promises to create a
  file after the destination accepts the drop. The macOS screenshot floating
  thumbnail can behave like this, so Laban must support it for screenshots.
- **Raw image drop**: image bytes on the pasteboard without a stable file path.
  Laban must write these bytes to a PNG file before inserting a path.

## Plan of Work

Add `Sources/LabanApp/TerminalDrop.swift`. This file should own all AppKit
drop-specific policy so `TerminalBitmapView` does not grow another large block
of pasteboard parsing. The helper should expose:

- a list of accepted pasteboard types for file URLs, images, and file promises;
- a predicate that says whether a drag pasteboard has acceptable data;
- a resolver that returns existing file URLs immediately and asynchronously
  fulfills file promises when present;
- a materializer that writes raw `NSImage` drops to PNG files in a Laban drop
  cache.

Add a small shared formatter in `Sources/LabanCore`, for example
`TerminalDropText.swift`. It should be pure Foundation code and should not
import AppKit. It converts one or more file paths or file URLs into
terminal-safe text. `LabanApp` and `LabanDebug` must both use this shared
formatter; `LabanDebug` cannot depend on `LabanApp` because `Package.swift`
defines the dependency in the other direction (`LabanApp` depends on
`LabanDebug`).

Use AppKit APIs only in `LabanApp`. Prefer modern URL/object reading over
legacy plain path strings:

- Read existing files with `NSPasteboard.readObjects(forClasses: [NSURL.self],
  options: [.urlReadingFileURLsOnly: true])`.
- Read raw images with `NSPasteboard.readObjects(forClasses: [NSImage.self],
  options: nil)`.
- Read promised files with `NSFilePromiseReceiver`. Fulfill promises into the
  Laban drop cache, then use the resulting file URLs.
- Keep legacy filename pasteboard support only as a fallback if tests show a
  common macOS source still needs it.

Use this default drop cache for interactive runs:

```text
~/Library/Application Support/Laban/drops/
```

For each drop that materializes data, create a unique child directory such as
`drop-20260514T120301Z-<uuid>/` and write files inside it. This avoids filename
collisions and keeps a group of dropped files together. Add a best-effort prune
that deletes drop cache children older than seven days on app launch or before
creating a new drop directory. Do not include drop cache contents in diagnostics
unless a later plan explicitly opts into that.

Format inserted path text with POSIX shell-style quoting and a trailing space:

```text
'/Users/rrj/Desktop/Screenshot 2026-05-14 at 12.03.01.png' 
```

For multiple dropped files, join quoted paths with one space and append a final
space:

```text
'/tmp/a.png' '/tmp/file with spaces.pdf' 
```

The actual pasted text begins with the first quote or path character.
Shell-style quoting is the terminal-emulator convention and keeps paths with
spaces, parentheses, and apostrophes unambiguous. Add unit tests for spaces and
single quotes in filenames.

Wire `TerminalBitmapView` as the destination:

- In `init(...)`, call `registerForDraggedTypes(TerminalDrop.acceptedTypes)`.
- Override `draggingEntered(_:)` and `draggingUpdated(_:)`.
- Convert the drag location into view coordinates.
- Return `.copy` only when the point is inside terminal content
  (`pt.x >= sidebarWidth`), an active session exists, and `TerminalDrop` can
  read the pasteboard.
- Return `[]` / `.none` for sidebar drops, inactive sessions, and unsupported
  data.
- Override `performDragOperation(_:)`. Resolve the drop, then on the main
  thread send the formatted paths to the active session through
  `session.writePasteCapturingBytes(_:)`.
- If promise fulfillment is asynchronous, do not block AppKit while the source
  writes the promised files. When fulfillment completes, re-check that the
  active tab still has a live session before sending input.

Add a small private method in `TerminalBitmapView` for final delivery, for
example `pasteDroppedFilePaths(_ urls: [URL], sourceKinds: [String])`. It should
mirror the existing paste path:

- call `followActiveBottomBeforeTerminalInput(session:)`;
- record any follow-bottom scroll through `recordInputFollowBottom(deltaRows:)`;
- call `session.writePasteCapturingBytes(formattedPathText)`;
- record an input envelope with `kind: "drop"`, `route: "terminal"`,
  `command: "dropFiles"`, `text: formattedPathText`, and encoded byte metadata;
- append an event such as `drop.files` with count, source kinds, and byte count,
  but do not log image bytes or file contents;
- set `renderInvalidated = true`.

Add debug support for autonomous verification. The debug action does not need
to synthesize OS drag sessions; it should exercise the same final formatting
and terminal delivery behavior:

- Extend `schemas/debug/action.schema.json` with:

```json
{
  "action": "dropFiles",
  "paths": ["/tmp/example image.png", "/tmp/spec.pdf"]
}
```

- Optionally add a second action for raw image materialization if it remains
  simple:

```json
{
  "action": "dropImageData",
  "filename": "screenshot.png",
  "dataBase64": "<base64 png bytes>"
}
```

  If this optional action is added, it must write the decoded image under the
  debug `artifactsURL/drops/` directory and then use the same path-insertion
  path as `dropFiles`.

- Add `dropFiles` to `DebugActionKind` in
  `Sources/LabanDebug/DebugRuntimeRequests.swift`.
- Add `DebugDropActions.swift` under `Sources/LabanDebug` to format paths with
  the shared `LabanCore` formatter used by AppKit and write through
  `session.writePasteCapturingBytes(_:)`.
- Add `dropFiles` to `DebugDiscoveryCatalog.actions` in
  `Sources/LabanDebug/DebugDiscoveryEndpoints.swift`.
- Update `docs/process/dev-process.md` to list `dropFiles` under control
  actions and explain that it inserts formatted file paths into the terminal
  using the same paste encoder as AppKit drops.

Update product documentation after implementation:

- In `docs/product/mvp.md`, add drag-and-drop file/screenshot input as required
  clipboard/file input behavior.
- Keep OSC 52 out of the MVP wording for this plan unless a separate plan is
  explicitly opened for terminal-initiated clipboard support.

## Concrete Steps

Run all commands from the repository root:

```sh
cd /Users/rrj/wrk/laban/.codex/worktrees/clipboard
```

1. Add the AppKit drop helper:

   - Create `Sources/LabanCore/TerminalDropText.swift` with path quoting and
     multi-path formatting helpers.
   - Create `Sources/LabanApp/TerminalDrop.swift`.
   - Import `AppKit` and `Foundation`. Import `UniformTypeIdentifiers` only if
     needed for type identifiers.
   - Implement accepted pasteboard types, file URL reading, image reading,
     file-promise reading, materialization, pruning, and calls to the shared
     path formatter.
   - Add focused formatting tests in
     `Tests/LabanCoreTests/TerminalDropTextTests.swift`.
   - Add focused AppKit drop/materialization tests in
     `Tests/LabanAppTests/TerminalDropTests.swift`.

2. Wire `TerminalBitmapView`:

   - Register the drop types in `init(...)`.
   - Add `draggingEntered`, `draggingUpdated`, `draggingExited` if state cleanup
     is needed, and `performDragOperation`.
   - Add the final delivery helper that records input kind `drop` and writes
     through `writePasteCapturingBytes(_:)`.

3. Add debug action support:

   - Update `schemas/debug/action.schema.json`.
   - Update `Sources/LabanDebug/DebugRuntimeRequests.swift`.
   - Add `Sources/LabanDebug/DebugDropActions.swift`.
   - Update `Sources/LabanDebug/DebugDiscoveryEndpoints.swift`.
   - Add debug smoke coverage in `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`
     or a dedicated nearby test file.

4. Update docs:

   - Add `dropFiles` to the debug action examples in
     `docs/process/dev-process.md`.
   - Add drag/drop file and screenshot input to `docs/product/mvp.md`.

5. Run focused checks:

```sh
rtk swift test --filter TerminalDropTests
rtk swift test --filter TerminalDropTextTests
rtk swift test --filter LabanDebugSmokeTests
rtk swift test --filter TerminalClipboardTests
```

6. Run repository gates:

```sh
rtk ./scripts/check-docs
rtk ./scripts/check
```

7. Perform a manual AppKit smoke test on macOS:

   - Build and launch the visible app using the repository's normal app run
     command or Xcode scheme.
   - Start Claude Code in a tab.
   - Drag a saved PNG from Finder into the terminal viewport.
   - Observe that a quoted absolute path appears in Claude's prompt.
   - Take a screenshot with the macOS floating thumbnail enabled.
   - Drag the floating thumbnail into the Laban terminal viewport.
   - Observe that Laban materializes the screenshot and inserts its path.
   - Drop a file over the sidebar and observe that it is rejected; no path is
     inserted into the terminal.

## Validation and Acceptance

The behavior is accepted when all of the following are true:

- Dropping one existing image file from Finder into terminal content inserts a
  local absolute path into the active terminal session.
- Dropping multiple files inserts all paths in order, shell-quoted and separated
  by single spaces.
- Dropping a macOS screenshot floating thumbnail materializes a PNG under
  `~/Library/Application Support/Laban/drops/...` and inserts that new file
  path.
- Dropping raw image data, when AppKit supplies image data without a file URL,
  materializes a PNG and inserts that path.
- Dropping over the sidebar does not send anything to the terminal.
- The inserted path text is sent via `Session.writePasteCapturingBytes(_:)`, so
  input logs and capture artifacts include the committed encoded bytes.
- The debug action `dropFiles` can prove the terminal delivery path without OS
  drag automation.
- No files under `Sources/LabanTerminalCore` change for this feature.

Expected focused test coverage:

- `TerminalDropTextTests.testFormatsSinglePathWithSpacesAndTrailingSpace`
- `TerminalDropTextTests.testFormatsSingleQuoteInPath`
- `TerminalDropTextTests.testFormatsMultiplePathsInOrder`
- `TerminalDropTests.testMaterializesImageAsPngUnderDropDirectory`
- `TerminalDropTests.testRejectsUnsupportedPasteboard`
- `TerminalDropTests.testResolvePrefersFileURLWhenPasteboardAlsoContainsImageData`
- `LabanDebugSmokeTests.testDropFilesActionPastesEscapedPaths`
- `LabanDebugSmokeTests.testDropFilesActionRecordsInputEnvelope`

The new tests should fail before the implementation and pass after it. Running
`rtk ./scripts/check` should complete successfully after the feature is wired.

Validation completed on 2026-05-15:

```sh
rtk swift test --filter TerminalDropTextTests
rtk swift test --filter TerminalDropTests
rtk swift test --filter LabanDebugSmokeTests/testDropFilesActionPastesEscapedPaths
rtk swift test --filter LabanDebugSmokeTests/testDropFilesActionRecordsInputEnvelope
rtk swift test --filter TerminalClipboardTests
rtk swift test --filter DebugActionDecodingTests
rtk swift test --filter LabanDebugSmokeTests
rtk git diff --name-only -- Sources/LabanTerminalCore
rtk rg -n "OSC|osc|52|read_clipboard|write_clipboard" Sources/LabanApp/TerminalDrop.swift Sources/LabanCore/TerminalDropText.swift Sources/LabanDebug/DebugDropActions.swift Tests/LabanAppTests/TerminalDropTests.swift Tests/LabanCoreTests/TerminalDropTextTests.swift
rtk ./scripts/check-docs
rtk ./scripts/check
```

All commands passed. The `rg` check intentionally exits 1 when it finds no
matches; that no-output result is the expected pass condition for this gate.
`./scripts/check` emitted existing Xcode module-cache warnings during app build,
then completed with `check passed`.

No live Finder drag was performed by this agent session. After the Review Gate,
the user tested dragging an image into a Claude Code session running in the new
app build and reported that it worked. The remaining desktop behavior is covered
by AppKit pasteboard resolver tests, the final `TerminalBitmapView` delivery
path, the debug `dropFiles` action, and the fresh-agent Review Gate.

## Idempotence and Recovery

The implementation should be safe to retry:

- Drop cache directories are unique per drop, so re-running tests or repeating
  a drop does not overwrite previous user files.
- Existing file URL drops do not copy or mutate the source file.
- Raw image and promised-file materialization writes only under the Laban drop
  cache or the debug artifact `drops/` directory.
- If materialization fails, log `drop.failed` with the source kind and error
  summary, but do not send partial or invalid bytes to the terminal unless at
  least one file path was resolved.
- If a tab closes while a promised file is being fulfilled, abandon terminal
  delivery and log the cancellation.
- If tests create temporary drop roots, use `addTeardownBlock` or `defer` to
  remove them.

## Interfaces and Dependencies

Required AppKit dependencies:

- `NSView.registerForDraggedTypes(_:)`: registers `TerminalBitmapView` as a
  candidate destination for selected pasteboard types.
- `NSDraggingInfo.draggingPasteboard`: provides the pasteboard for the current
  drag.
- `NSPasteboard.readObjects(forClasses:options:)`: reads file URLs, images, and
  file promises as typed objects.
- `NSFilePromiseReceiver`: receives promised files from sources that create the
  file only after a drop is accepted.
- `NSImage` and `NSBitmapImageRep`: convert raw dropped images to PNG files.

Required Laban dependencies:

- `Sources/LabanApp/TerminalBitmapView.swift`: destination methods and final
  terminal delivery.
- `Sources/LabanCore/Session.swift`: `writePasteCapturingBytes(_:)` for
  bracketed-paste-aware terminal input.
- `Sources/LabanCore/TerminalDropText.swift`: new shared path formatting helper
  used by both `LabanApp` and `LabanDebug`.
- `Sources/LabanCore/CaptureTypes.swift`: existing `InputEventEnvelope` fields
  are sufficient; use `kind: "drop"` and `command: "dropFiles"` without adding
  new envelope fields unless tests prove a need.
- `Sources/LabanDebug`: debug action routing, discovery, and tests.

Out of scope for this ExecPlan:

- OSC 52 clipboard reads/writes.
- Dragging terminal-selected text out of Laban.
- Uploading files to cloud services.
- Remote/SSH path translation.
- Inline image display protocols such as Kitty graphics.
- New settings UI for drop-cache location or retention.
