# Extract `labpty` from `laband`

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file plus the current
working tree, then deliver Phase 1 end-to-end.

This plan implements Phase 1 of the three-tier session architecture decided
in `docs/adr/0006-three-tier-session-architecture.md`. Phase 2
(single-client byte-ring mode in `laband`) and Phase 3 (`labpty` self-upgrade
via fd handoff) are separate ExecPlans that build on this one.

## Purpose / Big Picture

Today the `laband` daemon (`Sources/Laband/main.swift`) owns the PTY master
fd, runs `libghostty-vt` for parsing, maintains scrollback, publishes the
`LBNDSS01` snapshot ring, manages leases, writes the lifecycle journal, and
forks user child processes. Every change to `laband` — a libghostty bump, a
new theme behavior, a fix like the M2 (foreground process metadata) work in
`execplans/active/background-session-regressions.md` — requires restarting
the daemon, which closes the PTY master and kills the user's live shells
via `SIGHUP`. The "live sessions survive app upgrade" promise of ADR 0005
therefore has a hole: it does not survive `laband`'s own upgrades.

Phase 1 closes that hole. It introduces a separate, deliberately minimal
binary named `labpty` that owns only the kernel-level objects (PTY master
fd, child process group, raw output byte ring). `laband` becomes a `labpty`
client internally: it asks `labpty` to open the PTY, then drains output by
**reading the per-session byte ring `labpty` publishes in shared
memory**. The app-facing `LabandTerminalSessionClient` contract does not
change. The user-visible improvement Phase 1 ships:

- **After Phase 1, killing or upgrading `laband` no longer kills sessions
  born under `labpty`.** A running Claude Code conversation or `vim` session
  inside a tab survives a daemon restart.

Phase 1 does **not** ship the latency improvement from ADR 0006's
single-client mode. The app continues to receive parsed snapshots from
`laband` exactly as today. Latency-bypass (app reads the byte ring
directly) is Phase 2 and is gated by its own ExecPlan.

### First-migration caveat

Phase 1 is the first build to ship `labpty`. When a user upgrades from a
pre-`labpty` Laban to a `labpty`-enabled Laban, the old `laband` must
restart and its in-flight PTY sessions die — this is the one acceptable
session loss. There is **no design here for an old `laband` to hand
already-open master fds to a new `labpty`**; that complexity is not worth
the value. From that first launch onward, every newly-created background
session is born under `labpty`, and from that point laband restarts/upgrades
do not kill the child.

### Phase boundaries on session survival

| Event | Phase 1 (this plan) | Phase 2 | Phase 3 |
| --- | --- | --- | --- |
| App restart | child survives (already today via `laband`) | survives | survives |
| `laband` restart/upgrade | **child survives (Phase 1 headline)** | survives | survives |
| `libghostty` bump in `laband` | survives (`libghostty` only runs in `laband`; restart is allowed) | survives | survives |
| `labpty` restart/upgrade | child dies | child dies | survives via fd handoff |
| `labpty` crash | child dies | child dies | child dies |
| OS reboot | child dies | child dies | child dies |

## Architectural Invariants

These invariants are the spine of Phase 1. The plan, the code, and the
Review Gate all enforce them. Every milestone description below must
preserve them. If a step appears to violate one, stop and revise the plan
rather than coding past it.

1. **`labpty` is the sole steady-state reader and writer of every PTY
   master it opens.** No other process — not `laband`, not `LabanApp`, not
   a test harness — reads from or writes to a PTY master fd that `labpty`
   owns. POSIX rationale: two processes blocked in `read(2)` on the same
   PTY master fd will both wake when the kernel buffer becomes readable
   and either can win a given byte; bytes get split between readers
   non-deterministically. Two writers can interleave partial writes. There
   is no portable way to fix this without an external arbiter, so we make
   `labpty` the arbiter by being the only process holding the fd.

2. **`laband` consumes output via the byte ring `labpty` publishes in
   shared memory.** `laband` parses those bytes through a parser-only
   `LabanCore.Session` (no PTY underneath), then publishes the existing
   `LBNDSS01` parsed-snapshot ring to clients exactly as today.

3. **`laband` routes input by calling a `labpty` RPC; `laband` does not
   `write(2)` to a master fd.** Phase 1 uses a bounded control-plane
   `writeInput` RPC. Phase 2 may upgrade to a shared-memory input ring
   (`LBPTY-IR-01` in the protocol design) once that hop is shown to add
   measurable user-visible keystroke latency.

4. **`LabanApp` continues to speak only the existing `laband` protocol in
   Phase 1.** `LabanApp` does not link `LabptyTerminalSessionClient` and
   does not consume the byte ring directly. The Phase 1 user-visible
   change is reliability, not architecture.

