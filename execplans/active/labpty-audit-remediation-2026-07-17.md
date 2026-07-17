# Remediate the July labpty correctness and verification audit

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress`, `Decision Log`, `Surprises & Discoveries`, and `Validation and
Acceptance` current as the work proceeds.

## Purpose / Big Picture

The labpty daemon is the process that owns background terminal PTYs and moves
their output through shared-memory byte rings to the macOS app. A focused audit
found five correctness defects: terminate responses lose their session
identity, multiple output-wake file descriptors overwrite one another's watched
sessions, concurrent daemon startups can strand a bound socket before it starts
listening, a byte-ring reader can return an unconfirmed copy after sustained
writer churn, and an encoded paste larger than one protocol frame is rejected
instead of delivered in ordered chunks. The audit also found that GitHub Actions
does not execute the tests and formal checks which are described as required.

After this plan, each defect has a regression test, concurrent daemon startup is
serialized and represented by the TLA+ startup model, large terminal input is
split into ordered protocol-sized writes, and pull requests run Swift tests,
the gated stress test, TLC state-machine checks, CBMC decoder proofs, and runtime
trace conformance. The three audit-identified tests for process-group signals,
PTY resize, and connection survival also assert the behavior named by their
test names rather than only an RPC echo or daemon liveness.

## Progress

- [x] (2026-07-17) Reproduced all five medium findings and confirmed the CI and test-assertion gaps against `main`.
- [x] (2026-07-17) Created branch `agent/labpty-audit-fixes`; preserved unrelated untracked handoff files.
- [x] (2026-07-17) Fixed terminate response ownership and multi-wake watch merging with daemon regression tests.
- [x] (2026-07-17) Serialized bind-to-listen startup, expanded `LabptyStartup.tla`, and added a negative-control config for the bind/listen race.
- [x] (2026-07-17) Made byte-ring confirmation exhaustion fail closed and taught the app feed to reset continuity even when no bytes are trusted.
- [x] (2026-07-17) Chunked large `writeInput` calls into ordered protocol-sized frames and verified the exact chunk sequence.
- [x] (2026-07-17) Strengthened the three misleading daemon tests so they observe process-group, kernel winsize, and same-connection behavior.
- [x] (2026-07-17) Added Swift, stress, TLC, CBMC, and trace-conformance gates to GitHub Actions and corrected the formal-process documentation.
- [x] (2026-07-17) Ran targeted tests, formal checks, formatting/lint, builds, deterministic stress, and the proportional repository check suite.
- [x] (2026-07-17) Committed correctness fixes and regression/formal coverage as `05b999f`.
- [x] (2026-07-17) Committed mandatory verification changes as `2aa80d3`
  and pushed both focused commits to `origin/agent/labpty-audit-fixes`.

## Decision Log

- Decision: serialize only the startup critical section with a persistent
  advisory lock file next to the Unix socket, held from stale-path inspection
  through `listen(2)`.
  Rationale: binding a pathname publishes it before `listen(2)`, so a second
  process can observe `ECONNREFUSED` and unlink it. A lock covers that exact
  multi-process window while preserving the existing live-socket refusal and
  stale-socket recovery behavior. The lock file must not be unlinked on release,
  because unlinking while another process waits can create two independently
  locked inodes.
  Date/Author: 2026-07-17 / Codex

- Decision: merge each successful park request into an output-wake fd's current
  watched-handle set, pruning handles no longer present in the registry.
  Rationale: the protocol keys wake connections by logical `client_id` and does
  not identify which of several same-ID wake fds a control-socket park request
  targets. A union preserves every parked fd's earlier session while stale
  handle pruning bounds the set by the daemon's 64 live registry slots.
  Date/Author: 2026-07-17 / Codex

- Decision: after all byte-ring confirmation retries fail, advance to the last
  confirmed producer offset with no payload and `overflowed = true`.
  Rationale: no copied byte range was proven safe from overwrite. Dropping the
  uncertain range and forcing the existing parser-continuity reset is safer than
  feeding potentially torn bytes to the VT parser.
  Date/Author: 2026-07-17 / Codex

- Decision: keep the 64 KiB wire limit and chunk in
  `LabptyTerminalSessionClient.writeInput`.
  Rationale: the limit bounds individual frames and daemon staging memory; it
  is not intended to cap a user's logical paste. Sequential RPCs preserve byte
  order without changing the C/Swift wire layout or proof bounds.
  Date/Author: 2026-07-17 / Codex

## Surprises & Discoveries

- The local Homebrew prefix is not writable, so `brew install cbmc` cannot
  install the verifier without changing machine ownership. `scripts/check-cbmc`
  completed its compile/drift smoke check locally; the workflow installs CBMC
  in the GitHub-hosted runner and executes the actual proofs there.
- The complete `swift test` run consistently executes 2,494 tests but reports
  six assertions in three existing renderer calibration tests: one styled
  narrow-glyph width assertion, one 48 MB atlas-ladder budget assertion, and
  four horizontal centroid-direction assertions. This change does not touch
  renderer sources or tests. The complete 117-test `LabptyTests` selection,
  deterministic labpty stress run, and every new regression test pass.
- Output-wake replacement remains exact when a client has one wake fd. The
  daemon switches to live-handle pruning plus union only when several wake fds
  share a client id, preserving the established single-fd reconnect behavior
  while closing the audited multi-fd stall.

## Context and Orientation

`Sources/Labpty/main.c` owns the daemon control socket, request handlers,
output-wake connections, and Unix-socket startup. `Sources/Labpty/
labpty_registry.c` owns session lifetime; `labpty_session_descriptor` returns a
view whose string fields borrow storage from the session. Termination currently
builds that view, clears the session's logical id and ring path during close,
then encodes the now-empty borrowed strings.

An output-wake fd is a long-lived control connection switched into a one-byte
readiness channel. A normal control connection sends `parkOutputWake` with a set
of session handles. `arm_output_wake_clients` currently assigns that set to
every wake connection with the same `client_id`; assignment destroys the set an
older wake fd was already parked over.

`listen_unix_socket` binds an AF_UNIX pathname and calls `listen` later. Its
stale probe treats `ECONNREFUSED` as proof that the path can be removed. That is
correct for a crashed daemon's leftover socket but also describes a concurrent
daemon between successful `bind` and `listen`. `specs/labpty/
LabptyStartup.tla` currently combines those syscalls in one atomic action and
therefore cannot produce the race.

`Sources/LabanCore/LabptyByteRingReader.swift` copies shared ring bytes and
re-reads the producer offset to prove the copied region was not overwritten.
After repeated failed confirmations it returns the last copy unconditionally.
`Sources/LabanApp/AppSessionCoordinator.swift` already resets the VT parser when
`overflowed` is true, but its empty-byte early return currently prevents a
drop-only fallback from triggering that reset.

`Sources/LabanCore/LabptyProtocol.swift` deliberately caps one write-input
payload at 64 KiB. `Sources/LabanCore/PTYLabClient.swift` currently constructs
one payload from the whole logical input, so a larger paste throws before any
frame is sent. The AppKit paste route reaches this client through
`AppSessionCoordinator`.

`.github/workflows/check.yml` runs format lint and `swift build` only.
`scripts/check-specs`, `scripts/check-cbmc`, and `scripts/check-trace` already
exist and are used locally. `Tests/LabptyTests/LabptyStressTests.swift` is gated
by `LABPTY_STRESS=1`, which no checked-in automation currently sets.

## Plan of Work

First, copy the terminate descriptor's two strings into stack-owned buffers
before any close operation and point the encoded view at those buffers. Replace
output-wake watch assignment with bounded live-handle pruning and de-duplicated
union. Add integration tests that assert a live terminate response preserves
both identity strings and that two same-ID wake fds retain independently parked
sessions after the control connection disconnects.

Second, add a private, owner-only startup lock file derived from the socket path.
Validate the opened lock inode, take `flock(LOCK_EX)` with EINTR handling, and
hold it around the complete existing probe/bind/chmod/listen sequence. Keep the
lock file on disk. Refactor `LabptyStartup.tla` so startup has separate acquire,
probe/bind, and publish-listen actions. Add a constant that removes
serialization for a negative control, wire that config into
`scripts/check-specs`, and update formal documentation.

Third, return an empty overflow result after exhausted byte-ring confirmation
attempts and expose a narrow internal confirmation closure so the fallback can
be tested deterministically. Move the app feed's overflow handling ahead of its
empty-byte return and dirty the session after a reset-only result. Add tests for
the fallback result and feed behavior where practical.

Fourth, iterate over at most `maxWriteInputBytes` slices in the handle-based
Swift client write method. A fake labpty server will negotiate hello, decode all
write requests, and assert that a payload of two full chunks plus a tail arrives
as exactly three ordered frames.

Fifth, rewrite the named weak tests. The signal test will obtain a spawned
descendant pid and require a group signal to kill both parent and descendant.
The resize test will install a `SIGWINCH` handler which prints `stty size`, then
assert the child observes the new kernel PTY dimensions. The unknown-operation
test will send a valid hello request on the same raw fd after the error and
require a successful response.

Finally, extend GitHub Actions. Reuse the existing macOS 26 build job for
`swift test` and a deterministic bounded stress run. Add a small formal job
which downloads a checksum-pinned `tla2tools.jar`, installs CBMC from Homebrew,
and runs anchors, TLC specs, CBMC, trace conformance, and model coverage. Update
the process documentation so every statement about CI matches the workflow.

## Concrete Steps

Run commands from `/Users/rrj/wrk/laban`.

1. Implement daemon, Swift, test, spec, workflow, and documentation patches
   with `apply_patch`.
2. Format Swift sources and tests with `./scripts/format`, then inspect the
   resulting diff so unrelated files are not included.
3. Build and run targeted checks while iterating:

       swift build --product labpty
       swift test --filter LabptyDaemonTests
       swift test --filter LabptyAdversarialTests
       swift test --filter LabptyClientTransportTests
       ./scripts/check-specs
       ./scripts/check-cbmc
       ./scripts/check-trace

4. Before publication, run the broader gates that fit the changed boundaries:

       ./scripts/lint
       swift test
       LABPTY_STRESS=1 LABPTY_STRESS_DURATION_S=10 LABPTY_STRESS_SEED=20260717 swift test --filter LabptyStressTests
       ./scripts/check-anchors
       ./scripts/check-model-coverage
       git diff --check

5. Stage only files named by this plan, make focused single-reason commits, and
   push with tracking:

       git push -u origin agent/labpty-audit-fixes

## Validation and Acceptance

The work is accepted when all of the following are observable:

- Terminating a live `/bin/sleep` session returns its original logical id and
  byte-ring path with `alive == false`; the client cache contains no empty-id
  entry.
- With two wake fds sharing one `client_id`, parking the first over session A,
  opening the second and parking over B, then disconnecting the control socket
  still lets A wake the first fd and B wake the second.
- TLC verifies the serialized startup model and rejects a negative-control
  configuration where two daemons can interleave bind and listen without the
  startup lock.
- An exhausted read-confirmation sequence returns no untrusted bytes,
  advances the consumer offset, and reports overflow so the app resets parser
  continuity.
- A logical input larger than 128 KiB reaches a fake server as two 64 KiB
  write-input requests plus the exact remaining tail, in byte order.
- The signal regression fails if the daemon uses `kill(pid)` only, the resize
  regression fails if it merely echoes requested rows/columns without
  `TIOCSWINSZ`, and the unknown-operation regression fails if the daemon closes
  that connection after its error response.
- The workflow contains and locally reproducible commands for Swift tests,
  stress, TLC, CBMC, and trace conformance.
- All commands recorded in `Concrete Steps` exit zero, or an environmental
  blocker and its exact impact are recorded in `Surprises & Discoveries`.

Validation completed on 2026-07-17:

- `./scripts/format`, `./scripts/lint`, `git diff --check`, workflow YAML parse,
  `swift build --product labpty`, and the repository anchor, boundary, docs,
  fd-hygiene, and model-coverage checks passed.
- `swift test --filter LabptyTests` passed 116 tests and skipped only the
  opt-in stress case. The same stress case then passed with
  `LABPTY_STRESS=1`, a 10-second duration, seed `20260717`, and 4,037 opens.
- TLC accepted every fixed model and rejected every checked-in negative
  control, including the new startup bind/listen race and output-wake watch
  replacement models. Runtime trace conformance accepted all fixed traces and
  rejected its negative controls.
- `scripts/check-cbmc` passed its local compile/drift path. The actual CBMC
  proof remains an environmental exception locally and is a mandatory CI step.
- The full package run's unrelated renderer calibration failures are recorded
  above; no labpty suite failed.

## Outcomes & Retrospective

All five medium findings are fixed without changing the wire layout or shipped
session semantics. The daemon now preserves terminate identity, serializes the
socket publication window, and retains multi-fd output watches; the Swift side
drops unconfirmed ring copies and frames large logical writes. Tests now observe
the kernel and connection behavior their names promise. Formal negative
controls reproduce both newly modelled races, and the CI workflow makes the
previously manual labpty verification set mandatory on pull requests.

The lower-severity daemon epoch, response-tag validation, nonblocking startup
probe, and main-thread RPC concerns remain outside this focused remediation.
The only incomplete local proof is CBMC execution itself; the checked-in CI job
provides a writable Homebrew environment and makes that proof a merge gate.

## Idempotence and Recovery

All tests create run-id-scoped `.tmp` directories and clean them in teardown.
The daemon's startup lock file intentionally persists beside the socket; it is
an inode used for future advisory locks and is removed when the containing
runtime/test directory is removed. Re-running the formal checks overwrites only
temporary files. If a test leaves a child process alive, use the test harness's
recorded pid and run-id-scoped path rather than broad `pkill` commands.

Git staging must use explicit paths because the worktree contains unrelated
untracked handoff files. Recovery from a failed publication is a normal fix and
new commit on the same branch; do not reset or delete user files.

## Interfaces and Dependencies

No wire layout changes. `LabptyProtocolLimits.maxWriteInputBytes` remains the
per-frame maximum. `LabptyTerminalSessionClient.writeInput(handle:bytes:)`
retains its public signature and gains ordered chunking internally.

The startup implementation uses Darwin/POSIX `open`, `fstat`, `flock`, and
`close`; no new package dependency is introduced. CI uses TLA+ tools 1.7.1 as a
checksum-pinned jar and the Homebrew `cbmc` formula. The TLA model gains one
Boolean constant selecting whether startup serialization is present, used only
to keep a permanent negative control of the reported race.
