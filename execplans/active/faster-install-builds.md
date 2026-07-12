# Make installed-app builds fast without weakening the release bundle

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

`scripts/install-app` is the local delivery boundary for Laban: it produces a
profilable release bundle and replaces `~/Laban.app` plus its matching debug
symbols. It should remain just as complete and launchable, but repeated local
installs should avoid unnecessary SwiftPM planning and bundle work. After this
change, a warm install will build the same five executables, create the same
profile bundle and dSYM, and take measurably less wall-clock time.

## Progress

- [x] Inspect the existing install and bundle scripts and identify the repeated
  SwiftPM invocations on the warm path.
- [x] Record the initial profile install time and choose an optimization that
  preserves all five bundled executables.
- [x] Replace five product-specific SwiftPM planner invocations with one
  unqualified package build, retaining the existing required-product verifier.
- [x] Disable SwiftPM index-store generation for this non-IDE packaging path.
- [x] Verify warm install speed, bundle contents, signature, and dSYM UUID.
- [ ] Run the repository-wide check (blocked by unrelated existing SwiftLint
  failures in `Sources/LabanApp/LabanWindowScreenshotCapture.swift`).

## Context and Orientation

`scripts/install-app` calls `scripts/build-app --profile`, then copies
`.build/laban/Laban.app` and its sibling dSYM to the selected install directory.
`scripts/build-app` creates that bundle. The bundle must contain executable
files named `LabanApp`, `laban-agent`, `laband`, `labpty`, and `laban` in
`Contents/MacOS`; the profile mode must create an unstripped matching dSYM.

The current `build-app` runs a separate `swift build --product` process for
each executable, then a sixth `swift build --show-bin-path` process. This is
safe but makes SwiftPM repeatedly parse and plan the same package even when
nothing needs recompiling.

## Decision Log

- Decision: Use one unqualified `swift build` instead of attempting repeated
  `--product` options.
  Rationale: In the installed SwiftPM 6.3.3, `--product` is single-valued and
  repeated options use only the last product. The unqualified build produces
  all five required executables in one planning pass; the already-present
  executable existence check makes a missing helper a hard failure. It can
  also build non-install helper products, so cold and warm measurements must
  be assessed separately.
  Date/Author: 2026-07-12 / Codex.

- Decision: Pass `--disable-index-store` to both SwiftPM invocations in
  `scripts/build-app`.
  Rationale: `install-app` produces an app bundle and does not consume source
  navigation data. A direct same-cache measurement showed the unqualified
  release build fall from 29.04s to 5.20s when index-store work was disabled.
  The option changes only generated IDE index data, not the linked products or
  their debug information.
  Date/Author: 2026-07-12 / Codex.

## Plan of Work

Measure a second warm `scripts/install-app` invocation and capture its
wall-clock time. Use SwiftPM's supported unqualified build form, then verify
the resulting bin directory contains every required executable. Keep the existing post-build existence,
bundle, dSYM, signing, and installation checks. Add a small script-level
mechanical test if the repository has an appropriate shell-test convention;
otherwise use an explicit bundle-content check in the validation transcript.

## Validation and Acceptance

From this worktree, run `scripts/install-app` twice with the normal profile
configuration and compare the second elapsed time to the recorded baseline.
The optimized path passes when:

- the warm optimized install is faster than the baseline on the same checkout;
- `~/Laban.app/Contents/MacOS` contains all five executables above;
- `~/Laban.app.dSYM` exists and `codesign --verify --verbose=4 ~/Laban.app`
  succeeds;
- relevant script checks and `./scripts/check` remain green.

## Outcomes & Retrospective

On 2026-07-12, the old five-product sequence took 29.82s on the warmed local
release cache. The single package build with index-store generation disabled
took 5.20s in the same worktree. A complete `scripts/install-app` run after the
change took 9.11s and installed a valid ad-hoc-signed app. `dwarfdump --uuid`
reported the same UUID for `~/Laban.app/Contents/MacOS/LabanApp` and
`~/Laban.app.dSYM/Contents/Resources/DWARF/LabanApp`:
`B732165F-C763-31FB-95AE-98C29B298F32`.

The app bundle contained executable `LabanApp`, `laban-agent`, `laband`,
`labpty`, and `laban`; `codesign --verify --verbose=4 ~/Laban.app` passed.
`git diff --check` passed. `./scripts/check` reached the lint stage after its
boundary, documentation, debug-contract, model, CBMC, trace, coverage, and
fuzz checks, then failed on pre-existing formatting errors in the unrelated
`Sources/LabanApp/LabanWindowScreenshotCapture.swift` (lines 44 and 88 too
long; line 92 missing a trailing comma).

## Idempotence and Recovery

The install command deliberately replaces only the selected `Laban.app` and
its adjacent dSYM. It is safe to rerun. If a candidate SwiftPM invocation
omits a required executable, restore the existing per-product build loop before
proceeding; no installed bundle is changed until `build-app` completes.
