# labpty fd-handoff self-upgrade (ADR 0006 Phase 3)

## Purpose and intent

Today, shipping a new `labpty` binary means killing every background terminal
session the user has open. `labpty` is the per-user daemon that owns the
pseudo-terminal master file descriptors ("PTY masters" — the kernel handle
through which the daemon reads a shell's output and writes the user's
keystrokes). When the daemon process dies, the kernel sends `SIGHUP` to each
child shell and the sessions are gone. There is no way to update `labpty`
without that loss, because `labpty` has no self-upgrade path (verified: no
`exec`/`LISTEN_FDS`/handoff code exists in `Sources/Labpty/`).

After this work, the user can install a new build of Laban and the running
`labpty` daemon will **replace its own binary in place without dropping a
single session**: the shells keep running, scrollback is intact, and the only
visible effect is a sub-second pause on the control channel while clients
reconnect (a path that already exists and is already tested — see ADR 0007's
"control-channel failure is recoverable" contract).

You can see it working with a single command after implementation:

```
swift test --filter LabptyDaemonTests/testSelfUpgradePreservesSessions
```

The test starts a daemon, opens a shell running an echo loop, triggers a
self-upgrade to a fresh `labpty` image, then asserts the child pid is
unchanged and still alive, that output written *before* the upgrade is still
readable from the byte ring, and that a write *after* the upgrade still echoes
back. Before this change that test cannot exist; after it, it passes.

This plan implements ADR 0006's "Phase 3 — labpty fd-handoff for
self-upgrades." It corrects one load-bearing detail of that ADR's sketch (see
Decision Log: the ADR's "fork … then exits" model is wrong for labpty).

## Orientation: the pieces and where they live

A novice should read these before starting. All paths are repository-relative.

- **`Sources/Labpty/main.c`** — the daemon. Single-threaded `poll()` event
  loop (`event_loop`, ~line 855). Holds a `labpty_daemon_t` with a fixed array
  of client connection slots (`clients[LABPTY_MAX_CLIENTS]`, 8) and a
  `labpty_registry_t registry`. Accepts client connections on a UNIX domain
  socket (`add_client`), dispatches framed RPCs (`dispatch_frame`, ~line 660),
  and drains each session's PTY master into that session's byte ring
  (`drain_session`, ~line 769). Signals: `SIGTERM`/`SIGINT` request shutdown,
  `SIGPIPE` ignored (`install_signal_handlers`, ~line 88).
- **`Sources/Labpty/labpty_registry.{h,c}`** — the session catalog. Each
  `labpty_session_t` is one shell session: `handle` (monotonic id),
  `child_pid`, `master_fd`, `slave_inspect_fd` (a passive read-only slave fd
  used for the ADR 0008 write-backpressure preflight), `rows`/`cols`,
  `alive`, the teardown fields `close_pending`/`sigkill_sent`/
  `terminate_deadline_ns`, `canonical_pending_estimate`, `logical_id`,
  `attached_clients` (the per-session connected-client bitmask added in ADR
  0010), and `ring` (the byte-ring writer). The registry holds
  `sessions[LABPTY_MAX_SESSIONS]` (64) and a `next_handle` counter. Child
  exit is detected **only** by `waitpid(child_pid, …, WNOHANG)`
  (`labpty_registry.c:58,63,67,335`). This single fact forces the whole
  design (see Decision Log).
- **`Sources/Labpty/labpty_byte_ring.{h,c}`** — the per-session shared-memory
  ring buffer. A file under the daemon's `--shm-dir`, `mmap`-ed, into which
  the daemon writes raw PTY output and from which **the app reads on its own
  independent file descriptor**. The ring is created with
  `O_CREAT | O_EXCL | O_CLOEXEC` (`labpty_byte_ring.c:18`). Its header records
  the layout (offsets, capacities) and live counters (bytes-written-total,
  wrap count, producer-heartbeat). Because the app's reader fd is independent
  of the daemon, **output flow is uninterrupted by a daemon swap** as long as
  the same ring file keeps being written.
- **`Sources/Labpty/include/labpty_internal.h`** — limits and the op/error
  enums. `LABPTY_MAX_SESSIONS = 64`, `LABPTY_MAX_CLIENTS = 8`. Ops are
  `LABPTY_OP_*` (hello=0x0001 … ping=0x0008, attach=0x0009, detach=0x000A).
