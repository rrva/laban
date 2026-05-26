# labpty Protocol Design

Design notes for the wire protocol and shared-memory layouts owned by
`labpty`, the kernel-resource custodian introduced in ADR 0006. This is a
working specification — not yet a `docs/reference/` artifact — that the
Phase 1 ExecPlan (`execplans/active/labpty-extraction.md`) implements.
Once `labpty` ships and the protocol has survived its first real load,
this document graduates to `docs/reference/labpty-protocol.md` and the
ABI gets frozen.

This design is written with the disciplines an algorithmic trading firm
would apply to a low-latency local IPC: every operation has a latency
budget, every allocation is intentional, hot paths are lock-free,
backpressure is explicit, and observability is non-optional. The reasoning
is exposed inline so a contributor can see *why* a choice was made and
whether their proposed change preserves the invariant.

## Design principles

These are the axioms. Every concrete decision below traces to one of
them.

1. **Latency is measured, not estimated.** Every hot-path operation
   carries timestamps at multiple stages. A latency regression must be
   diagnosable from production counters without attaching a profiler.
2. **Predictable tail latency over peak throughput.** A protocol that
   runs at 5 µs p50 and 50 µs p99.9 beats one at 1 µs p50 and 5 ms
   p99.9. Tail spikes are designed out: no allocations on hot paths, no
   locks on hot paths, no per-message JSON, no GC, no scheduler-visible
   waits unless we declared them.
3. **Separate control and data planes.** Control is rare,
   reliability-sensitive, ergonomics-allowed. Data is frequent,
   latency-sensitive, ergonomics-forbidden. Use different transports.
4. **Single-producer, multi-consumer shared memory for the hot path.**
   The kernel already serializes the producer's writes to the PTY
   master; mirror that single-writer discipline in our ring. Readers
   are lock-free.
5. **Schema is fixed-offset binary on the hot path, JSON on the control
   plane.** Fixed offsets let the compiler emit `load` instructions
   directly against memory-mapped regions. JSON survives on the control
   plane because the rate is bounded by user action (open / resize /
   terminate happen once per minute at most).
6. **Versioning happens once, at handshake, never per message.** After
   `hello`, both sides know the schema. No version field on any
   subsequent message.
7. **Capabilities are explicit and additive.** New features land behind
   capability flags negotiated at handshake. Old clients refuse what
   they don't understand; new clients fall back when capabilities are
   missing.
8. **Every operation has a timeout, every error has a code.** Infinite
   hangs and exception-driven control flow are forbidden.
9. **Heartbeats both directions.** Peer death is detected in
   milliseconds, not minutes. Stale connections are reaped explicitly.
10. **Observability is in-band, not optional.** Per-session counters
    live in shared memory, sampled by anyone with read access. No
    log-scraping required.
11. **No daemon-side allocation on the hot path.** Buffers are
    preallocated at session open. Read/write/ring/wake — zero
    allocations after warm-up.
12. **The ABI must be frozen-able.** Every layout choice anticipates a
    later `freeze` event after which fields cannot move or change
    meaning, only be added at the end.

## Transport map

| Concern | Transport | Why |
| --- | --- | --- |
| Control RPC (open, attach, list, resize, signal, terminate, writeInput, publishOpaqueSnapshot, ping, hello) | Length-prefixed JSON over Unix `SOCK_STREAM` | Bounded rate. Ergonomics matter. Reuses the existing `LabandProtocol` codec discipline. |
| Output bytes (PTY → readers) | Single-producer multi-consumer shared-memory ring (`LBPTY-BR-01`) | Hot path. Hundreds to thousands of writes per second per active session. Zero IPC overhead per byte. |
| Input bytes (writer → PTY), Phase 1 | `writeInput` control RPC on the same Unix socket, bytes base64-encoded in JSON, bounded to 64 KiB per call | Keystroke and paste throughput is bounded by user action. Avoids the cost of building a real shared-memory input path before measurements justify it. **Phase 1's invariant: laband, not the app, calls this RPC.** Multi-attach write conflicts are resolved by laband's existing client-level lease, not by a labpty primitive. |
| Input bytes (writer → PTY), Phase 2 | Single-producer single-consumer shared-memory ring (`LBPTY-IR-01`) per session, with pipe-based wakeup | Lower-rate hot path. SPSC ring matches the output path's discipline. **Predicated on a labpty-level write-lease primitive (`multi-attach-write-lease/v1`); not shippable without it because direct ring writes have no way to arbitrate among multiple writers.** |
| Reader wakeups | Pipe write-end handed to labpty at `attachSession` via SCM_RIGHTS; labpty writes one byte per coalesced batch | macOS does not have `eventfd`. `EVFILT_USER` is a per-process construct and cannot be triggered from another process. A pipe is the simplest cross-process wake primitive available on Darwin, well-understood, and avoids the Mach-port complexity of `mach_semaphore_t`. This is the only SCM_RIGHTS use in Phase 1 — it sends a pipe write-end, not a PTY master. |
| Heartbeats | Shared-memory timestamp fields, sampled by readers | No kernel call to check "is the other side alive". |
| Per-session counters | Shared-memory counters block at fixed offset of the byte ring | Anyone with the shm path can sample. No RPC needed. |
| Self-upgrade fd handoff (`labpty` itself) | LISTEN_FDS-style env + a status pipe, plus SCM_RIGHTS handoff of PTY master fds between old and new `labpty` instances | **Phase 3 only**; the only design where a PTY master fd legitimately crosses a process boundary. Out of scope for Phase 1; documented here for foresight. |

The shared-memory artifacts per session (byte ring, future input ring,
future metadata ring, per-reader slot table) share one file but are
distinct regions described by the file header. The control socket
carries only the file path and offsets; PTY payload bytes never cross a
socket.

### What does **not** cross the socket in normal attach

- **PTY master fds.** Per the architectural invariant of
  `execplans/active/labpty-extraction.md`, `labpty` is the sole
  steady-state reader and writer of every PTY master it opens. No
  client (`laband`, `LabanApp`, diagnostic tool) receives a duplicated
  master fd in the response to `attachSession`. Two readers on the
  same PTY master split bytes non-deterministically; two writers
  interleave. The only safe shape is one custodian, and the protocol
  enforces that by simply never handing the fd out.

- The diagnostic and Phase 3 self-upgrade paths each have explicit,
  separate sections in this document. Neither uses `attachSession`.

## Memory layout — the byte ring (`LBPTY-BR-01`)

