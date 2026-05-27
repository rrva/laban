# App-Direct Mode for LabanApp

> **SUPERSEDED — 2026-05-27.** Superseded by
> `execplans/active/labpty-and-app-direct.md`. This plan framed
> App-direct mode as a **Phase 2A follow-on** to a Phase 1 plan that
> refactored `laband` to be a `labpty` client
> (`execplans/superseded/labpty-extraction.md`). The new plan
> collapses Phase 1 and Phase 2A into a single plan that builds
> `labpty` and wires `LabanApp` directly to it from the start, while
> **keeping `laband` intact** as a third user-selectable mode
> ("Detached sessions"). The bench-comparison milestone, the
> `LBPTY-IR-01` single-writer carve-out, the
> `LabanApp`-restart-survival acceptance test, and the
> libproc-back-to-`LabanApp` decision all carried forward into the
> new plan. The on-demand `laband` LaunchAgent framing in this draft
> was dropped; the new plan keeps `laband`'s current always-on
> production behavior unchanged and selects between modes per
> session at the app layer. Preserved here so the Decision Log and
> design rationale remain reachable.

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.
A fresh contributor should be able to read only this file plus
`execplans/active/labpty-extraction.md` (Phase 1) plus the current working
tree, then deliver Phase 2A end-to-end.

This plan implements Phase 2A of the three-tier session architecture decided
in `docs/adr/0006-three-tier-session-architecture.md`. It builds on Phase 1
(`execplans/active/labpty-extraction.md`), which made `labpty` the
steady-state PTY custodian. Phase 2A makes `LabanApp` a direct `labpty`
client for primary sessions, restoring the pre-`laband` Tier 1 latency
profile while keeping the session-survives-app-upgrade property `labpty`
provides. `laband` becomes a multi-client adjunct, launched on demand only
when a secondary observer needs `LBNDSS01`.

**Do not start Phase 2A work until Phase 1 ships.** Phase 2A consumes
types `Sources/LabanCore/Labpty*.swift` that Phase 1 builds; depending on
them while their shape is still moving multiplies merge cost without
buying anything.

## Purpose / Big Picture

Phase 1's user-visible win was `laband` restart survival. The user-visible
wins Phase 2A ships:

- **Keystroke-to-cell latency matches pre-`laband` Tier 1.** No JSON parse
  hop, no `LBNDSS01` marshaling on the primary session's render path.
  `libghostty-vt` runs in `LabanApp` as it did in the Tier 1 era; bytes
  arrive via a shared-memory ring rather than direct PTY `read(2)`, but
  the difference is one memcpy through cache-line-hot shm.
- **`LabanApp` upgrade no longer kills children.** Same property
  Phase 1 ships for `laband`, lifted to the app. The PTY master stays
  with `labpty`; on relaunch `LabanApp` calls `labpty.listSessions` and
  reattaches.
- **`libghostty` bumps inside `LabanApp` are now free.** A parser change
  forces an `LabanApp` restart; because Phase 2A makes that restart
  preserve children, the operational cost of a parser bump drops to
  "next tab open re-renders from current window."

What Phase 2A keeps unchanged from Phase 1:

- `labpty` itself. Phase 2A is a pure consumer of the Phase 1 `labpty`
  surface; no `labpty` code or wire-protocol changes unless M3 ships
  (conditional, see Plan of Work).