- **`Sources/LabanTerminalCore/session_lifecycle.c`** — `laban_pty_open`, which
  `openpty`s the master and `fork`s the child (ADR 0002). It sets
  `FD_CLOEXEC` on the master (`set_cloexec(pty_fd)` at lines 226/507/639).
  **This is why a naive exec would kill sessions: the master would close on
  exec.** The handoff must clear `FD_CLOEXEC` first.
- **`Sources/LabanApp/MainWindowController.swift`** — the app side. The app
  connects to an existing daemon at the socket path and reuses it if `hello`
  succeeds (~line 512); only if none is running does it spawn one from
  `labptyExecutableURL()` (the app bundle's `labpty`, falling back to
  `.build/debug/labpty`). The app is the natural place to *detect* that the
  running daemon is older than the bundled binary and *trigger* the upgrade.
- **`Sources/LabanCore/PTYLabClient.swift`** — the Swift control client. One
  long-lived socket per app. `hello()` negotiates protocol version and
  capabilities. On a control-channel error it closes the connection, clears
  caches, and reconnects on the next RPC (ADR 0007). This reconnect path is
  what makes a brief control-channel gap during handoff invisible to the user.
- **`specs/labpty/`** — TLA+ models run by `scripts/check-specs`. Relevant:
  `LabptyStartup.tla` (who owns the socket path; `AtMostOneServing`),
  `LabptyLifecycle.tla` (session-slot/reap state machine),
  `LabptyControlChannel.tla`, `LabptyAttachment.tla` (the ADR 0010 counter).
