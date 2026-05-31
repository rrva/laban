# Record And Replay Full Input-To-Render Timelines

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then implement in-the-wild capture and deterministic replay for
Laban's input, PTY, terminal, and rendering pipeline.

## Purpose / Big Picture

Laban is becoming useful enough that rendering and input bugs will increasingly
show up only during real interactive use: a keyboard layout edge case, a TUI
that enables a terminal mode, a burst of PTY output, a resize race, or a frame
that renders differently after a later renderer change. Screenshots and
bounded debug logs help explain the current run, but they do not let another
agent replay the exact input and terminal byte stream that produced a bad
frame.

After this change, a developer can launch Laban with capture enabled, use it
normally, stop capture, and get a local artifact directory containing one
ordered timeline. That timeline links platform input, normalized input
envelopes, encoded PTY input bytes, PTY output bytes, session/tab changes,
terminal snapshots, frame-command extraction, render traces, and screenshots.
The developer or an agent can then run a replay command against the artifact
and reproduce the terminal state and rendered frames without the original shell
or TUI still running.

## Progress

- [x] (2026-05-04) Confirmed the keyboard ExecPlan now treats
  `/debug/input-log` as a bounded projection over replay-compatible input
  event envelopes, not as the durable recorder.
- [x] (2026-05-04) Checked `docs/product/mvp.md`,
  `docs/process/dev-process.md`, `docs/process/observability.md`,
  `docs/process/worktree-isolation.md`, `schemas/debug/input-log.schema.json`,
  `schemas/debug/terminal-log.schema.json`, and
  `schemas/artifact-manifest.schema.json`.
- [x] (2026-05-04) Inspected current capture-adjacent code in
  `Sources/LabanTerminalCore/session.c`, `Sources/LabanCore/Session.swift`,
  `Sources/LabanApp/TerminalBitmapView.swift`,
  `Sources/LabanDebug/HeadlessDebugRuntime.swift`,
  `Sources/LabanDebug/DebugHTTPServer.swift`, and
  `Sources/LabanAgent/main.swift`.
- [x] (2026-05-04) Add capture artifact schemas, event models,
  byte-stream storage, and schema validation tests.
- [x] (2026-05-04) Add terminal-core byte taps for PTY input, PTY output,
  terminal responses, resize, and lifecycle events.
- [x] (2026-05-04) Connect AppKit and headless input routes to shared input
  event envelopes.
- [x] (2026-05-04) Capture frame boundaries, terminal snapshots, frame
  commands, render traces, screenshot hashes, and optional screenshots in
  lockstep with input and PTY events.
- [x] (2026-05-04) Add capture start/stop/status/snapshot controls in debug
  mode and CLI flags for interactive/headless capture.
- [x] (2026-05-04) Add replay mode that can recreate terminal sessions from
  captured PTY output bytes and compare frame-command/render outputs.
- [x] (2026-05-04) Add renderer-only replay from captured frame commands to
  isolate renderer regressions from terminal parser regressions.
- [x] (2026-05-04) Add unit, integration, and E2E tests. Manual in-the-wild
  AppKit capture remains a Review Gate/manual acceptance item.
- [x] (2026-05-04) Fixed AppKit replay gaps found by a manual capture:
  terminal replay now hydrates captures started after an existing prompt,
  recomputes commands with captured AppKit layout, records AppKit scroll/mouse/
  selection input envelopes, and can infer missing scrolls in legacy artifacts.
- [x] (2026-05-07) Split mouse encoding preview from committed send state so
  capture/debug logging cannot mutate held-button drag state before PTY input
  is sent.
- [x] (2026-05-07) Added a terminal-core mouse send-and-capture ABI so
  debug/headless mouse logs use the bytes from the committed send operation
  instead of a pre-send preview.
- [x] (2026-05-07) Centralized paste sanitization in `LabanCore` and applied it
  to both AppKit paste and debug paste actions so captured/debug paste
  envelopes report the exact sanitized terminal text sent through libghostty's
  paste encoder.
- [x] (2026-05-07) Added a terminal-core paste send-and-capture ABI so
  AppKit/debug paste input envelopes and terminal-input logs can report the
  exact committed plain or bracketed paste bytes.
- [x] (2026-05-17) Pass the Review Gate before marking this plan complete.

## Decision Log

- Decision: Capture is local-only, explicit, and treated as sensitive.
  Rationale: PTY bytes, input events, screenshots, environment metadata, and
  terminal text may contain secrets. Capture must be disabled by default, write
  only to the requested artifact directory, and never upload or bind to public
  interfaces.
  Date/Author: 2026-05-04 / Codex.

- Decision: Use one append-only timeline with stable IDs and sidecar blobs.
  Rationale: Reproducibility depends on ordering. Input logs, terminal logs,
  render traces, and screenshots are only useful together if every item can be
  ordered by a single monotonically increasing sequence and linked to frame,
  tab, session, and byte offsets. Large bytes and images should live in
  sidecar files referenced by timeline events so JSON stays bounded enough to
  inspect.
  Date/Author: 2026-05-04 / Codex.

- Decision: Capture two replay surfaces: terminal-byte replay and renderer-only
  replay.
  Rationale: Terminal-byte replay feeds captured PTY output into libghostty and
  proves parsing, snapshots, frame command extraction, and rendering still
  reproduce the run. Renderer-only replay consumes captured frame commands and
  proves the renderer still draws the same command stream. Separating them
  turns "a frame changed" into either a terminal/parser/input problem or a
  renderer problem.
  Date/Author: 2026-05-04 / Codex.