- The `LBPTY-BR-01` byte ring layout. SPMC by design, so a second
  consumer (`LabanApp`'s in-process parser) is supported by the existing
  format without modification.
- `laband` as a component. `laband` still exists, still gets the Phase 1
  byte-ring-consumer / snapshot-publisher implementation, still passes
  its restart-survival acceptance test. The difference is that `laband`
  no longer auto-starts and no longer carries primary sessions.

What Phase 2A does **not** ship:

- Multi-attach write arbitration. Phase 2A is single-writer by
  construction (the user's `LabanApp`).
- `labpty` self-upgrade fd handoff. That stays Phase 3.
- A real second observer (cast / share / SSH). Phase 2A's M6
  integration test uses a synthetic test consumer; product surfaces
  for secondary observers are out of scope.

### Phase boundaries on session survival, after Phase 2A

| Event | Phase 1 | **Phase 2A (this plan)** | Phase 3 |
| --- | --- | --- | --- |
| `LabanApp` restart | survives (PTY in `laband`) | **survives (PTY in `labpty`)** | survives |
| `LabanApp` upgrade | dies | **survives** | survives |
| `libghostty` bump in `LabanApp` | n/a (not in app) | **survives** | survives |
| `laband` restart / upgrade | survives (Phase 1 headline) | survives | survives |
| `libghostty` bump in `laband` | survives | survives | survives |
| `labpty` restart / upgrade | child dies | child dies | survives |
| `labpty` crash | child dies | child dies | child dies |
| OS reboot | child dies | child dies | child dies |

After Phase 2A, the only remaining session-killing event in normal
operation is a `labpty` upgrade or crash. Phase 3 closes that hole.

## Architectural Invariants

These invariants are the spine of Phase 2A. The plan, the code, and the
Review Gate all enforce them.

1. **`labpty` is unchanged from Phase 1 in M0–M2 and M4–M6.** No
   `labpty`-side code or protocol changes except inside M3, which is
   conditional on the M2 bench result. Every line of `labpty` is still a
   line subject to the Phase 1 verification bar; Phase 2A does not put
   pressure on the bottom-process surface unless the latency measurement
   forces it.

2. **`LabanApp` runs `libghostty-vt` in-process.** This is the Tier 1
   pattern restored. Bytes from `labpty`'s byte ring flow into
   `Session.feedOutput(_:)` inside `LabanApp`'s process, not via
   `laband`. The same parser-only `Session.fixture(size:)` constructor
   Phase 1's M3 wired into `laband`'s ring-reader loop is reused
   in-process inside `LabanApp`.

3. **`LabanApp` is the steady-state writer of input.** Phase 2A is
   single-writer; the `multi-attach-write-lease/v1` primitive named in
   the protocol-design doc stays Phase 3+ because Phase 2A does not
   need it.

4. **`laband` is on-demand.** A `LaunchAgent` plist with `ServiceIPC = true`
   (or equivalent on-demand trigger) starts `laband` only when a client
   `connect(2)`s to its socket. After idle timeout `laband` exits.
   `LabanApp` never connects to `laband` for primary sessions; a primary
   session opens via `labpty.openSession` directly.

5. **When `laband` is running, it consumes the same byte ring as
   `LabanApp`.** Two parser instances see the same bytes in the same
   order. `labpty`'s single-producer / multi-reader design handles this
   with no `labpty` change. Each parser maintains its own
   `last_seen_offset` in its own address space (per the byte-ring
   contract in `labpty-protocol-design.md`).

6. **`LabanApp` survives its own crash via `labpty.listSessions`.**
   Phase 1's reattach mechanism for `laband` is the same primitive
   `LabanApp` uses; the in-ring "replay from current window" recovery
   path warms the parser on cold reattach.

7. **Phase 1 acceptance tests continue to pass unchanged.** Phase 2A is
   additive. The Phase 1 review-gate grep "`LabptyTerminalSessionClient`
   does not appear in `Sources/LabanApp/`" becomes obsolete when
   Phase 1's plan moves to `execplans/completed/`; the inverse grep
   ("`LabptyTerminalSessionClient` does appear in `Sources/LabanApp/`")
   lands in Phase 2A's Review Gate.

8. **The `writeInput` RPC is the input path in M1; `LBPTY-IR-01` lands
   in M3 only if M2 bench warrants.** Measurement gates the input-ring
   implementation. Single-writer input is a much simpler design than
   the multi-writer case the protocol-design doc currently couples to
   `multi-attach-write-lease/v1`; Phase 2A's M3 explicitly ships the
   SPSC variant.

## Progress

- [ ] M0: `LabanApp` declares dependencies on `LabptyTerminalSessionClient`
  and `LabptyByteRingReader` (built by Phase 1, sitting in `LabanCore`).
  Phase 1 Review Gate grep "`LabptyTerminalSessionClient` not in
  `Sources/LabanApp/`" is retired with Phase 1's plan; Phase 2A Review
  Gate replaces it with the inverse grep.
- [ ] M1: `LabanApp` opens a session directly through `labpty`. End-to-end
  smoke test creates a session, types, observes the cell update with no
  `laband` running.
- [ ] M2: `Tools/KeystrokeLatencyBench` extended to compare three
  configurations on the same quiet hardware: (a) pre-`laband` Tier 1,
  (b) Phase 1 `laband`-mediated, (c) Phase 2A App-direct with
  `writeInput` RPC. Histogram artifacts in
  `.artifacts/runs/<run-id>/bench/`. Decision recorded in this plan's
  Decision Log whether M3 ships.
- [ ] M3 (conditional on M2): `LBPTY-IR-01` input ring as a single-writer
  SPSC. Adds the `input-ring/v1` capability to `labpty` (the only
  `labpty`-side change in Phase 2A; gated behind capability
  negotiation so old `labpty` builds still interoperate).
- [ ] M4: `laband` becomes on-demand. `LaunchAgent` plist gains
  `ServiceIPC`; `laband` idle-exits when no clients are attached.
  `LabanApp` no longer connects to `laband` for primary sessions.
- [ ] M5: `LabanApp` restart preserves child via `labpty`. Acceptance
  test analogous to Phase 1's
  `testLabandRestartPreservesChildViaLabpty`.
- [ ] M6: Multi-client adjunct integration. Test exercises the
  full path: `labpty` + `LabanApp` App-direct session + on-demand
  `laband` startup + `laband` attaches to the same byte ring + a
  synthetic secondary consumer reads `LBNDSS01` while `LabanApp`
  continues typing.

## Context and Orientation

### Where the Tier 1 in-process path used to live

Pre-`laband`, `LabanApp` owned the PTY master directly via
`Session.realShell(...)` (`Sources/LabanCore/Session.swift:159`) and ran
`libghostty-vt` in-process. `Sources/LabanApp/` still contains
keystroke-handler code that called `Session.write(_:)` directly; that
path is the closest historical model for Phase 2A's input path.
Phase 1 moved primary session ownership out of `LabanApp` and into
`laband` (which in turn delegates PTY ownership to `labpty`). Phase 2A
reintroduces an in-process parser path but keeps PTY ownership in
`labpty`.

### Where the `labpty` client types live after Phase 1

- `Sources/LabanCore/LabptyTerminalSessionClient.swift` — RPC client.
- `Sources/LabanCore/LabptyByteRingReader.swift` — byte-ring consumer.
- `Sources/LabanCore/LabptyProtocol.swift` — request/response shapes.
- `Sources/LabanCore/LabptyFraming.swift` — `LBPTY-CT-01` binary frames.
- `Sources/LabanCore/LabptyByteRingLayout.swift` — `LBPTY-BR-01`
  offsets.
- `Sources/LabanCore/Session+ParserOnly.swift` (optional) — the
  `Session.parserOnly(size:)` convenience.

Phase 2A imports the same types into `LabanApp`. No new types in M0–M2
or M4–M6; M3 adds `LabptyInputRingWriter` if it ships.

### Where `laband`'s on-demand trigger plugs in

macOS LaunchAgents support `ServiceIPC` — when a client `connect(2)`s
to the agent's socket, `launchd` exec's the binary. The Phase 1 plan
deferred production LaunchAgent ordering. Phase 2A picks it up here:
`scripts/install-launch-agents` (new) installs a per-user LaunchAgent
plist for `laband` only (`labpty` runs as a separate always-on agent
since Phase 1; that doesn't change). `laband`'s plist marks
`ServiceIPC = true` and includes an idle-exit hook after 30 s of zero
attached clients.

For tests, the harness exec's `laband` directly (as Phase 1's tests
already do); the LaunchAgent path is exercised by M4's interactive
acceptance script, not by unit tests.

### What the bench harness measures

`Tools/KeystrokeLatencyBench` exists as the pre-`laband` Tier 1 bench
(measures `keystroke → first cell update visible to renderer`).
Phase 2A's M2 milestone extends it to run the same workload through
three paths and compare histograms. The Phase 1 plan's
`BenchPtyLabptyEcho` is the labpty-byte-ring half of this; M2 wires the
input side and produces the unified comparison.

Decision criterion baked into M2: p50 within 1.5× of pre-`laband`
Tier 1, p99 within 2×. Miss either gate ⇒ M3 ships.

### How `LBPTY-IR-01` simplifies in single-writer mode

The protocol-design doc currently couples `input-ring/v1` to
`multi-attach-write-lease/v1` because multi-writer shared-memory has
no safe semantics without an arbitrating lease. Phase 2A's single-writer
constraint removes the coupling: one writer, one consumer (`labpty`),
clean SPSC. Implementation cost: one memcpy + atomic store-release on
the producer (`LabanApp`); one atomic load-acquire + memcpy + `write(2)`
to the PTY master on the consumer (`labpty`). The `multi-attach-write-
lease/v1` primitive remains Phase 3+ territory because a future
secondary-observer-with-input scenario still needs it.

If M3 ships, the additive edit to `labpty-protocol-design.md` records
this single-writer carve-out explicitly so Phase 3 work knows the
existing `input-ring/v1` is the single-writer flavor.

## Plan of Work

### M0 — Dependency surface

`Sources/LabanApp/` gains imports of `LabptyTerminalSessionClient`,
`LabptyByteRingReader`, `LabptyProtocol`, and (optionally)
`Session+ParserOnly`. `Package.swift` does not need a new target — all
new symbols live in `LabanCore`, which `LabanApp` already depends on.

Coordinate with Phase 1's plan completion: the Phase 1 Review Gate item
forbidding `LabptyTerminalSessionClient` in `Sources/LabanApp/` should
be marked obsolete (struck through or moved to a "superseded by
Phase 2A" subsection) at the same commit Phase 2A's M0 lands.

### M1 — `LabanApp` opens directly

New session-creation entry point in `LabanApp` that:

1. Calls `labptyClient.openSession(argv:envp:cwd:rows:cols:logicalSessionId:)`.
2. Receives a `LabptySessionDescriptor` carrying `ptyHandle`, `childPid`,
   `rows`, `cols`, `byteRingShmPath`, `foregroundPid`, `foregroundPgid`.
3. Constructs a parser-only `Session` via `Session.parserOnly(size:)`
   (or `Session.fixture(size:)` directly).
4. Opens the byte ring via `LabptyByteRingReader(path:)`.
5. Starts a ring-reader loop on a dedicated dispatch queue (or a
   `DispatchSourceTimer` ticking at the M2 poll cadence — initially 4 ms
   matching `laband`'s loop, but `LabanApp` may pin to its own render
   cadence as a later optimization).
6. Wires keystroke handling to call
   `labptyClient.writeInput(handle:bytes:)`.

Files touched (new or modified):

- `Sources/LabanApp/AppLabanSessionCoordinator.swift` (or similar
  coordinator class — locate the existing one in `Sources/LabanApp/`
  that owns session lifecycle for the Phase 1 `laband`-mediated path).
  Gains a `mode: SessionTransportMode` enum-like field with cases
  `appDirect(LabptyTerminalSessionClient)` and `labandMediated(...)`.
  M1 hard-codes `appDirect` for new sessions; M4 makes it the default
  and reduces `labandMediated` to a fallback / disabled path.
- `Sources/LabanApp/AppLabandSessionCoordinator.swift` is renamed or
  refactored so its name reflects "session coordinator," not
  "laband-specific coordinator."
- `Tests/LabanAppTests/AppDirectSessionTests.swift` (new). Smoke test:
  launch `labpty` (no `laband`), open a session via the new path, type
  `printf hi\n`, assert the parsed snapshot contains `hi`.

ADR 0002 invariants still live inside `labpty` (Phase 1). `LabanApp`
no longer makes ADR 0002 claims directly.

### M2 — Bench harness comparison

Extend `Tools/KeystrokeLatencyBench` with two new modes:

- `--mode laband-mediated` (Phase 1 path): drives keystrokes through
  `LabandTerminalSessionClient.writeInput` and reads cells from
  `LBNDSS01`.
- `--mode app-direct-writeInput` (Phase 2A M1 path): drives keystrokes
  through `LabptyTerminalSessionClient.writeInput` and reads cells
  in-process from the parser the bench instantiates.

The existing `--mode tier1` path stays as-is. M2 lands a script
`scripts/bench-keystroke-latency` that runs all three modes against an
identical workload and produces a unified histogram comparison.

Acceptance: comparison artifact at
`.artifacts/runs/<run-id>/bench/keystroke-latency-comparison.json`.
Decision recorded in this plan's Decision Log: ship M3 or skip.

### M3 (conditional) — `LBPTY-IR-01` single-writer input ring

Skeleton — full design lands inline here if M2 says "build it."

- `Sources/LabanCore/LabptyInputRingWriter.swift` (new). Single-producer
  writer mirroring `LabptyByteRingWriter`'s shape.
- `Sources/Labpty/labpty_input_ring.c` + `.h` (new). Single-consumer
  reader inside `labpty`'s event loop. Drains the ring into the PTY
  master via `write(2)` under `labpty`'s existing master-write lock.
- `Sources/LabanCore/LabptyByteRingLayout.swift` — populate the
  `input_ring_offset` and `input_ring_capacity` header fields that
  Phase 1 reserved at zero. Default capacity: 64 KiB (matches the
  protocol-design doc's input-ring default).
- `labpty.openSession` response gains an `inputRingShmPath` field via
  an `abi_minor` bump (ABI-major stays 1). Existing readers ignore
  unknown trailing bytes per the binary-frame contract.
- Capability `input-ring/v1` negotiated at `hello`. Fallback path:
  `writeInput` RPC continues to work; `LabanApp` picks the input ring
  iff the capability negotiates true.

The Phase 1 plan's coupling note in `labpty-protocol-design.md`
("`input-ring/v1` requires `multi-attach-write-lease/v1`") gets an
additive carve-out paragraph stating the single-writer flavor that
Phase 2A's M3 ships.

### M4 — `laband` on-demand

`scripts/install-launch-agents` (new):

- Generates `~/Library/LaunchAgents/xyz.laban.labpty.plist` (always-on,
  same as Phase 1 production setup).
- Generates `~/Library/LaunchAgents/xyz.laban.laband.plist` with
  `Sockets` + `ServiceIPC = true`. `launchd` exec's `laband` on first
  client `connect(2)`.

`Sources/Laband/main.swift`:

- Adds an idle-exit timer. When `LabandDaemon.sessions` is empty AND
  no client has been connected for >30 s, the daemon initiates a clean
  shutdown (closes the listening socket; the next `accept(2)` cycle
  drops out of the event loop; binary exits 0).
- Idle-exit is disabled when `LABAND_TESTING_DO_NOT_IDLE_EXIT=1` is
  set, for test harness use.

`LabanApp`:

- Stops connecting to `laband` for primary sessions. Session-coordinator
  defaults to `appDirect`. The `labandMediated` path remains compiled
  for the Phase 1 → Phase 2A migration grace period; remove in Phase 2B
  or Phase 3.

### M5 — `LabanApp` restart survival acceptance

`Tests/LabanAppTests/LabanAppRestartSurvivalTests.swift` (new):

- `testLabanAppRestartPreservesChildViaLabpty`:
  1. Test harness launches `labpty` (run-id-scoped socket + shm dir).
  2. Launches `LabanApp` in headless mode (`HeadlessDebugRuntime`),
     opens an App-direct session running `/bin/sh -c 'printf STARTED;
     while read x; do echo "got $x"; done'`.
  3. Records `child_pid` via debug endpoint; sends `ping`; observes
     `STARTED` in snapshot.
  4. Terminates `LabanApp` (SIGTERM to the headless host). Verifies
     `labpty` and the child are both still alive.
  5. Relaunches `LabanApp` headless. New process calls
     `labpty.listSessions`; finds the existing session; reattaches the
     byte ring; parser warms via in-ring replay; sends `pong`.
  6. Asserts new snapshot contains `got pong` AND the underlying
     `child_pid` is unchanged from step 3.

`scripts/test-labanapp-survives-restart` (new): interactive analog of
the test, mirrors `scripts/test-labpty-survives-laband-restart` from
Phase 1.

### M6 — Multi-client adjunct integration

`Tests/LabanAppTests/MultiClientAdjunctTests.swift` (new):

- `testSecondaryObserverAttachesAlongsideAppDirect`:
  1. Launch `labpty`.
  2. Launch `LabanApp` headless; open an App-direct session.
  3. Exec `laband` directly (test harness simulates the launchd
     trigger). `laband` connects to `labpty`; calls `listSessions`;
     attaches to the byte ring for the existing session; starts
     publishing `LBNDSS01`.
  4. A synthetic secondary consumer (`Tools/LabandSnapshotTail`, a
     small CLI that opens `LabandTerminalSessionClient` and prints
     snapshots) connects to `laband` and reads `LBNDSS01`.
  5. `LabanApp` types `hello\n`. Assert the secondary consumer's
     `LBNDSS01` snapshot contains `hello` within 200 ms of the type.
  6. Assert `LabanApp`'s own in-process snapshot also contains
     `hello` (both parsers see the same bytes).
  7. Kill the secondary consumer; verify `laband` idle-exits after the
     test-shortened timeout (`LABAND_IDLE_EXIT_MS=500`).

## Concrete Steps

All commands from repo root.

```
# After Phase 1 lands. Rebase Phase 2A on Phase 1's merge commit.
git fetch origin
git rebase origin/main

# Build the full stack (labpty + laband + LabanApp).
./scripts/build-app

# Phase 2A unit tests.
swift test --filter LabanAppTests.AppDirectSessionTests

# Phase 2A bench (manual, on a quiet local machine, not CI).
./scripts/bench-keystroke-latency

# Phase 2A acceptance.
swift test --filter LabanAppTests.LabanAppRestartSurvivalTests
swift test --filter LabanAppTests.MultiClientAdjunctTests

# Interactive acceptance.
./scripts/test-labanapp-survives-restart
```

## Validation and Acceptance

**M0:** `swift build` succeeds with `LabanApp` importing `Labpty*`
types from `LabanCore`. Phase 1 review-gate item for the inverse grep
marked superseded.

**M1:** `swift test --filter LabanAppTests.AppDirectSessionTests` exits
0. The test runs with no `laband` process anywhere.

**M2:** `.artifacts/runs/<run-id>/bench/keystroke-latency-comparison.json`
exists and contains histograms for all three modes. Decision Log entry
records the comparison numbers and the M3 ship/skip outcome.

**M3 (if shipped):** `swift test --filter LabanCoreTests.LabptyInputRingTests`
exits 0. `Tools/KeystrokeLatencyBench --mode app-direct-input-ring`
produces a histogram whose p50 is within 1.5× of the pre-`laband`
Tier 1 mode.

**M4:** A fresh login (or `launchctl unload` / `load` of the agents)
shows no `laband` process via `pgrep -f laband` immediately after.
Opening a new `LabanApp` session does **not** trigger `laband`. A
manual `socket-cat` (or equivalent) to `laband`'s socket triggers
`launchd` to start it; after the test client disconnects and 30 s
pass, `laband` exits.

**M5:** `testLabanAppRestartPreservesChildViaLabpty` exits 0, with the
transcript showing identical `child_pid` before and after.

**M6:** `testSecondaryObserverAttachesAlongsideAppDirect` exits 0.
Manual acceptance: open `LabanApp`, type in a session, then in a
separate terminal run `Tools/LabandSnapshotTail` and observe the
typed text appearing in the snapshot stream.

## Idempotence and Recovery

Phase 2A additions are confined to:

- `Sources/LabanApp/` — new session-coordinator code; reverting reverts
  to Phase 1's `labandMediated` path which still works.
- `Sources/Laband/main.swift` — additive idle-exit; defaults preserve
  Phase 1 behavior under `LABAND_TESTING_DO_NOT_IDLE_EXIT=1`.
- `scripts/install-launch-agents` — `launchctl unload` of the new
  plist reverts to Phase 1's always-on `laband`.

M3, if shipped, is additive in `labpty` (capability flag at `hello`).
Old `LabanApp` builds against a new `labpty` continue to work
(negotiated capability is missing ⇒ `LabanApp` falls back to
`writeInput`). New `LabanApp` against an old `labpty` does the same.

Sockets, byte-ring shm files, and LaunchAgent plists are all
run-id-scoped or per-user; nothing machine-wide migrates.

## Interfaces and Dependencies

### No new types in M0–M2 and M4–M6

`LabanApp` imports `LabptyTerminalSessionClient`, `LabptyByteRingReader`,
`LabptyProtocol`, and `Session.parserOnly` (or `Session.fixture`) — all
built by Phase 1.

### M3-only types (conditional)

```swift
public final class LabptyInputRingWriter {
  public init(path: String, capacity: Int) throws
  public func write(_ bytes: UnsafeBufferPointer<UInt8>)
  public func close()
}
```

C-side counterpart in `Sources/Labpty/labpty_input_ring.{c,h}`. The
two communicate through the shm file alone; no symbol coupling.

Header layout extension: populate `input_ring_offset` and
`input_ring_capacity` in `LBPTY-BR-01` (Phase 1 reserved both at zero).
The Phase 1 power-of-two-capacity invariant applies to the input ring
too.

### Module dependencies after Phase 2A

- `Labpty` (C) — unchanged in M0–M2/M4–M6; M3 adds `labpty_input_ring.{c,h}`.
- `LabanCore` (Swift) — unchanged in M0–M2/M4–M6; M3 adds
  `LabptyInputRingWriter.swift`.
- `Laband` (Swift) — gains idle-exit logic in M4; no other changes.
- `LabanApp` (Swift) — gains the App-direct session coordinator,
  imports `LabanCore`'s `Labpty*` types.

### `laband` LaunchAgent plist (M4)

`~/Library/LaunchAgents/xyz.laban.laband.plist` minimal shape:

```xml
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>xyz.laban.laband</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/Laban.app/Contents/MacOS/laband</string>
    <string>--socket</string>
    <string>SOCKET_PATH</string>
    <string>--labpty-socket</string>
    <string>LABPTY_SOCKET_PATH</string>
  </array>
  <key>Sockets</key>
  <dict>
    <key>Listeners</key>
    <dict>
      <key>SockPathName</key>
      <string>SOCKET_PATH</string>
      <key>SockPathMode</key>
      <integer>384</integer>
    </dict>
  </dict>
  <key>ServiceIPC</key>
  <true/>
</dict>
</plist>
```

`labpty`'s plist (installed by Phase 1's M6, untouched here) is
always-on with `KeepAlive = true`.

## Decision Log

- Decision: Phase 2A is a separate ExecPlan file, not an extension of
  the Phase 1 plan.
  Rationale: Phase 1's plan must be archivable on completion. Phase 1
  invariant #4 ("`LabanApp` does not link `Labpty*`") is directly
  inverted by Phase 2A; co-locating them would require qualifying
  every invariant statement with a phase number. The protocol-design
  doc is destined to graduate to `docs/reference/labpty-protocol.md`
  after Phase 1 ships; ExecPlan content (milestones, Concrete Steps,
  Review Gates) does not belong in a long-term reference doc.
  Date/Author: 2026-05-27 / Phase 2A author.

- Decision: `laband` becomes on-demand via `launchd` `ServiceIPC`, not
  always-on or eliminated.
  Rationale: Eliminating `laband` outright would force every secondary
  observer (cast, share, future SSH) to build its own `libghostty`
  parser and `LBNDSS01` consumer. Keeping `laband` always-on burns a
  process for the common case where no secondary observer exists.
  `ServiceIPC` is the `launchd` mechanism designed for exactly this:
  pay process-startup cost only when a client connects, exit when
  idle. `laband`'s startup latency is dominated by Swift runtime
  init (~50 ms) which is acceptable for the first secondary-observer
  connection — that operation is interactive, not steady-state.
  Date/Author: 2026-05-27 / Phase 2A author.

- Decision: `LBPTY-IR-01` input ring is gated on M2 bench result, not
  shipped unconditionally.
  Rationale: The protocol-design doc names the `writeInput`-RPC
  alternative as acceptable for Phase 1 because keystroke rate is
  bounded by user action. Phase 2A inherits that argument until a
  measured comparison shows the App-direct `writeInput` path is
  perceptibly slower than pre-`laband` Tier 1. The discipline of
  "measure first, build second" matches the protocol-design doc's
  Principle 1 (Latency is measured, not estimated). Shipping the input
  ring speculatively would lock in `labpty`-side complexity that may
  buy nothing user-visible.
  Date/Author: 2026-05-27 / Phase 2A author.

- Decision: Single-writer `LBPTY-IR-01` (Phase 2A M3) is decoupled
  from the protocol-design doc's `multi-attach-write-lease/v1` claim.
  Rationale: The protocol-design doc currently couples `input-ring/v1`
  to `multi-attach-write-lease/v1` because multi-writer shared-memory
  has no safe semantics without an arbitrating lease. Phase 2A's
  constraint is single-writer (one `LabanApp` per primary session); the
  lease problem does not arise. M3, if shipped, lands as the
  single-writer flavor of `input-ring/v1`; a future Phase 3+ ExecPlan
  can extend it to the multi-writer case behind the lease primitive.
  An additive paragraph in `labpty-protocol-design.md` records the
  single-writer carve-out.
  Date/Author: 2026-05-27 / Phase 2A author.

- Decision: `LabanApp` runs its own libghostty parser in-process;
  `laband`'s parser does not feed `LabanApp`.
  Rationale: This is the structural mechanism by which Phase 2A
  recovers Tier 1 latency. Any design where `LabanApp` reads bytes
  through `laband` reintroduces the JSON parse hop and the `LBNDSS01`
  marshaling that pre-`laband` Tier 1 avoided. Two parser instances
  (one in `LabanApp`, one in `laband` when running) is the cost; the
  byte ring is SPMC by design and accommodates this without
  modification.
  Date/Author: 2026-05-27 / Phase 2A author.

- Decision: libproc resolution moves back from `laband` (where Phase 1
  put it) into `LabanApp` for primary sessions.
  Rationale: `laband` no longer holds primary-session state in Phase
  2A. Foreground-process resolution (`proc_name` / `proc_pidpath` /
  `proc_pidinfo` on the `foreground_pid`/`foreground_pgid` `labpty`
  reports) happens where the consumer of the resolved data lives. For
  the primary session, that's `LabanApp` (tab title, process metadata
  panel). For a secondary observer attached via `laband`, `laband`
  still resolves and publishes via `LabandSessionInfo.foreground*`.
  The libproc helper code (`Sources/LabanTerminalCore/process_metadata.c`)
  is unchanged; only the call site moves.
  Date/Author: 2026-05-27 / Phase 2A author.

- Decision: M0 is a no-op file move plus a Review Gate flip, not a
  feature.
  Rationale: M0 exists to make the Phase 1 → Phase 2A boundary
  explicit and reviewable. The actual code change is small (an
  `import LabanCore` already exists; the new types come for free).
  M0's value is procedural: it forces the Phase 1 plan archival and
  the inverse Review Gate item in one commit, so a fresh contributor
  can read this plan and the Phase 1 plan and unambiguously know which
  invariants are live.
  Date/Author: 2026-05-27 / Phase 2A author.

## Surprises & Discoveries

(Filled in as implementation proceeds.)

## Review Gate

A separate fresh-state agent must verify the following before this plan
is considered complete. The executing agent must not mark the plan as
done until this gate has passed. See the "Review gate and review-fix
loop" section in `PLANS.md` for the full process.

### Build and tests

- [ ] `./scripts/build-app` exits 0 and the bundle contains `labpty`,
  `laband`, and `LabanApp` (same as Phase 1).
- [ ] `swift test --filter LabanAppTests.AppDirectSessionTests` exits 0.
- [ ] `swift test --filter LabanAppTests.LabanAppRestartSurvivalTests`
  exits 0; transcript shows the same `child_pid` before and after
  `LabanApp` relaunch.
- [ ] `swift test --filter LabanAppTests.MultiClientAdjunctTests`
  exits 0; transcript shows both `LabanApp`'s in-process snapshot and
  the secondary consumer's `LBNDSS01` snapshot containing the typed
  text within 200 ms of input.
- [ ] All Phase 1 tests continue to pass without modification.

### Invariants (mechanical greps)

- [ ] `git grep -n 'LabptyTerminalSessionClient' Sources/LabanApp/`
  returns at least one hit (inverse of the Phase 1 grep).
- [ ] `git grep -n 'LabandTerminalSessionClient' Sources/LabanApp/`
  returns hits only inside the `labandMediated` fallback path or
  related code clearly labeled as such (Phase 1 fallback retained for
  one grace cycle; remove in a follow-up).
- [ ] `git grep -nE 'Session\.realShell|laban_session_poll_blocking'
  Sources/LabanApp/` returns zero hits. (`LabanApp` does not own PTYs
  directly; `labpty` does.)
- [ ] `git grep -nE 'SCM_RIGHTS|sendmsg|cmsghdr'
  Sources/LabanApp/ Sources/LabanCore/Labpty*.swift Sources/Labpty/`
  returns zero hits. (Phase 2A still has no SCM_RIGHTS anywhere.)
- [ ] `git grep -n 'Session\.parserOnly\|Session\.fixture'
  Sources/LabanApp/` returns at least one hit, in the App-direct
  session-coordinator code path.

### On-demand `laband` behavior

- [ ] After `./scripts/install-launch-agents` and a fresh login (or
  `launchctl unload`+`load`), `pgrep -f '/laband'` returns empty.
- [ ] Opening a primary session in `LabanApp` does **not** trigger
  `laband` to start (`pgrep -f '/laband'` still empty).
- [ ] A test client connecting to `laband`'s socket triggers `launchd`
  to start `laband` within 200 ms.
- [ ] After the test client disconnects and 30 s pass (or
  `LABAND_IDLE_EXIT_MS=500` in tests), `laband` exits cleanly
  (exit code 0).

### Bench artifact

- [ ] `.artifacts/runs/<run-id>/bench/keystroke-latency-comparison.json`
  exists and contains histograms for all three modes.
- [ ] The Decision Log records the M3 ship/skip outcome with the
  measured p50 and p99 ratios against pre-`laband` Tier 1.

### M3 (conditional)

If M3 shipped:

- [ ] `swift test --filter LabanCoreTests.LabptyInputRingTests` exits 0.
- [ ] `git grep -nE 'multi-attach-write-lease' Sources/Labpty/
  Sources/LabanCore/` returns zero hits. (Phase 2A's input ring is
  single-writer; the lease primitive is Phase 3+.)
- [ ] `labpty` `hello` response includes `input-ring/v1` in its
  capability set; old `LabanApp` clients that don't request it still
  work via `writeInput`.
- [ ] An additive paragraph in `execplans/active/labpty-protocol-design.md`
  records the single-writer carve-out of `input-ring/v1`.

### Cleanup

- [ ] No `labpty`, `laband`, or `LabanApp` processes remain after the
  test suite exits.
- [ ] No leftover shm files under `.tmp/<run-id>/labpty/`.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)