This is the hot path. It deserves cache-line-aware design.

### File layout

```
+----------------------------+ 0
|         File header        |     fixed 128 bytes, cache-line aligned
+----------------------------+ 128
|     Global counters block  |     fixed 128 bytes, one cache line
+----------------------------+ 256
|   Per-reader slot table    |     READER_SLOT_BYTES * MAX_READERS
|                            |     Phase 1: 64 B * 8 slots = 512 bytes
+----------------------------+ 256 + reader_slot_bytes
|        Input ring          |     INPUT_CAPACITY bytes
|                            |     Phase 1: 0 (deferred to Phase 2)
+----------------------------+ + INPUT_CAPACITY
|        Output ring         |     OUTPUT_CAPACITY bytes (default 8 MiB)
+----------------------------+ + OUTPUT_CAPACITY
|       Metadata ring        |     METADATA_CAPACITY bytes
|                            |     Phase 1: 0 (deferred to Phase 2)
+----------------------------+ end
```

With Phase 1 defaults: 128 (header) + 128 (counters) + 512 (slot table) +
0 (input) + 8 MiB (output) + 0 (metadata) ≈ 8.001 MiB per session. With
the full Phase 2 layout: ~8.06 MiB. Capacities are configurable at
`openSession` within hard limits (max 64 MiB output, min 256 KiB).

`MAX_READERS = 8`. Rationale: covers the worst plausible attached set
(`laband` parser + a couple of casting clients + a diagnostic tool +
headroom) without wasting cache. A ninth `attachSession` returns
`attachLimitExceeded`. Sized as a frozen ABI constant so the slot-table
offset never moves; raising the cap is an `abi_minor` event that adds
slots beyond the existing eight.

### File header (128 bytes, offset 0)

```
Offset  Size  Name                  Notes
------  ----  --------------------  ----------------------------------------
0       8     magic                 b"LBPTY-BR" (8 ASCII bytes)
8       4     abi_major             1, frozen
12      4     abi_minor             additive
16      4     header_bytes          128, validate on attach
20      4     counters_offset       128
24      4     reader_slot_offset    256
28      4     reader_slot_bytes     64 (per slot, frozen)
32      4     reader_slot_count     8  (frozen ABI cap)
36      4     reserved
40      8     input_ring_offset     reader_slot_offset + 512 = 768
48      8     input_ring_capacity   power-of-two; 0 in Phase 1
56      8     output_ring_offset    input_ring_offset + input_ring_capacity
64      8     output_ring_capacity  power-of-two byte count
72      8     metadata_ring_offset  output_ring_offset + output_ring_capacity
80      8     metadata_ring_capacity 0 in Phase 1
88      8     session_id_hash       FNV-1a of the logical session id
96      4     producer_pid          labpty's pid at create time
100     4     reserved
104     8     created_at_unix_ns
112    16     reserved              zeroed, future use
```

`header_bytes` is checked on attach. A mismatch means `abi_major` skew;
clients refuse the ring. Power-of-two ring capacities are required so
wrap arithmetic is `& (capacity - 1)` instead of `% capacity` — one
instruction versus a few. Phase 1 readers must tolerate
`input_ring_capacity == 0` and `metadata_ring_capacity == 0`; those
regions simply do not exist in a Phase 1 file.

### Global counters block (128 bytes, offset 128)

One cache line of process-wide-per-session counters. Each counter is u64,
atomic, sampled by readers without locks. **No per-reader state lives
here.** That's why the block fits in 128 bytes; the per-reader storage
(wake-pending, consumer-alive heartbeat, last-seen offset for diagnostic
sampling) is in the separate per-reader slot table at offset 256.

Hot counters (offset 128, first half cache line):

```
Offset  Name
------  -------------------------------------
128     output_bytes_written_total     ← write-side hot
136     output_writes_total
144     output_wrap_count              ← wrap detection
152     output_wake_notifications_total
160     producer_alive_mono_ns         ← labpty's monotonic heartbeat
168     reserved (padding to 192)
```

Cold counters (offset 192, second half cache line):

```
192     input_bytes_consumed_total     ← Phase 2; labpty reads from input ring
200     input_writes_blocked_total     ← Phase 2
208     master_read_calls_total
216     master_read_eagain_total
224     ring_overflow_observed_total   ← reader-incremented (informational)
232     attached_consumer_count        ← labpty maintains as slots fill/free
240     last_attach_mono_ns
248     reserved (padding to 256)
```

`producer_alive_mono_ns` is the heartbeat. labpty updates it at 100 ms
cadence on its main loop tick. A reader that sees this field stale by
>300 ms can assume labpty is dead or hung and trigger reconnect /
escalation. Same primitive as a market-data feed-staleness check.

Why no `output_read_total`: readers are multiple and lock-free; we don't
serialize their reads through a single counter. Each reader maintains its
own watermark in its own address space (and a diagnostic mirror in its
own per-reader slot — see below).

### Per-reader slot table (offset 256, 64 bytes × 8 = 512 bytes)

Eight cache-line-aligned slots. `labpty` allocates a slot at
`attachSession` and clears it on detach. Each slot:

```
Offset within slot  Size  Name
------------------  ----  ----------------------------------------
0                   8     occupied               (0 = free, 1 = in use; CAS-claimed by labpty)
8                   8     reader_client_id_hash  (FNV-1a of the client id)
16                  8     consumer_alive_mono_ns (reader's heartbeat, ~1 Hz updates)
24                  1     wake_pending           (u8 flag; reader clears, labpty sets)
25                  7     padding
32                  8     last_seen_offset       (diagnostic mirror; not load-bearing)
40                 24     reserved (padding to 64)
```

`occupied` is the slot-claim CAS target. `labpty` finds the first free
slot, atomically CASes `0 → 1`, fills the other fields, returns the
slot index in the attach response. On detach (`terminateSession` of the
reader's attach, control socket close, or sweep due to stale
`consumer_alive_mono_ns`), `labpty` clears the slot back to zero.