- Decision: Do not spawn the original shell during default replay.
  Rationale: The original process may be gone, machine-specific, timing
  dependent, or destructive. Default replay uses captured PTY output bytes as
  the authoritative terminal input stream. An optional future live-replay mode
  may use recorded input events against a process, but that is not required
  for deterministic render reproduction.
  Date/Author: 2026-05-04 / Codex.

- Decision: Capture input facts before and after terminal encoding.
  Rationale: Keyboard and mouse bugs can be in platform input normalization,
  consumed modifiers, terminal encoder state, or PTY writes. The artifact must
  include raw/bounded platform facts, normalized event envelopes, route
  decisions, encoded bytes, and actual PTY write result. PTY output replay
  alone cannot diagnose wrong keyboard encoding.
  Date/Author: 2026-05-04 / Codex.

- Decision: Record full frame commands for captured frames and screenshots on
  a configurable cadence.
  Rationale: Full frame-command capture is the best renderer replay contract.
  Screenshots are larger and privacy-sensitive, so capture mode should default
  to command capture for every rendered frame and screenshot capture for
  marked frames, failures, explicit snapshots, and an optional every-frame
  setting.
  Date/Author: 2026-05-04 / Codex.

## Surprises & Discoveries

- Observation: The current debug server already exposes many pieces needed for
  capture, but they are endpoint views, not one ordered durable recording.
  Evidence: `Sources/LabanDebug/HeadlessDebugRuntime.swift` can return state,
  sessions, screenshots, frame commands, render traces, and events, while
  `docs/process/dev-process.md` describes `/debug/input-log` and
  `/debug/terminal-log`. There is no capture manifest, global sequence, byte
  offset archive, or replay runner.

- Observation: Capturing PTY output requires a terminal-core hook because
  `laban_session_poll` reads the PTY and immediately feeds bytes into
  `ghostty_terminal_vt_write` inside `Sources/LabanTerminalCore/session.c`.
  Evidence: Swift only calls `Session.poll()`. It does not see the bytes read
  from the PTY today.

- Observation: Capturing PTY input also needs a terminal-core hook because
  writes can come from `laban_session_write`, `laban_session_send_mouse`, and
  the planned `laban_session_send_key`, plus terminal-generated responses.
  Evidence: `Sources/LabanTerminalCore/session.c` writes bytes directly to the
  PTY from those C functions.

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [x] Run `./scripts/check` from the repository root; expect exit 0 and final
  output `check passed`.
- [x] Run `find schemas -name '*.json' -print0 | xargs -0 -n1 jq empty`;
  expect exit 0.
- [x] Validate at least one generated capture manifest against
  `schemas/capture/manifest.schema.json` and one timeline event against
  `schemas/capture/event.schema.json` using the repository's schema validation
  method or `jq` plus targeted tests.
- [x] Grep `Sources/LabanTerminalCore/include/LabanTerminalCore.h`; expect a
  capture callback ABI with direction values for PTY input, PTY output, and
  terminal response or effect bytes.
- [x] Grep `Sources/LabanTerminalCore/session.c`; expect capture callback calls
  before `ghostty_terminal_vt_write` consumes PTY output bytes and after every
  successful PTY input write path.
- [x] Run `swift test --filter CaptureRecorderTests`; expect tests for
  monotonic sequence numbers, sidecar byte offsets, SHA-256 hashes, atomic
  finalize, partial-capture recovery, and private-file permissions where the
  platform supports them.
- [x] Run `swift test --filter CaptureReplayTests`; expect a deterministic
  fixture capture to replay and match terminal text, terminal dimensions,
  frame-command hash, and screenshot hash for at least one frame.
- [x] Run `swift test --filter LabanDebugCaptureTests`; expect debug capture
  start/status/stop/snapshot endpoints, capture disabled by default, and
  rejection of capture paths outside the requested artifact directory.
- [x] Run `./scripts/test-e2e`; expect it to create a capture artifact during a
  deterministic headless run, replay that artifact, and compare the replay
  report as passing.
- [x] Run `./scripts/replay-capture <artifact>` on the E2E-generated artifact;
  expect exit 0 and a report containing `terminalReplay: passed` and
  `rendererReplay: passed`.
- [x] Launch the AppKit app with capture enabled, run a small interactive
  sequence including typing, resize, scroll, and a TUI, stop capture, then
  replay the artifact. Record the command and replay result in `Outcomes &
  Retrospective`.
- [x] Inspect the generated capture directory. Expect a manifest, timeline
  NDJSON, PTY byte sidecars, frame-command sidecars, replay report, and no
  files outside the requested artifact directory.

Review status: PASSED on 2026-05-17 by a fresh-state review agent against
HEAD `a9bff444f47ba7e1bf74ea3c22ed64abefbde278`. The "Launch AppKit with
capture enabled" item explicitly requires a human; the prior 2026-05-04
manual acceptance (`appkit-2026-05-04T19-19-03Z`, 76 frames, both replays
passed) remains documented above and was not re-driven in this rerun.

Review findings (2026-05-04T19:15:33Z, fresh-state review against HEAD
`dd82e254d2893bb126ab964f90c99954dae5f2af`):

