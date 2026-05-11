# Add Agent-Friendly Quality Tooling

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. This
is a small tooling shard for the broader MVP plan in
`execplans/active/swiftpm-appkit-software-renderer-mvp.md`.

## Purpose / Big Picture

After this shard, an agent can catch routine Swift, C, and memory-safety
mistakes before renderer and AppKit work grows the codebase. A developer or
agent should be able to run one fast lint command, one auto-format command, one
editor-index command for clangd/SourceKit-LSP, and one slower sanitizer command.

The outcome is visible from the terminal: `./scripts/lint` exits 0 for style and
mechanical Swift checks, `./scripts/dev-index` produces clangd-readable C index
data, `clangd --check=Sources/LabanTerminalCore/session.c` can analyze the C
terminal core, `./scripts/check-sanitize` runs the C-facing tests under Address
Sanitizer, and `./scripts/check` still passes as the normal fast gate.

This shard is not a CI migration and does not add product behavior. It should
not block the renderer milestone on heavyweight optional tools.

## Progress

- [x] (2026-05-03) Draft this ExecPlan after checking the current SwiftPM
  package, scripts, quality docs, and local toolchain.
- [x] (2026-05-03) Add Swift formatting and lint scripts that are deterministic and low
  noise for agents.
- [x] (2026-05-03) Add clangd/editor indexing support for the C terminal core.
- [x] (2026-05-03) Add a sanitizer script for deep local checks of `LabanTerminalCore`.
- [x] (2026-05-03) Update `docs/quality/quality.md` with the new gates after they exist.
- [x] (2026-05-03) Run all validation commands and record any surprises in this plan.
- [x] (2026-05-07) Add `./scripts/check-docs` to verify repository-local
  Markdown link targets and run it from `./scripts/check`.
- [x] (2026-05-07) Update quality docs to close the repository-local link
  checker debt.
- [x] (2026-05-07) Add `./scripts/check-debug-contract` to compare debug
  endpoint docs, discovery, router cases, and schema paths, and run it from
  `./scripts/check`.
- [x] (2026-05-07) Add failed-run artifact collection to
  `./scripts/test-e2e` and verify it with a forced failure after debug-server
  readiness.
- [x] (2026-05-07) Add `./scripts/check-dependencies` to enforce the current
  no-SwiftPM-dependencies policy and verify the libghostty-vt pin, source,
  checkout, archive, and header.

## Decision Log

- Decision: Introduce this tooling now, before the software renderer and AppKit
  surface area land.
  Rationale: The repository already has a real C terminal core, Swift app state,
  and 22 tests. The next milestones will add more files and more agent handoffs,
  so fast mechanical feedback is cheaper now than after UI code accumulates.
  Date/Author: 2026-05-03 / Codex.

- Decision: Split fast gates from deep gates.
  Rationale: `./scripts/check` should stay suitable for every agent turn and CI
  smoke run. Sanitizers, leak checks, and static analyzer probes are valuable but
  slower and more environment-sensitive, so they belong in explicit commands
  such as `./scripts/check-sanitize`.
  Date/Author: 2026-05-03 / Codex.

- Decision: Use built-in Swift and Apple tooling first; defer SwiftLint until
  the project has enough AppKit/debug Swift code to justify a third-party rule
  set.
  Rationale: `swift format lint --strict` is already available, deterministic,
  and paired with an auto-fixer. SwiftLint can be useful later for semantic
  rules, but early global rules such as line length, identifier length, or force
  unwrap bans tend to produce noisy agent churn unless scoped carefully.
  Date/Author: 2026-05-03 / Codex.

- Decision: Prefer Address Sanitizer and macOS `leaks` over Valgrind on this
  macOS-first shard.
  Rationale: SwiftPM supports `--sanitize address` on the current toolchain and
  `leaks` is available on macOS. Valgrind is not installed locally and is not a
  reliable baseline for modern macOS Swift/AppKit work. Add Valgrind only if a
  future Linux CI target exists.
  Date/Author: 2026-05-03 / Codex.

## Context and Orientation

The repository is a SwiftPM package at the repo root. Important files:

- `Package.swift` defines `LabanTerminalCore` as a C target and Swift targets
  `LabanCore`, `LabanRenderer`, `LabanDebug`, `LabanApp`, and `LabanAgent`.
