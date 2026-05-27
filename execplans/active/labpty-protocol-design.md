# labpty Protocol Design

Design notes for the wire protocol and shared-memory layouts owned by
`labpty`, the kernel-resource custodian introduced in ADR 0006. This is
a working specification — not yet a `docs/reference/` artifact — that
`execplans/active/labpty-and-app-direct.md` implements. Once `labpty`
ships and the protocol has survived its first real load, this document
graduates to `docs/reference/labpty-protocol.md` and the ABI gets
frozen.

## Who consumes `labpty`'s surfaces

`labpty`'s only client in the planned default ("Background sessions")
is `LabanApp`. The active plan also retains the existing
`laband`-mediated path as a third selectable mode ("Detached sessions"),
but Detached sessions don't go through `labpty` — `laband` owns its
own PTYs directly, as it does today. So in steady state:

- **Background mode**: `LabanApp` ↔ `labpty` ↔ child PTY. `LabanApp`
  runs the parser in-process and reads bytes from `labpty`'s byte
  ring. This is the path the rest of this document describes.
- **Detached mode**: `LabanApp` ↔ `laband` ↔ child PTY. `labpty` is
  not involved. Out of scope for this document.
- **Local mode**: `LabanApp` ↔ child PTY directly. Also out of scope.

Sections below sometimes refer to `laband` for historical reasons (an
earlier draft of the implementation plan made `laband` a `labpty`
client). Where a section names `laband` as "the labpty client," read
"`LabanApp`." Where a section discusses
`multi-attach-write-lease/v1` as a prerequisite for `input-ring/v1`,
note that the active plan's M5 ships the **single-writer flavor**
without the lease (one app, one writer; the lease is deferred until a
multi-writer scenario is concrete). The "Phase 2 single-client
byte-ring mode" repeatedly named below as a future trigger for wake
pipes is **the current Background-mode default**, not a future
state — but the wake-pipe deferral still stands (polling delivers the
same outcome at zero `labpty` state). A graduation pass to
`docs/reference/labpty-protocol.md` will sweep the residual
historical phrasing.

This design is written with the disciplines an algorithmic trading firm
would apply to a low-latency local IPC: every operation has a latency
budget, every allocation is intentional, hot paths are lock-free,
backpressure is explicit, and observability is non-optional. The reasoning
is exposed inline so a contributor can see *why* a choice was made and
whether their proposed change preserves the invariant.

## Design principles

These are the axioms. Every concrete decision below traces to one of
them. Principle 0 is the load-bearing one; the others apply *within*
the surface 0 lets through.

0. **Surface minimalism is the architectural goal, not a stretch
   target.** Every line of `labpty` code is a line that can have a bug,
   and every `labpty` bug forces the one upgrade or restart that still
   kills live sessions until Phase 3 fd-handoff lands. The whole point
   of putting `labpty` *underneath* its client (`LabanApp` in Background
   mode; any future labpty client) is to make the bottom process so
   small and boring that we almost never need to touch it. The mode
   test for every feature is: **"Can the client do this without
   `labpty`?"** If yes, the feature lives in the client. Features
   earn their place in `labpty` only by being (a) required to keep
   the PTY alive (drain output, accept input, resize, signal,
   terminate), (b) required to preserve an ADR invariant (ADR 0002
   launch), or (c) required so the client can rediscover sessions
   after restart (`listSessions`, the byte ring shm path). Everything
   else — recovery policy, multi-attach lease, snapshot caching,
   rich observability, latency-forensics tagging — belongs in the
   client, which is allowed to change often *because* `labpty`
   exists.

