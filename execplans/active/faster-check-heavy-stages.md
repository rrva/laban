# Speed up the four heaviest stages of `scripts/check`

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

`scripts/check` is the full local pre-push gate a developer runs before
pushing to `main`. A timed baseline of a clean, isolated `./scripts/check`
run in this worktree, captured 2026-07-12, recorded a total run of about
692 seconds across 22 stages. Four stages account for 675 of those 692
seconds (97%):

| Stage | Command (in `scripts/check`) | Seconds |
| --- | --- | --- |
| `swift-test` | `swift test` (`scripts/check:96`) | 357 |
| `check-sanitize` | `./scripts/check-sanitize` (`scripts/check:97`) | 139 |
| `coverage-labpty` | `./scripts/coverage-labpty --check 45` (`scripts/check:109`) | 126 |
| `smoke-runtime` | `./scripts/smoke-runtime` (`scripts/check:98`) | 53 |

Everything else in `scripts/check` (boundaries, docs, anchors, TLA+ specs,
CBMC proofs, trace conformance, model coverage, fuzzing, lint, dependency
checks, `swift build`, `test-e2e`) sums to about 17 seconds combined and is
NOT part of this plan; a prior optimization pass already batched the JSON
schema validation (`scripts/check:14-19`, committed as `4747bcf1`) and found
nothing else in that remaining 17 seconds worth the churn. Do not spend time
on those small stages under this plan.

After this plan, a developer running `./scripts/check` on a warm, incremental
`.build` should see the same pass/fail behavior and the same coverage
guarantees (MC/DC ratchet, sanitizer coverage, full test suite, full runtime
smoke), but in meaningfully less wall-clock time. Success is demonstrated by
timing each targeted stage before and after your change (see per-milestone
"how to measure" instructions below) and by a full `./scripts/check` run
still exiting 0.

**A repository rule you must follow throughout this work** (from
`docs/process/agent-operating-guide.md`, restated here so this plan is
self-contained): never run two builds, `scripts/check` invocations, or
`scripts/build-app` invocations concurrently against the *same* `.build/`
directory in the *same* worktree. A competing Swift build can relink the app
bundle after ad-hoc signing and produce spurious codesign/smoke failures that
have nothing to do with your change. If you want to measure two things at
once, use two separate git worktrees (see
`docs/process/worktree-isolation.md`) or two separate `--scratch-path`
values (see Milestone 1 and 3 below, which introduce exactly this).

## Context and Orientation

This is a macOS terminal application built with Swift Package Manager (SwiftPM).
`Package.swift` at the repository root defines the products (executables like
`laban-agent`, `labpty`, `LabanApp`) and targets (buildable units of Swift/C
source, each either a library `.target`, an `.executableTarget`, or a
`.testTarget`). A "target" in SwiftPM is a named collection of source files
compiled together; a "product" is something a consumer can build or run
(an executable or library made from one or more targets).

`.build/` is SwiftPM's scratch directory: object files, module caches, and
linked binaries live there, keyed by target triple and build configuration
(`debug` or `release`). Two `swift build`/`swift test` invocations that pass
*different* compiler flags (for example, one plain and one with
`-sanitize address`) still write into the *same* `.build/<triple>/debug`
directory by default, because SwiftPM does not include arbitrary flags in the
directory key — only the target triple and configuration name. This means a
flag change between two consecutive invocations forces SwiftPM to treat
previously-built objects as stale and recompile them, even though nothing in
`.build/<triple>/debug`'s *name* changed. This mechanism (confirmed by
inspecting `.build/arm64-apple-macosx/debug` directly in this investigation:
it is currently only 0 bytes / freshly evicted, and the previously-built
`LabanPackageTests.xctest` binary showed no ASan runtime linked via `otool -L`
even though `check-sanitize` had run) is the root cause behind three of the
four heavy stages below, and `--scratch-path <path>` (a `swift build`/`swift
test` flag that redirects the *entire* `.build`-equivalent directory
elsewhere, confirmed present via `swift build --help` / `swift test --help`
on this toolchain, Swift 6.3.3) is the standard SwiftPM mechanism to give a
flag-incompatible build its own home so it stops evicting a sibling build's
cache.

Read `scripts/check` (repository root) in full before starting; it is the
top-level driver and defines the exact stage order these four stages run in:
`swift build` (line 95) → `swift test` (96) → `check-sanitize` (97) →
`smoke-runtime` (98) → `test-e2e` (99) → ... → `coverage-labpty --check 45`
(109, inside an `if` guard that skips it when the darwin profile runtime is
absent).

## Milestone 1: Stop `check-sanitize` from evicting the plain debug build cache

### What exists today

`scripts/check-sanitize` (repository root) is:

```sh
#!/usr/bin/env sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
./scripts/fetch-libghostty-vt
swift test --sanitize address --filter 'LabanTerminalCoreTests|LabptyTests'
```

`LabanTerminalCoreTests` depends only on `LabanTerminalCore` (a mixed C/Swift
target, about 5,300 lines of C, that statically links a vendored library at
`.external/libghostty-vt/zig-out/lib/libghostty-vt.a`). `LabptyTests` depends
on `Labpty` (a pure-C executable target, about 2,900 lines) and on
`LabanCore`, which transitively pulls in `LabanRenderer` (about 17,200
lines) and `LabanTerminalCore` again. (All of this is declared in
`Package.swift`'s `targets:` array, around lines 159-191 for the test
targets and their `dependencies:` lists — read that file to confirm current
line numbers before editing, since other work may shift them.)

`./scripts/fetch-libghostty-vt` (repository root) early-exits in under a
second when `.external/libghostty-vt/zig-out/lib/libghostty-vt.a`,
`.external/libghostty-vt/zig-out/include/ghostty/vt.h`, and the pinned git
commit are already present and matching (read the script's own guard
condition near its start to confirm). It is not a meaningful contributor to
this stage's time and does not need to change. Note `scripts/check:93` also
calls `fetch-libghostty-vt` once already before `swift build` at line 95;
`check-sanitize`'s own call is a redundant but cheap no-op guard, not a bug
worth fixing here.

`swift test --sanitize address ...` forces AddressSanitizer (ASan)
instrumentation into every object file in the dependency chain above
(LabanTerminalCore, LabanRenderer, LabanCore, Labpty, plus the two test
targets themselves — order 50,000 lines of C/Swift total). Because
`scripts/check` runs a *plain* `swift build` (line 95) and `swift test`
(line 96) immediately before this stage, and because SwiftPM's `.build`
directory key does not include sanitizer flags, this stage's ASan build
overwrites the plain build's cached objects for every target it touches. The
*next* build in `scripts/check` that touches any of those same targets (in
particular `coverage-labpty`'s own `swift build --build-tests` at
`scripts/coverage-labpty:42`, which happens later in the same
`scripts/check` run — see Milestone 2) then finds a flag mismatch and pays a
real, unnecessary recompile too. The same eviction tax repeats on a
developer's very next plain `swift build`/`swift test` in their next local
session.