- `Sources/LabanTerminalCore/session.c` owns PTY lifecycle and feeds bytes into
  libghostty-vt.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` exposes the C ABI to
  Swift.
- `Sources/LabanCore/Session.swift`, `Tab.swift`, and `AppModel.swift` own Swift
  application state.
- `scripts/check` currently validates JSON, enforces small `AGENTS.md`, checks
  active ExecPlan sections, runs `git diff --check`, fetches libghostty-vt, then
  runs `swift build`, `swift test`, and `scripts/smoke-runtime`.
- `docs/quality/quality.md` already lists formatter/linter, unit test command,
  headless E2E command, architecture checks, dependency policy checks, and
  artifact collection as gates to add after language selection.

Terms:

- "clangd" is the C/C++ language server. It needs `compile_commands.json`, a
  JSON file that tells it how each C file is compiled.
- "SourceKit-LSP" is Swift's language server. SwiftPM projects work with it
  after `swift build` and do not need a checked-in Xcode project.
- "Address Sanitizer" is a runtime checker that catches memory bugs such as
  use-after-free and out-of-bounds access while tests execute.
- "Agent-friendly linting" means the rule has low false positives, has a clear
  command to fix it, emits deterministic output, and does not require a human to
  adjudicate taste.

Local toolchain observed when this plan was written:

```text
swift format lint supports --recursive, --parallel, and --strict
swift package supports --sanitize address
/usr/bin/clangd exists
/usr/bin/leaks exists
clang-tidy, scan-build, and valgrind are not installed locally
```

## Plan of Work

### Milestone 1: Fast Swift Formatting and Lint

Add `.swift-format` at the repository root using
`swift format dump-configuration` as the starting point. Keep the configuration
boring and agent-safe:

- 2-space indentation.
- 100-character line length as a formatter guide, not a source of manual churn.
- ordered imports enabled.
- ASCII identifiers enabled.
- documentation-required rules disabled for now.
- force unwrap, force try, and implicitly unwrapped optional rules disabled for
  now because this tool cannot scope those rules to `Sources/` while relaxing
  them in `Tests/` and future AppKit glue.

Add `scripts/format`:

```sh
#!/usr/bin/env sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
swift format format --in-place --recursive Sources Tests
```

Note: `Package.swift` is excluded from both `format` and `lint` because the
`OrderedImports` rule moves `import Foundation` before the
`// swift-tools-version:` comment, which must appear on the first line of the
manifest. See Surprises & Discoveries.

Add `scripts/lint`:

```sh
#!/usr/bin/env sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
swift format lint --strict --recursive --parallel Sources Tests
```

Update `scripts/check` to run `./scripts/lint` after the existing repo metadata
checks and before `swift build`. If the first lint run fails only because files
need formatting, run `./scripts/format`, inspect the diff, then rerun
`./scripts/lint`.

Do not add SwiftLint in this milestone. When SwiftLint is introduced later, the
profile should be semantic and source-scoped: stricter in `Sources/` than
`Tests/`, no hard line-length rule, no identifier-length policing, no TODO bans,
no blanket "large type" failures, and any force unwrap or force try rule must
allow explicit test fixtures and AppKit entry points.

### Milestone 2: clangd Indexing for the C Core

Add `.clangd` at the repository root. Keep it useful but low-noise:

```yaml
Index:
  Background: Build
CompileFlags:
  Add:
    - -std=c11
    - -Wall
    - -Wextra
    - -Wpedantic
    - -Wstrict-prototypes
    - -Werror=implicit-function-declaration
Diagnostics:
  ClangTidy:
    Add:
      - clang-analyzer-*
      - bugprone-*
      - portability-*
    Remove:
      - bugprone-easily-swappable-parameters
      - readability-magic-numbers
```

Add `scripts/dev-index`. It should:

1. Run `./scripts/fetch-libghostty-vt` so libghostty-vt headers exist.
2. Generate a root `compile_commands.json` for every
   `Sources/LabanTerminalCore/*.c` file.
3. Use absolute repository paths in the JSON because clangd consumes the file
   from editor processes that may not have the same working directory.
4. Include at least these flags: `-std=c11`,
   `-ISources/LabanTerminalCore/include`,
   `-I.external/libghostty-vt/zig-out/include`, and the warning flags from
   `.clangd`.
5. Run `swift build --enable-index-store` so Swift's SourceKit-LSP has fresh
   package index data.

Add `compile_commands.json` to `.gitignore`; it contains machine-local absolute
paths and must not be committed.

### Milestone 3: Deep Runtime Checks

Add `scripts/check-sanitize`:

```sh
#!/usr/bin/env sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
./scripts/fetch-libghostty-vt
swift test --sanitize address --filter LabanTerminalCoreTests
```

Start with Address Sanitizer only. Add Undefined Behavior Sanitizer later only
after it is proven to pass on this macOS SwiftPM package without toolchain false
positives. Add a `leaks` command later against `laban-agent` headless fixture
mode, not against raw `swift test`, because SwiftPM and XCTest can produce
irrelevant allocations that obscure leaks in Laban's code.

Do not add `scripts/check-analyze` until either `scan-build` or `clang-tidy` is
available in the baseline development environment. clangd's `--check` command
is enough static analysis for this shard.

### Milestone 4: Quality Docs

Update `docs/quality/quality.md` after the scripts exist:

- Change mechanical enforcement evidence to include `./scripts/lint`.
- Change mechanical enforcement evidence to include `./scripts/check-docs`.
- Change mechanical enforcement evidence to include
  `./scripts/check-debug-contract`.
- Change debug harness evidence to include `./scripts/test-e2e` failed-run
  artifacts.