1. **Latency is measured, not estimated.** Every hot-path operation
   carries timestamps at multiple stages. A latency regression must be
   diagnosable from production counters without attaching a profiler.
   *Phase 1 application: only the minimum counters needed to debug "is
   labpty alive and are bytes moving" land in shm; richer per-read
   timestamping is Phase 2's `metadata-ring/v1`.*
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
5. **Schema is fixed-offset binary on both planes.** Hot path: shm
   ring with atomic offsets. Control plane: length-prefixed binary
   frames over Unix `SOCK_STREAM`. JSON was the earlier choice (rate
   is bounded by user action; ergonomics matter) but lost on the
   day `labpty` was committed to C: a JSON parser in C is the single
   most exposed surface a fuzzer would have to cover, and at ~300
   LoC for a closed-schema parser the cost outweighs the human-`jq`
   benefit. Binary frames are ~80 LoC of bounded decoder, a trivial
   fuzz target, and need no base64 for `writeInput` bytes. Human
   debugging happens through a separate `Tools/LabptyDump` shim that
   pretty-prints captured frames. **The binary protocol is a chance
   to make the protocol smaller, not a chance to translate the JSON
   one byte-for-byte: every decoder byte is now `labpty` code,
   subject to the verification bar.** Concrete trims below: `u64`
   pty handles (not 64-byte strings), `argv`/`envp` as counted
   arrays of length-prefixed strings (decoded into a daemon-lifetime
   `mmap`'d scratch arena), `writeInput` payload-bytes implicit
   from frame length (no inner length prefix), no configurable
   terminate grace period, no foreground-process strings on the
   wire (labpty returns only `foreground_pid` and `foreground_pgid`;
   the client resolves names/paths via its own libproc call).
6. **Versioning happens once, at handshake, never per message.** After
   `hello`, both sides know the schema. No version field on any
   subsequent message.
7. **Capabilities are explicit and additive.** New features land behind
   capability flags negotiated at handshake. Old clients refuse what
   they don't understand; new clients fall back when capabilities are
   missing.
8. **Every operation has a typed error code.** Infinite hangs and
   exception-driven control flow are forbidden. *Phase 1 application:
   deadlines are advisory — clients may include `deadline_ns` and
   enforce locally by tearing down the socket; `labpty` does not check
   deadlines itself until measurement justifies the syscall.*
9. **Heartbeat from `labpty` to readers via shm.** Peer death is
   detected in hundreds of milliseconds, not minutes. *Phase 1
   application: only the producer-alive heartbeat ships; reader →
   labpty heartbeat is Phase 2 (`labpty` does not track readers in
   Phase 1).*
10. **Observability is in-band, not optional.** Per-session counters
    live in shared memory, sampled by anyone with read access. No
    log-scraping required. *Phase 1 application: the per-session ring
    header carries the minimum counters
    (`output_bytes_written_total`, `output_wrap_count`,
    `producer_alive_mono_ns`). Daemon-global counters and per-read
    latency tags are Phase 2.*
11. **No daemon-side allocation on the hot path.** Buffers are
    preallocated at session open. Read/write/ring/wake — zero
    allocations after warm-up.
12. **The ABI must be frozen-able.** Every layout choice anticipates a
    later `freeze` event after which fields cannot move or change
    meaning, only be added at the end. Phase 1 reserves Phase 2 regions
    at their final offsets even when it does not populate them, so
    Phase 2 is a pure addition.

## Phase 1 thin surface

Surface principle 0 makes the Phase 1 / Phase 2 / Phase 3 split
explicit. This section enumerates the smallest credible surface; the
rest of the document elaborates the *eventual* shape that Phase 2+
moves toward. A fresh implementer of Phase 1 should be able to read
this section and `execplans/active/labpty-and-app-direct.md` and
skip the "Phase 2" subsections of everything below.

**Phase 1 RPCs** (eight):

- `hello` — version + capability negotiation.
- `openSession` — fork+exec a child with a fresh PTY; return
  descriptor (`ptyHandle`, `childPid`, `rows`, `cols`,
  `byteRingShmPath`, `foregroundPid`, `foregroundPgid`).
- `listSessions` — return descriptors for every live session.
  Includes the byte-ring shm path so callers can read directly; no
  separate "attach" step.
- `resizeSession` — `TIOCSWINSZ` on the master.
- `signalSession` — `killpg` to the child's process group.
- `terminateSession` — graceful shutdown.
- `writeInput` — bounded raw byte chunk (≤ 64 KiB); `labpty` writes to master.
- `ping` — control-plane heartbeat / connection liveness.

**Phase 1 shared memory** (one shm file per session):

- File header carrying magic, abi version, capacities, and offsets.
- The output byte ring (default 8 MiB, lock-free monotonic
  write-offset).
- Three counters: `output_bytes_written_total`,
  `output_wrap_count`, `producer_alive_mono_ns`. Everything else is
  reserved space whose offsets are pinned for Phase 2.

**Phase 1 transports:**

- Length-prefixed binary frames (`LBPTY-CT-01`) over Unix
  `SOCK_STREAM` for control RPCs. ~80 LoC of bounded decoder in C;
  trivially fuzzable; no JSON anywhere on the wire.
- Output byte ring in shm for the data plane.
- Input via the `writeInput` control RPC, raw bytes in the frame
  payload. No shared-memory input ring.
- **No SCM_RIGHTS anywhere.** No PTY master fd handoff (forbidden by
  the single-custodian invariant); no wake-pipe fd handoff (readers
  poll the ring).

**Phase 1 reader model:**

`LabanApp` (the Background-mode client, and the only reader by default;
any future reader would behave the same way) opens the byte ring
read-only, samples `output_write_offset` on a poll tick (4 ms is the
recommended starting interval; tune later), reads new bytes, feeds
them into its own parser. `labpty` does not know readers exist; there
is no per-reader slot table populated, no wake registry, no
consumer-alive tracking. Phase 2 introduces wake pipes and per-reader
state if and only if measurements show the polling tick is a
perceptible source of latency.

**Phase 1 control-plane semantics:**

- Request envelope: `{seq, op, payload}`. No `v` (negotiated at
  `hello` only). No `deadline_ns` enforcement (clients may include
  it; `labpty` ignores).
- Response envelope: `{seq, ok, code?, payload?}`.
- One outstanding request at a time per connection (no pipelining
  required in Phase 1; the protocol shape allows it later).

**What is deliberately NOT in Phase 1:**

- `attachSession` RPC (no per-reader state to register; `listSessions`
  is sufficient for discovery).
- SCM_RIGHTS on any RPC (master fd never crosses a process boundary
  in normal operation; wake-pipe fd handoff is Phase 2 if polling
  proves insufficient).
- Shared-memory input ring (`LBPTY-IR-01`).
- Per-reader slot table writes by `labpty`. The slot-table offsets
  are reserved in the file header for ABI stability, but `labpty`
  does not write to those bytes and readers do not read them.
- Wake mechanism. Readers poll.
- `publishOpaqueSnapshot` and the snapshot-cache shm region.
- Metadata ring (`LBPTY-MR-01`).
- Daemon-global counters file
  (`labpty_daemon_counters/{run_id}`).
- Deadline enforcement in `labpty`.
- Reader → `labpty` heartbeat slots; stale-reader sweep; per-reader
  `consumer_alive_mono_ns`.
- Latency-forensics benchmarks gating CI on absolute microseconds.

Each of these earns its place in a later Phase by a deliberate
decision, recorded in a Decision Log entry, against an observed need
that the client could not solve from above. The Decision Log entries
near the end of this document already record the Phase 1 deferrals
explicitly.

## Transport map

| Concern | Transport | Why |
| --- | --- | --- |
| Control RPC (hello, openSession, listSessions, resizeSession, signalSession, terminateSession, writeInput, ping) | Length-prefixed **binary frames** over Unix `SOCK_STREAM` (`LBPTY-CT-01` framing, see "Control-plane protocol" below) | Bounded rate. C-side decoder is ~80 LoC and trivially fuzzable. Binary lets `writeInput` carry raw bytes without base64. Human-readable debugging happens through `Tools/LabptyDump`, not on the wire. |
| Output bytes (PTY → readers) | Single-producer multi-consumer shared-memory ring (`LBPTY-BR-01`) | Hot path. Hundreds to thousands of writes per second per active session. Zero IPC overhead per byte. |
| Input bytes (writer → PTY), Phase 1 | `writeInput` control RPC on the same Unix socket, bytes carried directly in the binary frame payload (no base64), bounded to 64 KiB per call | Keystroke and paste throughput is bounded by user action. Avoids the cost of building a real shared-memory input path before measurements justify it. **Phase 1's writer is `LabanApp` (one writer per session by construction).** Multi-writer arbitration is not a Phase 1 concern. |
| Input bytes (writer → PTY), Phase 2 | Single-producer single-consumer shared-memory ring (`LBPTY-IR-01`) per session, with pipe-based wakeup | Lower-rate hot path. SPSC ring matches the output path's discipline. The active plan's M5 ships the **single-writer flavor** without `multi-attach-write-lease/v1`; a future multi-writer scenario would re-introduce the lease prerequisite. |
| Reader readiness, Phase 1 | Readers poll the byte ring's `output_write_offset`. Recommended tick: 4 ms (250 Hz). `labpty` does nothing — no per-reader registry, no fd handoff. | Polling for a `LabanApp`-attached reader is dominated by `LabanApp`'s own render-frame cadence (~16 ms at 60 Hz); the polling tick is invisible at the system level. Costs `labpty` zero state and zero code; matches surface principle 0. |
| Reader readiness, Phase 2 | Pipe write-end handed to labpty via SCM_RIGHTS at attach time; labpty writes one byte per coalesced batch | Lands when measurements show the Phase 1 polling tick is a perceptible latency source — primarily a Phase 2 / single-client-byte-ring-mode concern, not a Phase 1 concern. Documented under "Wakeup discipline (Phase 2)" below. |
| Heartbeats, `labpty` → readers | Shared-memory timestamp `producer_alive_mono_ns`, updated on each event-loop tick capped at 100 ms cadence | No kernel call to check "is the other side alive". One u64 store per tick on labpty; one u64 load per reader poll. |
| Heartbeats, reader → `labpty` (Phase 2) | Reserved field in the per-reader slot table | Phase 1 `labpty` does not know readers exist, so this primitive is meaningless until the per-reader slot table is populated in Phase 2. |
| Per-session counters | Shared-memory counters block at fixed offset of the byte ring | Anyone with the shm path can sample. No RPC needed. |
| Self-upgrade fd handoff (`labpty` itself) | LISTEN_FDS-style env + a status pipe, plus SCM_RIGHTS handoff of PTY master fds between old and new `labpty` instances | **Phase 3 only**; the only design where a PTY master fd legitimately crosses a process boundary. Out of scope for Phase 1; documented here for foresight. |

The shared-memory artifacts per session (byte ring, future input ring,
future metadata ring, per-reader slot table) share one file but are
distinct regions described by the file header. The control socket
carries only the file path and offsets; PTY payload bytes never cross a
socket.

### What does **not** cross the socket in normal attach

- **PTY master fds.** Per the architectural invariant of
  `execplans/active/labpty-and-app-direct.md`, `labpty` is the sole
  steady-state reader and writer of every PTY master it opens. No
  client (`LabanApp`, future readers, diagnostic tool) receives a
  duplicated master fd in the response to `attachSession`. Two
  readers on the same PTY master split bytes non-deterministically;
  two writers interleave. The only safe shape is one custodian,
  and the protocol
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
(`LabanApp` parser + a couple of casting clients + a diagnostic tool
+ headroom) without wasting cache. A ninth `attachSession` returns
`attachLimitExceeded`. Sized as a frozen ABI constant so the
slot-table offset never moves; raising the cap is an `abi_minor`
event that adds slots beyond the existing eight.

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

One cache line of process-wide-per-session counters. Each counter is
u64, atomic, sampled by readers without locks. **No per-reader state
lives here.**

```
Offset  Name                            Phase  Notes
------  ------------------------------  -----  -------------------------
128     output_bytes_written_total      1      = output_write_offset
136     output_writes_total             2      reserved zero in Phase 1
144     output_wrap_count               1      writer increments on wrap
152     output_wake_notifications_total 2      reserved zero in Phase 1
160     producer_alive_mono_ns          1      labpty's heartbeat
168     reserved (padding to 192)
192     input_bytes_consumed_total      2      input ring; reserved zero
200     input_writes_blocked_total      2      reserved zero
208     master_read_calls_total         2      reserved zero
216     master_read_eagain_total        2      reserved zero
224     ring_overflow_observed_total    2      reader-incremented; zero
232     attached_consumer_count         2      Phase 1 labpty does not
                                               track readers; zero
240     last_attach_mono_ns             2      reserved zero
248     reserved (padding to 256)
```

Phase 1 `labpty` populates exactly three fields:
`output_bytes_written_total` (the write offset; the load-bearing
counter), `output_wrap_count` (incremented when the writer laps), and
`producer_alive_mono_ns` (one u64 store per event-loop tick capped at
100 ms cadence). The cold counters' offsets are pinned for Phase 2 so
adding them is a pure extension; until Phase 2 wires them they stay
zero.

`producer_alive_mono_ns` is the heartbeat. A reader that sees this
field stale by >300 ms can assume `labpty` is dead or hung and trigger
reconnect / escalation. Same primitive as a market-data
feed-staleness check.

Why no `output_read_total`: readers are multiple and lock-free; we
don't serialize their reads through a single counter. Each reader
maintains its own watermark in its own address space.

### Per-reader slot table (offset 256, 64 bytes × 8 = 512 bytes) — Phase 2

> **Phase 2 design.** Phase 1 `labpty` does not write to this region.
> Phase 1 readers do not read from it. The region exists at offset 256
> with 512 bytes of zeroed shm so that Phase 2's per-reader state lands
> at a frozen offset; without the reservation, adding it would shift
> the output ring offset and break ABI stability.
>
> The motivation for the per-reader table is the Phase 2 wake-pipe
> mechanism. Phase 1 readers poll the ring directly; there is no slot
> to claim, no wake-pending flag to manage, no consumer-alive
> heartbeat to update. Phase 2 introduces all three together when
> wake-pipe latency wins justify the surface.

Eight cache-line-aligned slots. In Phase 2, `labpty` would allocate a
slot at `attachSession` and clear it on detach. Each slot:

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

In Phase 2: `occupied` is the slot-claim CAS target. `wake_pending` is
the edge-triggered signal coalescer (see "Wakeup discipline (Phase
2)"): `labpty` sets it before writing the pipe; the reader clears it
after draining. The reader's pipe read-end fd lives outside this file
(the reader holds it; `labpty` holds the matched write-end fd received
via SCM_RIGHTS at attach time). `last_seen_offset` is **not** consulted
by the producer for correctness; the byte-ring's correctness depends
only on `output_write_offset`. The slot's `last_seen_offset` exists so
a diagnostic tool can sample which readers are lagging without
bothering `labpty`.

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
   continues forward from there. This is the fastest path for any
   reader that publishes its own snapshots on every render frame
   (`LabanApp` in Background mode is the planned default reader; the
   parser-as-publisher pattern works for any future client too).

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
`ring_overflow_observed_total` before resuming. `LabanApp` additionally
notes the overflow in its per-session lifecycle journal so post-mortem
analysis can correlate dropped output with frame rendering.

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

### Phase 1: readers poll

`labpty` does not signal readers. Readers (just `LabanApp` in
Background mode) poll the byte ring's `output_write_offset` on a
tick. Recommended starting interval is 4 ms (250 Hz); a slower tick
is acceptable for sessions whose output is dominated by human typing,
and the reader is free to vary the tick rate per session based on
its own render cadence.

This costs `labpty` zero code and zero per-reader state. The latency
penalty (mean 2 ms, worst case 4 ms before the reader notices new
bytes) is invisible inside `LabanApp`'s render-frame cadence (~16 ms
at 60 Hz). The headline acceptance (`LabanApp` restart preserves
children) does not depend on sub-millisecond reader wake.

