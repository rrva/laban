# 6. Three-Tier Session Architecture: Local, Background-Serving, Upgrade-Proof

Date: 2026-05-26

## Status

Accepted.

This ADR elaborates ADR 0005. It does not reverse 0005's invariant that a
separate process owns live PTY lifecycle; it splits that owner into two
layers with different change rates and adds a third explicit tier for the
in-process case.

## Context

ADR 0001 selected `libghostty-vt` as Laban's terminal parser and located
PTY ownership inside `LabanTerminalCore`. ADR 0002 fixed the PTY launch
mechanism (parent-side `openpty`, constrained fork child, parent-only
master fd). ADR 0005 made `laband`, a per-user daemon, the owner of live
terminal session lifecycle: PTY master, libghostty parser state,
scrollback, snapshot ring, lease management, lifecycle journal — all in
one daemon process — with the app, headless harness, and tests attaching
as clients.

That choice shipped working live-session survival. It also bound together
two concerns with very different lifetimes:

**Concern A: kernel-resource custody.** Holding the PTY master fd, owning
the child process group, draining the master into a buffer. This is small,
slow-moving, kernel-API-shaped. It almost never needs to change.

**Concern B: VT interpretation and serving.** Running libghostty, owning
scrollback, publishing snapshots, managing leases, handling theme palettes,
running the lifecycle journal. This changes whenever libghostty bumps, a
new theme feature lands, a protocol field is added, or a regression in any
of those surfaces.

When the two concerns live in one process, every Concern B change forces
a restart of the Concern A owner — which closes the PTY master and sends
SIGHUP to the child. The user-visible failure mode: the daemon designed to
preserve the user's terminal across app upgrades cannot preserve it across
its own upgrades. Three recent regressions
(`execplans/active/background-session-regressions.md`, M1/M2/M3) are
concrete evidence of a parallel cost — every libghostty feature has to be
re-exported across the parsed-state-over-IPC seam, and any feature not in
the exported schema becomes a silent regression in background mode.

The architectural shape that addresses both is to separate Concern A and
Concern B into distinct processes, and to recognize a third tier for
sessions that don't need any out-of-process serving at all.

## Decision

Three coexisting session-lifetime tiers, served by a layered architecture
with a single app-facing protocol.

### The three tiers

**Tier 1 — Local.** App owns the PTY directly per ADR 0002. `libghostty-vt`
runs in-process. No daemons. Session lifetime equals app lifetime. This is
today's `AppKitTerminalBackend.inProcess`. Optimized for keystroke latency,
test ergonomics, ephemeral shells, ad-hoc commands.

**Tier 2 — Background-Serving.** `laband` runs `libghostty-vt`, owns
scrollback, publishes the existing `LabandSnapshotResponse` snapshot ring,
manages leases, journals lifecycle. Multiple clients attach to the same
parsed state. Optimized for multi-attach, network casting, headless server
deployments, web/browser clients, out-of-process observability tooling.

**Tier 3 — Upgrade-Proof.** `labpty` owns only the kernel-level objects:
PTY master, child process group, a per-session ring buffer of raw bytes
drained from the master, and a session catalog. No VT parsing. Tiny
versioned RPC surface (~8 calls; see "labpty surface" below). Sessions
survive every upgrade except `labpty` itself.

### Layering

Tier 2 and Tier 3 are not alternatives. Tier 2 sits on top of Tier 3:
`laband` attaches to `labpty` for PTY ownership rather than holding the
master itself. Tier 2 inherits Tier 3's upgrade-proof guarantee. Tier 3
also exists standalone — the app can connect to `labpty` through `laband`
in single-client mode and receive a direct byte-ring handle that lets it
parse with in-process libghostty.

```
                ┌─────────────────────────┐
                │       Laban app         │
                │  libghostty in-process  │
                │   (Tier 1 or Tier 3)    │
                │    OR consume snapshot  │
                │       ring (Tier 2)     │
                └───────┬─────────────┬───┘
                        │             │
                        │             │  one protocol
                        ▼             ▼
                   ┌─────────────────────┐
                   │        laband       │
                   │  mode-switched:     │
                   │  single-client →    │
                   │    pass through     │
                   │  multi-client →     │
                   │    libghostty +     │
                   │    snapshot ring    │
                   └─────────┬───────────┘
                             │
                             ▼  SCM_RIGHTS + byte ring
                   ┌─────────────────────┐
                   │        labpty       │  ← Tier 3 foundation
                   │  master fd +        │
                   │  byte ring +        │
                   │  tiny catalog       │
                   └─────────┬───────────┘
                             │
                       child processes
```

