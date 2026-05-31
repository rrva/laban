# Add The Headless Debug Server

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then implement the first usable Laban debug server.

## Purpose / Big Picture

Laban now has a headless `laban-agent` that can run one fixture, render one
PNG, write one result JSON file, and exit. That proves the renderer path works,
but it does not let an autonomous agent drive the app while it is running. The
MVP requires a local debug server so agents can launch Laban, wait for
readiness, create/select/close tabs, type text, resize, capture screenshots,
query state, and inspect render diagnostics without using desktop automation.

After this plan is complete, a developer can run `laban-agent` in headless mode
with `--debug-server=127.0.0.1:0`, parse the single readiness JSON line from
stdout, drive the app through HTTP endpoints, and receive screenshots and JSON
state from the same `AppModel`, frame-command producers, and software renderer
used by the current one-shot headless path.

This plan implements the headless debug server first. Interactive AppKit debug
server support is a later shard. If
`execplans/active/appkit-backing-scale-text-crispness.md` is still incomplete
when this plan starts, do not implement its AppKit scale work here; keep the
headless renderer at scale 1 and report that scale in debug responses.

## Progress

- [x] (2026-05-03) Verified current `Sources/LabanAgent/main.swift` exits with
  `debug server not implemented in this shard` when `--debug-server` is used.
- [x] (2026-05-03) Verified `Sources/LabanDebug/LabanDebug.swift` is a
  placeholder target and can own the reusable debug HTTP/runtime code.
- [x] (2026-05-03) Read the required debug contracts in
  `docs/process/dev-process.md`, `docs/process/worktree-isolation.md`,
  `docs/process/observability.md`, and `schemas/debug/*.schema.json`.
- [x] (2026-05-03) Add a small loopback-only HTTP server in `LabanDebug`
  (`Sources/LabanDebug/DebugHTTPServer.swift`).
- [x] (2026-05-03) Add a long-running headless runtime that owns `AppModel`,
  fixture state, frame advancement, frame commands, software rendering,
  screenshots, and bounded debug state
  (`Sources/LabanDebug/HeadlessDebugRuntime.swift`).
- [x] (2026-05-03) Wire `laban-agent --headless --debug-server=127.0.0.1:0` to
  start the runtime, print one readiness line, and keep serving until
  terminated (`Sources/LabanAgent/main.swift`).
- [x] (2026-05-03) Implement phase 1 endpoints: `/debug/health`,
  `/debug/state`, `/debug/screenshot`, and `/debug/actions` (including
  `newTab`, `closeTab`, `selectTab`, `resizeWindow`, `typeText`,
  `advanceFrames`, `setClipboardText`, `paste`; unsupported actions return
  bounded `ok:false`).
- [x] (2026-05-03) Implement low-cost phase 2 diagnostics: `/debug/sessions`,
  `/debug/render`, `/debug/frame-commands`, `/debug/render-trace`,
  `/debug/wait`, and `/debug/events`.
- [x] (2026-05-03) Add `scripts/test-e2e` (18-step E2E script) and include it
  in `./scripts/check`. Added `.artifacts/` and `.tmp/` to `.gitignore`.
- [x] (2026-05-03) Local verification passed: `./scripts/check` passes,
  `./scripts/test-e2e` passes, 78 unit tests pass (13 new in
  `LabanDebugTests`), `smoke-runtime` still passes.

## Decision Log

- Decision: Implement the first debug server only for `laban-agent` headless
  mode.
  Rationale: The MVP needs autonomous verification immediately. Headless mode
  already has `AppModel`, fixtures, frame commands, and software rendering
  without AppKit lifecycle complexity. Interactive debug support can reuse the
  same `LabanDebug` types later.
  Date/Author: 2026-05-03 / Codex.

- Decision: Use the Swift standard libraries plus Foundation, Darwin sockets,
  CoreGraphics, and the existing package targets. Do not add SwiftNIO, Vapor,
  or another HTTP dependency in this shard.
  Rationale: The required server is local-only, low-throughput, and
  test-facing. A small single-process HTTP implementation is easier for agents
  to inspect and avoids dependency and package-resolution churn before the MVP
  needs production networking features.
  Date/Author: 2026-05-03 / Codex.