- `./scripts/check` passed and ended with `check passed`.
- `find schemas -name '*.json' -print0 | xargs -0 -n1 jq empty` passed.
- Generated capture
  `.artifacts/runs/e2e-1777921319-15259/captures/e2e-capture/manifest.json`
  and its first `timeline.ndjson` event passed `jq` validation against the
  required fields and enum values from `schemas/capture/manifest.schema.json`
  and `schemas/capture/event.schema.json`.
- Header grep found `LABAN_CAPTURE_BYTES_PTY_INPUT`,
  `LABAN_CAPTURE_BYTES_PTY_OUTPUT`,
  `LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE`, and
  `laban_session_set_capture_callback` in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`.
- Source grep found `emit_capture_bytes` before
  `ghostty_terminal_vt_write` in `vt_write_capture`, after successful
  `write_pty_input` writes, and after successful terminal response writes in
  `Sources/LabanTerminalCore/session.c`.
- `swift test --filter CaptureRecorderTests` passed 6 tests.
- `swift test --filter CaptureReplayTests` passed 5 tests.
- `swift test --filter LabanDebugCaptureTests` passed 4 tests.
- `./scripts/test-e2e` passed.
- `./scripts/replay-capture .artifacts/runs/e2e-1777921319-15259/captures/e2e-capture`
  passed with `terminalReplay: passed`, `rendererReplay: passed`, and
  `framesCompared: 17`.
- Capture directory inspection found `manifest.json`, `timeline.ndjson`,
  `streams/pty-input.bin`, `streams/pty-output.bin`,
  `streams/terminal-response.bin`, frame command/render/snapshot sidecars,
  screenshots, `snapshots/`, and `replay/report.json` under the capture
  directory. The parent E2E run also contains expected non-capture E2E
  artifacts (`long-line-render.json`, `long-line.png`, and
  `screenshots/frame-000001.png`).
- Manual AppKit launch was later performed by the user. Initial replay exposed
  AppKit replay gaps; after fixes, replay of
  `.artifacts/appkit-manual/appkit-2026-05-04T19-19-03Z` passed with
  `terminalReplay: passed`, `rendererReplay: passed`, and
  `framesCompared: 76`.

Review findings (2026-05-17, fresh-state rerun against HEAD
`a9bff444f47ba7e1bf74ea3c22ed64abefbde278`):

All autonomous gate checks passed. `./scripts/check` ended with
`check passed`; `jq empty` validated every file in `schemas/`; the freshly
produced E2E capture manifest and first timeline event satisfied the required
fields/enum from `schemas/capture/manifest.schema.json` and
`schemas/capture/event.schema.json`; the capture ABI symbols
(`LABAN_CAPTURE_BYTES_PTY_INPUT/OUTPUT/TERMINAL_RESPONSE` and
`laban_session_set_capture_callback`) are present in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h`. The session-file
split landed since 2026-05-04, so the capture emission contracts now live
in `Sources/LabanTerminalCore/capture.c` (PTY-output bytes emitted
immediately before `ghostty_terminal_vt_write` inside
`laban_vt_write_capture`), `Sources/LabanTerminalCore/pty_io.c`
(`laban_write_pty_bytes` emits the direction tag after each successful PTY
write), and `Sources/LabanTerminalCore/terminal_effects.c` (terminal
responses emit `LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE`). `CaptureRecorderTests`
passed 8 tests, `CaptureReplayTests` 9, `LabanDebugCaptureTests` 5.
`./scripts/test-e2e` exited 0 and produced
`.artifacts/runs/e2e-1778309160-92866/captures/e2e-capture`;
`./scripts/replay-capture` on that artifact reported `terminalReplay: passed`,
`rendererReplay: passed`, `framesCompared: 20`, no mismatches. The capture
directory contains `manifest.json`, `timeline.ndjson`, `streams/*.bin`,
`frames/*.{commands,render,snapshot}.json` plus a frame PNG, and
`replay/report.json`, all confined to the requested artifact directory. The
manual "Launch AppKit with capture enabled" item still requires a human user;
the prior 2026-05-04 acceptance (76 frames, both replays passed) remains in
scope and was not re-driven.

## Context and Orientation

The relevant source files and responsibilities are:

- `Sources/LabanTerminalCore/session.c` owns the C terminal session, PTY file
  descriptor, libghostty terminal, PTY polling, PTY writes, resize, mouse
  encoding, and snapshots. Add low-level byte capture callbacks here.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` is the public C ABI
  consumed by Swift. Add capture callback types here without exposing Ghostty
  handles to Swift.
- `Sources/LabanCore/Session.swift` wraps the C ABI. It owns the Swift session
  ID and should attach session-aware capture sinks to C sessions.
- `Sources/LabanCore/AppModel.swift` owns tabs and sessions. Capture must log
  tab create/select/close and session identity transitions here or at the
  call sites that mutate the model.
- `Sources/LabanCore/FrameProducer.swift` and
  `Sources/LabanCore/SidebarProducer.swift` produce frame commands from model
  and terminal state. Capture must record the produced command stream for
  replay.
- `Sources/LabanRenderer/SoftwareRenderer.swift` and
  `Sources/LabanRenderer/BitmapSurface.swift` render frame commands into a
  bitmap. Renderer replay should use the same renderer code.
- `Sources/LabanApp/TerminalBitmapView.swift` owns the interactive AppKit frame
  loop, input routing, resize, rendering, copy, paste, and mouse events. It
  must emit input envelopes and frame capture events for interactive runs.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` owns the headless runtime,
  debug actions, screenshots, frame commands, render traces, and events. It
  should use the same capture recorder as AppKit and should expose capture
  control endpoints.