5. **`labpty`'s in-memory session catalog is the discovery mechanism after
   a `laband` restart.** `laband` keeps no persistent map of "which
   `labpty` session belongs to which logical session id" beyond its own
   journal; on restart it calls `labpty.listSessions` and reattaches each
   live session's byte ring. The catalog need not survive `labpty`'s own
   restart in Phase 1 (that is Phase 3's problem).

6. **ADR 0002 PTY launch invariants move with the PTY into `labpty`.**
   Parent-side `openpty`, initial winsize before child runs, constrained
   fork child branch, parent-only master fd, teardown via process-group
   escalation. Every existing test that proves these for `laband` must be
   reformulated to prove them for `labpty`.

## Progress

- [ ] M0: Wire-protocol and ring design reconciled with
  `execplans/active/labpty-protocol-design.md`. Phase 1 subset documented
  in this plan's `Interfaces and Dependencies` section.
- [ ] M1: New `labpty` executable that owns PTYs and exposes the Phase 1
  control RPCs (`hello`, `openSession`, `listSessions`, `attachSession`,
  `resizeSession`, `signalSession`, `terminateSession`, `writeInput`,
  `ping`) over a run-id-scoped Unix socket. No byte ring yet; the
  master drain discards bytes into a tiny buffer just to keep the
  child unblocked. ADR 0002 launch invariants preserved inside
  `labpty`. Unit-test coverage for open/list/resize/signal/terminate
  and `child_pid` alive/dead.
- [ ] M2: Output byte ring `LBPTY-BR-01` implemented as a lock-free
  single-producer multi-reader shared-memory ring with a monotonic
  `write_offset` counter and 100 ms producer-alive heartbeat (subset of
  the layout in `execplans/active/labpty-protocol-design.md`). `labpty`
  drains the master into the ring. `attachSession` returns the shm path
  for that ring. **No master fd is sent over the socket in Phase 1.**
  Independent writer/reader tests in `Tests/LabptyTests/`.
- [ ] M3: Parser-only `laband` session path. Confirms that the existing
  `Session.fixture(size:)` + `session.feedOutput(_:)` combination is the
  correct basis (the C ABI already exposes
  `laban_session_feed_output`). Add a tiny Swift wrapper if needed for
  ergonomics, but do not invent new C ABI in Phase 1. Tests prove a
  representative PTY byte stream replayed through this path produces the
  same `LabandSnapshotResponse` as the same stream drained from a real
  PTY today.
- [ ] M4: Refactor `Sources/Laband/main.swift` so `ManagedLabandSession`
  no longer opens PTYs directly. `laband.createSession` calls
  `labpty.openSession`; `laband` opens the byte ring via `labpty
  .attachSession`; `laband` runs a ring-reader loop that calls
  `session.feedOutput(_:)` on a parser-only `LabanCore.Session` and
  publishes the existing `LabandSnapshotRingWriter`. `laband
  .resize/signal/terminate` route to `labpty`. `laband.writeInput`
  routes to `labpty.writeInput`. App-facing
  `LabandTerminalSessionClient` is unchanged.
- [ ] M5: `laband` restart survival. Acceptance test launches `labpty`
  and `laband`, creates a session, writes/reads some bytes, kills
  `laband` with `SIGTERM`, restarts it, calls `listSessions`,
  reattaches the byte ring, writes more bytes, and observes new output
  from the **same** `child_pid`.
- [ ] M6: Packaging and run orchestration. `scripts/build-app` bundles
  `labpty`, `laband`, and `LabanApp` together. Dev/test sockets, rings,
  and journals are run-id-scoped under `.tmp/<run-id>/` and
  `.artifacts/runs/<run-id>/` per
  `docs/process/worktree-isolation.md`. Launch order (`labpty` before
  `laband`) is documented in `scripts/` and in this plan.

## Context and Orientation

All paths are repo-relative. A fresh contributor with no prior context
should be able to navigate from this section to every file they need to
read or edit.

### Where `laband` currently owns PTYs

`Sources/Laband/main.swift`:

- `ManagedLabandSession` (line 193) owns:
  - `session: Session?` — a `LabanCore.Session` wrapping a libghostty-vt
    handle **and** the PTY master fd. Opened via `Session.realShell(...)`
    at line 451.
  - `runner: SessionRunner?` — drains the master into libghostty on a
    dedicated thread (`Sources/LabanCore/SessionRunner.swift`).
  - `ringWriter: LabandSnapshotRingWriter?` — publishes parsed snapshots
    for the app's `LabandTerminalSessionClient` to consume.
- `LabandDaemon` (line 320) is the per-process daemon object; its
  `sessions` map keys logical session ids to `ManagedLabandSession`
  instances.

The PTY itself is opened by `Sources/LabanCore/Session.swift:159`
(`Session.realShell(...)`) which delegates into `LabanTerminalCore` for
the C-level `openpty` + constrained-fork-child per ADR 0002.
`Sources/LabanTerminalCore/session_lifecycle.c:170`
(`laban_session_create`) gates PTY creation on a `fixture_mode` flag in
`LabanLaunchConfig`. When `fixture_mode != 0`, the session has libghostty
parser state but no PTY (line 312 short-circuits the launch).

`laban`'s drain loop is built on
`Sources/LabanTerminalCore/include/LabanTerminalCore.h:196`,
`laban_session_poll_blocking(session, timeout_ms)`, called from
`SessionRunner.run()` (line 74 of `SessionRunner.swift`). It reads from
the master and feeds bytes into libghostty internally; the parser-feed is
the same code path as `laban_session_feed_output`, just sourced from the
master.

### The parser-only feed path already exists

A material discovery (see `Surprises & Discoveries`): the C ABI in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h:223-229` exposes
`laban_session_feed_output(session, bytes, len)` which "feeds bytes
directly into the VT parser (ghostty_terminal_vt_write) in both fixture
and PTY modes." The Swift wrapper is `Session.feedOutput(_:)` at
`Sources/LabanCore/Session.swift:407`. Tests already exercise it for
fixture-only parsing (e.g.,
`Tests/LabanCoreTests/CaptureSessionBridgeTests.swift:18`,
`Tests/LabanCoreTests/RecentByteRingIntegrationTests.swift:30`).

This means Phase 1 does **not** need a new "parser-only Session"
constructor or a new C ABI for byte injection. M3's job is to compose
existing pieces: `Session.fixture(size:)` to create a parser-only session
plus `session.feedOutput(_:)` to inject bytes from `labpty`'s ring. A
thin Swift helper (`Session.attachingByteRing(...)` or similar, doing
nothing more than `let s = try .fixture(size: size); return s`) is
optional ergonomics.

### Where the snapshot ring lives

`Sources/LabanCore/LabandSnapshotRingLayout.swift` defines the `LBNDSS01`
shared-memory layout: file header, slot headers with seqlock protection,
per-cell records, string table. `LabandSnapshotRingWriter` publishes;
`LabandSnapshotRingReader` consumes. This is the *parsed* snapshot ring —
cells, cursor, dirty ranges — used by the app's snapshot generation
monitor.

The Phase 1 byte ring `LBPTY-BR-01` is a **different** shared-memory
artifact with a different design: a circular byte buffer with a
single-producer lock-free monotonic write-offset counter (per
`execplans/active/labpty-protocol-design.md`), not a seqlock-protected
slot. The two rings coexist: `labpty` writes `LBPTY-BR-01`, `laband`
reads it and writes `LBNDSS01`, the app reads `LBNDSS01`.

### Where the control protocols live

`Sources/LabanCore/LabandProtocol.swift` defines the JSON-shaped wire
protocol between `laband` and clients. `Sources/LabanCore
/LabandTerminalSessionClient.swift` is the client side;
`Sources/Laband/main.swift` is the server side.

`labpty` introduces a **second** control protocol, deliberately separate
from `LabandProtocol`. Keep them in distinct files
(`Sources/LabanCore/LabptyProtocol.swift` and
`Sources/LabanCore/LabptyTerminalSessionClient.swift`); do not collapse
them. Rationale: `labpty`'s surface is meant to be small and rarely
change while `LabandProtocol` evolves with libghostty features.

### Where tests for the daemon live

`Tests/LabandTests/LabandControlProtocolTests.swift` is the canonical
example of launching a real `laband` from a test and exercising it
end-to-end. The new `Tests/LabptyTests/` directory follows the same
pattern: build the binary, launch under `.tmp/<run-id>/`, exercise the
RPC, verify.

`scripts/test-laband-reattach` is an existing script that already proves
client-reattach across `laband` restart against the current architecture
(where `laband` owns the PTY and the child dies on restart — this script
tests reattach to the *daemon*, not session survival). Phase 1 introduces
a new acceptance script
`scripts/test-labpty-survives-laband-restart` that asserts the
headline behavior: child survives.

### Worktree isolation

`docs/process/worktree-isolation.md` and ADR 0005 require dev/test
sockets, journals, and shm files to be run-id-scoped. Existing patterns
use `.tmp/<run-id>/` and `.artifacts/runs/<run-id>/`. Apply the same to
`labpty`'s control socket, byte-ring shm files, and (optional) catalog
file. Production paths (per-user LaunchAgent) are out of scope for Phase
1.

## Plan of Work

The milestones below are independently verifiable and incrementally
implement the overall goal. Each names exact files, APIs, and
behaviors.

### M0 — Wire-protocol and ring design

Add the Phase 1 protocol and ring types to `LabanCore`:

- `Sources/LabanCore/LabptyProtocol.swift` (new). Declares
  `LabptyRequest`, `LabptyResponse`, the request/response payloads for
  the eight Phase 1 RPCs (`hello`, `openSession`, `listSessions`,
  `attachSession`, `resizeSession`, `signalSession`, `terminateSession`,
  `writeInput`), and the error-code enum. JSON-Codable. See `Interfaces
  and Dependencies` for the concrete shapes.
- `Sources/LabanCore/LabptyByteRingLayout.swift` (new). Declares the
  `LBPTY-BR-01` file-header offsets and constants. **No seqlock-slot
  pattern.** A monotonic `output_write_offset` plus a power-of-two
  capacity is the entire synchronization. Counters block sits between
  file header and the ring payload.
- `Sources/LabanCore/LabptyTerminalSessionClient.swift` (new). Thin
  client that opens a Unix socket, sends length-prefixed JSON, parses
  responses. No SCM_RIGHTS in Phase 1 (see Decision Log).

Unit tests in `Tests/LabptyTests/` (new):

- `testLabptyProtocolRoundTrip` — Codable round-trip for each
  request/response shape.
- `testByteRingHeaderConstants` — header offsets and sizes are stable;
  capacity must be a power of two; magic bytes are `b"LBPTY-BR"`.

### M1 — `labpty` executable and ADR 0002 PTY ownership

Add a new SwiftPM executable target `Labpty` (sibling of `Laband` in
`Package.swift`).

Files:

- `Sources/Labpty/main.swift` (new). Process entry; argument parsing
  (`--socket <path>` and `--shm-dir <path>`); Unix-socket listener; RPC
  dispatch; main event loop.
- `Sources/Labpty/LabptySessionRegistry.swift` (new). In-memory map
  `ptyHandle → (LabanCore.Session, child_pid, byte_ring_writer, attach
  count, rows, cols, openedAtMonoNs)`. The catalog. Provides the queries
  `listSessions`, `find(ptyHandle:)`, `insert`, `remove`. Phase 1
  catalog is in-memory only; an optional run-scoped file at
  `.artifacts/runs/<run-id>/labpty/catalog.json` is written for
  diagnostics (it is **not** read on startup — `labpty` restart is not
  survivable in Phase 1).

PTY ownership and launch:

- `labpty` performs the ADR 0002 launch directly (parent-side
  `openpty`, initial winsize before child startup, constrained fork
  child branch, parent-only master fd retained, teardown via
  process-group escalation). The reference implementation already
  lives inside `Sources/LabanTerminalCore/session_lifecycle.c` (lines
  377-431 plus the destroy path); `labpty` either reuses that code
  via a new minimal C entry point `laban_pty_open(rows, cols, argv,
  envp, cwd, &master_fd, &child_pid)` that performs only the launch
  (recommended), or wraps `Session.realShell` and never touches its
  parser side (acceptable fallback — see Decision Log). Each master
  fd is registered with `labpty`'s single-threaded kqueue on
  `EVFILT_READ`. **`labpty` is the only process that holds the
  master fd.** No code in `labpty` ever sends that fd to another
  process in Phase 1.
- `labpty` polls foreground-process metadata via the same primitives
  the current `laban_session_process_metadata` C function uses
  (`tcgetpgrp` on the master, `proc_name`/`proc_pidpath`/
  `proc_pidinfo` from libproc) at ~1 Hz. The Swift wrapper
  `Session.processMetadata()` (`Sources/LabanCore/Session.swift:534`)
  is one way to call it if `labpty` keeps a `Session` per master; a
  thin C helper that reads the same fields without a `Session`
  works equally well. Either path populates
  `LabptySessionDescriptor.foreground*` on every `listSessions` and
  `attachSession` response. This is the source the tab-title fix
  added in `Sources/LabanApp/AppLabandSessionCoordinator.swift` will
  consume after M4 — `laband`'s own parser-only
  `Session.processMetadata()` returns `nil` (no PTY), so `labpty`'s
  poll is the only source.
- The master drain in M1 is a simple call to `Session.feedOutput`-style
  internal poll (existing `laban_session_poll_blocking` works) but
  bytes are discarded; the parser still runs so the child sees normal
  PTY backpressure semantics. M2 wires the drain into the ring.

Tests in `Tests/LabptyTests/`:

- `testOpenAndListAndTerminate` — open a session, `listSessions`
  reports it with `alive=true` and a real `child_pid`,
  `terminateSession` returns 0, `listSessions` reports `alive=false`
  (or omits the entry; pick one and document), the `child_pid` is no
  longer in the process table.
- `testResizeUpdatesWinsize` — open `/bin/sh -c 'stty size; sleep
  30'`, `resizeSession(rows:24, cols:80)`, then attach the byte ring
  (anticipating M2) or call `stty size` and grep output — but since
  M1 has no byte ring, this test can be deferred to M2 or use
  out-of-band measurement (e.g., `signalSession(SIGWINCH)` and observe
  no error). Prefer to defer the readable assertion to M2.
- `testSignalSendsToProcessGroup` — open `/bin/sh -c 'trap "echo
  SIGINT" INT; sleep 30'`, send `SIGINT`, prove the child is still
  running but the trap fired (assertable in M2 when output is
  readable). Defer the output-side assertion to M2.

### M2 — Output byte ring `LBPTY-BR-01`

Implement the Phase 1 subset of the byte ring in `LabanCore`:

- `Sources/LabanCore/LabptyByteRingWriter.swift` (new). Single-producer
  writer. Owns the shm region; writes monotonic `output_write_offset`.
  `write(_ bytes: UnsafeBufferPointer<UInt8>)` does memcpy with at most
  one wrap-split, then `atomic_store_explicit(&offset, new,
  memory_order_release)`. Updates `output_bytes_written_total`,
  `output_writes_total`, `output_wrap_count`,
  `producer_alive_mono_ns`.
- `Sources/LabanCore/LabptyByteRingReader.swift` (new). Lock-free
  reader. Maintains its own `last_seen_offset`. `readSince(_ last:
  UInt64) -> (bytes: [UInt8], newOffset: UInt64, overflowed: Bool)`.
  Reports `overflowed=true` when `current - last > capacity` (the
  writer lapped the reader; this is a signal to drop to a clean state,
  not an error).

Counters and heartbeat live in a 128-byte block between the file header
and the ring payload, sized to two cache lines (hot and cold). Phase 1
subset of counters:

```
hot:  output_write_offset / output_bytes_written_total (one counter,
                                                       same value)
      output_writes_total
      output_wrap_count
      producer_alive_mono_ns
cold: attached_consumer_count
      ring_overflow_observed_total
      master_read_calls_total
      master_read_eagain_total
```

`producer_alive_mono_ns` is updated by `labpty` on every event-loop
tick capped at 100 ms cadence. Stale by >300 ms is a "labpty hung"
signal to readers.

Wire the writer into `labpty`'s master drain: each chunk read from the
PTY master goes into `Session.feedOutput`-equivalent (still owned by
`labpty`'s libghostty session — `labpty` keeps a libghostty session per
PTY only to avoid blocking the child, and to keep the existing capture
hooks working; it does **not** publish parsed snapshots) **and** into
the byte-ring writer.

> **Open design tension.** Does `labpty` keep a `LabanCore.Session`
> per PTY just for the drain mechanics, or does it drop libghostty
> entirely and call `read(2)` itself? The simpler answer for Phase 1
> is "drop libghostty; `labpty` is a byte-mover." The reason to keep
> it is that the existing `SessionRunner` + `laban_session_poll_blocking`
> path is debugged and the PTY-byte capture callbacks
> (`laban_session_capture_*`) are useful for diagnostics. The Phase 1
> decision (see Decision Log) is to keep `LabanCore.Session` in
> `labpty` for the drain only, with the parser side unused — this
> minimizes new C code, preserves capture hooks, and keeps fixture
> mode irrelevant. Phase 3's `labpty` will likely shed libghostty
> entirely.

Update `attachSession` to return the byte-ring shm path in the JSON
response. **The response does not include a master fd.** Phase 1's
`attachSession` is a metadata RPC, not an fd-handoff RPC.

Tests in `Tests/LabptyTests/`:

- `testByteRingHeaderAndCapacity` — open the ring file, validate magic,
  abi version, capacity is power-of-two, offsets fit.
- `testByteRingRoundTripSmall` — writer writes 1 KiB, reader reads
  1 KiB, bytes identical.
- `testByteRingWrapDetection` — capacity = 1 KiB, write 2 KiB across
  the wrap, reader's first call sees expected bytes, second call sees
  `overflowed=false`; reset reader to old offset, observe
  `overflowed=true`.
- `testProducerAliveHeartbeat` — open a session, sample
  `producer_alive_mono_ns` twice with 150 ms between samples, observe
  monotonic increase.

### M3 — Parser-only `laband` session path

No new C ABI is required (see `Surprises & Discoveries`). M3 confirms
this with a focused test and adds a thin Swift helper.

Files:

- (Optional) `Sources/LabanCore/Session+ParserOnly.swift` (new). Adds
  `Session.parserOnly(size:) throws -> Session` that calls
  `Session.fixture(size:)` and is named to make intent explicit. If
  this is judged unnecessary ergonomics, skip it and have `laband`
  call `Session.fixture(size:)` directly with a comment explaining
  why (parser-only, no PTY, fed from labpty's byte ring).

Tests in `Tests/LabanCoreTests/`:

- `testParserOnlySessionMatchesRealPtySnapshotForRecordedStream`
  (new). Replay a recorded byte stream (e.g., from `fixtures/` if a
  representative one exists; otherwise capture one as part of this
  milestone using `laban_session_capture_start`) into two sessions —
  one real-shell session that produced the bytes, one parser-only
  session fed via `feedOutput` — and assert their
  `laban_session_snapshot` outputs are byte-equal cell-for-cell after
  the same input.

  This test is the proof that the parser-only path Phase 1 will rely
  on is observationally equivalent to today's drain path for the
  semantic content `laband` exposes to clients.

### M4 — `laband` as `labpty` client

This is the largest milestone. It refactors `Sources/Laband/main.swift`
so that `ManagedLabandSession` no longer holds a PTY-owning `Session`,
and adds the ring-reader loop that feeds a parser-only `Session`.

`Sources/Laband/main.swift` adds a required CLI flag `--labpty-socket
<path>`: the absolute path to `labpty`'s control socket. There is no
default; `laband` exits with a non-zero status if the flag is absent or
the socket cannot be connected at startup (Phase 1's design assumes
`labpty` is started first per `Concrete Steps`). The new
`LabandDaemon` initializer takes the socket path and opens a
`LabptyTerminalSessionClient` against it; the daemon exits if `hello`
fails.

`ManagedLabandSession` after M4:

```
private final class ManagedLabandSession {
  let logicalSessionId: String
  let labptyHandle: String              // assigned by labpty
  var childPid: Int                      // copied from labpty
  var rows: Int
  var cols: Int
  var session: Session?                  // parser-only, no PTY
  var byteRingReader: LabptyByteRingReader?
  var ringReaderTask: Task<Void, Never>?  // or DispatchSourceRead-equivalent
  var ringWriter: LabandSnapshotRingWriter?  // unchanged; LBNDSS01
  var lease: LabandLeaseInfo?
  // (other existing fields preserved)
}
```

Session lifecycle changes inside `LabandDaemon`:

- `handleCreateSession`: replace the `Session.realShell(...)` call (line
  451) with `labptyClient.openSession(...)`. The returned descriptor
  carries `ptyHandle`, `child_pid`, `rows`, `cols`, `byteRingShmPath`.
  Allocate a parser-only `Session` via `Session.fixture(size:)`. Open
  the byte ring via `LabptyByteRingReader(path:)`. Start the
  ring-reader loop.

- Ring-reader loop (one per session): blocks on a per-reader wake (Phase
  1: poll every 4 ms or use a `DispatchSourceRead` on a kqueue user
  event registered with `labpty`; preferred minimum for Phase 1 is a
  short-poll loop on a dedicated thread, identical in shape to today's
  `SessionRunner` but reading from the ring instead of a master fd).
  Each iteration:
  1. `readSince(lastSeenOffset)` → bytes + new offset + overflowed
     flag.
  2. If `overflowed`, drop to a clean state (set
     `lastSeenOffset = newOffset`, optionally request the opaque
     snapshot cache when that capability ships in Phase 2 — Phase 1
     just resyncs forward).
  3. `session.feedOutput(bytes)` to drive the parser.
  4. `markDirty()` so the existing snapshot-publish path
     (`ringWriter.publish(...)` already in `main.swift` at line 311)
     runs on the next tick.

- `handleResize`, `handleSignal`, `handleTerminate`: route to
  `labptyClient.resizeSession`, `signalSession`, `terminateSession`.
  Update local `rows`/`cols`/state. The local parser-only `Session`
  also receives `resize(size:)` so its parser grid matches.

- `handleWriteInput` / `handleWritePaste`: route to
  `labptyClient.writeInput(handle, bytes)`. **Never** write to a master
  fd from `laband`.

- `handleListSessions` (the app-facing `LabandRequestType.listSessions`)
  is unchanged externally. Internally it consults the `sessions` map
  the same way as today.

App-facing protocol surface:

- `LabandRequest`, `LabandResponse`, `LabandSessionInfo`,
  `LabandSnapshotResponse` are all **unchanged**.
- `LabandTerminalSessionClient` (in `LabanApp` and `LabanCore`) is
  **unchanged**.

### M5 — `laband` restart survival (acceptance)

The test scenario keeps `labpty` running continuously and restarts only
`laband`. `labpty`'s control socket, shm directory, and live PTY
sessions persist across the restart; the new `laband` process connects
to the same `labpty` socket and reattaches the same byte rings. If both
processes are restarted, the test does not exercise Phase 1's value;
that scenario is Phase 3's responsibility.

Add `Tests/LabandTests/LabandRestartSurvivalTests.swift`:

- `testLabandRestartPreservesChildViaLabpty`:
  1. Build the test harness that launches `labpty` (with run-id-scoped
     socket and shm dir) **once for the whole test**, then `laband`
     (with run-id-scoped journal, pointed at labpty's socket via
     `--labpty-socket`).
  2. Connect a `LabandTerminalSessionClient`, call `createSession`
     with `/bin/sh -c 'printf STARTED; while read x; do echo
     "got $x"; done'`.
  3. Record `child_pid` from `listSessions` (which surfaces the
     labpty-supplied pid; verify > 0).
  4. Call `writeInput("ping\n")`. Read the next snapshot. Assert the
     visible text contains `STARTED` and `got ping`.
  5. `SIGTERM` `laband`. Wait for it to exit. **Leave `labpty`
     running** — it is the survivor, not the casualty.
  6. Relaunch `laband` (same socket, journal, `--labpty-socket`
     pointing at the still-running `labpty`).
  7. Reconnect a fresh client. Call `listSessions`. Assert there is a
     session with the same logical id; record its `child_pid`.
  8. Assert the new `child_pid` equals the original.
  9. Verify the child process is alive via `kill(pid, 0)`.
 10. Call `writeInput("pong\n")`. Read the next snapshot. Assert the
     visible text grows to contain `got pong`.

Add `scripts/test-labpty-survives-laband-restart`:

A shell script that runs the same scenario interactively for local
verification:

```
#!/bin/sh
set -eu
RUN_ID=$(date +%Y%m%d-%H%M%S)
TMP=.tmp/$RUN_ID
mkdir -p "$TMP/labpty" "$TMP/laband"
swift build --product labpty --product laband
.build/debug/labpty --socket "$TMP/labpty/s.sock" --shm-dir "$TMP/labpty" &
LABPTY_PID=$!
.build/debug/laband \
  --socket "$TMP/laband/s.sock" \
  --journal "$TMP/laband/journal" \
  --labpty-socket "$TMP/labpty/s.sock" &
LABAND_PID=$!
trap 'kill $LABAND_PID $LABPTY_PID 2>/dev/null; rm -rf "$TMP"' EXIT
# ... drive the scenario, assert child pid survives laband restart.
```

### M6 — Packaging and run orchestration

- `scripts/build-app` (existing) is updated to compile and bundle
  `labpty` alongside `laband` and `LabanApp`. The bundle layout adds
  `Contents/MacOS/labpty`. Ad-hoc signing applied to all three
  binaries.
- Dev/test launch order: `labpty` first, then `laband` (which connects
  to labpty's socket on startup). Documented in this plan and in
  `scripts/test-labpty-survives-laband-restart`. Production launch
  order (LaunchAgent ordering) is deferred to a separate plan;
  per-user LaunchAgents are not in Phase 1's scope.
- First-migration caveat: documented in `Purpose / Big Picture` of
  this plan and surfaced in `docs/product/spec.md` only if a future
  scope-change ExecPlan requires it. Phase 1 does not edit
  `docs/product/spec.md` or `docs/product/mvp.md`.

## Concrete Steps

All commands run from the repo root.

```
# Build the new labpty executable in isolation.
swift build --product labpty

# Build everything (includes labpty + laband + app).
./scripts/build-app

# Phase 1 unit tests.
swift test --filter LabptyTests
swift test --filter LabanCoreTests.testParserOnlySessionMatchesRealPtySnapshotForRecordedStream

# Phase 1 daemon integration tests.
swift test --filter LabandTests

# Phase 1 headline acceptance.
swift test --filter LabandTests.testLabandRestartPreservesChildViaLabpty

# Interactive acceptance for local sanity.
./scripts/test-labpty-survives-laband-restart
```

Expected transcript for the headline test:

```
Test Case 'testLabandRestartPreservesChildViaLabpty' started.
[harness] launched labpty pid=NNN socket=.tmp/<run-id>/labpty/s.sock
[harness] launched laband pid=MMM socket=.tmp/<run-id>/laband/s.sock
[client] createSession sh -c '...'  -> logicalSessionId=L1, child_pid=KKK
[client] listSessions               -> 1 session, child_pid=KKK, state=running
[client] writeInput "ping\n"        -> ok
[client] snapshot contains          "STARTED" and "got ping"
[harness] SIGTERM laband (pid MMM); wait for exit
[harness] relaunched laband pid=MMM' against the same labpty
[client] listSessions               -> 1 session, child_pid=KKK, state=running
[assert] kill(KKK, 0)               == 0 (alive)
[client] writeInput "pong\n"        -> ok
[client] snapshot contains          "got pong"
Test Case 'testLabandRestartPreservesChildViaLabpty' passed (X.XX seconds)
```

## Validation and Acceptance

Each milestone gates on observable behavior, not types or compilation.

**M0:** `swift test --filter LabptyTests.testLabptyProtocolRoundTrip`
and `testByteRingHeaderConstants` exit 0. Both compile against the new
files in `Sources/LabanCore/`.

**M1:** `swift test --filter
LabptyTests.testOpenAndListAndTerminate` exits 0. The test launches
the real `labpty` binary under `.tmp/<run-id>/`, opens a child running
`/bin/sh`, asserts `child_pid > 0` and the pid is alive via `kill(pid,
0)`, terminates, asserts `kill(pid, 0)` returns -1.

**M2:**

- `testByteRingHeaderAndCapacity`, `testByteRingRoundTripSmall`,
  `testByteRingWrapDetection`, `testProducerAliveHeartbeat` all pass.
- A manual sanity step: launch `labpty`, open a session running
  `printf foo; sleep 30`, attach the ring with a small test client,
  observe `foo` appears in the readout.

**M3:**

- `testParserOnlySessionMatchesRealPtySnapshotForRecordedStream`
  passes. This is the proof that the path Phase 1 substitutes for the
  current real-PTY drain is functionally equivalent for `laband`'s
  needs.

**M4:** All existing `LabandTests` continue to pass without
modification, except for harness updates that launch `labpty` before
`laband` and pass `--labpty-socket`. **No app-facing protocol change.**
Manual verification: run the app against the new stack; create tabs,
type, resize — should be behaviorally identical to pre-refactor.

**M5 (headline):** `testLabandRestartPreservesChildViaLabpty` passes.
The same `child_pid` survives `laband` restart, and a fresh client
after restart can drive input/output. This is the single test that
proves Phase 1 delivers the value it promises.

**M6:** `./scripts/build-app` succeeds. The resulting
`.build/laban/Laban.app` bundle contains
`Contents/MacOS/labpty`, `Contents/MacOS/laband`, and
`Contents/MacOS/LabanApp`. `./scripts/test-labpty-survives-laband-restart`
exits 0.

## Idempotence and Recovery

All steps are additive within `Sources/Labpty/`,
`Sources/LabanCore/Labpty*.swift`, and `Tests/LabptyTests/`. The
`Sources/Laband/main.swift` refactor in M4 is the only edit that
changes existing behavior; if it breaks something mid-way, revert that
single file and the daemon continues to work as today (since `labpty`
is a separate process that can simply be ignored by `laband` if the
refactor is rolled back).

Sockets, byte-ring shm files, and the (optional) diagnostic catalog
all live under run-id-scoped paths. Re-running tests cleans them up.
There is no machine-wide state to migrate.

If a test leaves processes running (a hung `labpty` or `laband`),
`pkill -f '/labpty --socket .tmp/'` and `pkill -f '/laband --socket
.tmp/'` clean up; the test harness should also do this in its
`tearDown`.

## Interfaces and Dependencies

### `LabptyProtocol` (new — `Sources/LabanCore/LabptyProtocol.swift`)

The Phase 1 subset of `execplans/active/labpty-protocol-design.md`. JSON
over length-prefixed Unix `SOCK_STREAM`. Capability negotiation at
`hello`; sequence numbers and deadlines on every request.

```swift
public struct LabptyHelloRequest: Codable, Sendable {
  public var clientId: String?
}

public struct LabptyHelloResponse: Codable, Sendable {
  public var protocolVersion: Int
  public var capabilities: [String]
  // Phase 1 capabilities: "byte-ring/v1", "writeInput-control/v1",
  // "session-id-pinning/v1", "heartbeat-shm/v1"
}

public struct LabptyOpenSessionRequest: Codable, Sendable {
  public var argv: [String]
  public var envp: [String: String]?
  public var cwd: String
  public var rows: Int
  public var cols: Int
  public var logicalSessionId: String?
}

public struct LabptySessionDescriptor: Codable, Sendable {
  public var ptyHandle: String
  public var logicalSessionId: String?
  public var childPid: Int
  public var rows: Int
  public var cols: Int
  public var alive: Bool
  public var openedAtMonoNs: UInt64
  public var byteRingShmPath: String
  /// Foreground-process metadata polled by `labpty` from the PTY's
  /// `tcgetpgrp` + libproc. `nil` when nothing useful is known yet.
  /// `laband` forwards these into `LabandSessionInfo.foreground*`
  /// fields, which the app's `TabMetadataSynchronizer` consumes for
  /// tab titles. Without this carry-over, the tab-title fix in
  /// `Sources/LabanApp/AppLabandSessionCoordinator.swift` regresses
  /// because `laband`'s parser-only `Session.processMetadata()`
  /// returns `nil` (it has no PTY).
  public var foregroundPid: Int?
  public var foregroundProcess: String?
  public var foregroundCommand: String?
  public var foregroundArguments: [String]?
  public var foregroundCwd: String?
}

public struct LabptyAttachRequest: Codable, Sendable {
  public var ptyHandle: String
}

public struct LabptyAttachResponse: Codable, Sendable {
  public var session: LabptySessionDescriptor
  // byteRingShmPath is on the descriptor.
  // NO master_fd. SCM_RIGHTS is not used in Phase 1.
}

public struct LabptyListSessionsResponse: Codable, Sendable {
  public var sessions: [LabptySessionDescriptor]
}

public struct LabptyResizeRequest: Codable, Sendable {
  public var ptyHandle: String
  public var rows: Int
  public var cols: Int
}

public struct LabptySignalRequest: Codable, Sendable {
  public var ptyHandle: String
  public var signal: Int
}

public struct LabptyTerminateRequest: Codable, Sendable {
  public var ptyHandle: String
  public var gracePeriodMs: Int?
}

public struct LabptyWriteInputRequest: Codable, Sendable {
  public var ptyHandle: String
  /// Raw input bytes, base64-encoded for JSON safety. Bounded to 64 KiB
  /// per request; clients chunk larger payloads (e.g., paste).
  public var bytesBase64: String
  public var leaseToken: String?
}

public enum LabptyErrorCode: String, Codable, Sendable {
  case ok
  case sessionNotFound
  case sessionIdInUse
  case ptyOpenFailed
  case ringMapFailed
  case deadlineExceeded
  case capabilityRequired
  case versionMismatch
  case permissionDenied
  case payloadTooLarge
  case internalError
  case shuttingDown
}
```

Phase 1 input is base64-in-JSON. The rationale (see Decision Log) is
that keystroke throughput is bounded by user typing; the base64 overhead
is invisible against the JSON+socket round-trip cost. Phase 2 may
upgrade to a binary length-prefixed frame or to the
`LBPTY-IR-01` shared-memory input ring if measurement shows
perceptible keystroke latency.

### `LabptyByteRingLayout` (new — `Sources/LabanCore/LabptyByteRingLayout.swift`)

Phase 1 subset of `execplans/active/labpty-protocol-design.md` (lock-free
monotonic-offset ring). Field names and offsets match the design doc
exactly so Phase 2 and Phase 3 inherit a frozen-able ABI.

```swift
public enum LabptyByteRingLayout {
  public static let magic: [UInt8] = Array("LBPTY-BR".utf8)
  public static let abiMajor: UInt32 = 1
  public static let abiMinor: UInt32 = 0
  public static let headerBytes: UInt32 = 128
  public static let countersOffset: UInt64 = 128
  public static let countersBytes: UInt32 = 128
  public static let outputRingOffset: UInt64 = 256

  // Counters block layout matches
  // `execplans/active/labpty-protocol-design.md` byte-for-byte so the
  // Phase 1 subset and the Phase 2 input-ring expansion share one
  // frozen ABI. Slots Phase 1 does not yet populate are reserved at
  // their final offsets and stay zero until Phase 2 (input ring)
  // wires them up.
  public enum CountersOffset {
    // Hot cache line (offset 128).
    public static let outputWriteOffset: UInt64 = 128  // a.k.a.
    //                                          output_bytes_written_total
    public static let outputWritesTotal: UInt64 = 136
    public static let outputWrapCount: UInt64 = 144
    public static let outputWakeNotificationsTotal: UInt64 = 152
    public static let producerAliveMonoNs: UInt64 = 160
    // Bytes 168-191: reserved, padding to second cache line.

    // Cold cache line (offset 192).
    public static let inputBytesConsumedTotal: UInt64 = 192   // Phase 2
    public static let inputWritesBlockedTotal: UInt64 = 200   // Phase 2
    public static let masterReadCallsTotal: UInt64 = 208
    public static let masterReadEagainTotal: UInt64 = 216
    public static let ringOverflowObservedTotal: UInt64 = 224
    public static let attachedConsumerCount: UInt64 = 232
    public static let lastAttachMonoNs: UInt64 = 240
    // Bytes 248-255: reserved, padding to 256.
  }

  /// Default per-session output capacity, in bytes. Must be a power of
  /// two. Configurable at openSession in a later phase; Phase 1 ships
  /// the default only.
  public static let defaultOutputCapacityBytes: Int = 8 * 1024 * 1024
}

public final class LabptyByteRingWriter {
  public init(path: String, sessionId: String, capacity: Int) throws
  public func write(_ bytes: UnsafeBufferPointer<UInt8>)
  public func updateHeartbeat(monoNs: UInt64)
  public func close()
}

public final class LabptyByteRingReader {
  public init(path: String) throws
  public var capacity: Int { get }
  public func currentOffset() -> UInt64
  public func producerAliveMonoNs() -> UInt64

  /// Returns the bytes written since `lastSeenOffset`, the new
  /// offset, and whether the writer lapped the reader (overflowed).
  /// On overflow, the reader's logical state is "current"; missed
  /// bytes are unrecoverable from this ring.
  public func readSince(_ lastSeenOffset: UInt64)
    -> (bytes: [UInt8], newOffset: UInt64, overflowed: Bool)

  public func close()
}
```

Phase 1 omits the input ring (`LBPTY-IR-01`), the metadata ring, and
the opaque-snapshot-cache region. They are reserved-but-absent in the
header (offsets present, capacities zero). This keeps the layout stable
for Phase 2 to fill in.

### `LabptyTerminalSessionClient` (new)

Located in `Sources/LabanCore/LabptyTerminalSessionClient.swift`.
Mirrors `LabandTerminalSessionClient` in shape: open a socket, send
JSON, parse responses. Used **only** by `laband` in Phase 1; `LabanApp`
must not import this type (enforced by the Review Gate).

### `Sources/Labpty/main.swift` (new)

Process entry. Argument parsing for `--socket`, `--shm-dir`, optional
`--run-id`. Unix-socket listener. Single-threaded event loop dispatching
RPCs and per-session master-drain ticks. Each session is added to the
in-memory `LabptySessionRegistry` and gets a `LabptyByteRingWriter`
backed by a file under `--shm-dir`.

PTY ownership notes (preserves ADR 0002 inside `labpty`):

- `Session.realShell(...)` performs the parent-side `openpty` + child
  fork inside `LabanTerminalCore`. `labpty` calls it directly; ADR
  0002 invariants are inherited mechanically.
- `Session.close()` performs the master-close + pgrp escalation
  teardown. `labpty.terminateSession` calls it.

### `Session.parserOnly` (optional — `Sources/LabanCore/Session+ParserOnly.swift`)

```swift
extension Session {
  /// Construct a libghostty session with no PTY underneath. Bytes are
  /// fed into the parser via `feedOutput(_:)`; intended for laband's
  /// ring-reader loop, which sources bytes from labpty's byte ring.
  /// Equivalent to `Session.fixture(size:)` today; named separately so
  /// the call site documents intent.
  public static func parserOnly(size: LabanTerminalSize) throws -> Session {
    try .fixture(size: size)
  }
}
```

Optional; the underlying `Session.fixture(size:)` already exists. The
helper exists only so a grep for "parser-only attach" finds the laband
call sites.

### Module dependencies

- `Labpty` (new executable) depends on `LabanTerminalCore` and
  `LabanCore`.
- `LabanCore` gains `LabptyProtocol.swift`, `LabptyByteRingLayout.swift`,
  `LabptyByteRingWriter.swift`, `LabptyByteRingReader.swift`,
  `LabptyTerminalSessionClient.swift`, and (optionally)
  `Session+ParserOnly.swift`.
- `Laband` gains a `LabptyTerminalSessionClient` field used during
  session open/attach/resize/signal/terminate/writeInput.
- `LabanApp` **does not** depend on `Labpty*` types in Phase 1. The
  Review Gate enforces this with a grep.

## Decision Log

- Decision: `labpty` is the sole steady-state reader/writer of every
  PTY master fd. `laband` consumes the byte ring; `laband` does not
  hold a master fd in normal operation.
  Rationale: Two processes blocked on `read(2)` of the same PTY master
  race for individual bytes — POSIX makes no per-byte fairness or
  atomicity guarantee, and on macOS we have observed `read(2)` returning
  partial chunks to one reader while the other was scheduled. Two
  writers can interleave at sub-write granularity. There is no portable
  arbiter at the kernel level; the only safe shape is one custodian.
  An earlier draft of this plan (and the surface-list bullet in ADR
  0006) proposed `attachSession` returning the master fd via
  `SCM_RIGHTS`. That is reserved for Phase 3 fd-handoff (labpty
  self-upgrade), not for normal `laband` attach. The Review Gate
  forbids master-fd handoff in Phase 1's attach path.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: First-migration accepts loss of pre-`labpty`-owned
  sessions.
  Rationale: A migration that transfers already-open PTY master fds
  from an old `laband` into a new `labpty` would require either an
  intermediate handoff process or a deliberately staged restart where
  old `laband` exec's a hand-rolled fd-passer. Both are weeks of work
  for a one-time event. Accepting one upgrade-time session loss for
  the labpty-introducing build is cheap and unambiguous. Every
  session created from that point forward inherits Phase 1's restart
  survival.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: Phase 1 input is a JSON `writeInput` control RPC with
  base64 bytes; Phase 2 may upgrade to a shared-memory input ring.
  Rationale: The shared-memory `LBPTY-IR-01` design in
  `execplans/active/labpty-protocol-design.md` is the right
  long-term shape, but it adds non-trivial implementation (SPSC
  ring, eventfd/kqueue wakes, counters, backpressure) for a path
  whose Phase 1 latency budget is dominated by the existing
  app↔laband JSON socket. Measure first in Phase 2; only build the
  input ring if the measurement shows perceptible cost.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: Phase 1 byte ring is the lock-free monotonic
  write-offset design from `execplans/active/labpty-protocol-design.md`,
  not the seqlock-slot pattern an earlier draft proposed.
  Rationale: A monotonic offset with one release/acquire pair is
  strictly simpler and strictly faster than a seqlock slot for the
  single-producer/multi-reader case. The seqlock pattern matters
  when readers need to read a record-shaped state safely under
  concurrent writes; a byte stream's "record" is just a position,
  which a single 64-bit atomic represents fully. The earlier
  seqlock language in the plan was carried over from the `LBNDSS01`
  parsed-snapshot ring (where it is correct for cell records) and
  did not survive scrutiny.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: `labpty.listSessions` is mandatory in Phase 1 even though
  a persisted catalog is not.
  Rationale: After `laband` restart, `laband` has no in-memory map of
  which `labpty` sessions belong to it. `listSessions` is the
  discovery mechanism that makes the headline acceptance test
  possible. The on-disk catalog (`.artifacts/runs/<run-id>/labpty
  /catalog.json`) is diagnostic-only in Phase 1; it is **not** read
  on `labpty` startup because Phase 1 explicitly does not promise
  `labpty` restart survival (Phase 3 does, via fd handoff).
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: `labpty` calls `openpty` + constrained fork + `execve`
  directly and registers each master fd with its own single-threaded
  kqueue event loop. It does **not** wrap each PTY in a
  `LabanCore.Session` and does **not** use
  `laban_session_poll_blocking` / `SessionRunner` for the drain.
  Rationale: An earlier draft of this plan kept a
  `LabanCore.Session` per PTY for "drain mechanics," intending to
  reuse the debugged `Session.realShell` launch and the
  `SessionRunner` drain thread. That conflicts with the protocol
  design's single-threaded event-loop discipline
  (`execplans/active/labpty-protocol-design.md` Execution model):
  `SessionRunner` is per-session-threaded by construction
  (`Sources/LabanCore/SessionRunner.swift`), which would force
  per-session locks in `labpty` and break the no-locks-on-hot-path
  axiom. The architecturally consistent choice is for `labpty` to
  own raw master fds and register them all with one kqueue.
  Implementation can pick between (a) a new minimal C entry point
  `laban_pty_open(rows, cols, argv, envp, cwd, &master_fd, &child_pid)`
  that performs only the ADR 0002 launch (parent-side `openpty`,
  initial winsize before child, constrained fork child branch,
  parent-only master fd retained, teardown via process-group
  escalation) without constructing a libghostty session, or (b)
  reusing `Session.realShell` internally and extracting the master
  fd via a new `laban_session_master_fd(session) -> int` accessor
  while never calling `laban_session_poll`/`poll_blocking` on that
  session. Option (a) is cleaner and is the recommended path; option
  (b) is acceptable if the focused C extraction proves more
  intrusive than expected. Either way the ADR 0002 invariants are
  preserved.
  Date/Author: 2026-05-26 / review iteration after protocol-design
  alignment.

- Decision: Phase 1 does not amend ADR 0006.
  Rationale: ADR 0006's body is consistent with this plan ("laband
  becomes a labpty client internally; libghostty still runs inside
  laband but is fed from the byte ring rather than from a directly-
  owned master"). The "labpty surface" bullet list at the top of
  ADR 0006 lists `attachSession(ptyHandle) → master_fd via
  SCM_RIGHTS, …` which reads as a steady-state design but is, on
  closer inspection, only consistent with the body if interpreted as
  a future-only flow (Phase 3 self-upgrade). Rather than amend the
  ADR for one interpretive bullet, this plan records the resolution
  in `Surprises & Discoveries` and binds Phase 1 to "no master fd
  in attachSession." If a future reader of ADR 0006 trips over the
  bullet, the right next step is a narrow ADR edit, not a plan-level
  workaround.
  Date/Author: 2026-05-26 / Phase 1 author.

## Surprises & Discoveries

- Observation: The parser-only feed path Phase 1 needs already exists
  end-to-end.
  Evidence: `Sources/LabanTerminalCore/include/LabanTerminalCore.h:223`
  declares `int laban_session_feed_output(LabanSession *session,
  const uint8_t *bytes, size_t len)` which "feeds bytes directly
  into the VT parser (ghostty_terminal_vt_write) in both fixture and
  PTY modes." The Swift wrapper is `Session.feedOutput(_:)` at
  `Sources/LabanCore/Session.swift:407`. Existing tests
  (`Tests/LabanCoreTests/CaptureSessionBridgeTests.swift:18`,
  `Tests/LabanCoreTests/RecentByteRingIntegrationTests.swift:30`)
  exercise it on fixture sessions. M3 collapses to "compose existing
  pieces"; no new C ABI is required for parser-only operation.

- Observation: ADR 0006's labpty surface lists `attachSession →
  master_fd via SCM_RIGHTS` even though its body says `laband` is fed
  from the byte ring rather than a directly-owned master.
  Evidence: `docs/adr/0006-three-tier-session-architecture.md` line
  152 vs lines 225-229. This plan resolves the tension toward the
  body — no master fd in Phase 1's `attachSession` — and records the
  resolution in the Decision Log. A future ADR edit may reconcile
  the surface-list bullet directly.

- Observation: `Sources/LabanTerminalCore/session_lifecycle.c` already
  has `fixture_mode` (line 183, 212, 312) that skips PTY creation
  while keeping libghostty parser state. The C-side support for
  "parser without PTY" is plumbed through every relevant subsystem
  (capture callbacks, theme injection via `feedOutput`, process
  metadata returning nil — see the recent fixture-mode change in
  `Sources/LabanCore/Session.swift:547`). The Phase 1 parser-only
  Session is the existing fixture mode, just used at a different
  call site.

## Review Gate

A separate fresh-state agent must verify the following before this plan
is considered complete. The executing agent must not mark the plan as
done until this gate has passed. See the "Review gate and review-fix
loop" section in `PLANS.md` for the full process.

The checks are deliberately mechanical so a fresh agent can run them
without judgment.

### Build and tests

- [ ] `swift build --product labpty` exits 0.
- [ ] `swift test --filter LabptyTests` exits 0.
- [ ] `swift test --filter LabandTests` exits 0.
- [ ] `swift test --filter
  LabandTests.testLabandRestartPreservesChildViaLabpty` exits 0, and
  the test transcript shows: (a) the same `child_pid` before and after
  `laband` restart; (b) `writeInput` issued before restart produced
  observable output; (c) `writeInput` issued after restart produced
  fresh observable output from the same child.
- [ ] `./scripts/build-app` exits 0 and the bundle at
  `.build/laban/Laban.app/Contents/MacOS/` contains `labpty`,
  `laband`, and `LabanApp`.

### Invariants (mechanical greps)

- [ ] `git grep -n '\bSession\.realShell\b' Sources/Laband/main.swift`
  returns zero hits. (PTY launch moved into `labpty`.)
- [ ] `git grep -n 'laban_session_poll_blocking' Sources/Laband/`
  returns zero hits. (Master-drain loop moved into `labpty`.)
- [ ] `git grep -nE 'SCM_RIGHTS|sendmsg|cmsghdr' Sources/Laband/
  Sources/LabanCore/LabptyTerminalSessionClient.swift` returns zero
  hits. (No master-fd handoff in Phase 1's normal attach path. Any
  hit must be in code paths clearly labeled "Phase 3" or "labpty
  self-upgrade".)
- [ ] `git grep -n 'LabptyTerminalSessionClient' Sources/LabanApp/`
  returns zero hits. (The app does not depend on labpty in Phase 1.)
- [ ] `git grep -n 'LabptyTerminalSessionClient' Sources/Laband/`
  returns at least one hit. (laband uses it internally.)
- [ ] `git grep -n 'Session.fixture\|Session.parserOnly'
  Sources/Laband/main.swift` returns at least one hit, and the
  surrounding code is the ring-reader loop that constructs a
  parser-only session to feed bytes from `labpty`'s byte ring.

### Byte-ring sanity

- [ ] In a one-shot test (can be the existing
  `testByteRingWrapDetection`): writing 2× capacity worth of bytes
  through `LabptyByteRingWriter` and reading them through
  `LabptyByteRingReader` produces an `overflowed=true` signal on the
  reader that did not keep up. No torn reads (no spurious extra
  bytes, no truncated tail).
- [ ] `producer_alive_mono_ns` advances by more than 50 ms when
  sampled 150 ms apart against a session whose `labpty` is healthy.

### High-volume drain (catches accidental dual-readers)

- [ ] Add a test `testHighVolumeOutputIsNotSplitOrLost` that runs
  `/bin/sh -c 'for i in $(seq 1 100000); do printf "line-%06d\n" $i;
  done'` against the new stack and asserts the resulting byte stream
  on `labpty`'s byte ring contains every `line-NNNNNN` from
  `line-000001` to `line-100000` in order with no duplicates and no
  gaps. Assert at the byte-ring layer, **not** at the parsed snapshot
  — the dual-reader race manifests as missing or duplicated bytes in
  the ring; assertions against the rendered snapshot would let parser
  policy (line wrapping, scrollback truncation) mask or amplify the
  signal. Use `LabptyByteRingReader` with capacity sized so the full
  ~1.4 MiB stream fits without wrapping (a 2 MiB or 4 MiB ring works);
  if the producer wraps anyway, the test fails with a clear "ring
  overflowed; widen capacity" message rather than misreporting as a
  byte-loss bug.

### Cleanup

- [ ] No `labpty` or `laband` processes remain after the test suite
  exits (`pgrep -f '/labpty --socket .tmp/'` and `pgrep -f '/laband
  --socket .tmp/'` return empty).
- [ ] No leftover shm files under `.tmp/<run-id>/labpty/` after tests
  pass.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)
