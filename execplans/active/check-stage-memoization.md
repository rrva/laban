# Skip check stages whose inputs are byte-identical to their last passing run

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
It cuts `scripts/check` wall-clock for the common case (a diff that does not
touch a given stage's inputs) without weakening any gate. It follows
`execplans/active/faster-check-heavy-stages.md` (parallel/scratch-dir work,
complete) and `execplans/active/test-userdefaults-isolation.md` (test-shard
parallelisation, in progress), which together brought `check` from 772s to
597s. Success here is demonstrated by a full `check` passing, then a second
run completing in a small fraction of that time with every heavy stage
reporting a memo skip, and a targeted edit invalidating exactly the stages
whose inputs it touches.

## Purpose / Big Picture

After the sharding work, `check`'s remaining time is a set of heavy stages
(tests, coverage, sanitizers, CBMC, TLA+, fuzz replay) that are pure functions
of a modest input set: source trees, proofs, specs, fixtures, the stage script,
and the toolchain. Re-running them on byte-identical inputs proves nothing new.
`scripts/check-memo` hashes a stage's declared inputs plus `swift --version`
and itself; a hash matching the stamp of the last successful run skips the
stage, and only a zero exit writes a stamp. Reverting an edit restores the old
hash, whose old stamp is again honored, which is correct: those exact bytes
passed.

The correctness burden moves entirely into the input lists declared in
`scripts/check`. A too-narrow list can skip a stage that should have rerun; a
too-wide list only loses cache hits. Lists are therefore deliberately
over-inclusive (the Swift test stages key on all of `Sources` + `Tests`; the
labpty formal cluster keys on `Sources/Labpty` + `Sources/LabanTerminalCore` +
`proofs` + `specs`).

## Progress

- [x] (2026-07-26) `scripts/check-memo`: content-hash memoization helper with
  stamp store in `.artifacts/check-memo/` (gitignored, per-checkout), a
  `LABAN_CHECK_NO_MEMO=1` escape hatch, and a `-n` dry-run flag that reports
  the run/skip decision without executing or stamping. Unit-validated: first
  run executes, identical rerun skips, input change reruns, failure writes no
  stamp and propagates its exit code, reverting bytes revalidates the old
  stamp, bypass works. Hashing the largest input set costs 0.33s.
- [x] (2026-07-26) Wrapped 14 stages in `scripts/check`: controlgen, specs,
  cbmc, cbmc-contracts, trace, model-coverage, fuzz, fuzz-msan, lint,
  test-split, coverage-labpty, sanitize, smoke-runtime, test-e2e. Cheap
  guards (JSON validity, docs, boundaries, anchors, fd-hygiene, `swift build`)
  stay unconditional.
- [x] (2026-07-26) Validated end to end. A full `check` passed (exit 0, 585s)
  and populated stamps, but only `controlgen` skipped on the repeat: the
  labpty formal cluster invalidated itself, because `check-specs` drops a
  timestamped TLC run directory into `specs/labpty/states` and the fuzzer grows
  `proofs/labpty/fuzz/findings`, both inside declared input trees. Fixed by
  hashing `git ls-files --cached --others --exclude-standard` instead of
  `find`, so the hash honours `.gitignore`; an empty git-visible file list is
  now a hard error rather than a constant hash. Re-warmed with a full passing
  run (exit 0, 534s), after which a fully warm `./scripts/check` passed in
  **17s** with all 14 wrapped stages printing the skip line. Against the 597s
  pre-memoization baseline that is a 35x cut; the floor is the cheap guards
  plus an already-warm `swift build`.
- [x] (2026-07-26) Selective-invalidation probes via `check-memo -n`, all as
  designed: a docs-only edit (`docs/product/spec.md`) invalidated none of
  `test-split`, `cbmc`, `sanitize`; a comment edit in
  `Sources/Labpty/labpty_frame.c` made both `cbmc` and `sanitize` report
  WOULD RUN, and reverting restored both skips; a comment edit in
  `Sources/LabanApp/AppDelegate.swift` invalidated `sanitize` only, leaving
  `cbmc` skipping, and reverting restored the skip.
  `LABAN_CHECK_NO_MEMO=1 ./scripts/check-memo cbmc ... -- echo BYPASS` printed
  `BYPASS` and left the stamp intact. Hashing the largest input set costs
  0.44s.

## Decision Log

- Decision: memoize at stage granularity, not file or test granularity.
  Rationale: stages already have crisp input sets and a single pass/fail; this
  is the entire win of test-impact analysis for the inter-stage case at a
  fraction of the machinery. Finer-grained selection (running only affected
  test targets inside `test-split`) changes guarantees and belongs to a
  separate fast-tier decision, not the gate.
  Date/Author: 2026-07-26 / Claude
- Decision: stamps are content-addressed pass records, never invalidated
  explicitly. Rationale: a stamp asserts "this hash passed", which stays true
  forever; matching is the only operation. This makes failure handling trivial
  (a failed run writes nothing) and revert-to-green free.
  Date/Author: 2026-07-26 / Claude
- Decision: known limitation accepted — stages that self-skip when a tool is
  absent (cbmc, TLA+ jar) stamp that self-skip as a pass. After installing
  such a tool, run once with `LABAN_CHECK_NO_MEMO=1`. Documented in the
  `scripts/check` header. Encoding tool presence into the hash was rejected as
  leaking per-stage knowledge into the wrapper.
  Date/Author: 2026-07-26 / Claude
- Decision: tool VERSIONS are salted into the hash, revisiting the narrow
  reading of the decision above. This host runs the real provers (cbmc 6.9.0,
  goto-cc, TLA+ jar under OpenJDK 11, Apple clang 21), so `swift --version`
  alone left a gap: upgrading a prover would not re-run the proofs it gates.
  `check-memo` gained a generic `-s <string>` salt option and `scripts/check`
  passes `cbmc --version`, `goto-cc --version`, the TLA+ jar's sha256, the
  JVM banner, and `cc --version` to the stages that depend on them. Per-stage
  knowledge stays in the caller; the wrapper remains tool-agnostic, which is
  what the original decision was actually protecting. Absent tools salt as
  "none", matching the stages' own self-skip, so the install-time limitation
  above is unchanged.
  Date/Author: 2026-07-26 / Claude

## Context and Orientation

- `scripts/check-memo`: the helper; self-hashing, so editing it invalidates
  every stamp (intended).
- `scripts/check`: declares `swift_inputs` and `labpty_inputs` and wraps each
  heavy stage with `$memo <name> <inputs> -- <command>`.
- Stamp store: `.artifacts/check-memo/<stage>` containing the input hash of
  the last successful run.

## Validation and Acceptance

- A full `./scripts/check` passes and populates one stamp per wrapped stage.
- An immediately repeated `./scripts/check` passes with every wrapped stage
  printing `inputs unchanged since last pass; skipping`, in a small fraction
  of the full time (target: under 90s; the unwrapped guards and `swift build`
  are the floor).
- `check-memo -n` shows: a docs-only edit invalidates nothing; an edit under
  `Sources/Labpty` invalidates the labpty formal cluster and the Swift test
  stages; an edit under `Sources/LabanApp` invalidates the Swift test stages
  but not the labpty formal cluster.
- `LABAN_CHECK_NO_MEMO=1 ./scripts/check` runs every stage.

## Surprises & Discoveries

- A stage that writes its own output back inside a declared input tree can
  never hit the cache: it invalidates the very stamp it just wrote. `find`
  hashed `specs/labpty/states/<timestamp>/`, which `check-specs` appends to on
  every TLC run, so the entire labpty formal cluster reran forever while
  looking correct. The tell was a repeat run where exactly one stage skipped.
  Hashing what git sees (`ls-files --cached --others --exclude-standard`)
  rather than what the filesystem holds fixes the class, not just the instance:
  build output is gitignored by construction, and a genuinely new source file
  is untracked-but-not-ignored, so it still invalidates. It also means an input
  set that is entirely gitignored would hash to a constant, which is now a hard
  error.
- Registered defaults are only a FALLBACK layer, not an override.
  `UserDefaults.standard.register` is the technique the test suites use to pin
  a key per process without touching disk (see
  `execplans/active/test-userdefaults-isolation.md`), but any *persisted* value
  in the same domain shadows it silently. So a register-pinned key is only
  safe if **zero** writers repo-wide persist it, and one half-converted test is
  enough to break unrelated suites. This is exactly how the first full run
  failed: `CJKFontHeadlessTests` still called the persisting
  `CJKFontSettings.set`, leaking `"Sarasa Term SC"` into the
  `com.apple.dt.xctest.tool` domain, where it shadowed
  `CJKFontMetricsTests.testFallbackOrderPutsUserPreferenceFirst`'s registered
  `"PingFang SC"`. Fixed by converting that test and
  `TabTitleEndToEndTests` to register instead of persist, and wiping the leaked
  domain. Reassuringly, the memo behaved correctly under failure: the failing
  stage wrote no stamp.