Phase 2 may add wake pipes (next subsection) if measurements show the
polling tick produces user-visible lag.

### Phase 2: per-reader wake pipes

> **Phase 2 design.** Phase 1 `labpty` does not implement this
> section. Phase 1 readers do not pass wake pipes at attach.

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
  ancillary data on the (Phase 2) `attachSession` request — a pipe
  write fd, never a PTY master fd. Phase 1 has no SCM_RIGHTS anywhere;
  this section describes the Phase 2 design.
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

Length-prefixed binary frames (`LBPTY-CT-01`) over `SOCK_STREAM` Unix
sockets. The framing is identical in both directions and identical
for every op:

```c
// All fields little-endian. Total header size: 24 bytes.
// Field order matches the wire byte order exactly; the C struct is
// documentation, NOT a memcpy target — see "No struct memcpy" below.
struct labpty_frame_header_wire {
  uint8_t  magic[4];    // "LPCT" (0x4C 0x50 0x43 0x54); rejects garbage and
                        //   misdirected connections at the framing layer
  uint16_t abi_major;   // 1 in Phase 1; bump only for breaking changes
  uint16_t abi_minor;   // 0 in Phase 1; bump for additive changes
  uint32_t frame_len;   // total bytes including this header; ≤ MAX_FRAME (128 KiB)
  uint16_t op;          // request: labpty_op enum; response: 0xFFFF
  uint16_t code;        // request: 0; response: labpty_error_code enum (0 = ok)
  uint64_t seq;         // request: monotonic per client; response: echoes request seq
};
// followed by frame_len - 24 bytes of op-specific payload.
```

A receiver reads exactly 24 bytes, validates magic / `abi_major` /
`abi_minor ≥ this implementation's known minor` / `frame_len ≤ MAX_FRAME`
/ `frame_len ≥ 24`, then reads `frame_len - 24` payload bytes into a
preallocated scratch buffer. No additional state machine, no streaming
parser. The payload decode for each op is documented under "Operations"
below; every variable-length field is preceded by a `u32` length that
the decoder bounds-checks against the remaining frame budget.

### No struct memcpy

The `labpty_frame_header_wire` declaration above is **documentation of
the wire byte order**, not a C struct anyone reads as `*(struct
*)buf`. C struct padding/alignment varies across compilers, settings,
and ABI revisions; relying on the in-memory layout matching the wire
layout is exactly the class of bug that a thinness-disciplined daemon
must rule out at the design level. Every field is read individually
through bounds-checked primitive helpers:

```c
labpty_status_t labpty_read_u8 (const uint8_t **cur, const uint8_t *end, uint8_t  *out);
labpty_status_t labpty_read_u16(const uint8_t **cur, const uint8_t *end, uint16_t *out);
labpty_status_t labpty_read_u32(const uint8_t **cur, const uint8_t *end, uint32_t *out);
labpty_status_t labpty_read_u64(const uint8_t **cur, const uint8_t *end, uint64_t *out);
labpty_status_t labpty_read_bytes(const uint8_t **cur, const uint8_t *end, size_t n, const uint8_t **out);
```

Each helper checks `cur + sizeof(T) ≤ end`, advances `*cur` on
success, returns `LABPTY_E_TRUNCATED` on failure. Decoders compose
helpers; they never alias raw struct memory. The fuzz target
(`Tools/LabptyProtocolFuzz`) covers exactly these helpers and the
per-op composers built from them.

### Per-field bounds

Every variable-length field has a per-field cap enforced before any
allocation. Frame-level `MAX_FRAME` is the outer bound; the inner
caps are what each per-op decoder checks:

| Field | Cap | Notes |
| --- | --- | --- |
| Frame total | 128 KiB | `MAX_FRAME` constant |
| `argv_count` | 64 entries | Per `openSession`; real shells never approach this |
| Single `argv` entry | 4096 bytes | UTF-8 |
| `envp_count` | 256 entries | Pairs; macOS default envp is ~30 entries |
| Single `envp` key | 256 bytes | |
| Single `envp` value | 4096 bytes | |
| `cwd` | 4096 bytes | `PATH_MAX` on macOS is 1024 but allow generous slack |
| `logical_session_id` | 256 bytes | |
| `byte_ring_shm_path` | 1024 bytes | |
| `writeInput` bytes | 64 KiB | + frame header + pty_handle ≈ 64 KiB + 32 |
| `client_id` | 256 bytes | `hello` payload |
| `capabilities` per entry | 64 bytes | Tokens like `byte-ring/v1` |
| `capabilities` count | 64 entries | Both directions |
| `LabptySessionDescriptor` count in `listSessions` response | 64 | Matches the per-daemon session cap |

No foreground-process strings on the wire. `labpty` reports only
`foreground_pid` (`int32`) and `foreground_pgid` (`int32`) on every
descriptor — one `tcgetpgrp` + one `getpgid` per session per
catalog read. The client (`LabanApp` in Background mode) resolves
the rest (executable name, command path, argv, cwd) via
`proc_name`/`proc_pidpath`/`proc_pidinfo` against those pids. This
keeps `labpty` free of libproc string-extraction code, truncation
rules, and the descriptor-bloat that ~5 KiB of foreground strings ×
64 sessions would push into every `listSessions` response. The
client's tab-title path consumes the resolved strings unchanged;
the libproc call lives in `LabanApp` via the existing public Swift
facade `LibprocIntrospector`
(`Sources/LabanCore/Persistence/AgentSessionDetector.swift:547`),
which is pid-based. The C entry point in
`Sources/LabanTerminalCore/process_metadata.c` takes a
`LabanSession *` and stays the Detached-mode resolver; Background
mode uses the Swift facade.

Any decoder that observes a length-prefix exceeding the relevant cap
returns `LABPTY_E_OVERSIZE` and the connection closes.

### Pipelining

Phase 1 has no pipelining: a client sends one request and waits for
the response before sending the next. The frame header carries `seq`
so Phase 2+ can introduce pipelining without an ABI bump; until then
the daemon may process requests serially per connection and clients
match responses to requests by socket position.

**Why not JSON.** The original design picked JSON for the control
plane on ergonomics grounds. The C-implementation decision changed
that calculus: a JSON parser in C is the single most-exposed surface
in `labpty`, ~300 LoC at minimum, and a mandatory fuzz target. The
binary frame decoder is ~80 LoC, trivially fuzzable (one bounds check
per length-prefix against remaining frame bytes), and lets
`writeInput` carry raw bytes without a base64 hop. Human-readable
debugging is preserved through `Tools/LabptyDump`, a Swift CLI that
connects to a `labpty` socket and pretty-prints the captured frames —
~50 LoC, one-time cost, never on the hot path. The Decision Log
records the reversal explicitly.

### Common shape rules

- Every length prefix is a `u32` little-endian byte count, **never**
  a UTF-8 character count.
- Strings are UTF-8, not null-terminated; the `u32` length includes
  exactly the byte count.
- The `pty_handle` is a `u64` assigned monotonically by `labpty` at
  `openSession` time. It is opaque to clients and unique within the
  daemon's lifetime. No string handles, no UUIDs — a 64-bit counter
  fits the only requirement (uniqueness across active sessions) and
  saves 56 bytes per RPC over the earlier 64-byte string design.
- `u32`/`u64` integers are little-endian (Apple Silicon native; the
  doc commits to little-endian as the only supported byte order).
- Booleans are `u8` (0 or 1; any other value is `internalError`).
- Counts (`argv_count`, `envp_count`) are `u32`. Each fits trivially
  in 32 bits; capping is enforced by the per-frame `MAX_FRAME`
  budget plus per-op sanity limits (e.g., argv ≤ 4096 entries).
- The receiver always validates: `sum(known fields) ≤ frame_len - 24`
  (24 being the fixed header bytes). Any field whose length-prefix
  would push the cursor past the frame body returns
  `LABPTY_E_TRUNCATED` and the connection closes.