### Single app protocol, mode-switched server

The app speaks one protocol: `laband`'s. `laband` operates in two modes,
chosen per session based on attached-client count:

**Single-client mode.** When exactly one client is attached, `laband`
includes labpty's byte-ring shared-memory handle and an opaque-snapshot
cache handle in the attach response. The client runs libghostty in-process,
reads bytes from the byte ring, and renders from its own parsed state.
`laband` does not parse in this mode. Keystroke and output paths bypass
`laband`'s libghostty entirely — only control RPCs (resize, signal,
terminate) and lease ownership flow through it.

**Multi-client mode.** When a second client attaches, `laband` flips to
authoritative-parse. It reads bytes from labpty, parses with libghostty,
publishes the existing snapshot ring, and all attached clients consume
snapshots. The single-client byte-ring handle is still exposed but should
not be used as the primary data source (clients receive a mode-flag in
the per-frame attach response).

Mode flips are transparent to clients in the sense that they all speak the
same protocol surface; the per-attach capabilities response tells them
which data shape (byte ring or snapshot ring) to consume primarily.
Promotion is a controlled handoff: when the second client attaches,
`laband` parses the byte ring forward to current state, publishes a first
snapshot, signals both clients to switch primary source. One snapshot
flicker, no SIGHUP. Demotion (back to single client) is the reverse and is
allowed but not required.

### labpty surface

The `labpty` RPC is deliberately small and additive-only:

- `hello() → versionInfo, capabilities`
- `openSession(rows, cols, argv, envp, cwd, logicalSessionId?) → ptyHandle, child_pid`
- `attachSession(ptyHandle) → master_fd via SCM_RIGHTS, byte_ring shm handle, opaque_snapshot_cache shm handle`
- `listSessions() → [(ptyHandle, child_pid, rows, cols, alive)]`
- `resizeSession(ptyHandle, rows, cols)`
- `signalSession(ptyHandle, signo)`
- `terminateSession(ptyHandle)`
- `publishOpaqueSnapshot(ptyHandle, blob)` — for the snapshot-cache fast path on cold client attach

Anything not on this list goes through `laband`, not `labpty`. labpty
performs no VT parsing, no theming, no lease management, no journaling of
parsed state. Its on-disk state is a tiny catalog file recording which
PTYs exist for crash recovery, plus the shared-memory byte rings.

### Load-bearing claim

**PTY ownership and VT interpretation are separate concerns with different
lifetimes, and the right architectural seam is between them, not below
them.** Everything else — labpty's RPC shape, the byte-ring layout, the
mode-switched server, the lease split — falls out of that one claim.

ADR 0001's "libghostty-vt owns VT parsing" still holds in whichever
process is parsing. ADR 0002's PTY launch invariants move into `labpty`.
ADR 0005's invariant — Close Tab terminates, app quit detaches — still
holds; tier choice does not change tab close semantics.

## Consequences

### Regression-contract assignment

The work shipped in `execplans/active/background-session-regressions.md`
maps cleanly:

- **M1** (block-element seam in remote FrameProducer): regression contract
  for Tier 2 multi-client mode. Tier 1 and Tier 3 use the local
  `FrameProducer.commands(from: UnsafePointer<LabanSnapshot>, ...)`
  overload, which already emits procedural rects. Bug cannot recur there.
- **M2** (foreground process metadata): regression contract for Tier 2's
  serialization completeness. Tier 1 and Tier 3 call
  `Session.processMetadata()` in-process against the master they hold.
- **M3** (default background color): regression contract for Tier 2's
  serialization completeness. Tier 1 and Tier 3 read
  `snapshot.default_background_rgba` directly from libghostty.

None of the M1/M2/M3 fixes are wasted; they pin behavior for the tier
that actually needs serialization, and they continue to apply whenever
`laband` is in multi-client mode.

### Upgrade matrix

