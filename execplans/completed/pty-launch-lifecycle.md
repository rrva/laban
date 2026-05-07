# Make PTY Launch And Reap Deterministic

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Shell startup should be reliable even when the app has multiple threads, and a
child process should see the configured terminal size before it runs shell
startup code. This change removes `forkpty`'s opaque child-side setup, creates
the PTY with the initial window size in the parent, uses a constrained fork
child only for controlling-terminal setup and `execve`, and makes child reaping
retry `waitpid` when signals interrupt it.

## Progress

- [x] Read `session.c` PTY creation, resize, destroy, and poll paths.
- [x] Read PTY-mode tests and the terminal-core PTY ownership ADR.
- [x] Add a regression showing a shell can read the requested initial PTY size at startup.
- [x] Replace the `forkpty` child branch with `openpty` plus a constrained fork
  child.
- [x] Build spawn argv/env in the parent while preserving Laban TERM/COLORTERM defaults and caller env overrides.
- [x] Prove pure `posix_spawn` is insufficient on Darwin for Laban's
  controlling-terminal requirements.
- [x] Use `setsid`, `TIOCSCTTY`, and stdio fd wiring in the constrained child
  branch so the child owns a controlling terminal.
- [x] Loop `waitpid` through `EINTR` in poll and destroy paths.
- [x] Add a regression covering spawn environment defaults and caller overrides.
- [x] Run focused terminal-core tests and the full package suite.
- [x] 2026-05-07 Reconcile the current worktree with this plan: `session.c`
  still contains a `forkpty` child branch even though the plan recorded the
  replacement as done. A direct `openpty` plus `posix_spawn` patch preserved
  startup geometry but failed the focused Ctrl-C/Ctrl-Z PTY tests because the
  spawned process did not own the PTY foreground process group. At that point,
  keep `forkpty` and treat a spawn-based replacement as requiring an explicit
  controlling-terminal helper design.
- [x] 2026-05-07 Replace `forkpty` with parent-side `openpty` plus a constrained
  fork child. A stricter `setsid` then `open(slave)` variant preserved Ctrl-C
  but made startup `stty size` report `0 0`; the accepted path keeps the
  already-sized slave fd and claims it with `TIOCSCTTY`.
- [x] 2026-05-07 Record the durable launch decision in
  `docs/adr/0002-pty-launch-uses-openpty-constrained-fork.md`.
- [x] 2026-05-07 Escalate destroy-time termination to the child process group
  so shell-launched descendants that ignore HUP/TERM cannot survive tab close
  or session teardown.

## Context and Orientation

`Sources/LabanTerminalCore/session.c` owns the PTY and child process lifecycle. Swift only sees an opaque `LabanSession*`; this boundary is required by `docs/adr/0001-libghostty-vt-owns-vt-parsing.md`. In earlier code, `forkpty` hid session and controlling-terminal setup inside libc and left Laban's child branch to do additional process setup before `execve`. That is hard to audit in a multi-threaded AppKit process.

`openpty` can create the PTY master/slave pair with a `winsize`, so the slave already has the correct rows, columns, and pixel size before the child process starts. A pure `posix_spawn` attempt with `POSIX_SPAWN_SETSID` did not satisfy Laban's acceptance tests: Ctrl-C and Ctrl-Z were not delivered through the PTY foreground process group. A second attempt that did `setsid` then reopened the slave path in the child preserved Ctrl-C but lost the initial window size (`stty size` reported `0 0`). The accepted design is documented in `docs/adr/0002-pty-launch-uses-openpty-constrained-fork.md`.

## Plan of Work

