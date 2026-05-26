# Extract `labpty` from `laband`

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then deliver the milestones below end-to-end.

## Purpose / Big Picture

Today, the `laband` daemon owns the PTY master fd, runs `libghostty-vt`,
maintains scrollback, publishes the snapshot ring, manages leases, writes
the lifecycle journal, and forks user child processes. Every change to
`laband` — a libghostty bump, a new theme behavior, a fix like
`execplans/active/background-session-regressions.md` M2 — requires
restarting the daemon, which closes the PTY master and kills the user's
live shells via SIGHUP. The "live sessions survive app upgrade" promise
of ADR 0005 therefore has a hole: it doesn't survive `laband`'s own
upgrades.

After this work, the kernel-level part of session ownership (PTY master,
child process group, raw byte buffer) lives in a separate, deliberately
minimal binary named `labpty`. `laband` becomes a `labpty` client
internally and continues to expose its existing protocol to the app
unchanged. The user-visible test of success: kill `laband` mid-session,
let it restart, watch a running Claude Code conversation continue without
SIGHUP.

This is Phase 1 of the three-tier session architecture decided in
`docs/adr/0006-three-tier-session-architecture.md`. Phase 2 (single-client
byte-ring mode in `laband`) and Phase 3 (`labpty` fd-handoff for
self-upgrades) are separate ExecPlans that build on this one. Phase 1
ships zero user-visible change; the value lands in Phase 2.

## Progress

- [ ] M0: Wire-protocol and byte-ring shapes for `labpty`. A short design
  note in this file (under "Interfaces and Dependencies") and a Swift
  module sketch for the RPC types.
- [ ] M1: New `labpty` executable that owns PTYs and exposes the control
  RPCs (`hello`, `openSession`, `listSessions`, `resizeSession`,
  `signalSession`, `terminateSession`) over a Unix socket. No byte ring,
  no SCM_RIGHTS attach yet. Unit-test coverage that `labpty` forks a child
  and reports its `child_pid` correctly.
- [ ] M2: Shared-memory byte-ring layout (an LBNDSS01-shaped sibling
  format, named `LBPTYBR01` here) and a writer/reader pair. `labpty`
  drains the master into the ring with a seqlock-protected slot and a
  monotonic generation counter. Tested independently of `laband`.
- [ ] M3: `attachSession` returns the master fd via SCM_RIGHTS plus the
  shm path for the byte ring. A test attaches twice and proves both
  attachees can hold the master simultaneously without disrupting the
  child.
- [ ] M4: Refactor `Sources/Laband/main.swift` so its
  `ManagedLabandSession` no longer opens PTYs directly. PTY open and
  master ownership move to `labpty`; `laband` calls
  `labpty.openSession`/`attachSession`, holds the master via SCM_RIGHTS,
  drains it through libghostty as today, and updates the existing
  `LabandSnapshotRingWriter` (the parsed snapshot ring) for clients to
  consume. The app-facing `LabandTerminalSessionClient` contract is
  unchanged.
- [ ] M5: All existing tests pass against the refactored stack. New
  acceptance test: launch `labpty`, launch `laband` against it, create a
  session running `/bin/sh -c 'sleep 30'`, kill `laband`, restart
  `laband`, reattach, verify the same child PID is still alive and the
  session lifecycle journal reflects the continuity.
- [ ] M6 (optional in Phase 1, deferred otherwise): Mirror the existing
  laband journal patterns so `labpty` has a tiny session catalog that
  records `(ptyHandle, child_pid, rows, cols, openedAt)` and survives
  `labpty`'s own normal restart with the catalog readable (children are
  still dead because the master closed, but the catalog tells `laband`
  what happened).

## Context and Orientation

The reader needs the following landmarks. All paths are relative to the
repo root.

### Where laband currently owns PTYs

`Sources/Laband/main.swift` defines `ManagedLabandSession` (~line 190),
which holds:

- `session: Session?` — the `LabanCore.Session` wrapper around a
  libghostty-vt handle plus a PTY master fd.
- `runner: SessionRunner?` — drains the master into libghostty.
- `ringWriter: LabandSnapshotRingWriter?` — publishes parsed snapshots
  for the app to consume.

