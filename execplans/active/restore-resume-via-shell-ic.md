# Restore agent resume via `$SHELL -l -i -c`, not typed-into-PTY

## Purpose

When Laban restarts and restores a tab that had a running coding agent
(`claude` / `codex`), it currently re-launches the user's login shell and then
*types* `clear && claude --resume <id>\n` into that live shell, relying on the
shell's echo to put the command on screen. That typed-injection is fragile: it
depends on the shell being ready to read input, it shows a command echo, and it
needs a `clear` hack to wipe the echoed line off row 0.

This change makes the restored tab launch its shell **with the resume command as
the shell's own argument**:

```
$SHELL -l -i -c '<resume-command>; exec $SHELL -l -i'
```

`-l -i` runs a login+interactive shell (sources the user's rc files so aliases / PATH /
functions are present); `-c '<cmd>'` runs the resume command directly (no typing,
no echo race); the trailing `; exec $SHELL -l -i` replaces the process with a fresh
interactive shell once the agent exits, so the user is left at a normal prompt —
matching today's post-agent behavior. `$SHELL` is whatever the user's login
shell is (`zsh`, `bash`, `fish`, …); all three accept `-l -i -c '...'`, support `;`
statement separators, and have `command`/`exec` builtins, so the same shape works
for each.

After this change, restoring a tab whose agent was running at quit drops you
straight into the resumed agent in a fully-initialized interactive shell, with no
visible typed command and no `clear` hack — and when the agent exits you fall back
to a live shell prompt.

Scope: this reworks only the **`.executeNow`** restore case (agent was running at
quit). The **`.prefillPrompt`** case (agent had been exited; command sits at the
prompt for the user to press ENTER) is unchanged — `-c` always runs immediately,
so it cannot "sit at a prompt" and stays typed-into-PTY.

## Definitions

- **Deferred spawn**: a `Session` created with its VT parser ready but no child
  process yet (`Session.makeDeferred`). The restore path uses this, then calls
  `startSpawn(...)` to fork+exec the shell. See `Sources/LabanCore/Session.swift`.
- **Restore launch instruction**: `RestoreLaunchInstruction` in
  `Sources/LabanCore/Persistence/RestoreLaunchPlanner.swift` — `.executeNow`,
  `.prefillPrompt`, or `.noPrefill`. The planner decides which from the persisted
  `agent` metadata.
- **Injection**: the new `RestoreShellInjection` value (this plan) that turns a
  resume command string into the `[shellPath, "-l", "-i", "-c", payload]` argv used to
  exec the shell.

## Files to edit

| File | Change |
| --- | --- |
| `Sources/LabanTerminalCore/session_lifecycle.c` | Thread an optional `exe`/`argv` override through `laban_session_spawn_now_`; add `laban_session_start_spawn_argv`. Stale comment at the spawn-helper says it is shared with the non-deferred create path — it is not (only `laban_session_start_spawn` calls it); fix the comment. |
| `Sources/LabanTerminalCore/include/LabanTerminalCore.h` | Declare `laban_session_start_spawn_argv`. |
| `Sources/LabanTerminalCore/session_internal.h` | Update `laban_session_spawn_now_` signature. |
| `Sources/LabanCore/Persistence/RestoreShellInjection.swift` (new) | `LoginShell.resolvePath()` (mirror C: `$SHELL` → passwd → `/bin/sh`) + `RestoreShellInjection(command:)` building argv `[shell, "-l", "-i", "-c", "<cmd>; exec <quoted-shell> -l -i"]` + `RestoreLaunchInstruction.spawnInjection`. |
| `Sources/LabanCore/Session.swift` | `startSpawn(overrideCwd:injection:)`; when `injection != nil`, call `laban_session_start_spawn_argv`. |
| `Sources/LabanCore/Persistence/WorkspaceState.swift` | Add `agent: AgentInfo?` and `shellPid: Int?` to `RestoredSessionSpec` (raw persisted data the factory needs to run the planner). |
| `Sources/LabanCore/AppModel.swift` | Populate the two new `RestoredSessionSpec` fields from `persistedTab`. AppModel stays ignorant of injection. |
| `Sources/LabanApp/MainWindowController.swift` | Deferred factory runs the planner from `spec.agent`/`spec.shellPid` and spawns with `injection` on `.executeNow`. `applyRestoreLaunchPlans` drops its `.executeNow` write (now handled at spawn); keeps `.prefillPrompt`. |
| `Sources/LabanDebug/HeadlessDebugRuntime.swift` | Same factory change for parity (real-shell mode). |
| `Tests/LabanCoreTests/RestoreShellInjectionTests.swift` (new) | Assert argv/payload construction for representative commands and shells. |
| `Tests/LabanAppTests/WorkspaceRestoreEndToEndTests.swift` | Mirror production factory; convert the executeNow test to real-shell + `echo MARKER` drop-to-interactive assertion. |

