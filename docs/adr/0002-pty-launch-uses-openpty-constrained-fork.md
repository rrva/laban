# 2. PTY Launch Uses openpty With A Constrained Fork Child

Date: 2026-05-07

## Status

Accepted

## Context

`LabanTerminalCore` owns the PTY and child process lifecycle. The first
implementation used `forkpty`, which hides the PTY setup inside libc and then
left Laban's child branch to restore signal defaults, change directory, and
`execve` the shell.

That shape is difficult to review in a multi-threaded AppKit process. After a
fork in a multi-threaded process, the child branch must stay as small as
possible before `execve`; library code that may take locks is risky. At the
same time, terminal correctness depends on real PTY job-control behavior:

- the child must see the requested rows and columns before shell startup;
- the child process group must own the terminal foreground process group;
- terminal line discipline must deliver generated `SIGINT` and `SIGTSTP`;
- the parent must retain sole ownership of the PTY master fd.

A pure `posix_spawn` replacement was tested and rejected. Darwin's spawn API
can express fd actions, signal defaults, and `POSIX_SPAWN_SETSID`, but it
cannot express the controlling-terminal setup Laban needs while preserving both
initial `TIOCSWINSZ` geometry and terminal-generated signal delivery. The
regression tests that caught this were Ctrl-C, Ctrl-Z, and startup `stty size`.

## Decision

`LabanTerminalCore` opens the PTY pair with `openpty` in the parent, with the
initial window size applied before the child can run. It then forks a child that
does only the PTY/session setup needed before `execve`:

1. restore terminal-relevant signal dispositions to default;
2. close the inherited PTY master fd;
3. call `setsid`;
4. claim the already-sized slave fd as the controlling terminal;
5. duplicate the slave to stdin, stdout, and stderr;
6. change to the launch cwd when one was configured;
7. call `execve`.

The parent closes the slave fd, marks the master close-on-exec and nonblocking,
stores the child pid, and remains the only owner of the PTY master.

When tearing down a live session, Laban first closes the PTY master to deliver
the normal terminal hangup semantics, then escalates termination to the child's
process group, not only the shell pid. The child is a session leader whose pid
is also the process group id, so group termination catches foreground and
background processes launched by the shell that ignore SIGHUP.

## Consequences

- Laban no longer depends on `forkpty`'s opaque child-side behavior.
- Initial PTY geometry is applied in the parent before shell startup.
- Existing terminal line-discipline behavior is preserved: Ctrl-C and Ctrl-Z
  still reach the foreground process through the PTY, not through app-side
  signal injection.
- A pure `posix_spawn` shell launch remains rejected unless Darwin exposes a
  way to order controlling-terminal setup correctly or Laban introduces a
  dedicated, audited helper executable.
- The child branch is intentionally small. Do not add allocation, logging,
  Swift calls, Objective-C, libghostty calls, or other product behavior there.
- Teardown cannot leave shell-launched descendants behind when they ignore
  SIGHUP or SIGTERM; escalation targets the PTY process group and then reaps
  the direct child.

## Applies To New Code

Before changing PTY launch, answer:

1. Do `testPTYInitialSizeIsVisibleAtShellStartup`,
   `testControlCInterruptsForegroundPTYProcess`, and
   `testControlZSendsSuspendCharacterThroughForegroundPTY` still pass?
2. Does the parent still own the PTY master fd and close the slave fd?
3. Does the child branch still go directly from PTY/session setup to `execve`?
4. Are argv and environment assembled before the fork?
5. If proposing `posix_spawn`, how does the design prove controlling-terminal
   ownership, initial window size, and line-discipline signal delivery?
6. Does `testDestroyTerminatesProcessGroupChildrenThatIgnoreHangup` still
   prove teardown reaches shell-launched child processes?

If any answer is unclear, keep the existing launch path and add a focused
regression before changing it.
