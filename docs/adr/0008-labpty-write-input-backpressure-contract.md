# 8. labpty writeInput is Atomic Under Canonical Backpressure

Date: 2026-05-28

## Status

Accepted. Supersedes the implicit "OK means write(2) returned len" reading
of the Phase 1 contract frozen by ADR 0007 for the `writeInput` operation
only. The rest of ADR 0007 stands.

## Context

The Phase 1 `writeInput` contract promised that an OK response meant the
bytes "reached the master." That phrasing skipped a real failure mode:
under `ICANON`, the slave-side line discipline silently drops bytes once
the raw queue plus canonical queue reach `MAX_INPUT`, and a canonical line
silently truncates past `MAX_CANON`. On Darwin those limits sit at ~1 KiB.
`write(2)` on the master returns the full request length regardless. The
caller sees success; the child sees ~1 KiB.

The regression in `Tests/LabptyTests/LabptyAdversarialTests.swift`
(`testWriteInputOkPromisesDeliveryAndDaemonSurvivesBackpressure`) pins
this: it writes 64 KiB to a child that never reads stdin, then asserts
either OK with delivery to the slave, or error with zero echoes. The
pre-ADR daemon failed both branches — it returned OK but the slave only
saw ~1 KiB.

We cannot make the write succeed for an oversized cooked payload without
either growing the slave's input queue (kernel-side, not ours to change)
or holding the request inside the daemon for arbitrarily long while the
child drains its input (would punish unrelated sessions on the single
event loop). We can refuse the write atomically before any byte reaches
the master.

## Decision

`writeInput` is externally atomic: a non-OK response means no byte
reached the master, and OK means the payload was admitted into the
slave's line discipline within the queue limits in effect at the time of
the call.

The daemon performs a preflight admission check on every `writeInput`:

1. If the session has no slave inspection fd or `tcgetattr` fails, skip
   the check and fall back to the pre-ADR best-effort write. Graceful
   degradation rather than hard failure.
2. If `ICANON` is clear (raw mode), skip the check. Raw writes bypass the
   line discipline; the existing best-effort write loop is correct.
3. If `ICANON` is set, compute
   `headroom = min(MAX_INPUT, MAX_CANON) - SAFETY_MARGIN - in_flight`,
   where `in_flight = FIONREAD(slave) + per_session_raw_queue_estimate`.
   The estimate counts bytes accepted by prior `writeInput` calls since
   the last canonical delimiter (`\n`, `VEOL`, `VEOL2`, `VEOF`) we saw in
   our own payloads.
4. If `payload.len > headroom`, return `LABPTY_E_INPUT_BACKPRESSURE`
   (`0x000E`) without invoking `write(2)`.
5. Otherwise perform the existing bounded write loop, then update the
   per-session estimate from the payload's last delimiter position.

The Swift client surfaces non-OK responses as a typed
`LabptyResponseError` carrying the `LabptyErrorCode`, not the prior
`TerminalSessionClientError.protocolError(message)` flattening. Callers
that want to react to backpressure pattern-match on `code ==
.inputBackpressure`. Existing call sites that ignored the error type
continue to work; the error still conforms to `Error`.

This is a compatibility break under the Phase 1 freeze in ADR 0007, but
the only previously-shipping callers of `writeInput` saw silent data
loss under this codepath, so no real client behavior is being
invalidated — only a documented contract that the implementation never
actually delivered.

There is no new capability gate. The daemon always returns the new error
when admission fails; the Swift client always exposes the typed error.

## Consequences

- `writeInput` callers must handle `LabptyResponseError.code ==
  .inputBackpressure` by chunking the payload smaller, by waiting for
  the child to drain input, or by switching the slave out of canonical
  mode if the use case is bulk paste rather than line editing.
- The daemon holds a second slave-side fd per session, opened
  `O_RDONLY|O_NOCTTY` via `ptsname_r(master_fd)`. It is never read from
  and is closed when the session closes. Sessions opened before this
  ADR landed lose preflight admission gracefully; the inspection fd is
  best-effort.
- Raw-mode `writeInput` is unchanged. The check applies only when
  `ICANON` is set on the slave at the time of the call; termios is read
  fresh each call. KNOWN LIMITATION (M3): a `raw`→`canonical` flip is
  *not* fully handled. Bytes written while raw that the child never read
  stay queued in the slave, but the raw-mode path resets
  `canonical_pending_estimate` to 0, and canonical-mode `FIONREAD`
  reports only completed lines — not the carried-over unterminated line.
  So the first canonical write after an undrained raw period can
  over-admit into a near-full queue and the line discipline silently
  drops the overflow (bounded to that overflow). Not fixed: the only
  accurate fix is an `ioctl(FIONREAD)` on every raw-mode write — too
  costly on the hot input path for this narrow window (a child flipping
  to canonical almost always drains first).
- The per-session `canonical_pending_estimate` is a conservative
  estimate, not authoritative state. It can drift over-pessimistic
  (refusing writes that would have fit) if the child consumes raw-queue
  bytes via `VLNEXT` or other non-delimiter promotion paths. Within a
  continuous canonical period it cannot drift over-optimistic (admitting
  writes that overflow) so long as we count every accepted byte and only
  credit when we observe a delimiter; the one exception is the
  raw→canonical carry documented above. A safety margin against `MAX_INPUT`/`MAX_CANON` absorbs
  termios edge cases (`IUTF8` multibyte expansion, etc).
- ADR 0007's "additive-only" guarantee is amended: new daemon error
  codes may be introduced when the previous behavior was data-losing.
  Adding a new `LabptyErrorCode` case without renaming or renumbering
  existing ones remains additive at the wire layer.

## Applies To New Code

Daemon-side I/O paths that translate between an RPC and a kernel
syscall must answer the same question this ADR answered for
`writeInput`: when the syscall reports success but the externally
observable effect is partial or zero, which side does the contract sit
on? Either the daemon proves delivery before returning OK, or it
returns a typed error that callers can react to. "Best-effort write
then OK" is not a permitted shape for new operations.