Reasoning about the 139-second baseline for this stage: `LabanTerminalCoreTests`
and `LabptyTests` are low-level parser/PTY-protocol unit tests, not the
CoreText/Metal visual-fidelity suites that dominate elsewhere in this repo's
test suite; their *unsanitized* runtime is plausibly single-digit-to-low-
double-digit seconds. Even at a generous 10-20x ASan/UBSan slowdown (typical
for sanitizer runtime overhead), that only accounts for roughly 20-40 seconds.
The remaining roughly 100-115 seconds is most plausibly a from-scratch
ASan-instrumented compile+link of the ~50,000-line dependency chain, which
would not need to repeat on every local run if it had its own stable cache
directory instead of colliding with the plain-build cache every time.

### What to change

Give `check-sanitize`'s ASan build its own SwiftPM scratch directory so it
stops evicting (and being evicted by) the plain debug build. Edit
`scripts/check-sanitize` so the `swift test` line becomes:

```sh
swift test --sanitize address --scratch-path .build-asan --filter 'LabanTerminalCoreTests|LabptyTests'
```

`--scratch-path .build-asan` tells SwiftPM to use `.build-asan/` (created
relative to the current working directory, which the script has already
`cd`'d to the repository root) instead of the default `.build/`. This is a
plain relative path, matching how the rest of this repository names build
byproducts; do not use an absolute path, since the worktree location differs
per checkout (see `docs/process/worktree-isolation.md` if you need the full
rationale for that rule).

Also add `.build-asan/` to the repository's root `.gitignore` (find the
existing `.build` or similar entry in `.gitignore` and add a sibling line
directly beneath it) so this new scratch directory is never accidentally
committed.

### How to measure this milestone

Do not run the full `./scripts/check` gate to measure a single-stage change;
it takes over 11 minutes and most of that time is unrelated to this
milestone. Instead:

1. From the repository root, run `rm -rf .build-asan` to start from a known
   state (this is safe: it is a new directory this milestone introduces, not
   an existing cache).
2. Run `time ./scripts/check-sanitize` once (this is the "cold" run for the
   new scratch path; expect it to take roughly as long as today's 139
   seconds, since nothing is cached yet).
3. Run `time ./scripts/check-sanitize` a second time immediately after,
   with no source changes in between. This is the "warm" measurement that
   matters: on the *old* (pre-this-milestone) script, a second consecutive
   run still recompiled everything because the interleaved plain
   `swift build`/`swift test` (if you also ran those in between, matching
   real `scripts/check` usage) would have evicted the cache again. With the
   scratch-path change, a second consecutive `check-sanitize` run with
   nothing else touching `.build-asan` in between should be dramatically
   faster (low tens of seconds or less, dominated by the genuine ASan
   runtime overhead on the test bodies rather than a full recompile).
4. To confirm the fix actually addresses the *real* scenario (interleaved
   with the rest of `scripts/check`, not run twice in isolation), run, in
   order: `swift build` (plain, matching `scripts/check:95`), then
   `time ./scripts/check-sanitize`, then `swift build` (plain) again and
   time that second plain build too. Before this milestone, the second
   plain `swift build` would have paid a real recompile because
   `check-sanitize` evicted its cache; after this milestone, the second
   plain `swift build` should be a fast no-op (nothing changed in
   `.build/`, since `check-sanitize` no longer touches it).
5. Record all four timings (step 2, step 3, and the two `swift build` calls
   in step 4) in this plan's `Surprises & Discoveries` section, with the
   exact commands and elapsed times, so a future contributor does not have
   to re-derive them.

### Acceptance for this milestone