The planner already needs a `TabState`; the factory will build a minimal one
from `spec.agent`/`spec.shellPid`/`spec.cwd`, or call a planner overload taking
those fields. The persisted resume-command string itself (and its "no destructive
flags" filtering) is unchanged and stays covered by `RestorePlannerTests`.

## Decision Log

- **`$SHELL -l -i -c '<cmd>; exec $SHELL -l -i'`** (drop to interactive prompt after the
  agent exits) chosen by the user over "let the shell exit" and "drop to login
  shell". Matches today's post-agent behavior.
- **No `clear &&` prefix.** The old prefix existed only to wipe the *echoed* typed
  command off row 0; argv injection produces no echo, so the justification does
  not transfer. Stay faithful to the approved invocation.
- **Login shell (`-l -i -c`), not bare `-i -c`.** A normal Laban tab spawns its
  shell as a login shell (argv[0] = `-zsh`). On macOS, PATH is commonly set in
  login-only files (`.zprofile`), so a non-login injected shell could fail to find
  `claude`/`codex` even though the old typed-into-the-login-shell path found them.
  Verified: `/bin/zsh -i -c 'command claude'` misses a fake `claude` exported only
  from `.zprofile`; `/bin/zsh -l -i -c …` finds it. The `exec` tail is `-l -i` too.
- **Persisted fields on the spec, not a resolver closure on AppModel.** Keeps
  AppModel ignorant of restore policy; the factory (app shell, where the activity
  checker already lives) runs the planner. Covers `persistenceRelaunch` too since
  it goes through `replaceTabs` → spec building.
- **Only `.executeNow` moves to argv injection;** `.prefillPrompt` stays
  typed-into-PTY because `-c` cannot sit at a prompt.

## Progress

- [x] C: `laban_session_start_spawn_argv` + `spawn_now_` exe/argv override; stale comment fixed
- [x] Swift: `RestoreShellInjection` + `LoginShell` + `Session.startSpawn(injection:)`
- [x] `RestoredSessionSpec` carries `agent`/`shellPid`; `AppModel` populates them
- [x] Production + headless factories run planner and inject on `.executeNow`; `applyRestoreLaunchPlans` keeps only `.prefillPrompt`
- [x] Unit tests for injection argv; E2E executeNow test reworked to real-shell drop-to-interactive
- [x] `scripts/check` green

## Validation and Acceptance

- `swift test --filter RestoreShellInjectionTests` proves argv is
  `[shell, "-l", "-i", "-c", "command claude --resume abc; exec '<shell>' -l -i"]`.
- `swift test --filter RestorePlannerTests` still green (planner contract
  unchanged).
- `swift test --filter WorkspaceRestoreEndToEndTests` green; the reworked
  executeNow test (real `/bin/zsh`, skipped if absent) restores an agent tab,
  writes `echo MARKER\n`, and observes `MARKER` — proving the `exec $SHELL -l -i`
  tail leaves a live interactive shell after the (uninstalled-`claude`) resume
  attempt.
- `scripts/check` passes end-to-end (lint, build, tests, smoke, e2e).
- Manual: build the app, run an agent in a tab, quit while it is running,
  relaunch — the tab comes back running the resumed agent with no visible typed
  command; exiting the agent leaves an interactive prompt.