| Change | Tier 1 effect | Tier 2 effect | Tier 3 effect |
| --- | --- | --- | --- |
| App rebuild + relaunch | session dies | survives | survives |
| App crash | session dies | survives | survives |
| `libghostty` bump in app | session dies | n/a | survives (master in labpty) |
| `libghostty` bump in `laband` | n/a | survives via byte-ring replay | n/a (laband not in single-client data path) |
| `laband` code change | n/a | survives via byte-ring replay | survives (laband only in control path) |
| `labpty` code change with fd-handoff | n/a | survives | survives |
| `labpty` code change without fd-handoff | n/a | session dies | session dies |
| `labpty` crash | n/a | session dies | session dies |
| OS restart | session dies | session dies | session dies |

The user-visible promise is: **upgrading anything Laban ships does not
kill the user's terminal**, provided `labpty`'s surface stays stable. The
fd-handoff dance (LISTEN_FDS-style: old `labpty` exec's new binary with
master fds in the inherited fd table, signals ready via a pipe, then
exits) is a Tier 3 acceptance requirement. Implementable in ~100 LoC and
well-trodden territory (systemd socket activation, nginx graceful reload).

### What changes from today's code

- `Sources/Laband/` retains its current structure for the multi-client
  path (the protocol surface, snapshot ring publishing, lease/journal/
  theme handling are all unchanged externally).
- A new `Sources/Labpty/` (or sibling SwiftPM product) houses the Tier 3
  daemon and its RPC.
- `Sources/Laband/main.swift` is refactored so its PTY ownership and
  master-drain code lives in `labpty`. `laband` becomes a `labpty` client
  internally; libghostty still runs inside `laband` but is fed from the
  byte ring rather than from a directly-owned master.
- `LabandSnapshotResponse` and the `LBNDSS01` snapshot ring are retained
  as the Tier 2 multi-client publishing format.
- A capability flag in `laband`'s attach response indicates whether the
  client is in single-client mode (consume byte ring) or multi-client
  mode (consume snapshot ring).
- `AppLabandSessionCoordinator` gains a single-client-mode path that uses
  in-process libghostty against the byte ring; the existing snapshot-ring
  path remains for multi-client mode.
- Backend selection in `MainWindowController` remains a process-wide enum
  (`inProcess` vs `laband`); the tier-1 vs tier-3 distinction within
  `laband` mode is a per-session capability negotiated at attach time, not
  a backend choice.

### Bug surface and operational cost

Three tiers is more surface than one or two:

- `laband` now has two internal modes (single-client byte-ring pass-through
  and multi-client authoritative parse). Mode transitions need explicit
  test coverage. The single-client mode is conceptually simpler than the
  multi-client mode but has to handle the transition.
- The `AppLabandSessionCoordinator` has two consumption paths. Both must
  produce the same rendered output for identical input streams.
- Two daemons to plist-register, monitor, and version (`labpty` and
  `laband`). Per-user LaunchAgents must order: `labpty` before `laband`.
- `labpty`'s protocol must be designed deliberately and frozen early;
  iterating it has the same upgrade-kills-children problem `laband` has
  today. The fd-handoff dance softens this but does not remove it.

These costs are real and paid once at the architectural seams, rather
than amortized indefinitely across every libghostty feature.

## Migration

Three phases, separately shippable. Each is gated on its own ExecPlan.

**Phase 1 — Extract labpty from laband.** Mechanical refactor. PTY
ownership moves to `labpty`; `laband` becomes a labpty client internally.
App and laband contracts unchanged externally. All existing tests still
pass. Plus a new acceptance test: kill `laband` mid-session, restart it,
verify the child process survives. Scope:
`execplans/active/labpty-extraction.md`.

**Phase 2 — Single-client byte-ring mode in laband.** Add the
capability-flagged byte-ring path to `laband`'s attach response. Teach
`AppLabandSessionCoordinator` to consume the byte ring with in-process
libghostty. Mode transition on second-client attach. This is the phase
that activates the Tier 3 "no serialization tax" benefit. Scope: a new
ExecPlan once Phase 1 lands.

**Phase 3 — labpty fd-handoff for self-upgrades.** Closes the last
remaining "daemon upgrade kills children" hole. Independent ExecPlan;
shippable any time after Phase 1.

You can stop after Phase 1 and already have most of the upside: a clean
layered architecture, `labpty` as a stable foundation, `laband` upgrades
no longer kill children. Phase 2 and 3 are pure upside.

## Alternatives considered

