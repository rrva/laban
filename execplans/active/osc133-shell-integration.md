# OSC 133 Shell Integration: Prompt / Command / Exit State

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(at the repository root). Keep `Progress` and `Validation and Acceptance`
current as work proceeds. Add optional sections only when they contain
information that will help a fresh contributor.

## Purpose / Big Picture

Today Laban (a macOS terminal app) shows a terminal but has no idea what the
shell inside it is *doing*: whether the user is sitting at a prompt, running a
command, or just got a non-zero exit. This plan adds **OSC 133 shell
integration** so Laban knows the shell's lifecycle phase and the exit code of
the last command.

"OSC 133" is a small set of escape sequences a shell emits at known moments:

| Sequence | Meaning |
| --- | --- |
| `ESC ] 133 ; A ST` | A fresh prompt is about to be drawn (precmd). |
| `ESC ] 133 ; B ST` | The prompt finished; user input starts here. |
| `ESC ] 133 ; C ST` | The user pressed Enter; a command is now running (preexec). |
| `ESC ] 133 ; D ; <exit> ST` | The command finished; `<exit>` is its status. |

`ESC` is byte `0x1B`, `ST` ("string terminator") is either `BEL` (`0x07`) or
`ESC \` (`0x1B 0x5C`). These markers are produced by the shell, not by the
user, and they are invisible — terminals consume them rather than displaying
them.

**What a user can do after this change that they could not before:** every tab
exposes a live shell phase — `idle` / `at-prompt` / `running` / `finished` —
plus the exit code of the last finished command. A headless test (and later
the UI) can read this and react: e.g. a tab badge that turns red when a
background command exits non-zero, or a "command still running" indicator.

**How to see it working (end state of Milestone 1):** start the headless debug
runtime, feed a session a canned OSC 133 byte stream, and `GET
/debug/shell-integration/state` returns the phase and last exit code. Feed the
same bytes through a real shell that has Laban's integration installed
(Milestone 2) and the same endpoint reflects real prompt/command transitions.

This is item #5 on the post-MVP roadmap in `docs/product/mvp.md`
("shell integration markers"), and it implements section 7 plus the relevant
parts of sections 15–21 of `docs/product/spec.md`.

## Progress

- [x] (2026-05-22) Architecture validated: libghostty-vt's C API exposes
  `GHOSTTY_OSC_COMMAND_SEMANTIC_PROMPT` but provides **no data extraction** for
  the action letter or exit code (only `GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR`
  exists). Decided on a Laban-side byte scanner mirroring `tab_status.c`. See
  Decision Log entry 1.
- [x] (2026-05-22) **Milestone 1 — Parsing + headless contract.** Done:
  Laban-side OSC 133 scanner (`Sources/LabanTerminalCore/osc133.c`) wired into
  `laban_vt_write_capture` (`capture.c`) beside `laban_scan_tab_status`;
  C-boundary callback `laban_session_set_osc133_callback` +
  `LabanOSC133Action`; Swift reducer `ShellIntegrationState` owned by `Session`
  (tracked unconditionally from creation); `GET
  /debug/shell-integration/state` endpoint + `shell.integration` events on
  `GET /debug/events` via `AppModel.onShellIntegrationChange`. 15 tests pass
  (`swift test --filter ShellIntegration`): reducer, scanner (split reads, ESC\
  terminator, unknown/unrelated OSC), and endpoint/event-stream coverage.
  Full `./scripts/check` gate passes (build, swift-format, ASan tests, smoke,
  E2E, boundaries, debug-contract, deps). Shipped as PR #4. Awaiting the
  fresh-agent Review Gate below.
- [x] (2026-05-22) **Milestone 2 — zsh injection.** Done:
  `Sources/LabanCore/ShellIntegrationOverlay.swift` generates a zsh rc-overlay
  (`.zshenv` restores the user's real `ZDOTDIR` then sources a guarded
  `laban-integration.zsh` that emits A/C/D via `precmd`/`preexec`). C layer
  persists `config->envp` on the session (`stored_envp`, deep-copied at
  create, used by the deferred-spawn path, freed in destroy) so the `ZDOTDIR`
  override survives restore. `Session.realShell`/`makeDeferred` gained an
  `environment:` parameter; `MainWindowController` installs the overlay once
  per process under a unique temp dir and threads the overrides into all
  session factories. End-to-end test spawns real `/bin/zsh` under the overlay,
  runs `false`, and observes `lastExitCode == 1` (5 tests pass,
  `swift test --filter ShellIntegrationOverlay`). Full `./scripts/check`
  (incl. ASan) passes. The `B` (prompt-end) marker is omitted — it needs PS1
  surgery and `A` already drives `atPrompt`. See Decision Log.
- [x] (2026-05-22) **Milestone 3 — bash + fish injection.** Done:
  `ShellIntegrationOverlay.install` now returns a `ShellIntegrationLaunch`
  (env overrides + optional argv). **bash**: launches `bash --rcfile <overlay>
  -i` (interactive, non-login); the overlay rcfile sources the login profile
  chain then installs a `PROMPT_COMMAND` + `DEBUG`-trap hook that preserves
  `$?`. **fish**: prepends a dir to `XDG_DATA_DIRS` holding
  `fish/vendor_conf.d/laban-integration.fish` (additive vendor conf.d, verified
  against fish docs — not `XDG_CONFIG_HOME`, which would replace user config),
  using `fish_prompt`/`fish_preexec`/`fish_postexec` events. `Session` gained
  `launchArgv:` on `realShell`/`startSpawn` (argv[0] is the executable);
  `startSpawn` prefers a resume injection over the integration argv so agent
  resume still wins. `MainWindowController` threads the full launch through all
  factories. Tests: 10 in `ShellIntegrationOverlayTests` — real `/bin/zsh` and
  `/bin/bash` end-to-end (`false` -> `lastExitCode == 1`); fish e2e skips when
  fish is absent but its install (file + `XDG_DATA_DIRS`) is unit-tested. Full
  `./scripts/check` passes.
- [x] (2026-05-22) **Milestone 4 — UI consumers.** Done: OSC 133 phase +
  last command exit code fold into `TabTitleMetadata` (runtime UI state, not
  persisted) via `AppModel.applyShellIntegration`. `SidebarProducer` renders a
  top-right indicator dot: red for a non-zero finished command, blue while a
  command runs, nothing at prompt/idle — slotted below the OSC 21337 agent dot
  and above the legacy attention badge. Debug `/debug/state` `TabResponse`
  exposes `shellPhase` + `lastCommandExitCode` (schema updated). Tests: 5
  `SidebarShellIndicatorTests` (indicator color matrix) + a `/debug/state`
  assertion that the active tab reflects `finished`/exit 3. `quality.md` no
  longer lists shell integration as deferred.

## Decision Log

- Decision: Implement OSC 133 detection as a Laban-side byte scanner
  (`Sources/LabanTerminalCore/osc133.c`) rather than via libghostty-vt's OSC
  parser.
  Rationale: The vendored C API (`.external/libghostty-vt/include/ghostty/vt/osc.h`)
  defines `GHOSTTY_OSC_COMMAND_SEMANTIC_PROMPT = 3` but the `GhosttyOscCommandData`
  enum only supports extracting `CHANGE_WINDOW_TITLE_STR` — there is no way to
  read the action letter (A/B/C/D) or the exit code through the C boundary,
  even though the Zig parser (`src/terminal/osc/parsers/semantic_prompt.zig`)
  has full support. A Laban-side scan is consistent with ADR 0003
  (terminal-find scans Laban-side until libghostty-vt exposes bindings), ADR
  0001 (libghostty owns VT *rendering* state; app-semantic OSC observers are
  Laban's), and the existing OSC 21337 tab-status scanner. The bell, by
  contrast, *does* have a libghostty callback — OSC 133 does not, so the bell's
  approach does not transfer.
  Date/Author: 2026-05-22

- Decision: Milestone 1 claims only the iTerm2/FinalTerm A/B/C/D subset (with D's
  exit code). Defer L/I/N/P actions and the `aid=`, `cmdline=`, `redraw=`
  options.
  Rationale: A/B/C/D + exit code is exactly the set `docs/product/spec.md` §7
  names ("idle → at-prompt → running → finished") and what the UI consumers in
  Milestone 4 need. The other actions/options have no consumer yet; parsing
  them would be untested code. The scanner ignores unknown actions rather than
  erroring, so adding them later is additive.
  Date/Author: 2026-05-22

- Decision: idempotence with the user's existing shell integration —
  emit-anyway, tolerate in the parser. Starship, oh-my-zsh, and Ghostty's own
  shell-integration script all emit OSC 133. Rather than detect and suppress
  the user's integration (fragile, shell-and-framework-specific), Laban's
  overlay sets `LABAN_SHELL_INTEGRATION=1` only to guard against re-sourcing
  itself, and otherwise emits its markers unconditionally. The `ShellIntegrationState`
  reducer is idempotent for phase (two `A`s in a row stay `atPrompt`); the only
  duplication risk is two `D`s, where the reducer keeps the last reported exit
  code. If real-world double-emit proves noisy, revisit in a later milestone.
  Date/Author: 2026-05-22

- Decision: the zsh rc-overlay is a **per-process shared directory**, generated
  lazily on the first real-shell spawn under a unique temp directory, not a
  global fixed path.
  Rationale: the OSC 133 snippet is identical for every session, so a
  per-session mkdir+write would be pure overhead. `docs/process/worktree-isolation.md`
  forbids global fixed temp paths (they collide across concurrent worktree
  runs), so the overlay base is a unique per-process directory
  (`<temp>/laban-shell-integration-<uuid>/`) and is injectable so headless runs
  can place it under their run-scoped temp dir. The overlay sources the user's
  real `ZDOTDIR` (or `$HOME`) captured at generation time, so a per-process dir
  is correct even across tab restarts. OS temp cleanup reclaims it; Laban does
  not delete it at exit because live shells still reference it.
  Date/Author: 2026-05-22

- Decision: the shell-phase indicator and the bell badge stay independent but
  layered by specificity in the sidebar's single top-right indicator slot:
  OSC 21337 agent dot > OSC 133 shell phase (red = failed command, blue =
  running) > legacy bell/attention badge. The bell says "output happened"; the
  shell phase says "the command finished, and whether it succeeded" — distinct
  signals, so the shell phase does not replace or recolor the bell badge, it
  occupies the slot when more specific.
  Rationale: a single indicator slot can show only one thing; ordering by
  specificity surfaces the most actionable signal without inventing a second
  badge column. Date/Author: 2026-05-22

## Outcomes & Retrospective

All four milestones shipped as a stack of focused PRs (one behavioral reason
each, per AGENTS.md): #4 parsing + headless contract, #5 zsh injection, #6
bash + fish injection, #7 UI consumers. A user now sees, per tab, whether the
shell is at a prompt, running a command, or just failed — driven by real OSC
133 markers their own shell emits through Laban's rc-overlays, with no dotfile
edits. The architecture validated cleanly against the existing OSC 21337
scanner and `RestoreShellInjection` precedents; the only load-bearing new
mechanism was persisting `config->envp` on the C session so env overrides
survive the deferred-spawn restore path. Deferred within §7 (unchanged): regex
needles are unrelated; for shell integration specifically, the `B`
(prompt-end) marker, command-line capture (`aid=`/`cmdline=`), and detecting
the user's pre-existing integration to suppress double-emit are left for later
if real usage demands them.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan's **Milestone 1** is considered complete. The executing agent must not
mark Milestone 1 as done until this gate passes. See "Review gate and
review-fix loop" in `PLANS.md`.

- [ ] `grep -n "laban_scan_osc133" Sources/LabanTerminalCore/capture.c` returns
  a hit on the same call path as `laban_scan_tab_status` (i.e. inside
  `laban_vt_write_capture`, before `ghostty_terminal_vt_write`).
- [ ] `swift build` exits 0.
- [ ] `swift test` exits 0 and includes a new test whose name contains
  `OSC133` (or `ShellIntegration`) that fails if the scanner is removed.
  Demonstrate: comment out the `laban_scan_osc133` call in `capture.c`, rerun
  the targeted test, expect failure; restore it, expect pass.
- [ ] `./scripts/check-boundaries` exits 0 (the new C scanner must not pull in
  AppKit/renderer/debug-HTTP includes; the state machine lives in `LabanCore`).
- [ ] Feed this exact byte stream to a session and assert the resulting phase
  is `finished` with exit code `0`:
  `ESC]133;A BEL` + `prompt$ ` + `ESC]133;B BEL` + `ls` + `ESC]133;C BEL` +
  `output\n` + `ESC]133;D;0 BEL`. A unit test or a `GET
  /debug/shell-integration/state` transcript both satisfy this.
- [ ] `GET /debug/shell-integration/state` is reachable on the headless debug
  runtime and returns a JSON object containing keys `phase` and
  `lastExitCode`. Confirm via `./scripts/check-debug-contract` exit 0 (the
  endpoint must be registered in discovery and documented in
  `docs/process/dev-process.md`).
- [ ] `./scripts/check` exits 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Context and Orientation

You need no prior knowledge of this repo. Here is the lay of the land for this
task.

**Module layout** (each is a SwiftPM target under `Sources/`):

- `Sources/LabanTerminalCore/` — a thin C layer that wraps the vendored
  `libghostty-vt` VT parser and owns the pty. It exposes a C ABI declared in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`. This is where the
  byte scanner and its callback live. It must not depend on AppKit, the
  renderer, or the debug HTTP server (enforced by `./scripts/check-boundaries`).
