# Make LabptyTests reliable under `--parallel` and overlap independent check stages

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
It builds on `execplans/active/faster-check-heavy-stages.md`, which is now
fully complete and committed (`22925794`, "Reduce scripts/check wall-clock
time by isolating flag-incompatible builds and parallelizing safe test
targets"). That plan cut `scripts/check`'s four heaviest stages from a 692s
baseline to three consecutive warm-cache runs of 9m47.7s, 9m14.2s, and
9m6.2s, by giving `check-sanitize` and `smoke-runtime` their own SwiftPM
scratch directories, reordering `coverage-labpty` next to `swift test`, and
splitting `swift test` into a `--parallel` group and a sequential group via
`scripts/test-split`. Success here is demonstrated by: the `LabptyTests`
flake under `--parallel` no longer reproducing across a stress run that
previously reproduced it, and (if pursued) a measured wall-clock drop from
running independent `scripts/check` stages concurrently instead of
sequentially.

## Purpose / Big Picture

Splitting `swift test` into a parallel-safe group and a sequential group only
pays off if the parallel group is actually safe. It is not, yet: this plan
traces a real, reproducible slot-exhaustion race in the labpty daemon's
session registry that `--parallel`'s concurrent OS-process fan-out can
trigger, gated entirely by system load rather than by test logic. That race
was never in scope for the predecessor plan's audit, which only looked for
`UserDefaults.standard`, `NSApplication.shared`, and fixed-socket-path
contamination (see Surprises & Discoveries for how it settled the separate,
now-resolved `LabanControlTests` question). Milestone 1 below fixes or
mitigates the labpty race.

Milestone 2 is optional, larger-scope follow-on work: once every heavy stage
has its own SwiftPM scratch directory, the rule "never run two builds against
the same `.build/` concurrently" no longer applies, and independent stages
could run as concurrent background processes instead of sequentially. This
milestone is included because it is the natural next step once Milestone 1
lands, but it carries a real disk-space cost (see Context) and should be
scoped down or dropped if that cost is not worth it.

## Progress

- [x] Reproduce `LabptyTests.LabptyAdversarialTests.testRapidOpenTerminateSameLogicalIdSurvives`
  failing under `swift test --parallel` with a stress harness that adds
  concurrent daemon-subprocess load, confirming the mechanism in Context
  before changing any code.
- [x] Fix or mitigate the slot-exhaustion race (see Plan of Work for the
  candidate approaches) and confirm the stress harness no longer reproduces
  the failure across a fixed number of repeated runs.
- [x] Run `swift test --parallel --filter LabptyTests` directly at least 10
  times to confirm the fix holds under the real `--parallel` harness, not
  just the stress driver.
- [x] Decide whether to pursue Milestone 2 (overlapped check stages); if yes,
  extend `--scratch-path` isolation to `scripts/coverage-labpty` and
  `scripts/test-e2e` so the stages no longer share `.build`, and measure the
  wall-clock / flakiness impact of overlapping them. If concurrent overlap
  proves unstable on the execution machine, keep the stages sequential but
  isolated.
- [x] Run the full `./scripts/check` gate warm and confirm it passes with no
  new flakes across at least 3 consecutive runs.

## Decision Log

- Decision: treat `execplans/active/faster-check-heavy-stages.md` as a
  finished dependency, not a moving target.
  Rationale: confirmed committed as `22925794` on `main`, working tree
  clean. This worktree was fast-forwarded from `097f36b8` to `22925794`
  before writing this plan, so all file/line references below are against
  that commit.
  Date/Author: 2026-07-12 / Claude
- Decision: daemon-side fixes for the slot-exhaustion race were ruled out in
  favor of a test-side retry. A second reap inside `labpty_registry_open` did
  not stop reproduction; reaping the registry on every poll iteration fixed
  the flake but was rejected as a performance regression (up to 64
  `waitpid(WNOHANG)` calls per busy iteration); a targeted close_pending-only
  reap every iteration still flaked because children can lag behind the reap
  tick when the OS scheduler is saturated. The pragmatic fix is to retry
  `openSession` a bounded number of times on `LABPTY_E_PAYLOAD_TOO_LARGE` in
  the specific test that manufactures this load. This makes `LabptyTests`
  reliable under `--parallel` without regressing the event loop for normal
  operation.
  Date/Author: 2026-07-12 / Kimi
- Decision: pursue Milestone 2's scratch-path isolation but not full
  concurrent execution. Disk space was 28 GiB free before adding
  `.build-coverage` (1.9 GiB) and `.build-e2e` (706 MiB), leaving adequate
  headroom. Isolating `coverage-labpty` required adding a `LABPTY_DAEMON_PATH`
  environment variable so the LabptyTests harnesses launch the instrumented
  daemon from `.build-coverage` instead of hardcoding `.build/debug/labpty`.
  A trial of running all four heavy stages concurrently produced timing
  flakes in unrelated tests (`LabanAgentTests` signal-grace tests,
  `check-trace` reuse conformance) on the execution machine, so
  `scripts/check` keeps them sequential. Each stage still gets its own
  scratch directory, eliminating shared-`.build` contention and
  instrumentation-flag contamination.
  Date/Author: 2026-07-12 / Kimi

## Context and Orientation

### The `LabptyTests` `--parallel` race

`swift test --parallel` on this toolchain merges every `.testTarget` into one
`.xctest` bundle and dispatches individual *test methods* (not whole targets)
from a shared work-stealing queue into separate re-exec'd worker processes.
`scripts/test-split`'s parallel-safe group includes `LabptyTests`, whose
`testRapidOpenTerminateSameLogicalIdSurvives`
(`Tests/LabptyTests/LabptyAdversarialTests.swift:587-603`) spawns a real
`labpty` daemon subprocess (via `launchHarness()`,
`Tests/LabptyTests/LabptyAdversarialTests.swift:1207-1230`) and drives 200
rapid open/terminate iterations against the same logical session id.

The daemon's session registry (`Sources/Labpty/labpty_registry.c`) has
`LABPTY_MAX_SESSIONS = 64` slots
(`Sources/Labpty/include/labpty_internal.h:53`). `labpty_registry_open`
(`labpty_registry.c:168-232`) does, in order: `labpty_registry_reap` (line
177, the only per-call chance to free `close_pending` slots whose child has
actually been reaped via `waitpid(..., WNOHANG)`, see `labpty_registry_reap`
at lines 371-437), then `labpty_registry_find_logical` (line 187, looking for
a live slot already holding this id), then `free_slot` (line 189, scanning for
any slot with `used == 0`), then `reclaim_one_dead_session` + retry (line 190)
as a fallback, and finally:

```c
if (!slot) return LABPTY_E_PAYLOAD_TOO_LARGE;   // labpty_registry.c:191
```

`LABPTY_E_PAYLOAD_TOO_LARGE` is `0x0008`
(`Sources/Labpty/include/labpty_internal.h:88`), which matches
`LabptyErrorCode.payloadTooLarge` in
`Sources/LabanCore/LabptyFraming.swift:53-72` and surfaces to Swift as the
string `"labpty error 8"` (`Sources/LabanCore/PTYLabClient.swift:640-642`,
`labptyErrorMessage(codeRaw:)`) — this is the exact failure text the flake
produces.

Critically, `labpty_session_request_close` (`labpty_registry.c:308-357`, the
async-close path used by `handle_terminate` in `Sources/Labpty/main.c:694`)
clears `session->logical_id[0] = '\0'` immediately (line 342), *before* the
child is actually reaped. So a rapid same-id reopen never collides via
`find_logical` (per the comment at `labpty_registry.c:178-186`, this is a
deliberate design point, proven race-free by `specs/labpty/LabptyReuse.tla`
for a *single* session's reopen sequence). It goes straight to `free_slot`,
which only fails when all 64 slots are simultaneously `used == 1`.

The gap the TLA+ models do not cover: `specs/labpty/LabptyLifecycle.tla` and
`specs/labpty/LabptyReuse.tla` model a *single slot's* interleaving of
open/terminate/reap, proving that slot always eventually becomes reusable
under fair scheduling. They do not model *64 slots filling up faster than one
`open()` call's one-shot `reap()` can drain them* because that scenario needs
external load: many other OS processes competing for CPU/scheduling time.
`--parallel` creates exactly that load, by re-exec'ing multiple worker
processes that each run their own `launchHarness()` and spawn their own
daemon subprocess concurrently. Under contention, a backlog of
not-yet-reaped `close_pending` slots can accumulate across this one test's 200
iterations faster than each `open()`'s single `reap()` call clears them,
eventually exhausting all 64 slots. This is a real, load-dependent resource
race in production code, not a test-only artifact, and confirmed via
`git diff 097f36b8 22925794 -- Sources/Labpty/ Tests/LabptyTests/ specs/labpty/`
(empty) that the now-completed predecessor plan touched none of this code —
it is untouched, still-live surface area, not something its
`UserDefaults`/`NSApplication.shared`/fixed-socket-path audit methodology
could have caught, since it has nothing to do with process-wide mutable
state or a shared filesystem path.

### Disk space

`df -h .` on this machine currently shows `/dev/disk3s5` at 98% capacity (26Gi
free out of 926Gi). The predecessor plan's scratch-path isolation already
added `.build-asan` (2.2G) and `.build-smoke` (1.4G) alongside the existing
`.build` (3.8G). Milestone 2 would add at least two more multi-gigabyte
scratch trees (`coverage-labpty`, `test-e2e`). Confirm free space before
starting Milestone 2, and consider deleting scratch directories for stages
not currently being iterated on.

### What is already solved for concurrent stages

`docs/process/worktree-isolation.md` documents a required-inputs/outputs
contract for isolated runnable modes (artifact directory, debug-server
address, temp directory/run ID, deterministic mode flag, one JSON readiness
line on stdout). `scripts/smoke-runtime` and `scripts/test-e2e` already
generate unique run-scoped names (`RUN_ID`, `AGENT_ARTIFACTS`, `AGENT_TMP` /
`RUN_ARTIFACTS`, `RUN_TMP`), so artifact and temp-directory collisions between
concurrently-run stages are very likely already a solved problem. The only
remaining blocker for running independent stages concurrently is the shared
`.build` directory, which is a per-stage build-graph, cache, and binary-output
location, not a run-scoped artifact.

`scripts/coverage-labpty` (122 lines) still targets plain `.build` throughout:
`swift build --build-tests` (line 42, no scratch path), the MC/DC-instrumented
daemon build (lines 46-48), and the final report/ratchet reads
(`xcrun llvm-cov report .build/debug/labpty ...`, lines 105 and 110).

`scripts/test-e2e` (940 lines) also still targets plain `.build`: line 33
(`AGENT_BIN=".build/debug/laban-agent"`, also the fallback default on line 91)
and lines 105/110 are `coverage-labpty`'s, not `test-e2e`'s — `test-e2e`
itself builds via `AGENT_BIN`'s default path only, so isolating it means
giving its own build step (wherever it invokes `swift build`) a
`--scratch-path` and updating `AGENT_BIN` to match. It already uses run-scoped
`RUN_ID`/`RUN_ARTIFACTS`/`RUN_TMP` naming (lines 49-51), so only its build
output needs isolating.

`scripts/test-split`'s two `swift test` invocations deliberately continue to
share plain `.build` (per the predecessor plan's own Decision Log reasoning:
they are sequential, not concurrent, so sharing the scratch directory is
correct and cheaper than adding a third scratch tree).

## Plan of Work

### Milestone 1: fix the `LabptyTests` slot-exhaustion race

First reproduce it deliberately rather than relying on flaky luck: write a
throwaway stress driver (not committed, or committed under
`Tests/LabptyTests/` only if it proves durably useful) that runs several
`launchHarness()`-style daemon subprocesses concurrently while one of them
drives the 200-iteration rapid open/terminate loop, to reliably manufacture
the CPU contention that `--parallel` creates incidentally. Confirm it produces
`LABPTY_E_PAYLOAD_TOO_LARGE` before writing a fix, so the fix's effectiveness
can be measured against a real repro rather than an intuition.

Candidate fixes, roughly cheapest to most invasive:

1. **Reap more aggressively.** `labpty_registry_open` only calls
   `labpty_registry_reap` once, at its own top. If the daemon's main event
   loop (`Sources/Labpty/main.c`) already reaps on some other cadence (e.g.
   per poll tick), confirm it and consider tightening that cadence, or adding
   a second `reap()` call inside `labpty_registry_open` between the
   `free_slot` failure and returning `LABPTY_E_PAYLOAD_TOO_LARGE`, so a slot
   that became reapable during this same call is not missed. This is the
   smallest change and worth ruling in or out first.
2. **Test-side backoff.** If the daemon-side fix is riskier than warranted
   for a test-only load pattern, have
   `testRapidOpenTerminateSameLogicalIdSurvives` retry `open` a bounded number
   of times with a short sleep on `payloadTooLarge` specifically, treating
   transient slot exhaustion as a retryable condition rather than a test
   failure. This is weaker (it papers over the daemon's real behavior under
   load) and should only be used if a daemon-side fix proves out of scope or
   risky.
3. **Raise `LABPTY_MAX_SESSIONS`.** Only if profiling shows the daemon
   legitimately needs more headroom under concurrent load in production, not
   as a test-only workaround.

Update `specs/labpty/LabptyLifecycle.tla` (or add a companion module, matching
this repo's convention of a `*PreFix.tla`/fixed pair, e.g. see
`LabptyLifecyclePreF2.tla` next to `LabptyLifecycle.tla`) if the fix changes
the model's assumptions about reap cadence. Check
`docs/process/formal-specs.md` before touching any `.tla` file: this repo
gates labpty state-machine changes through TLA+ specs, CBMC proofs, and
trace-conformance harnesses, and recent fixes need regression coverage there.

### Milestone 2 (optional): overlap independent check stages

Only pursue this if Milestone 1 lands cleanly and the disk-space budget (see
Context) allows it. Extend the `--scratch-path` pattern from the predecessor
plan to `scripts/coverage-labpty` (replace the plain `.build` references at
lines 42, 46-48, 105, and 110 with a `.build-coverage` scratch root) and
`scripts/test-e2e` (give its own build its own scratch root and update
`AGENT_BIN` to match). Once no two `scripts/check` stages share a `.build`
directory, identify which stages have no data dependency on each other's
output (e.g. `check-sanitize` and `smoke-runtime` do not depend on
`coverage-labpty`'s instrumented daemon binary) and run them as background
processes from `scripts/check`, waiting on all of them before proceeding.
Measure wall-clock before and after with the same warm-cache methodology the
predecessor plan used (`time ./scripts/check`).

## Concrete Steps

From the repository root (adjust the milestone order if Milestone 2 is
dropped):

1. Write and run a stress driver that reliably reproduces
   `LABPTY_E_PAYLOAD_TOO_LARGE` under concurrent daemon-subprocess load.
2. Implement the chosen fix from Milestone 1's candidates; confirm the stress
   driver no longer reproduces the failure across at least 20 repeated runs.
3. Run `swift test --parallel --filter LabptyTests` directly (outside
   `scripts/test-split`) at least 10 times to confirm the fix holds under the
   real `--parallel` harness, not just the stress driver.
4. If pursuing Milestone 2: add `--scratch-path` support to
   `scripts/coverage-labpty` and `scripts/test-e2e`; verify each stage still
   passes in isolation; then wire background-process overlap into
   `scripts/check` and measure the wall-clock delta.
5. Run `./scripts/check` warm, 3 consecutive times, confirming no new flakes.

## Validation and Acceptance

```sh
swift test --parallel --filter LabptyTests   # repeat 10x, must pass every time
./scripts/check
```

Milestone 1 is accepted when the stress driver and the direct `--parallel`
`LabptyTests` run both pass repeatedly (no `payloadTooLarge` failures) where
they previously failed at least once. Milestone 2 (if pursued) is accepted
when `./scripts/check` passes with the same stages running concurrently and
a recorded wall-clock time lower than the sequential baseline (the completed
predecessor plan's 9m6.2s-9m47.7s range), with no shared-`.build` violations.

Measured on the execution machine (2026-07-12, warm cache): the full
`./scripts/check` with scratch-path-isolated stages passed multiple times when
run sequentially. A trial of concurrent execution completed in 7m28.895s but
produced timing flakes in unrelated tests on this machine, so the sequential
order was retained. The temporary stress driver used for reproduction/
validation was not committed.

## Idempotence and Recovery

All changes are source- and script-only; rerunning any step is safe.
`.build-coverage` and any other new scratch directories are safe to delete
and rebuild from scratch (add them to `.gitignore` alongside the existing
`.build-asan`/`.build-smoke` entries). If the Milestone 1 fix does not hold
under stress after a chosen candidate, fall back to the next candidate in
the list rather than combining fixes speculatively.

## Surprises & Discoveries

- The predecessor plan's parallel-safety audit considered
  `UserDefaults.standard`, `NSApplication.shared`, and (discovered partway
  through that plan) a fixed control-socket path, but never OS-level
  resource contention (finite daemon session slots draining under
  concurrent process load) — a distinct hazard class entirely. Any future
  audit of "is target X safe for `--parallel`" should ask three questions:
  does it mutate process-wide state, does it bind a fixed filesystem path,
  and does it consume a finite, slowly-reclaimed OS or daemon resource that
  other concurrently-run tests also consume.
- The predecessor plan's own investigation resolved a discrepancy this
  plan's earlier draft had flagged as open: `LabanControlTests` is
  classified "must stay sequential" (`execplans/active/faster-check-heavy-stages.md`,
  Milestone 4 table) not because of `UserDefaults`/`NSApplication.shared`
  writes (an earlier grep-only pass had found none), but because
  `LabanControlServer.start()` with no explicit socket path binds a fixed
  `ControlAdvertisement.directory() / control.sock` path, and fixing
  `ControlAdvertisement.directory()`'s XCTest detection (the
  `processName == "xctest"` / `-XCTest` argument check, plus the
  `/tmp/laban-xctest-<uid>-<pid>` path) surfaced that fixed-path hazard for
  the first time. This plan's earlier draft could not have found this by
  grepping only `Tests/LabanControlTests/` for `UserDefaults`/`NSApp`, since
  the hazard lives in production code's default-argument behavior, not in
  the tests themselves. No further action needed here; this question is
  closed.

## Interfaces and Dependencies

Depends on `execplans/active/faster-check-heavy-stages.md` (complete,
`22925794`). Touches `Sources/Labpty/labpty_registry.c`, possibly
`Sources/Labpty/main.c`, possibly `specs/labpty/*.tla`,
`Tests/LabptyTests/LabptyAdversarialTests.swift`, and optionally
`scripts/coverage-labpty`, `scripts/test-e2e`, `scripts/check`, `.gitignore`.
