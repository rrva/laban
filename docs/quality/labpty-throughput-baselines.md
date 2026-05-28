# Labpty Throughput Baselines

Reference numbers for the labpty producer hot path so future "should we
optimize labpty" questions have a starting answer. Re-measure when the
event loop, byte-ring writer, or PTY drain changes.

## How To Measure

```
swift build --product labpty -c release
swift build --product bench-labpty-hot-path
.build/debug/bench-labpty-hot-path --top-outliers 10 daemon-drain
.build/debug/bench-labpty-hot-path --sessions 8 daemon-drain
```

The bench is `Tools/BenchLabptyHotPath/main.swift`. Three modes:

- `daemon-drain` — end-to-end. Spawns labpty, opens N sessions running a
  payload-emitting child, drains via `LabptyByteRingReader`. Only mode
  that exercises labpty's compiled C in the daemon.
- `daemon-drain-noread` — same setup, consumer only samples the writer
  offset. Isolates producer cost.
- `ring-write` — Swift `LabptyByteRingWriter` microbench. Floor only;
  not labpty's C path.

Flags: `--sessions N`, `--producer cat|zero`, `--top-outliers N`.

## Baseline (recorded 2026-05-28, release labpty, debug bench)

| Configuration | Throughput | p50 / p99 / max read |
| --- | --- | --- |
| `ring-write` (Swift floor) | ~17 GiB/s | n/a |
| `daemon-drain` 1 session, `cat` | ~26 MiB/s | 2µs / 7µs / 225µs |
| `daemon-drain` 4 sessions | ~50 MiB/s aggregate (~12.5/session) | 1µs / 11µs / — |
| `daemon-drain` 8 sessions | ~56 MiB/s aggregate (~7/session) | 1µs / 17µs / 573µs |

Numbers vary 5–10% iteration to iteration. The shape is what matters,
not the precise value.

## What These Numbers Mean

- **Byte-ring write is not the bottleneck.** The Swift writer alone moves
  ~17 GiB/s; the C path in labpty is structurally identical. Producer
  throughput is ~700× below the ring's capacity per session.
- **Single-session is PTY-bound, not labpty-bound.** Bumping
  `LABPTY_READ_BUFFER_BYTES` 4 KiB → 32 KiB and skipping the per-write
  `labpty_byte_ring_heartbeat` both yielded zero change. The cap is in
  the kernel TTY/line-discipline path. Swapping `cat` for `dd
  if=/dev/zero` made it *slower* (20.5 MiB/s) because larger child-side
  writes fragment against the PTY slave queue.
- **Multi-session ceiling is ~55 MiB/s.** Sub-linear scaling from 1→4
  sessions, near-flat from 4→8. The single-threaded event loop is
  saturating somewhere — likely contention between the daemon, N `cat`
  children, and N consumer threads on a small machine. The bench can't
  decompose further without daemon-side instrumentation.

## When To Care

Interactive use (a few tabs, one focused, output bursty) sits orders of
magnitude below these ceilings — humans can read ~100 KB/s of useful
information. Snapshot publishing and rendering downstream of labpty have
their own latency budgets and aren't measured here.

Revisit if:

- Product scope adds workflows that drive 8+ heavy-output tabs
  concurrently (e.g. parallel agent builds streaming through labpty).
  The 4→8 scaling cliff would become a real constraint, and the fix is
  almost certainly architectural (multi-threading the event loop or
  pushing drain to per-session threads), not optimizing the byte-ring
  write.
- Read-latency p99 ever exceeds a frame budget (~16 ms at 60 Hz). The
  current max (573 µs at 8 sessions) is 28× below the budget.
- `daemon-drain` falls noticeably below ~25 MiB/s single-session. That
  would indicate a regression in the drain loop or the kernel TTY path.

Do *not* revisit to "make labpty faster" without a specific workload
that's slower than this baseline.