- `Sources/LabanDebug/DebugHTTPServer.swift` maps local HTTP requests to the
  runtime. Add `/debug/capture/...` endpoints here.
- `Sources/LabanAgent/main.swift` parses command-line flags for headless and
  debug-server modes. Add capture and replay flags here.
- `schemas/debug/input-log.schema.json` and
  `schemas/debug/terminal-log.schema.json` describe bounded debug projections.
  Keep them as projections, not the durable capture format.
- `schemas/artifact-manifest.schema.json` describes E2E artifact manifests.
  Capture should add dedicated schemas under `schemas/capture/`.

Definitions used in this plan:

- Capture means writing a durable local artifact from a real run. It includes
  timeline events, byte streams, frame commands, hashes, and selected images.
- Replay means reading a capture artifact and recreating observable behavior
  without requiring the original child process. Default replay feeds captured
  PTY output bytes into fixture sessions and compares recorded outputs.
- Timeline means one ordered event stream. Every capture event gets a
  monotonic `seq` integer. Frame numbers alone are not enough because many
  input and PTY events can happen between frames.
- PTY input means bytes Laban writes to the PTY master. From the child
  process's perspective these are keyboard, paste, mouse, terminal response,
  and app-generated bytes.
- PTY output means bytes Laban reads from the PTY master and feeds into
  libghostty's terminal parser.
- Terminal response means bytes generated by the terminal core and written
  back to the PTY in response to application queries, such as device
  attributes or capability replies.
- Frame command means a backend-neutral drawing command such as rect,
  glyphRun, cursor, selection, or texturedQuad.
- Terminal-byte replay means replaying captured PTY output, resize, tab, and
  frame-boundary events through Laban's terminal and renderer pipeline.
- Renderer-only replay means rendering captured frame commands directly,
  without libghostty or PTY byte parsing, to isolate renderer regressions.

## Artifact Format

Create one capture directory per run. The directory must be self-contained and
safe to move to another checkout on the same platform.

```text
.artifacts/captures/<run-id>/
  manifest.json
  timeline.ndjson
  streams/
    pty-input.bin
    pty-output.bin
    terminal-response.bin
  frames/
    frame-000001.commands.json
    frame-000001.render.json
    frame-000001.snapshot.json
    frame-000001.png
  snapshots/
    snapshot-000018/
      manifest.json
      state.json
      sessions.json
      events.json
      input-log.json
      terminal-log.json
      render.json
      frame-commands.json
      render-trace.json
      screenshot.png
  replay/
    report.json
    frame-000001.png
```

`manifest.json` should include:

```json
{
  "schemaVersion": 1,
  "kind": "laban-capture",
  "runId": "capture-20260504-123456",
  "createdAt": "2026-05-04T10:34:56Z",
  "finishedAt": "2026-05-04T10:35:20Z",
  "app": {
    "gitSha": "unknown-or-sha",
    "buildConfiguration": "debug",
    "executable": "LabanApp"
  },
  "privacy": {
    "containsTerminalBytes": true,
    "containsScreenshots": true,
    "redaction": "none"
  },
  "timeline": {"path": "timeline.ndjson", "events": 1234},
  "streams": {
    "ptyInput": {"path": "streams/pty-input.bin", "sha256": "...", "bytes": 42},
    "ptyOutput": {"path": "streams/pty-output.bin", "sha256": "...", "bytes": 9912}
  },
  "frames": {"count": 18, "first": 1, "last": 18}
}
```

`timeline.ndjson` is newline-delimited JSON. Each line is one event. All event
types share this envelope:

```json
{
  "seq": 42,
  "timeNs": 123456789,
  "kind": "pty.output",
  "frame": 7,
  "tabId": "tab-1",
  "sessionId": "session-1"
}
```

Required event kinds:

- `capture.started`
- `capture.finished`
- `app.state`
- `tab.created`
- `tab.selected`
- `tab.closed`
- `session.created`
- `session.resized`
- `session.exited`
- `input.event`
- `pty.input`
- `pty.output`
- `terminal.response`
- `frame.begin`
- `terminal.snapshot`
- `frame.commands`
- `frame.rendered`
- `screenshot.captured`
- `capture.snapshot`
- `capture.error`

Byte events reference sidecar offsets:

```json
{
  "seq": 99,
  "kind": "pty.output",
  "frame": 12,
  "sessionId": "session-1",
  "stream": "pty-output",
  "offset": 128,
  "length": 24,
  "sha256": "sha-of-these-24-bytes",
  "escapedPreview": "\\u001b[?1h"
}
```

Frame command events reference JSON sidecars:

```json
{
  "seq": 120,
  "kind": "frame.commands",
  "frame": 12,
  "path": "frames/frame-000012.commands.json",
  "sha256": "sha-of-command-json",
  "commandCount": 384
}
```

Input events use the input envelope from the keyboard plan and add replay
context:

