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

## Baseline (2026-05-30, `main`)

Un-proven daemon code, 52 daemon processes across the suite:

| File | Line | Branch | **MC/DC** |
| --- | --- | --- | --- |
| `main.c` | 84.4% | 56.8% | **15.9%** |
| `labpty_registry.c` | 85.5% | 55.1% | **23.3%** |
| **daemon total** | 84.7% | 56.3% | **18.4%** |

The gap between 85% line coverage and 18% MC/DC is the finding: most of the
daemon's compound decisions (`a && b`, error-path disjunctions, the
backpressure preflight, signal handling) are never tested for each condition's
independent effect.

## Ratchet + target

`scripts/coverage-labpty --check 18` is a one-way ratchet: coverage may only go
up. CI runs it as a floor so the suite can never regress below the recorded
baseline. The target is to drive the un-proven daemon code toward **100%
MC/DC** by adding targeted tests, raising the floor each time.

To find the specific untested conditions, run:

```
xcrun llvm-cov show .build/debug/labpty -instr-profile=<merged.profdata> \
  --show-mcdc Sources/Labpty/labpty_registry.c
```

Each reported decision lists which condition combinations were never observed
— those are the inputs the next test must produce.
