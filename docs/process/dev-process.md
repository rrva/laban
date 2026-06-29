# Agent-Driven Development Process

This document defines the development process and test harness required for
fully agent-driven implementation. The goal is not just automated tests; the
goal is that an agent can build, run, observe, diagnose, and verify the app
end to end without human-operated UI.

The debug/test surface is product infrastructure. It should be implemented
early, kept small, and treated as part of the MVP.

The debug protocol is app-level. The terminal core exposes inspectable state
and control primitives, but it does not own HTTP, JSON, artifact directories,
or debug-server concerns.

## Principles

- Every visible behavior must be observable by an agent.
- Every important internal state transition must be queryable by an agent.
- The same rendering path must be testable with and without a visible window.
- Tests should exercise real terminal behavior whenever possible, but they
  should also support deterministic fake sessions for exact assertions.
- Debug hooks are opt-in, local-only, and unavailable in production builds
  unless explicitly enabled by a developer flag.

## Required Run Modes

The app should support these modes from the beginning.

### Interactive Mode

Normal developer run with a visible window.

Required capabilities:

- debug endpoint can be enabled with a flag
- screenshots can be captured through the same debug hook used in CI
- state can be queried while a human or agent interacts with the app

Example shape:

```sh
app --debug-server=127.0.0.1:0
```

### Headless Mode

No visible OS window, but the app still creates terminal sessions, processes
input, advances frames, and renders into an inspectable offscreen surface.

Required capabilities:

- works in a cloud CI environment without a display server
- produces screenshots from the actual renderer or a renderer-equivalent
  offscreen target
- exposes the same debug state endpoints as interactive mode
- can run with deterministic clocks and deterministic test shell/session input
- supports fixture sessions as the primary CI gate
- supports controlled real-shell smoke sessions with a sanitized fixed
  shell/command

Example shape:

```sh
app --headless --debug-server=127.0.0.1:0 --artifacts=.artifacts/run-001
```

### Test Fixture Mode

Runs controlled sessions instead of the user's real shell. This is the primary
CI mode for visual and stateful headless tests. It allows exact, repeatable
tests for colors, glyphs, resize, exit state, title updates, and mouse
behavior.

Required capabilities:

- launch a scripted pty child or in-memory fake session
- emit known byte sequences
- wait for expected terminal state
- capture screenshots and state snapshots at deterministic points

Example shape:

```sh
app --headless --fixture=fixtures/colored-boxes.json --debug-server=127.0.0.1:0
```

## Debug Server Contract

Expose a small HTTP server bound to loopback only. If port `0` is requested,
the app chooses a free port and prints a single machine-readable line to stdout:

```json
{"debugServer":"http://127.0.0.1:49321","debugToken":"<bearer-token>","pid":12345,"runId":"abc123"}
```

Every `/debug` request must include `Authorization: Bearer <bearer-token>`.
The token is only emitted in the readiness JSON.

The server must be disabled by default. It must not listen on public interfaces.
It must not be enabled in release builds unless an explicit developer flag is
present.

### Discovery

`GET /debug`

Returns a live capability index for agents. This is the first endpoint to call
after parsing the readiness URL. It lists supported endpoints, schema paths
where they exist, action names, wait conditions, fixture controls, artifact
root, and short curl examples.

`GET /debug/capabilities`

Alias for `/debug` for tools that look for an explicit capabilities document.

The agent executable should also expose these entry points from `--help`, and
`./scripts/run-debug` should remain a stable way to start a discoverable local
debug server.

### Debug Scripts

`./scripts/run-debug-script <scenario.json>`

Runs a local JSON scenario against the debug server. By default the runner
builds `laban-agent`, starts a headless loopback debug server, executes each
step, writes `debug-script-report.json` under `.artifacts/runs/<run-id>/`, and
shuts down the server it started. Use `--server <url>` to run a scenario
against an already-running debug server.

The scenario schema is `schemas/debug-script.schema.json`. A scenario step maps
to one existing endpoint: `discover` calls `GET /debug`, `action` posts to
`/debug/actions`, `wait` posts to `/debug/wait`, `snapshot` posts to
`/debug/snapshot`, and `screenshot` captures `GET /debug/screenshot`.

### Health

`GET /debug/health`

Returns process readiness.

```json
{
  "ok": true,
  "mode": "headless",
  "frame": 12,
  "focused": true
}
```

### Screenshot

`GET /debug/screenshot`

Returns a PNG of the current rendered surface. Query parameters:

- `target=window|terminal|sidebar|tab:<id>`; default `window`
- `scale=1|2`; default current backing scale
- `format=png`; default `png`

Response headers should include:

- `Content-Type: image/png`
- `X-App-Frame: <frame-number>`
- `X-App-Size: <width>x<height>`

`POST /debug/screenshot`

Same capture, but writes into the artifact directory and returns metadata:

```json
{
  "path": ".artifacts/run-001/screenshots/frame-000012.png",
  "width": 1280,
  "height": 800,
  "frame": 12,
  "target": "window"
}
```

The screenshot hook must capture the app-rendered surface, not the OS desktop.
This is what makes it usable in headless cloud environments.

### Full Capture Replay

Screenshots, bounded debug logs, and `/debug/state` are fast diagnostics. Use a
full capture when a bug depends on real input ordering, PTY bytes, terminal
parser state, resize timing, scrollback position, or rendered frame commands.
The capture artifact is the durable repro contract for in-the-wild terminal
failures.

Full captures are explicit and local-only. They can contain typed input,
clipboard text, terminal output, screenshots, paths, and secrets. Do not upload
them or paste their contents into responses. Store them under `.artifacts/` or
an explicitly requested local artifact root.

Artifact shape:

- `manifest.json` describes the run, privacy flags, streams, and frame count.
- `timeline.ndjson` is the ordered sequence of input, PTY, session, snapshot,
  frame-command, render, screenshot, tab-metadata (`tab.metadata`: mirrored
  tab-state journal entries — title, status, selection, notification badge),
  and capture lifecycle events.
- `streams/*.bin` stores PTY input, PTY output, and terminal response bytes.
- `frames/*.snapshot.json` stores visible terminal snapshots and hashes.
- `frames/*.commands.json` stores the frame-command stream for renderer replay.
- `frames/*.png` is present when screenshots are captured.
- `replay/report.json` is written by replay and records pass/fail details.

Headless/debug-server capture:

```sh
.build/debug/laban-agent \
  --headless \
  --debug-server=127.0.0.1:0 \
  --artifacts=.artifacts/run-001 \
  --capture=capture-001 \
  --capture-screenshots=final
```

The debug server also exposes capture controls:

- `GET /debug/capture/status`
- `POST /debug/capture/start`
- `POST /debug/capture/stop`
- `POST /debug/capture/snapshot`

AppKit capture:

```sh
mkdir -p .artifacts/appkit-manual
LABAN_CAPTURE_DIR="$PWD/.artifacts/appkit-manual" \
  .build/laban/Laban.app/Contents/MacOS/LabanApp 2>&1 \
  | tee .artifacts/appkit-manual/laban-app.log
```

Start and stop recording with `Cmd+Shift+R` or
`Debug > Toggle PTY Capture`. The app prints the capture directory on start and
the manifest path on stop. A useful manual repro should include typed input,
resize, scrollback movement, and a TUI when relevant.

Replay:

```sh
./scripts/replay-capture <capture-dir>
./scripts/replay-capture --mode=terminal <capture-dir>
./scripts/replay-capture --mode=renderer <capture-dir>
```

`terminalReplay: passed` means captured PTY output reconstructs the terminal
snapshots and frame commands. `rendererReplay: passed` means captured frame
commands render to the same screenshot hashes where screenshots are present.
When replay fails, use frame IDs, sidecar paths, and expected/actual hashes in
`replay/report.json` as the starting point for diagnosis.

### State Introspection

`GET /debug/state`

Returns a stable, implementation-neutral snapshot of app state:

```json
{
  "mode": "headless",
  "frame": 12,
  "window": {
    "width": 1280,
    "height": 800,
    "focused": true
  },
  "tabs": [
    {
      "id": "tab-1",
      "index": 0,
      "title": "Shell",
      "active": true,
      "status": "running",
      "sessionId": "session-1"
    }
  ],
  "activeTabId": "tab-1",
  "activeSessionId": "session-1",
  "findStateBySession": {
    "session-1": {
      "isActive": true,
      "needle": "apple",
      "total": 2,
      "selectedIndex": 0
    }
  }
}
```

This endpoint should be safe for frequent polling. It should not include large
buffers by default.

### Session Introspection

`GET /debug/sessions`

Returns all sessions and their lifecycle state:

```json
{
  "sessions": [
    {
      "id": "session-1",
      "tabId": "tab-1",
      "pid": 12346,
      "status": "running",
      "exitStatus": null,
      "rows": 38,
      "cols": 120,
      "cellWidth": 9,
      "cellHeight": 18,
      "scrollbackLines": 250,
      "viewportOffset": 0,
      "title": "Shell",
      "mouseTracking": false,
      "focusReporting": false,
      "dirty": true
    }
  ]
}
```

`GET /debug/sessions/<id>`

Returns one session with more detail. Optional query parameters:

- `includeGrid=true` returns visible cells in a compact JSON shape
- `includeAnsi=true` returns a bounded transcript slice
- `includeImages=true` returns image placement metadata

Large fields must be bounded. Agents should never need unbounded scrollback to
verify behavior.

### Render Introspection

`GET /debug/render`

Returns renderer state that helps an agent diagnose blank or corrupt graphics:

```json
{
  "frame": 12,
  "backend": "offscreen",
  "surface": {"width": 1280, "height": 800, "scale": 2},
  "terminalViewport": {"x": 220, "y": 10, "width": 1050, "height": 780},
  "cell": {"width": 9, "height": 18},
  "damage": [{"x": 0, "y": 0, "width": 1280, "height": 800}],
  "lastDraw": {
    "cells": 4560,
    "glyphs": 238,
    "backgroundRects": 75,
    "images": 0,
    "cursor": true
  }
}
```

### Frame Commands

`GET /debug/frame-commands`

Returns the bounded command stream for the current frame. This is the primary
way for an agent to explain a screenshot: the screenshot shows pixels, while
frame commands show what the renderer intended to draw.

Query parameters:

- `source=sidebar|terminal|selection|find|cursor|image|all`; default `all`
- `limit=<n>`; default implementation-defined bounded limit
- `includeText=true|false`; default `true` for bounded visible text

Example response:

```json
{
  "frame": 12,
  "backend": "software",
  "commands": [
    {
      "index": 0,
      "kind": "rect",
      "source": "sidebar",
      "rect": {"x": 0, "y": 0, "width": 220, "height": 800},
      "color": [246, 239, 218, 255]
    },
    {
      "index": 14,
      "kind": "glyphRun",
      "source": "terminal",
      "rect": {"x": 236, "y": 32, "width": 90, "height": 18},
      "text": "hello mvp",
      "foreground": [16, 31, 36, 255],
      "background": null
    }
  ],
  "truncated": false
}
```

Frame-command dumps must use source tags so agents can distinguish sidebar,
terminal grid, selection, cursor, and future image commands.

### Render Trace

`POST /debug/render-trace`

Returns a bounded explanation of one rendered frame. This is the endpoint an
agent uses when a screenshot is wrong and frame commands alone are not enough.
It should connect terminal/app state to command extraction, resource lookup,
backend draw calls, and selected final pixels by stable IDs.

Example request:

```json
{
  "frame": 12,
  "target": "window",
  "include": ["layout", "packets", "commands", "resources", "passes", "pixels", "invariants"],
  "commandIds": ["cmd-14"],
  "pixelProbes": [
    {"name": "prompt-cursor", "x": 250, "y": 40}
  ]
}
```

Example response:

```json
{
  "traceId": "frame-12",
  "frame": 12,
  "backend": "software",
  "surface": {"width": 1280, "height": 800, "scale": 2},
  "sources": [
    {"id": "state-12", "kind": "appState", "revision": 12},
    {"id": "term-snap-8", "kind": "terminalSnapshot", "sessionId": "session-1", "rows": 38, "cols": 120}
  ],
  "layout": [
    {"id": "layout-terminal", "kind": "terminalViewport", "rect": {"x": 220, "y": 0, "width": 1060, "height": 800}, "sourceRefs": ["state-12"]}
  ],
  "packets": [
    {"id": "pkt-term-1", "producer": "LabanTerminalCore", "sourceRefs": ["term-snap-8"], "dirtyRows": [0], "glyphRuns": 3, "backgroundRuns": 1}
  ],
  "commandRanges": [
    {"producer": "terminal", "inputRefs": ["pkt-term-1"], "firstCommandId": "cmd-14", "lastCommandId": "cmd-18"}
  ],
  "commands": [
    {
      "id": "cmd-14",
      "index": 14,
      "kind": "glyphRun",
      "source": "terminal",
      "rect": {"x": 236, "y": 32, "width": 90, "height": 18},
      "text": "hello mvp",
      "sourceRefs": ["cell:session-1:0:0-8", "pkt-term-1"]
    }
  ],
  "resources": [
    {"id": "atlas-1", "kind": "glyphAtlas", "status": "resident", "width": 2048, "height": 2048},
    {"id": "glyph-U+0068-style-1", "kind": "glyph", "status": "resident", "atlasId": "atlas-1"}
  ],
  "passes": [
    {
      "id": "pass-main",
      "target": "window",
      "draws": [
        {
          "id": "draw-7",
          "kind": "glyphRun",
          "commandRefs": ["cmd-14"],
          "resourceRefs": ["atlas-1", "glyph-U+0068-style-1"],
          "clip": {"x": 220, "y": 0, "width": 1060, "height": 800},
          "drawRect": {"x": 236, "y": 32, "width": 90, "height": 18}
        }
      ]
    }
  ],
  "pixelProbes": [
    {
      "name": "prompt-cursor",
      "x": 250,
      "y": 40,
      "rgba": [16, 31, 36, 255],
      "contributors": [
        {
          "passId": "pass-main",
          "drawId": "draw-7",
          "commandId": "cmd-14",
          "sourceRefs": ["cell:session-1:0:1"],
          "coverage": 1.0,
          "rgbaBefore": [246, 239, 218, 255],
          "rgbaAfter": [16, 31, 36, 255]
        }
      ]
    }
  ],
  "invariants": [
    {"level": "ok", "kind": "clip.containsDraws", "message": "all draw rects intersect their clip"}
  ],
  "truncated": false
}
```