- `argv` and `envp` are **counted arrays of length-prefixed strings**,
  not flat NUL-separated buffers. Each entry's bytes are exactly its
  declared length, no NUL scanning required. `labpty` walks the
  array once at decode, validating each entry against its
  per-field cap, NUL-terminates each entry in place, and assembles
  a `char *const argv[]` and `char *const envp[]` pointing into a
  **daemon-lifetime `mmap`'d scratch arena**.

  The arena is allocated once at `labpty` startup:

  ```c
  // 2 MiB; demand-paged so RSS stays at the largest openSession used.
  arena = mmap(NULL, OPENSESSION_ARENA_BYTES,
               PROT_READ | PROT_WRITE,
               MAP_ANON | MAP_PRIVATE, -1, 0);
  ```

  Per RPC, the dispatcher resets the cursor to 0, decodes the
  argv/envp/cwd into the arena (bounds-checked at each step against
  remaining arena bytes), calls `openpty` + `fork`, and waits on a
  self-pipe for the child to signal "execve started" (one byte
  written by the child immediately before `execve`). The wait
  bounds the next dispatcher invocation: the arena cannot be
  overwritten while the child is still reading from it. The wait
  cap is 100 ms; on timeout the dispatcher returns
  `LABPTY_E_PTY_OPEN_FAILED` and kills the still-forked child.

  This pattern earns its place against the verification bar:

  - One allocation in `labpty`'s lifetime (at boot), zero per RPC.
  - The arena pointer is constant; no allocator state churns.
  - The serialization is structural (single-threaded daemon + wait
    for child confirmation), not a lock.
  - `MAX_FRAME` plus the per-field caps below bound the arena's
    worst-case use to ~1.4 MiB; the 2 MiB reservation is twice
    headroom.

  Per-field caps for `openSession`:

  | Field | Cap |
  | --- | --- |
  | `argv_count` | 64 entries |
  | Single `argv` entry | 4096 bytes |
  | `envp_count` | 256 entries |
  | Single `envp` key | 256 bytes |
  | Single `envp` value | 4096 bytes |
  | `cwd` | 4096 bytes |
  | `logical_session_id` | 256 bytes |

  Worst-case arena consumption: 64 × 4096 (argv) + 256 × (256 +
  4096) (envp) + 4096 (cwd) + 256 (logical_session_id) + pointer
  tables ≈ 1.4 MiB. Comfortable headroom under the 2 MiB
  reservation.

  If a decoded `openSession` exceeds the arena (because some
  combination of fields plus pointer tables crosses the
  reservation), the dispatcher returns `LABPTY_E_OVERSIZE`. The
  client retries with smaller inputs; no real shell launch has
  ever produced an argv near these caps.

### Versioning, sequence numbers, deadlines

- **Version negotiation happens at `hello`, never per message**
  (principle 6). The `hello` request payload carries the client's
  proposed `protocol_major` and `protocol_minor`; the successful
  `hello` response pins those for the connection lifetime. The
  frame header *does* carry `abi_major` + `abi_minor` on every
  frame, but as **identification, not negotiation**: a stray
  packet, a misdirected connection, or a frame from a wrong-version
  peer is rejected at the framing layer. The version chosen for the
  connection is the one in the `hello` exchange; subsequent frames
  must carry that same `abi_major` (mismatch closes the connection).
- **`seq` is in the frame header** for every request and response. The
  client picks a monotonic u64; the daemon echoes. Phase 1 does not
  pipeline (one outstanding RPC at a time per connection), but the
  field is there so Phase 2+ pipelining costs nothing on the wire.
- **No `deadline_ns` field anywhere in Phase 1.** The closed binary
  schema has no slot for one and no provision for trailing optional
  fields; "clients may include it and labpty ignores it" is not a
  meaningful contract in a fixed-shape protocol. Clients enforce
  deadlines client-side by closing the socket. The wire gains a
  `deadline_ns` field only when `deadline-enforcement/v1` lands in
  Phase 2 — at which point the frame header takes an ABI minor
  bump.

### Response shape

A response is a frame with `op = 0xFFFF` and `code` set to the
appropriate `labpty_error_code`. The payload, when present, is
op-specific (e.g., a `listSessions` response carries the session
descriptor list).

### Response schema

A response is a frame whose header sets `op = 0xFFFF` and `code` to a
`labpty_error_code` (0 = ok, others = enumerated errors). The payload
bytes are op-specific; ok responses carry the result struct (e.g.,
`LabptySessionDescriptor` for `openSession`), error responses carry no
payload (the error code is sufficient — there is no free-form
`message` string on the wire, because every byte of decoder code is
under the verification bar and "free-form string" multiplies the
state space without earning anything).

### Operations

`hello` — version and capability negotiation. Must be the first
message on the socket. After the response, the connection is pinned to
the agreed version and capabilities.

`openSession` — fork+exec a child with a fresh PTY. Returns a session
descriptor with `ptyHandle`, `childPid`, `byteRingPath`,
`outputRingCapacity`, `inputRingCapacity`. Payload includes argv, envp
overrides, cwd, initial rows/cols, optional `logicalSessionId` (caller's
preferred identifier; collisions return `sessionIdInUse`).

`attachSession` — **Phase 2.** Registers a wake pipe and (in a later
Phase) claims a per-reader slot in the per-reader slot table. Phase 1
does not have this RPC: readers learn the byte-ring shm path from the
descriptors returned by `listSessions` (or by `openSession` for the
creator) and read directly. Phase 1 `labpty` does not track who is
reading; principle 0 says state we don't need belongs in the client,
not `labpty`. In every Phase, `attachSession` **does not send a PTY master
fd to the caller**; the master stays with `labpty` and readers consume
bytes through the shared-memory ring.

`writeInput` — write a chunk of input bytes to the session's PTY
master. Payload (after the 24-byte frame header):

```
u64 pty_handle        // assigned by labpty at openSession
u8  bytes[frame_len - 24 (header) - 8 (pty_handle)]
                      // raw input bytes; no encoding.
                      // Length is implicit from frame_len; no inner length-prefix.
                      // Capped at 64 KiB by the per-op decoder.
```

In Phase 1 this is the sole input mechanism. `labpty` performs the
`write(2)` to the master under its own lock, ensuring no interleaving
across concurrent callers. Phase 1's writer is `LabanApp` (one writer
per session by construction); multi-writer arbitration is not a Phase
1 concern. Saving the inner length-prefix and switching `pty_handle`
from a 64-byte string to a `u64` reduces the per-keystroke overhead
from ~100 bytes (JSON-with-base64) to 32 bytes (header + pty_handle).

`listSessions` — returns all known sessions with their descriptors and
current alive/dead status. Bounded response size (max 1024 sessions per
list); larger catalogs paginate by `cursor` token.

`resizeSession` — `TIOCSWINSZ` on the master. Updates `rows`/`cols` in
the session descriptor and atomically in the counters block.

`signalSession` — sends a signal to the child's process group via
`killpg`. Useful for `SIGINT` / `SIGKILL`.

`terminateSession` — graceful shutdown: send `SIGHUP` to pgrp, wait up
200 ms (hard-coded; not client-configurable in Phase 1), then
`SIGKILL`. Closes the master, frees the ring. Catalog entry is marked
dead but retained for one generation for forensic queries. The
trimmed `terminateSession` payload is just `u64 pty_handle` — no
grace-period field. Configurable grace would add a u32 plus the
decode/clamp logic; the verification bar makes its absence worth
more than its presence.

`publishOpaqueSnapshot` — **Phase 2.** Stores an opaque blob (the most
recent parsed snapshot the active client emitted) in the snapshot-cache
shm region. `labpty` never parses it. A fresh attach can read it for
instant display before catching up via byte-ring replay. Phase 1's
overflow recovery uses the unconditional in-ring replay strategy (see
"Overflow recovery"); the snapshot cache only optimizes the latency
of that recovery for the common parser-as-reader case (e.g.,
`LabanApp` in Background mode), so it's optional and gated on the
`opaque-snapshot-cache/v1` capability.

`ping` — control-plane heartbeat. Returns daemon mono ns. Used by
control-channel clients that don't have the shm counters mapped (e.g.,
diagnostic tools); also serves as the connection liveness check when
the shm-based heartbeat is not available.

### Error codes

Enumerated `u16` values; the wire's `code` field carries the raw
value. No new codes added without an ABI minor bump.

```
ok                       0x0000  // not an error; present on ok responses
sessionNotFound          0x0001
sessionIdInUse           0x0002
ptyOpenFailed            0x0003
ringMapFailed            0x0004
capabilityRequired       0x0005
versionMismatch          0x0006
permissionDenied         0x0007
payloadTooLarge          0x0008
truncatedFrame           0x0009
oversizeFrame            0x000A
internalError            0x000B  // bug; the daemon logs the detail
shuttingDown             0x000C
// deadlineExceeded reserved for Phase 2 deadline-enforcement
```

**No diagnostic message is carried on the wire**, in any response. An
earlier draft of this doc said `internalError` would include a
"stack-trace-y" string; that contradicted the principle "every byte
of decoder code earns its place." Free-form string fields are exactly
what the verification bar argues against: open input shape, variable
length, only present on some responses, requires a length-prefix
decoder that must be fuzz-covered. The clean alternative is what
`labpty` does: on `internalError`, the daemon writes the detail to
its log (stderr in dev, syslog/console in production via a Phase 2
log routing decision) and the client gets only the code. The code is
sufficient for the client's recovery logic; the human investigator
reads the daemon log.

## Capability negotiation

Capabilities are short string tokens with explicit versions. Both sides
exchange their supported set at `hello`; the effective set is the
intersection.

Capabilities shipped in Phase 1 (deliberately small, per principle 0):

```
byte-ring/v1                  // output ring with the layout in this doc
write-input-rpc/v1            // writeInput control RPC, raw bytes in frame
heartbeat-shm/v1              // producer_alive_mono_ns in counters block
session-id-pinning/v1         // accepts client-supplied logicalSessionId
```