The PTY is opened by `Session.realShell(...)` inside `LabanCore` (which
delegates to `LabanTerminalCore` for the C-level `openpty` + fork
constrained child per ADR 0002). The master fd lives inside the libghostty
session opaque. There is currently no separate process that holds the
master; `laband`'s death closes it.

### Where the snapshot ring lives

`Sources/LabanCore/LabandSnapshotRingLayout.swift` defines the
`LBNDSS01` shared-memory layout: file header, slot headers with seqlock
protection, per-cell records, string table. `LabandSnapshotRingWriter`
publishes; `LabandSnapshotRingReader` consumes. This is the *parsed*
snapshot ring — cells, cursor, dirty ranges — used by the app's snapshot
generation monitor.

The new byte ring `labpty` introduces is a *different* shared-memory
artifact, with a much simpler layout: a circular buffer of raw PTY bytes
with a generation/write-offset counter, no per-cell structure. Reuse the
seqlock-protected-slot pattern but with byte payload.

### Where the control protocol lives

`Sources/LabanCore/LabandProtocol.swift` defines the JSON-shaped wire
protocol between `laband` and clients (`LabandRequest`,
`LabandResponse`, `LabandSessionInfo`, etc.).
`Sources/LabanCore/LabandTerminalSessionClient.swift` implements the
client side; `Sources/Laband/main.swift`'s daemon loop handles the server
side.

`labpty` introduces a *second* control protocol, distinct from
`LabandProtocol`. Despite the similarity in shape, keep them separate
types — `labpty`'s schema is meant to stay tiny and rarely change, while
`LabandProtocol` evolves with libghostty features. Create a new
`Sources/LabanCore/LabptyProtocol.swift` for the labpty types, and a new
`LabptyTerminalSessionClient.swift` for the client. Do not collapse them.

### Where tests for the daemon live

`Tests/LabandTests/LabandControlProtocolTests.swift` is the canonical
example of launching a real `laband` and exercising it end-to-end. The
new `Tests/LabptyTests/` directory should follow the same pattern: build
the binary, launch it under `.tmp/<run-id>/`, exercise the RPC, verify.

`scripts/test-laband-reattach` is an existing script that proves
reattach across `laband` restart. Update it (or write a sibling
`scripts/test-labpty-survives-laband-restart`) to assert the Phase 1
headline acceptance.

### Worktree isolation

Per `docs/process/worktree-isolation.md` and ADR 0005, all dev/test
sockets, journals, and shm files must be run-id-scoped. The existing
patterns in `LabandControlProtocolTests.swift` use `.tmp/<run-id>/` and
`.artifacts/runs/<run-id>/`. Apply the same to labpty's socket, byte-ring
shm files, and catalog file.

## Plan of Work

1. **M0 — Wire-protocol design.** Author the `LabptyProtocol.swift` types
   (`LabptyRequest`, `LabptyResponse`, the RPC payloads) and the
   `LBPTYBR01` byte-ring layout types. Both as Swift Codable structs in
   `LabanCore`. The byte-ring layout struct mirrors
   `LabandSnapshotRingLayout` but with byte payload and a single
   generation/write-offset/read-watermark trio per session.