The trace should be rich enough for an agent to answer:

- which app state, terminal snapshot, packet, and command produced a pixel
- whether a command was dropped during backend translation
- whether a glyph, image, buffer, texture, or pipeline resource was missing
- whether clipping, scaling, z order, blending, or damage tracking hid output
- whether the software and Metal backends consumed equivalent command ranges

The trace must stay bounded. Pixel provenance is required only for requested
points or small named regions; it must not dump the whole framebuffer. Metal
does not need to expose private GPU internals, but it must expose the encoded
draw plan, resource ledger, readback probes, and backend validation warnings.

### Pixel Probe

`POST /debug/pixel-probe`

Samples pixels or regions from the current render target without requiring the
agent to download and parse a full screenshot.

Example request:

```json
{
  "points": [{"x": 10, "y": 10}, {"x": 250, "y": 40}],
  "regions": [
    {"name": "sidebar", "x": 0, "y": 0, "width": 220, "height": 800}
  ]
}
```

Example response:

```json
{
  "frame": 12,
  "points": [
    {"x": 10, "y": 10, "rgba": [246, 239, 218, 255]},
    {"x": 250, "y": 40, "rgba": [16, 31, 36, 255]}
  ],
  "regions": [
    {
      "name": "sidebar",
      "averageRgba": [239, 231, 210, 255],
      "nonBackgroundPixels": 1240
    }
  ]
}
```

### Glyph Atlas

`GET /debug/atlas`

Returns font and glyph-atlas diagnostics.

```json
{
  "font": "JetBrains Mono",
  "fontSize": 16,
  "cell": {"width": 9, "height": 18, "baseline": 14},
  "cjkFont": {
    "font": "PingFangSC-Regular",
    "family": "PingFang SC",
    "source": "system",
    "candidates": ["PingFang SC", "Noto Sans Mono CJK SC", "Sarasa Term SC"],
    "fallbackOrder": ["primary terminal font", "PingFang SC", "...", "CoreText cascade"],
    "glyphAvailable": true,
    "glyphAdvance": 16,
    "targetCellWidth": 18,
    "scaleX": 1
  },
  "glyphs": {"loaded": 1532, "missing": 0},
  "missingCodepoints": [],
  "atlases": [
    {"id": "atlas-1", "width": 2048, "height": 2048, "occupancy": 0.42}
  ]
}
```

Agents use this endpoint to diagnose question-mark glyphs, baseline drift, and
cell metric errors.

### Find

`POST /debug/find/start`

Starts literal find in the active or named terminal session.

```json
{"sessionID": "session-1", "needle": "apple"}
```

`POST /debug/find/step`

Moves the selected match and scrolls it into view when necessary.

```json
{"sessionID": "session-1", "direction": "next"}
```

`POST /debug/find/stop`

Stops find, clears find highlights, and restores the starting viewport offset
when terminal dimensions still match.

```json
{"sessionID": "session-1"}
```

`GET /debug/find/state?sessionID=session-1`

Returns bounded find state:

```json
{
  "isActive": true,
  "needle": "apple",
  "total": 2,
  "selectedIndex": 0,
  "matches": [
    {"row": 3, "startColumn": 0, "endColumn": 5},
    {"row": 5, "startColumn": 0, "endColumn": 5}
  ]
}
```

`/debug/frame-commands?source=find` returns `findMatch` and `findSelected`
rectangles for the current frame so agents can verify highlighted cells without
desktop automation.

### Shell integration (OSC 133)

`GET /debug/shell-integration/state?sessionID=session-1`

Returns the OSC 133 ("semantic prompt") phase for the active or named session.
`phase` is `idle` before any marker, `atPrompt` after a prompt marker (A/B),
`running` while a command executes (C), and `finished` once the command ends
(D). `lastExitCode` is the status the shell reported with the last `D` marker,
or `null` if none was reported.

