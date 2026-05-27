# labpty and Three-Mode Session Selection

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
A fresh contributor should be able to read only this file plus
`execplans/active/labpty-protocol-design.md` (the wire-protocol and
shared-memory working spec) plus the current working tree, then deliver
the whole plan end-to-end.

This plan builds a new background-session path for Laban — a thin C
daemon (`labpty`) that owns PTY masters and child process groups, with
`LabanApp` consuming `labpty`'s shared-memory byte ring directly through
an in-process `libghostty-vt` parser — and exposes it alongside the
existing in-process and `laband`-mediated paths as three user-selectable
modes.

| Menu label (Workspace → Terminal Sessions) | What the user gets | Transport |
| --- | --- | --- |
| **Local sessions** | Process lives in `LabanApp`. Closing the app ends the session. Lowest latency, no daemon dependency. | in-process `Session` (the pre-`laband` Tier 1 path) |
| **Background sessions** | Process keeps running across `LabanApp` restart and upgrade. App is needed to render; long absences may lose scrollback past the byte-ring window. | `labpty` byte ring (this plan's new path) |
| **Detached sessions** | Process keeps running *and* its terminal state is fully maintained without the app: complete scrollback, multi-client viewing possible. | `laband` (existing path, kept as-is) |

CLI and environment extend `TerminalBackendSettings`'s existing
surface; no new `--session-mode` flag or `LABAN_SESSION_MODE` env
var (those were briefly proposed and dropped during pre-flight to
avoid churning today's working surface).

```
--terminal-backend <value>   # canonical: in-process | labpty | laband
                             # aliases: local|local-sessions → in-process
                             #          background|background-sessions → labpty
                             #          detached|detached-sessions|daemon|daemon-sessions → laband
--local-sessions             # short form, in-process
--background-sessions        # short form, labpty (REASSIGNED from laband)
--detached-sessions          # short form, laband (NEW)
--laband-sessions            # short form, laband (back-compat alias)
LABAN_TERMINAL_BACKEND=<value>   # same values and aliases as --terminal-backend
```

The default for new sessions is **labpty** (the Background mode).
Reassigning `--background-sessions` from `.laband` to `.labpty` is
the one breaking change to today's command-line; the
UserDefaults migration in the Pre-flight Findings keeps users who
had "Background Sessions" selected on `.laband` (now Detached) so
saved menu intent does not silently switch daemons.

`laband` is retained intact. Its future is undecided; exposing the
three modes to users makes it possible to learn from real usage whether
Detached mode earns its place. An earlier draft of this plan deleted
`laband` in a final milestone; that deletion has been removed.

This plan supersedes two earlier ExecPlans: `labpty-extraction.md`
(`laband` as a refactor target for `labpty`) and
`labpty-app-direct-mode.md` (App-direct mode atop a kept laband). Both
are preserved in `execplans/superseded/` so their Decision Logs remain
reachable; the design history in them informed the choices here.

## Purpose / Big Picture

Today `LabanApp` consumes parsed cells from `laband`, a Swift daemon
that owns each session's PTY master, runs the `libghostty-vt` parser,
and publishes cells through a shared-memory snapshot ring
(`LBNDSS01`). Two operational consequences observed in practice
motivated the new Background mode:

- **Killing or upgrading `laband` kills the user's live shells.**
  `laband` holds the master fd; its exit sends `SIGHUP` to every child
  process group. A `libghostty` bump, a parser bug fix, or a daemon
  restart costs the user every running `claude-code`, `vim`, build, or
  shell.
- **The parsed-snapshot hop introduces latency and known correctness
  bugs.** Selections-and-copy-paste in particular are unreliable across
  the snapshot-ring boundary; the parsed cells are a derived view, and
  the original parser state where selection coordinates are anchored
  lives in another process.

The new Background mode fixes both: `labpty` (a deliberately minimal C
daemon that owns only the kernel-level objects: PTY masters, child
process groups, output byte rings) plus an in-process `libghostty-vt`
parser inside `LabanApp`. `LabanApp` opens sessions by calling
`labpty.openSession`, reads bytes from a shared-memory ring `labpty`
publishes, drives its own parser, and renders directly. Input goes
from `LabanApp`'s keystroke handler through a `writeInput` RPC to
`labpty`. The Background-mode wins:

- **Sessions survive `LabanApp` upgrade.** The PTY master and child
  pgroup live in `labpty`, not in the app. Restarting `LabanApp` (for
  a feature update, a parser bump, a crash) finds the session intact
  via `labpty.listSessions` and reattaches.
- **Selection, copy, paste, search are all in-process.** Same address
  space as the parser; no marshaling of cell coordinates across a
  daemon boundary.
- **Keystroke-to-cell latency matches pre-`laband` Tier 1 feel.** No
  JSON parse hop, no cell-marshaling, no `LBNDSS01` seqlock reads in
  the render path.

The existing Detached mode (`laband`) retains its own user-visible
properties:

- Sessions and scrollback survive `LabanApp` absence in a way
  Background mode cannot: the parser keeps running with no client
  attached, so output produced while the app is closed is captured to
  full scrollback rather than bounded by the byte-ring window.
- Multi-client viewing of the same session is structurally supported
  (foundation for a future cast / share / remote feature).
- Lease-arbitrated input handoff between clients is implemented
  (foundation for a future agent–user collaboration feature).

The three modes coexist; sessions choose one at creation and stay in
that mode for their lifetime.

What survives what restart, by mode:

| Event | Local | Background (new) | Detached (`laband`) |
| --- | --- | --- | --- |
| `LabanApp` restart / upgrade | child dies | **survives** | survives |
| `libghostty` bump in `LabanApp` | child dies | **survives** | survives (parser is in `laband`) |
| `laband` restart / upgrade | n/a | n/a | child dies (current Detached-mode behavior) |
| `labpty` restart / upgrade | n/a | child dies (future fd-handoff plan closes this) | n/a |
| `labpty` crash | n/a | child dies | n/a |
| `laband` crash | n/a | n/a | child dies |
| OS reboot | child dies | child dies | child dies |

### How the three modes split responsibilities

| Responsibility | Local | Background | Detached |
| --- | --- | --- | --- |
| PTY master ownership, child pgroup | `LabanApp` (in-process via `LabanTerminalCore`) | `labpty` | `laband` |
| `libghostty-vt` parser | `LabanApp` (in-process) | `LabanApp` (in-process) | `laband` |
| Output transport | direct (parser reads master fd) | `labpty` byte ring (lock-free SPMC shm) | `laband` parsed-snapshot ring `LBNDSS01` (seqlock cells) |
| Lifecycle journal | `LabanApp` | `LabanApp` | `laband` |
| libproc resolution | `LabanApp` | `LabanApp` (against `foregroundPid`/`foregroundPgid` reported by `labpty`) | `laband` |
| ADR 0002 launch invariants | `Sources/LabanTerminalCore/session_lifecycle.c`, called in-process | same file, called by `labpty` | same file, called by `laband` |
| Multi-client lease | n/a (one client) | n/a (single-writer) | `laband` |

The ADR 0002 launch primitive ends up in three contexts; the C entry
point this plan carves out (`laban_pty_open`) is reusable by all
three.

## Architectural Invariants

These are the spine of the plan. The code and the Review Gate enforce
them. If a step appears to violate one, stop and revise the plan rather
than coding past it.

1. **`labpty` is the sole steady-state reader and writer of every PTY
   master it opens.** No other process — not `LabanApp`, not a test
   harness — reads from or writes to a PTY master fd that `labpty`
   owns. Two processes blocked in `read(2)` on the same PTY master
   race for bytes (POSIX makes no per-byte fairness or atomicity
   guarantee); two writers interleave at sub-write granularity. The
   only safe shape is one custodian.

2. **`LabanApp` consumes output via the shared-memory byte ring
   `labpty` publishes.** Bytes flow `PTY → labpty → byte ring (shm) →
   LabanApp parser in-process`. No JSON, no cell-marshaling daemon,
   no `LBNDSS01`.

3. **`LabanApp` routes input by calling `labpty.writeInput`; it does
   not `write(2)` to a master fd.** Default ships with the
   bounded-rate control-plane RPC; if M4's bench shows a perceptible
   keystroke-latency tax, M5 adds a single-writer SPSC input ring
   (`LBPTY-IR-01`) and `LabanApp` migrates to it.

4. **ADR 0002 PTY launch invariants live inside `labpty`.** Parent-side
   `openpty`, initial winsize before child runs, constrained fork
   child branch, parent-only master fd, teardown via process-group
   escalation. The reference implementation already lives in
   `Sources/LabanTerminalCore/session_lifecycle.c`; `labpty` reuses it
   via a focused C entry point.

5. **`labpty`'s in-memory session catalog is the rediscovery mechanism
   after `LabanApp` restart.** `LabanApp` keeps no persistent map of
   "which `labpty` session belongs to which logical session id"; on
   restart it calls `labpty.listSessions` and reattaches each live
   session's byte ring. The catalog need not survive `labpty`'s own
   restart (that is a future plan's problem).

6. **`labpty` is kept as thin and boring as possible.** Every line of
   `labpty` code is a line that can have a bug, and every `labpty` bug
   forces the one upgrade/restart that still kills live sessions. The
   mode test for every feature: **can `LabanApp` do this without
   `labpty`?** If yes, the feature lives in `LabanApp`, which is
   allowed to change often (its restart now preserves children). A
   feature earns its place in `labpty` only by being (a) required to
   keep the PTY alive (drain output, accept input, resize, signal,
   terminate), (b) required to preserve ADR 0002 (launch invariants),
   or (c) required so `LabanApp` can rediscover sessions after restart
   (`listSessions`, the byte-ring shm path). This explicitly rules out
   in M0–M3: an `attachSession` RPC, wake-pipe `SCM_RIGHTS`,
   per-reader slot-table writes, opaque-snapshot cache, metadata
   ring, deadline enforcement in `labpty`, daemon-global counters,
   stale-reader sweeps. The protocol-design doc records the rationale
   for each deferral. M5's input ring is the one feature in this plan
   that earns its way into `labpty` against criterion (a), and only
   if M4's bench warrants it.

7. **Every non-syscall decision in `labpty` is covered by a property
   test, a fuzzer, or both.** The verification bar that makes "boring"
   stick. The JSON-shaped earlier protocol-design proposal lost on
   exactly this bar; the current binary-frame protocol (`LBPTY-CT-01`)
   is the only `labpty` decoder allowed in this plan.

8. **`labpty` adopts NASA JPL's *Power of Ten* coding rules** plus a
   small set of soft-realtime additions (`mlockall`, scratch-arena
   pre-touch). Certification-grade conventions (DO-178C, MC/DC, tool
   qualification) are out of scope. The protocol-design doc's "Coding
   rules for labpty" section is the binding reference.

## Progress

- [x] M0: Wire-protocol and ring layouts added to `LabanCore`. Eight
  Phase 1 RPC shapes (`hello`, `openSession`, `listSessions`,
  `resizeSession`, `signalSession`, `terminateSession`, `writeInput`,
  `ping`) encode/decode through a 24-byte `LBPTY-CT-01` binary frame.
  `LBPTY-BR-01` byte-ring layout declared. Round-trip unit tests
  cover every shape. Verified 2026-05-27 with
  `swift test --filter LabptyTests` (10 tests, 0 failures).
- [ ] M1: New C executable `labpty`. Owns PTY masters; exposes the
  Phase 1 RPCs over a run-id-scoped Unix socket. ADR 0002 launch
  invariants preserved inside `labpty`. Master drain in M1 discards
  bytes into a small scratch buffer (the byte ring lands in M2).
  Unit-test coverage for open/list/resize/signal/terminate and
  `child_pid` alive/dead.
- [ ] M2: Output byte ring `LBPTY-BR-01` implemented as a lock-free
  single-producer multi-reader shared-memory ring (monotonic
  `output_write_offset`, `output_wrap_count`, 100 ms producer-alive
  heartbeat). `labpty` drains masters into the ring. Readers poll.
  Independent writer/reader tests in `Tests/LabptyTests/`.
- [ ] M3: `LabanApp` gains a `labpty` client path alongside the
  existing `laband` client. `LabptyTerminalSessionClient` drives session
  control and `LabptyByteRingReader` consumes output; the parser is
  `Session.parserOnly(size:)` running in `LabanApp`'s process. The
  Background-mode coordinator routes through this path. The `laband`
  client path stays intact for Detached mode. End-to-end smoke test:
  open a session in Background mode, type, see the cell update; no
  `laband` process running.
- [ ] M4: `Tools/KeystrokeLatencyBench` extended to compare two
  configurations on the same quiet hardware: (a) Detached-mode
  `laband` path, (b) Background-mode `labpty` + App-direct +
  `writeInput` RPC. Histogram artifacts in
  `.artifacts/runs/<run-id>/bench/`. Decision recorded in this plan's
  Decision Log whether M5 ships.
- [ ] M5 (conditional on M4): `LBPTY-IR-01` single-writer SPSC input
  ring for Background mode. `LabanApp` migrates input from
  `writeInput` to the ring; `labpty` drains the ring into the master
  fd. Acceptance: M4 bench reruns and the new histogram closes the
  gap against the pre-`laband` Tier 1 baseline (now reachable via the
  Local-mode bench column).
- [ ] M6: `LabanApp` restart survival acceptance for Background mode.
  Test launches `labpty`, brings up `LabanApp` headless, opens a
  Background session, writes/reads, terminates `LabanApp`, restarts
  it, reattaches via `labpty.listSessions`, writes more, observes new
  output from the **same** `child_pid`.
- [ ] M7: Three-mode selection UI and CLI. The `Terminal Sessions`
  menu gains a `Detached Sessions` item alongside today's `Local
  Sessions` and `Background Sessions` (the latter reassigned from
  `.laband` to `.labpty`). The existing `--terminal-backend` flag,
  per-mode shortcut flags, and `LABAN_TERMINAL_BACKEND` env var
  accept the new canonical `labpty` value and re-pointed
  `background-sessions` alias; a new `--detached-sessions` flag
  joins the existing surface. The session coordinator routes
  through `InProcessTerminalSessionClient`,
  `LabptyTerminalSessionClient`, or `LabandTerminalSessionClient`
  based on the mode. Workspace restore remembers each session's
  mode and reattaches through the same path. Default for new
  sessions is `.labpty` (Background). One-time UserDefaults
  migration keeps users who had `.laband` selected pre-upgrade on
  `.laband` (now Detached). No `laband` deletion.

## Context and Orientation

All paths are repo-relative.

### Where each mode's path lives

All three modes retain their existing code paths. M3 *adds* a
Background-mode path without removing anything.

- `Sources/Laband/main.swift` — `LabandDaemon`, `ManagedLabandSession`,
  per-session libghostty parser, snapshot publishing. Detached mode
  uses this; intact.
- `Sources/LabanCore/LabandProtocol.swift` and
  `Sources/LabanCore/LabandTerminalSessionClient.swift` — `LabanApp`'s
  client of `laband`. Used by the Detached-mode coordinator path;
  intact.
- `Sources/LabanCore/LabandSnapshotRingLayout.swift`,
  `LabandSnapshotRingWriter.swift`, `LabandSnapshotRingReader.swift` —
  the `LBNDSS01` cells ring. Used by the Detached-mode render path;
  intact.
- `Sources/LabanCore/InProcessTerminalSessionClient.swift` — the
  in-process Tier 1 client. Used by Local mode; intact.
- `Sources/LabanApp/AppLabandSessionCoordinator.swift` — `LabanApp`'s
  session lifecycle. M3 generalizes it: the class is renamed to
  `AppSessionCoordinator` (drop the `Laband` infix; the class is no
  longer laband-specific) and gains a `mode: TerminalSessionBackend`
  field that selects between the three transport clients. The
  existing `laband` path becomes the Detached-mode branch; the new
  `labpty` path becomes the Background-mode branch; the existing
  in-process path becomes the Local-mode branch.

### Where the PTY launch and parser-only paths already exist

- `Sources/LabanTerminalCore/session_lifecycle.c` — the ADR 0002 launch
  (parent-side `openpty`, constrained fork child, etc.). M1 carves a
  new minimal C entry point `laban_pty_open(rows, cols, argv, envp,
  cwd, &master_fd, &child_pid)` from this file and exports it via
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`. The new
  entry point performs only the launch — no libghostty session
  construction.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h:223-229`
  declares `laban_session_feed_output(session, bytes, len)`, which
  feeds bytes directly into the VT parser in both fixture and PTY
  modes. The Swift wrapper is `Session.feedOutput(_:)` at
  `Sources/LabanCore/Session.swift:407`. The parser-only mode is
  `Session.fixture(size:)` (PTY-less); M3 wraps this as
  `Session.parserOnly(size:)` for call-site readability.
- `Sources/LabanCore/Persistence/AgentSessionDetector.swift:547` —
  `public struct LibprocIntrospector` is the pid-based Swift libproc
  facade (already used by `RestoreLaunchPlanner` and
  `AgentSessionDetector`). It resolves a pid to executable name,
  path, argv, cwd, and open-fd info via `proc_pidpath`,
  `proc_pidinfo`, and `proc_pidfdinfo`. `LabanApp` reuses this for
  Background-mode foreground-process resolution.
  `Sources/LabanTerminalCore/process_metadata.c`'s C entry point
  takes a `LabanSession *` (it derives pgid from the session's PTY
  fd internally) and is the Detached-mode resolver; **do not** use
  it directly from Background-mode Swift, since Background mode
  does not have a `LabanSession *` against the labpty-owned PTY.
  `labpty` itself does not link libproc and reports only
  `foreground_pid` and `foreground_pgid`.

### Worktree isolation

`docs/process/worktree-isolation.md` and ADR 0005 require dev/test
sockets, journals, and shm files to be run-id-scoped. Apply the same
to `labpty`'s control socket, byte-ring shm files, and (optional)
diagnostic catalog file. Existing patterns use `.tmp/<run-id>/` and
`.artifacts/runs/<run-id>/`.

### Wire-protocol and ring details

The full protocol design (binary frame layout, byte-ring layout,
Power-of-Ten coding rules, capability negotiation, error codes,
verification ladder) lives in
`execplans/active/labpty-protocol-design.md`. That document is
authoritative on every shape and rule; this plan defers to it for
detail and reproduces only what's needed for narrative.

## Pre-flight Findings (2026-05-27)

A pre-handoff survey of the existing tree turned up infrastructure
that materially shapes M3, M4, and M7. **Do not start M3 or later
work without reconciling these.** M0–M2 are unaffected.

### What already exists in 2-mode shape

`LabanApp` already ships a mode-selection layer for two modes
(`inProcess` and `laband`). M7 is **not** building this from scratch;
it extends what's there to a third mode.

- `Sources/LabanCore/TerminalSessionClient.swift` declares
  `TerminalSessionBackend` (currently `case inProcess = "in-process"`,
  `case laband`) and the `TerminalSessionClient` protocol that
  abstracts session lifecycle across backends. `parse(_:)` already
  accepts a generous alias set including `"local-sessions"`,
  `"background-sessions"`, `"daemon-sessions"`, `"persistent"`. The
  third case (`labpty`) lands here.
- `Sources/LabanApp/TerminalBackendSettings.swift` resolves the
  active backend through a precedence chain: command-line flag
  (`--local-sessions`, `--background-sessions`, `--laband-sessions`,
  `--terminal-backend <value>`), env var
  (`LABAN_TERMINAL_BACKEND`), legacy disable flag, persisted
  `UserDefaults` key `LabanTerminalSessionBackend`, automatic
  default. Reuse this precedence; add the third option to each
  layer.
- `Sources/LabanApp/TerminalBackendMenuController.swift` builds the
  `Terminal Sessions` submenu, today with `Local Sessions` and
  `Background Sessions` items, a restart-prompt UX for changes, and
  override-detection for command-line/env overrides. Add the third
  item here.
- `Sources/LabanApp/MenuCommands.swift` wires the
  `TerminalBackendMenuController` into the main menu bar.
- `Sources/LabanApp/AppLabandSessionCoordinator.swift` is the
  per-session coordinator. M3's "rename to `AppSessionCoordinator`
  and add `mode` field" lands here.
- `Tools/KeystrokeLatencyBench/main.swift` exposes
  `--transport {in-process|laband}` and `--socket PATH`. M4 extends
  this with a third transport value, not a new `--mode` flag.

### What does not exist and M0–M7 must create

- `Sources/Labpty/` — entire C executable target. Expected.
- `Sources/LabanCore/Labpty*.swift` — the M0 protocol/framing/byte-
  ring types and the M3 `LabptyTerminalSessionClient`. Expected.
- `Tools/LabptyProtocolFuzz/` — the protocol-design doc names this
  as the primary fuzz target; it does not exist. Codex creates it
  in M1 alongside the frame decoder.
- `Tools/LabptyDump/` — the Decision Log mentions this as a
  human-readable shim for the binary protocol; it does not exist.
  Defer to a follow-up unless `LabanApp` development needs it
  during M3.
- `Tools/LabptyCodingRules/check_function_length.sh` and
  `check_assertion_density.sh` — named in the Review Gate; do not
  exist. Codex writes them in M1 against the patterns in
  `scripts/check-*` (existing examples:
  `scripts/check-debug-contract`, `scripts/check-dependencies`,
  `scripts/check-boundaries`).

### Naming-and-migration tension to resolve before M3

The current menu uses **"Background Sessions"** to mean `laband`.
This plan's mode naming reassigns **"Background sessions"** to mean
`labpty` (the new, faster path), and reassigns the existing
`laband`-backed mode to **"Detached sessions"**.

Consequences for M7:

1. **`TerminalSessionBackend` aliases need re-pointing.** The current
   `parse(_:)` maps `"background-sessions"` and `"persistent"` to
   `.laband`. After M7, `"background-sessions"` must map to the new
   `.labpty` case; the `.laband` case keeps `"detached"`,
   `"detached-sessions"`, `"daemon"`, `"daemon-sessions"`, plus the
   raw value `"laband"` for back-compat.
2. **Persisted `UserDefaults` value `"laband"` must migrate.** A
   user on the current build who selected "Background Sessions"
   has `LabanTerminalSessionBackend = "laband"` in their defaults.
   On first launch under the new build, their stored intent
   ("the daemon-backed mode") is now Detached, not Background.
   The migration: if the raw stored value parses to `.laband`,
   keep it on `.laband` (which is now Detached). No user-visible
   silent switch.
3. **Legacy CLI flag `--background-sessions`** must remap to
   `.labpty` (the new Background mode), and a new
   `--detached-sessions` flag is added for `.laband`. The
   `--laband-sessions` flag stays for explicit back-compat.
4. **Env var `LABAN_TERMINAL_BACKEND`** accepts the additional
   value `labpty` (canonical) plus the alias `background` and its
   neighbors. No env-var rename; `LABAN_SESSION_MODE` was the
   plan's initial proposal but the existing variable serves and
   churning it is unnecessary.

This refines the Decision Log entry "User-facing mode names are
Local / Background / Detached" — the names stand, but the migration
work is real and M7-scoped.

### TerminalSessionClient protocol: keep as-is, dispatch at call sites

The existing `TerminalSessionClient` protocol at
`Sources/LabanCore/TerminalSessionClient.swift:79-95` is shaped
around the laband-mediated path: `attachSnapshotRing` returns a
`LabandSnapshotRingAttachment` (cells ring); `scrollViewport`,
`markRendered`, and `transferLease` assume the cell-ring +
lease-arbitration model. `LabptyTerminalSessionClient` (byte-ring
transport, in-process parser, single writer) cannot implement
these meaningfully.

**M3 decision: Option B. Keep the protocol as-is.**
`LabptyTerminalSessionClient` conforms to `TerminalSessionClient`
and throws `TerminalSessionClientError.protocolError("not supported
for labpty transport")` for the four operations that do not fit
byte-ring semantics: `attachSnapshotRing`, `scrollViewport`,
`markRendered`, `transferLease`. The coordinator
(`AppSessionCoordinator`, renamed in M3 from
`AppLabandSessionCoordinator`) already needs to branch on
`sessionMode` for output-transport setup (cell-ring vs byte-ring +
in-process parser); the four additional conditional dispatches
cost little and stay local to the coordinator.

Recorded in the Decision Log below. The cleaner alternative
(Option A: split the protocol into common + mode-specific
extensions, or lift output-transport setup out of the protocol
entirely) is a welcome later cleanup if dispatch-by-mode proves
ugly; doing it as part of M3 would couple the working
Detached-mode path to the same refactor and multiply risk.

### M4 bench surface

`Tools/KeystrokeLatencyBench/main.swift` already has the option
parser for `--transport in-process|laband` and `--socket PATH`. M4
extends with a third value (`labpty`) and a second socket
(`--labpty-socket PATH`). The bench's verifiedEcho gating
(non-zero exit unless `verifiedEcho=N/N`) is the right model and
should stay.

The output artifact path
`.artifacts/runs/<run-id>/bench/keystroke-latency-comparison.json`
is what the plan named, but verify against the actual artifact
naming convention `bench-keystroke-latency` produces today (look
at `.artifacts/runs/keystroke-latency-after-m8/` from the laband
plan's M8 run for the existing shape).

## Plan of Work

### M0 — Wire-protocol and ring layouts in `LabanCore`

New files:

- `Sources/LabanCore/LabptyProtocol.swift` — plain Swift structs for
  the eight Phase 1 RPC shapes. **Not `Codable`**; each has explicit
  `encode(into: inout Data)` and `decode(from:) throws` methods that
  pack/unpack the binary layout per `labpty-protocol-design.md`'s
  "Common shape rules".
- `Sources/LabanCore/LabptyFraming.swift` — 24-byte
  `labpty_frame_header` encode/decode plus bounds-checked primitive
  helpers (`readU16`, `readU32`, `readU64`, `readBoundedBytes`).
- `Sources/LabanCore/LabptyByteRingLayout.swift` — `LBPTY-BR-01`
  file-header offsets and constants. Power-of-two capacity required.
  Counters block layout matches the protocol-design doc byte-for-byte.
- `Sources/LabanCore/LabptyTerminalSessionClient.swift` — thin Swift
  client that opens a Unix socket, encodes Phase 1 request structs
  through `LabptyFraming` into the binary frame format, writes,
  reads back the response frame, decodes.

Tests in `Tests/LabptyTests/`:

- `testLabptyProtocolRoundTrip` — encode/decode round-trip for each
  request/response shape.
- `testByteRingHeaderConstants` — header offsets and sizes are stable;
  capacity must be a power of two; magic bytes are `b"LBPTY-BR"`.

### M1 — `labpty` executable and ADR 0002 PTY ownership

New SwiftPM C executable target `Labpty` (sibling of `LabanTerminalCore`
in `Package.swift`). Links libc, libSystem, `LabanTerminalCore`. No
Swift runtime.

Files (all C):

- `Sources/Labpty/main.c` — process entry; argument parsing
  (`--socket <path>`, `--shm-dir <path>`); Unix-socket listener via
  `socket(2)` + `bind(2)` + `listen(2)` + `accept(2)`; single-threaded
  `kqueue` event loop dispatching RPCs and per-session master drains.
  `mlockall(MCL_CURRENT | MCL_FUTURE)` at startup; scratch arena
  pre-touch before the event loop begins.
- `Sources/Labpty/labpty_registry.c` + `.h` — in-memory session
  catalog. Open-addressing hash table keyed by `u64 pty_handle`;
  capped at 64 sessions per daemon. Per entry:
  `{ pty_handle, child_pid, master_fd, byte_ring_writer, rows, cols,
  opened_at_mono_ns, logical_session_id[256], foreground_pid,
  foreground_pgid }`. **No foreground-process strings**, no libproc.
- `Sources/Labpty/labpty_frame.c` + `.h` — 24-byte
  `labpty_frame_header_wire` decoder/encoder plus bounds-checking
  primitive helpers (the only place untrusted bytes enter `labpty`;
  the primary fuzz target).
- `Sources/Labpty/labpty_protocol.c` + `.h` — per-op decoders/encoders
  built on `labpty_frame.c`'s primitives. Eight ops in, eight
  responses out, ~20-30 LoC per function. No variable-length
  lookahead, no recursive structures.
- `Sources/Labpty/labpty_pty.c` + `.h` — ADR 0002 launch: reuses the
  existing `Sources/LabanTerminalCore/session_lifecycle.c` internals
  via a new exported entry point `laban_pty_open(rows, cols, argv,
  envp, cwd, &master_fd, &child_pid)`. The new entry point performs
  only the launch; no libghostty session is constructed.
- `Sources/Labpty/labpty_byte_ring.c` + `.h` — C-side byte-ring
  writer. M1 leaves this as a stub; M2 wires it in.
- `Sources/Labpty/include/labpty_internal.h` — internal types shared
  across `labpty`'s C sources.

PTY ownership notes:

- `labpty` performs the ADR 0002 launch directly; the new C entry
  point keeps the invariants in one place.
- Each master fd is registered with `labpty`'s single-threaded
  `kqueue` on `EVFILT_READ`. `labpty` is the only process holding
  the master fd; no code in this plan ever sends that fd to another
  process.
- Master drain in M1 reads into a small scratch buffer and discards
  (just enough to keep the child from blocking on PTY-output
  back-pressure). M2 wires the drain into the byte ring.
- Foreground polling: `tcgetpgrp(master_fd)` returns the foreground
  pgid; `getpgid` (or a second `tcgetpgrp`) confirms a foreground
  pid in the same group. These two `int32` values populate every
  `LabptySessionDescriptor`.

Tests in `Tests/LabptyTests/`:

- `testOpenAndListAndTerminate` — open a session, `listSessions`
  reports it with `alive=true` and a real `child_pid`,
  `terminateSession` returns 0, the pid is gone afterward.
- `testSignalSendsToProcessGroup` — `signalSession` delivers signals
  to the child pgroup. Output-side assertion deferred to M2.
- `testResizeUpdatesWinsize` — `resizeSession` returns ok; visible
  effect (`stty size`) deferred to M2.

### M2 — Output byte ring `LBPTY-BR-01`

Implement the Phase 1 subset of the byte ring (see
`labpty-protocol-design.md` for the full file layout).

New files:

- `Sources/LabanCore/LabptyByteRingWriter.swift` (used by tests and
  diagnostics; the steady-state writer is the C-side in `labpty`).
- `Sources/LabanCore/LabptyByteRingReader.swift` — lock-free reader.
  `readSince(_ last: UInt64) → (bytes, newOffset, overflowed)`.
  Reports `overflowed=true` when `current - last > capacity`.
- `Sources/Labpty/labpty_byte_ring.c` + `.h` — completed
  implementation. Single-producer; `atomic_store_explicit(...,
  memory_order_release)` on the offset after each memcpy.

`labpty` drain wired in:

- Each PTY master's kqueue `read(2)` chunk goes straight into the
  byte-ring writer for that session. No libghostty parser inside
  `labpty`.
- `producer_alive_mono_ns` updated on each event-loop tick, capped at
  100 ms cadence.
- `output_wrap_count` incremented when the writer laps the ring.

`openSession` and `listSessions` include `byteRingShmPath` in every
`LabptySessionDescriptor`. **No descriptor carries a master fd; no
RPC carries `SCM_RIGHTS` ancillary data.** Readers learn the ring
path from the descriptor.

Tests in `Tests/LabptyTests/`:

- `testByteRingHeaderAndCapacity`
- `testByteRingRoundTripSmall`
- `testByteRingWrapDetection`
- `testProducerAliveHeartbeat`

### M3 — `LabanApp` as `labpty` client (Background-mode path)

This is the milestone where `LabanApp` gains the labpty-backed
Background-mode path. After M3 finishes, a session created in
Background mode works end-to-end without involving `laband`; the
existing `laband` codepath stays intact and continues to back
Detached-mode sessions.

Refactor in `Sources/LabanApp/`:

- Rename `AppLabandSessionCoordinator.swift` to
  `AppSessionCoordinator.swift` (drop the `Laband` infix; the class
  is no longer laband-specific). The class is the only owner of
  per-session lifecycle in the app process.
- The coordinator now holds a `LabptyTerminalSessionClient` (control
  channel), a per-session parser-only `Session` (via
  `Session.parserOnly(size:)` from `Sources/LabanCore/`), and a
  `LabptyByteRingReader`.
- Session creation path:
  1. Call `labptyClient.openSession(argv:envp:cwd:rows:cols:logicalSessionId:)`.
  2. Receive `LabptySessionDescriptor` (carries `ptyHandle`,
     `childPid`, `byteRingShmPath`, foreground pids).
  3. Construct `Session.parserOnly(size:)` for the parser.
  4. Open `LabptyByteRingReader(path: descriptor.byteRingShmPath)`.
  5. Start a ring-reader loop (one per session, dedicated dispatch
     queue or `DispatchSourceTimer` ticking initially at 4 ms; the
     cadence can be tuned to the render frame later).
  6. Wire `keystrokeHandler → labptyClient.writeInput(handle:bytes:)`.
- Resize / signal / terminate: route to
  `labptyClient.resizeSession`, `signalSession`, `terminateSession`.
  The local parser also receives `resize(size:)` so its grid matches.
- Foreground process metadata: `LabanApp` resolves
  `descriptor.foregroundPid` via `LibprocIntrospector` from
  `Sources/LabanCore/Persistence/AgentSessionDetector.swift:547`
  (the same Swift type `RestoreLaunchPlanner` and
  `AgentSessionDetector` already use). The C entry point in
  `Sources/LabanTerminalCore/process_metadata.c` is **not** reused
  here because its public signature takes a `LabanSession *` rooted
  in the PTY fd, which Background mode doesn't have; the
  Swift-side pid-based facade is the right entry point.

Optional ergonomic helper:

- `Sources/LabanCore/Session+ParserOnly.swift` — adds
  `Session.parserOnly(size:)` that calls `Session.fixture(size:)`.
  Optional; the underlying function already exists.

Tests in `Tests/LabanAppTests/`:

- `testAppDirectSessionEndToEnd` (new). Launch `labpty` (no `laband`);
  bring up `LabanApp` in headless mode (`HeadlessDebugRuntime`);
  open a session running `/bin/sh -c 'printf STARTED; while read x;
  do echo "got $x"; done'`; type `ping\n`; assert the in-process
  snapshot contains `STARTED` and `got ping`.

### M4 — Keystroke latency bench

Extend `Tools/KeystrokeLatencyBench/main.swift`. The existing parser
accepts `--transport {in-process|laband}` and `--socket PATH`; M4
adds a third value:

- Existing `--transport in-process`: keeps current behavior (Local
  mode reference).
- Existing `--transport laband` with `--socket <laband socket>`:
  Detached-mode reference; stays as the comparison baseline.
- New `--transport labpty` with `--labpty-socket <labpty socket>`:
  drives keystrokes through `LabptyTerminalSessionClient.writeInput`
  and samples cells from an in-process parser fed by the labpty
  byte ring.

The bench's existing `verifiedEcho=N/N` exit-code gating stays as-is
(nonzero exit on any failed sample). Path-length and run-id-scoping
rules from `scripts/run-debug` and `scripts/run-headless` apply.

New helper script `scripts/bench-keystroke-latency` (parallels
`scripts/test-laband-reattach`):

- Runs all three transports against an identical workload on a quiet
  local machine (NOT shared CI — macOS scheduler jitter makes
  absolute thresholds flaky).
- Produces a unified histogram comparison artifact under
  `.artifacts/runs/<run-id>/bench/` (verify the exact filename
  against the existing `keystroke-latency-after-mN/` pattern from
  the laband plan's M8 run).
- Decision criterion baked into the script's exit code: p50 of
  `--transport labpty` within 1.5× of `--transport in-process`
  baseline, p99 within 2×. Miss either gate ⇒ M5 ships.

Acceptance: bench artifact exists; Decision Log entry records the
measured ratios and the M5 ship/skip outcome.

### M5 (conditional on M4) — `LBPTY-IR-01` single-writer SPSC input ring

Only shipped if M4 bench shows the `writeInput` RPC delta is
perceptible.

New files:

- `Sources/LabanCore/LabptyInputRingWriter.swift` — single-producer
  Swift writer. Mirrors the byte-ring writer's atomic-offset
  discipline.
- `Sources/Labpty/labpty_input_ring.c` + `.h` — single-consumer C
  reader inside `labpty`'s event loop. Drains the ring into the PTY
  master via `write(2)` under the existing master-write lock.

`LabptyByteRingLayout` populates the previously-reserved
`input_ring_offset` and `input_ring_capacity` header fields. Default
input-ring capacity: 64 KiB (matches the protocol-design doc).

`labpty` capability negotiation:

- `labpty`'s `hello` response gains `input-ring/v1` in its capability
  set.
- `openSession` response gains an `inputRingShmPath` field via an
  `abi_minor` bump (ABI major stays 1). Existing readers ignore
  unknown trailing fields per the binary-frame contract.
- `LabanApp` uses the input ring iff the capability negotiates true;
  otherwise it falls back to `writeInput`.

**Decoupling from `multi-attach-write-lease/v1`:** the protocol-design
doc currently couples `input-ring/v1` to a multi-attach write lease
because multi-writer shared-memory has no safe semantics. This plan's
M5 ships the **single-writer flavor** — one app, one writer, one
consumer — which does not need the lease. A future multi-writer
scenario re-introduces the lease primitive against a concrete use
case. An additive paragraph in `labpty-protocol-design.md` records
this carve-out.

Tests in `Tests/LabptyTests/`:

- `testInputRingRoundTrip` — writer writes; `labpty` drains; PTY
  child observes the bytes.
- `testInputRingOverflowBackpressure` — writer can detect when the
  ring is full (or `labpty` is wedged); reports it to the caller.

Acceptance: bench rerun closes the gap to the pre-`laband` baseline
within the criterion in M4.

### M6 — `LabanApp` restart survival acceptance

The headline test that proves the value this plan ships.

New `Tests/LabanAppTests/LabanAppRestartSurvivalTests.swift`:

- `testLabanAppRestartPreservesChildViaLabpty`:
  1. Harness launches `labpty` (run-id-scoped socket + shm dir).
  2. Launches `LabanApp` headless. Opens a session running `/bin/sh -c
     'printf STARTED; while read x; do echo "got $x"; done'`.
  3. Records `child_pid` via the headless-debug endpoint. Sends `ping\n`;
     observes snapshot contains `STARTED` and `got ping`.
  4. Terminates `LabanApp` (`SIGTERM` to the headless host). Waits for
     exit. Verifies `labpty` and the child are both still alive.
  5. Relaunches `LabanApp` headless. Calls `labpty.listSessions`;
     finds the existing session; reattaches the byte ring; parser
     warms via in-ring "replay from current window."
  6. Sends `pong\n`. Asserts new snapshot contains `got pong`.
  7. Asserts `child_pid` from step 5's reattach equals step 3's pid.

New `scripts/test-labanapp-survives-restart`:

- Interactive analog of the test for local verification.
- Same scenario, run manually; outputs a clear "child survived /
  child died" line at the end.

### M7 — Three-mode selection UI and CLI

Surface the three modes to users. Internal names (`labpty`, `laband`)
stay out of the user-facing surface.

**Menu** — `Workspace → Terminal Sessions` gains a submenu with three
items, presented in this order:

```
Local sessions
Background sessions     (default for new sessions)
Detached sessions
```

The currently-selected option has a checkmark. Changing the selection
applies to **new** sessions opened from this point onward; existing
sessions keep the mode they were created with for their lifetime
(no mid-session migration in this plan; that is a future ExecPlan if
it is ever wanted).

**CLI / environment** — extend the existing `TerminalBackendSettings`
surface (defined in `Sources/LabanApp/TerminalBackendSettings.swift`).
Both `LabanApp` and `--headless` mode parse:

```
--terminal-backend <value>   # canonical: in-process | labpty | laband
                             # aliases: local|local-sessions → in-process
                             #          background|background-sessions → labpty
                             #          detached|detached-sessions|daemon|daemon-sessions → laband
--local-sessions             # short form, in-process (UNCHANGED meaning)
--background-sessions        # short form, labpty (REASSIGNED — was laband)
--detached-sessions          # short form, laband (NEW)
--laband-sessions            # short form, laband (back-compat alias, unchanged)
LABAN_TERMINAL_BACKEND=<value>   # same values and aliases
```

Precedence, low to high (preserved from today's
`TerminalBackendSettings.resolve(...)`): automatic default →
persisted `LabanTerminalSessionBackend` UserDefaults → legacy
`LABAN_DISABLE_PRODUCT_LABAND` flag → `LABAN_TERMINAL_BACKEND` env →
CLI flag → in-app menu selection. Workspace restore remembers each
session's mode in the per-session state file and replays the same
mode on relaunch.

The default for new sessions is `.labpty` (the Background mode);
the existing automatic-default branch in `TerminalBackendSettings`
is changed from `.inProcess` to `.labpty`.

**Routing inside `LabanApp`** — `AppSessionCoordinator` (renamed
from `AppLabandSessionCoordinator` in M3) gains a `sessionMode`
field. The session-creation path branches:

| Mode | Client | PTY owner | Parser location |
| --- | --- | --- | --- |
| `local` | `InProcessTerminalSessionClient` (existing) | `LabanApp` | in-process |
| `background` | `LabptyTerminalSessionClient` (M3) | `labpty` | in-process |
| `detached` | `LabandTerminalSessionClient` (existing) | `laband` | `laband` |

The coordinator owns a `LabptyTerminalSessionClient` (lazy-started
when the first `background` session is opened, against
`LABAN_LABPTY_SOCKET` or a default per-user socket path) and a
`LabandTerminalSessionClient` (lazy-started likewise for `detached`).
Mode-specific lifecycles are isolated: a `labpty` daemon outage
affects only Background sessions; a `laband` daemon outage affects
only Detached sessions; Local sessions are independent of both.

**Files touched** (all confirmed to exist in the current tree as of
the 2026-05-27 pre-flight; see "Pre-flight Findings" above):

- `Sources/LabanCore/TerminalSessionClient.swift` — add a third
  `TerminalSessionBackend` case `case labpty = "labpty"`; rework
  `parse(_:)` aliases per the naming-and-migration tension in the
  pre-flight findings (`"background-sessions"` now maps to `.labpty`;
  `.laband` keeps `"laband"`, `"detached"`, `"detached-sessions"`,
  `"daemon"`, `"daemon-sessions"`).
- `Sources/LabanApp/TerminalBackendSettings.swift` — extend
  `commandLineBackend(arguments:)` to recognize `--detached-sessions`
  (maps to `.laband`); the existing `--background-sessions` now maps
  to `.labpty`; `--laband-sessions` stays as an explicit alias for
  `.laband` (back-compat). Add the defaults-migration entry point
  the pre-flight findings describe.
- `Sources/LabanApp/TerminalBackendMenuController.swift` — add a
  third menu item `Detached Sessions` with `@objc selectDetached(_:)`
  invoking `select(.laband)`; rename `selectLaband` to
  `selectBackground` and have it invoke `select(.labpty)`. Update
  the `syncMenuState` checkmark logic to handle three items. Update
  the restart-prompt copy.
- `Sources/LabanApp/MenuCommands.swift` — no functional change; the
  controller wires the three-item submenu into the same menu slot.
- `Sources/LabanApp/AppLabandSessionCoordinator.swift` — rename to
  `Sources/LabanApp/AppSessionCoordinator.swift`; gain a
  `sessionMode: TerminalSessionBackend` field and three-way
  routing. Per the Pre-flight Findings, `LabptyTerminalSessionClient`
  conforms to `TerminalSessionClient` but throws
  `protocolError("not supported for labpty transport")` for
  `attachSnapshotRing`, `scrollViewport`, `markRendered`, and
  `transferLease`; the coordinator branches on `sessionMode` at
  these call sites.
- Workspace persistence: each persisted session record gains a
  `sessionMode` field. Locate the existing persistence module via
  `grep -rn 'TabState\|WorkspacePersistence\|persistSession'
  Sources/LabanApp/` if the path isn't obvious; the laband plan's
  M5 work added the durable tab-id field there, so the file is
  already in flux.

**Tests:**

- `Tests/LabanAppTests/SessionModeRoutingTests.swift` (new). Three
  test cases:
  - `testLocalModeUsesInProcessClient` — open with mode `local`,
    assert no `labpty` or `laband` process is running, assert the
    coordinator holds an `InProcessTerminalSessionClient`.
  - `testBackgroundModeUsesLabptyClient` — open with mode `background`,
    assert a `labpty` process is running, assert the session survives
    `LabanApp` restart (subset of M6).
  - `testDetachedModeUsesLabandClient` — open with mode `detached`,
    assert a `laband` process is running, assert the session survives
    `LabanApp` restart with full scrollback intact.
- `Tests/LabanAppTests/SessionModePersistenceTests.swift` (new).
  Open sessions in all three modes, save workspace, restore, assert
  each session reattaches via its original mode.
- `Tests/LabanAppTests/SessionModeCLITests.swift` (new). Verify
  the precedence chain
  `TerminalBackendSettings.resolve(...)` already implements
  (automatic → persisted UserDefaults → legacy disable flag →
  `LABAN_TERMINAL_BACKEND` env → CLI flag) plus the in-app menu
  selection persisting to UserDefaults. The new canonical
  automatic default is `.labpty`.

**Documentation:**

- `docs/product/spec.md` — short subsection under terminal sessions
  describing the three modes in user-facing language (lifecycle
  scope, when each mode is appropriate). The internal names
  (`labpty`, `laband`) do not appear in the user-facing doc.
- `AGENTS.md` — no changes; the three-mode shape does not change the
  ADR index entries.

No `laband` deletion. The Detached-mode path keeps working exactly
as it does today; M7 makes it visible and selectable instead of
implicit.

## Concrete Steps

All commands from the repo root.

```
# Build the new labpty executable in isolation.
swift build --product labpty

# Build everything (labpty + laband + LabanApp; all three modes ship).
./scripts/build-app

# Unit tests.
swift test --filter LabptyTests
swift test --filter LabanAppTests.testAppDirectSessionEndToEnd
swift test --filter LabanAppTests.SessionModeRoutingTests
swift test --filter LabanAppTests.SessionModePersistenceTests
swift test --filter LabanAppTests.SessionModeCLITests

# Bench (manual, quiet local machine). Compares all three modes.
./scripts/bench-keystroke-latency

# Background-mode restart-survival acceptance.
swift test --filter LabanAppTests.LabanAppRestartSurvivalTests

# Interactive acceptance.
./scripts/test-labanapp-survives-restart

# Per-mode launch examples (CLI / env).
LabanApp --terminal-backend in-process       # Local mode
LabanApp --terminal-backend labpty           # Background mode
LabanApp --terminal-backend laband           # Detached mode
LabanApp --local-sessions                    # short form, Local
LabanApp --background-sessions               # short form, Background (labpty)
LabanApp --detached-sessions                 # short form, Detached (laband)
LABAN_TERMINAL_BACKEND=labpty LabanApp       # env, Background
LABAN_TERMINAL_BACKEND=detached LabanApp     # env, Detached (alias)
```

Expected transcript for `testLabanAppRestartPreservesChildViaLabpty`:

```
Test Case 'testLabanAppRestartPreservesChildViaLabpty' started.
[harness] launched labpty pid=NNN socket=.tmp/<run-id>/labpty/s.sock
[harness] launched LabanApp headless pid=MMM
[client] createSession sh -c '...'  -> logicalSessionId=L1, child_pid=KKK
[client] writeInput "ping\n"        -> ok
[snapshot] contains "STARTED" and "got ping"
[harness] SIGTERM LabanApp pid MMM; wait for exit
[harness] verify labpty pid=NNN alive; verify child_pid=KKK alive
[harness] relaunched LabanApp pid=MMM' against same labpty
[client] listSessions               -> 1 session, child_pid=KKK
[client] writeInput "pong\n"        -> ok
[snapshot] contains "got pong"
[assert] child_pid before == child_pid after  (KKK == KKK)
Test Case 'testLabanAppRestartPreservesChildViaLabpty' passed (X.XX seconds)
```

## Validation and Acceptance

Each milestone gates on observable behavior, not types or compilation.

**M0:** `swift test --filter LabptyTests.testLabptyProtocolRoundTrip`
and `testByteRingHeaderConstants` exit 0.

**M1:** `swift test --filter LabptyTests.testOpenAndListAndTerminate`
exits 0. The test launches the real `labpty` binary, opens a child
running `/bin/sh`, asserts `child_pid > 0` and the pid is alive via
`kill(pid, 0)`, terminates, asserts `kill(pid, 0)` returns -1.

**M2:** Byte-ring tests pass; manual sanity check that a `printf foo`
session's bytes appear in the ring.

**M3:** `testAppDirectSessionEndToEnd` exits 0 with no `laband`
process anywhere.

**M4:** Bench artifact at
`.artifacts/runs/<run-id>/bench/keystroke-latency-comparison.json`
exists. Decision Log records p50/p99 ratios and the M5 ship/skip
outcome.

**M5 (if shipped):** Input-ring tests pass; bench rerun shows the gap
to the pre-pivot baseline closed.

**M6:** `testLabanAppRestartPreservesChildViaLabpty` passes. Identical
`child_pid` before and after `LabanApp` restart.

**M7:** All three modes are reachable and routable.

- Menu inspection: `Terminal Sessions` shows the three items
  `Local Sessions`, `Background Sessions`, `Detached Sessions`,
  with `Background Sessions` checked by default. Verified through
  the headless menu-introspection endpoint, not host-global
  `defaults read`.
- `LabanApp --terminal-backend {in-process|labpty|laband}` accepts
  each canonical value plus aliases (`local`, `background`,
  `detached`, etc.); passing any unknown value exits nonzero with
  a usage error naming the accepted set.
- `LABAN_TERMINAL_BACKEND` respected by both AppKit and headless
  mode with the same value set.
- Per-mode shortcut flags `--local-sessions`,
  `--background-sessions`, `--detached-sessions`, and
  `--laband-sessions` route as documented.
- `SessionModeRoutingTests`, `SessionModePersistenceTests`,
  `SessionModeCLITests` all pass.
- Per-mode smoke (using run-id-scoped sockets that the test
  harness owns; no global `pgrep`): Local mode opens a session
  with no labpty/laband process started under
  `.tmp/<run-id>/`; Background mode produces a session visible
  through `labpty.listSessions` on the run-id-scoped socket;
  Detached mode produces a session visible through
  `laband.listSessions` on the run-id-scoped socket.
- UserDefaults migration: an isolated-defaults test with
  `LabanTerminalSessionBackend = "laband"` seeded pre-launch
  still routes to the laband-backed Detached path after the
  upgrade.

## Idempotence and Recovery

Every milestone in this plan is additive. No file deletions, no
existing-behavior regressions.

M0–M2 are additive within `Sources/Labpty/`, `Sources/LabanCore/Labpty*.swift`,
and `Tests/LabptyTests/`. They do not modify existing behavior.

M3 is the first milestone that changes `LabanApp` source: the
session coordinator is generalized to route by mode. The Detached
path (existing `LabandTerminalSessionClient`) continues to work
unchanged; the Local path (existing in-process client) continues to
work unchanged; the Background path is the new branch. If M3 breaks
something mid-flight, reverting the `Sources/LabanApp/AppSession*`
files returns to the pre-M3 single-path coordinator.

M4 and M5 do not change `LabanApp` behavior; M5 adds a new path
behind capability negotiation (old `labpty` builds still work with
new `LabanApp` and vice versa, and Background sessions fall back to
`writeInput` if `input-ring/v1` is missing).

M6 only adds tests.

M7 is non-destructive. It surfaces the three modes through menu,
CLI, and env. No existing path is removed; no daemon binary is
deleted. If the menu wiring or CLI parsing breaks something,
reverting the M7 commits restores the M6 state.

Sockets, byte-ring shm files, and the optional diagnostic catalog
all live under run-id-scoped paths. Re-running tests cleans them up.
There is no machine-wide state to migrate.

If a test leaves processes running, `pkill -f '/labpty --socket .tmp/'`
and `pkill -f '/laband --socket .tmp/'` clean up; the test harness
should also do this in `tearDown`.

## Interfaces and Dependencies

### Module dependency graph after M7

- `Labpty` (new C executable) depends on `LabanTerminalCore` (the C
  target, for the `laban_pty_open` entry point and the process-group
  teardown helper). Links libc, libSystem, `LabanTerminalCore`.
  Nothing else.
- `Laband` (existing Swift executable) unchanged; still depends on
  `LabanCore`, `LabanRenderer`, `LabanDebug`, `LabanTerminalCore`.
- `LabanCore` (Swift) gains `LabptyProtocol.swift`,
  `LabptyFraming.swift`, `LabptyByteRingLayout.swift`,
  `LabptyByteRingReader.swift`,
  `LabptyTerminalSessionClient.swift`,
  `Session+ParserOnly.swift` (optional),
  `LabptyInputRingWriter.swift` (only if M5 shipped). The existing
  `Laband*` types and the `LabandSnapshotRing*` files stay.
- `LabanApp` (Swift) imports `LabanCore`'s `Labpty*` types alongside
  the existing `Laband*` types. The session coordinator holds three
  client implementations and selects one at session open per mode.

### Protocol surface

The eight Phase 1 RPCs (`hello`, `openSession`, `listSessions`,
`resizeSession`, `signalSession`, `terminateSession`, `writeInput`,
`ping`) and the `LBPTY-BR-01` byte-ring layout are documented
authoritatively in `execplans/active/labpty-protocol-design.md`.
This plan does not reproduce the wire byte order or the per-field
caps; refer to the protocol-design doc.

Capabilities negotiated at `hello` (Phase 1 set):

- `byte-ring/v1` — required.
- `write-input-rpc/v1` — required.
- `heartbeat-shm/v1` — required.
- `session-id-pinning/v1` — required.
- `input-ring/v1` — present only if M5 shipped; single-writer flavor
  as documented in this plan's Decision Log and the protocol-design
  doc's additive paragraph.

### What `LabanApp` gains for Background mode

- The ring-reader loop and parser-feed code path. Structurally
  identical to the pre-`laband` Tier 1 path; the byte source is a
  shm ring rather than a master fd.
- `LabptyTerminalSessionClient` for control operations on Background
  sessions.
- libproc resolution against `labpty`-reported foreground pids via
  `LibprocIntrospector`
  (`Sources/LabanCore/Persistence/AgentSessionDetector.swift:547`),
  the existing public pid-based Swift facade. Background mode
  calls it with `LabptySessionDescriptor.foregroundPid` rather
  than receiving resolved strings from `laband`.
- Per-session lifecycle journaling for Background sessions inside
  `LabanApp` (Detached sessions continue to be journaled by `laband`
  itself).

## Decision Log

- Decision: Three coexisting modes (Local / Background / Detached).
  `laband` is retained intact, not deleted.
  Rationale: An earlier draft of this plan proposed deleting `laband`
  in a final milestone on the grounds that its responsibilities
  (parsing, multi-client viewing, parsed-cell publishing, lease) are
  individually either speculative (multi-client cast/share/remote) or
  recoverable from the labpty foundation later (parser moves
  in-process, single-writer doesn't need a lease). A subsequent
  decision (2026-05-27, user direction) reversed that: `laband`'s
  future is undecided, deletion is premature, and the three modes
  should coexist so usage can decide which earns its place.
  Concrete reasons to keep `laband` in tree:
  (a) Detached mode is the only path that preserves complete
  scrollback through long `LabanApp` absences (Background mode is
  bounded by the byte-ring window).
  (b) Multi-client viewing and lease-arbitrated input — the two
  speculative futures — already work in `laband`; deleting them and
  rebuilding from labpty later costs more than keeping them.
  (c) The known correctness bugs in `laband` (notably copy-paste
  across the snapshot ring) motivate Background mode as the new
  default but do not require `laband` to be removed from the tree.
  The cost is the maintenance overhead of three modes; the benefit
  is preserved optionality and a comparison surface for measuring
  which futures matter.
  Date/Author: 2026-05-27 / user reversal of pivot iteration.

- Decision: M3 keeps `TerminalSessionClient` as-is;
  `LabptyTerminalSessionClient` throws `protocolError` for the
  operations that don't fit byte-ring transport. (Option B over
  Option A.)
  Rationale: The existing `TerminalSessionClient` protocol at
  `Sources/LabanCore/TerminalSessionClient.swift:79-95` is shaped
  around the laband-mediated path: `attachSnapshotRing` returns
  `LabandSnapshotRingAttachment` (cells ring); `scrollViewport`,
  `markRendered`, and `transferLease` assume cell-ring +
  lease-arbitration model. `LabptyTerminalSessionClient` cannot
  implement these meaningfully under byte-ring transport. Option A
  (split the protocol into common + mode-specific extensions, or
  lift output-transport setup out of the protocol entirely) is
  cleaner but couples M3 with a refactor of the working
  Detached-mode path; Option B contains the change to the new
  `LabptyTerminalSessionClient` plus a few conditional dispatches
  in `AppSessionCoordinator` (which already branches on
  `sessionMode` for output-transport setup). Additive change beats
  coupled refactor while the new path is being proven. Option A
  is welcome in a later plan if dispatch-by-mode call sites
  become ugly.
  Date/Author: 2026-05-27 / Codex review reconciliation.

- Decision: CLI / env surface extends `TerminalBackendSettings`'s
  existing flags and env var; no new `--session-mode` flag or
  `LABAN_SESSION_MODE` env var.
  Rationale: An earlier draft of this plan proposed a new
  `--session-mode` flag and `LABAN_SESSION_MODE` env var. The
  Pre-flight Findings turned up that
  `Sources/LabanApp/TerminalBackendSettings.swift` already
  resolves through a full precedence chain over `--terminal-backend`,
  per-mode shortcut flags (`--local-sessions`,
  `--background-sessions`, `--laband-sessions`), and
  `LABAN_TERMINAL_BACKEND`. Adding a parallel
  `--session-mode`/`LABAN_SESSION_MODE` surface would churn the
  working code, add a layer to the precedence chain, and force
  users to learn two ways to express the same intent. Extending
  the existing surface: add `--detached-sessions`, repoint
  `--background-sessions` (and the `background` /
  `background-sessions` aliases) from `.laband` to `.labpty`,
  keep `--laband-sessions` as an explicit back-compat alias, and
  let `--terminal-backend` accept `labpty` as a canonical value.
  Net cost is one breaking change to the meaning of
  `--background-sessions`; the alternative was churn across the
  entire CLI/env surface.
  Date/Author: 2026-05-27 / Codex review reconciliation.

- Decision: Background-mode libproc resolution uses
  `LibprocIntrospector`
  (`Sources/LabanCore/Persistence/AgentSessionDetector.swift:547`),
  not the C entry point in
  `Sources/LabanTerminalCore/process_metadata.c`.
  Rationale: An earlier draft claimed Background mode could call
  the existing C helper against `LabptySessionDescriptor.foregroundPid`.
  Codex's pre-implementation review caught this: the C public API
  takes a `LabanSession *` (it derives pgid from the session's PTY
  fd internally), and Background mode does not have a
  `LabanSession *` rooted in the labpty-owned PTY. The right
  reuse target is `LibprocIntrospector`, a public pid-based Swift
  facade already used by `RestoreLaunchPlanner` and
  `AgentSessionDetector`. It exposes `proc_pidpath`,
  `proc_pidinfo`, and `proc_pidfdinfo` against a raw pid, which
  is exactly what Background mode needs.
  Date/Author: 2026-05-27 / Codex review reconciliation.

- Decision: `labpty` is implemented in C, not Swift.
  Rationale: `labpty`'s work is `openpty`, `fork`, `execve`, `read`,
  `write`, `kqueue`/`kevent`, `mmap`/`shm_open`, atomics on shm
  regions, and `killpg` — exactly what C is built for. Swift gives
  collections, optionals, and `throws` ergonomics that `labpty`
  doesn't materially benefit from, in exchange for runtime/ARC/
  Foundation surface that costs binary size and audit complexity.
  Smaller binary, smaller dependency closure, fewer Swift-runtime
  traps to reason about during a `labpty` upgrade. The Swift-side
  pieces that talk to `labpty` (`LabptyTerminalSessionClient`,
  `LabptyByteRingReader`, `LabptyProtocol` structs) stay Swift
  because they live in `LabanApp`'s universe; the contract between
  the two languages is the binary wire format plus the shm layout,
  both fixed in `labpty-protocol-design.md`.
  Date/Author: 2026-05-27.

- Decision: Control plane is length-prefixed binary frames
  (`LBPTY-CT-01`), not JSON.
  Rationale: A JSON parser in C is the single most-exposed surface
  in `labpty`, ~300 LoC at minimum, mandatory fuzz target. The
  binary frame decoder is ~80 LoC, trivially fuzzable (one bounds
  check per length-prefix), and lets `writeInput` carry raw bytes
  without base64. Human-readable debugging is preserved through a
  separate `Tools/LabptyDump` Swift CLI that connects to a `labpty`
  socket and pretty-prints captured frames — one-time cost, never
  on the hot path. The protocol-design doc records the full
  rationale.
  Date/Author: 2026-05-27.

- Decision: `labpty` reports foreground **pid + pgid only**;
  `LabanApp` resolves the executable name, command path, argv, and
  cwd via its own libproc helper.
  Rationale: Earlier drafts had `labpty` populate four 1024-byte
  foreground-process strings on every `LabptySessionDescriptor`.
  That pulled libproc, string-truncation rules, and ~5 KiB of
  per-session descriptor bloat into `labpty` — exactly the kind of
  feature that grows the custodian without earning kernel-resource
  ownership. `labpty`'s irreducible foreground role is the
  `tcgetpgrp(master_fd)` + `getpgid` calls that *only* the master-fd
  holder can make; once those return a pid, anyone same-uid
  (notably `LabanApp`) can resolve the rest via libproc against
  that pid. The two `int32` fields fit in 8 bytes per descriptor,
  `labpty` no longer links libproc, and `LabanApp` already has a
  public pid-based libproc facade — `LibprocIntrospector` at
  `Sources/LabanCore/Persistence/AgentSessionDetector.swift:547`,
  already used by `RestoreLaunchPlanner` and `AgentSessionDetector`.
  (The C entry point in
  `Sources/LabanTerminalCore/process_metadata.c` takes a
  `LabanSession *` and is the Detached-mode resolver; Background
  mode uses the Swift facade.)
  Date/Author: 2026-05-27.

- Decision: `labpty` adopts NASA JPL's *Power of Ten* rules as its
  coding-rule baseline. Certification-grade conventions (DO-178C,
  MC/DC, tool qualification) are explicitly out of scope.
  Rationale: `labpty` is soft-realtime, kernel-adjacent C with
  operational stakes (its bugs cost user terminal sessions until a
  future fd-handoff plan ships), but not safety-critical in the
  avionics sense. The Power of Ten subset delivers small,
  predictable, audit-friendly code at single-digit percent of the
  certification cost. The full mapping plus exclusions lives in
  `labpty-protocol-design.md`'s "Coding rules for labpty" section.
  Date/Author: 2026-05-27.

- Decision: Phase 1 readers (just `LabanApp`) poll the byte ring;
  no wake mechanism in `labpty`. No `SCM_RIGHTS` anywhere in this
  plan.
  Rationale: An earlier draft accepted a wake-pipe write fd via
  `SCM_RIGHTS` at session attach and ran a per-reader slot table.
  That bought ~3 ms of wake latency over a 4 ms polling tick —
  invisible inside `LabanApp`'s ~16 ms render-frame cadence. The
  per-reader registry, wake-pending flag protocol, `SCM_RIGHTS`
  plumbing, and stale-reader sweep logic are not required for the
  acceptance test (`LabanApp` restart preserves the child) and add
  code to `labpty` whose only job is to make `LabanApp` slightly
  faster than it needs to be. Polling delivers the same user
  outcome at zero `labpty` state. A future plan may revisit if the
  4 ms tick becomes a perceptible latency source.
  Date/Author: 2026-05-27.

- Decision: This plan does not have an `attachSession` RPC.
  Rationale: With polling instead of wake pipes, `labpty` learns
  nothing at attach that it didn't already know. `listSessions`
  returns the byte-ring shm path on every descriptor, which is
  what `LabanApp` (and any future reader) needs to start consuming.
  Eliminating the RPC removes ~100 lines of `labpty` code plus one
  round-trip from every reader's startup path.
  Date/Author: 2026-05-27.

- Decision: `labpty` does not enforce request deadlines.
  Rationale: A deadline check is a `clock_gettime` syscall per RPC
  plus a code path to test. RPC rate is bounded by user action
  (open/resize/terminate happen seconds apart; `writeInput` rate is
  typing speed). The failure modes a deadline catches are caught
  more cheaply by the client's own socket timeout. Clients may
  include `deadline_ns` in the envelope; `labpty` ignores it. The
  protocol's frame header has no slot for one; if deadline
  enforcement is ever needed, it lands behind an `abi_minor` bump.
  Date/Author: 2026-05-27.

- Decision: Single-writer `LBPTY-IR-01` (M5, conditional) is
  decoupled from the protocol-design doc's
  `multi-attach-write-lease/v1` claim.
  Rationale: The protocol-design doc currently couples
  `input-ring/v1` to `multi-attach-write-lease/v1` because
  multi-writer shared-memory has no safe semantics without an
  arbitrating lease. This plan's constraint is single-writer (one
  `LabanApp`, one writer); the lease problem doesn't arise. If M5
  ships, it lands as the single-writer flavor; a future plan can
  extend it to multi-writer when that case is concrete.
  Date/Author: 2026-05-27.

- Decision: User-facing mode names are Local / Background / Detached.
  Internal daemon names (`labpty`, `laband`) do not appear in the
  menu or in user-facing docs.
  Rationale: The user picks a mode by the lifecycle they want, not
  by which daemon owns the bytes. "Local" is universally understood
  for "lives in this app instance." "Background" matches the user's
  proposed wording and conveys "running but not in the foreground."
  "Detached" carries the tmux/screen reading directly — a session
  that's been detached from any client and continues to run — which
  is exactly the property the `laband`-mediated path provides
  (continuous parsing with no app attached). Considered alternatives:
  "Persistent" for Background (rejected because Detached is also
  persistent — the distinguishing property is *what state survives*,
  which is what Local/Background/Detached convey better);
  "Always-on" or "Continuous" for Detached (rejected because both
  evoke daemon-internals more than user-visible behavior); using
  `labpty` / `laband` directly (rejected because internal daemon
  names leak implementation choices into the menu).
  Date/Author: 2026-05-27.

- Decision: ADR 0006 (three-tier session architecture) is **not**
  amended by this plan.
  Rationale: ADR 0006 commits to three coexisting tiers: in-process
  (Tier 1, now Local mode), `laband` multi-client serving (Tier 2,
  now Detached mode), and `labpty` upgrade-proof (Tier 3, now
  Background mode). The earlier draft of this plan deleted `laband`
  and collapsed the architecture to two tiers, requiring an ADR
  amendment. The current plan preserves all three tiers as
  user-selectable modes, so ADR 0006's architectural commitment
  remains accurate and no edit is needed. A future plan that
  decides `laband`'s fate (deletion, evolution, or further
  investment) will revisit the ADR if it changes the tier shape.
  Date/Author: 2026-05-27 / superseded the earlier amendment
  decision.

## Review Gate

A separate fresh-state agent must verify the following before this
plan is considered complete. The executing agent must not mark the
plan as done until this gate has passed.

The checks are deliberately mechanical so a fresh agent can run them
without judgment.

### Build and tests

- [ ] `swift build --product labpty` exits 0.
- [ ] `swift test --filter LabptyTests` exits 0.
- [ ] `swift test --filter LabanAppTests.testAppDirectSessionEndToEnd`
  exits 0; the test runs with no `laband` process anywhere.
- [ ] `swift test --filter
  LabanAppTests.testLabanAppRestartPreservesChildViaLabpty` exits 0,
  and the test transcript shows: (a) the same `child_pid` before and
  after `LabanApp` restart; (b) `writeInput` issued before restart
  produced observable output; (c) `writeInput` issued after restart
  produced fresh observable output from the same child.
- [ ] `./scripts/build-app` exits 0 and the bundle at
  `.build/laban/Laban.app/Contents/MacOS/` contains all three of
  `labpty`, `laband`, and `LabanApp`.

### Invariants (mechanical greps)

- [ ] `git grep -n 'LabptyTerminalSessionClient' Sources/LabanApp/`
  returns at least one hit (Background-mode path).
- [ ] `git grep -n 'LabandTerminalSessionClient' Sources/LabanApp/`
  returns at least one hit (Detached-mode path retained).
- [ ] `git grep -n 'InProcessTerminalSessionClient' Sources/LabanApp/`
  returns at least one hit (Local-mode path retained).
- [ ] `Sources/Laband/`, `Tests/LabandTests/`, and the
  `Sources/LabanCore/Laband*.swift` files still exist in the tree
  (not deleted by this plan).
- [ ] `git grep -nE 'SCM_RIGHTS|sendmsg|cmsghdr' Sources/LabanApp/
  Sources/LabanCore/Labpty*.swift Sources/Labpty/` returns zero hits.
- [ ] `git grep -nE 'attachSession|LabptyAttach' Sources/Labpty/
  Sources/LabanCore/Labpty*.swift Sources/LabanApp/` returns zero
  hits.
- [ ] `git grep -nE 'wake_pending|wakePipe|wake_pipe' Sources/Labpty/
  Sources/LabanCore/Labpty*.swift` returns zero hits.
- [ ] `git grep -nE 'json|JSON|jansson|cJSON|jsmn' Sources/Labpty/`
  returns zero hits.
- [ ] `git grep -nE 'memcpy\([^,]*,[^,]*frame.*header|memcpy\([^,]*,[^,]*[Hh]eader.*frame'
  Sources/Labpty/` returns zero hits. (Frame header is read field by
  field through bounded helpers.)
- [ ] `git grep -nE 'char\s+pty_handle\s*\[' Sources/Labpty/
  Sources/LabanCore/Labpty*.swift` returns zero hits. (`pty_handle`
  is `u64`, not a string.)
- [ ] `git grep -nE 'proc_name|proc_pidpath|proc_pidinfo|libproc'
  Sources/Labpty/` returns zero hits. (`labpty` reports only pids;
  libproc resolution stays in `LabanApp`.)

### Power of Ten coding rules (`Sources/Labpty/`)

- [ ] `git grep -nE '\bgoto\b' Sources/Labpty/` returns zero hits.
- [ ] `git grep -nE '\bsetjmp\b|\blongjmp\b' Sources/Labpty/` returns
  zero hits.
- [ ] No function in `Sources/Labpty/*.c` exceeds 60 lines between
  matching braces unless marked
  `// LABPTY: long-function-allowed: <reason>`.
- [ ] `git grep -nE '\b(malloc|calloc|realloc)\(' Sources/Labpty/`
  returns zero hits, or every hit is annotated with a
  `// LABPTY: session-lifecycle-allocation: <reason>` comment in
  the surrounding code.
- [ ] Assertion-density script reports `assert(`-line count divided
  by function-definition count ≥ 2.0 across `Sources/Labpty/*.c`.
- [ ] `swift build` of the `labpty` C target uses
  `-Wall -Wextra -Wpedantic -Werror`.
- [ ] `clang --analyze` over `Sources/Labpty/*.c` produces zero
  findings on a clean tree.
- [ ] `git grep -nE '#define\s+\w+\(' Sources/Labpty/` returns zero
  hits. (No function-style macros.)
- [ ] `mlockall(MCL_CURRENT | MCL_FUTURE)` appears exactly once in
  `Sources/Labpty/main.c`, called at startup before the event loop
  begins.

### Byte-ring sanity

- [ ] `testByteRingWrapDetection` passes: writing 2× capacity worth
  of bytes through the writer and reading them through the reader
  produces an `overflowed=true` signal on the reader that did not
  keep up. No torn reads.
- [ ] `producer_alive_mono_ns` advances by more than 50 ms when
  sampled 150 ms apart against a healthy session.

### High-volume drain (catches accidental dual-readers)

- [ ] `testHighVolumeOutputIsNotSplitOrLost` runs `/bin/sh -c 'for i
  in $(seq 1 100000); do printf "line-%06d\n" $i; done'` against the
  new stack and asserts the resulting byte stream on `labpty`'s byte
  ring contains every `line-NNNNNN` from `line-000001` to
  `line-100000` in order with no duplicates and no gaps. Assert at
  the byte-ring layer, **not** at the parsed snapshot — the
  dual-reader race manifests as missing or duplicated bytes in the
  ring.

### Three-mode selection (M7)

All daemon-existence checks below are gated on **run-id-scoped
socket paths**, not global process names, to comply with
`docs/process/worktree-isolation.md`: the harness records the
labpty and laband PIDs it started and looks for those PIDs (or
their `--socket` argv, which always contains `.tmp/<run-id>/`)
rather than `pgrep -f labpty` / `pgrep -f laband` against the
host. Tests that pre-launch their own daemons keep the PID
references for direct `kill(pid, 0)` checks.

- [ ] `Workspace → Terminal Sessions` menu contains exactly three
  items in this order: `Local Sessions`, `Background Sessions`,
  `Detached Sessions`. The default-checked item is
  `Background Sessions`. (Inspect via the headless
  menu-introspection endpoint exposed by `HeadlessDebugRuntime`;
  do not rely on global `defaults read`.)
- [ ] The internal names `labpty` and `laband` do **not** appear in
  any user-facing menu title, tooltip, or product-doc string.
  Verification: `git grep -nE '\b(labpty|laband)\b'
  Sources/LabanApp/TerminalBackendMenuController.swift
  Sources/LabanApp/MenuCommands.swift docs/product/` returns zero
  hits in user-visible strings (hits inside source comments or
  configuration paths are acceptable; identifiers like
  `LabandTerminalSessionClient` in source are also fine — the
  rule is about menu/tooltip/doc strings the user reads).
- [ ] `LabanApp --terminal-backend in-process` opens a session
  with neither daemon needed. Verification: the test harness
  starts no labpty/laband binaries beforehand; after the smoke
  session opens, the harness checks its tracked daemon-PIDs
  (none should exist) and confirms no labpty/laband process was
  started under the run-id-scoped `.tmp/<run-id>/` socket
  directory.
- [ ] `LabanApp --terminal-backend labpty` causes the
  harness-launched `labpty` (or a LabanApp-spawned `labpty`
  under the run-id-scoped socket) to receive an `openSession`
  RPC. Verification: the harness reads
  `labpty.listSessions` against its known run-id-scoped socket
  and observes a non-empty session list.
- [ ] `LabanApp --terminal-backend laband` causes
  laband-side session creation. Verification: the harness reads
  `laband.listSessions` against its known run-id-scoped socket
  and observes a non-empty session list.
- [ ] `LabanApp --terminal-backend invalidvalue` exits nonzero
  with stderr naming the accepted values
  (`in-process`/`labpty`/`laband` plus aliases).
- [ ] `LABAN_TERMINAL_BACKEND=labpty LabanApp` (without the CLI
  flag) produces the same routing as
  `LabanApp --terminal-backend labpty`. Verified by the same
  list-sessions check against the run-id-scoped socket.
- [ ] `LABAN_TERMINAL_BACKEND=background LabanApp` (alias) also
  routes to `.labpty`, per the new `parse(_:)` aliases.
- [ ] **UserDefaults migration:** seed
  `LabanTerminalSessionBackend = "laband"` in the test's
  isolated `UserDefaults` suite, launch `LabanApp`, open a
  session, observe it goes to the laband-backed Detached path
  (the user's intent is preserved). The test must use an
  isolated defaults suite (`UserDefaults(suiteName:)`), not
  `.standard`.
- [ ] `SessionModeRoutingTests`, `SessionModePersistenceTests`,
  and `SessionModeCLITests` all pass.

### Cleanup

- [ ] No `labpty`, `laband`, or `LabanApp` processes that the test
  harness started remain after the test suite exits. The harness
  tracks PIDs it launched and asserts they exited; **no global
  `pgrep` calls** (compliance with worktree isolation —
  unrelated user processes must not be inspected). The
  per-test `tearDown` is the right place.
- [ ] No leftover shm files under `.tmp/<run-id>/labpty/` after
  tests pass.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)