`wake_pending` is the edge-triggered signal coalescer (see "Wakeup
discipline"): `labpty` sets it before writing the pipe; the reader
clears it after draining. The reader's pipe read-end fd lives outside
this file (the reader holds it; `labpty` holds the matched write-end fd
received via SCM_RIGHTS at attach time).

`last_seen_offset` is **not** consulted by the producer for correctness;
the byte-ring's correctness depends only on `output_write_offset`. The
slot's `last_seen_offset` exists so a diagnostic tool can sample which
readers are lagging without bothering labpty.

This layout is what makes the advisor's "128 bytes is not enough for 8
readers" finding land safely: per-reader state was always going to need
~512 bytes, and it now has its own region with a frozen offset.

### Output ring (offset 256 + input_ring_capacity)

The hot data path. Single producer (labpty), multiple lock-free readers.

The ring is a circular byte buffer. The producer maintains
`output_write_offset` as a monotonically increasing u64 in the counters
block (logically, even though `output_bytes_written_total` is what's
actually stored — these are the same value; documented as one counter to
avoid duplication). To find the byte at position `p`, mask:
`payload[(p) & (output_ring_capacity - 1)]`.

**Producer protocol (labpty):**

1. Drain bytes from the PTY master with one `read()` call into a
   scratch buffer (preallocated at session open, sized 16 KiB).
2. Memcpy into the ring at `output_write_offset & mask`, splitting into
   two memcpys if the contiguous suffix is too short.
3. `atomic_store_explicit(&output_write_offset, new_offset, memory_order_release)`.
4. Optionally append a metadata record (see below).
5. If wake notifications are enabled and the previous wake has been
   consumed, signal one wakeup via the per-reader eventfd / EVFILT_USER.

The release fence in step 3 is the algo-trader move: it pairs with the
reader's acquire load and gives a happens-before relationship without a
lock. On Apple Silicon, this is a `stlr` instruction.

**Consumer protocol (laband or app in single-client mode):**

Each consumer maintains its own `last_seen_offset` in its private
memory.

1. `current = atomic_load_explicit(&output_write_offset, memory_order_acquire)`.
2. `available = current - last_seen_offset`.
3. If `available > output_ring_capacity`, the writer has wrapped the
   reader's window: this is overflow. Recover (see "Overflow recovery"
   below).
4. Otherwise, read `available` bytes via one or two memcpys from
   `payload[last_seen_offset & mask]`.
5. `last_seen_offset = current`.

#### Overflow recovery

A reader observes `available > output_ring_capacity` when `labpty` has
written more bytes since the reader's last read than the ring can hold.
The bytes between `last_seen_offset` and `current - capacity` are
unrecoverable from this ring: they have been overwritten in place. The
reader must reconcile its parser state with what is still present.

The recovery strategy is tiered. `labpty` does not parse VT state and
therefore cannot synthesize a fresh snapshot on demand; the opaque
snapshot cache is an optimization for the case where someone else
recently published one, not the primary recovery path.

1. **If a fresh opaque snapshot exists**
   (`publishOpaqueSnapshot` has been called within
   `opaque_snapshot_max_age_ms`, default 5 seconds, and the snapshot's
   `output_offset_at_publish` is within `output_ring_capacity` of
   `current`): the reader loads the snapshot, sets
   `last_seen_offset = snapshot.output_offset_at_publish`, and
   continues forward from there. This is the fastest path and the
   common case for laband-as-reader because laband publishes its own
   snapshots on every render frame.

2. **Otherwise, replay-from-current-window**: the reader sets
   `last_seen_offset = current - (output_ring_capacity -
   safety_margin)` where `safety_margin = 64 KiB`. It then reads the
   most recent `(output_ring_capacity - safety_margin)` bytes — which
   are still present in the ring because the producer is one safety
   margin ahead of where it would lap them again — and feeds them
   into its parser as if they were the beginning of the stream. The
   parser may show stale state briefly (cursor in the wrong place,
   incomplete escape sequence mid-buffer) but stabilizes within one
   prompt redraw or shell-output flush. This is the strategy when no
   parsed observer has published a snapshot yet (cold reattach of a
   long-idle session, `labpty` running with no Tier 2 parser, etc.).

3. **If the ring is so small or the producer so far ahead that even
   step 2 cannot read without lapping** (a producer writing
   `output_ring_capacity` bytes during the recovery read itself):
   the reader retries step 2 up to 3 times. On persistent failure,
   the reader requests a control-plane `terminateSession` on the
   logical session — this scenario means the consumer cannot keep up
   with even bounded recovery, which is a configuration error
   (output ring too small for the workload), not a transient
   overflow. The error is surfaced to the user.

In all three branches the reader increments
`ring_overflow_observed_total` before resuming. `laband` additionally
notes the overflow in its lifecycle journal so post-mortem analysis can
correlate dropped output with frame rendering.

No retry loop is needed because the producer never invalidates already-
written bytes — it only wraps over them when it laps the reader, which
the wrap check catches.

Step 4 is a single bounded read; no waiting, no interleaving, no torn
reads. If a torn read were possible — and it isn't here because
`output_write_offset` is published only after the bytes are in place —
the seqlock pattern would be appropriate. As designed, the offset acts
as a forward-only fence; the bytes behind it are immutable until the
next wrap.

### Metadata ring (offset after output ring)

Optional. A small SPSC ring of fixed 32-byte records, one per labpty
`read()` call:

```
Offset  Size  Name
------  ----  ----------------------------
0       8     output_offset_start
8       4     length_bytes
12      4     reserved
16      8     master_read_mono_ns        ← when labpty got these bytes
24      8     ring_publish_mono_ns       ← when labpty made them visible
```

Disabled by default. Enable via `openSession` capability flag
`metadata-ring/v1`. Useful for end-to-end latency post-mortems: a reader
correlates its render timestamp against `master_read_mono_ns` to compute
"PTY → screen" latency without instrumenting the renderer.

This is the trader's "tag every order at every hop" discipline applied
to terminal bytes.

## Input ring (`LBPTY-IR-01`) — Phase 2

> **Phase 2 design, not Phase 1.** Phase 1 ships only the `writeInput`
> control RPC (see "Operations"). The input ring is documented here
> so its shape is settled before the protocol freezes, and so the
> file-header reservation in `LBPTY-BR-01` (an offset and zero-byte
> placeholder capacity) is justified. The capability flag
> `input-ring/v1` requires `multi-attach-write-lease/v1` to land
> first; without an arbitrating write lease on the labpty side,
> multiple clients writing the same input ring have no safe
> semantics.

Mirrors the output ring but reversed: single producer (the lease-holding
client), single consumer (labpty). Reasoning to use a ring rather than
SCM_RIGHTS'ing a duplicated master write-side fd (the same fd-sharing
hazard that ruled out master-fd handoff on the output side):