- Decision: Treat unsupported debug actions as parsed, bounded failures rather
  than crashes.
  Rationale: `schemas/debug/action.schema.json` already includes actions that
  depend on later input, selection, clipboard, mouse, and scrollback work. The
  first server must be robust when an agent sends any schema action, but this
  shard only needs to make `newTab`, `closeTab`, `selectTab`, `resizeWindow`,
  `typeText`, `advanceFrames`, `setClipboardText`, and `paste` behaviorally
  useful.
  Date/Author: 2026-05-03 / Codex.

- Decision: Keep screenshots local and artifact-scoped.
  Rationale: Terminal pixels may contain secrets. `GET /debug/screenshot`
  returns PNG bytes to the local caller, and `POST /debug/screenshot` writes
  only under the requested artifact directory.
  Date/Author: 2026-05-03 / Codex.

## Executor Context Budget

For a context-limited implementation agent, start with this ExecPlan, then read
only these files before editing:

```text
AGENTS.md
Package.swift
Sources/LabanAgent/main.swift
Sources/LabanDebug/LabanDebug.swift
Sources/LabanCore/AppModel.swift
Sources/LabanCore/Session.swift
Sources/LabanCore/FixtureRunner.swift
Sources/LabanCore/FrameProducer.swift
Sources/LabanCore/SidebarProducer.swift
Sources/LabanRenderer/BitmapSurface.swift
Sources/LabanRenderer/SoftwareRenderer.swift
Sources/LabanRenderer/FrameCommand.swift
Sources/LabanRenderer/PNGEncoder.swift
Sources/LabanTerminalCore/include/LabanTerminalCore.h
schemas/debug/state.schema.json
schemas/debug/action.schema.json
schemas/debug/action-result.schema.json
schemas/debug/screenshot-result.schema.json
schemas/debug/session.schema.json
schemas/debug/sessions.schema.json
schemas/debug/render.schema.json
schemas/debug/frame-commands.schema.json
schemas/debug/render-trace-request.schema.json
schemas/debug/render-trace.schema.json
schemas/debug/wait.schema.json
schemas/debug/wait-result.schema.json
schemas/debug/events.schema.json
scripts/check
scripts/smoke-runtime
```

Do not read the full umbrella plan unless this file names a conflict. The
umbrella is background; this file is the implementation contract for this
shard.

## Context and Orientation

`LabanAgent` is the executable product named `laban-agent`. Today it has one
mode:

1. parse `--headless`, `--fixture`, `--artifacts`, `--temp-dir`, and
   `--deterministic`;
2. load a fixture with `FixtureRunner`;
3. create an `AppModel`;
4. apply all fixture steps at once;
5. render one frame through `SidebarProducer`, `FrameProducer`,
   `SoftwareRenderer`, and `BitmapSurface`;
6. write `screenshot.png` and `result.json`;
7. exit.

The debug server changes that shape only when `--debug-server` is present.
The existing one-shot path must keep working for `scripts/run-headless` and
`scripts/smoke-runtime`.

`LabanDebug` is currently a placeholder library target. This plan turns it into
the reusable debug/runtime layer. `LabanAgent` should be thin: parse arguments,
create the runtime, start the server, print readiness, and block until the
process receives a normal termination signal.

The important existing types are:

- `AppModel`: owns tabs and sessions. It can create, select, close, and resize
  tabs. It preserves stable tab and session identity.
- `Session`: wraps the C terminal core. It can `poll()`, `write(_:)`,
  `resize(_:)`, and return a snapshot through `snapshot()`.
- `LabanSnapshot`: a C-owned terminal snapshot. It contains rows, columns,
  cells, cursor, title, status, exit status, mouse tracking, focus reporting,
  and dirty state. Always call `laban_snapshot_destroy` after using a snapshot.
- `FrameProducer` and `SidebarProducer`: convert model/session state into
  `FrameCommand` values.