```json
{
  "sessionId": "session-1",
  "phase": "finished",
  "lastExitCode": 0
}
```

Each transition is also appended to `GET /debug/events` as a
`shell.integration` event whose `action` is the new phase and whose `text` is
the last exit code (when known).

### Selection

`GET /debug/selection`

Returns terminal selection state for copy behavior.

```json
{
  "active": true,
  "sessionId": "session-1",
  "anchor": {"row": 2, "col": 4},
  "focus": {"row": 2, "col": 14},
  "rects": [{"x": 236, "y": 46, "width": 90, "height": 18}],
  "text": "hello mvp"
}
```

The text field is bounded to visible selected text.

`POST /debug/actions` can set transient headless preedit text for renderer
verification without committing input to the terminal:

```json
{"action": "setPreedit", "text": "中👩‍💻a", "caretCells": 3}
```

Use `/debug/frame-commands?source=preedit&includeText=true` to verify the
background mask and underlined preedit glyph run.

### Clipboard

`GET /debug/clipboard`

Returns a test-safe summary of copy/paste behavior. It must not expose arbitrary
system clipboard contents unless the debug server itself set or read them
during the current run.

```json
{
  "lastCopyText": "hello mvp",
  "lastPasteText": "printf 'ok\\n'",
  "lastPasteUsedBracketedPaste": true,
  "lastPasteIgnoredNonText": false
}
```

### Input Log

`GET /debug/input-log?since=<sequence>`

Returns recent normalized input events and their routing decisions.

```json
{
  "events": [
    {
      "seq": 201,
      "kind": "key",
      "key": "v",
      "modifiers": ["command"],
      "route": "appCommand",
      "command": "paste"
    },
    {
      "seq": 202,
      "kind": "text",
      "text": "$",
      "consumedModifiers": ["option"],
      "route": "terminal"
    }
  ],
  "next": 203
}
```

Agents use this endpoint to diagnose wrong keyboard layout handling and
Command/Option leakage into terminal input. For terminal-routed key and mouse
events, `encodedHex` is populated from the terminal core's committed send path,
not from a separate preview encode.

### Terminal Log

`GET /debug/terminal-log?sessionId=<id>&since=<sequence>`

Returns bounded terminal byte-flow diagnostics. Raw bytes must be escaped or
encoded; never expose unbounded transcripts.

```json
{
  "sessionId": "session-1",
  "events": [
    {"seq": 301, "direction": "input", "escaped": "printf 'ok\\n'\\n"},
    {"seq": 302, "direction": "output", "escaped": "ok\\r\\n"}
  ],
  "next": 303,
  "truncated": false
}
```

### Timing

`GET /debug/timing`

Returns frame and endpoint timings useful for diagnosing sluggishness.

```json
{
  "frame": 12,
  "lastFrameMs": 3.4,
  "terminalPollMs": 0.2,
  "snapshotMs": 0.4,
  "commandExtractionMs": 0.7,
  "renderMs": 1.6,
  "screenshotMs": 2.1
}
```

### Metrics

`GET /debug/metrics`

Returns queryable counters and last-frame work metrics. These values let an
agent confirm that a scenario rendered frames, produced terminal byte traffic,
captured screenshots, or accumulated errors without scraping prose logs.

```json
{
  "runId": "run-001",
  "mode": "headless",
  "frame": 12,
  "uptimeMs": 1250.4,
  "counters": {
    "framesRendered": 12,
    "events": 30,
    "inputEvents": 4,
    "terminalLogEvents": 6,
    "errors": 0,
    "screenshots": 1,
    "tabs": 1,
    "sessions": 1
  },
  "terminalBytes": {"input": 24, "output": 96, "terminalResponse": 0},
  "lastFrame": {
    "commands": 42,
    "cells": 24,
    "glyphs": 8,
    "backgroundRects": 25,
    "images": 0,
    "cursor": true,
    "lastFrameMs": 3.4,
    "terminalPollMs": 0.2,
    "snapshotMs": 0.4,
    "commandExtractionMs": 0.7,
    "renderMs": 1.6
  }
}
```

### Errors

`GET /debug/errors?since=<sequence>`

Returns structured warnings/errors captured by the app.

```json
{
  "errors": [
    {
      "seq": 401,
      "level": "warning",
      "kind": "glyph.missing",
      "message": "Missing glyph for U+E0B0",
      "sessionId": "session-1"
    }
  ],
  "next": 402
}
```

### Event Log

`GET /debug/events?since=<sequence>`

Returns a bounded event stream for agent diagnosis:

```json
{
  "events": [
    {"seq": 101, "kind": "tab.created", "tabId": "tab-2"},
    {"seq": 102, "kind": "session.resized", "sessionId": "session-2", "cols": 120, "rows": 38}
  ],
  "next": 103
}
```