- A ring lets labpty implement bounded backpressure: if its PTY master
  is blocked on write (kernel buffer full), labpty stops draining the
  input ring; if the ring fills, the client gets explicit NACK via the
  counters (it can see `input_writes_blocked_total` ticking).
- Consistent with the output path; one less special case.
- Multiple control writes (e.g., bracketed paste markers around a chunk)
  preserve ordering relative to the bytes within the chunk because
  labpty serializes them in the input-ring read loop.

Capacity: 64 KiB default. Sufficient for hundreds of buffered keystrokes
or one large paste chunk. Larger pastes are sent in pieces.

Input writes have their own counters block adjacent to the input ring
(omitted from this draft for brevity; mirror the output counters with
input-direction fields).

## Wakeup discipline

One wake notification per drained batch from the PTY master, not per
byte. Algo-trader rationale: scheduler wakeups are the single most
expensive operation in this design at ~1–5 µs each. Coalescing across
a `read()`-and-write-to-ring cycle drops wakeup rate by an order of
magnitude with no impact on user-visible latency (the additional bytes
were going to be processed in the same render frame anyway).

Per-reader wake fd lifecycle (Darwin-specific; settled — see
Decision Log):

- Reader creates a pipe via `pipe(&fds[0])`. Sets the read end
  non-blocking and `O_CLOEXEC`.
- Reader includes the **write end** of the pipe as SCM_RIGHTS
  ancillary data on the `attachSession` request. (This is the only
  use of SCM_RIGHTS in Phase 1; it carries a pipe write fd, not a
  PTY master fd.)
- `labpty` receives the write end, stores it in the per-session
  per-reader slot it just allocated, marks the slot occupied. The
  reader's view of "my fd is in slot N" comes back in the
  attachSession response.
- After each ring publish, `labpty` walks the slot table and, for
  each occupied slot whose `wake_pending == 0`, writes one byte to
  the slot's pipe write fd and sets `wake_pending = 1`. The byte
  payload is arbitrary; `\x01` is conventional. The write is
  non-blocking; if the pipe is full (reader is wedged), `labpty`
  surfaces this as a stale-reader sweep candidate rather than
  blocking the event loop.
- The reader's main loop, registered with its own kqueue on the
  pipe's read end via `EVFILT_READ`, wakes when the byte arrives.
  It `read(2)`s and discards everything available (the pipe is
  edge-triggered as far as `wake_pending` is concerned; multiple
  pending bytes coalesce into one drain pass), drains the ring up
  to the current `output_write_offset`, then atomically stores
  `wake_pending = 0` in its slot.
- On detach (or socket close, or stale-sweep), `labpty` closes its
  copy of the pipe write fd. The reader sees EOF on its read end
  on the next kqueue tick and tears down its slot view.

Rationale: `EVFILT_USER` on macOS is a per-kqueue construct and
cannot be triggered cross-process. `eventfd` does not exist on
Darwin. A self-pipe is the simplest, well-understood, cross-process
wake primitive available; the latency cost (~1 µs to `write(1)` +
~1-3 µs scheduler pickup) is dominated by scheduler jitter that no
Darwin primitive avoids. Mach ports / `mach_semaphore_t` were
rejected as adding bootstrap-server / port-rights complexity that
outweighs any speed advantage at the rates this protocol sees.

`wake_pending` is the classic edge-triggered signal coalescer.
Without it, a busy producer saturates the reader's pipe with
redundant bytes; with it, the reader gets at most one outstanding
wake at a time and drains "everything available" on each one.

**Wake ack:** The reader resets `wake_pending` after it has drained
through the offset it observed on wake. This is one atomic store; no
RPC required. The flag lives in the reader's per-reader slot (see
"Per-reader slot table" above).

## Control-plane protocol

Length-prefixed JSON over `SOCK_STREAM` Unix sockets. Each message:

```
+-----------+--------------------+
| u32 LE    | JSON payload bytes |
| length    |                    |
+-----------+--------------------+
```

Why JSON survives here:
- Rate is bounded by user action (open / resize / signal / terminate
  fire at most a handful of times per minute per session).
- The ergonomic and tooling benefits of JSON outweigh the per-message
  overhead at this rate.
- The existing `LabandProtocol` codec is identical in shape; reuse the
  serialization discipline.

What we steal from the trading playbook anyway:

- **Every request has a u64 client sequence number.** Responses echo
  it. Pipelining is allowed; out-of-order responses are matched by
  sequence.
- **Every request has a deadline_mono_ns field.** If the daemon can't
  start processing before this deadline, it returns a `deadlineExceeded`
  error rather than processing late. Trading systems do this so
  late-arriving orders don't get filled at stale prices; we do it so
  a hung daemon doesn't return success for a request the user
  abandoned 10 seconds ago.
- **Errors are typed with codes, not strings.** Strings are
  supplementary, never load-bearing.

### Request schema

Two shapes: the `hello` envelope, which negotiates the protocol version
and capabilities, and the post-`hello` envelope used by every other
operation.

**`hello` request envelope** (the only request that carries a version
field):

```jsonc
{
  "v": 1,                 // protocol major; only valid on hello
  "capabilities": [ ... ],// strings the client offers
  "seq": 0,               // u64, monotonic; hello is seq 0 by convention
  "deadline_ns": 1234567, // monotonic ns; daemon's clock is the reference
  "op": "hello",
  "payload": { /* hello-specific */ }
}
```

**Post-hello request envelope** (every other op). No `v` field; the
version is pinned by the successful `hello` response and is part of
the connection's implicit state for its lifetime.

```jsonc
{
  "seq": 12345,           // u64, monotonic per client
  "deadline_ns": 1234567, // monotonic ns; daemon's clock is the reference
  "op": "openSession",    // operation tag
  "payload": { /* op-specific */ }
}
```

A `v` field in a post-`hello` request is a hard error (`code:
"versionMismatch"`); a missing `v` in `hello` is also a hard error.
This makes the principle "versioning happens once at hello" structural
rather than advisory.

### Response schema (shared envelope)

```jsonc
{
  "seq": 12345,           // echoes request seq
  "ok": true,             // or false
  "code": "ok",           // enumerated error code if !ok
  "message": "...",       // human-readable supplement, never parsed
  "payload": { /* op-specific */ }
}
```

### Operations

`hello` — version and capability negotiation. Must be the first
message on the socket. After the response, the connection is pinned to
the agreed version and capabilities.

