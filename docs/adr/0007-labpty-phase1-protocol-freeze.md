# 7. Freeze labpty Phase 1 Protocol and App-Direct Recovery Contract

Date: 2026-05-27

## Status

Accepted.

This ADR narrows the Phase 1 `labpty` contract that is actually shipping in
the app-direct client. ADR 0006 remains the long-term architecture: `labpty`
owns PTY custody and stays small, while `laband` can later sit above it for
multi-client serving.

## Context

`labpty` is the only process that must not churn if background sessions are
to survive routine app and library upgrades. That requires a small,
versioned, additive-only protocol with explicit client behavior for the
failure modes that are normal across year-scale use: app restarts, control
socket drops, byte-ring overflow, and daemon/client ABI mismatch.

The initial implementation shipped before this ADR already exposed the
Phase 1 shape: UNIX control socket, little-endian framed RPC, `hello`
capability negotiation, path-based shared-memory byte rings, and app-side
VT parsing. It did not yet document which pieces are frozen, nor did it
state how the Swift client should recover after losing its control socket.

## Decision

Phase 1 freezes the following contract:

- Every control connection must send `hello` first. Non-hello requests before
  negotiation are protocol errors.
- The frame header is 24 bytes, little endian, magic `LPCT`, ABI major `1`,
  ABI minor `0`, maximum frame size 128 KiB, and response operation `0xffff`.
- The Phase 1 capability set is `byte-ring/v1`, `write-input-rpc/v1`,
  `heartbeat-shm/v1`, and `session-id-pinning/v1`. The Swift client rejects
  daemons missing any of these capabilities.
- Shared byte-ring files use the `LBPTY-BR` header, ABI major `1`, ABI minor
  `0`, fixed header/counter/reader-slot offsets, and path-based discovery.
  Phase 1 does not pass file descriptors with `SCM_RIGHTS`.
- Session identity is pinned by `logicalSessionId`; the client may rebuild
  volatile handle caches by reconnecting, sending `hello`, then listing
  sessions.
- A control-channel failure is recoverable. The Swift client closes only the
  failed connection, clears negotiated state and handle caches, and reconnects
  on the next RPC.
- Byte-ring overflow is not silent. The reader returns retained bytes plus an
  overflow flag; the app resets parser continuity and marks the tab as
  degraded so the user can see that output was skipped.
- Every Phase 1 request and response payload must be additively evolvable:
  decoders MUST tolerate unknown trailing bytes. Two specific shapes
  enforce this for the payloads that were not naturally trailer-safe:
  - `writeInput` requests carry an explicit `u32 input_len` between the
    handle and the byte payload, so future fields appended after the
    bytes are ignored instead of being typed into the PTY.
  - `listSessions` responses are a `u32 count` followed by per-record
    `u32 record_len` + `byte[record_len]`. Each record contains the
    Phase 1 descriptor encoding; trailing bytes inside a record are
    additive fields and ignored by old decoders.

Anything not listed above is not a Phase 1 `labpty` guarantee. In particular,
attach-by-fd, per-reader slots, opaque snapshot cache publishing, durable
catalog recovery, and graceful `labpty` self-upgrade are reserved for later
protocol minors or a new ADR.

## Consequences

Golden protocol tests pin the frame bytes and hello payload layout. Client
reconnect tests pin the cache-rebuild contract. Byte-ring validation tests
pin ABI rejection, span rejection, and overflow behavior.

Future `labpty` work should be additive: new operations, fields, and
capabilities may be introduced behind minor-version or capability checks,
but existing Phase 1 fields and semantics should not change. Any breaking
change requires a new ABI major and a compatibility story for existing
session owners.

## Applies To New Code

New code that crosses the `labpty` control socket or byte-ring boundary must
add a golden or negative protocol test. New buffer-pointer C declarations
in `Sources/Labpty` should use the existing bounds-safety annotations and
must keep `Tools/LabptyCodingRules/check_bounds_safety_headers.sh` passing.