- `SoftwareRenderer`: draws `FrameCommand` values into a `BitmapSurface`.
- `BitmapSurface`: owns the bitmap, exposes `cgImage`, `pngData`, and
  `pixel(x:y:)`.

Definitions used in this plan:

- Debug server means the local HTTP server that accepts `/debug/...` requests.
- Readiness line means one JSON object printed to stdout after the server has
  bound its actual port. Agents parse this instead of guessing a port.
- Run ID means the final path component of the artifact directory unless the
  implementation adds an explicit `--run-id` flag later.
- Frame means one poll/snapshot/command-extract/render cycle in the headless
  runtime.
- Bounded means a response has a clear size cap and never dumps unbounded
  terminal output.

## Milestones

### Milestone 1: HTTP Server And Runtime Skeleton

Add a tiny HTTP server and a headless runtime, then prove the agent can start
and answer health checks.

Implementation requirements:

- Add `LabanTerminalCore` as a direct dependency of the `LabanDebug` target in
  `Package.swift` if `LabanDebug` imports `LabanTerminalCore`.
- Replace `Sources/LabanDebug/LabanDebug.swift` with real code or split it into
  small files under `Sources/LabanDebug/`.
- Add a loopback-only HTTP server. A good simple shape is:
  - `DebugHTTPServer` owns a Darwin TCP socket;
  - `start(host:port:)` binds only `127.0.0.1` or `localhost`;
  - port `0` is allowed and the selected port is discovered with
    `getsockname`;
  - one background thread accepts connections;
  - each connection handles one HTTP/1.1 request;
  - support `GET` and `POST`;
  - parse `Content-Length`;
  - return JSON, PNG, or plain text responses with correct status codes;
  - reject public hosts such as `0.0.0.0`, `::`, and non-loopback addresses.
- Add `HeadlessDebugRuntime` or an equivalent type. It owns:
  - `mode` string, initially `"fixture"` when a fixture path is provided and
    `"headless"` otherwise;
  - `runId`;
  - artifact and temp directory URLs;
  - `AppModel`;
  - `FontAtlas`;
  - `cellWidth` and `cellHeight`;
  - logical window width and height;
  - sidebar width, using `SidebarLayout.defaultWidth`;
  - `BitmapSurface`;
  - `SoftwareRenderer`;
  - current frame number;
  - last frame commands;
  - an in-memory debug clipboard string for debug `paste`;
  - a bounded event log.
- Protect runtime state with one serial `DispatchQueue`, `NSLock`, or another
  simple synchronization primitive. HTTP requests must not mutate `AppModel`
  concurrently.
- On startup, create artifact and temp directories if they do not exist.
- If `--fixture=<path>` is present, load the fixture and apply its steps before
  serving. Then render one frame so screenshot and render endpoints have
  current pixels.
- If no fixture is present, create an `AppModel` with fixture-backed sessions
  and render one empty initial frame.
- Preserve the existing no-debug one-shot path exactly enough that
  `scripts/run-headless` and the current `scripts/smoke-runtime` still pass.

Acceptance for Milestone 1:

```sh
swift build --product laban-agent
.build/debug/laban-agent --headless \
  --fixture=fixtures/colored-boxes.fixture.json \
  --debug-server=127.0.0.1:0 \
  --artifacts=.artifacts/runs/debug-server-manual \
  --temp-dir=.tmp/debug-server-manual \
  --deterministic
```

The process stays running. Its first stdout line must be one JSON object like:

```json
{"debugServer":"http://127.0.0.1:49321","pid":12345,"runId":"debug-server-manual"}
```

`curl "$debugServer/debug/health"` returns HTTP 200 JSON:

```json
{"ok":true,"mode":"fixture","frame":1,"focused":true}
```

Killing the process should stop the server and release the port.

### Milestone 2: Phase 1 Endpoints

Implement the endpoints required by the umbrella phase 1 milestone:
`/debug/health`, `/debug/state`, `/debug/screenshot`, and `/debug/actions`.

`GET /debug/health` returns readiness:

```json
{
  "ok": true,
  "mode": "fixture",
  "frame": 1,
  "focused": true
}
```

`GET /debug/state` returns JSON compatible with
`schemas/debug/state.schema.json`. Required fields:

```json
{
  "mode": "fixture",
  "frame": 1,
  "window": {"width": 1280, "height": 800, "focused": true},
  "tabs": [
    {
      "id": "tab-id",
      "index": 0,
      "title": "Tab 1",
      "active": true,
      "status": "running",
      "sessionId": "session-id"
    }
  ],
  "activeTabId": "tab-id",
  "activeSessionId": "session-id"
}
```

Use snapshot status to map terminal status:

```text
snapshot.status == 0 -> "running"
snapshot.status == 1 -> "exited"
snapshot.status == 2 -> "exited"
snapshot missing      -> "failed"
```

If `snapshot.title` is non-empty, use it for the debug title and update the
`AppModel` tab title if possible. If it is empty, use the existing tab title.

`GET /debug/screenshot` returns the current PNG bytes from `BitmapSurface`.
Response headers must include:

```text
Content-Type: image/png
X-App-Frame: <frame>
X-App-Size: <width>x<height>
```

`POST /debug/screenshot` writes a PNG under:

```text
<artifacts>/screenshots/frame-000001.png
```

and returns JSON compatible with
`schemas/debug/screenshot-result.schema.json`:

```json
{
  "path": ".artifacts/runs/run-id/screenshots/frame-000001.png",
  "width": 1280,
  "height": 800,
  "frame": 1,
  "target": "window"
}
```

`POST /debug/actions` accepts JSON compatible with
`schemas/debug/action.schema.json`. Implement these actions behaviorally:

- `newTab`: call `AppModel.createTab()`, render a frame, return the new active
  IDs.
- `closeTab`: call `AppModel.closeTab(tabId)`, render a frame, return active
  IDs. The final-tab replacement policy must still hold.
- `selectTab`: call `AppModel.selectTab(tabId)`, render a frame, return active
  IDs.
- `resizeWindow`: update logical window width and height, recreate the surface
  at scale 1, call `AppModel.resize(viewportWidth:height:cellWidth:cellHeight:)`
  with the terminal viewport width excluding the sidebar, then render a frame.
- `typeText`: write UTF-8 bytes to the active session, then advance/render one
  frame.
- `advanceFrames`: poll and render `count` frames.
- `setClipboardText`: store the given text in the runtime's debug clipboard.
- `paste`: write the debug clipboard text to the active session, then
  advance/render one frame.

For all other schema actions (`key`, `mouseWheel`, `click`, `copy`,
`scrollViewport`), return HTTP 200 with an action-result body containing
`"ok": false` and a bounded `"error"` string such as
`"debug action key is not implemented yet"`. Do not crash and do not silently
pretend unsupported actions worked.

All action responses must be compatible with
`schemas/debug/action-result.schema.json`:

```json
{
  "ok": true,
  "frame": 2,
  "activeTabId": "tab-id",
  "activeSessionId": "session-id"
}
```

Acceptance for Milestone 2:

- Launch the server.
- `GET /debug/state` shows one active tab and one active session.
- `POST /debug/actions` with `{"action":"newTab"}` shows two tabs and a new
  active session in the next `/debug/state`.
- `POST /debug/actions` with `{"action":"typeText","text":"hello\\n"}` returns
  `"ok": true` and advances the frame.
- `GET /debug/screenshot` returns a non-empty PNG.
- `POST /debug/screenshot` creates a PNG under the artifact directory.

### Milestone 3: Low-Cost Diagnostics

Implement the diagnostic endpoints that can be derived from current runtime
state without new product behavior: `/debug/sessions`, `/debug/render`,
`/debug/frame-commands`, `/debug/render-trace`, `/debug/wait`, and
`/debug/events`.

`GET /debug/sessions` returns JSON compatible with
`schemas/debug/sessions.schema.json`. For each tab/session pair, produce a
`schemas/debug/session.schema.json` object. Use snapshots for rows, cols,
title, status, exit status, mouse tracking, focus reporting, and dirty. Use the
known cell metrics for `cellWidth` and `cellHeight`. Until scrollback exists,
return:

```json
{"scrollbackLines":0,"viewportOffset":0}
```

`GET /debug/render` returns JSON compatible with
`schemas/debug/render.schema.json`. Use the last rendered frame:

```json
{
  "frame": 3,
  "backend": "software",
  "surface": {"width": 1280, "height": 800, "scale": 1},
  "terminalViewport": {"x": 200, "y": 0, "width": 1080, "height": 800},
  "cell": {"width": 9, "height": 18},
  "damage": [{"x": 0, "y": 0, "width": 1280, "height": 800}],
  "lastDraw": {
    "cells": 1920,
    "glyphs": 20,
    "backgroundRects": 24,
    "images": 0,
    "cursor": true
  }
}
```

`GET /debug/frame-commands` returns JSON compatible with
`schemas/debug/frame-commands.schema.json`. Serialize `FrameCommand` values
with stable IDs such as `cmd-0`, `cmd-1`, and these mappings:

- `rect`: kind `"rect"`, source from `FrameSource.rawValue`, `rect`, and
  `color`.
- `glyphRun`: kind `"glyphRun"`, source from `FrameSource.rawValue`, `text`,
  `foreground`, `background`, and an approximate `rect` using origin,
  `cellHeight`, and `text.count * cellWidth`.
- `cursor`: kind `"cursor"`, source `"cursor"`, `rect`, and `color`.
- `selection`: kind `"selection"`, source `"selection"`, `rect`, and `color`.
- `clip`: kind `"clip"`, source `"unknown"`, `rect`.
- `texturedQuad`: kind `"texturedQuad"`, source from `FrameSource.rawValue`,
  `rect`, and string `resourceId`.

Support query parameters:

- `source=sidebar|terminal|selection|cursor|image|chrome|all`, default `all`;
- `limit=<n>`, default `500`, hard cap `2000`;
- `includeText=true|false`, default `true`.

Set `"truncated": true` when commands are omitted by limit.

`POST /debug/render-trace` returns a minimal schema-compatible response for
`schemas/debug/render-trace.schema.json`. It does not need deep per-pixel
provenance in this shard. It must include every required top-level field and
should include:

- one `appState` source;
- one `terminalSnapshot` source for the active session when available;
- layout items for `window`, `sidebar`, and `terminalViewport`;
- one packet summary for the active terminal snapshot;
- one command range for sidebar commands and one for terminal commands when
  present;
- serialized frame commands, respecting request `limit` when provided;
- one `font` resource for JetBrains Mono and one `surface` resource;
- one render pass with draws referencing command IDs;
- pixel probe results for requested `pixelProbes`, using
  `BitmapSurface.pixel(x:y:)`;
- at least one `"ok"` invariant saying the trace was produced from the
  software renderer.

`POST /debug/wait` accepts JSON compatible with `schemas/debug/wait.schema.json`
and returns `schemas/debug/wait-result.schema.json`. Implement these condition
kinds:

- `frameAtLeast`;
- `tabCount`;
- `activeTab`;
- `sessionStatus`;
- `titleEquals`;
- `textVisible`;
- `renderCommandSeen`;
- `eventSeen`;
- `renderTraceInvariant` for invariant level/kind present in the current
  minimal trace.

The wait loop must be bounded by `timeoutMs`. In deterministic mode it may
advance one frame per iteration and sleep for a small duration such as 10 ms.

`GET /debug/events?since=<seq>` returns JSON compatible with
`schemas/debug/events.schema.json`. Keep a bounded in-memory event array with
at least these event kinds:

- `server.ready`;
- `frame.rendered`;
- `tab.created`;
- `tab.selected`;
- `tab.closed`;
- `window.resized`;
- `input.typed`;
- `clipboard.set`;
- `clipboard.pasted`;
- `screenshot.captured`;
- `action.unsupported`;
- `error`.

Acceptance for Milestone 3:

- `/debug/sessions` reports one object per tab and includes rows/cols matching
  the active fixture snapshot.