Add a PTY-mode test in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` that launches `/bin/sh -lc "stty size"`, starts with a non-default `LabanTerminalSize`, polls until the process exits, and asserts the visible grid contains the requested rows and columns.

In `Sources/LabanTerminalCore/session.c`, add helper functions near the top of the file for environment-name comparison, spawn environment assembly, spawn cleanup, and EINTR-safe `waitpid`. Build the default login-shell argv in parent memory when `config->argv` is nil. Build an environment array that removes inherited `NO_COLOR`, installs `TERM=xterm-256color` and `COLORTERM=truecolor` unless the caller overrides them, and appends caller-provided `envp` entries.

Replace `forkpty(&pty_fd, NULL, NULL, NULL)` with `openpty(&pty_fd, &slave_fd, NULL, NULL, &ws)`. Mark the master and parent slave fds close-on-exec before forking. In the child, restore terminal-relevant signal defaults, close the master fd, call `setsid`, claim the already-sized slave fd as the controlling terminal with `TIOCSCTTY`, duplicate the slave fd to stdin/stdout/stderr, change to the launch cwd when configured, and call `execve`. In the parent, close the slave fd, set the master fd nonblocking, store the child pid, and return.

Replace direct `waitpid` calls in `laban_session_destroy` and `laban_session_poll` with an EINTR-looping helper.

During destroy, close the PTY master first so the terminal session receives the
normal hangup. If the direct child does not reap promptly, send SIGTERM and then
SIGKILL to the child process group. The fork child calls `setsid`, so its pid is
the process group id; group escalation reaches foreground and background
processes launched by the shell.

## Validation and Acceptance

Run from the repository root:

```sh
rtk swift test --filter LabanSessionTests/testPTYInitialSizeIsVisibleAtShellStartup
rtk swift test --filter LabanSessionTests/testPTYSpawnEnvironmentAppliesDefaultsAndOverrides
rtk swift test --filter LabanSessionTests/testDestroyTerminatesProcessGroupChildrenThatIgnoreHangup
rtk swift test --filter LabanSessionTests
rtk swift test
```

Acceptance: the new initial-size test passes, existing real-shell PTY smoke tests still pass, and the full suite remains green.

Validated on 2026-05-05:

```sh
rtk swift test --filter LabanSessionTests/testPTYInitialSizeIsVisibleAtShellStartup
rtk swift test --filter LabanSessionTests
rtk swift test
```

Revalidated on 2026-05-07 after correcting this plan's stale completion state:

```sh
rtk swift test --filter LabanSessionTests/testControlCInterruptsForegroundPTYProcess
rtk swift test --filter LabanSessionTests
rtk swift test --filter LabanTerminalCoreTests
```

`rtk swift test --filter LabanSessionTests` passed with 48 tests and 0
failures. `rtk swift test --filter LabanTerminalCoreTests` passed with 72
tests, 1 skipped, and 0 failures. An initial package-wide `rtk swift test` run
failed only in `MetalRendererSmokeTests`, where seven Metal tests reported
`MetalRenderer.init returned nil`; no terminal-core, core, debug, or app tests
failed in that run. After fixing renderer resource-bundle discovery,
package-wide `rtk swift test` passed with 349 tests, 2 skipped, and 0 failures.

Validated after the final `openpty` plus constrained fork replacement on
2026-05-07:

```sh
rtk swift test --filter LabanSessionTests/testControlCInterruptsForegroundPTYProcess
rtk swift test --filter LabanSessionTests
rtk swift test --filter LabanTerminalCoreTests
rtk swift test
rtk scripts/smoke-runtime
```

`rtk swift test --filter LabanSessionTests` passed with 48 tests and 0
failures. `rtk swift test --filter LabanTerminalCoreTests` passed with 72
tests, 1 skipped, and 0 failures. Package-wide `rtk swift test` passed with
349 tests, 2 skipped, and 0 failures. `rtk scripts/smoke-runtime` passed after
building the app bundle and running the headless smoke path.

Revalidated process-group teardown on 2026-05-07:

```sh
rtk swift test --filter LabanSessionTests/testDestroyTerminatesProcessGroupChildrenThatIgnoreHangup
```

The regression launches a shell that starts `sleep`, makes both shell and child
ignore HUP/TERM, destroys the session, and verifies the child process is gone.
The focused test passed.