- **`docs/adr/0006-three-tier-session-architecture.md`** — the architecture;
  its upgrade matrix is the contract this closes ("labpty code change without
  fd-handoff → session dies" becomes "→ survives"). **`docs/adr/0007`** freezes
  the Phase 1 wire contract (additive-only). **`docs/adr/0010`** is the
  connected-client counter, which interacts with handoff (see below).

### Terms defined in plain language

- **exec-in-place / re-exec**: the daemon calls `execve()` on the new `labpty`
  binary *without forking*. "In-place" means *no fork / same process* — **not**
  the same file: `execve` takes an arbitrary path, so the target is the new,
  upgraded binary. `execve` replaces the current process's program image with
  that new binary but keeps the **same process id (pid)** and all open file
  descriptors that do not have the close-on-exec flag. Because the pid is
  unchanged, the process remains the parent of the shell children and can still
  `waitpid` them; because the master fds stay open, the kernel never `SIGHUP`s
  the children. The new binary's code then runs its `--adopt` path and resumes
  the inherited fds. (This is the same self-upgrade mechanism as systemd's
  `systemctl daemon-reexec`.) The state file is therefore a **cross-version
  contract**: the old binary writes it, the new binary reads it, so its format
  is versioned and defensively parsed exactly like the ADR 0007 wire protocol —
  a newer daemon must read state written by the older daemon it replaces.
- **FD_CLOEXEC ("close on exec")**: a per-fd flag; if set, the kernel closes
  that fd during `execve`. Masters have it set today; the handoff clears it on
  exactly the fds that must survive.
- **catalog / state file**: a small file the daemon writes just before exec,
  recording everything about each live session that is *not* recoverable from
  the kernel or the ring file alone (handles, pids, rows/cols, teardown
  deadlines, the integer fd number of each master, which fd is the listener,
  `next_handle`, the shm dir, the socket identity). The successor reads it to
  rebuild its in-memory registry.
- **adopt mode**: the successor `labpty` is launched (by the predecessor's
  exec) with a flag telling it "do not bind a fresh socket or open new PTYs;
  instead read the state file and resume the inherited fds."

## Design

### The one decision everything hangs on: exec-in-place, not fork+exec

The daemon detects shell exit solely via `waitpid` on `child_pid`. `waitpid`
only works for the calling process's own children. If the handoff `fork`ed a
helper that `exec`ed the new binary and the old daemon then exited (ADR 0006's
literal sketch), the shells would reparent to `launchd` and the new daemon —
a **different pid** — would get `ECHILD` forever: it could never reap zombies
nor finish the `close_pending` → `SIGKILL` escalation. macOS has no
subreaper mechanism to transfer this. **Therefore the handoff must be
exec-in-place: the same process `execve`s the new binary, keeping its pid,
its parent-child relationships, and its open fds.** This also eliminates the
two-process "who owns the socket" race that fork+exec would introduce.

A pleasant consequence: because it is the same process, open fds keep their
**same integer numbers** across `execve`. The state file can simply record
`master_fd = 7` and the successor finds fd 7 still open and pointing at the
same PTY master. No `SCM_RIGHTS`, no dup-to-known-number dance.

### The cost of exec-in-place, and the mitigation

`execve` is a one-way door: once it lands, the old image is gone. A broken
successor (crashes on adopt, mis-parses the catalog) would kill every
session — the exact outcome the feature exists to prevent. The mitigation is
a **dry-run-adopt gate**: immediately before the real exec, the daemon
`fork`s a short-lived child that runs the new binary as
`labpty --dry-run-adopt <statefile-copy>`. That mode parses a *copy* of the
state file, opens each ring read-only by path and validates its header, checks
each recorded master fd is a live PTY — then exits 0 on success or non-zero on
any problem. The daemon performs the real exec-in-place **only if the dry-run
child exits 0**; otherwise it logs, discards the upgrade, and keeps serving.
This exercises the actual adopt code against the actual state before crossing
the one-way door. (The dry-run child is forked and reaped normally; it owns no
sessions, so reparenting concerns do not apply to it.)

### Handoff sequence (exec-in-place)

The trigger sets `daemon->pending_upgrade_path` and the event loop performs
the handoff at a **clean point** — after finishing the current poll iteration,
with no half-staged client frame and no partial ring write — so there is no
torn ring write and the kernel PTY buffers drain cleanly on the successor's
first poll. Steps:

1. **Validate the new binary path.** Even on a 0600 per-user socket, the
   upgrade trigger is an arbitrary-`execve` primitive. Require the path to be
   owned by the same uid and within an allowed location (the app bundle dir or
   the configured install dir). Reject otherwise.
2. **Run the dry-run-adopt gate** (above). Abort the upgrade if it fails.
3. **Write the state file** (`<shm-dir>/labpty-handoff.state`, mode 0600):
   for each `used` session — `handle`, `child_pid`, `master_fd` (integer),
   `rows`, `cols`, `alive`, `close_pending`, `sigkill_sent`,
   `terminate_deadline_ns`, `canonical_pending_estimate`, `logical_id`,
   `ring_path`; plus `next_handle`, `shm_dir`, the listener fd number, and the
   bound socket dev/ino identity. Versioned with a magic + ABI byte. Write to
   a temp name and `rename()` into place so a crash mid-write never leaves a
   half file.
4. **Clear `FD_CLOEXEC`** on every live `master_fd` and on the listen socket
   fd. Leave it set on everything else: client connection fds, ring fds,
   `slave_inspect_fd` — these are meant to close (clients reconnect; rings and
   inspect fds are re-derived by the successor).
5. **`execve`** the validated new binary as `labpty --adopt <statefile>
   --socket <path> --shm-dir <dir>`. Same pid; masters + listener survive by
   number.

The successor in `--adopt` mode:

1. Parses the state file (defensively; any inconsistency → exit non-zero, which
   in the dry run aborts the upgrade and in the real run is a last-resort
   failure the acceptance tests must make impossible).
2. Rebuilds the registry: for each session, adopt the inherited `master_fd`
   by number, set it non-blocking, re-open `slave_inspect_fd` via
   `ptsname(master_fd)` (best-effort, exactly as `labpty_registry_open` does;
   if it fails the write path degrades per ADR 0008), and **re-attach the byte
   ring by path** using a new `labpty_byte_ring_attach(path, …)` that opens an
   *existing* ring (`O_RDWR`, no `O_CREAT|O_EXCL`) and re-derives the writer's
   offsets from the ring header rather than reinitialising it.
3. Restores `next_handle`, `terminate_deadline_ns` (see below), and the other
   scalar fields. **Resets `attached_clients` to 0 for every session** — all
   control connections dropped across the exec; clients reconnect and
   re-attach via the ADR 0010 attach path, so the connected-client count
   re-derives itself within the reconnect window.
4. Resumes ownership of the inherited listen socket fd (does **not** rebind),
   unlinks the state file once the registry is rebuilt, and enters the normal
   event loop. Existing children are still its children (same pid) so
   `waitpid` and `close_pending` escalation continue uninterrupted.

`terminate_deadline_ns` uses `CLOCK_MONOTONIC`, which is per-boot and survives
`execve` on the same machine, so a session mid-terminate keeps its original
SIGKILL deadline and the escalation continues correctly after handoff. This is
non-obvious and load-bearing — serialize it verbatim, do not recompute it.

### The trigger and version detection

`hello` already returns version/capabilities. Add a build identity (the
`labpty` build commit, mirroring `BuildInfo.commit`) to the hello response.
Add a control op `LABPTY_OP_UPGRADE` (next free code `0x000B`) whose payload
is the absolute path of the new binary. App side: in
`MainWindowController.makeSessionCoordinator`, after connecting to an existing
daemon and calling `hello`, if the daemon's reported build differs from the
bundled `labpty`'s build, send `UPGRADE` with the bundled binary's path, then
reconnect. The connection drops during the exec; the existing reconnect
contract re-establishes it and re-attaches sessions.

### Interaction with shipped features

- **ADR 0010 connected-client counter**: reset to 0 on adopt; clients
  re-attach on reconnect. During the brief handoff window an observer would
  see `connected_clients == 0` on live sessions; this is fine because the app
  itself initiates the upgrade and immediately reconnects, and orphan
  detection runs only at app launch.
- **ADR 0007 reconnect contract**: the entire client-visible story of the
  handoff *is* a control-channel drop + reconnect, which already exists and is
  tested. No new client recovery behavior is invented.
- **ADR 0008 write backpressure**: depends on `slave_inspect_fd`, re-opened on
  adopt; if re-open fails the documented degradation applies.

## Milestones

Each milestone is independently verifiable. Acceptance can `exec` the **same**
`labpty` binary — process identity is irrelevant to proving fd/child/ring
survival, which sidesteps "how do I stage two builds in a test."

### M1 — exec-in-place mechanism, proven end-to-end (feasibility core)

Add `--adopt <statefile>`, the state-file writer/reader, the CLOEXEC clearing,
and a **test-only** trigger (a signal, `SIGUSR1`, handled by setting
`pending_upgrade_path` to `/proc/self`-equivalent — on macOS, the path from
`_NSGetExecutablePath`/`KERN_PROCARGS`, or simply the path the daemon was
launched with, captured in `argv[0]`/an env var at startup). Re-attach byte
rings by path (`labpty_byte_ring_attach`). No version detection, no app
trigger, no dry-run gate yet.

At the end of M1 that did not exist before: a running daemon can replace its
own image and keep one live session.

Acceptance (`swift test --filter LabptyDaemonTests/testSelfUpgradePreservesSessions`):
open a `/bin/sh` echo-loop session, write `before\n` and confirm `got before`
in the ring, send the upgrade signal, then assert: child pid unchanged and
alive (`kill(pid,0)==0`), `got before` still readable from the ring, `list`
shows the session `alive`, and writing `after\n` yields `got after`.

### M2 — full session-state continuity

Carry the harder state across handoff: `close_pending`/`terminate_deadline_ns`
(a session mid-terminate keeps escalating to SIGKILL on its original deadline),
`canonical_pending_estimate` (ADR 0008 preflight stays accurate),
`slave_inspect_fd` re-open, `next_handle` (a post-handoff `openSession` gets a
fresh non-colliding handle), and `attached_clients` reset-to-0 + re-attach.

Acceptance: a test that calls `terminate` then immediately upgrades, and
asserts the child is still SIGKILL'd within the deadline window; a test that
opens a new session after handoff and asserts its handle does not collide; a
test that re-attaches after handoff and asserts `connected_clients` returns to
the pre-handoff value.

### M3 — dry-run-adopt validation gate

Add `labpty --dry-run-adopt <statefile>` and the fork-and-check before the
real exec. Add path validation (same uid, allowed directory).

Acceptance: a test that points the upgrade at a deliberately corrupt state
file (or a non-labpty/exit-nonzero binary) and asserts the upgrade is refused
and the **original** daemon keeps serving the session unharmed.

### M4 — real trigger: version in hello + UPGRADE op + app detection

Add build identity to the `hello` response, the `LABPTY_OP_UPGRADE` op and its
Swift client method, and app-side detection in
`MainWindowController.makeSessionCoordinator`.

Acceptance: a daemon launched from an "old" copy of the binary, an app
launched from a "new" copy, and on app launch the daemon self-upgrades and the
session survives (a Swift integration test driving the real app coordinator,
or a scripted two-binary harness). `connected_clients` re-derives to 1.

### M5 — formal spec + permanent regression test

Add `specs/labpty/LabptyHandoff.tla` modelling the handoff: the invariant that
**every live master fd is continuously owned across the handoff** (never closed
between predecessor and successor) and an `AtMostOneServing`-style property
that the socket path always has exactly one server. Add a positive `MC_Handoff`
config and a negative-control `MC_HandoffPreFix` (e.g. modelling the
fork+exec-then-exit variant, whose successor loses the child — the
counterexample that documents *why* exec-in-place is required). Wire both into
`scripts/check-specs`. Update `docs/process/formal-specs.md`.

## Validation and Acceptance

The feature is done when all of the following hold:

- `swift build` is clean and `swift test --filter LabptyDaemonTests` passes,
  including the new self-upgrade tests from M1–M4.
- `./scripts/check-specs` passes with the new `MC_Handoff` (verifies) and
  `MC_HandoffPreFix` (must find a counterexample) configs.
- Manual end-to-end: build `labpty` (`swift build --product labpty`), start it,
  open a session, trigger an upgrade to a freshly rebuilt `labpty`, and observe
  the shell's scrollback intact and new keystrokes echoing — the child pid
  unchanged throughout (watch with `ps`).
- ADR 0006's upgrade matrix row "labpty code change without fd-handoff →
  session dies" is updated to reflect that with the fd-handoff, the session
  survives; a short note added to ADR 0006 (or a new ADR if the policy is
  judged durable enough to record separately).

## Decision Log

- **Exec-in-place, not fork+exec (load-bearing).** Child exit is detected only
  by `waitpid(child_pid)` (`labpty_registry.c:58–67,335`). A fork+exec handoff
  where the old daemon exits reparents the shells to `launchd`; the
  new-pid successor gets `ECHILD` and can never reap or finish SIGKILL
  escalation. macOS has no subreaper to transfer this. ADR 0006's "fork …
  signals ready via a pipe, then exits" sketch is therefore wrong for labpty.
  Same-pid `execve` preserves the parent-child relationship, keeps open fds
  (and their numbers), and avoids a two-process socket-ownership race.
- **Dry-run-adopt gate before the real exec.** `execve` is irreversible, so a
  broken successor would kill all sessions. Forking a child to run the new
  binary in `--dry-run-adopt` against a copy of the state file exercises the
  real adopt code before crossing the one-way door; a `--version` check alone
  would miss subtle adopt/parse bugs.
- **Re-attach byte rings by path, do not pass ring fds.** `execve` wipes the
  address space, so the `mmap` is gone regardless; the ring is file-backed and
  re-openable by `ring_path`. A new `labpty_byte_ring_attach` opens the
  existing ring and re-derives offsets from the header rather than
  reinitialising it. Ring fds keep `O_CLOEXEC`.
- **Reset `attached_clients` to 0 on adopt.** Control connections drop across
  the exec; clients re-attach via the ADR 0010 path, so the count re-derives.
  Carrying stale masks across handoff would overcount departed connections.
- **Trigger via control RPC carrying the binary path, gated by hello version.**
  The app knows where its bundled `labpty` is and when it differs from the
  running daemon's build; an explicit, validated RPC is safer and clearer than
  a fixed-path signal re-exec.

## Surprises & Discoveries

- **Master fds are `FD_CLOEXEC`** (`session_lifecycle.c:226,507,639`). A naive
  exec would close them and SIGHUP the children. The handoff must clear the
  flag on masters + listener immediately before exec.
- **No catalog persistence exists.** ADR 0006 specified a "tiny catalog file
  for crash recovery," but a grep of all of `Sources/Labpty/` finds no writer.
  This plan introduces the first on-disk catalog (the handoff state file). A
  future crash-recovery feature can reuse the same serialization.
- **`terminate_deadline_ns` is `CLOCK_MONOTONIC`** — per-boot, so it survives
  `execve` on the same machine and the SIGKILL escalation continues without
  recomputation.
- **Same-pid exec preserves fd numbers**, so the state file records master fd
  integers directly — no `SCM_RIGHTS`, no renumbering.

## Risks

- A successor crash after the real `execve` loses sessions (no rollback past
  the one-way door). Mitigated by the dry-run gate; accept residual risk.
- The `--adopt` parser is a new trust boundary reading a file the daemon wrote;
  keep it defensive and fuzz-tested, and validate before mutating any state.
- The TLA+ handoff spec (M5) is the genuinely hard part; budget for it as a
  milestone, not an afterthought.

## Progress

- [ ] M1 — exec-in-place mechanism + `testSelfUpgradePreservesSessions`
- [ ] M2 — full session-state continuity (teardown deadlines, handles, inspect fd, attachment reset)
- [ ] M3 — dry-run-adopt validation gate + path validation
- [ ] M4 — hello build identity + `LABPTY_OP_UPGRADE` + app-side detection
- [ ] M5 — `LabptyHandoff.tla` + MC configs wired into `check-specs`; docs updated