- `/debug/render` reports backend `"software"`, surface dimensions, cell
  dimensions, and non-zero glyph/background counts for the colored-boxes
  fixture.
- `/debug/frame-commands?source=terminal&limit=20` returns at least one
  terminal command and a valid `truncated` boolean.
- `/debug/render-trace` returns every required top-level field in
  `schemas/debug/render-trace.schema.json`.
- `/debug/wait` with condition `textVisible` succeeds for `"hello mvp"` after
  launching with `fixtures/colored-boxes.fixture.json`.
- `/debug/events` includes `server.ready` and `frame.rendered`.

### Milestone 4: E2E Script And Check Integration

Add a stable script that launches the debug server, drives it, checks outputs,
and shuts it down.

Recommended file:

```text
scripts/test-e2e
```

The script must:

1. build `laban-agent`;
2. create a unique run ID;
3. use isolated artifact and temp directories under `.artifacts/runs/<run-id>`
   and `.tmp/<run-id>`;
4. launch:

   ```sh
   .build/debug/laban-agent --headless \
     --fixture=fixtures/colored-boxes.fixture.json \
     --debug-server=127.0.0.1:0 \
     --artifacts=".artifacts/runs/<run-id>" \
     --temp-dir=".tmp/<run-id>" \
     --deterministic
   ```

5. parse exactly one readiness JSON line from stdout;
6. call `/debug/health`;
7. call `/debug/state` and assert one active tab;
8. call `/debug/wait` for `textVisible` `"hello mvp"`;
9. call `/debug/screenshot` and assert the PNG is non-empty;
10. call `POST /debug/screenshot` and assert the artifact PNG exists under the
    run artifact directory;
11. call `/debug/frame-commands?source=terminal&limit=100` and assert at least
    one terminal command;
12. call `/debug/render`;
13. call `/debug/sessions`;
14. post `{"action":"newTab"}` and assert state now has two tabs;
15. post `{"action":"selectTab","tabId":"<first-tab-id>"}` and assert the
    first tab becomes active without changing its session ID;
16. post `{"action":"resizeWindow","width":1000,"height":600}` and assert
    `/debug/sessions` rows/cols are still at least 1;
17. post `{"action":"setClipboardText","text":"agent text\\n"}` then
    `{"action":"paste"}` and assert both return `"ok": true`;
18. terminate the server process;
19. remove the run artifact and temp directories on success;
20. preserve artifacts on failure and print their paths.

Update `scripts/check` to run `./scripts/test-e2e` after `scripts/smoke-runtime`
once the script is stable. Also add `.artifacts/` and `.tmp/` to `.gitignore`
because debug-server runs intentionally create those directories.

Acceptance for Milestone 4:

```sh
./scripts/test-e2e
```

prints a stable success line, for example:

```text
test-e2e passed
```

and:

```sh
./scripts/check
```

prints:

```text
check passed
```

## Plan of Work

Implement this plan in small commits or logical chunks:

1. Add the debug HTTP server type and unit tests that exercise path routing and
   response encoding without starting `laban-agent`.
2. Add the headless runtime type and unit tests for action decoding, state
   encoding, color serialization, frame-command serialization, and render
   summary counts.
3. Wire `laban-agent` to the runtime/server only when `--debug-server` is
   provided. Keep the existing no-debug path working.
4. Add endpoint handlers and focused tests for health, state, screenshot
   metadata, action results, session summaries, render summaries, frame-command
   serialization, render-trace minimum shape, wait conditions, and events.
5. Add `scripts/test-e2e`, then update `scripts/check`.
6. Run verification commands and update `Progress` and
   `Outcomes & Retrospective`.

## Concrete Steps

Work from the repository root:

```sh
cd /Users/dev/wrk/laban
```

Before editing, confirm the current baseline:

```sh
git status --short
./scripts/check
```

Create or update these files:

```text
Package.swift
Sources/LabanDebug/LabanDebug.swift
Sources/LabanDebug/DebugHTTPServer.swift
Sources/LabanDebug/HeadlessDebugRuntime.swift
Sources/LabanDebug/DebugModels.swift
Sources/LabanAgent/main.swift
Tests/LabanDebugTests/LabanDebugSmokeTests.swift
scripts/test-e2e
scripts/check
.gitignore
```

The new file names are recommended, not mandatory. Keep the target boundary:
HTTP, runtime, debug response models, endpoint handlers, and serialization
belong in `LabanDebug`; executable argument parsing and process lifetime belong
in `LabanAgent`.

Run focused tests while iterating:

```sh
swift test --filter LabanDebugTests
swift build --product laban-agent
```

Run the E2E script once it exists:

```sh
./scripts/test-e2e
```

Run the full local gate:

```sh
./scripts/check
```

If `./scripts/check` fails because `.artifacts/` or `.tmp/` were created,
verify they are ignored by `.gitignore` and remove any accidentally staged
generated files.

## Validation and Acceptance

This ExecPlan is complete when all of the following are true:

- `laban-agent` without `--debug-server` still supports the existing one-shot
  fixture path and `scripts/smoke-runtime` still passes.
- `laban-agent --headless --debug-server=127.0.0.1:0 --artifacts=...`
  starts a loopback-only HTTP server, prints exactly one readiness JSON line,
  and stays running until terminated.
- Requests to non-loopback hosts are rejected at startup.
- `GET /debug/health` returns HTTP 200 with `ok`, `mode`, `frame`, and
  `focused`.
- `GET /debug/state` returns schema-compatible app/window/tab state with
  stable tab and session IDs.
- `GET /debug/screenshot` returns non-empty PNG bytes from the software
  renderer.
- `POST /debug/screenshot` writes a PNG only under the requested artifact
  directory and returns schema-compatible metadata.
- `POST /debug/actions` behaviorally supports `newTab`, `closeTab`,
  `selectTab`, `resizeWindow`, `typeText`, `advanceFrames`,
  `setClipboardText`, and `paste`.
- Unsupported schema actions return bounded `ok:false` action results without
  crashing.
- `GET /debug/sessions` returns one schema-compatible session object per tab.
- `GET /debug/render` returns schema-compatible render diagnostics.
- `GET /debug/frame-commands` returns bounded, source-filterable serialized
  frame commands.
- `POST /debug/render-trace` returns a minimal schema-compatible render trace.
- `POST /debug/wait` succeeds for `textVisible` on the colored-boxes fixture.
- `GET /debug/events` returns bounded events with a monotonic `next` sequence.
- `scripts/test-e2e` launches the server, drives actions, validates endpoints,
  terminates the process, and cleans artifacts on success.
- `./scripts/check` passes.

## Idempotence and Recovery

All run artifacts must be isolated under the requested artifact directory and
all temp files under the requested temp directory. The implementation must be
safe to run from multiple worktrees at the same time by using port `0` and
run-specific directories.

If the server starts but a later setup step fails, close the listening socket
before exiting. If an endpoint fails internally, return a bounded JSON error
with an appropriate HTTP status instead of crashing the process.

The E2E script must kill the launched process on success, failure, or shell
interruption. Preserve artifacts on failure and remove them on success. Do not
commit generated files from `.artifacts/`, `.tmp/`, or `.build/`.

If exact JSON Schema validation tooling is not available locally, tests should
still assert every required field from the checked-in schemas. `./scripts/check`
already validates that schema files themselves are syntactically valid JSON.

## Interfaces and Dependencies

No new third-party package dependencies should be added in this shard.

Recommended Swift interfaces:

```swift
public struct DebugServerAddress: Equatable {
  public var host: String
  public var port: UInt16
}

public struct DebugReadiness: Encodable {
  public var debugServer: String
  public var pid: Int32
  public var runId: String
}

public final class DebugHTTPServer {
  public init(runtime: HeadlessDebugRuntime)
  public func start(host: String, port: UInt16) throws -> DebugReadiness
  public func stop()
}

public final class HeadlessDebugRuntime {
  public init(
    fixtureURL: URL?,
    artifactsURL: URL,
    tempURL: URL?,
    deterministic: Bool,
    runId: String
  ) throws

  public func health() -> DebugResponse
  public func state() -> DebugResponse
  public func screenshotBytes() throws -> (data: Data, frame: Int, width: Int, height: Int)
  public func writeScreenshotArtifact(target: String) throws -> DebugResponse
  public func applyAction(_ data: Data) -> DebugResponse
  public func sessions() -> DebugResponse
  public func renderState() -> DebugResponse
  public func frameCommands(query: DebugQuery) -> DebugResponse
  public func renderTrace(_ data: Data) -> DebugResponse
  public func wait(_ data: Data) -> DebugResponse
  public func events(since: Int) -> DebugResponse
}
```

The exact names may differ, but keep the responsibilities separate:

- `DebugHTTPServer` knows HTTP and sockets.
- `HeadlessDebugRuntime` knows app state, sessions, rendering, artifacts, and
  debug endpoint data.
- `LabanAgent` knows CLI arguments and process lifetime.

Use `JSONEncoder` with `.sortedKeys` for deterministic test output where
convenient. Use `JSONDecoder` for action, wait, and render-trace request
bodies. Use explicit `Encodable` response models instead of hand-assembled JSON
strings.

## Surprises & Discoveries

- Observation: The checked-in action schema already includes actions beyond
  current product behavior.
  Evidence: `schemas/debug/action.schema.json` includes `key`, `mouseWheel`,
  `click`, `copy`, and `scrollViewport`, while the current headless runtime has
  no scrollback, mouse reporting, or selection debug model. This plan requires
  bounded `ok:false` results for those actions instead of pretending they work.

- Observation: The current one-shot headless path writes `.artifacts/` and
  `.tmp/`, but those directories are not ignored yet.
  Evidence: `scripts/run-headless` and `scripts/smoke-runtime` create those
  paths; `.gitignore` currently ignores `.build/`, `.external/`,
  `.claude/worktrees/`, `compile_commands.json`, `*.o`, and `*.d`.

## Follow-up (2026-05-03)

- [x] Fixed `advanceFrames` to render `count` frames (was rendering 1 regardless of count — separate poll loop did not call `renderFrameUnlocked()` per iteration).
- [x] Added bare `--debug-server` shorthand: `--debug-server` without `=value` resolves to `127.0.0.1:0`.
- [x] Strengthened `scripts/test-e2e`: added unsupported-action `ok:false` check (step 19), `POST /debug/render-trace` required-fields check (step 12), `advanceFrames` exact-count check (step 18), bare `--debug-server` health check (step 22). `/debug/events` coverage already present (step 20).
- Decision: bare `--debug-server` supported. Rationale: matches existing `--headless` bare-flag style; agents launching a debug server almost always want port 0 / loopback, making the address explicit in the common case is unnecessary ceremony.

## Outcomes & Retrospective

All four milestones completed in one session (2026-05-03).

**Endpoints landed:** `/debug/health`, `/debug/state`, `GET /debug/screenshot`,
`POST /debug/screenshot`, `/debug/actions` (8 actions implemented, 5 return
bounded `ok:false`), `/debug/sessions`, `/debug/render`, `/debug/frame-commands`,
`POST /debug/render-trace`, `POST /debug/wait` (8 condition kinds), `/debug/events`.

**E2E output:**
```
debug server: http://127.0.0.1:<dynamic>
test-e2e passed
```

**check output:** `check passed` (78 tests, 0 failures).

**Deferred to follow-up:** Interactive (AppKit) debug server support; scrollback
endpoints; `/debug/pixel-probe`, `/debug/atlas`, `/debug/selection`,
`/debug/clipboard`, `/debug/input-log`, `/debug/terminal-log`, `/debug/timing`,
`/debug/errors`, `POST /debug/fixture`, `POST /debug/snapshot`.

**Discovery:** stdout must be flushed with `fflush(stdout)` after printing the
readiness line — Swift's `print()` is fully buffered when stdout is redirected
to a file, causing the parent process to wait indefinitely.