2. **M1 — labpty executable skeleton.** Add a new SwiftPM executable
   target `Labpty` (sibling of `Laband` in `Package.swift`). Implement
   `Sources/Labpty/main.swift` with the Unix-socket server, the RPC
   dispatch, and the open/list/resize/signal/terminate operations. Open
   PTYs via `LabanTerminalCore` (the same code path `laband` uses today,
   preserving ADR 0002's launch invariants). Hold master fds in a
   per-process dictionary keyed by `ptyHandle`. No byte ring yet — read
   the master with a kqueue and discard the bytes; this is just to keep
   the child unblocked.

3. **M2 — Byte ring.** Add `LabptySnapshotByteRingWriter` and
   `LabptySnapshotByteRingReader` in `LabanCore`, sibling to the existing
   `LabandSnapshotRingWriter`/`Reader`. Layout in
   `LabanCore/LabptyByteRingLayout.swift`. The writer is held by `labpty`
   (per session); the reader is what `laband` (and, in Phase 2, the app)
   uses. Wire `labpty` to write each kqueue-drained chunk into the ring.
   Test the writer/reader pair in isolation.

4. **M3 — SCM_RIGHTS attach.** Extend `labpty.attachSession` to send a
   dup of the master fd via `sendmsg(SCM_RIGHTS)` over the connecting
   client's Unix socket, plus the byte-ring shm path in the JSON
   response. Add Swift wrappers for the `cmsghdr` plumbing (there may
   already be reusable code in `LabanTerminalCore`; check first).

5. **M4 — laband as labpty client.** In `Sources/Laband/main.swift`,
   replace direct `Session.realShell(...)` calls with
   `labptyClient.openSession(...)` + `labptyClient.attachSession(...)`.
   The libghostty session inside `LabanCore.Session` is rebuilt to read
   from the master fd labpty hands over. Drain loop, snapshot publish,
   theme apply, lease handling, journal — all remain in `laband`. The
   `ManagedLabandSession` no longer holds an owning PTY; it holds a
   `ptyHandle` plus the master fd duped from labpty.

   Detail: today `LabanCore.Session` opens the PTY internally via
   `Session.realShell`. After M4, introduce `Session.attaching(masterFd:,
   childPid:, size:)` (or similar) that constructs a libghostty session
   around an externally-provided master fd. This is the key API addition
   in `LabanCore`.

6. **M5 — End-to-end and survival tests.** Update
   `Tests/LabandTests/LabandControlProtocolTests.swift` so the daemon
   harness launches both `labpty` and `laband` (in that order). Add a
   new test `testLabandRestartPreservesChildViaLabpty` that:
   - Launches `labpty` and `laband`.
   - Creates a session running `/bin/sh -c 'sleep 30'`.
   - Records the child PID from `listSessions`.
   - Sends SIGTERM to `laband`, waits for it to exit, relaunches it.
   - Reconnects the client; calls `listSessions`.
   - Asserts the child PID matches the original and `lifecycleState ==
     .running`.

7. **M6 (optional) — labpty catalog.** A small file under
   `.artifacts/runs/<run-id>/labpty/catalog.json` (or similar)
   recording the open sessions. Read on startup to populate the
   in-memory map. Used for diagnostics and for `laband` to know which
   sessions to reattach to after labpty's own normal restart (Phase 3
   fd-handoff makes this much more interesting, but Phase 1 can ship
   without it).

## Concrete Steps

All commands run from the repo root.

```
# Build the new labpty executable.
swift build --product labpty

# Build everything (includes labpty + laband + app).
./scripts/build-app

# Phase 1 unit tests.
swift test --filter LabptyTests
swift test --filter LabandTests

# Phase 1 headline acceptance.
swift test --filter LabandControlProtocolTests.testLabandRestartPreservesChildViaLabpty
```

Expected transcript for the headline test:

```
Test Case 'testLabandRestartPreservesChildViaLabpty' started.
[harness] launched labpty pid=NNN
[harness] launched laband pid=MMM
[client] createSession sh -c 'sleep 30' -> ptyHandle=A1, child_pid=KKK
[client] listSessions -> 1 session, child_pid=KKK, state=running
[harness] SIGTERM laband (pid MMM)
[harness] laband exited; relaunching
[harness] launched laband pid=MMM' (relaunched)
[client] listSessions -> 1 session, child_pid=KKK, state=running
[assert] child_pid still alive: yes
Test Case passed (X.XXX seconds)
```

## Validation and Acceptance

**M0:** `LabptyProtocol.swift` compiles. `LabptyByteRingLayout.swift`
compiles. Both have brief unit tests that round-trip their Codable types
and validate the byte-ring layout constants are aligned.

**M1:** `swift test --filter LabptyTests.testOpenAndListAndTerminate`
launches labpty, creates a session, lists it, terminates it, exits 0.
The session's child_pid is reported in the response and is alive after
`openSession` and dead after `terminateSession`.