Reserved for later phases (deliberately **not** Phase 1; each requires
its own justification against principle 0 when promoted):

```
wake-pipe-scm/v1              // pipe write-end via SCM_RIGHTS at attach.
                              // Phase 2; only when polling tick proves
                              //   to be a perceptible latency source.

opaque-snapshot-cache/v1      // publishOpaqueSnapshot + cache region.
                              // Phase 2; speeds overflow recovery for
                              //   parser-as-reader (LabanApp). The
                              //   Phase 1 "replay from current
                              //   window" path works without it.

input-ring/v1                 // SPSC input ring + pipe wake.
                              // Phase 2; requires
                              //   multi-attach-write-lease/v1.

multi-attach-write-lease/v1   // labpty-level write lease primitive.
                              // Phase 2; prerequisite for input-ring/v1.

metadata-ring/v1              // per-read latency tags for post-mortems.
                              // Phase 2; layout already reserves slots.

deadline-enforcement/v1       // labpty checks request deadline_ns.
                              // Phase 2 if measurement shows a hung
                              //   labpty actually completes work past
                              //   the client's give-up window often
                              //   enough to matter; Phase 1 ignores.

fd-handoff/v1                 // labpty self-upgrade: PTY master fds
                              // pass between old and new labpty via
                              // SCM_RIGHTS, never to a client.
                              // Phase 3.

shared-snapshot-ring/v1       // bridge to the existing LBNDSS01 ring
                              // if it ever has a labpty-side consumer.
                              // Indefinite; speculative.
```

Any capability not in the negotiated intersection is treated as missing;
clients fall back gracefully. Phase 1 fallbacks:

- For `input-ring/v1` → `write-input-rpc/v1`.
- For `opaque-snapshot-cache/v1` → in-ring "replay from current window"
  (see "Overflow recovery").
- For `wake-pipe-scm/v1` → 4 ms polling tick on `output_write_offset`.
- For `deadline-enforcement/v1` → client-side socket timeout / teardown.

Two capabilities that earlier drafts of this document listed in Phase 1
were removed deliberately:

- `scm-rights-attach/v1` (the old "master fd via SCM_RIGHTS in
  attachSession"). Removed for the architectural reason in
  `execplans/active/labpty-and-app-direct.md`: `labpty` is the sole
  steady-state reader/writer of every PTY master. The wake-pipe SCM_RIGHTS
  use was the only remaining justification for SCM_RIGHTS in Phase 1;
  with polling replacing wake pipes, Phase 1 has no SCM_RIGHTS at all.
- `input-ring/v1` as a Phase 1 capability. Direct shared-memory input
  has no safe semantics without an arbitrating write-lease primitive
  on the labpty side, and that primitive is its own design problem.

## Heartbeat and liveness

**labpty → readers:** `producer_alive_mono_ns` in the counters block,
updated at 100 ms cadence from labpty's main event loop. Readers check
on each poll tick (~free, just a u64 load). Stale by >300 ms ⇒ labpty
hung; the reader emits a diagnostic and reconnects. This is Phase 1.

**Readers → labpty:** Phase 2 design only. Phase 1 `labpty` does not
track readers; it has no reader-staleness sweep, no per-reader
heartbeat slot, no detach-on-stale behavior. The PTY master stays
open and bytes keep draining into the ring regardless of whether
readers are consuming them. If readers stop reading, the ring
eventually wraps and the readers' next poll observes the overflow —
the overflow-recovery section handles that without `labpty` needing to
know readers exist.

This asymmetry is a deliberate consequence of principle 0: readers can
notice labpty stalls cheaply (one u64 load per poll tick), but labpty
noticing reader stalls would require state and code that earn nothing
for Phase 1's headline acceptance.

## Timeouts and deadlines

Phase 1 `labpty` does **not** enforce deadlines. Clients may include
`deadline_ns` in a request envelope; `labpty` ignores it. The client
enforces its own deadline by closing the socket if the daemon hasn't
responded by then.

The numbers below are *client-side* deadline guidance — what a
well-behaved client should pick for its own socket timeout. They do
not appear in `labpty`'s code in Phase 1.

| Operation | Client-side guidance | Notes |
| --- | --- | --- |
| `hello` | 1000 ms | First contact; OS scheduling jitter dominates |
| `openSession` | 500 ms | fork+exec is the bottleneck |
| `listSessions` | 50 ms | All in-memory |
| `resizeSession` | 50 ms |  |
| `signalSession` | 50 ms |  |
| `terminateSession` | 400 ms | 200 ms grace + 200 ms reap budget; grace is daemon-fixed in Phase 1 |
| `writeInput` | 100 ms | Master `write(2)` may block briefly under back-pressure |
| `ping` | 50 ms |  |
| Reader observes new `output_write_offset` after byte arrival | ≤ poll tick (4 ms recommended) | Phase 1 polling cadence; Phase 2 may add wake pipes |

Phase 2 may promote `deadline-enforcement/v1` if measurement shows
`labpty` actually completes work past the client's give-up window
often enough to matter. Until then, ignoring deadlines saves one
`clock_gettime` syscall per RPC and removes a code path that has to
be tested.

## Backpressure

**Output direction (Phase 1):** None at the kernel level. labpty
drains the master as fast as it can. If readers fall behind and the
ring wraps, the bytes they missed are lost from their perspective;
they recover via the in-ring "replay from current window" path in
"Overflow recovery." Phase 2's `opaque-snapshot-cache/v1` adds a
faster recovery path; Phase 1 has only the in-ring fallback. The
byte ring is sized generously enough (8 MiB default) that wraps
shouldn't happen in practice.

**Input direction (Phase 1):** The `writeInput` control RPC is
synchronous from the caller's perspective: `labpty` performs the
`write(2)` to the PTY master under its own lock before responding
ok. If the kernel buffer is full, `labpty`'s `write(2)` blocks
briefly; the caller experiences this as a longer RPC. There is no
shared-memory input ring in Phase 1, no `input_writes_blocked_total`
counter populated, and no async backpressure signal — bounded only
by the caller's own willingness to keep sending RPCs.

**Input direction (Phase 2):** Bounded by the `LBPTY-IR-01` input
ring's capacity. If the kernel buffer for the PTY master write
blocks, `labpty` stops draining the input ring; the client sees
`input_writes_blocked_total` incrementing and applies its own
pacing. This is the algo-trader rate-limit model: tell the producer
to slow down rather than letting buffers grow without bound. Lands
only after `multi-attach-write-lease/v1` is settled.

**Shutdown:** `terminateSession` is a producer drain operation.
`labpty` keeps draining the PTY master into the byte ring while
killing the child gracefully, so any final output (exit codes, last
line of output) reaches attached readers before the ring is freed.

## Observability

Phase 1: the three per-session counters in the byte-ring shm header
(`output_bytes_written_total`, `output_wrap_count`,
`producer_alive_mono_ns`) plus the binary-frame responses to
`listSessions` and `ping` cover everything needed to answer "is this
daemon healthy and are bytes moving for each session." Debugging
proceeds by reading the ring header(s) and calling `listSessions` /
`ping` via `Tools/LabptyDump` (the human-readable shim that connects
to a `labpty` socket, sends a frame, and pretty-prints the response).

Phase 2 adds a daemon-global counters block at a well-known shm path:

```
labpty_daemon_counters/{run_id}                          Phase 2
+---------+-------------------------------+
| u64     | sessions_opened_total         |
| u64     | sessions_terminated_total     |
| u64     | rpc_calls_total               |
| u64     | rpc_errors_total              |
| u64     | uptime_mono_ns                |
| ...     |                               |
+---------+-------------------------------+
```

This is what richer monitoring scrapes every 10 seconds once the
daemon has earned that surface; until then, the per-session counters
plus the control-plane responses suffice for the headline use case
(`LabanApp` restart preserves children).

Diagnostic dumps (full session catalog, recent error log) are
accessed via `listSessions` and structured logs. Heavyweight dump
operations are deferred until they earn a place against principle 0.

## Execution model

Single-threaded event loop per `labpty` process. Phase 1 surface is
deliberately spare. One kqueue (macOS) watches:

- All PTY master fds (one per session), `EVFILT_READ`.
- All client control sockets, `EVFILT_READ` (for inbound RPCs).
- A self-pipe for control-plane shutdown signaling, `EVFILT_READ`.

There are no outbound reader-wake writes in Phase 1; readers poll the
byte ring. There is no input-ring drain in Phase 1; input arrives via
the `writeInput` control RPC and is written to the master inline.

Phase 2 additions to the event loop, when they land, are:

- Outbound non-blocking writes to per-reader wake pipes after each ring
  publish (gated on `wake-pipe-scm/v1`).
- `EVFILT_READ` registration on each input ring's wake pipe (gated on
  `input-ring/v1` plus `multi-attach-write-lease/v1`).

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

## Coding rules for `labpty`

`labpty` is operationally a soft-realtime, kernel-adjacent C daemon
with long-running stakes (its bugs cost user terminal sessions
between Phase 1 ship and Phase 3 fd-handoff). It is **not**
safety-critical in the avionics / automotive sense, so DO-178C
traceability, MC/DC coverage, and tool qualification are explicitly
out of scope (see "Deliberately out of scope" below). What `labpty`
*does* borrow from the safety-critical playbook is the subset that
delivers small, predictable, audit-friendly code at single-digit
percent of the certification cost.