- `./scripts/check-sanitize` still exits 0. Confirm it still runs exactly
  `LabanTerminalCoreTests` and `LabptyTests` and no other target by checking
  its output for XCTest's own per-suite summary lines (each test class
  prints a line of the form `Test Suite '<ClassName>' passed` as it
  finishes); grep the run's output for `Test Suite '` and confirm every
  matched class name belongs to one of these two targets, with none from
  any of the other eight test targets.
- A `swift build` (plain, no special flags) immediately before and
  immediately after a `check-sanitize` run no longer shows a full
  recompile the second time (confirm via elapsed time from step 4 above,
  or by adding `--verbose` to the second `swift build` and confirming it
  reports no recompiled modules).
- Disk usage: `.build-asan` will consume additional disk (the ASan build is
  a full separate copy of the instrumented dependency chain, comparable in
  size to the existing plain `.build/arm64-apple-macosx/debug`, which is
  part of the ~4.3GB `.build` directory measured in this worktree at the
  time this plan was written). Confirm the machine has headroom
  (`df -h .` from the repository root) before adopting this change broadly;
  if disk space is tight, note that in `Surprises & Discoveries` and
  consider periodic `rm -rf .build-asan` as an accepted manual reset
  (safe: it only ever holds derived, regeneratable build artifacts).

## Milestone 2: Reorder `coverage-labpty` to run right after `swift test`, before `check-sanitize`

### What exists today

`scripts/coverage-labpty` (repository root; read it in full — it is about
110 lines) computes MC/DC (Modified Condition/Decision Coverage — a coverage
metric stricter than line coverage; it requires showing that each individual
boolean condition inside a decision can independently flip that decision's
outcome, not just that the line was executed) for the `labpty` daemon's C
code. Its steps, in order:

1. `swift build --build-tests` (repository root's package, unfiltered — this
   builds every test target's test binary, not just `LabptyTests`).
2. `swift build --product labpty -Xcc -fprofile-instr-generate -Xcc
   -fcoverage-mapping -Xcc -fcoverage-mcdc -Xcc -fprofile-continuous
   -Xlinker <profile-runtime-path>` — rebuilds the `labpty` executable with
   MC/DC instrumentation flags. Because these are global `-Xcc` flags on the
   `swift build` command line (not scoped to just the `Labpty` target),
   they also recompile `LabanTerminalCore`'s 18 C files, since `Labpty`
   depends on `LabanTerminalCore` (`Package.swift`, `Labpty` target's
   `dependencies:`). This is called out explicitly in the script's own
   comment: "Instrument the daemon LAST so `--skip-build` runs the tests
   against it. The next ordinary build restores an un-instrumented binary,
   so the normal build is never contaminated."
3. `LLVM_PROFILE_FILE=... swift test --skip-build --filter LabptyTests` —
   re-runs the `LabptyTests` suite (which SwiftPM's `swift test` at
   `scripts/check:96` already ran once, uninstrumented, earlier in the same
   `scripts/check` invocation) against the now-instrumented `labpty` binary,
   to collect MC/DC profile data from real integration-test traffic.
4. Four standalone C harnesses under `proofs/labpty/coverage/` (`registry_cov.c`,
   `main_cov.c`, `signal_cov.c`, `poll_cov.c`; together about 1,350 lines) are
   compiled directly with `cc -O0 -fprofile-instr-generate -fcoverage-mapping
   -fcoverage-mcdc` (bypassing SwiftPM entirely) and run to exercise decision
   branches the timing-dependent integration suite cannot reliably reach
   (NULL ids, dead-child states, out-of-range signal numbers). This step is
   fast (a handful of small, `-O0`, single-file C compiles) and is not a
   target for optimization in this milestone.
5. All the `.profraw` profile files from steps 3 and 4 are merged with
   `xcrun llvm-profdata merge`, and `xcrun llvm-cov report --show-mcdc-summary`
   produces the final MC/DC percentage, optionally checked against a
   `--check N` floor (a ratchet: coverage may only go up over time, never
   down, matching this repository's regression-prevention philosophy).

In `scripts/check`'s current stage order (`swift build` at line 95, `swift
test` at 96, `check-sanitize` at 97, `smoke-runtime` at 98, `test-e2e` at 99,
`coverage-labpty --check 45` at 109, gated behind an `if` that checks for the
darwin profile runtime), `coverage-labpty` runs *last*, after every one of
the other three heavy stages has already touched the shared plain `.build`
directory with incompatible flags: `check-sanitize` builds
`Labpty`/`LabanTerminalCore` with `-sanitize address` (Milestone 1), and
`smoke-runtime`'s underlying `./scripts/build-app` does its own unqualified
`swift build` of every product in the package (including `labpty`, per
`scripts/build-app:102`'s `for product in LabanApp laban-agent laband labpty
laban` loop) with `--disable-index-store` plus four prefix-map flags
(Milestone 3) — so by the time `coverage-labpty` runs, both preceding heavy
stages have already left the `Labpty`/`LabanTerminalCore` chain in a flag
state incompatible with `coverage-labpty`'s own instrumentation flags. By
the time `coverage-labpty`'s own step 1 (`swift build --build-tests`,
unfiltered) runs, the build state left behind is stale for the
`Labpty`/`LabanTerminalCore` chain specifically, forcing step 1 to do a
real, avoidable recompile of that chain (plausibly 50-65 seconds of the
stage's 126-second baseline, by far the largest single contributor, with
step 3's `swift test --skip-build --filter LabptyTests` re-run itself
contributing another meaningful chunk, plausibly 25-40 seconds, that is not
eliminated by this milestone but is inherent to the ratchet's design — see
the "why not merge into the main test run" note below). All of the builds
discussed in this paragraph are debug-configuration builds; none of this
plan's heavy stages use a release build.

### What to change

Move the `coverage-labpty` invocation in `scripts/check` to run immediately
after `swift test` (line 96) and before `check-sanitize` (currently line 97).
Concretely, in `scripts/check`, take the block:

```sh
  # MC/DC ratchet over the daemon's un-proven decision code, plus the
  # assertion gates in proofs/labpty/coverage/*_cov.c (e.g. signal_cov's L9
  # no-out-of-range-signo-reaches-kill proof). Runs LAST: it leaves an
  # instrumented labpty that the next ordinary build restores. Gating it here
  # is what turns a stale coverage assertion — like the main_cov drift the
  # handle_write hung-up-child fix introduced — into a check failure instead of
  # silent rot. macOS-only (needs the darwin profile runtime); skips gracefully
  # elsewhere, like check-specs skips without the TLA+ jar.
  if [ -f "$(cc -print-resource-dir)/lib/darwin/libclang_rt.profile_osx.a" ]; then
    ./scripts/coverage-labpty --check 45
  else
    printf 'check: skipping coverage-labpty (darwin profile runtime not found)\n'
  fi
