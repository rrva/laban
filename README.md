# Laban

[![check](https://github.com/rrva/laban/actions/workflows/check.yml/badge.svg)](https://github.com/rrva/laban/actions/workflows/check.yml)

**A macOS terminal designed to be driven by agents.**

Laban is a native macOS terminal where every visible part of the running app
— tabs, selection, cursor, scrollback, rendered frames, event log — is also
queryable and controllable over a local HTTP control plane. It behaves like a
normal terminal for humans, and like a deterministic test fixture for agents
and CI.

## Why you'd want it

- **Your sessions outlive the app.** Shells run in a small background daemon,
  not inside the window. Quit Laban, upgrade it, or let it crash: everything
  keeps running, and reopening drops you back exactly where you were,
  scrollback and all.
- **Never lose a working agent.** A Claude Code or Codex run that has been
  going for an hour survives a terminal restart untouched.
- **Text that stays sharp.** A vector renderer mode draws glyphs from font
  curves on the GPU, not scaled bitmaps, so text is crisp at any zoom or
  display scale.
- **Feels like a real terminal.** Modern VT behavior (true color, hyperlinks,
  mouse, synchronized output) in a fast native Mac app, not a web view.
- **Agents can see what you see.** Tools can inspect and drive the same
  terminal you're looking at, so "check what happened in my session" is a
  query, not a copy-paste.

## Why Laban

- **HTTP control plane.** A debug server on a Unix domain socket (no TCP port
  is ever opened) exposes tabs, cursor, scrollback, rendered frames, and event
  log as JSON. Drive the app with `curl --unix-socket` or replay a scenario
  from a JSON fixture.
- **Headless rendering.** Boot the same terminal without a window server.
  Capture screenshots, diff frame commands, replay sessions — all from CI.
- **Real terminal behavior.** VT parsing is libghostty's, not hand-rolled.
  Synchronized output, hyperlinks, mouse, true color, and modern key
  protocols work as they would in any modern terminal.
- **macOS-native.** AppKit, not Electron. Native text input (including
  layout-specific Option characters), vertical tabs, JetBrains Mono and
  Selenized (Light or Dark, following system appearance) as defaults.
- **One gate for everything.** `./scripts/check` runs schemas, docs,
  debug-contract drift, formatting, build, unit tests, a runtime smoke test,
  and a headless end-to-end debug-server scenario.

> **Status: alpha.** APIs, scripts, debug endpoints, and on-disk artifact
> formats change without notice. Not yet a daily-driver replacement.

## Build

Prerequisites:

- macOS 13 (Ventura) or later to *run* the app
- Xcode 26 or later to *build* it. The renderer's glyph fast path uses
  `Span`/`UTF8Span`, which only exist in the macOS 26 SDK. They are gated at
  runtime with `@available(macOS 26, *)` and fall back to a legacy path, so the
  built app still runs on macOS 13, but the symbols must resolve at compile
  time. Xcode 16.4 (Swift 6.1) and earlier cannot build this tree.
- [Zig](https://ziglang.org/download/) **0.15.2 exactly** (not newer): builds
  the vendored libghostty-vt VT core. `fetch-libghostty-vt` refuses any other
  version, because the Ghostty pin below does not compile with it.
- `python3` (ships with macOS): used by `./scripts/build-app` and several
  `./scripts/check` stages
- `jq`: used by `./scripts/check` and the debug examples below

Install the tooling, then build:

```sh
# The default `zig` formula is 0.16, which fetch-libghostty-vt rejects.
# zig@0.15 is keg-only, so it must be put on PATH explicitly.
brew install zig@0.15 jq
export PATH="$(brew --prefix zig@0.15)/bin:$PATH"
zig version   # must print exactly 0.15.2

git clone https://github.com/rrva/laban
cd laban
./scripts/fetch-libghostty-vt   # one-time: clone + build the pinned libghostty-vt
./scripts/build-app             # builds LabanApp, laband, labpty into the .app bundle
```

`build-app` produces a signed (ad-hoc) bundle at **`.build/laban/Laban.app`**.

> Always build with `./scripts/build-app`, not a bare `swift build`. The script
> assembles the `.app` bundle, copies in the `laband`/`labpty` helpers and
> resources, stamps the git commit into `Info.plist`, and code-signs — none of
> which a plain `swift build` does.

The first `fetch-libghostty-vt` takes a couple of minutes; afterward it is a
no-op until the pin moves, and its output is cached under
`.external/libghostty-vt/zig-out/`.

## Run

Three ways to run Laban: as a normal windowed terminal, as a one-shot headless
renderer, or as a live, agent-controllable debug server.

### As a terminal (GUI)

```sh
open .build/laban/Laban.app
```

Drag it into `/Applications` if you want it on your dock. (It's an ad-hoc
signed alpha build, so the first launch may need a right-click → **Open**.)

### Headless, one shot

Render a fixture without a window server and write a screenshot plus a JSON
result — handy from CI or for a quick visual check:

```sh
./scripts/run-headless                              # default fixture
./scripts/run-headless fixtures/colored-boxes.fixture.json
```

It prints the artifact paths on exit:

```text
Artifacts: .artifacts/runs/<run-id>
Screenshot: .artifacts/runs/<run-id>/screenshot.png
Result:    .artifacts/runs/<run-id>/result.json
```

## Debugging and agent control

Start a headless debug server:

```sh
./scripts/run-debug
```

The first stdout line is readiness JSON. `debugServer` is the path to a Unix
domain socket, not a TCP URL:

```json
{"debugServer":"/path/to/laban/.tmp/<run-id>/control.sock","debugToken":"<bearer>","pid":12345,"runId":"manual-debug"}
```

The server speaks HTTP, but only over that socket: it never binds a TCP port,
so reach it with `curl --unix-socket` and a dummy `http://localhost` host.
Every `/debug` request needs `Authorization: Bearer <bearer>`. From there you
can list capabilities, query state, type input, take screenshots, wait on
conditions, and capture or replay full sessions:

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

For repeatable flows, point the scenario runner at a JSON fixture. It boots
a headless server, executes every step, writes a report, and shuts the
server down:

```sh
./scripts/run-debug-script fixtures/debug-script-basic.scenario.json
```

The agent binary lists every entry point:

```sh
swift run laban-agent -- --help
```

The full debug contract — capabilities, fixture format, capture/replay,
screenshot artifacts, observability — lives in
[`docs/process/dev-process.md`](docs/process/dev-process.md).

## Verify

Run the unit tests, or the full local gate (schemas, docs, formatting, build,
tests, runtime smoke test, and a headless end-to-end scenario):

```sh
./scripts/test     # swift test only
./scripts/check    # the full local gate; the pre-push hook runs its fast subset
```

## License

Laban is released under the MIT license; see [`LICENSE`](LICENSE).

Third-party components bundled or linked into the distributed app are credited
in full in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md):

- libghostty-vt (Ghostty) — MIT licensed (© 2024 Mitchell Hashimoto, Ghostty
  contributors); fetched at build time into `.external/libghostty-vt/` and
  statically linked.
- JetBrains Mono — SIL Open Font License 1.1; see
  [`Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt`](Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt).
