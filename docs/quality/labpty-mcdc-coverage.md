# Labpty MC/DC Coverage Baseline

Modified Condition/Decision Coverage (MC/DC) — the DO-178C DAL-A metric — for
the labpty daemon as exercised by the `LabptyTests` integration suite. MC/DC
asks the exacting question line and branch coverage do not: was each boolean
*condition* shown to **independently** flip its decision's outcome? It stays
low even when line coverage looks healthy, which is exactly why it is worth
tracking.

The decoders (`labpty_frame.c`, `labpty_protocol.c`, `labpty_byte_ring.c`
write path) are proven **exhaustively** by CBMC (`proofs/labpty/`), so their
dynamic MC/DC is not the target. The number that matters is the **un-proven
daemon code**: `main.c` handlers + the event loop, and `labpty_registry.c`.

## How To Measure

```
scripts/coverage-labpty            # build instrumented, run tests, print report
scripts/coverage-labpty --check 18 # same, but fail if daemon MC/DC < 18% (ratchet)
```

Single matched toolchain (Apple clang 21 + `xcrun llvm-cov`, both do MC/DC
natively). The daemon is `SIGKILL`ed at test teardown, so it is built with
`-fprofile-continuous` — counters are page-aligned and synced live, surviving
the kill. The instrumented binary is built last and the next ordinary build
restores an un-instrumented one, so the normal build is never contaminated.

## Why integration tests alone are the wrong instrument

The first measurement was **integration-only** (the LabptyTests suite driving
the real daemon): **18.4% daemon MC/DC**, and *non-deterministic* — it jittered
18.4%↔19.2% run-to-run because timing decides which sessions get reaped and
which deadlines fire. Worse, a large share of the missing conditions are
**unreachable from any integration test**: defensive guards on pointers that
are never null, `errno` fault branches (`EINTR`/`EAGAIN`/`POLLHUP`), `killpg`
failure fallbacks, and `snprintf` overflow.

So MC/DC is driven by **deterministic decision-function harnesses** in
`proofs/labpty/coverage/` (the same `#include` pattern as the CBMC harnesses):
each calls a daemon decision function directly with the exact condition vectors
MC/DC requires, including the ones integration can't reach. The harness profile
is merged with the integration profile (`llvm-cov -object`), so the reported
number is the **union**. `registry_cov.c` alone took `registry.c` from 23% to
44% by covering `valid_output_capacity`, `is_reclaimable_dead_session`,
`make_logical_id` (incl. the NULL vector), `registry_find`, and `make_ring_path`
to 100% / near-100% — deterministically.

## Baseline (2026-05-30, `main`)

Union of integration suite + `registry_cov.c` harness:

| File | Line | Branch | **MC/DC** | Source of coverage |
| --- | --- | --- | --- | --- |
| `main.c` | 84% | 57% | **~17%** | integration only (harness TODO) |
| `labpty_registry.c` | 87% | 61% | **~44%** | integration + `registry_cov.c` |
| **daemon total** | 85% | 58% | **~26%** (≥24% floor) | union |

## Ratchet + target

`scripts/coverage-labpty --check 24` is a one-way ratchet: coverage may only go
up. CI runs it as a floor so the suite can never regress below the recorded
baseline; raise the floor as each harness lands.

The honest target is **100% of the *feasible* conditions**, not 100% of all
conditions — a chunk are genuinely infeasible (defensive/fault-only) and should
be documented as excluded (an avionics-style deviation record) rather than
chased. The biggest remaining lever is a `main_cov.c` harness for the handlers,
`is_canonical_delimiter`, dispatch, and the expiry logic (`main.c` is 82 of the
125 conditions and still mostly integration-only).

To find the specific untested conditions, run:

```
xcrun llvm-cov show .build/debug/labpty -instr-profile=<merged.profdata> \
  --show-mcdc Sources/Labpty/labpty_registry.c
```

Each reported decision lists which condition combinations were never observed
— those are the inputs the next test must produce.
