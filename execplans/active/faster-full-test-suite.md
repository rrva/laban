# Make the full test suite faster without weakening its regression checks

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
It reduces the time developers wait for `swift test` and `scripts/check` while
retaining the same behavioral checks. Success is demonstrated by a passing
full suite and measured timings from the same warm worktree state.

## Purpose / Big Picture

The Laban gate contains process, renderer, and control-plane regressions that
must stay checked, but several tests currently wait on production-sized
timeouts. Test-only, dependency-injected timing lets those tests prove the
same timeout distinction in milliseconds instead of seconds. The full suite
should remain deterministic: it must not depend on unsafe parallel execution
because many tests intentionally change process-wide environment variables,
AppKit state, and user defaults.

## Progress

- [x] (2026-07-12) Profile the current suite and identify production-timeout
  waits as a concrete cost; establish that global parallel XCTest is unsafe.
- [x] (2026-07-12) Collapse the two address-sanitizer invocations into one
  regex-filtered run, preserving both test targets.
- [x] (2026-07-12) Add a scoped control-server timeout seam whose production
  default remains five seconds.
- [x] (2026-07-12) Convert the attached-connection idle regression to the short
  test timeout, preserving proof that its post-attach timeout is disabled.
- [x] (2026-07-12) Parallelize independent CoreText/vector oracle renders while
  retaining all 190 glyph/font comparisons, samples, and thresholds.
- [x] (2026-07-12) Validate focused tests and the merged address-sanitizer run
  (282 tests, 2 skipped, 0 failures).
- [x] (2026-07-12) Repeat normal timing: test execution fell from 279.825s to
  253.306s in this worktree.
- [x] (2026-07-12) Fix the route-catalog count assertion drift (46 → 47 after
  the window-screenshot route landed in e305a5aa).
- [x] (2026-07-12) Resolve the pre-existing renderer-fidelity failures
  (`VectorGlyphParityTests.testDefaultVectorTextFidelityStaysNearMetalOnLightBackground`
  and 3 `SlugGlyphAAFidelityTests` cases). Root cause: `swift test`'s
  `UserDefaults.standard` resolves to the on-disk `com.apple.dt.xctest.tool`
  preference domain, not a per-run sandbox; a crashed weight-probe test
  elsewhere (`SlugGlyphRendererTests.testSlugTextWeightThickensRenderedInk`)
  can leave `LabanVectorTextWeight` persisted non-default, contaminating
  later renderer fidelity tests. Fix: reset the key in `setUp`/`tearDown` of
  both affected test files. The leak's source point in
  `SlugGlyphRendererTests` was not hardened, only its victims.
- [ ] Continue optimizing the rest of `scripts/check` beyond `swift test`
  (boundaries/docs/anchors/specs/cbmc/trace/fuzz/e2e stages), guided by a
  per-stage timing baseline.

## Decision Log

- Decision: optimize deterministic waits before considering parallel test
  execution.
  Rationale: the suite changes global environment, AppKit state, and defaults;
  a global parallel flag can create cross-test races and false confidence.
  Date/Author: 2026-07-12 / Codex

## Context and Orientation

`Sources/LabanControl/LabanControlServer.swift` accepts connections and applies
a five-second request-read timeout before a connection authenticates. An
attached agent connection then switches to an unlimited timeout. The regression
in `Tests/LabanAppTests/ControlDefaultOnTests.swift` currently waits six real
seconds to prove that switch. The test needs to distinguish a regular timeout
from no timeout, but does not need the production duration.

## Plan of Work

Add an initializer parameter on `LabanControlServer` for the ordinary request
read timeout, defaulting to the existing five seconds. Store it per server and
use it for both the socket receive timeout and request parser deadline before
attachment. Keep the post-attachment timeout exactly zero. Construct the test
server with a short ordinary timeout, wait just beyond it, and issue the same
authenticated request. This proves the same property: if attachment failed to
disable the timeout, the read has already expired; if it succeeds, the request
returns 200.

## Concrete Steps

From the repository root:

1. Add `requestReadTimeout` to `LabanControlServer` with a default of `5`.
2. Pass the stored value to `setReceiveTimeout` and `readHTTPRequest` in the
   connection loop.
3. Update `testAttachedConnectionSurvivesIdleBeyondRequestTimeout` to use a
   short timeout and a slightly longer sleep.
4. Run the focused test, then `swift test`, then `./scripts/check` while
   recording warm elapsed time.

## Validation and Acceptance

Run:

```sh
swift test --filter ControlDefaultOnTests/testAttachedConnectionSurvivesIdleBeyondRequestTimeout
swift test
./scripts/check
```

The focused test must pass when its idle wait is longer than the injected
ordinary timeout. The full suite and full gate must exit zero. The production
default remains five seconds, so production behavior is unchanged.

## Idempotence and Recovery

The change is source-only and safe to rerun. If the focused test flakes, retain
the production default and increase only the test margin between its injected
timeout and its sleep; do not restore a multi-second production wait merely to
avoid a test race.

## Surprises & Discoveries

- The initial full-suite measurement executed 2,449 tests in 279.825 seconds.
  The post-change run executed the same 2,449 tests in 253.306 seconds.
- The printable-ASCII glyph oracle fell from 26.559 seconds to 3.505 seconds
  in a focused run, and to 6.680 seconds under full-suite load. Its input set,
  sample count, thresholds, and failure artifacts are unchanged.
- Both normal full-suite runs have unrelated route-catalog and renderer-fidelity
  failures. Neither modified test failed.