```json
{
  "seq": 87,
  "kind": "input.event",
  "inputId": "input-000087",
  "source": "appkit",
  "frameBefore": 11,
  "tabId": "tab-1",
  "sessionId": "session-1",
  "inputKind": "key",
  "route": "terminal",
  "key": "arrowUp",
  "modifiers": ["shift"],
  "consumedModifiers": [],
  "encodedHex": "1b5b313b3241",
  "encodedLength": 6
}
```

Add schemas:

- `schemas/capture/manifest.schema.json`
- `schemas/capture/event.schema.json`
- `schemas/capture/replay-report.schema.json`

Update `schemas/README.md` to list them. Keep `additionalProperties: true` for
forward compatibility, but require the fields needed for replay.

## Milestones

### Milestone 1: Capture Types And Schemas

Add the shared model and schema foundation without touching the terminal core
yet.

Implementation requirements:

- Add `Sources/LabanCore/CaptureTypes.swift` or an equivalent shared file with:
  - `CaptureEventKind`;
  - `CaptureTimelineEvent`;
  - `CaptureByteDirection`;
  - `CaptureByteRef`;
  - `CaptureFrameRef`;
  - `InputEventEnvelope` if the keyboard plan has not already added it.
- The types must be plain `Codable` Swift structs/enums where possible. They
  should not import AppKit, CoreGraphics, or Ghostty.
- Add a protocol:

  ```swift
  public protocol CaptureSink: AnyObject {
    func nextSequence() -> Int
    func record(_ event: CaptureTimelineEvent)
    func recordBytes(
      direction: CaptureByteDirection,
      sessionId: Session.ID?,
      frame: Int,
      bytes: UnsafeRawBufferPointer,
      preview: String?
    ) -> CaptureByteRef?
  }
  ```

  Adjust the exact signature if needed, but preserve the concept: callers can
  record structured events and sidecar bytes without knowing file paths.

- Add `Sources/LabanDebug/CaptureRecorder.swift` to implement the file-backed
  writer. It should:
  - create the capture directory under the configured artifact directory;
  - write `manifest.json.tmp` first and rename to `manifest.json` on finalize;
  - append JSON lines to `timeline.ndjson`;
  - append bytes to `streams/*.bin` and return offset/length/hash refs;
  - use a lock because AppKit/debug callbacks may arrive from different
    threads later;
  - mark the capture as `interrupted` if deinitialized without `finish()`;
  - set file permissions to owner-only when supported.

- Add schema files and tests that validate a minimal manifest, event, and
  replay report.

Acceptance for this milestone:

- `swift test --filter CaptureRecorderTests` passes for manifest creation,
  sequence monotonicity, byte sidecars, and finalize.
- `find schemas -name '*.json' -print0 | xargs -0 -n1 jq empty` passes.

### Milestone 2: Terminal Core Byte Capture Hooks

Record the exact bytes that cross the PTY boundary.

In `Sources/LabanTerminalCore/include/LabanTerminalCore.h`, add a callback ABI:

```c
typedef enum {
    LABAN_CAPTURE_BYTES_PTY_INPUT = 0,
    LABAN_CAPTURE_BYTES_PTY_OUTPUT = 1,
    LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE = 2
} LabanCaptureBytesDirection;

typedef void (*LabanCaptureBytesCallback)(
    void *userdata,
    LabanSession *session,
    LabanCaptureBytesDirection direction,
    const uint8_t *bytes,
    size_t len
);

int laban_session_set_capture_callback(
    LabanSession *session,
    LabanCaptureBytesCallback callback,
    void *userdata
);
```

If passing `LabanSession *` to the callback complicates Swift bridging, omit it
and rely on the per-session userdata. Do not expose Ghostty handles.

In `Sources/LabanTerminalCore/session.c`:

- Store the callback and userdata in `struct LabanSession`.
- In `laban_session_poll`, call the callback with
  `LABAN_CAPTURE_BYTES_PTY_OUTPUT` after a successful `read` and before
  `ghostty_terminal_vt_write`.
- In `laban_session_write`, call the callback with
  `LABAN_CAPTURE_BYTES_PTY_INPUT` after a successful PTY write in real PTY
  mode. In fixture mode, record the bytes as PTY output or fixture input only
  if the caller explicitly asks through a replay helper; do not mislabel
  fixture parser bytes as live child output.
- In `laban_session_send_mouse` and the planned `laban_session_send_key`, rely
  on the same PTY write helper so bytes are captured once.
- Capture terminal-generated responses after successful writes with
  `LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE` if those responses use a distinct
  path; otherwise record them as PTY input with an event field marking source
  `terminalResponse`.
- Capture resize as a structured event from Swift after successful
  `laban_session_resize`, including rows, cols, pixel width/height, cell size,
  tab ID, and session ID.

In `Sources/LabanCore/Session.swift`:

- Add optional `captureSink`.
- Add a C callback trampoline that maps bytes back to the Swift `Session` and
  calls `captureSink.recordBytes(...)`.
- Include the Swift session ID in recorded events because the C session does
  not know it.
- Ensure callback userdata is retained until `Session.close()` and released
  safely. Add tests for close/deinit without use-after-free.

Acceptance for this milestone:

- A terminal-core or LabanCore test writes bytes to a fixture or controlled
  PTY session and proves capture records byte direction, length, and offset.
- A real-shell smoke test captures at least one PTY output byte event after
  `poll()`.