`openSession` — fork+exec a child with a fresh PTY. Returns a session
descriptor with `ptyHandle`, `childPid`, `byteRingPath`,
`outputRingCapacity`, `inputRingCapacity`. Payload includes argv, envp
overrides, cwd, initial rows/cols, optional `logicalSessionId` (caller's
preferred identifier; collisions return `sessionIdInUse`).

`attachSession` — attach to an existing session. Returns a session
descriptor with the byte-ring shm path, output ring capacity, the
opaque-snapshot-cache path (if any), and the per-reader slot index the
caller has been assigned. The caller **must** include the write end of
its wake pipe as SCM_RIGHTS ancillary data on this request; `labpty`
stores that fd in the allocated slot. **`attachSession` does not send a
PTY master fd to the caller in any mode.** The master stays with
`labpty`; readers consume bytes through the shared-memory ring and
signal input through `writeInput` (or, in a future phase gated on
`multi-attach-write-lease/v1`, through the input ring).

`writeInput` — write a chunk of input bytes to the session's PTY
master. Payload includes `ptyHandle` and `bytes` (base64-encoded for
JSON safety, bounded to 64 KiB per call). In Phase 1 this is the sole
input mechanism. `labpty` performs the `write(2)` to the master under
its own lock, ensuring no interleaving across concurrent callers.
Multi-attach write-conflict resolution is the caller's concern (e.g.,
`laband`'s client-level lease); `labpty` accepts whatever bytes the
control-socket holder sends.

`listSessions` — returns all known sessions with their descriptors and
current alive/dead status. Bounded response size (max 1024 sessions per
list); larger catalogs paginate by `cursor` token.

`resizeSession` — `TIOCSWINSZ` on the master. Updates `rows`/`cols` in
the session descriptor and atomically in the counters block.

`signalSession` — sends a signal to the child's process group via
`killpg`. Useful for `SIGINT` / `SIGKILL`.

`terminateSession` — graceful shutdown: send `SIGHUP` to pgrp, wait up
to `gracePeriod` ms (default 200), then `SIGKILL`. Closes the master,
frees the ring. Catalog entry is marked dead but retained for one
generation for forensic queries.

`publishOpaqueSnapshot` — **Phase 2.** Stores an opaque blob (the most
recent parsed snapshot the active client emitted) in the snapshot-cache
shm region. `labpty` never parses it. A fresh attach can read it for
instant display before catching up via byte-ring replay. Phase 1's
overflow recovery uses the unconditional in-ring replay strategy (see
"Overflow recovery"); the snapshot cache only optimizes the latency of
that recovery for the common laband-as-reader case, so it's optional
and gated on the `opaque-snapshot-cache/v1` capability.

`ping` — control-plane heartbeat. Returns daemon mono ns. Used by
control-channel clients that don't have the shm counters mapped (e.g.,
diagnostic tools); also serves as the connection liveness check when
the shm-based heartbeat is not available.

### Error codes

Enumerated. No new codes added without an ABI minor bump:

```
ok                       // not actually an error, present in responses
sessionNotFound
sessionIdInUse
ptyOpenFailed
ringMapFailed
deadlineExceeded
capabilityRequired
versionMismatch
permissionDenied
internalError            // bug, includes message for diagnostics
shuttingDown
```

`internalError` is the only one that carries a stack-trace-y message.
The others are precise.

## Capability negotiation

Capabilities are short string tokens with explicit versions. Both sides
exchange their supported set at `hello`; the effective set is the
intersection.

Capabilities shipped in Phase 1:

```
byte-ring/v1                  // output ring with the layout in this doc
write-input-rpc/v1            // writeInput control RPC (base64 JSON)
wake-pipe-scm/v1              // pipe write-end via SCM_RIGHTS at attach
heartbeat-shm/v1              // producer_alive_mono_ns in counters block
session-id-pinning/v1         // accepts client-supplied logicalSessionId
deadline-enforcement/v1       // honors deadline_ns
```

Optional in Phase 1 (depends on whether the implementation lands them):

```
opaque-snapshot-cache/v1      // publishOpaqueSnapshot + cache region
                              // — recommended; speeds overflow recovery
                              //   for laband-as-reader
```

Reserved for later phases (deliberately **not** Phase 1):

```
input-ring/v1                 // SPSC input ring + pipe wake.
                              // Requires multi-attach-write-lease/v1
                              // because direct ring writes have no way
                              // to arbitrate among multiple writers.
                              // Phase 2.

multi-attach-write-lease/v1   // labpty-level write lease primitive.
                              // Necessary prerequisite for input-ring/v1.
                              // Phase 2.

metadata-ring/v1              // per-read latency tags for post-mortems.
                              // Phase 2; the layout reserves header
                              //   slots so adding it is additive.

fd-handoff/v1                 // labpty self-upgrade: PTY master fds
                              // pass between old and new labpty via
                              // SCM_RIGHTS, never to a client.
                              // Phase 3.

shared-snapshot-ring/v1       // bridge to the existing LBNDSS01 ring
                              // if it ever has a labpty-side consumer.
                              // Indefinite; speculative.
```

Any capability not in the negotiated intersection is treated as missing;
clients fall back gracefully (the Phase 1 fallback for `input-ring/v1`
is `write-input-rpc/v1`; the Phase 1 fallback for
`opaque-snapshot-cache/v1` is the in-ring "replay from current window"
recovery described under "Overflow recovery").

Two capabilities from earlier drafts of this document were removed
deliberately, not by oversight:

- `scm-rights-attach/v1` (the old "master fd via SCM_RIGHTS in
  attachSession"). Removed for the architectural reason in
  `execplans/active/labpty-extraction.md`: `labpty` is the sole
  steady-state reader/writer of every PTY master. SCM_RIGHTS in Phase 1
  exists only for the wake-pipe write end (`wake-pipe-scm/v1`).
- `input-ring/v1` as a Phase 1 capability. Direct shared-memory input
  has no safe semantics without an arbitrating write-lease primitive
  on the labpty side, and that primitive is its own design problem.
  Phase 1 keeps input on the control RPC where laband's existing
  client-level lease already arbitrates among multiple attached
  clients.

## Heartbeat and liveness

**labpty → readers:** `producer_alive_mono_ns` in the counters block,
updated at 100 ms cadence from labpty's main event loop. Readers check
on each wake (~free, just a load). Stale by >300 ms ⇒ labpty hung; the
reader emits a diagnostic and reconnects.

**Readers → labpty:** Each attached reader holds a `consumer_alive_mono_ns`
slot in the counters block, updated at 1 Hz (slower because there are
more readers). labpty sweeps stale slots every 5 s; readers stale by
>10 s have their wake registrations dropped (the master stays open;
output keeps draining into the ring; only the wake stops).

This is the trader's feed-staleness detector applied to terminal byte
streams. The numbers are conservative — terminals are not microsecond
sensitive — but the discipline is the same.

## Timeouts and deadlines

| Operation | Default deadline | Notes |
| --- | --- | --- |
| `hello` | 1000 ms | First contact; OS scheduling jitter dominates |
| `openSession` | 500 ms | `posix_spawn` is the bottleneck |
| `attachSession` | 100 ms | Should be sub-ms in practice |
| `listSessions` | 50 ms |  |
| `resizeSession` | 50 ms |  |
| `signalSession` | 50 ms |  |
| `terminateSession` | gracePeriod + 200 ms | grace is user-supplied |
| `publishOpaqueSnapshot` | 50 ms |  |
| `ping` | 50 ms |  |
| Wake notification → reader observes new offset | 10 ms | Else reader considers labpty unresponsive |

Deadlines are advisory in the response sense (daemon returns
`deadlineExceeded` if it can't service in time) and hard in the
client sense (client gives up after deadline regardless of daemon
state).

## Backpressure

**Output direction:** None at the kernel level. labpty drains the master
as fast as it can. If readers fall behind and the ring wraps, the bytes
they missed are lost from their perspective; they must recover via the
opaque snapshot. This is the right model: terminals are
display-current-state, not replay-history. The byte ring is sized
generously enough (8 MiB default) that wraps shouldn't happen in
practice.

**Input direction:** Bounded by the input ring's capacity. If the kernel
buffer for the PTY master write blocks, labpty stops draining the input
ring. The ring fills. The client sees `input_writes_blocked_total`
incrementing and either applies its own pacing or accepts that further
writes will be rejected. This is the algo-trader rate-limit model: tell
the producer to slow down rather than letting buffers grow without
bound.

**Shutdown:** `terminateSession` is a producer drain operation. labpty
keeps draining the ring while killing the child gracefully, so any
final output (exit codes, last line of output) makes it through to
attached readers before the ring is freed.

## Observability

Counters live in the per-session counters block (above). Additionally,
the daemon exposes a process-global counters block at a well-known shm
path:

```
labpty_daemon_counters/{run_id}
+---------+-------------------------------+
| u64     | sessions_opened_total         |
| u64     | sessions_terminated_total     |
| u64     | attach_calls_total            |
| u64     | rpc_calls_total               |
| u64     | rpc_errors_total              |
| u64     | rpc_deadline_exceeded_total   |
| u64     | uptime_mono_ns                |
| ...     |                               |
+---------+-------------------------------+
```

This is what an algo-trader's monitoring would scrape every 10 seconds.
No structured logging is required to know "is this daemon healthy".

Diagnostic dumps (full session catalog, lease state, recent error log)
are accessed via the `ping` op extended with capability flags. The
hot-path counters are always available; the heavyweight dumps are gated.

## Execution model

Single-threaded event loop per labpty process. One kqueue (macOS)
watches:

- All PTY master fds (one per session), `EVFILT_READ`.
- All client control sockets, `EVFILT_READ` (for inbound RPCs).
- A self-pipe for control-plane shutdown signaling, `EVFILT_READ`.

Wake-pipe writes to readers are outbound; `labpty` queues one
non-blocking `write(2)` per ready reader after each ring publish.
These are not kqueue-watched on the labpty side; the receiving
process's kqueue handles them.

Phase 2 (input ring) will add a `EVFILT_READ` registration per
session's input-ring wake pipe so labpty can drain client-written
input bytes promptly. Phase 1 has no input-ring wakes because input
arrives as a control-RPC `writeInput`.

Why single-threaded:

- No locks. Algo-trader axiom: locks are a tail-latency liability.
  Without locks, p99 is the kqueue tick + ring memcpy time, which is
  deterministic.
- Scheduler determinism. One thread on one core (or wherever the
  scheduler runs us) is as predictable as macOS allows.
- Scales to thousands of sessions before single-threaded becomes the
  bottleneck. Laban will never have thousands of sessions.

Scratch buffers for `read()`/`write()` are preallocated per session at
`openSession` time. The event loop allocates nothing per tick.

Per-tick budget: 100 µs target, 1 ms hard ceiling. If a tick exceeds
the ceiling, log and continue; if it exceeds repeatedly, the daemon is
in trouble and the diagnostics endpoint should surface that.

## Forbidden patterns

These are pulled from the algo-trader playbook of "things that ruin tail
latency":

- **No allocations on the hot path** (PTY drain, ring publish, wake
  signal, input ring read).
- **No locks on the hot path.** Atomic operations only.
- **No syscalls inside the ring publish.** kqueue wake is a syscall,
  but it's at the end of the batched tick.
- **No `Codable` decoding on data-plane bytes.** Ever. They are bytes.
- **No string formatting** for any field that ends up in shm or in a
  hot-path code path. Format on demand at the periphery.
- **No exception-driven control flow** in Swift code on the hot path.
  Use `Result`-style sentinels or fixed return codes.
- **No virtual dispatch on the hot path.** Concrete types only.
- **No retain/release on the hot path.** Use unmanaged pointers where
  the lifetime is clear (the shm mapping outlives every call).

## Sequence diagrams

### Steady-state output flow

```
PTY master           labpty event loop          ring                consumer
   |                       |                     |                     |
   |---bytes ready (kqueue)|                     |                     |
   |                       |--read(buf, 16KiB)-->|                     |
   |<-- bytes copied ------|                     |                     |
   |                       |--memcpy to ring---->|                     |
   |                       |--release store wo-->|                     |
   |                       |--write(wake_pipe,1) |---byte on pipe----->|
   |                       |  if !wake_pending   |  (reader's kqueue   |
   |                       |  set wake_pending=1 |   EVFILT_READ wakes)|
   |                       |                     |                     |--acquire load wo
   |                       |                     |                     |--memcpy out
   |                       |                     |                     |--read(wake_pipe)
   |                       |                     |                     |  drain pending bytes
   |                       |                     |                     |--store wake_pending=0
```

**Design budgets** (not CI thresholds):

- p50 ~5 µs from PTY ready to consumer holding bytes.
- p99 ~50 µs. Most of the variance comes from the pipe write +
  scheduler pickup, neither of which we control.

These are targets to design *toward*, not absolute numbers a build can
fail on. Production macOS scheduling jitter, contention from unrelated
processes, and the `pipe(2)` write path itself produce occasional
outliers in the hundreds of microseconds on a busy machine. See
"Validation strategy" for how CI actually gates on this.

### Attach sequence

```
client                                          labpty
  |---pipe(&fds[]); fds[0]=read, fds[1]=write
  |   register fds[0] with own kqueue on EVFILT_READ
  |---attachSession(ptyHandle, SCM_RIGHTS=fds[1])->|
  |                                                |--receive write fd
  |                                                |--claim slot in
  |                                                |  per-reader table
  |                                                |--store write fd in slot
  |                                                |--build descriptor
  |<--attach response w/ slot index, byte-ring----|
  |   path, output capacity, optional snapshot
  |   cache path. NO master fd.
  |---open(byteRingPath, O_RDONLY, mmap)
  |---validate header (magic, abi_major, capacity)
  |---store last_seen_offset = current_write_offset
  |---read producer_alive_mono_ns; verify fresh
  |---close(fds[1])  // labpty has its own dup; we don't need ours
  |---ready
```

**Design budget:** p50 ~200 µs (one socket roundtrip + one `mmap`).
Treated as a design target; CI does not gate on absolute microseconds
here either.

## What this design does *not* try to do

Honest scope limits:

- **No cross-machine transport.** Unix domain only. Network attach is a
  Tier 2 concern handled by `laband` on top, not `labpty`.
- **No encryption.** Authorization is "peer is the same UNIX uid as the
  daemon," checked at connect time via `getpeereid(socket, &euid,
  &egid)` (the Darwin POSIX call). On any other Unix this would be
  `SO_PEERCRED`, but Laban's product target is macOS and
  `SO_PEERCRED` is a Linux-only socket option; `getpeereid` is the
  portable Darwin equivalent. `LOCAL_PEERCRED` via `getsockopt(s,
  SOL_LOCAL, LOCAL_PEERCRED, ...)` is the older lower-level form and
  also acceptable; the design fixes the **semantics** (same-uid peer)
  rather than the specific syscall, and either Darwin primitive
  satisfies them. Cross-uid attach fails with `permissionDenied`.
- **No replicated state across labpty instances.** One labpty per user
  per machine. High availability is "make labpty unkillable in practice",
  not "active-active replication".
- **No persistence of byte rings across labpty restart.** When labpty
  exits, ring shm files are unmapped and unlinked. Children die unless
  Phase 3 fd-handoff is implemented.
- **No buffering policy beyond the ring.** Output bytes that arrive
  faster than readers can drain are wrapped over. No spill-to-disk.

These are deliberate omissions. Adding any of them is a future ADR's
problem.

## Validation strategy

Tests live in `Tests/LabptyTests/`. Functional invariants gate the build
mechanically; latency is tracked as a histogram against a regression
budget, **not** an absolute microsecond threshold (macOS scheduler
jitter on shared CI hardware makes absolute thresholds flaky and
discredits the suite).

**Functional invariants** (each gates the build on exact-match
behavior):

| Invariant | Test |
| --- | --- |
| Power-of-two output capacity enforced | `testRingCapacityMustBePowerOfTwo` |
| Header magic and abi version checked on attach | `testAttachRejectsBadMagic` |
| Reader-slot table is 8 × 64 bytes at offset 256 | `testReaderSlotTableLayout` |
| Producer alive heartbeat advances ≥ 50 ms in 150 ms | `testProducerAliveIncrements` |
| Consumer detects wrap and recovers per "Overflow recovery" | `testConsumerDetectsRingWrap` |
| Wake coalesces; bursty writes produce fewer wakes than publishes | `testWakeCoalescing` |
| Deadline rejected at daemon when exceeded | `testDeadlineExceededRejected` |
| Sequence number echo | `testSequenceNumberEcho` |
| `attachSession` **does not** return a master fd, never, in any code path | `testAttachReturnsNoMasterFd` |
| `attachSession` does accept and store a wake-pipe write fd | `testAttachAcceptsWakePipe` |
| Cross-uid attach fails with `permissionDenied` | `testAttachRejectsCrossUid` |
| `v` field rejected on post-`hello` requests | `testVersionFieldOnlyOnHello` |
| Hot-path allocation profile is bounded | `testHotPathAllocationCount` (sample-mode) |
| `labpty` restart kills children (Phase 3 will lift this) | `testLabptyExitClosesMaster` |
| `laband` restart preserves children | `testLabandRestartPreservesChildViaLabpty` (in `Tests/LabandTests/`) |

**Latency tracking** (does not gate the build by default):

A `BenchPtyLabptyEcho` tool — sibling to today's
`Tools/KeystrokeLatencyBench` — drives a known workload through the
stack and emits per-bucket histograms (1 µs buckets up to 1 ms, 100 µs
buckets to 100 ms). Each CI run uploads its histogram to
`.artifacts/runs/<run-id>/labpty/latency/`. The check is **comparison
against a rolling 30-day baseline**:

- If the new run's p50 exceeds baseline p50 by > 1.5× or the new p99
  exceeds baseline p99 by > 2×, the check fails. (These are the
  "regression budget" numbers; tune after the first month of data.)
- Absolute thresholds in earlier drafts (p50 < 10 µs, p99 < 100 µs)
  are retained as **design budgets** in "Sequence diagrams", not as
  build gates. They describe what the implementation should aim for
  on a quiet machine, not what every CI run must achieve.
- An `LABPTY_LATENCY_REQUIRE_BUDGET=1` opt-in mode runs the same
  bench against the absolute design budgets, for developers
  validating a candidate implementation on local hardware. It is
  not enabled in shared CI.

## Open questions

Defer to implementation experience:

- **Counters block alignment under macOS shared memory.** Ensure
  64-byte alignment by `shm_open` + `ftruncate` + `mmap` of an
  appropriately rounded size, with the header pinned at offset 0.
- **Multi-reader writeable counter scheme.** The `consumer_alive_mono_ns`
  per-reader slots: how many to preallocate (proposal: 8), and what
  happens if a 9th reader attaches (proposal: reject with
  `attachLimitExceeded`).
- **Endianness.** Apple Silicon is little-endian; document as the only
  supported endianness for the wire and shm. No conversion routines.
- **Snapshot cache size.** One blob? Last N blobs? Time-based eviction?
  Probably one for Phase 1, ring of last 4 in Phase 2 for diagnostics.

These are tracked in the Phase 1 ExecPlan's M0 milestone.

## Why this is worth the discipline

The naive design — JSON over Unix socket for everything, allocate per
message, no heartbeat, no counters — would work. It would also produce
a daemon whose tail latency is dominated by GC pauses (Swift's ARC), JSON
parse spikes, and unbounded buffer growth under load. It would be
*indistinguishable from working* until a user's busy build session
saturated the control plane and the daemon stopped responding to
keystrokes for 300 ms. That's the failure mode algo traders see in
naive feed handlers, and it's the failure mode labpty must not have.

The disciplines above buy a daemon whose worst-case behavior is bounded
and observable. The cost is roughly 600 lines of carefully-written
code versus 200 lines of careless code, plus a couple of weeks of
implementation. The benefit is that the protocol can be frozen — which
is the entire point of putting `labpty` below `laband`.

## Decision Log

Load-bearing design decisions that survived review. Each entry records
why an alternative was considered and rejected.

- Decision: `attachSession` does not return a PTY master fd. SCM_RIGHTS
  in Phase 1 carries only the reader's wake-pipe write end.
  Rationale: Two processes blocked in `read(2)` on the same PTY master
  fd race for individual bytes; POSIX makes no per-byte fairness or
  atomicity guarantee. Two writers interleave. The previous draft of
  this doc handed the master fd out at attach time, which would have
  let any client read or write the same master as `labpty` and split
  the byte stream non-deterministically. The fix is to make `labpty`
  the sole custodian and route input through `writeInput`. The
  `fd-handoff/v1` capability remains reserved for Phase 3 labpty
  self-upgrade, which is the only legitimate scenario for a PTY master
  fd to cross a process boundary.
  Date/Author: 2026-05-26 / review iteration.

- Decision: Per-reader state lives in a separate 8-slot × 64-byte
  table at offset 256, not in the 128-byte counters block.
  Rationale: An earlier draft put per-reader wake-pending flags and
  consumer-alive timestamps in the same 128-byte counters block as
  the global counters. Eight readers at 64 bytes each (one cache line
  per reader, to avoid false sharing on the wake flag) need 512
  bytes, which obviously does not fit in 128. The fix introduces a
  dedicated `Per-reader slot table` region with its own offset in the
  file header; the counters block stays one cache line.
  Date/Author: 2026-05-26 / review iteration.

- Decision: Authorization uses `getpeereid` (Darwin POSIX), not
  `SO_PEERCRED` (Linux only).
  Rationale: Laban's product target is macOS. `SO_PEERCRED` is a
  Linux-specific socket option not available on Darwin. `getpeereid`
  is the macOS-portable peer-credential primitive; `LOCAL_PEERCRED`
  via `getsockopt(SOL_LOCAL)` is the older lower-level form and is
  also acceptable. The design fixes the semantics (same-uid peer
  required, cross-uid attach fails with `permissionDenied`); the
  implementation picks one of the two Darwin primitives.
  Date/Author: 2026-05-26 / review iteration.

- Decision: Reader wake primitive is a self-pipe with the write end
  passed to `labpty` via SCM_RIGHTS at attach time.
  Rationale: `eventfd` does not exist on Darwin. `EVFILT_USER` is a
  per-process kqueue construct and cannot be triggered cross-process;
  earlier drafts treated it like a passable equivalent to `eventfd`,
  which was wrong. Mach semaphores would work but bring
  bootstrap-server and port-rights complexity that outweighs any
  speed advantage at the rates this protocol sees. A pipe is the
  simplest, well-understood, cross-process wake primitive available
  on Darwin; the ~1 µs `write(1)` cost plus scheduler pickup is
  dominated by jitter that no Darwin primitive avoids. This is the
  only Phase 1 use of SCM_RIGHTS.
  Date/Author: 2026-05-26 / review iteration.

- Decision: Overflow recovery is tiered (fresh snapshot → in-ring
  replay → controlled failure), not solely "request opaque snapshot."
  Rationale: `labpty` does not parse VT state and cannot synthesize a
  snapshot on demand. The opaque snapshot cache is populated only when
  some parsing client (`laband` in Phase 1) has recently called
  `publishOpaqueSnapshot`. A cold-attached or long-idle session may
  have no cached snapshot, in which case the recovery must work from
  the ring alone. The chosen strategy replays the most recent
  `(capacity - safety_margin)` bytes through the parser, accepting a
  brief stale render until the next prompt redraw. The opaque
  snapshot remains an optimization for the common laband-as-reader
  case, not a precondition for correctness.
  Date/Author: 2026-05-26 / review iteration.

- Decision: `input-ring/v1` and `multi-attach-write-lease/v1` are
  Phase 2, not Phase 1.
  Rationale: Direct shared-memory input writes from multiple clients
  have no safe semantics without an arbitrating write-lease primitive
  on the `labpty` side. Designing and validating that lease is a
  separate problem from PTY custody. Phase 1 routes all input through
  the `writeInput` control RPC where `laband`'s existing client-level
  lease already arbitrates among multiple attached clients. The
  shared-memory input ring can ship in Phase 2 once a labpty-level
  lease primitive exists and keystroke latency measurements justify
  the additional complexity.
  Date/Author: 2026-05-26 / review iteration.

- Decision: Microsecond latency targets are design budgets, not CI
  gates.
  Rationale: `testPtyToConsumerLatencyP50 < 10 µs` and `…P99 <
  100 µs` would be flaky on shared macOS CI hardware where scheduler
  jitter under unrelated load routinely produces sub-millisecond
  outliers. CI compares each run's histogram against a rolling
  30-day baseline (regression budget: p50 within 1.5×, p99 within
  2×); the absolute design budgets remain in the sequence-diagram
  section as "what the implementation should aim for on a quiet
  machine" and are reachable via the `LABPTY_LATENCY_REQUIRE_BUDGET=1`
  opt-in for local hardware validation.
  Date/Author: 2026-05-26 / review iteration.

- Decision: The `v` field is only valid in `hello` requests; all other
  requests omit it.
  Rationale: The design principle is "versioning happens once at
  handshake, never per message." An earlier draft showed `v` in the
  shared request envelope, contradicting the principle. The fix
  splits the envelope into a `hello`-specific shape that carries `v`
  + `capabilities` and a post-`hello` shape that does not; a `v`
  field in any other op is `versionMismatch`. This makes the
  invariant structural rather than advisory.
  Date/Author: 2026-05-26 / review iteration.