The canonical reference is NASA JPL's *Power of Ten* (Gerard
Holzmann's ten rules for safety-critical C). Each rule is mapped
below to its enforcement mechanism in `labpty`.

### Power of Ten compliance

| Rule | Status | Enforcement |
| --- | --- | --- |
| 1. Restrict control flow to very simple constructs. No `goto`, `setjmp`, `longjmp`, recursion. | **Enforced** | Review Gate greps in `Sources/Labpty/`: `\bgoto\b`, `setjmp`, `longjmp` return zero hits. Recursion is checked by a CI script that finds direct or single-hop self-calls in the labpty source. |
| 2. Give all loops a fixed upper bound, checkable by a static analyzer. | **Enforced** | Frame decoder reads exactly `frame_len` bytes; ring writer is one memcpy with at most one wrap-split; registry hash table walks a fixed-size open-addressing table; dispatch is a switch on a closed enum. clang static analyzer flags any loop whose upper bound isn't an integer constant or a previously-validated input field. |
| 3. Do not use dynamic memory allocation after initialization. | **Enforced** | One `mmap` at boot for the openSession scratch arena. Per-session byte-ring shm files created at `openSession`, destroyed at `terminateSession`. **No `malloc`/`calloc`/`realloc` calls in the hot path.** Review Gate grep: `git grep -nE '\b(malloc\|calloc\|realloc)\(' Sources/Labpty/` returns zero hits, or every hit is in a session-lifecycle (open/terminate) path explicitly labeled as such. |
| 4. No function longer than 60 lines of code (a single printable page). | **Enforced** | Review Gate CI step: a small AWK script over `Sources/Labpty/*.c` counts lines per function (between matching braces), flags any function > 60 lines. Exceptions documented inline with a `// LABPTY: long-function-allowed: <reason>` marker. |
| 5. Average ≥ 2 assertions per function. | **Enforced** | Assertions are bounded checks of "this cannot happen by construction": precondition assertions on inputs the caller is supposed to have validated, postcondition assertions on outputs other functions will rely on, invariant assertions on data structures. Built with `NDEBUG` *off* in dev and CI. The Review Gate CI step counts `assert(` lines and function definitions; ratio must be ≥ 2. |
| 6. Restrict the scope of data to the smallest possible. | **Enforced** | No `extern` globals outside the daemon-lifetime singletons (the scratch arena pointer, the session registry, the global counters block). File-static helpers preferred over header-visible exports. Reviewed at PR time. |
| 7. Check the return value of all non-void functions. | **Enforced** | clang static analyzer's `core.uninitialized.UndefReturn` plus `-Wunused-result` catches missed returns. Helper functions that return error codes are marked `__attribute__((warn_unused_result))`. |
| 8. Limit preprocessor use to header guards and simple constants. | **Enforced** | No `#define` for code. Constants use `static const`. Opcodes are an `enum`, not `#define`. Conditional compilation is allowed only for platform-detection (`__APPLE__`) at the top of files. Reviewed at PR time. |
| 9. Restrict pointer use. No more than one level of dereference. Function pointers banned except in the request dispatch table. | **Enforced** | Review Gate grep: `git grep -nE '\([^)]*\*[^)]*\*[^)]*\)' Sources/Labpty/` finds suspicious `**` declarations (with manual triage). Function pointers banned except inside `labpty_dispatch_table[]`, an array of (`op`, `handler`) tuples that is the only function-pointer-typed value in the codebase. |
| 10. Compile with all warnings; check the code daily with a static analyzer. | **Enforced** | `swift build` of the labpty C target uses `-Wall -Wextra -Wpedantic -Werror`. CI runs `clang --analyze` over `Sources/Labpty/*.c` on every PR and fails on any new finding. This is the *floor*, not aspirational — the verification ladder (CBMC, Frama-C, differential Swift/C decoder) adds layers above. |

### Additional rules beyond Power of Ten

These cover realtime / operational concerns the Power of Ten doesn't
specifically address but matter for `labpty`'s actual classification
as a long-running soft-realtime daemon:

- **`mlockall(MCL_CURRENT | MCL_FUTURE)` at boot.** Prevents the
  scratch arena, the per-session byte rings, and the labpty code
  pages from being swapped or paged out. One syscall at startup;
  removes a category of tail-latency surprises (major faults on
  hot-path memory) that principle 2 says we're trying to avoid.

- **Pre-touch the scratch arena.** After `mmap`, `memset(arena, 0,
  ARENA_BYTES)` once at boot. Demand-paged pages would otherwise
  fault on first use during the first `openSession`, producing a
  visible latency cliff. The pre-touch makes the worst-case latency
  of the first `openSession` equal to that of the hundredth.

- **Validate inputs even from trusted sources.** Same-uid peer
  credential authorization is necessary but not sufficient: a
  malicious or buggy client (`LabanApp`, or any future labpty
  client) could send malformed frames. Every byte received over the
  control socket is treated as untrusted; the bounded decoders run
  before any state mutation. The same applies to any future
  `labpty`-side reading of the byte ring (Phase 1 doesn't read its
  own ring, but Phase 3 fd-handoff might).

- **External liveness supervision.** Phase 3 task: a sibling
  supervisor (`launchd` `KeepAlive`, or a dedicated watchdog
  process) restarts `labpty` if it stops responding to `ping` for
  >5 seconds. Phase 1 can defer this — `LabanApp`'s next user-action
  timeout will surface a hung labpty within ~10 seconds — but it
  is explicitly listed here so a future contributor doesn't
  rediscover the gap.

- **Coding rules CI step.** A single CI job runs the Power of Ten
  grep checks plus the function-length and assertion-density
  counters. Reports per-file deviations. Gates the build on first
  pass; subsequent enforcement strictness is iterative.

### Deliberately out of scope

These conventions are standard in genuinely safety-critical code
but are excessive for `labpty`'s operational stakes. They are
listed so a future reviewer doesn't conclude they were forgotten:

- **DO-178C traceability matrix** (requirements ↔ code ↔ tests).
  Certification-grade overhead; no certifying authority is
  involved.
- **MC/DC coverage gate.** Branch coverage at ~90% (via
  `llvm-cov` over the labpty C target) is sufficient for
  `labpty`'s scope; MC/DC is for control flow where a single
  condition's flip can cost lives, not for a custodian daemon.
- **Tool qualification** for CBMC / Frama-C / clang static
  analyzer. Their results are used as evidence in code review,
  not as certified-correct proofs.
- **CRC on shm data.** ECC RAM covers most silent corruption; the
  byte ring is in-process memory between `labpty` and `LabanApp` on
  the same machine, not a hostile boundary. Magic + ABI version on
  the file header is the wire-level integrity check.
- **Hard-realtime scheduling primitives.** macOS's
  `THREAD_TIME_CONSTRAINT_POLICY` is for sub-millisecond audio
  pipelines; `labpty`'s latency budget is ~10 ms user-perceptible,
  not deadline-driven.
- **Full WCET analysis** (aiT, OTAWA). The histogram-vs-baseline
  mechanism in the Validation strategy is the operational
  approximation; an upper-bound proof would be excessive.
- **`SCHED_FIFO` priority** (Linux). Same reasoning as above; not
  available on macOS in the Linux sense anyway.

## Sequence diagrams

### Steady-state output flow (Phase 1: polling)

```
PTY master           labpty event loop          ring                consumer
   |                       |                     |                     |
   |---bytes ready (kqueue)|                     |                     |
   |                       |--read(buf, 16KiB)-->|                     |
   |<-- bytes copied ------|                     |                     |
   |                       |--memcpy to ring---->|                     |
   |                       |--release store wo-->|                     |
   |                       |                     |                     |
   |                       |  (no signal sent;   |                     |
   |                       |   reader polls)     |                     |
   |                       |                     |  ...(≤ poll tick)...|
   |                       |                     |                     |--poll tick (4 ms)
   |                       |                     |                     |--acquire load wo
   |                       |                     |                     |--memcpy out
   |                       |                     |                     |--update reader's
   |                       |                     |                     |  own last_seen_offset
```

**Design budgets**:

- Mean wake latency: 2 ms (half the 4 ms poll tick), p99: 4 ms +
  scheduler jitter.
- Once the reader has bytes, the `memcpy` cost is sub-microsecond.

These are deliberately above the wake-pipe budget Phase 2 would buy.
The Phase 1 budget is "imperceptible inside `LabanApp`'s ~16 ms
render-frame cadence"; sub-millisecond wake is a Phase 2 concern.

### Steady-state output flow (Phase 2: wake pipes)

Documented under "Wakeup discipline (Phase 2)" above. The sequence
diagram from earlier drafts of this document (with
`write(wake_pipe, 1)` and `read(wake_pipe)`) describes that Phase 2
flow. Phase 1 implementers should ignore it.

### `openSession` / `listSessions` sequence

```
client                                          labpty
  |---openSession(argv, envp, cwd, rows, cols)---->|
  |                                                |--openpty + fork + exec
  |                                                |  (ADR 0002 invariants)
  |                                                |--create byte-ring shm file
  |                                                |--write file header
  |                                                |--register master fd with
  |                                                |  own kqueue
  |                                                |--insert into in-memory
  |                                                |  session catalog
  |<--openSession response w/ ptyHandle,---------|
  |   child_pid, rows, cols, byte-ring shm path,
  |   foreground_pid, foreground_pgid.
  |   NO foreground-process strings (client resolves).
  |   NO master fd. NO SCM_RIGHTS.
  |---open(byteRingPath, O_RDONLY, mmap)
  |---validate header (magic, abi_major, capacity)
  |---store last_seen_offset = current_write_offset
  |---read producer_alive_mono_ns; verify fresh
  |---ready

A laband-as-client coming up after a restart uses:
  |---listSessions------------------------------->|
  |<--list of descriptors-------------------------|
  |   (same fields as openSession; one per live
  |    session known to labpty)
  |---for each: open(byteRingPath), validate, ready
```