### Milestone 3: Input Envelopes Across AppKit And Headless

Make all input paths emit replay-compatible facts.

Implementation requirements:

- If the keyboard plan has already added `InputEventEnvelope`, reuse it. If
  not, add it here and update the keyboard plan implementation to use it.
- AppKit input paths in `TerminalBitmapView` must record:
  - raw bounded platform facts: keyCode, characters, charactersIgnoringModifiers,
    modifier flags, event type, repeat flag, and timestamp when available;
  - normalized key/mouse/paste/copy/command fields;
  - route: `terminal`, `appCommand`, `sidebar`, `selection`, or `ignored`;
  - `frameBefore`;
  - tab ID and session ID;
  - encoded bytes for terminal-routed key and mouse events;
  - resulting command name for app commands.
- Headless debug actions in `HeadlessDebugRuntime` must emit the same envelope
  shape for `typeText`, `key`, `mouseWheel`, `click`, `copy`, `paste`, and tab
  commands.
- `/debug/input-log` must remain a bounded projection over the same envelopes.
  Do not duplicate route logic just for debug JSON.
- Input envelopes must be recorded before and after encoding where useful:
  record the raw/normalized event before writing to the PTY, then update or
  follow with a `pty.input` event containing the exact byte reference after
  the C write succeeds.

Acceptance for this milestone:

- `swift test --filter TerminalKeyInputTests` and
  `swift test --filter LabanDebugKeyboardSmokeTests` pass if the keyboard plan
  has landed.
- `swift test --filter CaptureInputEnvelopeTests` proves AppKit-style and
  debug-style inputs produce the same envelope fields for the same logical
  key.

### Milestone 4: Lockstep Frame Capture

Capture frame boundaries and render products in both interactive and headless
paths.

In `TerminalBitmapView.advanceFrame()` and
`HeadlessDebugRuntime.renderFrameUnlocked()`:

- Ask the capture sink for a new frame number or use the existing frame number
  but emit `frame.begin` before polling/snapshot/render work for that frame.
- Record session poll events and any PTY output byte refs produced during
  polling before recording the terminal snapshot for that frame.
- After `session.snapshot()`, serialize a bounded terminal snapshot sidecar
  for the active session:
  - rows, cols, cursor position/visibility, title, status, mouse tracking,
    focus reporting, dirty flag, and a hash of visible cells;
  - visible text may be included in explicit capture mode because capture is
    already sensitive, but keep it bounded to the visible grid.
- After producing frame commands, write `frames/frame-N.commands.json` and
  record a `frame.commands` event with path, command count, and SHA-256.
- After `renderer.render(cmds)`, record `frame.rendered` with surface size,
  scale, backend, draw stats, and optional pixel hash.
- Capture screenshots:
  - always on explicit `/debug/snapshot`;
  - always on capture stop for the final frame;
  - every frame only when `--capture-screenshots=all` or a debug option is set;
  - on test failures through `./scripts/test-e2e`.
- Ensure the same frame IDs appear in input envelopes, PTY events, frame
  command refs, render traces, and screenshot events.

Acceptance for this milestone:

- A headless run with capture enabled produces `frame.begin`,
  `terminal.snapshot`, `frame.commands`, and `frame.rendered` timeline events
  for the same frame number.
- The frame command sidecar can be decoded and rendered by a test without
  needing a live session.

### Milestone 5: Capture Controls And CLI

Expose capture in both debug-server and command-line flows.

In `Sources/LabanAgent/main.swift`, add flags:

```text
--capture=<dir-or-name>
--capture-screenshots=final|marked|all|none
--replay-capture=<path>
--replay-mode=terminal|renderer|both
```

Rules:

- `--capture=<relative-name>` resolves under the current artifacts directory.
- `--capture=<absolute-path>` is allowed only if it is under `--artifacts` or
  an explicitly allowed capture root. Prefer rejecting absolute paths in the
  first implementation.
- Capture may be used with `--headless --debug-server`, one-shot fixtures, and
  eventually `LabanApp`.
- Capture is disabled by default.

In `Sources/LabanDebug/DebugHTTPServer.swift`, add:

- `GET /debug/capture/status`
- `POST /debug/capture/start`
- `POST /debug/capture/stop`
- `POST /debug/capture/snapshot`

`POST /debug/capture/start` accepts:

```json
{
  "name": "keyboard-bug-001",
  "screenshots": "marked"
}
```

It returns the capture directory, run ID, and whether capture was already
active. Starting capture when active should return a clear 409-style JSON
error rather than replacing the current artifact.

`POST /debug/capture/stop` finalizes the manifest, writes final state, and
returns a manifest path.

`POST /debug/capture/snapshot` writes a point-in-time diagnostic bundle inside
the capture directory and records `capture.snapshot` in the timeline. It may
reuse the existing `/debug/snapshot` behavior but must link the snapshot
manifest from the capture timeline.

Acceptance for this milestone:

- Debug tests can start capture, drive actions, stop capture, and inspect a
  manifest with paths and byte counts.
- Capture path validation prevents writing outside the artifact directory.

### Milestone 6: Terminal-Byte Replay

Implement default replay: recreate terminal/render state from captured bytes.

Add `Sources/LabanDebug/CaptureReplayRunner.swift` or equivalent.

Replay algorithm:

1. Load `manifest.json` and `timeline.ndjson`.
2. Validate schema version and required sidecar files.
3. Create a fresh `AppModel` using fixture sessions, not real shells.
4. Recreate tab/session creation, selection, close, and resize events from the
   timeline.
5. For each `pty.output` event, read the referenced bytes from
   `streams/pty-output.bin` and feed them to the matching fixture session's
   terminal parser using a new explicit replay helper such as
   `session.replayPtyOutput(bytes)`. Do not use `laban_session_write` if its
   semantics imply "user input to child"; add a clearly named ABI if needed.
6. At each captured `frame.begin`, poll no live PTY, snapshot the active
   session, produce frame commands, render, and compare:
   - terminal snapshot hash;
   - frame command SHA-256;
   - screenshot SHA-256 when a recorded screenshot exists or when replay is
     asked to render screenshots.
7. For each `input.event` with `encodedHex`, optionally re-run key/mouse
   encoding against the replay terminal state and compare encoded bytes. This
   catches keyboard encoder regressions even though replay output comes from
   captured PTY output.
8. Write `replay/report.json` with pass/fail per check and bounded diffs.

Replay report shape:

```json
{
  "schemaVersion": 1,
  "captureRunId": "capture-20260504-123456",
  "terminalReplay": "passed",
  "rendererReplay": "passed",
  "framesCompared": 18,
  "mismatches": []
}
```

Add a script:

```sh
./scripts/replay-capture .artifacts/captures/<run-id>
```

The script should run the package executable in replay mode and preserve the
report under the capture directory or requested artifacts directory.

Acceptance for this milestone:

- Replaying a deterministic fixture capture reproduces terminal text and frame
  command hashes.
- If a test intentionally mutates one recorded frame-command hash, replay
  fails with a bounded mismatch that names the frame and expected/actual hash.

### Milestone 7: Renderer-Only Replay

Render captured frame commands directly.

Implementation requirements:

- Add a frame-command decoder for captured `frames/frame-N.commands.json`.
  Reuse the same serialized shape as `/debug/frame-commands` where possible.
- Add a renderer replay mode that:
  - creates a `BitmapSurface` with captured surface width, height, and scale;
  - renders the captured commands through `SoftwareRenderer`;
  - compares screenshot hash if available;
  - writes replay PNGs under `replay/` when mismatches occur or when requested.
- Keep renderer-only replay independent from libghostty. It should not need a
  `LabanSession`.

Acceptance for this milestone:

- `./scripts/replay-capture --mode=renderer <capture>` passes on a deterministic
  capture with recorded frame commands.
- A renderer-only mismatch report identifies the frame, command sidecar, and
  screenshot path.

### Milestone 8: E2E And In-The-Wild Acceptance

Add automated and manual coverage.

Automated tests:

- `swift test --filter CaptureRecorderTests`
- `swift test --filter CaptureReplayTests`
- `swift test --filter LabanDebugCaptureTests`
- `./scripts/test-e2e`
- `./scripts/replay-capture <artifact from test-e2e>`

Extend `scripts/test-e2e`:

1. Start `laban-agent --headless --debug-server=127.0.0.1:0 --capture=e2e-capture`.
2. Drive existing tab, type, resize, scroll, mouse, and screenshot checks.
3. Stop capture through `/debug/capture/stop`.
4. Validate capture manifest and timeline exist.
5. Run replay on the generated capture.
6. Assert replay report says terminal and renderer replay passed.

Manual acceptance:

1. Build the AppKit app.
2. Launch it with capture enabled, using an artifact path under `.artifacts`.
3. Run a small real workflow: type shell text, resize the window, scroll, run
   `cat -v`, then run one installed TUI such as `vim`, `nvim`, `less`, or
   `tmux`.
4. Stop capture.
5. Run `./scripts/replay-capture` on the artifact.
6. Record the command, replay report path, frames compared, and any mismatch
   under `Outcomes & Retrospective`.

## Concrete Steps

Run commands from the repository root:

```sh
pwd
# /Users/dev/wrk/laban/.claude/worktrees/still-glowing-cobra

swift test --filter CaptureRecorderTests
swift test --filter CaptureReplayTests
swift test --filter LabanDebugCaptureTests
./scripts/test-e2e
./scripts/replay-capture .artifacts/captures/<run-id>
./scripts/check
```

During implementation, use focused tests after each milestone. Before marking
this ExecPlan complete, run every Review Gate check and update `Progress` with
the results.

## Validation and Acceptance

This plan is complete only when:

- A capture can be started and stopped explicitly in headless debug mode.
- A capture can be enabled for the AppKit app without desktop automation.
- Captures include one ordered timeline connecting input, PTY bytes, terminal
  snapshots, frame commands, render events, and screenshots or screenshot
  hashes.
- PTY output bytes are captured before terminal parsing.
- PTY input bytes are captured after successful PTY writes.
- Input events include raw bounded platform facts, normalized facts, route,
  consumed modifiers, encoded bytes, frame, tab, and session references.
- Frame-command sidecars are written for captured frames.
- Terminal-byte replay passes on a deterministic capture.
- Renderer-only replay passes on captured frame commands.
- Replay failures produce bounded diffs that identify frame IDs, session IDs,
  event sequences, paths, and expected/actual hashes.
- Capture artifacts stay under the requested artifact directory.
- `./scripts/check` passes.

## Idempotence and Recovery

