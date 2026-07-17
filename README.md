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

Prerequisites:

- macOS 13 (Ventura) or later
- Xcode 15 or later (provides the Swift 5.9+ and Metal toolchains)
- [Zig](https://ziglang.org/download/) 0.15.2 or later — builds the vendored
  libghostty-vt VT core
- `jq` — used by `./scripts/check` and the debug examples below

Install the tooling, then build:

```sh
brew install zig jq
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

## Verify

Run the unit tests, or the full local gate (schemas, docs, formatting, build,
tests, runtime smoke test, and a headless end-to-end scenario):

```sh
./scripts/test     # swift test only
./scripts/check    # the full local gate; CI runs its per-PR test/formal subset
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