**Design budgets** (Phase 1; advisory, not gating):

- `openSession`: ~200 µs (fork+exec dominates).
- `listSessions`: <1 ms for ~100 sessions.
- `mmap` open on a Phase 1 file: ~50 µs.

Reads of the byte ring after attach are pure shm; no syscall per byte.

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
behavior). Phase 1 only — Phase 2 adds more as it lands:

| Invariant | Test |
| --- | --- |
| Power-of-two output capacity enforced | `testRingCapacityMustBePowerOfTwo` |
| Header magic and abi version checked on open | `testReaderRejectsBadMagic` |
| Reader-slot table region exists at offset 256 with 512 zero bytes (reserved for Phase 2) | `testReaderSlotTableReservedZero` |
| Producer alive heartbeat advances ≥ 50 ms in 150 ms | `testProducerAliveIncrements` |
| Consumer detects wrap and recovers per "Overflow recovery" | `testConsumerDetectsRingWrap` |
| `output_wrap_count` increments on writer lap | `testWrapCountIncrements` |
| Sequence number echo | `testSequenceNumberEcho` |
| **No RPC returns a master fd or any other PTY fd** | `testNoRpcReturnsMasterFd` |
| **No RPC returns or accepts any SCM_RIGHTS ancillary data in Phase 1** | `testPhase1HasNoScmRights` |
| `listSessions` returns the byte-ring shm path for every live session | `testListSessionsCarriesByteRingPath` |
| Cross-uid connect fails with `permissionDenied` | `testConnectRejectsCrossUid` |
| Frame magic `"LPCT"` checked on every frame; mismatch closes connection | `testFrameMagicRequired` |
| `abi_major` mismatch closes connection; `abi_minor` newer-than-implementation accepted | `testAbiMajorRejectsMismatch`, `testAbiMinorTolerant` |
| Frame `op = 0xFFFF` rejected when sent from client (response code only) | `testClientCannotSendResponseOp` |
| Version pinned at `hello`; subsequent requests carry no version slot | `testVersionPinnedAtHello` |
| No deadline field in the Phase 1 frame header (no place to send one) | `testFrameHeaderHasNoDeadlineSlot` |
| Frame decoder rejects `frame_len > MAX_FRAME` without read-past-buffer | `testFrameDecoderRejectsOversizeFrame` |
| Frame decoder rejects truncated payloads (length-prefix exceeds remaining frame budget) | `testFrameDecoderRejectsTruncatedPayload` |
| Frame decoder is closed under fuzz: arbitrary bytes never crash or read past buffer | `testFrameDecoderFuzz` (libFuzzer corpus harness; the primary fuzz target) |
| `pty_handle` is a `u64`; no string handle types reachable | `testPtyHandleIsU64` (grep + decode test) |
| `argv`/`envp` counted-array decoder rejects entry exceeding per-field cap | `testArgvRejectsOversize`, `testEnvpRejectsOversize` |
| `writeInput` payload size derived from `frame_len`; no inner length prefix | `testWriteInputPayloadFromFrameLen` |
| `terminateSession` payload is exactly 8 bytes after the header | `testTerminatePayloadShape` |
| Every per-op decoder rejects bytes that would alias the in-memory C struct layout (no `memcpy(&hdr, buf, 24)` regression) | `testNoStructMemcpyRegression` (`git grep -nE 'memcpy\(.*&.*,.*frame'` returns zero hits in `Sources/Labpty/`) |
| `attachSession` op is **not** registered in Phase 1 (or returns `versionMismatch`) | `testAttachSessionUnimplementedInPhase1` |
| Hot-path allocation profile is bounded | `testHotPathAllocationCount` (sample-mode) |
| `labpty` restart kills children (Phase 3 will lift this) | `testLabptyExitClosesMaster` |
| `LabanApp` restart preserves children | `testLabanAppRestartPreservesChildViaLabpty` (in `Tests/LabanAppTests/`) |
| `LabptySessionDescriptor` carries `foreground_pid` + `foreground_pgid` (`int32` each, -1 = unknown) and **no foreground-process strings** | `testDescriptorCarriesForegroundPids`, `testDescriptorHasNoForegroundStrings` |
| `labpty` does not link libproc, does not call `proc_name`/`proc_pidpath`/`proc_pidinfo` | `git grep -nE 'proc_name\|proc_pidpath\|proc_pidinfo\|libproc' Sources/Labpty/` returns zero hits |
| `labpty` does not write to per-reader slot table region in Phase 1 (region stays zero through normal operation) | `testReaderSlotTableStaysZeroInPhase1` |

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

**Verification ladder.** Beyond property tests and the frame-decoder
fuzzer, the verification bar in architectural invariant #7 of
`execplans/active/labpty-and-app-direct.md` admits stronger tools as
they become useful:

- **Phase 1 floor:** property tests + libFuzzer on the frame
  decoder. The base level every patch to `labpty` must satisfy.
- **Aspirational rung 1: CBMC.** Bounded model checking on the
  frame decoder, byte-ring writer arithmetic, and session-registry
  hash table. CBMC unrolls loops and proves bounds across the
  unrolled depth; for our bounded-input code (every loop's bound
  is a wire-supplied length or a compile-time constant), the
  unroll depth is finite and the proof is realistic. Worth one
  spike to evaluate; not a Phase 1 acceptance gate.
- **Aspirational rung 2: Frama-C / ACSL annotations.** Inline
  contracts on the helper primitives (`labpty_read_u32` and
  friends) that a static analyzer checks. Useful if the codebase
  has more than ~1000 lines of C in `labpty`; Phase 1 should land
  closer to 500 lines, at which point the eyeball is competitive.
- **Aspirational rung 3: differential property testing across the
  Swift and C decoders.** Generate a random valid frame; encode it
  via the Swift `LabptyFraming` encoder; decode it via the C
  `labpty_frame.c` decoder (and the inverse direction). Identity
  must hold. Catches drift between the two implementations the
  binary protocol leaves split across language boundaries.

The ladder is documented here so a future maintainer who wants to
strengthen the bar has a concrete next rung to climb, not a vague
"add more tests."

## Open questions

Defer to implementation experience:

- **Counters block alignment under macOS shared memory.** Ensure
  64-byte alignment by `shm_open` + `ftruncate` + `mmap` of an
  appropriately rounded size, with the header pinned at offset 0.
- **Multi-reader per-reader slot table size for Phase 2.** The
  `consumer_alive_mono_ns` slots: 8 preallocated is the current
  proposal; a 9th attach returns `attachLimitExceeded`. Verify
  the cap against early multi-attach use cases before Phase 2 ships.

Resolved-but-listed-for-future-readers (do not treat as open):

- **Endianness:** little-endian. Settled at principle 12 / "Common
  shape rules"; macOS is the only target.
- **Snapshot cache size:** Phase 2 ships one blob per session.
  Phase 3 may revisit with a ring of last N blobs for forensic
  diagnostics. Not Phase 1.

## Why this is worth the discipline

The naive design — Swift-shaped daemon with one socket per session,
allocate per message, no heartbeat, no counters, JSON on every hop —
would work. It would also produce a daemon whose tail latency is
dominated by ARC, parse spikes on open-shape input, and unbounded
buffer growth under load. It would be *indistinguishable from working*
until a user's busy build session saturated the control plane and the
daemon stopped responding to keystrokes for 300 ms. That's the
failure mode algo traders see in naive feed handlers, and it's the
failure mode `labpty` must not have. The Phase 1 design — C
implementation, binary frame protocol, polling readers, fixed-offset
shm, three counters, no GC, no ARC, no JSON parser — is what bounds
that risk.

The disciplines above buy a daemon whose worst-case behavior is bounded
and observable. The cost is roughly 600 lines of carefully-written
code versus 200 lines of careless code, plus a couple of weeks of
implementation. The benefit is that the protocol can be frozen — which
is the entire point of putting `labpty` underneath its client.

## Decision Log

Load-bearing design decisions that survived review. Each entry records
why an alternative was considered and rejected.

- Decision: Surface minimalism (principle 0) is the architectural
  constraint that decides Phase 1 / Phase 2 / Phase 3 for every
  feature in this document. `labpty` is the only process whose own
  upgrade still kills live sessions until Phase 3 fd-handoff lands,
  so every feature that lives in `labpty` carries an upgrade-restart
  cost we pay every time we touch the code. Phase 1's surface is the
  smallest credible set required for the headline acceptance test:
  open a PTY, drain it into a byte ring, accept input via an RPC,
  resize / signal / terminate, expose enough metadata for client
  restart to rediscover sessions, and a producer-alive heartbeat.
  Everything else — `attachSession`, wake pipes, per-reader slot
  table, snapshot cache, metadata ring, input ring, deadline
  enforcement, daemon-global counters, latency-forensics CI gating
  — was moved to Phase 2+ in this iteration, even where the
  long-term design still wants it.
  Date/Author: 2026-05-26 / thinness review iteration.

