# Laban

[![check](https://github.com/rrva/laban/actions/workflows/check.yml/badge.svg)](https://github.com/rrva/laban/actions/workflows/check.yml)

**A macOS terminal designed to be driven by agents.**

Laban is a native macOS terminal where every visible part of the running app
— tabs, selection, cursor, scrollback, rendered frames, event log — is also
queryable and controllable over a loopback HTTP server. It behaves like a
normal terminal for humans, and like a deterministic test fixture for agents
and CI.

## Why Laban

- **HTTP control plane.** A loopback debug server exposes tabs, cursor,
  scrollback, rendered frames, and event log as JSON. Drive the app with
  `curl` or replay a scenario from a JSON fixture.
- **Headless rendering.** Boot the same terminal without a window server.
  Capture screenshots, diff frame commands, replay sessions — all from CI.
- **Real terminal behavior.** VT parsing is libghostty's, not hand-rolled.
  Synchronized output, hyperlinks, mouse, true color, and modern key
  protocols work as they would in any modern terminal.
- **macOS-native.** AppKit, not Electron. Native text input (including
  layout-specific Option characters), vertical tabs, JetBrains Mono and
  Selenized Light as defaults.
- **One gate for everything.** `./scripts/check` runs schemas, docs,
  debug-contract drift, formatting, build, unit tests, a runtime smoke test,
  and a headless end-to-end debug-server scenario.

> **Status: alpha.** APIs, scripts, debug endpoints, and on-disk artifact
> formats change without notice. Not yet a daily-driver replacement.

## Build

Requirements:

- macOS 13 or later
- Xcode 15 or later (Swift 5.9+)
- Zig 0.15.2 or later (used to build the vendored libghostty-vt core)

```sh
brew install zig
git clone https://github.com/rrva/laban
cd laban
./scripts/fetch-libghostty-vt
./scripts/build-app
open .artifacts/Laban.app
```

The first build of libghostty-vt takes a couple of minutes. Subsequent builds
are cached under `.external/libghostty-vt/zig-out/`.

## Debugging and agent control

Start a headless debug server:

```sh
./scripts/run-debug
```

The first stdout line is readiness JSON:

```json
{"debugServer":"http://127.0.0.1:49321","debugToken":"<bearer>","pid":12345,"runId":"manual-debug"}
```

Every `/debug` request needs `Authorization: Bearer <bearer>`. From there you
can list capabilities, query state, type input, take screenshots, wait on
conditions, and capture or replay full sessions:

```sh
export DEBUG_URL=http://127.0.0.1:49321
export DEBUG_TOKEN=<token from readiness line>
AUTH=(-H "Authorization: Bearer $DEBUG_TOKEN")

curl "${AUTH[@]}" "$DEBUG_URL/debug/capabilities" | jq
curl "${AUTH[@]}" "$DEBUG_URL/debug/state" | jq

curl "${AUTH[@]}" -X POST "$DEBUG_URL/debug/actions" \
  -H 'Content-Type: application/json' \
  -d '{"action":"typeText","text":"printf ok\n"}'

curl "${AUTH[@]}" -X POST "$DEBUG_URL/debug/wait" \
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

## License

Laban is released under the MIT license; see [`LICENSE`](LICENSE).

- JetBrains Mono is licensed under the SIL Open Font License 1.1; see
  [`Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt`](Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt).
- libghostty-vt, fetched at build time into `.external/libghostty-vt/`, is
  MIT licensed (© 2024 Mitchell Hashimoto, Ghostty contributors).
