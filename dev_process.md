# Agent-Driven Development Process

This document defines the development process and test harness required for
fully agent-driven implementation. The goal is not just automated tests; the
goal is that an agent can build, run, observe, diagnose, and verify the app
end to end without human-operated UI.

The debug/test surface is product infrastructure. It should be implemented
early, kept small, and treated as part of the MVP.

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

Example shape:

```sh
app --headless --debug-server=127.0.0.1:0 --artifacts=.artifacts/run-001
```

### Test Fixture Mode

Runs controlled sessions instead of the user's real shell. This allows exact,
repeatable tests for colors, glyphs, resize, exit state, title updates, and
mouse behavior.

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
{"debugServer":"http://127.0.0.1:49321","pid":12345}
```

The server must be disabled by default. It must not listen on public interfaces.
It must not be enabled in release builds unless an explicit developer flag is
present.

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
  "activeSessionId": "session-1"
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
{"action":"typeText","text":"printf '$HOME\\n'\\n"}
{"action":"key","key":"t","modifiers":["command"]}
{"action":"mouseWheel","x":400,"y":300,"deltaY":-3}
{"action":"click","x":24,"y":84,"button":"left"}
{"action":"advanceFrames","count":3}
```

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

## Headless Rendering Contract

Headless mode must render into an offscreen surface that can be captured as a
PNG. The preferred design is:

- terminal core and app state are identical in interactive and headless modes
- renderer exposes a surface abstraction
- interactive mode presents the surface to the OS
- headless mode renders the same scene into an offscreen surface
- screenshots read pixels from that surface

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
- compare screenshots or pixel probes
- store artifacts on failure

End-to-end tests should be fewer than unit/core tests, but they must cover the
user workflows in `mvp.md`.

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

## Definition Of Done

A behavior is done when an agent can:

- launch the app in headless mode
- drive the behavior through debug actions or test fixtures
- query state proving the internal transition happened
- capture graphics proving the visible result happened
- run the same test in CI without human interaction

Manual testing can still be useful, but it is not the completion criterion for
MVP behavior.