**M2:** `swift test --filter LabptyTests.testByteRingRoundTrip` writes a
known sequence of bytes through `LabptySnapshotByteRingWriter`, reads
them through `LabptySnapshotByteRingReader`, asserts identity. Tests the
seqlock and wrap-around behavior with both small and large payloads.

**M3:** `swift test --filter LabptyTests.testAttachReturnsMasterFd`
opens a session, calls `attachSession`, receives a non-negative master
fd, writes test bytes to it directly, observes those bytes appearing in
the byte-ring readout.

**M4:** All existing `LabandControlProtocolTests` continue to pass
without modification (other than the harness change to launch `labpty`
first). No app-facing protocol change.

**M5 (headline):** `testLabandRestartPreservesChildViaLabpty` passes.
This is the single test that proves Phase 1 delivers the value it
promises.

**M6 (optional):** `labpty` restarted with a known catalog file
populates its in-memory session map from the catalog on startup, and
`listSessions` returns those entries with `lifecycleState == .dead`
(children are gone because the master closed when the old labpty
exited — Phase 1 does not include fd-handoff).

**Whole build:** `./scripts/build-app` succeeds. The bundle contains
`LabanApp`, `laband`, and the new `labpty` binary, all ad-hoc signed.

## Idempotence and Recovery

All steps are additive within `Sources/Labpty/`, `Sources/LabanCore/`,
and `Tests/LabptyTests/`. The `Sources/Laband/main.swift` refactor in M4
is the only edit that changes existing behavior; if it breaks something
mid-way, revert that single file and the daemon continues to work as
today (since labpty is a separate process that can simply not be used).

Sockets, byte-ring shm files, and the (optional) catalog all live under
run-id-scoped paths. Re-running tests cleans them up. There is no
machine-wide state to migrate.

## Interfaces and Dependencies

### LabptyProtocol (new)

```swift
public struct LabptyHelloRequest: Codable, Sendable {
  public var clientId: String?
}

public struct LabptyHelloResponse: Codable, Sendable {
  public var protocolVersion: Int
  public var capabilities: [String]   // e.g., "byte-ring/v1", "scm-rights-attach/v1"
}

public struct LabptyOpenSessionRequest: Codable, Sendable {
  public var argv: [String]
  public var envp: [String: String]?
  public var cwd: String
  public var rows: Int
  public var cols: Int
  public var logicalSessionId: String?  // optional client-chosen id
}

public struct LabptySessionDescriptor: Codable, Sendable {
  public var ptyHandle: String           // labpty-assigned, opaque
  public var logicalSessionId: String?
  public var childPid: Int
  public var rows: Int
  public var cols: Int
  public var alive: Bool
  public var openedAtMonoNs: UInt64
}

public struct LabptyAttachResponse: Codable, Sendable {
  public var session: LabptySessionDescriptor
  public var byteRingShmPath: String
  public var opaqueSnapshotCacheShmPath: String?
  // master fd is delivered out-of-band via SCM_RIGHTS in the same response
}

// Plus: ListSessions, Resize, Signal, Terminate, PublishOpaqueSnapshot.
```

Version negotiation follows the same shape as `LabandProtocol`. Adding
fields is allowed; removing or repurposing them is not without a
protocol-version bump.

### LabptyByteRingLayout (new)

```swift
public enum LabptyByteRingLayout {
  public static let magic: [UInt8] = Array("LBPTYBR01".utf8)
  public static let abiVersion: UInt32 = 1
  public static let fileHeaderBytes: UInt32 = 64

  public enum FileHeaderOffset {
    public static let magic = 0           // 16 bytes, "LBPTYBR01" null-padded
    public static let abiVersion = 16     // U32
    public static let headerBytes = 20    // U32
    public static let capacity = 24       // U64 — total byte payload size
    public static let writerGeneration = 32  // U64
    public static let writeOffset = 40    // U64 — bytes written total (wraps via mod capacity)
    public static let sessionIdHash = 48  // U64
  }
}

public final class LabptyByteRingWriter {
  public init(path: String, sessionId: String, capacity: Int) throws
  public func write(_ bytes: UnsafeBufferPointer<UInt8>) throws
  public func generation() -> UInt64
}

public final class LabptyByteRingReader {
  public init(path: String) throws
  public func read(since lastGeneration: UInt64, into: inout [UInt8])
      -> UInt64  // returns new generation
  public var capacity: Int { get }
}
```

