# Make PTY Launch And Reap Deterministic

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Shell startup should be reliable even when the app has multiple threads, and a child process should see the configured terminal size before it runs shell startup code. This change replaces the unsafe `forkpty` child branch with parent-side `posix_spawn` setup, creates the PTY with the initial window size, and makes child reaping retry `waitpid` when signals interrupt it.

## Progress

- [x] Read `session.c` PTY creation, resize, destroy, and poll paths.
- [x] Read PTY-mode tests and the terminal-core PTY ownership ADR.
- [x] Add a regression showing a shell can read the requested initial PTY size at startup.
- [x] Replace the `forkpty` child branch with `openpty` plus `posix_spawn`.
- [x] Build spawn argv/env in the parent while preserving Laban TERM/COLORTERM defaults and caller env overrides.
- [x] Use `POSIX_SPAWN_SETSID`, file actions, and the PTY slave path so the child owns a controlling terminal.
- [x] Loop `waitpid` through `EINTR` in poll and destroy paths.
- [x] Add a regression covering spawn environment defaults and caller overrides.
- [x] Run focused terminal-core tests and the full package suite.

## Context and Orientation

`Sources/LabanTerminalCore/session.c` owns the PTY and child process lifecycle. Swift only sees an opaque `LabanSession*`; this boundary is required by `docs/adr/0001-libghostty-vt-owns-vt-parsing.md`. In the current code, `forkpty` creates a child and then the child calls functions such as `setenv`, `putenv`, `snprintf`, `strrchr`, `signal`, and `chdir` before `execv`. After a multi-threaded fork, only async-signal-safe functions are safe until `exec`; those calls can deadlock if another thread held a libc lock at fork time.

`openpty` can create the PTY master/slave pair with a `winsize`, so the slave already has the correct rows, columns, and pixel size before the child process opens it. `posix_spawn` lets the parent describe the child setup through attributes and file actions, avoiding a manual child branch. `POSIX_SPAWN_SETSID` makes the child a new session leader; opening the slave device as fd 0 in that new session gives the shell a controlling terminal, then fd 0 is duplicated to stdout and stderr.

## Plan of Work

Add a PTY-mode test in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` that launches `/bin/sh -lc "stty size"`, starts with a non-default `LabanTerminalSize`, polls until the process exits, and asserts the visible grid contains the requested rows and columns.

In `Sources/LabanTerminalCore/session.c`, add helper functions near the top of the file for environment-name comparison, spawn environment assembly, spawn cleanup, and EINTR-safe `waitpid`. Build the default login-shell argv in parent memory when `config->argv` is nil. Build an environment array that removes inherited `NO_COLOR`, installs `TERM=xterm-256color` and `COLORTERM=truecolor` unless the caller overrides them, and appends caller-provided `envp` entries.

Replace `forkpty(&pty_fd, NULL, NULL, NULL)` with `openpty(&pty_fd, &slave_fd, NULL, NULL, &ws)`. Mark the master and parent slave fds close-on-exec. Use `ttyname_r` to capture the slave path. Configure `posix_spawn_file_actions_t` to `chdir` to the launch cwd, open the slave path on stdin, duplicate stdin to stdout/stderr, and close inherited PTY fds. Configure `posix_spawnattr_t` with `POSIX_SPAWN_SETSID` and `POSIX_SPAWN_SETSIGDEF` for SIGPIPE and SIGINT. On spawn success, close the parent slave fd, set the master fd nonblocking, store the child pid, and return.

Replace direct `waitpid` calls in `laban_session_destroy` and `laban_session_poll` with an EINTR-looping helper.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter LabanSessionTests/testPTYInitialSizeIsVisibleAtShellStartup
rtk swift test --filter LabanSessionTests/testPTYSpawnEnvironmentAppliesDefaultsAndOverrides
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