**Always-via-laband (single protocol, no labpty-direct path).** Simpler
app, but the serialization tax for parsed state across IPC remains
permanent. Every libghostty feature continues to need a slot in the
laband schema. M1/M2/M3-class regressions remain a recurring product
quality concern. Rejected on the grounds that the tax is paid every time
libghostty changes, not once.

**App speaks both protocols (labpty-direct and laband).** No
serialization tax in the common case, no laband restart latency for
single-client sessions. Rejected on the grounds that two app-side attach
paths double the bug surface in the renderer and the coordinator, and
the single-protocol mode-switched server (the accepted decision) achieves
the same benefit without that cost.

**Keep ADR 0005 as-is, patch regressions as they appear.** Defers the
architectural work but pays the M1/M2/M3 tax in perpetuity and leaves the
"daemon upgrade kills children" hole open. Rejected as the long-term
default.

## Open questions deferred to migration ExecPlans

- **Byte-ring sizing.** Per-session limit, system-wide cap, configurable
  per session. Default proposal: 8 MB per session (~minutes to hours of
  scrollback depending on output verbosity). Resolved in Phase 1.
- **Snapshot-cache contents.** One opaque blob per session (last published)
  versus a small ring of recent blobs. One blob suffices for fast attach;
  a ring helps post-mortem debugging. Resolved in Phase 2.
- **Lease semantics across tiers.** `labpty` needs a write-lease primitive
  (one writer at a time). `laband` enforces its own client-level lease
  layer on top. The two layers must compose: a `labpty` write-lease held
  by `laband` must coexist with `laband`'s per-client leases. Resolved in
  Phase 1.
- **Mode-flip continuity.** What snapshot does a freshly-promoted
  multi-client mode publish? How are dropped frames during the flip
  surfaced (if at all)? Resolved in Phase 2.
- **Headless debug runtime.** Today's `HeadlessDebugRuntime` runs
  in-process; with the new layering it can target any tier. Test parity
  needs explicit thought. Resolved iteratively across phases.
- **Persistence.** What survives an OS reboot? Nothing — the PTY is a
  kernel resource. The Claude/Codex semantic resume path (per ADR 0005)
  continues to bridge OS reboots.

## Prior art

- **dtach** (~1000 LoC C): thin PTY holder, no VT parsing, byte forwarder
  to attached clients. Closest precedent for `labpty`.
- **abduco**: dtach's slightly more featured cousin. Same model.
- **tmux server**: a thick daemon that owns VT state. Restart kills
  sessions. Illustrates the cost of conflating ownership and parsing.
- **mosh**: state-sync over a lossy network. The relevant insight for
  Tier 3 is "rebuild from authoritative current state rather than replay
  stale bytes". The byte-ring + opaque-snapshot-cache is a local analogue.
- **systemd socket activation, nginx graceful reload, qemu live
  migration**: well-understood patterns for fd handoff between process
  instances. Reference for the `labpty` self-upgrade mechanism.
- **VS Code Remote / SSH Remote, code-server, Tabby Web**: server process
  stays running, client reconnects. The shape of Tier 2 with remote
  clients.

## Applies To New Code

Before adding state to any session-management path, answer:

1. Which tier owns this state? If "all tiers", justify duplication or
   move the state to the lowest tier that needs it.
2. Does this state need to cross the `labpty` ↔ client boundary? If yes,
   the `labpty` RPC schema must be extended deliberately, with explicit
   ABI versioning, and the change must be justified against the tier's
   "minimal surface" guarantee.
3. Is the state Tier-2-specific (multi-client, networkable, server) or
   Tier-3-foundational (PTY survival)? Tier-2-specific state belongs in
   `laband`; Tier-3-foundational state belongs in `labpty`.
4. Does this state need to survive `laband` restart? If yes, can it be
   reconstructed from the byte ring on reattach, or must `labpty` hold
   it? Prefer reconstruction over `labpty` ownership.
5. Are tests written against the in-process tier, the `labpty` tier, or
   the `laband` tier? If you're claiming behavior in a specific tier,
   the test must exercise that tier — not a fake.
6. Does ADR 0001 (`libghostty-vt` owns parsing) still hold inside
   whichever process is parsing? Does ADR 0002 (PTY launch invariants)
   still hold inside `labpty`?
7. Does ADR 0005's Close Tab versus app quit invariant still hold? Tier
   choice does not change tab close semantics.

If any answer is "no" or "unclear", stop and surface the question
explicitly in the relevant ExecPlan rather than coding past it.
