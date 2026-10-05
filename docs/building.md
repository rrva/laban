# Build, run, and test Laban

This document tells you how to build Laban from source. It also tells you how
to run Laban without a window and how to control it from scripts.

## Prerequisites

- macOS 13 (Ventura) or later to run the app.
- Xcode 26 or later to build the app. The renderer uses `Span` and
  `UTF8Span`. These types are only in the macOS 26 SDK. The app checks for
  them at runtime with `@available(macOS 26, *)` and uses a legacy path on
  older systems. Thus the app runs on macOS 13, but the build needs the
  macOS 26 SDK. Xcode 16.4 (Swift 6.1) and earlier cannot build Laban.
- [Zig](https://ziglang.org/download/) **0.16.0 exactly**. Zig builds the
  vendored libghostty-vt VT core. `fetch-libghostty-vt` does not accept
  other versions, because the Ghostty pin does not compile with them.
- `python3` (included with macOS). `./scripts/build-app` and some
  `./scripts/check` stages use it.
- `jq`. `./scripts/check` and the debug examples below use it.

## Build

Install the tools, then build:

```sh
# If zig@0.15 is still linked from an older checkout: brew unlink zig@0.15
brew install zig@0.16 jq
zig version   # must print exactly 0.16.0

git clone https://github.com/rrva/laban
cd laban
./scripts/fetch-libghostty-vt   # one-time: clone + build the pinned libghostty-vt
./scripts/build-app             # builds LabanApp, laband, labpty into the .app bundle
```

`build-app` makes a signed bundle at **`.build/laban/Laban.app`**.

- If your keychain has a team identity (team `3563RJWBQP`), `build-app` uses
  it. It uses an `Apple Development` certificate first, then a
  `Developer ID Application` certificate.
- The bundle has the hardened runtime and `get-task-allow`. Thus debuggers
  and Instruments can attach to it.
- If your keychain has no team identity, `build-app` signs ad hoc.
- `LABAN_CODESIGN_IDENTITY` sets a different identity. The value `-` forces
  ad-hoc signing. `LABAN_TEAM_ID` sets a different team.

> Always use `./scripts/build-app`. Do not use `swift build` alone. The script
> makes the `.app` bundle, adds the `laband` and `labpty` helpers and the
> resources, writes the git commit into `Info.plist`, and signs the bundle.
> `swift build` does none of these steps.

The first `fetch-libghostty-vt` takes some minutes. After that, it does
nothing until the pin changes. Its output is in
`.external/libghostty-vt/zig-out/`.

## Run

You can run Laban in three modes: as a terminal with a window, as a headless
renderer, or as a debug server that an agent can control.

### As a terminal

```sh
open .build/laban/Laban.app
```

To keep Laban in your Dock, move it into `/Applications`. A local build is not
notarized. An ad-hoc build also has no team signature. Thus the first start
can need right-click → **Open**.

### Headless, one time

This mode renders a fixture without a window server. It writes a screenshot
and a JSON result. Use it in CI or for a quick visual check:

```sh
./scripts/run-headless                              # default fixture
./scripts/run-headless fixtures/colored-boxes.fixture.json
```

When it stops, it shows the paths of the artifacts:

```text
Artifacts: .artifacts/runs/<run-id>
Screenshot: .artifacts/runs/<run-id>/screenshot.png
Result:    .artifacts/runs/<run-id>/result.json
```

## Debug and agent control

### The `laban` CLI

Use the `laban` CLI to control a Laban window that runs. The CLI is in
`Laban.app/Contents/MacOS`. `laban install-cli` adds a shim to your PATH. The
CLI finds the socket and the token of the app.

- `laban status --json` shows the state of the app.
- `laban session get-text --screen --max-lines 40` reads the visible text.
- `laban session screenshot` captures the window.
- `laban propose --purpose "..." -- CMD` sends a command to the user for
  approval. The CLI never types into your session.

Laban asks you one time in the app before it lets the CLI read a session.
`laban --help` shows all the commands.

### HTTP from a headless server

The CLI uses an HTTP debug contract. You can also use this contract directly
from CI or with curl. It does not need a window server. To start a headless
debug server, run:

```sh
./scripts/run-debug
```

The first line on stdout is a readiness JSON. `debugServer` is the path to a
Unix domain socket. It is not a TCP URL:

```json
{"debugServer":"/path/to/laban/.tmp/<run-id>/control.sock","debugToken":"<bearer>","pid":12345,"runId":"manual-debug"}
```

The server uses HTTP only on that socket. It never opens a TCP port. Use
`curl --unix-socket` and a dummy `http://localhost` host. Each `/debug`
request must have `Authorization: Bearer <bearer>`. You can list
capabilities, read the state, type input, take screenshots, wait for
conditions, and capture or replay sessions:

```sh
export DEBUG_URL=<debugServer path from readiness line>
export DEBUG_TOKEN=<token from readiness line>
AUTH=(--unix-socket "$DEBUG_URL" -H "Authorization: Bearer $DEBUG_TOKEN")

curl "${AUTH[@]}" http://localhost/debug/capabilities | jq
curl "${AUTH[@]}" http://localhost/debug/state | jq

curl "${AUTH[@]}" -X POST http://localhost/debug/actions \
  -H 'Content-Type: application/json' \
  -d '{"action":"typeText","text":"printf ok\n"}'

curl "${AUTH[@]}" -X POST http://localhost/debug/wait \
  -H 'Content-Type: application/json' \
  -d '{"timeoutMs":5000,"condition":{"kind":"textVisible","text":"ok"}}'
```

For flows that you repeat, give a JSON fixture to the scenario runner. The
runner starts a headless server, does each step, writes a report, and stops
the server:

```sh
./scripts/run-debug-script fixtures/debug-script-basic.scenario.json
```

To see all entry points of the agent binary, run:

```sh
swift run laban-agent -- --help
```

[`process/dev-process.md`](process/dev-process.md) has the full debug
contract: capabilities, fixture format, capture and replay, screenshot
artifacts, and observability.

## Test

Run the unit tests, or the full local gate. The full gate checks schemas,
docs, formatting, the build, the tests, a runtime smoke test, and a headless
end-to-end scenario:

```sh
./scripts/test     # swift test only
./scripts/check    # the full local gate; the pre-push hook runs its fast subset
```