Capacity defaults to 8 MiB per session, configurable. The writer uses a
write-offset counter and the reader compares against its last-seen
generation to detect new data; wrap-around is detected by the
generation delta exceeding capacity (the reader must report
"overflowed; replay from current state" rather than reading torn data).

### Session.attaching (new LabanCore API)

```swift
extension Session {
  /// Construct a libghostty session around a master fd that another
  /// process already owns. The caller is responsible for keeping the
  /// fd valid for the session's lifetime.
  public static func attaching(
    masterFd: Int32,
    childPid: Int32,
    size: LabanTerminalSize
  ) throws -> Session
}
```

This is the load-bearing API addition. It's how `laband` rebuilds its
view of a session around a labpty-owned master rather than opening one
itself.

### Module dependencies

- `Labpty` (new executable) depends on `LabanTerminalCore`, `LabanCore`.
- `LabanCore` gains `LabptyProtocol.swift`, `LabptyByteRingLayout.swift`,
  `LabptyTerminalSessionClient.swift`, and the `Session.attaching`
  extension.
- `Laband` gains a `LabptyTerminalSessionClient` field used during
  session open/attach.
- `LabanApp` does not depend on `labpty` in Phase 1 — it continues to
  talk to `laband` only. The Phase 2 ExecPlan teaches it to consume the
  byte ring directly.

## Decision Log

- Decision: Keep `LabptyProtocol` separate from `LabandProtocol` even
  though they look similar.
  Rationale: They have very different change rates. `labpty`'s surface
  is meant to be frozen; `laband`'s evolves with libghostty. Collapsing
  them would tempt contributors to add `laband` features to the labpty
  schema and re-introduce the upgrade-fragility ADR 0006 is trying to
  fix.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: Byte-ring capacity defaults to 8 MiB per session.
  Rationale: At typical interactive output rates this covers tens of
  minutes to hours of scrollback. Larger sessions (Claude, builds) may
  exceed 8 MiB; configurable via env var or open-session option in a
  later phase.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: Phase 1 does not include `labpty`'s own fd-handoff for
  self-upgrade.
  Rationale: fd-handoff is well-trodden (LISTEN_FDS-style) but it
  deserves its own ExecPlan with explicit testing for the handoff
  window. Phase 1 ships value (laband restart no longer kills children)
  without it.
  Date/Author: 2026-05-26 / Phase 1 author.

- Decision: Phase 1 does not teach the app to talk to labpty directly.
  Rationale: That is Phase 2's value proposition. Phase 1's
  user-visible delta is zero by design; the app continues to attach to
  `laband` exactly as today.
  Date/Author: 2026-05-26 / Phase 1 author.

## Review Gate

A separate fresh-state agent must verify the following before this plan
is considered complete:

- [ ] `swift build --product labpty` succeeds.
- [ ] `swift test --filter LabptyTests` exits 0.
- [ ] `swift test --filter LabandControlProtocolTests.testLabandRestartPreservesChildViaLabpty`
  exits 0.
- [ ] `git grep -n 'class LabptyByteRingWriter' Sources/LabanCore/` returns at
  least one hit.
- [ ] `git grep -n 'Session.attaching' Sources/LabanCore/` returns at least
  one hit.
- [ ] `git grep -n 'LabptyTerminalSessionClient' Sources/Laband/` returns at
  least one hit (laband uses it internally).
- [ ] `git grep -n 'LabptyTerminalSessionClient' Sources/LabanApp/` returns
  zero hits (the app does not depend on labpty in Phase 1).
- [ ] `./scripts/build-app` succeeds and the resulting `.build/laban/Laban.app`
  bundle contains `Contents/MacOS/labpty`, `Contents/MacOS/laband`, and
  `Contents/MacOS/LabanApp`.
- [ ] `git grep -n '\bSession\.realShell\b' Sources/Laband/main.swift`
  returns zero hits (the refactor moved this call into labpty).

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)