Events should include tab creation/close/select, session spawn/exit, resize,
title change, focus report, input delivery, render failure, and screenshot
capture.

### Tab-State Journal

`GET /debug/tab-journal?since=<sequence>&tabId=<id>`

Returns the model's always-on, bounded journal of what each tab visibly
showed over time: one `state` entry per change to a tab's title metadata,
status, selection, or notification badge, plus `note` entries for banner
decisions (`banner.posted`, `banner.suppressed.frontmost`). Entry `timeNs`
shares the capture-timeline clock, so journal entries line up with
`timeline.ndjson` pty/frame events when diagnosing attention-timing bugs
(e.g. "when did the tab actually show needs-you relative to the prompt
bytes?"). While a capture runs, the same entries are mirrored into
`timeline.ndjson` as `tab.metadata` events. In the AppKit app the journal is
dumped via Debug ▸ Dump Tab Journal (ndjson under
`~/Library/Logs/Laban/tab-journal/`).

```json
{
  "entries": [
    {"seq": 12, "timeNs": 1781245288433020928, "tabId": "tab-1", "kind": "state",
     "isSelected": false, "status": "running", "metadata": {"displayTitle": "✳ Pick an option"}},
    {"seq": 13, "timeNs": 1781245288433520928, "tabId": "tab-1", "kind": "note",
     "note": "banner.posted", "text": "Awaiting your input"}
  ],
  "next": 14
}
```

Schema: `schemas/debug/tab-journal.schema.json`.

### Control Actions

`POST /debug/actions`

Allows tests to drive the app without OS automation. This is only available
when the debug server is enabled.

Example actions:

```json
{"action":"newTab"}
{"action":"closeTab","tabId":"tab-2"}
{"action":"selectTab","tabId":"tab-1"}
{"action":"resizeWindow","width":1280,"height":800}
{"action":"setFontSize","pointSize":20}
{"action":"setRenderer","renderer":"vectorGlyph"}
{"action":"setVectorSubpixelLayout","layout":"bgrStripe"}
{"action":"typeText","text":"printf '$HOME\\n'\\n"}
{"action":"key","key":"t","modifiers":["command"]}
{"action":"mouseWheel","x":400,"y":300,"deltaY":-3}
{"action":"click","x":24,"y":84,"button":"left"}
{"action":"advanceFrames","count":3}
{"action":"copy"}
{"action":"paste"}
{"action":"dropFiles","paths":["/tmp/screenshot.png","/tmp/spec.pdf"]}
{"action":"setClipboardText","text":"printf 'ok\\n'\\n"}
{"action":"scrollViewport","sessionId":"session-1","deltaRows":-3}
{"action":"find.start","sessionID":"session-1","needle":"apple"}
{"action":"find.step","sessionID":"session-1","direction":"next"}
{"action":"find.stop","sessionID":"session-1"}
```

Paste actions use the same shared sanitizer as the AppKit paste path before
writing terminal input: HT, LF, and CR are preserved, while other C0 controls,
DEL, and C1 controls are stripped before libghostty encodes bracketed or plain
paste bytes. `/debug/clipboard` reports the sanitized text, while
`/debug/input-log` and terminal-input logs report the committed encoded bytes
from the terminal-core paste send path.

`dropFiles` formats the supplied local paths the same way AppKit drag-and-drop
does, then writes the formatted path text through the terminal-core paste send
path. This action models terminal delivery of a file drop; it does not
synthesize a desktop drag session or read arbitrary file contents.

Actions return the resulting frame number and a state summary:

```json
{
  "ok": true,
  "frame": 15,
  "activeTabId": "tab-2",
  "activeSessionId": "session-2"
}
```

Control actions are not a replacement for unit tests. They are the bridge that
lets agents perform end-to-end tests without fragile desktop automation.

### Wait Conditions

`POST /debug/wait`

Waits for a bounded condition without brittle sleeps.

Example request:

```json
{
  "timeoutMs": 2000,
  "condition": {
    "kind": "textVisible",
    "sessionId": "session-1",
    "text": "hello mvp"
  }
}
```

Supported condition kinds should include:

- `frameAtLeast`
- `eventSeen`
- `tabCount`
- `activeTab`
- `sessionStatus`
- `titleEquals`
- `textVisible`
- `renderCommandSeen`
- `renderTraceInvariant`

Example response:

```json
{
  "ok": true,
  "frame": 18,
  "elapsedMs": 41
}
```

### Fixture Control

`POST /debug/fixture`

Loads, restarts, or steps a fixture session.

Example requests:

```json
{"action":"load","path":"colored-boxes.fixture.json"}
{"action":"restart"}
{"action":"step","count":1}
```

Fixture control is only available in fixture/headless-capable modes. `load.path`
must be relative to the debug runtime's fixture root. Absolute paths, `..`, and
symlink components are rejected.

### Artifact Snapshot

`POST /debug/snapshot`

Writes a diagnostic bundle into the artifact directory and returns the manifest
path. A snapshot should include current state, sessions, render state, frame
commands, render trace summary, events, input log, terminal log, errors, and
timing, metrics, and screenshot metadata.

```json
{
  "path": ".artifacts/run-001/snapshots/snapshot-000018/manifest.json",
  "frame": 18
}
```

### Scroll & Zoom Debug Surface

A second, headful-only loopback server (`ScrollDebugServer`, default port 8787)
is opted into with `--scroll-debug[=PORT]` or `LABAN_SCROLL_DEBUG=1`. It drives a
real on-screen window for behaviors the offscreen `laban-agent` cannot reproduce.
Beyond the scroll routes (self-documented at `GET /`), it exposes pinch-zoom:

`POST /zoom/pinch?magnification=<delta>&phase=<began|changed|ended|cancelled>`

Feeds a synthetic pinch through the same accumulate/apply path as the real
`magnify(with:)` trackpad gesture (and the Cmd+scroll laptop path). The
magnification is multiplicative: target size is `base * (1 + sumOfDeltas)`,
clamped to [8, 40]. A `phase=ended` (or `cancelled`) call persists the final
size to `UserDefaults`.

`GET /zoom/state`

Reports the live zoom state. `effectivePointSize` is fractional only when the
vector renderer is active (`POST /config/renderer?name=vectorGlyph`); the
classic/software backends round to an integer ladder size. `gridReflowCount`
advances once per distinct `(cols, rows)` pair a gesture sweeps, not once per
event: the grid (and its `SIGWINCH`) re-fits only on integer column/row
boundary crossings.

```json
{
  "effectivePointSize": 17.5,
  "cols": 96,
  "rows": 30,
  "backend": "vectorGlyph",
  "fractional": true,
  "gridReflowCount": 4
}
```

## Headless Rendering Contract

Headless mode must render into an offscreen surface that can be captured as a
PNG. The product UI target remains macOS; headless and cross-platform code
exists to make autonomous testing reliable in CI, not to replace the macOS app
shell. The preferred design is:

- terminal core and app state are identical in interactive and headless modes
- app/session state is extracted into unified frame commands
- Metal and software/offscreen backends consume the same frame-command language
- interactive mode presents the Metal surface to the OS
- headless mode renders the same commands into an offscreen software surface
- screenshots read pixels from the active render target

The software backend must be deterministic and behavior-equivalent to Metal,
but does not need to be bit-for-bit identical. Tests should combine
frame-command assertions, deterministic software goldens, and Metal smoke or
pixel-probe checks.

If the production renderer cannot run in a given CI environment, provide a
renderer-equivalent test backend that consumes the same render commands and
produces pixels. The test backend must be close enough to catch blank frames,
wrong colors, missing glyph ranges, bad cursor placement, layout bugs, and
sidebar overlap.

Do not make headless screenshots by serializing model state into a separate
image generator. That would test a different renderer.

## Determinism

Agent tests need deterministic control over time and input.

The app should support:

- manual frame advancement in headless mode
- deterministic timers when `--deterministic` is set
- stable generated IDs in fixture mode, or a debug ID map that tests can query
- bounded logs and bounded transcript snapshots
- predictable font selection in CI
- fixed initial window size unless overridden

Avoid tests that depend on the user's shell prompt, local dotfiles, network,
wall-clock timing, or installed terminal themes.

## Test Layers

### Unit Tests

Fast tests for pure behavior:

- tab selection fallback
- session registry pruning
- launch configuration composition
- shell fallback resolution
- key event consumed-modifier rules
- mouse mode routing
- resize row/column math
- title sanitization

### Core Integration Tests

Tests that run terminal core and pty behavior without the full app shell:

- spawn shell or fixture child
- feed ANSI/OSC bytes
- verify title, colors, cursor, scrollback, exit state
- verify resize propagates to pty
- verify terminal responses are written back

### End-To-End Agent Tests

Tests that launch the app through the debug server:

- wait for `/debug/health`
- drive actions through `/debug/actions`
- inspect `/debug/state` and `/debug/sessions`
- capture `/debug/screenshot`
- inspect `/debug/render-trace` when pixels or frame commands do not explain a
  failure
- compare screenshots or pixel probes
- store artifacts on failure

End-to-end tests should be fewer than unit/core tests, but they must cover the
user workflows in `docs/product/mvp.md`.

## Required MVP E2E Tests

The first implementation should not be considered complete until these can run
headlessly:

- launches to one tab with one running session
- screenshot is non-empty and includes sidebar plus terminal viewport
- new tab creates a second session and selects it
- selecting the first tab preserves the first session
- close tab tears down only that tab's session
- closing the final tab follows the MVP replacement policy
- typed text reaches the pty exactly once
- layout-specific text input can be injected as text and is not reinterpreted
  as a modified key chord
- colored fixture output renders with non-monochrome pixels
- box-drawing fixture output renders without replacement glyphs
- resize changes rows/columns and redraws without blanking
- scroll wheel scrolls scrollback when mouse tracking is inactive
- wheel events go to the terminal app when mouse tracking is active
- exited child shows exited state and exit status
- intentional spawn failure leaves existing tabs valid

## Artifact Policy

Every failed E2E run writes an artifact directory containing:

- command line and environment summary
- debug server URL
- final `/debug/state`
- final `/debug/sessions`
- final `/debug/render`
- final `/debug/render-trace` summary
- recent `/debug/events`
- screenshot PNGs
- bounded stdout/stderr logs
- test fixture name and seed, if any

Artifacts should be small enough to keep in CI logs or upload as CI artifacts.
Large transcripts and screenshots should be bounded or compressed.

## Security And Safety

The debug server is powerful. It can type into terminals and close sessions.

Rules:

- bind only to loopback
- require an explicit flag
- print the selected port only to the launching process output
- disable in production by default
- never expose unbounded terminal output
- redact environment values likely to contain secrets in debug snapshots
- avoid endpoints that execute arbitrary host commands outside the terminal
  session model

## Development Workflow

For each non-trivial feature:

1. Add or update the smallest relevant unit/core test.
2. Implement the behavior.
3. Add or update a debug-state field if an agent could not otherwise diagnose
   the behavior.
4. Add or update an E2E debug-server test for user-visible behavior.
5. Run headless tests locally.
6. Capture a screenshot artifact for UI changes.
7. Commit the behavior and tests together unless splitting is clearer.

The debug hooks should evolve with the product. If an agent gets stuck because
it cannot see enough state, improve the debug hook instead of adding brittle
sleep-based tests or relying on manual screenshots.

## Metal Trace Perf Loop

`scripts/analyze-metal-trace` turns Instruments `.trace` bundles into a
self-checking perf iteration loop (this block is regenerable via
`scripts/analyze-metal-trace --print-agent-docs`).

Verify the tool first (no trace or macOS needed):

    scripts/analyze-metal-trace --self-test

Standard loop (each step is one command):

1. Establish a baseline from a recorded trace (exports are cached; reruns skip
   xctrace but still pay XML parse time):

       scripts/analyze-metal-trace path/to/run.trace --json-output .build/baseline.json

2. Make ONE code change, rebuild, then record + analyze + compare in one shot:

       scripts/analyze-metal-trace --record 10 --attach Laban \
           --baseline .build/baseline.json --fail-on-regression

   (or: `--launch -- ./build/Laban --bench-scroll`)
   Exit 0 = no regression beyond thresholds; exit 3 = regression or unreliable
   comparison -> revert or fix.
3. Read ONLY stdout (brief report + verdict). Full details are in the JSON/MD
   files if a finding needs evidence.

Refocusing on the code you just changed:

    scripts/analyze-metal-trace --print-config > trace-focus.json
    # edit cpuSymbols / metalLabels to include your function or signpost label,
    # then rerun; trace-focus.json is auto-discovered in the cwd.

Fast paths:

    --cpu-only --max-rows 50000     # quick CPU hot-path check
    --list-schemas                  # what tables exist in this trace
    --no-cache / --clear-cache      # force fresh exports

Thresholds: `--threshold-pp` (CPU pp, default 1.0), `--threshold-pct`
(GPU p95 %, default 10.0).

Rules of thumb:

- One change per trace; the compare verdict is only attributable if you do.
- If brief output warns about missing symbolicated frames, fix dSYMs before
  trusting CPU numbers.
- Never pass `--allow-sensitive-schemas` unless explicitly asked; raw exports
  can contain launch env vars and logs.
- Cached exports persist in `~/.cache/analyze-metal-trace` (never for
  sensitive schemas); `--clear-cache` removes them.

## Definition Of Done

A behavior is done when an agent can:

- launch the app in headless mode
- drive the behavior through debug actions or test fixtures
- query state proving the internal transition happened
- capture graphics proving the visible result happened
- run the same test in CI without human interaction

Manual testing can still be useful, but it is not the completion criterion for
MVP behavior.