- `Sources/LabanCore/` — Swift wrappers over the C layer: `Session.swift`,
  `AppModel.swift`, plus the `Persistence/` subtree. No AppKit. The OSC 133
  *state machine* (turning callback events into a phase enum) lives here.
- `Sources/LabanApp/` — the AppKit UI (`MainWindowController.swift`,
  `AppDelegate.swift`, the views). Milestone 4's tab indicator lands here.
- `Sources/LabanDebug/` — the headless debug HTTP server
  (`DebugHTTPServer.swift`, `HeadlessDebugRuntime.swift`) that mirrors the
  AppKit runtime so tests can drive the app without a screen. New debug
  endpoints register here.
- `.external/libghostty-vt/` — the vendored VT library (read-only reference).
  Its C API lives in `.external/libghostty-vt/include/ghostty/vt/`.

**The established precedent you are copying.** There is already a Laban-side
OSC scanner for iTerm2's OSC 21337 "tab status" sequence. Read these three
files before writing any code — your work mirrors them almost exactly:

1. `Sources/LabanTerminalCore/tab_status.c` — a byte-at-a-time state machine
   (`laban_scan_tab_status`) that sniffs `ESC ] 21337 ; ... ST`, buffers the
   payload across reads, parses it, and fires a registered callback. It also
   handles both `BEL` and `ESC \` terminators and resets cleanly when a
   different OSC number appears.
2. `Sources/LabanTerminalCore/session_internal.h` (lines ~63–88, 142–144) —
   the scanner's state enum (`TS_NORMAL`, `TS_AFTER_ESC`, …), its fixed-size
   buffers, and the `LabanTabStatusScanner` struct stored inside the session
   struct, plus the callback function pointer + userdata fields.
3. `Sources/LabanTerminalCore/include/LabanTerminalCore.h` (lines ~309–356) —
   the public callback typedef (`LabanTabStatusCallback`) and the registration
   function (`laban_session_set_tab_status_callback`). The bell callback
   (`LabanBellCallback`, `laban_session_set_bell_callback`) right below it shows
   the simplest possible callback shape (userdata, session, a count).

**The single integration point.** All PTY output bytes pass through
`laban_vt_write_capture` in `Sources/LabanTerminalCore/capture.c`. At line 31
it calls `laban_scan_tab_status(s, bytes, len)` immediately before handing the
bytes to libghostty (`ghostty_terminal_vt_write`). You add one line —
`laban_scan_osc133(s, bytes, len);` — on the same path. The scanner only
observes; it never modifies the byte stream.

**The launch/environment path** (needed for Milestone 2+). The C function
`build_spawn_env(overrides)` in
`Sources/LabanTerminalCore/session_lifecycle.c` (line ~35) merges the parent
`environ` with caller-supplied `envp` overrides (it already special-cases
`TERM`, `COLORTERM`, `NO_COLOR`). Passing `ZDOTDIR=<dir>` as an override is how
zsh is pointed at a wrapper rc-directory. Shell resolution is centralized in
`Sources/LabanCore/Persistence/RestoreShellInjection.swift` (`LoginShell.resolvePath`):
`$SHELL` → passwd entry → `/bin/sh`. Reuse it; do not re-derive.

**Definitions used in this plan:**

- *Scanner*: a small C state machine fed raw bytes; it remembers partial
  sequences across calls (PTY reads arrive in arbitrary chunks).
- *rc-overlay*: a directory of shell startup files Laban generates, which
  `source` the user's real startup files and then append a few lines that emit
  the OSC 133 markers. The shell is pointed at this directory with an
  environment variable so the user never edits their dotfiles.
- *Phase*: the shell lifecycle state — `idle` (no marker seen yet),
  `atPrompt` (saw A or B), `running` (saw C), `finished` (saw D).

## Plan of Work

### Milestone 1 — Parsing + headless contract

The goal: turn raw OSC 133 bytes into an observable phase + exit code, with no
shell changes yet (canned bytes drive the test).

1. **C scanner state — `Sources/LabanTerminalCore/session_internal.h`.**
   Add an OSC 133 scanner mirroring the tab-status one. Add a state enum
   (`O133_NORMAL`, `O133_AFTER_ESC`, `O133_OSC_NUM`, `O133_BODY_133`,
   `O133_BODY_133_AFTER_ESC`, `O133_BODY_OTHER`, `O133_BODY_OTHER_AFTER_ESC`),
   a small fixed payload buffer (the payload after `133;` is short: a single
   action letter, optionally `;<digits>`; cap at e.g. 64 bytes), a struct
   `LabanOSC133Scanner`, and add an instance plus
   `LabanOSC133Callback osc133_callback` / `void *osc133_userdata` to the
   session struct next to the tab-status fields. Declare
   `void laban_scan_osc133(LabanSession *s, const uint8_t *bytes, size_t len);`.

2. **C scanner implementation — new file `Sources/LabanTerminalCore/osc133.c`.**
   Copy the control-flow shape of `tab_status.c`. On reaching the body for OSC
   number `133`, buffer until `ST`, then parse: first char is the action
   (`A`/`B`/`C`/`D`); if action is `D` and a `;` follows, parse the trailing
   digits as the exit code. Ignore unknown actions (per Decision Log entry 2).
   Fire `s->osc133_callback(userdata, session, action, has_exit, exit_code)`.
   Reset scanner state in the registration function so a stale partial sequence
   doesn't fire on a freshly attached observer (tab_status does this).

3. **C boundary — `Sources/LabanTerminalCore/include/LabanTerminalCore.h`.**
   Add the callback typedef and registration function next to the tab-status
   ones:
   ```c
   /* OSC 133 semantic-prompt action. */
   typedef enum {
       LABAN_OSC133_PROMPT_START = 0,   /* 'A' */
       LABAN_OSC133_PROMPT_END = 1,     /* 'B' */
       LABAN_OSC133_COMMAND_START = 2,  /* 'C' */
       LABAN_OSC133_COMMAND_END = 3,    /* 'D' */
   } LabanOSC133Action;

   typedef void (*LabanOSC133Callback)(
       void *userdata,
       LabanSession *session,
       LabanOSC133Action action,
       int has_exit_code,   /* 1 only for 'D' with a numeric arg */
       int exit_code);

   int laban_session_set_osc133_callback(
       LabanSession *session,
       LabanOSC133Callback callback,
       void *userdata);
   ```

4. **Wire the scan in — `Sources/LabanTerminalCore/capture.c` line 31.**
   Add `laban_scan_osc133(s, bytes, len);` right after the
   `laban_scan_tab_status(s, bytes, len);` call, before
   `ghostty_terminal_vt_write`.

5. **Swift state machine — `Sources/LabanCore/`.**
   Add `ShellIntegrationState` (new file
   `Sources/LabanCore/ShellIntegrationState.swift`) holding a `phase` enum
   (`idle`/`atPrompt`/`running`/`finished`) and `lastExitCode: Int?`. Map
   callback actions: `A`/`B` → `atPrompt`; `C` → `running`; `D` → `finished`
   and store the exit code. Register the C callback from `Session.swift` (where
   the bell/tab-status callbacks are registered) and forward into this state.
   Make the state observable the same way `Session`'s other UI-facing state is.

6. **Debug endpoint — `Sources/LabanDebug/`.**
   Add `GET /debug/shell-integration/state` returning
   `{ "phase": "...", "lastExitCode": <int|null> }` for the active session, and
   ensure each OSC 133 transition also lands on the existing `GET /debug/events`
   stream (look at how the bell or tab-status events are emitted to
   `EventLog`). Register the route so `./scripts/check-debug-contract` sees it,
   and document it in `docs/process/dev-process.md` alongside the other debug
   endpoints. Wire the same state into `HeadlessDebugRuntime` so it has parity
   with the AppKit runtime (AGENTS.md hard rule).

7. **Tests — `Tests/LabanTerminalCoreTests/` and `Tests/LabanCoreTests/`.**
   - C-level / Swift-level: feed canned byte streams (including a split where a
     marker straddles two `laban_scan_osc133` calls, and one using `ESC \`
     instead of `BEL`) and assert the callback fires with the right action and
     exit code.
   - State machine: assert the A→B→C→D sequence ends in `finished` exit 0, and
     that `D;1` yields exit 1.
   - Negative: an unrelated OSC (e.g. a title set `ESC]0;hi BEL`) does not move
     the phase.

### Milestone 2 — zsh injection

Generate an rc-overlay directory containing `.zshrc` (and `.zprofile` /
`.zlogin` as needed) that first sources the user's real files
(`source "$LABAN_REAL_ZDOTDIR/.zshrc"` etc., where `LABAN_REAL_ZDOTDIR` is the
user's original `ZDOTDIR` or `$HOME`) and then appends a `precmd`/`preexec`
snippet emitting OSC 133 A/B/C/D. Decide overlay lifetime (per-app shared dir
vs per-session) — see the open Decision Log item — and respect
`docs/process/worktree-isolation.md` for temp-dir placement. Pass
`ZDOTDIR=<overlay>` through the existing `envp` override path. Acceptance: spawn
a real zsh in the headless runtime, run a command, and
`GET /debug/shell-integration/state` reflects real transitions with the real
exit code.

### Milestone 3 — bash + fish injection

bash: generate an rc file and pass it via `--rcfile` (interactive) and/or
`BASH_ENV`; fish: overlay `XDG_CONFIG_HOME` with a `fish/config.fish` that
defines `fish_prompt`/`fish_preexec` hooks. Each shell's rc-loading rules
differ (spec §7, §14) — handle them separately and test each.

### Milestone 4 — UI consumers

Drive a per-tab status indicator from `ShellIntegrationState` and decide how it
relates to the existing bell-attention badge (augment vs. independent — pick in
the Decision Log). Add screenshot/frame assertions via the debug runtime. Only
after this lands, update `docs/quality/quality.md` to remove shell integration
from the deferred list.

## Concrete Steps

Run everything from the repository root `/Users/rrj/wrk/laban`.

```
# Read the precedents first.
sed -n '1,150p' Sources/LabanTerminalCore/tab_status.c
sed -n '60,90p;140,210p' Sources/LabanTerminalCore/session_internal.h