- Change mechanical enforcement evidence to include `./scripts/check-dependencies`.
- Add `./scripts/check-sanitize` as the deep local memory-safety gate.
- Add `./scripts/dev-index` and `clangd --check=...` as editor/static-analysis
  evidence for the C target.
- Leave CI, headless E2E, and artifact collection gaps open until their
  respective MVP shards implement them.

## Concrete Steps

Run these commands from the repository root, `/Users/rrj/wrk/laban`:

```sh
./scripts/format
./scripts/lint
./scripts/check-docs
./scripts/check-debug-contract
./scripts/check-dependencies
LABAN_E2E_FORCE_FAILURE_AFTER_READY=1 ./scripts/test-e2e
./scripts/dev-index
clangd --check=Sources/LabanTerminalCore/session.c --tweaks=
./scripts/check-sanitize
./scripts/check
```

Expected success shape:

```text
./scripts/lint exits 0
./scripts/check-docs exits 0 and prints check-docs passed
./scripts/check-debug-contract exits 0 and prints check-debug-contract passed
./scripts/check-dependencies exits 0 and prints check-dependencies passed
LABAN_E2E_FORCE_FAILURE_AFTER_READY=1 ./scripts/test-e2e exits nonzero and
writes `.artifacts/runs/<run-id>/failure/`
compile_commands.json exists and contains Sources/LabanTerminalCore/session.c
clangd --check=Sources/LabanTerminalCore/session.c --tweaks= exits 0
./scripts/check-sanitize exits 0 with LabanTerminalCoreTests passing
./scripts/check exits 0 and prints check passed
```

## Validation and Acceptance

This plan is complete when all of the following are true:

- `./scripts/format` can be run twice in a row without producing new diffs on
  the second run.
- `./scripts/lint` exits 0.
- `./scripts/check-docs` exits 0 and fails if a repository-local Markdown link
  points at a missing file.
- `./scripts/check-debug-contract` exits 0 and fails if a documented debug
  endpoint is absent from discovery, a discovered endpoint is absent from the
  router, or a discovery schema path is missing.
- `./scripts/check-dependencies` exits 0 and fails if SwiftPM grows an
  undocumented external package dependency or the libghostty-vt pin/source,
  checkout, archive, or header violates policy.
- `LABAN_E2E_FORCE_FAILURE_AFTER_READY=1 ./scripts/test-e2e` exits nonzero
  after readiness and writes a failure bundle containing debug JSON, screenshot,
  server log tails, and run metadata.
- `./scripts/dev-index` creates an ignored root `compile_commands.json`.
- `clangd --check=Sources/LabanTerminalCore/session.c --tweaks=` exits 0 using
  the generated compile database.
- `./scripts/check-sanitize` exits 0 under Address Sanitizer.
- `./scripts/check` exits 0 and still prints `check passed`.
- `docs/quality/quality.md` names the new scripts as evidence.
- No Homebrew-only dependency is required for the fast gate.

## Idempotence and Recovery

All scripts added by this shard must be safe to rerun. Generated files belong in
`.build/`, `.external/`, or ignored root files such as `compile_commands.json`.
If formatting changes more files than expected, inspect `git diff` before
continuing and keep only changes caused by `swift format`.

If `clangd --check` fails because `compile_commands.json` is stale, rerun
`./scripts/dev-index`. If `./scripts/check-sanitize` fails but `./scripts/check`
passes, treat the sanitizer failure as a real C memory-safety investigation
unless the failure clearly comes from a known SwiftPM/XCTest runtime issue and
is documented in `Surprises & Discoveries`.

## Surprises & Discoveries

- **`clangd --check` requires `--tweaks=` to exit 0.**
  Without it, clangd's per-token code-action loop emits 4 `SwapBinaryOperands`
  errors on POSIX wait macros (`WIFEXITED`, `WEXITSTATUS`, etc.) and exits with
  code 3. These are internal refactoring-action failures, not C compiler
  diagnostics. Adding `--tweaks=` (empty: disable all tweaks) suppresses the loop
  and gives exit 0. The C code has no actual warnings or errors.

- **`swift format` must not be run on `Package.swift`.**
  The `OrderedImports` rule moves `import Foundation` before the
  `// swift-tools-version:` comment, which breaks the SwiftPM manifest invariant
  that the tools-version comment must appear on the first line. `scripts/format`
  and `scripts/lint` are scoped to `Sources Tests` only. This is not a formatter
  bug to fix — it is a Package.swift structural constraint.

## Interfaces and Dependencies

Use only tools available in the current macOS Swift toolchain for required
gates:

- `swift format` for formatting and Swift linting.
- `swift build` and `swift test` for package verification.
- `swift test --sanitize address` for the first memory-safety gate.
- `clangd` and generated `compile_commands.json` for C editor diagnostics.
- `jq` is allowed in scripts because `scripts/check` already requires it for
  schema and fixture validation.

Do not require SwiftLint, clang-tidy, scan-build, Valgrind, or a Homebrew LLVM
install in this shard. Those may be added by a later plan after the MVP has
stable AppKit, renderer, and headless debug surfaces.
