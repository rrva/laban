# Laban

**Quit, update or crash Laban. Your shells keep running.**

[![Latest release](https://img.shields.io/github/v/release/rrva/laban)](https://github.com/rrva/laban/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
[![License: MIT](https://img.shields.io/github/license/rrva/laban)](LICENSE)

<img src="docs/images/laban.png" width="877" alt="Laban with vertical tabs, JSON and git output, and CJK and emoji text">

Laban is a native macOS terminal whose sessions live in a background daemon,
not the window. Reopen it and you are back in the same tabs, with the same
running processes and scrollback, and no tmux. Text is drawn from font curves
on the GPU, on top of Ghostty's VT core.

## Why Laban

- **Shells outlive the app.** A small daemon owns your shells. Quit Laban,
  let it auto-update, or let it crash: your processes keep running, and
  reopening drops you back where you were, scrollback included. You keep the
  terminal's own scrollback, selection, and mouse, with no prefix keys. (A
  reboot still ends them; they are processes, not snapshots.)
- **Text drawn from font curves.** The default renderer draws glyphs
  straight from font outlines on the GPU. There is no bitmap atlas to
  re-bake, so text stays sharp while you zoom and on fractional display
  scales. Ligatures are on by default. CJK and color emoji stay on the
  raster path that complex scripts need, and tests hold that line.
- **A native Mac app.** AppKit, not Electron. Native text input (including
  layout-specific Option characters), vertical tabs, JetBrains Mono and
  Selenized (Light or Dark, following system appearance) as defaults.
- **Chinese, Japanese, and Korean just work.** A CJK-capable font (PingFang,
  Noto CJK, or Sarasa) is paired with JetBrains Mono automatically and can
  be overridden in Settings. Double-width cell layout comes from the
  conformance-tested terminal core, and Pinyin and other IMEs keep their
  normal candidate window and inline composition.
- **A modern terminal core.** VT parsing comes from libghostty-vt, Ghostty's
  terminal core; the rendering, daemons, and app around it are Laban's own.
  True color, hyperlinks, mouse, synchronized output, Kitty graphics, and
  modern key protocols all work.
- **Scriptable when you want it.** Tabs, scrollback, and screenshots are
  queryable as JSON over a local Unix socket (no TCP port is ever opened),
  and the bundled `laban` CLI makes that a one-liner. An hour-long Claude
  Code or Codex run survives a restart, and with your approval the agent can
  read your session instead of you pasting it. The same terminal also boots
  headless, so CI can type, wait on conditions, and take screenshots.

> **Status: beta.** APIs, scripts, debug endpoints, and on-disk artifact
> formats change without notice.

## Features

Everything below ships in the app today. Most of it lives in the menu bar or
in **Laban → Settings** (⌘,); shortcuts are listed where they exist.

### Sessions and tabs

- **Sessions survive quits, crashes, and updates.** **Laban → Restart Laban**
  (⌥⌘R) relaunches the app without touching your shells. Settings → Terminal
  → *Restore tabs on launch* and *Ask before closing* control the rest.
- **Vertical tab sidebar** (⌃⌘S to show or hide). Each tab shows its folder,
  git branch, and running command. Agents that report status (iTerm2's OSC
  21337) get a colored dot and an Idle / Working / Waiting label. Hover a
  background tab to see a live preview of it (Slug renderer).
- **Tabs:** new ⌘T, close ⌘W, jump with ⌘1–⌘8 and ⌘9 for the last one,
  previous and next with ⌥⌘← / ⌥⌘→. New tabs open in the current tab's
  directory.
- **Split panes:** ⌘D splits right, ⇧⌘D splits down. ⌥⌘[ and ⌥⌘] cycle
  panes, ⌥⌘↑ / ⌥⌘↓ move up and down, ⇧⌘↩ zooms one pane, ⌃⌘= equalizes, and
  ⌃⌘ plus an arrow moves a divider. All of it is in the **Pane** menu.
- **Notifications** when a tab needs you, when a task finishes, or on a bell,
  only for tabs you are not looking at. Each kind can be turned off in
  Settings → Notifications, which also has a sound toggle and a test button.

### Working with text and files

- **Find** in the session with ⌘F.
- **Quick Look** (⌘Y) a selected file path, resolved against the shell's
  current directory.
- **Clickable hyperlinks** (OSC 8) and **drag and drop**: drop files or images
  onto a tab to paste their paths.
- **Clipboard over SSH.** Programs can copy to your Mac clipboard with OSC 52.
  Pasting an image (⌘V) into an `ssh` session uploads it to the remote host,
  once you allow that host, and pastes its path, so Claude Code or Codex on a
  server can take a screenshot. Programs that speak Kitty's clipboard protocol get the image
  in-band instead.
- **Inline images** through the Kitty graphics protocol.
- **Export the last few seconds as an asciinema cast**: ⌘E for the last 10 s,
  or **File → Export Recent…** for 5, 30, or 60 s.
- **Unicode:** grapheme-cluster widths for emoji (mode 2027), automatic CJK
  font pairing, and optional right-to-left text in reading order (Settings →
  Rendering).

### Look and feel

- **Themes:** pick separate light and dark themes that follow the system
  appearance, or import your own `.laban-theme.json`. The import dialog opens
  on bundled examples: Catppuccin, Dracula, Gruvbox, Nord, Rosé Pine,
  Selenized, and Terminal Basic.
- **Background opacity, blur, and an image** behind the text, with Frosted
  and other presets (Settings → Appearance).
- **Text:** font, CJK font, ligatures, text weight, cursor shape and blink,
  emoji rendering, and ⌘+ / ⌘− / ⌘0 to zoom.
- **Keyboard:** *Option as Meta* (Settings → Terminal) for Emacs and shell
  bindings, off by default so layout-specific ⌥ characters still type.
- **Renderers:** Slug Glyph (the default, drawn from font curves), GPU-driven
  Metal, classic Metal, and software. Switch under Settings → Rendering.

### Agents and automation

- **The `laban` CLI** reads a session's screen or scrollback, takes window
  screenshots, scrolls, and waits for a prompt or a finished command. Every
  read asks for your approval in the app first.
- **Command proposals:** `laban propose` lets an agent suggest a command that
  you approve or reject in the app. Nothing is typed into your shell without
  you.
- **Agent control** is switched on or off in Settings → Terminal or from
  **Debug → Disable Agent Control Server**, and Settings → Agent lists and
  revokes the approvals you have given. See
  [`docs/process/controlling-agent-control-plane.md`](docs/process/controlling-agent-control-plane.md)
  and the [threat model](docs/process/control-plane-threat-model.md).
- **Headless mode and scenario scripts** for CI: see
  [Debugging and agent control](#debugging-and-agent-control) below.

### Troubleshooting

- **Help → Diagnostics…**, **Help → Reveal Log Folder in Finder**, and
  **Debug → Send Diagnostics…** collect what a bug report needs.
- **Debug → Start PTY Capture** (⇧⌘R) records raw terminal output for a
  rendering bug.
- Laban checks for updates automatically; turn that off in Settings →
  Terminal. See
  [`docs/release/update-checks.md`](docs/release/update-checks.md).

Design decisions behind each feature are recorded in [`docs/adr/`](docs/adr/);
the documentation index is [`docs/README.md`](docs/README.md).

## Install

Download the notarized `Laban-<version>.dmg` from the
[latest release](https://github.com/rrva/laban/releases/latest), open it, and
drag Laban into `/Applications`. Laban updates itself from then on. Requires
macOS 13 (Ventura) or later.

To build from source instead, read on.

## Build

Prerequisites:

- macOS 13 (Ventura) or later to *run* the app
- Xcode 26 or later to *build* it. The renderer's glyph fast path uses
  `Span`/`UTF8Span`, which only exist in the macOS 26 SDK. They are gated at
  runtime with `@available(macOS 26, *)` and fall back to a legacy path, so the
  built app still runs on macOS 13, but the symbols must resolve at compile
  time. Xcode 16.4 (Swift 6.1) and earlier cannot build this tree.
- [Zig](https://ziglang.org/download/) **0.16.0 exactly**: builds the vendored
  libghostty-vt VT core. `fetch-libghostty-vt` refuses any other version,
  because the Ghostty pin does not compile with it.
- `python3` (ships with macOS): used by `./scripts/build-app` and several
  `./scripts/check` stages
- `jq`: used by `./scripts/check` and the debug examples below

Install the tooling, then build:

```sh
# If zig@0.15 is still linked from an older checkout: brew unlink zig@0.15
brew install zig@0.16 jq
zig version   # must print exactly 0.16.0

git clone https://github.com/rrva/laban
cd laban
./scripts/fetch-libghostty-vt   # one-time: clone + build the pinned libghostty-vt
./scripts/build-app             # builds LabanApp, laband, labpty into the .app bundle
```

`build-app` produces a signed bundle at **`.build/laban/Laban.app`**. It signs
with the team's identity (team `3563RJWBQP`; an `Apple Development` certificate
if present, else `Developer ID Application`) when your keychain has one, with
the hardened runtime and `get-task-allow` so debuggers and Instruments can
attach, and ad-hoc otherwise. `LABAN_CODESIGN_IDENTITY` overrides the identity
(`-` forces ad-hoc); `LABAN_TEAM_ID` changes the team it looks for.

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

Drag it into `/Applications` if you want it on your dock. (A local build is not
notarized, and an ad-hoc one is not team-signed either, so the first launch may
need a right-click → **Open**.)

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

### Using the `laban` CLI

For a running windowed Laban, the bundled `laban` CLI is the everyday way in
(in `Laban.app/Contents/MacOS`; `laban install-cli` puts a shim on your
PATH). It discovers the running app's socket and token for you.
`laban status --json` shows app state, `laban session get-text --screen
--max-lines 40` reads the visible grid, `laban session screenshot` captures
the window, and `laban propose --purpose "..." -- CMD` submits a command for
the user to approve in the app; the CLI never types into your session
directly. Session reads prompt for a one-time in-app approval. `laban --help`
lists everything.

### Raw HTTP from a headless server

Everything the CLI does rides on an HTTP debug contract you can also drive
directly, with no window server, from CI, or with plain curl. Start a
headless debug server:

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