- Decision: Phase 1 readers poll the byte ring; no wake mechanism in
  `labpty`. No SCM_RIGHTS in Phase 1.
  Rationale: An earlier draft had `labpty` accept a wake-pipe write
  fd via SCM_RIGHTS at `attachSession`, maintain a per-reader slot
  table, and write one byte per coalesced ring publish to signal
  readers. That bought ~3 ms of wake latency over a 4 ms polling
  tick — which is invisible inside `LabanApp`'s render-frame cadence
  (~16 ms at 60 Hz). The Phase 1 cost was a per-reader registry, a
  wake-pending flag protocol, SCM_RIGHTS plumbing, and stale-reader
  sweep logic. None of it is required for the headline acceptance
  (`LabanApp` restart preserves the same child PID). Polling delivers
  the same outcome at zero `labpty` state and zero `labpty` code.
  Phase 2 may add the wake-pipe mechanism if measurements show the
  polling tick is a perceptible latency source.
  Date/Author: 2026-05-26 / thinness review iteration.

- Decision: Phase 1 does not have an `attachSession` RPC.
  Rationale: Once polling replaces wake pipes (preceding decision),
  there is no per-reader state for `attachSession` to register —
  `labpty` learns nothing it didn't already know. `listSessions`
  returns the byte-ring shm path on every descriptor, which is what
  `LabanApp` (and any future reader) actually needs to start
  consuming. Eliminating the RPC removes about 100 lines of `labpty`
  code plus one round-trip from every reader's startup path. Phase 2
  may reintroduce `attachSession` if/when the wake-pipe mechanism
  lands and needs a registration point.
  Date/Author: 2026-05-26 / thinness review iteration.

- Decision: Phase 1 `labpty` does not enforce request deadlines.
  Rationale: A deadline check is a `clock_gettime` syscall on every
  RPC plus a code path that has to be tested. Phase 1 RPC rate is
  bounded by user action (open/resize/terminate happen seconds
  apart; `writeInput` rate is bounded by typing speed). The Phase 1
  failure modes a deadline catches — `labpty` hangs while processing
  an RPC — are caught more cheaply by the client's own socket
  timeout. Clients may still include `deadline_ns` in the request
  envelope as forward-compat; `labpty` ignores it. Phase 2 may
  promote `deadline-enforcement/v1` if measurement justifies the
  syscall cost.
  Date/Author: 2026-05-26 / thinness review iteration.

- Decision: Phase 1 `labpty` populates only three shm counters
  (`output_bytes_written_total`, `output_wrap_count`,
  `producer_alive_mono_ns`). All other counter slots are reserved
  at their final offsets and stay zero.
  Rationale: The three populated counters are exactly what's needed
  to answer "is `labpty` alive and are bytes moving for this
  session." Master-side counters
  (`master_read_calls_total`/`master_read_eagain_total`),
  attached-consumer counters, input-side counters, wake-notification
  counters all become useful when Phase 2 starts caring about reader
  registration, input ring backpressure, and wake coalescing. Each
  costs a u64 store somewhere on a hot path; bundling them with their
  feature reduces the chance of an unused counter accumulating wrong
  values nobody notices.
  Date/Author: 2026-05-26 / thinness review iteration.

- Decision: Phase 1 does not ship the daemon-global counters file
  (`labpty_daemon_counters/{run_id}`).
  Rationale: Per-session counters in each ring's shm header plus the
  control-plane responses to `listSessions` and `ping` cover Phase
  1's observability needs. A daemon-global counters file adds a
  separate shm artifact, an opening / mapping path, and counter-update
  code on every RPC. The features it would observe — RPC rate, RPC
  error rate, daemon uptime — are interesting once `labpty` is in
  steady production use; Phase 1 is still proving the headline
  acceptance.
  Date/Author: 2026-05-26 / thinness review iteration.

- Decision: No PTY master fd ever crosses a process boundary in
  normal operation; Phase 1 uses no SCM_RIGHTS at all.
  Rationale: Two processes blocked in `read(2)` on the same PTY master
  fd race for individual bytes; POSIX makes no per-byte fairness or
  atomicity guarantee. Two writers interleave. An early draft of this
  doc handed the master fd out at `attachSession`, which would have
  let any client read or write the same master as `labpty` and split
  the byte stream non-deterministically. A later draft reduced
  SCM_RIGHTS to wake-pipe write fds only. The thinness review
  iteration removed SCM_RIGHTS from Phase 1 entirely by replacing
  wake pipes with polling. The `fd-handoff/v1` capability remains
  reserved for Phase 3 `labpty` self-upgrade, which is the only
  legitimate scenario for a PTY master fd to cross a process
  boundary, and that handoff goes between `labpty` instances, never
  to a client.
  Date/Author: 2026-05-26 / superseded then re-confirmed across
  successive review iterations.

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

- Decision: Phase 2's reader wake primitive (when it lands) is a
  self-pipe with the write end passed to `labpty` via SCM_RIGHTS at
  attach time. Phase 1 has no wake primitive — readers poll (see
  "Phase 1 readers poll").
  Rationale: `eventfd` does not exist on Darwin. `EVFILT_USER` is a
  per-process kqueue construct and cannot be triggered cross-process;
  earlier drafts treated it like a passable equivalent to `eventfd`,
  which was wrong. Mach semaphores would work but bring
  bootstrap-server and port-rights complexity that outweighs any
  speed advantage at the rates this protocol sees. A pipe is the
  simplest, well-understood, cross-process wake primitive available
  on Darwin; the ~1 µs `write(1)` cost plus scheduler pickup is
  dominated by jitter that no Darwin primitive avoids. The Phase 2
  decision is settled in case it's needed; the thinness review
  deferred actually shipping it because polling achieves the same
  user-visible behavior at zero `labpty` cost.
  Date/Author: 2026-05-26 / settled cross-iteration.

- Decision: Overflow recovery is tiered (fresh snapshot → in-ring
  replay → controlled failure), not solely "request opaque snapshot."
  Rationale: `labpty` does not parse VT state and cannot synthesize a
  snapshot on demand. The opaque snapshot cache is populated only
  when some parsing client (`LabanApp` in Background mode) has
  recently called `publishOpaqueSnapshot`. A cold-attached or
  long-idle session may have no cached snapshot, in which case the
  recovery must work from the ring alone. The chosen strategy
  replays the most recent `(capacity - safety_margin)` bytes through
  the parser, accepting a brief stale render until the next prompt
  redraw. The opaque snapshot remains an optimization for the common
  parser-as-reader case, not a precondition for correctness.
  Date/Author: 2026-05-26 / review iteration.

- Decision: `input-ring/v1` and `multi-attach-write-lease/v1` are
  Phase 2, not Phase 1.
  Rationale: Direct shared-memory input writes from multiple clients
  have no safe semantics without an arbitrating write-lease primitive
  on the `labpty` side. Designing and validating that lease is a
  separate problem from PTY custody. Phase 1 ships single-writer
  Background mode (one `LabanApp`, one writer per session); multi-
  writer arbitration is not needed. The active plan's M5 ships the
  single-writer flavor of `input-ring/v1` without the lease. A
  future multi-writer scenario (e.g., a labpty client letting a
  second observer also write input) re-introduces the lease
  prerequisite.
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

- Decision: Version *negotiation* happens at `hello`; version
  *identification* (`abi_major` + `abi_minor`) is in every frame
  header.
  Rationale: An earlier draft (JSON-based) showed a per-request
  `v` field used for negotiation, which contradicted the principle
  "versioning happens once at handshake." A subsequent binary
  draft removed the slot entirely, which over-corrected: a stray
  packet or a misdirected connection then had no framing-layer
  defense. The current shape splits the two concerns. `hello`
  negotiates which `protocol_major`/`protocol_minor` the
  connection uses; subsequent frames must carry that same
  `abi_major` in their header (mismatch closes the connection)
  but cannot renegotiate — the field is identification, not
  negotiation. Cost: 4 bytes (`abi_major` + `abi_minor`) per
  frame, negligible at RPC rates. Benefit: every frame
  self-identifies as `labpty` traffic at the right ABI level,
  catching bit-flips, misdirected sockets, and version skew at
  the framing layer.
  Date/Author: 2026-05-26 / settled across review iterations
  (refined in the cleanup-pass iteration to distinguish
  identification from negotiation).

- Decision: Control plane is length-prefixed binary frames
  (`LBPTY-CT-01`), not JSON.
  Rationale: The earlier design picked JSON for the control plane on
  ergonomics + bounded-rate grounds. The decision to implement
  `labpty` in C plus the verification bar (every non-syscall decision
  has a property test or fuzzer) inverted the cost: a JSON parser in
  C is the single most-exposed surface in `labpty` and a mandatory
  fuzz target, ~300 LoC at minimum for a closed schema. A binary
  frame decoder is ~80 LoC, trivially fuzzable (one bounds check per
  length prefix), and lets `writeInput` carry raw bytes without
  base64 (avoiding ~33% bandwidth overhead per keystroke and an
  encode/decode hop on each end). The human-debug ergonomics
  argument JSON used to win on is preserved through a separate
  `Tools/LabptyDump` Swift shim — ~50 LoC, one-time cost, never on
  the hot path. `LabandProtocol` reuse was the third JSON argument;
  it dissolved when `labpty` became C (Swift `Codable` doesn't help
  a C daemon).
  Date/Author: 2026-05-26 / binary-protocol switch iteration.
