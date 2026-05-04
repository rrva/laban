# Build Exploratory Debug Control

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

After this change, an agent can launch Laban headlessly, remotely drive the
running app through the loopback debug server, and collect enough diagnostics
to explore failures without desktop automation. The existing debug server
already supports core actions, screenshots, state, sessions, render state, frame
commands, render traces, events, input logs, selection, clipboard, and capture
controls. This plan fills the remaining exploratory gaps: artifact snapshots,
pixel probes, terminal byte logs, timing summaries, structured errors, and
fixture reload/restart/step control.

The behavior is visible by starting `laban-agent --headless
--debug-server=127.0.0.1:0`, parsing the readiness URL, then calling endpoints
such as `/debug/pixel-probe`, `/debug/terminal-log`, `/debug/snapshot`, and
`/debug/fixture`.

## Progress

- [x] Read `AGENTS.md`, `PLANS.md`, `docs/product/mvp.md`,
  `docs/process/dev-process.md`, `docs/process/worktree-isolation.md`,
  `docs/process/observability.md`, `Sources/LabanAgent/main.swift`,
  `Sources/LabanDebug/DebugHTTPServer.swift`,
  `Sources/LabanDebug/HeadlessDebugRuntime.swift`,
  `Sources/LabanDebug/DebugModels.swift`, `Sources/LabanCore/FixtureRunner.swift`,
  and the relevant debug schemas.
- [x] Confirmed the current tree already has core headless remote control:
  `/debug/actions`, `/debug/health`, `/debug/state`, `/debug/screenshot`,
  `/debug/sessions`, `/debug/render`, `/debug/frame-commands`,
  `/debug/render-trace`, `/debug/wait`, `/debug/events`, `/debug/input-log`,
  `/debug/capture/*`, `/debug/selection`, and `/debug/clipboard`.
- [x] Queried DeepWiki for `asciinema/asciinema`, `charmbracelet/vhs`, and
  `kovidgoyal/kitty` as references for PTY event capture, replay, scripted
  driving, waits, artifact generation, and out-of-process extension boundaries.
- [x] Add `/debug/snapshot`, `/debug/pixel-probe`, `/debug/terminal-log`,
  `/debug/timing`, `/debug/errors`, and `/debug/fixture` routes.
- [x] Add runtime support for fixture load/restart/step without requiring a
  process restart.
- [x] Add tests and E2E script coverage proving the exploratory loop works.
- [x] Run validation commands and record results.

## Decision Log

- Decision: Build the headless exploratory-control surface first and leave
  interactive AppKit debug-server attachment for a later shard.
  Rationale: `laban-agent` already owns a stable `HeadlessDebugRuntime` and
  loopback server that agents can use today. AppKit attachment needs lifecycle
  integration with `MainWindowController` and must not risk destabilizing the
  current UI path while this task is about remote exploratory testing.
  Date/Author: 2026-05-04 / Codex.

- Decision: Implement `/debug/snapshot` as an artifact-directory bundle
  independent of active full capture recording.
  Rationale: Exploratory testing often needs a one-shot diagnostic dump without
  first starting a capture. Existing `/debug/capture/snapshot` remains the
  capture-specific bundle inside a capture run.
  Date/Author: 2026-05-04 / Codex.

## Surprises & Discoveries

- Observation: DeepWiki reports that `asciinema/asciinema` models terminal
  recording as timestamped `Output`, `Input`, `Resize`, and `Marker` events
  emitted from a PTY-owning session and fanned out to file writers or live
  streaming. It also treats input capture as opt-in and supports pause/markers
  for privacy.
  Impact: Laban's debug terminal log should stay event-based and bounded, and
  future capture controls should keep input capture/privacy as explicit policy.

- Observation: DeepWiki reports that `charmbracelet/vhs` layers a declarative
  tape format over terminal-driving primitives such as typed text, key presses,
  waits, sleeps, screenshots, and output artifacts.
  Impact: This plan implements HTTP primitives, not a script language, but the
  endpoints should be composable enough for a later tape-style exploratory
  runner.

- Observation: DeepWiki reports that `kovidgoyal/kitty` kittens run extension
  logic out-of-process, then return structured results to the main kitty process
  through a constrained result handler. Kittens can opt into remote-control
  capabilities, and terminal UI helpers live outside the main app authority
  boundary.
  Impact: Future Laban exploratory helpers should be layered on top of
  `/debug/actions` and result artifacts rather than getting direct access to
  `AppModel` internals.

## Context and Orientation

`Sources/LabanAgent/main.swift` parses command-line flags. When
`--debug-server=127.0.0.1:0` is present with `--headless`, it creates
`HeadlessDebugRuntime`, starts `DebugHTTPServer`, prints one readiness JSON
line, then serves until terminated.

`Sources/LabanDebug/DebugHTTPServer.swift` is a small loopback-only HTTP
server. Its `route(method:path:query:body:)` function maps `/debug/...`
requests to methods on `HeadlessDebugRuntime`.

`Sources/LabanDebug/HeadlessDebugRuntime.swift` owns the app model, fixture
sessions, software renderer, current surface, frame counter, event log, input
log, capture recorder, and debug clipboard. It is protected by one lock so HTTP
requests do not mutate `AppModel` concurrently.

`Sources/LabanCore/FixtureRunner.swift` loads JSON fixtures and applies fixture
steps to the active session. A fixture step is one of `setTitle`, `writeBytes`,
or `waitFrames`.

## Plan of Work

1. Add request/response models in `DebugModels.swift` for pixel probes,
   terminal logs, timing, structured errors, fixture control, and artifact
   snapshots when existing models are not sufficient.
2. Extend `DebugHTTPServer.route` with:
   - `POST /debug/pixel-probe`
   - `GET /debug/terminal-log`
   - `GET /debug/timing`
   - `GET /debug/errors`
   - `POST /debug/fixture`
   - `POST /debug/snapshot`
3. Extend `HeadlessDebugRuntime` with:
   - bounded structured error storage;
   - bounded terminal-byte projections derived from debug input, output, and
     paste actions;
   - timing fields for the last frame and screenshot capture;
   - pixel point/region probes against `BitmapSurface`;
   - a general artifact snapshot writer under
     `<artifacts>/snapshots/snapshot-######/manifest.json`;
   - fixture state fields and helpers for load/restart/step.
4. Update `scripts/test-e2e` to call the new endpoints against a live server.
5. Add focused `LabanDebugTests` for runtime methods that are easier to test
   without opening a socket.

## Validation and Acceptance

Run from the repository root:

```sh
./scripts/test
./scripts/test-e2e
./scripts/check
```

Validation completed on 2026-05-04:

```sh
swift test --filter LabanDebugExploratoryControlTests
# Executed 5 tests, with 0 failures.

./scripts/test-e2e
# test-e2e passed

./scripts/test
# Executed 246 tests, with 2 skipped and 0 failures.

./scripts/check
# check passed
```

Acceptance:

- `/debug/pixel-probe` returns point RGBA values and region summaries.
- `/debug/terminal-log` returns bounded input/output events for the requested
  session.
- `/debug/timing` returns the current frame and non-negative timing fields.
- `/debug/errors` returns structured errors after invalid debug requests.
- `/debug/snapshot` writes a diagnostic bundle containing JSON state files and
  a screenshot under the requested artifact directory.
- `/debug/fixture` can load, step, and restart a fixture while the server keeps
  running.

## Idempotence and Recovery

All generated snapshots and screenshots must be written under the supplied
artifact directory. Re-running tests may remove temporary artifact directories
on success and preserve them on failure. Source edits are additive and can be
re-run safely.