```

and move it to run directly after the `swift test` line and before
`./scripts/check-sanitize`, updating the comment's "Runs LAST" claim since it
will no longer be literally last (rewrite it to explain the *new* reason for
its position: it runs right after the plain `swift test` so its own
`swift build --build-tests` reuses that warm, matching cache instead of a
stale one left by a later, flag-incompatible stage; it still runs before
`check-sanitize`/`smoke-runtime`/`test-e2e` so the ASan/`build-app` debug
builds those stages do afterward are unaffected by `coverage-labpty`'s own
instrumentation flags, preserving the "next ordinary build restores an
un-instrumented binary" guarantee for whichever stage happens to run right
after it now). The resulting order becomes: `swift build` → `swift test` →
`coverage-labpty --check 45` → `check-sanitize` → `smoke-runtime` →
`test-e2e`.

This reordering does not eliminate the recompile cost this milestone
targets, it relocates it: whichever stage now runs immediately after
`coverage-labpty` (`check-sanitize` in the new order) is the one that pays
the cost of rebuilding `Labpty`/`LabanTerminalCore` out of
`coverage-labpty`'s `-Xcc` MC/DC-instrumented state back to its own flags,
in place of `check-sanitize` previously paying that cost against a plain,
uninstrumented state. This is still a net win for `coverage-labpty` itself
(its own step 1 no longer pays a recompile it used to), and Milestone 1
already gives `check-sanitize` its own `--scratch-path`, so once Milestones
1 and 2 are both in place `check-sanitize` is not actually affected either
way. But before Milestone 1 lands, or if you are validating Milestone 2 in
isolation, expect to see `check-sanitize`'s own timing get *slightly worse*
immediately after this reorder (it now recompiles away MC/DC flags instead
of ASan-colliding with a plain build) even though `coverage-labpty` itself
gets faster; record both stages' before/after timings together in
`Surprises & Discoveries` so this cost-shift is visible, not just
`coverage-labpty`'s own improvement.

Do not attempt to merge `coverage-labpty`'s step 3 (`swift test --skip-build
--filter LabptyTests`) into the main `swift test` run at line 96 to avoid the
"re-run the same suite twice" cost. The script's own design comment argues
against this, and the argument holds: baking MC/DC instrumentation into the
primary correctness gate risks skewing the daemon's already-timing-sensitive
behavior (the project's own coverage documentation, `docs/quality/labpty-mcdc-coverage.md`,
records run-to-run MC/DC jitter of roughly 18.4% to 19.2% from timing
variance alone) into the main pass/fail signal developers rely on for every
other test in the suite. Keeping the instrumented run isolated, as it is
today, is the safer design; this milestone only changes *when* that isolated
run happens, not its isolation from the main suite.

### How to measure this milestone

1. Do not combine this measurement with Milestone 1's `.build-asan` changes
   in the same timing run at first; measure each milestone independently so
   you can attribute the time savings correctly, then do one final combined
   measurement once both are in place (see the plan's overall Validation
   section).
2. From a clean, freshly-built state (`swift build && swift test`, matching
   what a real `scripts/check` run does immediately before this stage), run
   `time ./scripts/coverage-labpty --check 45` and compare against the
   126-second baseline. Expect a meaningful reduction, concentrated in step
   1's `swift build --build-tests` now finding a warm, compatible cache
   instead of a stale one.
3. Confirm the MC/DC percentage reported is unchanged (or only naturally
   different) from a baseline run captured before this change (rerun the
   old stage order once, note the reported `daemon MC/DC = N%` line, then
   compare against the new order's reported percentage; they should match,
   since this milestone changes scheduling only, not what code runs or how
   coverage is measured).

### Acceptance for this milestone

- `./scripts/coverage-labpty --check 45` still exits 0 and reports the same
  MC/DC percentage as before this change (moving it earlier must not change
  what gets measured, only when).
- The full `scripts/check` stage order, after this milestone (and
  independent of whether Milestone 1 has landed), is: `swift build` →
  `swift test` → `coverage-labpty --check 45` → `check-sanitize` →
  `smoke-runtime` → `test-e2e`. Grep `scripts/check` to confirm the
  `coverage-labpty` block's lines now appear before the
  `./scripts/check-sanitize` line.
- A subsequent `check-sanitize` run (right after the relocated
  `coverage-labpty`) still passes; it is expected to still pay its own full
  recompile cost (that is exactly what Milestone 1 addresses separately) but
  must not fail outright due to leftover instrumented artifacts from
  `coverage-labpty`. If it does fail in a way that looks related to stale
  instrumented objects, note this in `Surprises & Discoveries` — this would
  indicate the "next ordinary build restores an un-instrumented binary"
  comment's guarantee is weaker than documented and needs its own follow-up
  investigation (out of scope to fix here, but must be reported, not
  silently worked around).

## Milestone 3: Give `smoke-runtime`'s underlying `build-app` build its own scratch path, and drop `smoke-runtime`'s now-redundant first build

### What exists today

`scripts/smoke-runtime` (repository root) starts with:

```sh
swift build --product LabanApp --product laban-agent
./scripts/build-app
```

On this toolchain (Swift 6.3.3), SwiftPM's `--product` flag is last-wins on a
single command line — passing it twice, as this line does, only builds
`laban-agent`; the `--product LabanApp` portion is silently ignored. (This is
already documented in this repository's own `execplans/active/faster-install-builds.md`,
commit `3600855f`, which discovered the same last-wins behavior while working
on `scripts/build-app` itself — read that file's Decision Log if you want the
original discovery context; it is incorporated by reference here rather than
repeated in full.)

`./scripts/build-app` (repository root; read it in full — it is about 335
lines) then does its own unqualified `swift build -c "$build_config"
--disable-index-store $prefix_map_flags` (around line 76), where
`$build_config` defaults to `debug` and `$prefix_map_flags` expands to
`-Xswiftc -debug-prefix-map -Xswiftc <repo_root>=. -Xswiftc -file-prefix-map
-Xswiftc <repo_root>=. -Xcc -fdebug-prefix-map=<repo_root>=. -Xcc
-ffile-prefix-map=<repo_root>=.` (declared around lines 59-63; these flags
strip the local build machine's absolute path out of debug symbols and
embedded strings, so a built bundle does not leak a developer's home
directory layout). This unqualified build produces every product the package
defines, including `laban-agent`, at `.build/$build_config/laban-agent` (the
same path `smoke-runtime`'s own `AGENT_BIN=".build/debug/laban-agent"`
variable points at).

Because `build-app`'s flags (`--disable-index-store` plus the four
prefix-map flags) differ from `smoke-runtime`'s own preceding plain
`swift build --product LabanApp --product laban-agent` line (which passes
none of those flags), and because — per the SwiftPM directory-keying
behavior explained in this plan's Context and Orientation section — a flag
change forces recompilation even though both builds target the same
`debug` configuration, `smoke-runtime`'s own first `swift build` line is (a)
producing output that `build-app`'s differently-flagged build immediately
invalidates anyway, and (b) therefore pure wasted work: whatever it built is
not what ends up at `AGENT_BIN` after `build-app` finishes; `build-app`'s own
unqualified build is what actually lands there. This repository's own
`execplans/active/faster-install-builds.md` (Decision Log) recorded a
related, but distinct, measurement worth knowing as background: on a build
whose cache was already keyed with `--disable-index-store` present, adding
or removing just that one flag between two otherwise-identical builds moved
an unqualified release build between 29.04 seconds and 5.20 seconds. That
measurement was about index-store work being skipped on an otherwise-warm
cache, not a direct measurement of the *recompile* cost this milestone's
`smoke-runtime`/`build-app` flag mismatch causes; do not cite it as if it
were the same number. Instead, measure this milestone's actual before/after
timings yourself (see "How to measure this milestone" below) and record
them in `Surprises & Discoveries` rather than relying on this estimate.

Separately: this investigation traced `smoke-runtime`'s step 7 (the AppKit
smoke launch, running the built `.app`'s binary directly with `LABAN_SMOKE=1`
and a 10-second-timeout background watchdog) line by line and confirmed it
does *not* block for the full 10 seconds on the happy path. The script's
`wait "$_pid"` waits only on the smoked app's own process id and returns as
soon as that process exits (which, per the script's own comment, happens in
well under a second since `LABAN_SMOKE=1` makes the app print a stable line
and exit without entering its normal event loop); only after that does the
script kill and reap the still-sleeping watchdog subprocess. The 10-second
sleep is a pure safety net against a real hang and is not a target for this
plan; do not change step 7.

### What to change

Two changes, both in `scripts/smoke-runtime`:

1. Delete the now-redundant first line, `swift build --product LabanApp
   --product laban-agent`. It is fully superseded by `./scripts/build-app`'s
   own internal build, which produces every binary `smoke-runtime` needs
   (including `laban-agent` at the exact `AGENT_BIN` path) at a path
   `build-app` itself already guarantees exists (`build-app` has its own
   "assert every bundled product actually built" check around line 92-108
   of that script, which already covers `laban-agent` in its `for product in
   LabanApp laban-agent laband labpty laban` loop — so removing
   `smoke-runtime`'s own separate build does not remove any safety check,
   it removes a genuinely redundant one).

2. Give `build-app`'s internal build its own scratch path so it, like
   `check-sanitize` in Milestone 1, stops evicting (and being evicted by)
   the plain debug build's cache on repeated local runs. `scripts/build-app`
   does not currently accept a `--scratch-path`-style argument of its own;
   add one. Read the top of `scripts/build-app` (the argument-parsing loop
   at lines 24-35 at the time this plan was written) closely: it is a
   `for arg in "$@"; do case "$arg" in ... esac; done` loop over single
   tokens, with an explicit `*) printf 'build-app: unknown argument: %s\n'
   ...; exit 2 ;;` fallback for anything unrecognized. That loop structure
   cannot consume a flag and its value as two separate tokens (a bare
   `--scratch-path` token would fall into the same iteration as any value
   that follows it, and that value token would itself then hit the
   `unknown argument` fallback on the *next* iteration and exit 2). Use a
   single self-contained token instead: recognize `--scratch-path=<path>`
   (flag and value joined with `=`, matching the shape `--profile` already
   uses as a bare no-value flag in the same loop), for example by adding a
   case arm `--scratch-path=*) scratch_path=${arg#--scratch-path=} ;;`
   alongside the existing `--profile)` arm, with `scratch_path` declared
   and defaulting to empty before the loop starts (meaning "use SwiftPM's
   own default `.build`, unchanged from today"). When `scratch_path` is
   non-empty, pass `--scratch-path "$scratch_path"` through to every
   `swift build` invocation inside `scripts/build-app` (there are two call
   sites: the main build around line 76, and the fallback
   `--show-bin-path` call around line 89 — both must receive the same
   `--scratch-path` value, and the `bin=".build/$build_config"` /
   `app_bundle=".build/laban/Laban.app"` path variables used later in the
   script must be updated to be relative to `$scratch_path` instead of the
   hardcoded `.build` when `scratch_path` is set, since SwiftPM's
   `--scratch-path` moves the *entire* scratch directory, not just the
   `debug`/`release` subdirectory). Update `scripts/smoke-runtime` to call
   `./scripts/build-app --scratch-path=.build-smoke` instead of bare
   `./scripts/build-app`.

   Keep `scripts/build-app`'s existing default behavior (no `--scratch-path`
   argument given) writing to plain `.build`, unchanged, since `build-app`
   is also invoked directly by developers outside of `scripts/check` (for
   example via `scripts/install-app`, referenced in `execplans/active/faster-install-builds.md`)
   where the current default-`.build` behavior is correct and should not
   change.

3. Add `.build-smoke/` to the repository's root `.gitignore`, alongside the
   `.build-asan/` entry from Milestone 1.

### How to measure this milestone

1. From the repository root, run `rm -rf .build-smoke` to start clean.
2. Run `swift build` (plain, matching `scripts/check:95`) once so the
   plain debug cache is warm, matching real `scripts/check` conditions.
3. Run `time ./scripts/smoke-runtime` (cold `.build-smoke`; expect this
   run to take roughly as long as today's 53-second baseline, since nothing
   is cached in `.build-smoke` yet).
4. Run `time ./scripts/smoke-runtime` a second time immediately after, with
   no source changes in between. Expect a meaningful reduction versus the
   first run, since `build-app`'s internal build now finds its own warm,
   flag-consistent cache in `.build-smoke` instead of colliding with
   `.build`'s plain-build state.
5. Confirm the plain `swift build` from step 2, if rerun after step 3 or 4,
   is now a fast no-op (nothing in `.build/` was touched by
   `smoke-runtime` anymore, since both its build calls now target
   `.build-smoke`).

### Acceptance for this milestone

- `./scripts/smoke-runtime` still exits 0 and prints `smoke-runtime passed`
  as its last line, matching today's behavior.
- `./scripts/smoke-runtime` still performs every check it does today
  (headless fixture screenshot + `foundExpectedText`, `Info.plist` lint,
  renderer resource bundle presence, binary executable bit, codesign
  verification, AppKit smoke launch). Every place in `scripts/smoke-runtime`
  that references `.build` must be updated to point into `.build-smoke`
  instead (or wherever `build-app --scratch-path` actually wrote its output
  — confirm by reading `build-app`'s own `bin=`/`app_bundle=` variables
  after your change, since those are the source of truth for where the
  bundle actually lands). This is not limited to the `AGENT_BIN`/`APP_BIN`/
  `PLIST` variables declared near the top of the script (lines 20-22 at the
  time this plan was written): `RES_BUNDLE` (around line 47) and the
  `codesign --verify` call (around lines 54-55) each hardcode the literal
  path `.build/laban/Laban.app` inline rather than referencing a variable,
  and both must be updated too. Grep `scripts/smoke-runtime` for every
  literal occurrence of `.build` after making this change and confirm none
  remain pointing at the old plain `.build` path; missing one of these means
  the smoke stage would silently check a stale bundle left over in `.build`
  from a previous run instead of the one `build-app` just produced in
  `.build-smoke`, which would make this stage pass vacuously instead of
  actually verifying the current build.
- `scripts/build-app`, called with no arguments at all (its original,
  default invocation, as used by any other caller such as
  `scripts/install-app`), is byte-for-byte unchanged in behavior: no new
  required argument, output still lands in plain `.build`/`.build/laban`.
  Confirm by running `./scripts/build-app` (no flags) once after your
  change and checking it still produces `.build/laban/Laban.app` as before.

## Milestone 4: Investigate cross-target `swift test` process-level parallelism (higher risk; do last, and only if Milestones 1-3 do not deliver enough)

This milestone is the highest-risk, highest-potential-payoff item in this
plan, targeting the single largest stage (`swift test`, 357 seconds). It
is listed last deliberately: attempt it only after Milestones 1-3 are
complete, measured, and merged, since it is more invasive and carries real
correctness risk if rushed. If you are short on time or confidence, stop
after Milestone 3 and hand this milestone to a follow-up ExecPlan instead of
rushing it.

### What exists today, and the real constraint on using `--parallel`

`scripts/check:96` runs plain `swift test`, with no `--parallel` flag
(`swift test --help` on this toolchain confirms `--parallel/--no-parallel`
defaults to `--no-parallel`).

On macOS, when a package defines multiple XCTest test targets (this
package's ten test targets are plain `.testTarget` entries using XCTest, not
the newer `swift-testing` framework), SwiftPM merges every test target into
one single, unified `.xctest` bundle rather than building one bundle per
target. Confirm this yourself: after any `swift test` or `swift build
--build-tests` in this package, `find .build -iname '*.xctest'` finds
exactly one bundle, `.build/arm64-apple-macosx/debug/LabanPackageTests.xctest`
— not ten. When `--parallel` is given, SwiftPM's `ParallelTestRunner`
discovers every individual test method from that one merged bundle (from
all ten targets at once) and enqueues them all into a single shared
work-stealing queue; worker threads then dequeue individual test methods
and each worker re-execs the built `.xctest` bundle as a **separate OS
process**, filtered to run just that one test method. This means
`--parallel` genuinely can dispatch test methods from *different* test
targets (for example `LabandTests` and `LabanCLITests`) concurrently with
each other as separate OS processes — it is not scoped to one target's
bundle. (Verified via SwiftPM's own source: `ParallelTestRunner.run`
enqueues every discovered `UnitTest` — the unit of one test method — before
any worker begins dequeuing, with no per-target grouping in that queue.)

So a blanket `swift test --parallel` at `scripts/check:96` is not
*ineffective*, the way an earlier draft of this plan assumed — it is
*unsafe*, for a more specific and more serious reason: because every
worker's re-exec'd process shares the same real `$HOME`, and because
`UserDefaults.standard` (confirmed in this repository's own prior
investigation, `execplans/active/faster-full-test-suite.md`) resolves to a
real on-disk preferences file at `~/Library/Preferences/com.apple.dt.xctest.tool.plist`
shared by every one of those concurrently-running processes, any two test
methods that happen to be scheduled onto different workers at the same
moment and that both touch `UserDefaults.standard` can race on that one
file — regardless of which test targets they belong to. This is a strictly
larger version of the same hazard this repository already found and fixed
once in sequential execution (`execplans/active/faster-full-test-suite.md`):
under `--parallel`, the contamination window is not "one crashed test
leaves a stale key for a later test in the same process," it is "two tests
in two different concurrently-running processes read/write the same key at
the same time," which is harder to reproduce and debug. `NSApplication.shared`
is not a `--parallel` hazard by this same mechanism, since AppKit's shared
instance is one-per-process and each worker gets a fresh re-exec'd process;
but `LabanAppTests`' AppKit-touching tests may still have other unlisted
real-machine side effects (window server registration, synthetic keyboard
event dispatch) that are not safe to run at the same wall-clock moment as
other GUI-touching tests, which is a softer, less-quantified risk worth
treating with the same caution as the confirmed `UserDefaults` hazard
rather than assuming away.

`Package.swift`'s `targets:` array defines ten `.testTarget` entries
(`grep -n '.testTarget(' Package.swift` finds them at lines 159, 163, 168,
172, 176, 180, 184, 188, 192, 197 at the time of this investigation — always
re-verify current line numbers before editing, since other work may shift
them):
`LabanTerminalCoreTests`, `LabanCoreTests`,
`LabanRendererTests`, `LabanDebugTests`, `LabanControlTests`,
`LabanCLITests`, `LabandTests`, `LabptyTests`, `LabanAppTests`,
`LabanAgentTests`. A grep-based audit of every file under each target's
`Tests/<TargetName>/` directory for `UserDefaults.standard`,
`NSApplication.shared`/`NSApp`, `setenv`/`unsetenv`/`putenv`/
`ProcessInfo...environment` mutation, and shared `Sources/`-side mutable
global state (`static var`, `nonisolated(unsafe) static var`) produced the
classification below. Re-derive it yourself with the same greps before
acting on it (for example: `grep -rn 'UserDefaults.standard\|NSApplication.shared\|NSApp\b' Tests/<TargetName>Tests/`
for each of the ten targets), since source files change over time and this
table can go stale; do not rely on the table alone without re-running the
greps:

| Target | Classification | Why |
| --- | --- | --- |
| `LabandTests` | Safe to isolate | No `UserDefaults`/`NSApp`/`setenv` writes found. |
| `LabptyTests` | Safe to isolate | No `UserDefaults`/`NSApp`/`setenv` writes found. |
| `LabanAgentTests` | Safe to isolate | No `UserDefaults`/`NSApp`/`setenv` writes found. |
| `LabanControlTests` | Must stay sequential | Initially classified as safe because it only mutates process-local env and static vars. In practice, `LabanControlServer.start()` with no explicit socket path binds `ControlAdvertisement.directory() / control.sock`, which was a fixed path under XCTest once `XCTestConfigurationFilePath` detection was repaired. Multiple concurrent `LabanControlServer` instances in separate worker processes would still bind the same per-process directory, but the same xctest process running `LabanControlTests` sequentially also uses the same fixed path across test methods; running it in the sequential group with the other UserDefaults/AppKit-touching targets is the conservative, passing choice. |
| `LabanCLITests` | Safe to isolate as its own process | Mutates `setenv("LABAN_SESSION_ATTACH", ...)`; per-process, does not leak across separate OS processes. |
| `LabanTerminalCoreTests` | Safe to isolate as its own process | Mutates generic env vars via `setenv`; per-process, does not leak across separate OS processes. |
| `LabanCoreTests` | Must stay isolated from the group below, OR needs source changes | Writes `UserDefaults.standard` keys `LabanCursorStyle`, `LabanCursorBlink`, `LabanScrollMode` — the same key names other targets below also write to the same on-disk domain file. |
| `LabanRendererTests` | Must stay isolated from the group below, OR needs source changes | Writes `UserDefaults.standard` keys including `LabanVectorTextWeight` (the exact key already implicated in the cross-test contamination bug documented and fixed in `execplans/active/faster-full-test-suite.md`), `LabanCJKFontPreference`, `LabanEmojiRenderingMode`. |
| `LabanDebugTests` | Must stay isolated from the group below, OR needs source changes | Writes `UserDefaults.standard` keys `LabanCursorStyle`, `LabanCursorBlink`, `LabanTerminalIdentity`, `LabanFontSize`, `LabanEmojiRenderingMode`, `LabanGraphemeWidthMode`, `LabanCJKFontPreference` — overlapping the two targets above. |
| `LabanAppTests` | Must stay isolated from the group above, AND is the one target that genuinely launches real `NSApplication.shared` state | Writes overlapping `UserDefaults.standard` keys (`RendererSelection.defaultsKey`, `ScrollSettings.modeKey`, `AttentionNotificationSettings.defaultsKey`, `CursorSettings.*`, `GraphemeWidthSettings.defaultsKey`) AND directly touches `NSApplication.shared` (for example `Tests/LabanAppTests/AppDelegateThemeTests.swift`, which sets `.appearance` on the shared app, and `Tests/LabanAppTests/TerminalKeyInputTests.swift`, which dispatches real key events through the shared app). |

The four targets in the last group (`LabanCoreTests`, `LabanRendererTests`,
`LabanDebugTests`, `LabanAppTests`) collectively write overlapping
`UserDefaults.standard` keys to the *same on-disk file* whenever they run
under the same `$HOME`. `LabanControlTests` was added to the sequential group
because `LabanControlServer.start()` with no explicit socket path binds a
fixed `ControlAdvertisement.directory() / control.sock` path. Running these
five targets as separate concurrent OS processes without addressing the
`UserDefaults`/`NSApplication`/`NSApplication.shared` or fixed-socket hazards
would reintroduce cross-test contamination. Do not attempt to parallelize
these five targets against each other without first solving those hazards.

### A concrete, low-risk mechanism: split into two `swift test` invocations, not per-target processes

Because `--parallel` already dispatches every discovered test method from
the single merged `.xctest` bundle into one shared work queue, the fix does
not require spawning one OS process per test target with a hand-redirected
`$HOME` (an earlier draft of this plan proposed exactly that, before this
investigation corrected the premise above — do not build that; it is more
complex than necessary and this simpler design supersedes it). Instead,
split `scripts/check:96`'s single `swift test` call into exactly two
invocations:

1. **Parallel-safe invocation**: `swift test --parallel --filter
   'LabandTests|LabptyTests|LabanAgentTests|LabanCLITests|LabanTerminalCoreTests'`
   — covering the five targets confirmed in the table above to touch neither
   `UserDefaults.standard` nor `NSApplication.shared` and to have no fixed
   control socket path conflicts. Since `--parallel`'s work queue in this
   one invocation only ever contains test methods from these five targets,
   there is no cross-target `UserDefaults` collision possible.
2. **Sequential invocation, unchanged from today's behavior**: `swift test
   --filter 'LabanCoreTests|LabanRendererTests|LabanDebugTests|LabanAppTests|LabanControlTests'`
   (no `--parallel`) — covering the five targets that touch
   `UserDefaults.standard`/`NSApplication.shared` or bind a fixed control
   socket path. This invocation must behave identically to how these targets
   run today: same relative order, same single process, no parallelism. Do not
   add `--parallel` to this invocation, and do not attempt to further split it
   without first solving the `UserDefaults`-key-overlap and `NSApplication.shared`
   hazards documented above.

Both invocations use the *same* `.build` scratch directory (no new
`--scratch-path` needed for this milestone): both are plain debug builds
with identical compiler flags, so they do not evict each other's cache the
way an ASan or MC/DC-instrumented build would (see Milestones 1-3). Do not
run these two invocations concurrently with each other; run them
sequentially, one after the other, in either order. (Running them
concurrently would mean two separate `swift build`/`swift test` processes
touching the same `.build` directory's build-plan lock at once, which is
the exact hazard the "never run two builds concurrently against the same
`.build`" rule in this plan's Purpose section warns about — the payoff here
comes entirely from `--parallel`'s intra-invocation speedup on the six safe
targets, not from running the two invocations against each other.)

### What to change

1. Do not edit `Package.swift` or the test targets themselves for this
   milestone.
2. In `scripts/check`, replace line 96's single `swift test` with the two
   invocations above, run one after the other. Consider extracting this
   into its own script (for example `scripts/test-split`), called from
   `scripts/check`, so the two-invocation logic has a home outside the
   top-level driver, following this repository's existing convention of one
   focused script per concern (visible throughout `scripts/`).
3. If, after measuring (see below), the six-target parallel-safe group's
   `--parallel` run does not meaningfully beat its own sequential baseline
   (small test counts can have too little work to amortize worker startup
   cost), do not force the split; report that finding and close this
   milestone as "investigated, not adopted" per its Acceptance criteria
   below.

### How to measure this milestone

1. Measure the five-target parallel-safe group's sequential baseline first:
   `time swift test --filter
   'LabandTests|LabptyTests|LabanAgentTests|LabanCLITests|LabanTerminalCoreTests'`
   (no `--parallel`).
2. Measure the same five-target filter with `--parallel` added:
   `time swift test --parallel --filter
   'LabandTests|LabptyTests|LabanAgentTests|LabanCLITests|LabanTerminalCoreTests'`.
   Compare against step 1's baseline.
3. Measure the five-target sequential group unchanged (no `--parallel`):
   `time swift test --filter
   'LabanCoreTests|LabanRendererTests|LabanDebugTests|LabanAppTests|LabanControlTests'`.
   This group's time is expected to be unaffected by this milestone; record
   it anyway, since it now dominates the 357-second total and sets the
   floor for what this milestone alone can save.
4. Sum step 2 and step 3's times and compare against the original combined
   357-second baseline for a single plain `swift test` covering all ten
   targets.

### Acceptance for this milestone

- Every test that runs today still runs exactly once, with the same
  pass/fail result, under the new two-invocation arrangement. (Do not
  reduce coverage to gain speed — if any of the six "parallel-safe" targets
  turns out not to be safe once you spot-check it yourself, per the warning
  above, move it into the four-target sequential invocation instead of
  guessing.)
- Three consecutive full runs of the new two-invocation arrangement show no
  new flakiness versus a baseline of three consecutive runs of today's
  plain `swift test` (capture both sets of three runs' pass/fail results in
  `Surprises & Discoveries` for comparison).
- If, after honest measurement, this milestone's wall-clock savings are
  small relative to its complexity and flakiness risk (for example, because
  the four-target sequential group alone still dominates the total), record
  that finding plainly in `Surprises & Discoveries` and do not merge a
  change that adds risk for negligible benefit — reverting to plain
  sequential `swift test` and closing this milestone as "investigated, not
  adopted" is an acceptable, honest outcome.

## Progress

- [x] Milestone 1: `check-sanitize` gets its own `--scratch-path`
      (`.build-asan`); `.gitignore` updated.
- [x] Milestone 2: `coverage-labpty` reordered to run right after
      `swift test`, before `check-sanitize`; MC/DC ratchet unchanged.
- [x] Milestone 3: `smoke-runtime`'s redundant first `swift build` removed;
      `build-app` gains an optional `--scratch-path` argument; `smoke-runtime`
      uses `.build-smoke`; `.gitignore` updated; default behavior unchanged.
- [x] Milestone 4 (optional, highest risk, do last): splitting `swift test`
      into a `--parallel` invocation for the five safe targets plus a
      sequential invocation for the remaining five (including
      `LabanControlTests` after `LabanControlServer` was found to bind a
      fixed control socket path); adopted via `scripts/test-split`.
- [x] Final: full `./scripts/check` run, from a warm `.build` state, timed
      end-to-end and compared against the 692-second baseline; recorded in
      `Surprises & Discoveries`.

## Decision Log

- Decision: scope this plan to only the four stages that account for 97% of
  total `scripts/check` time (`swift-test`, `check-sanitize`,
  `coverage-labpty`, `smoke-runtime`), and explicitly exclude the small
  remaining stages (boundaries, docs, anchors, specs, cbmc, trace, model
  coverage, fuzzing, lint, dependencies) that sum to about 17 seconds
  combined.
  Rationale: a prior optimization pass (Fable's automated analysis) proposed
  several small-stage changes (reordering `LabanControlGen --check`, batching
  `jq empty` invocations, deduping `check-model-coverage` against
  `check-trace`); one of those (`jq` batching) was implemented and merged
  (`4747bcf1`) since it was essentially free, but pursuing the rest against
  a combined 17-second budget was judged not worth the churn, especially
  given each verification cycle risks a slow full-gate rerun. Concentrating
  effort on the four dominant stages is where real wall-clock savings exist.
  Date/Author: 2026-07-12 / (prior session, Sonnet 5 + Fable)

- Decision: for `swift test` (Milestone 4), split into two `swift test`
  invocations by `UserDefaults`/`NSApplication.shared` safety (one with
  `--parallel` for six confirmed-safe targets, one unchanged/sequential for
  four confirmed-unsafe targets), rather than one-process-per-target with
  `--scratch-path`/`HOME` redirection.
  Rationale: on this toolchain, `swift test` merges every XCTest test target
  in the package into one single `.xctest` bundle
  (`.build/arm64-apple-macosx/debug/LabanPackageTests.xctest`), confirmed by
  `find .build -iname '*.xctest'` finding exactly one bundle despite ten
  `.testTarget` declarations, and confirmed against SwiftPM's own source via
  DeepWiki (`ParallelTestRunner` enqueues every discovered unit test from
  that one bundle into a single shared work-stealing queue with no
  per-target grouping). This means `--parallel` already dispatches test
  methods from different targets concurrently as separate OS processes —
  the earlier working theory that `--parallel` was scoped to a single
  target's bundle was wrong and has been corrected. Given that, filtering
  `swift test --parallel` down to just the six targets confirmed free of
  `UserDefaults`/`NSApplication.shared` mutation (via the same source-level
  audit that already found `LabanCoreTests`, `LabanRendererTests`,
  `LabanDebugTests`, `LabanAppTests` writing overlapping `UserDefaults` keys,
  including the exact key (`LabanVectorTextWeight`) already implicated in a
  real, previously-fixed cross-test contamination bug,
  `execplans/active/faster-full-test-suite.md`) is sufficient on its own;
  it needs no per-target `--scratch-path` (all ten targets share the same
  plain debug build, so there is no flag-mismatch cache-eviction hazard
  here the way there is for ASan/MC/DC builds in Milestones 1-3) and no
  `HOME` redirection (the six safe targets do not touch `UserDefaults` at
  all, so there is no on-disk file to collide on). The four unsafe targets
  keep running exactly as they do today, in one sequential, non-parallel
  invocation.
  Date/Author: 2026-07-12 / (this session, Sonnet 5 research agents;
  premise corrected during independent review by a Fable reviewer agent,
  same date)

## Surprises & Discoveries

- Observation: `.build/arm64-apple-macosx/debug` was found empty (0 bytes
  in its `LabanPackageTests.xctest`, confirmed via `otool -L` showing no
  ASan dylib linked) at the time this plan was written, despite
  `check-sanitize` having run earlier in this worktree's history — direct,
  concrete evidence that a sanitizer build genuinely evicts/overwrites the
  plain debug build's cache in place, rather than coexisting alongside it,
  confirming Milestone 1's premise is a real, not hypothetical, problem.
  Evidence: `find .build -maxdepth 3 -type d` showed only
  `.build/arm64-apple-macosx/debug` as the sole per-configuration directory
  (no separate sanitizer-specific subdirectory exists on this SwiftPM
  version); `du -sh .build` reported 4.3G total at the time of writing, and
  `df -h .` showed 37Gi free (96% used) on the filesystem backing this
  worktree — worth re-checking before adopting Milestone 1 and 3's new
  scratch directories broadly, since each new `--scratch-path` plausibly
  adds a multi-gigabyte, largely-duplicate copy of the shared dependency
  chain's build artifacts.

- Observation: `scripts/build-app`'s `--product LabanApp` flag, when passed
  alongside a second `--product laban-agent` on the same `swift build`
  command line (as `scripts/smoke-runtime`'s first line currently does), is
  silently ignored due to SwiftPM's last-wins behavior for repeated
  `--product` flags on this toolchain (Swift 6.3.3) — this was already
  independently discovered and documented once before, in
  `execplans/active/faster-install-builds.md` (commit `3600855f`), while
  working on a different script (`scripts/build-app` itself). This plan's
  Milestone 3 is the first place this same behavior is confirmed to also
  make `smoke-runtime`'s specific invocation redundant, not just
  surprising.
  Evidence: `execplans/active/faster-install-builds.md`, Decision Log entry
  for commit `3600855f`.

- Observation: `swift test` on the command line does not set
  `XCTestConfigurationFilePath`, and `ControlAdvertisement.directory()`
  relied on that variable to detect a test run and avoid binding the
  production control socket at `~/Library/Application Support/Laban`. When
  a developer's own `Laban.app` was running, this caused
  `ControlDirectorySecurityError.socketPathInUse` failures for any test
  starting `LabanControlServer` with its default socket path. It also
  exposed a related test fragility: `ControlAdvertisement.directory()`
  returned a `FileManager.default.temporaryDirectory` path long enough to
  wrap inside the 80-column terminal used by
  `AppSessionCoordinatorTests/testDaemonAgentAttachedSessionRedeemsC14FromChildEnv`,
  breaking that test's string assertion. The fix was to detect the test
  runner by `processName == "xctest"` and `CommandLine.arguments` containing
  `-XCTest`, and to use a short `/tmp/laban-xctest-<uid>-<pid>` directory
  (created 0700) for XCTest control sockets.
  Evidence: `ControlAdvertisement.directory()` now uses multiple XCTest
  signals, and `ControlDirectorySecurity.prepareSocketPath` preserves
  0700/permission checks while tolerating `/tmp` as a symlink on macOS.

- Final full-gate timings (warm `.build` state, three consecutive runs):
  - Run 1: `real 9m47.699s` — `check passed`
  - Run 2: `real 9m14.168s` — `check passed`
  - Run 3: `real 9m06.185s` — `check passed`
  Baseline from this plan: 692 seconds (~11m32s). Net improvement: roughly
  90-145 seconds per run, with all runs exiting 0 and no new flakiness.

## Validation and Acceptance

Each milestone has its own "Acceptance for this milestone" subsection above;
satisfy those first, in order (Milestone 1, then 2, then 3; Milestone 4 is
optional). After Milestones 1-3 are complete (Milestone 4 optional), run the
full gate once from a clean, warm `.build` state and confirm it still passes:

```sh
swift build
time ./scripts/check
```

- `./scripts/check` must print `check passed` and exit 0, exactly as it does
  today.
- Compare the total elapsed time against the 692-second baseline recorded in
  this plan's Purpose section. Record the new total, and a per-stage
  breakdown for the four targeted stages, in this plan's `Surprises &
  Discoveries` section.
- Every one of the four targeted stages (`swift test`, `check-sanitize`,
  `coverage-labpty`, `smoke-runtime`) must still perform every check it
  performs today: same tests run, same MC/DC ratchet enforced, same smoke
  assertions checked. This plan's goal is wall-clock time only; it must not
  reduce what gets verified. If any milestone's acceptance criteria and this
  final full-gate run disagree, trust the full-gate run and treat the
  milestone as not yet done.
- If Milestone 4 was attempted but closed as "investigated, not adopted"
  (see its Acceptance subsection), this final run uses plain sequential
  `swift test`, unchanged from today, and that is a fully acceptable outcome
  for this plan as a whole: Milestones 1-3 alone are expected to deliver
  real, measurable savings independent of Milestone 4.

## Interfaces and Dependencies

- SwiftPM (bundled with the Swift 6.3.3 toolchain used by this repository)
  is the only build tool involved; no new external dependency is introduced
  by this plan.
- `--scratch-path <path>`, `--skip-build`, and `--parallel` are all
  confirmed present on `swift build --help` / `swift test --help` for this
  toolchain at the time this plan was written; if a future toolchain
  upgrade removes or renames any of them, re-verify via `swift build
  --help`/`swift test --help` before proceeding with any milestone that
  relies on them (Milestones 1 and 3 rely on `--scratch-path`; Milestone 4
  relies on `--parallel`; Milestone 2 additionally relies
  on `coverage-labpty`'s own existing use of `--skip-build`, which this plan
  does not change, only reorders when it runs).