Capture start should fail if capture is already active. Capture stop should be
safe to call more than once: the first call finalizes, and later calls return
the existing manifest path.

The recorder should write temporary manifest files and rename atomically on
finalize. If the process crashes, the capture directory should still contain
`timeline.ndjson` and stream sidecars. Replay should detect an interrupted
capture, warn, and replay events up to the last complete JSON line.

All generated files belong under `.artifacts/` or the requested artifact
directory. Do not clean or rewrite unrelated captures. Tests should create
unique run IDs and clean only their own temp paths.

If C capture callbacks cause a crash or use-after-free, disable capture by
default and add focused lifecycle tests before continuing. The non-capture app
path must remain unaffected.

## Security And Privacy

Capture artifacts can contain passwords, tokens, prompts, command output,
clipboard text, screenshots, paths, environment summaries, and shell output.
Implement these rules:

- Capture is off by default.
- Capture paths must be local filesystem paths under an artifact root.
- Debug capture controls remain loopback-only.
- File permissions should be owner-only where supported.
- Manifest privacy metadata must state whether bytes and screenshots are
  present and whether redaction is none.
- Do not include the full environment by default. Record a bounded environment
  summary: keys relevant to terminal behavior such as `TERM`, `COLORTERM`,
  shell executable, rows, cols, cell size, locale, and app build info. Redact
  values for secret-looking keys.
- Do not upload, print, or paste capture contents in final responses.

## Interfaces and Dependencies

Use existing project dependencies and standard Foundation APIs. Do not add a
database, tracing service, or external telemetry dependency for this milestone.

Required interfaces at completion:

- C ABI in `LabanTerminalCore.h` for capture byte callbacks and explicit PTY
  output replay into fixture sessions.
- Swift `CaptureSink` protocol and `CaptureRecorder` implementation.
- Reusable `InputEventEnvelope`.
- Debug endpoints:
  - `GET /debug/capture/status`
  - `POST /debug/capture/start`
  - `POST /debug/capture/stop`
  - `POST /debug/capture/snapshot`
- CLI flags:
  - `--capture=...`
  - `--capture-screenshots=final|marked|all|none`
  - `--replay-capture=...`
  - `--replay-mode=terminal|renderer|both`
- Scripts:
  - `./scripts/replay-capture`

## Outcomes & Retrospective

Implemented a full local capture artifact path with `manifest.json`,
`timeline.ndjson`, PTY byte sidecars, frame-command sidecars, terminal snapshot
sidecars, render sidecars, optional screenshots, debug capture controls,
headless CLI capture flags, AppKit menu capture, terminal-byte replay, and
renderer-only replay.

Validation run on 2026-05-04:

```text
find schemas -name '*.json' -print0 | xargs -0 -n1 jq empty
swift test --filter CaptureRecorderTests
swift test --filter CaptureReplayTests
swift test --filter LabanDebugCaptureTests
swift test --filter CaptureSessionBridgeTests
swift test --filter TerminalKeyInputTests
swift test --filter LabanDebugKeyboardSmokeTests
./scripts/test-e2e
./scripts/replay-capture .artifacts/runs/e2e-1777921319-15259/captures/e2e-capture
./scripts/check
```

Observed results: all commands above passed. The replay command reported
`terminalReplay: passed`, `rendererReplay: passed`, and `framesCompared: 17`.
`./scripts/check` ended with `check passed`.

Additional local Review Gate evidence from continuing execution on 2026-05-04:

```text
find schemas -name '*.json' -print0 | xargs -0 -n1 jq empty
swift test --filter CaptureRecorderTests
swift test --filter CaptureReplayTests
swift test --filter LabanDebugCaptureTests
./scripts/test-e2e
./scripts/replay-capture .artifacts/runs/e2e-1777921319-15259/captures/e2e-capture
```

Observed results: all commands above passed. Header grep confirmed
`LABAN_CAPTURE_BYTES_PTY_INPUT`, `LABAN_CAPTURE_BYTES_PTY_OUTPUT`,
`LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE`, and
`laban_session_set_capture_callback` in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h`. Source grep confirmed
capture emission before VT parser writes and after PTY input/terminal response
write paths in `Sources/LabanTerminalCore/session.c`. The inspected capture
directory contained `manifest.json`, `timeline.ndjson`, stream sidecars, frame
command sidecars, and `replay/report.json`; replay reported
`terminalReplay: passed`, `rendererReplay: passed`, and `framesCompared: 17`.

Manual AppKit evidence from 2026-05-04:

```text
./scripts/replay-capture .artifacts/appkit-manual/appkit-2026-05-04T19-19-03Z
swift test --filter CaptureReplayTests
./scripts/test-e2e
./scripts/check
git diff --check
```

Observed results: the manual AppKit artifact replay passed with
`terminalReplay: passed`, `rendererReplay: passed`, and `framesCompared: 76`.
The regression test `testReplayHandlesAppKitMidSessionCaptureAndLegacyScroll`
now covers AppKit-style layout, a capture started after an existing prompt, and
a legacy local scroll segment without recorded scroll input. `./scripts/check`
ended with `check passed`; `git diff --check` produced no output.

Known remaining gate: the fresh-state Review Gate was run before the AppKit
follow-up fixes. The implementation is locally validated, but this ExecPlan
should not be considered complete until the independent Review Gate is rerun
against the current changes.
