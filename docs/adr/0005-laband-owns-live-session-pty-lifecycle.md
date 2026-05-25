# 5. laband Owns Live Session PTY Lifecycle

Date: 2026-05-25

## Status

Accepted

## Context

ADR 0001 selected `libghostty-vt` as Laban's terminal parser and put PTY
ownership inside `LabanTerminalCore`. ADR 0002 then fixed the launch mechanism:
the parent side opens the PTY with `openpty`, applies the initial size before
the child can run, forks a constrained child branch, gives the child a
controlling terminal, and keeps the PTY master fd solely in the parent.

That architecture shipped the MVP, but it has one product-level limit: the
visible app process is also the process that owns the live shell's PTY master,
child process group, parser state, scrollback, and terminal metadata. If the
app quits, crashes, or is replaced during an upgrade, live terminal work dies
with it. Workspace restore can semantically relaunch Claude Code or Codex
sessions, but that is not the same as preserving a running PTY.

The `laband` ExecPlan changes the owner of live terminal sessions. A separate
per-user daemon process must outlive the visible app and become the process
that owns the `LabanTerminalCore` session objects. The app and headless harness
then attach as clients that render and control sessions through a versioned
local protocol.

This ADR reverses only the process boundary from ADR 0001. It does not reverse
ADR 0002's PTY launch invariants and does not move raw libghostty handles into
Swift UI code.

## Decision

`laband` owns live terminal session lifecycle. A live interactive PTY session is
created, polled, resized, written to, snapshotted, journaled, and terminated by
the `laband` process. The visible app, headless debug runtime, tests, and future
viewers are clients of that daemon for any behavior that claims live PTY
survival across app detach, app restart, app replacement, or multi-attach.

`laband` runs `LabanTerminalCore` in its own process. In that process,
`LabanTerminalCore` still owns raw libghostty-vt handles, the PTY master fd,
the child pid/process group, input encoders, parser state, scrollback, title,
terminal modes, and snapshots. Swift/AppKit does not hold PTY file descriptors
or libghostty pointers. AppKit remains responsible for native input
normalization, menus, windows, tabs, renderer selection, glyph atlases, Metal
or software drawing, and visible UI policy.

ADR 0002 remains binding inside `laband`:

1. the daemon parent opens the PTY pair with `openpty`;
2. the initial size is applied before child startup;
3. the child branch stays constrained and proceeds directly to `execve`;
4. the daemon parent remains the sole owner of the PTY master fd;
5. teardown closes the PTY master and escalates to the child process group.

The migration uses a versioned local protocol. Development and tests use
run-id-scoped Unix sockets and artifact/temp directories. Product mode uses a
per-user LaunchAgent and an XPC listener when that milestone ships. Local
rendering remains client-side: `laband` publishes semantic terminal state, and
clients render it with their own renderer resources.

Close Tab remains destructive and terminates the daemon-owned session. App
quit, window close, app crash, and app upgrade detach the client and leave live
daemon sessions running when possible.

## Consequences

- `LabanTerminalCore` is still the only layer that owns raw terminal parser
  state, PTY fds, and child process groups. The owning process changes from the
  visible app to `laband`.
- Existing in-process session code remains valid for migration adapters,
  parser/unit tests, and fallback paths, but it no longer represents the final
  product owner for live session lifecycle.
- Headless/debug tests that claim attach, detach, restore, daemon ownership, or
  PTY survival must use a real `laband` process, not an in-process fake.
- The app must tolerate an older compatible daemon during upgrade. It must not
  kill live sessions merely to replace helper code.
- Development sockets, journals, pid files, and temp artifacts must live under
  explicit run-id paths such as `.tmp/<run-id>/` and
  `.artifacts/runs/<run-id>/`.
- Semantic Claude Code and Codex resume remains necessary. If `laband` or the
  OS loses the live PTY, Laban falls back to the existing restore picker rather
  than pretending a relaunched command is the same live process.

## Applies To New Code

Before changing live session lifecycle, answer:

1. Does code that claims live attach, detach, restart survival, or upgrade
   survival use a real `laband` process?
2. Does `LabanTerminalCore` still hide raw libghostty handles and PTY fds from
   `LabanApp`, `LabanDebug`, and renderer code?
3. Are ADR 0002's `openpty`, constrained fork child, initial size, process
   group, and teardown invariants preserved inside the daemon process?
4. Does Close Tab still terminate the session, while app quit/window close only
   detaches the client?
5. Are dev/test sockets, journals, pid files, and artifacts run-id-scoped
   instead of global fixed paths?
6. If the daemon is gone, does the Claude/Codex path fall back to semantic
   resume with user choice rather than auto-running hidden commands?

If any answer is "no" or "unclear", keep the existing behavior and add a
focused regression before changing live session ownership.
