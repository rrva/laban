# 10. labpty Connected-Client Counter via Attach/Detach

Date: 2026-05-28

## Status

Accepted.

This ADR realises the per-reader attachment concept that ADR 0007 explicitly
reserved ("attach-by-fd, per-reader slots ... are reserved for later protocol
minors or a new ADR"). It extends the Phase 1 `labpty` contract; it does not
change ADR 0006's tier split or ADR 0007's framing, hello, byte-ring, or
recovery guarantees.

## Context

A `labpty` session outlives the app that opened it — that is the whole point
of the upgrade-proof tier (ADR 0006). When the app relaunches it must tell
two cases apart:

- **An abandoned session** — the owning instance died or its `workspace.json`
  desynced. These are the adoptable orphans the launch-time recovery flow
  reattaches as tabs.
- **A session a *running* instance still holds** — a concurrent second
  instance attached to the same per-user daemon. Touching these is wrong:
  adopting double-feeds one byte ring, terminating is data loss.

The Phase 1 descriptor carried no owner affinity (only `handle`, `child_pid`,
`alive`, `logical_id`, `ring_path`, capacities). `AppSessionCoordinator`
papered over the gap by reporting `attachedClientCount = alive ? 1 : 0`, which
is a liveness restatement, not an owner count. Without a real count, a safe
`Terminate` orphan action and a precise adopt-only-when-unowned policy cannot
be built.

A raw owner pid does not work: pids are reused, and they are reused precisely
across the app death this tier is designed to survive. The daemon already
holds the authoritative signal — it owns the persistent client sockets and
detects their disconnects — so the count belongs there.

## Decision

`labpty` tracks, per session, which client connections are attached, and
surfaces the count.

- **Storage.** Each registry session carries a `uint8_t attached_clients`
  bitmask over client slots. `LABPTY_MAX_CLIENTS == 8`, so the mask is one
  byte. The connected-client count is `popcount(attached_clients)`, computed
  on demand when a descriptor is built — there is no cached counter to drift.
- **Attach.** `openSession` implicitly attaches its opener. Two new
  operations, `ATTACH_SESSION` (`0x0009`) and `DETACH_SESSION` (`0x000A`),
  let a connection claim or release an already-open session — the
  reattach-after-restart and adopt-orphan flows. Both take the existing
  handle-request payload and return the descriptor so the caller observes the
  updated count. Both are idempotent.
- **Disconnect.** `client_release` — the single funnel for every teardown
  path (poll fault, idle/frame expiry, shutdown) — scrubs the departing
  connection's bit from every session. Established-but-idle clients are not
  reaped (they read output over the byte ring, not the socket), so an idle
  live tab keeps its count.
- **Slot reuse is safe both ways.** A freshly opened session zeroes the mask;
  a released client's bit is cleared everywhere. A reused registry slot or a
  reused client slot never inherits stale attachment.
- **Wire.** The descriptor encoding gains a trailing `u32 connected_clients`.
  Per ADR 0007's record framing this is an additive trailer, but the Phase 1
  Swift client is updated to *require* the field rather than tolerate its
  absence. That is a deliberate pre-release break: `labpty` has not shipped
  publicly, daemon and client always ship together, so no compatibility
  shim is owed. No ABI-major bump.
- **App.** `AppSessionCoordinator` reports `attachedClientCount =
  connectedClients` and the reattach path calls `attachSession` (the opener
  auto-attaches, so only reattach needs an explicit claim).

The consumer policy — gating the adopt prompt and a future `Terminate`
action on `connectedClients == 0` — is intentionally **not** part of this
change. This ADR delivers the signal; the policy is a separate decision.

## Consequences

- A safe `Terminate` orphan action and a precise "adopt only when unowned"
  policy are now buildable: `connectedClients == 0` on an `alive` session is
  the abandoned-orphan signal; a non-zero count means a live instance owns it.
- "Connected clients" means live control-socket attachments, capped at
  `LABPTY_MAX_CLIENTS` (8). It is not a count of byte-ring readers; the
  reserved reader slots remain unused.
- Computed-on-demand counting means no teardown path has to decrement a
  counter — correctness rides on the single `client_release` scrub plus the
  per-session mask, both exercised by the daemon-level test.
- `LabptyDaemonTests` pins the semantics: open = 1, second-client attach = 2,
  disconnect falls back to 1 (poll-until, since the daemon learns on its next
  poll), detach to 0 with the session still alive, and an established-idle
  owner stays counted past the idle timeout.

## Applies To New Code

New code crossing the `labpty` control socket must add a golden or negative
protocol test, and new buffer-pointer C declarations in `Sources/Labpty` must
use the existing bounds-safety annotations. Attachment is keyed by client slot
and scrubbed in `client_release`; any new client-teardown path must route
through it (or scrub the mask itself) so the count cannot leak. The
attach/detach/disconnect lifecycle is modelled in
`specs/labpty/LabptyAttachment.tla` (with the `MC_AttachmentPreFix`
negative control pinning the missed-scrub regression) and wired into
`scripts/check-specs` — a change to attach, detach, or disconnect semantics
flows through that spec per `docs/process/formal-specs.md`.
