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
- [x] Run the repository-wide check (the blocking SwiftLint failures in
  `Sources/LabanApp/LabanWindowScreenshotCapture.swift` were fixed separately
  and merged; see `git log` for that commit).
- [x] Add a batch-mode compile flag for `--profile` builds, so a single-file
  edit does not force a whole-module recompile.
- [x] Flip that flag to the `--profile` default, after measuring it safe and
  faster in every case tried; `LABAN_WMO_PROFILE=1` now opts back into
  whole-module optimization instead.
- [x] Reuse the `.build/<config>` symlink SwiftPM already creates instead of a
  second `swift build --show-bin-path` planner invocation in `build-app`.
- [x] Reuse SwiftPM's own emitted `$bin/LabanApp.dSYM` (verified same UUID as
  the linked binary) instead of re-running `dsymutil` in `--profile` mode,
  with a UUID-equality guard and dsymutil fallback if they ever diverge.
- [x] Drop `-enable-batch-mode` from the `--profile` flags after the Swift
  Build system became the toolchain default and could no longer plan a
  batch-mode release target; per-file compilation stays the default.
- [x] Seed a brand-new git worktree's empty `.build` by cloning
  `.build/checkouts`, `.build/repositories`, and `workspace-state.json` from
  the main checkout via `cp -c` (APFS clonefile) before the first
  `scripts/install-app` build, so the first build in a fresh worktree does not
  pay to re-resolve and re-fetch every pinned dependency.

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

- Decision: Make whole-module optimization vs. batch-mode compilation an env
  var, initially opt-in (`LABAN_FAST_PROFILE=1` to enable batch mode).
  Rationale: whole-module optimization (WMO) recompiles an entire Swift module
  from scratch whenever any one file in it changes; this is the dominant cost
  of a warm, single-file-edit `--profile` build (measured: 16.6s-17.9s for a
  one-line comment appended to a 50-line leaf file, `LabanApp` being the
  largest affected module). Swift's incremental "batch mode"
  (`-no-whole-module-optimization -enable-batch-mode`) compiles per file
  instead, recompiling only what changed; it still runs at `-O` (unlike a
  debug `-Onone` build), so it is still meaningfully more representative for
  profiling than a debug build. Measured with the flag on: the same one-line
  edit rebuilt in 6.5s-7.5s end to end, roughly a 60% reduction. It started
  opt-in rather than the default because batch mode can make different
  cross-file inlining decisions than WMO, so a profile captured under it is
  not guaranteed byte-identical in code shape to one from a default
  `--profile` build. Flipping the flag forces one full rebuild (SwiftPM
  replans on any compiler-flag change); this is a one-time cost paid once per
  session per worktree, not on every subsequent incremental build.
  Date/Author: 2026-07-12 / Claude (Sonnet 5), following a research pass by a
  Fable-model subagent that proposed and independently measured this option
  before implementation.

- Decision: Flip batch-mode compilation to be `--profile`'s default; add
  `LABAN_WMO_PROFILE=1` to opt back into whole-module optimization.
  Rationale: after using the opt-in flag for a session with no observed
  correctness or profiling-fidelity issues, and since every measurement so far
  showed batch mode strictly faster with no downside besides the theoretical
  cross-file-inlining difference, the user decided the safer default was the
  faster one; WMO becomes the rarely-needed opt-in for the specific case where
  a profile must match a distributed release build's exact code shape.
  Date/Author: 2026-07-12 / Claude (Sonnet 5), at the user's direction.

- Decision: Drop `-enable-batch-mode`, keeping `-no-whole-module-optimization`
  as `--profile`'s default.
  Rationale: Swift 6.4 makes the Swift Build system the default, and it plans
  a release target as a single WMO "Compilation Requirements" task expecting
  one `<module>-primary.d`. Batch mode makes the driver emit per-file
  dependency files instead, so `scripts/install-app` failed outright with
  `unable to open dependencies file` on LabanRenderer — the fast path had
  stopped being a path at all. Measured on this toolchain, the leaf-file edit
  loop (`Sources/LabanApp/TerminalQuickLook.swift`, `build-app --profile`)
  costs ~38.9s under WMO and ~24.0s with per-file compilation alone, so
  dropping only the unplannable flag keeps most of the win and restores a
  working default. Both figures are slower than the ~17.9s/~7.5s measured
  under the old native build system; that regression is the build system's,
  not this flag's. The cross-file-inlining caveat and `LABAN_WMO_PROFILE=1`
  escape hatch are unchanged.
  Date/Author: 2026-08-16 / Claude (Opus 5), while repairing the build on a
  Swift 6.4 / macOS 27.0 SDK toolchain.

- Decision: Reuse the `.build/<config>` symlink instead of a second
  `swift build --show-bin-path` call in `build-app`.
  Rationale: SwiftPM creates a `.build/debug` or `.build/release` symlink
  pointing at the same directory `--show-bin-path` would print (verified via
  `-ef` inode comparison after both a debug and a release build). Reading that
  symlink avoids a second full SwiftPM planner invocation just to recover a
  path already known on disk. Falls back to the original `--show-bin-path`
  call if the symlink is somehow missing.
  Date/Author: 2026-07-12 / Claude (Sonnet 5).