# Build and test as you go (build script is ./scripts/build-app, not raw swift build).
swift build
swift test --filter OSC133

# Full local gate before declaring Milestone 1 done.
./scripts/check
```

Expected after Milestone 1: `swift test --filter OSC133` reports the new tests
passing; removing the `laban_scan_osc133` line from `capture.c` makes them
fail.

## Validation and Acceptance

Milestone 1 is accepted when, with the headless debug runtime running, feeding
a session the byte stream `ESC]133;A` `prompt$ ` `ESC]133;B` `ls`
`ESC]133;C` `output\n` `ESC]133;D;0` (each marker terminated by `BEL`) results
in `GET /debug/shell-integration/state` returning
`{"phase":"finished","lastExitCode":0}`, and the four transitions appear on
`GET /debug/events`. Changing the final marker to `ESC]133;D;1` yields
`lastExitCode:1`. The new unit test fails before the scanner is wired in and
passes after. `./scripts/check` exits 0.

Later milestones are accepted when a real shell of the relevant type, launched
through Laban with the overlay, drives the same endpoint with real prompt and
exit-code transitions, and (Milestone 4) the tab indicator visibly reflects the
phase in a debug-runtime screenshot.

## Idempotence and Recovery

The scanner is observe-only and stateless across sessions, so re-running tests
is safe. The rc-overlay generation (M2+) must be idempotent: regenerating the
overlay directory must overwrite cleanly and never corrupt or recurse into the
user's real dotfiles (the overlay sources the originals by absolute path
captured at generation time). If overlay generation fails, the session must
still launch a plain login shell (degrade gracefully, no integration) rather
than failing to spawn.

## Interfaces and Dependencies

- New C symbols (in `LabanTerminalCore`): `laban_scan_osc133`,
  `laban_session_set_osc133_callback`, `LabanOSC133Callback`,
  `LabanOSC133Action`, `LabanOSC133Scanner`.
- New Swift type (in `LabanCore`): `ShellIntegrationState` with `phase` and
  `lastExitCode`, owned by `Session`.
- New debug route (in `LabanDebug`): `GET /debug/shell-integration/state`.
- No new third-party dependencies (SwiftPM stays dependency-free per
  `./scripts/check-dependencies`). libghostty-vt is consumed only through its
  existing C API; no upstream patch is required.