- Decision: In `--profile` mode, reuse SwiftPM's own `$bin/LabanApp.dSYM`
  instead of re-running `dsymutil` over the linked binary's `.o` files.
  Rationale: SwiftPM's release build already runs `dsymutil` itself and leaves
  a `$bin/LabanApp.dSYM` next to the binary; verified with `dwarfdump --uuid`
  that its UUID matches `$bin/LabanApp` (the same file `cp -f`'d into the
  bundle with no intervening mutation). Copying that existing dSYM with
  `ditto` is materially cheaper than a second full `dsymutil` invocation. A
  UUID-equality check runs first every time, comparing the bundled binary's
  UUID against the candidate dSYM's UUID; only on a match is the dSYM copied,
  otherwise `build-app` falls back to running `dsymutil` fresh, so a future
  change that makes the bundle binary diverge from `$bin/LabanApp` cannot
  silently ship a UUID-mismatched (and therefore useless-for-symbolication)
  dSYM.
  Date/Author: 2026-07-12 / Claude (Sonnet 5).

- Decision: Seed a new git worktree's empty `.build` from the main checkout's
  `.build/checkouts`, `.build/repositories`, and `workspace-state.json` using
  `cp -c` (APFS clonefile, copy-on-write and near-instant on the same volume)
  before the very first `scripts/install-app` build in that worktree.
  Rationale: this repo's contributors work from many parallel git worktrees
  (`docs/process/worktree-isolation.md`), each starting with a completely
  empty `.build`. `.build/checkouts` and `.build/repositories` hold only
  fetched dependency source trees and git metadata for the ~21 pinned
  SwiftPM dependencies (swift-nio, swift-crypto, swift-algorithms, etc.), not
  this worktree's own compiled object files or module cache, so they carry no
  worktree-specific absolute paths and are safe to clone verbatim: SwiftPM
  re-validates whatever is in `.build/checkouts` against `Package.resolved`
  on every build and re-fetches anything that does not match, so a stale,
  partial, or unrelated clone degrades to normal (slower) resolution rather
  than producing a wrong build. Measured: `cp -c -R` of the main checkout's
  230MB `.build/checkouts` completed in ~1.8s. Only compiled build output
  (`.build/arm64-apple-macosx`, `.build/laban`, module caches) is intentionally
  left out of this seeding: those directories are known to embed
  worktree-specific absolute paths (via the existing `-debug-prefix-map`/
  `-file-prefix-map` flags keyed on `repo_root`) and are exactly the class of
  state the prior `terminalBackendMenu` stale-cache incident (see
  `scripts/build-app`'s required-executable guard) warns against sharing
  across checkouts.
  Date/Author: 2026-07-12 / Claude (Sonnet 5).

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

On 2026-07-12, a second pass (this worktree, `linked-wandering-bird`) measured
the warm single-file-edit case directly: appending one comment line to
`Sources/LabanApp/TerminalQuickLook.swift` (a 50-line leaf file) and running
`./scripts/build-app --profile` took ~17.9s under whole-module optimization
(WMO), which was the default at the time, after this round's mechanical fixes
(`.build/<config>` symlink reuse, dSYM reuse), down modestly from ~20.5s
before them. With batch-mode compilation enabled (at the time via
`LABAN_FAST_PROFILE=1`), the identical edit rebuilt in ~7.5s, about a 58%
reduction versus the ~17.9s WMO figure and roughly 63% versus the original
~20.5s baseline. A fully warm, no-source-change `scripts/install-app` run
(nothing to rebuild) dropped from ~2.7s to ~1.2s from the `.build/<config>`-
symlink and dSYM-reuse changes alone. In both the WMO and batch-mode
configurations, `dwarfdump --uuid` confirmed the installed binary and its
adjacent `.dSYM` shared the same UUID, and `codesign --verify --verbose=4`
passed on the installed bundle. The cold-worktree `.build/checkouts` seeding
step was exercised implicitly (its guard condition, `.build/checkouts`
already present, was true throughout this session's testing since the
worktree's `.build` was not empty); the underlying `cp -c -R` of the main
checkout's 230MB `.build/checkouts` was timed standalone at ~1.8s, confirming
the mechanism is cheap, but the full "very first build in a brand-new
empty-`.build` worktree" path was not re-verified end-to-end in this pass.

Following these measurements, batch-mode compilation was flipped to be
`--profile`'s default (`LABAN_WMO_PROFILE=1` now opts back into WMO); see the
Decision Log entry above. Re-verification after the flip: with no env var set,
`swift package describe --type json` still parsed the manifest correctly, and
a leaf-file edit under the new default rebuilt in the same ~7s range measured
above for batch mode (the compile flags themselves are unchanged, only which
one is selected by default). `dwarfdump --uuid` and `codesign --verify`
continued to pass against the newly installed bundle.

## Idempotence and Recovery

The install command deliberately replaces only the selected `Laban.app` and
its adjacent dSYM. It is safe to rerun. If a candidate SwiftPM invocation
omits a required executable, restore the existing per-product build loop before
proceeding; no installed bundle is changed until `build-app` completes.
