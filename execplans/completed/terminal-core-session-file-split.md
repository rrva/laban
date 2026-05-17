# Split the terminal core session implementation into focused C modules

This ExecPlan is a living document maintained per `PLANS.md`. Keep `Progress`
and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

`Sources/LabanTerminalCore/session.c` currently mixes process launch, PTY I/O,
terminal effect callbacks, snapshot extraction, capture, paste, key input,
mouse input, process metadata, and the OSC tab-status parser. After this
change, the same public C ABI remains available, but each area lives in a
focused `.c` file under `Sources/LabanTerminalCore/`. The observable behavior
is unchanged: terminal tests should still pass, and a maintainer can now review
future changes without scanning one 2,500-line file.

## Progress

- [x] Read `docs/product/mvp.md`, `PLANS.md`, `Package.swift`, and the public
  terminal core header to establish scope and build constraints.
- [x] Add a private `session_internal.h` containing `struct LabanSession`,
  lock helpers, shared constants, and private cross-module function prototypes.
- [x] Split `session.c` into lifecycle, PTY I/O, capture/tab-status, terminal
  effects, snapshot/viewport, process metadata, key input, mouse input, and
  paste modules.
- [x] Build and run terminal-core tests, then fix any compile or behavior
  regressions.
- [x] Record validation results and final outcome here.

## Decision Log

- Decision: Keep the public header `Sources/LabanTerminalCore/include/LabanTerminalCore.h`
  unchanged.
  Rationale: This is an internal refactor. Swift and test callers should not
  need source changes, and unchanged ABI is the best guardrail for behavior
  preservation.
  Date/Author: 2026-05-11 / Codex.

- Decision: Use one private header rather than duplicating helper definitions
  or exposing internals in the public header.
  Rationale: SwiftPM compiles all C files in `Sources/LabanTerminalCore`, and a
  private header keeps `struct LabanSession` visible only to the C target while
  allowing modules to share the existing lock and response/capture helpers.
  Date/Author: 2026-05-11 / Codex.

## Context and Orientation

The public C API for the terminal core is declared in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h`. The implementation to
split is `Sources/LabanTerminalCore/session.c`. SwiftPM's `LabanTerminalCore`
target in `Package.swift` does not list individual C sources, so any new `.c`
files placed directly under `Sources/LabanTerminalCore/` are compiled
automatically.

The term "PTY" means pseudo-terminal: `session.c` opens a master/slave terminal
pair, forks a child shell connected to the slave side, and reads/writes the
master side. The term "terminal effects" means libghostty-vt callbacks that
produce replies to terminal capability queries such as device attributes,
window size, color scheme, or version.

## Plan of Work

Create `Sources/LabanTerminalCore/session_internal.h` with the private session
struct and helper prototypes. Then move functions from `session.c` into these
files while preserving their bodies:

- `session_lifecycle.c`: create, destroy, resize, direct write/feed/replay, and
  exit-state functions.
- `pty_io.c`: environment/termios helpers, PTY read/write helpers, polling, and
  child reaping helpers.
- `terminal_effects.c`: libghostty effect callbacks, terminal response capture,
  response draining, mode queries, synchronized output, focus, and color-scheme
  reporting.
- `capture.c`: capture callback/file plumbing and VT-write mirroring.
- `tab_status.c`: OSC 21337 scanner and callback registration.
- `snapshot.c`: render snapshots, dirty state, title consumption, and viewport
  scrolling/state.
- `process_metadata.c`: Darwin process metadata helpers and public metadata API.
- `mouse_input.c`: mouse encoding/sending.
- `key_input.c`: key encoding/sending.
- `paste.c`: paste safety, paste encoding, and paste writing.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/0259/laban`:

```sh
swift test --filter LabanTerminalCoreTests
```

Acceptance is exit code 0 with all `LabanTerminalCoreTests` passing. If time
allows, also run `scripts/test` for the full suite. Because this is an internal
refactor, no user-visible behavior should change and no public header changes
should be needed.

Validation completed on 2026-05-11:

```sh
swift test --filter LabanTerminalCoreTests
```

Result: passed. The run executed 92 selected tests, skipped 1
capture-bisect opt-in test, and reported 0 failures. `git diff --check` also
reported no whitespace errors.

## Surprises & Discoveries

- Observation: This worktree was missing `.external`, so SwiftPM could not find
  `ghostty/vt/terminal.h` on the first validation attempt.
  Evidence: the initial build failed with `fatal error:
  'ghostty/vt/terminal.h' file not found`. Following `AGENTS.md`, adding
  `.external -> /Users/rrj/wrk/laban/.external` restored the vendored headers.

## Outcomes & Retrospective

`session.c` is now an orientation stub. The prior implementation is split into
focused modules under `Sources/LabanTerminalCore/`: lifecycle, PTY I/O,
terminal effects, snapshot/viewport, process metadata, capture, tab status,
mouse input, key input, and paste. The public header remains unchanged.

## Idempotence and Recovery

The refactor is source-only. If a split introduces compile errors, fix the
private prototypes or move a helper to the module that owns its invariant. Do
not change public Swift or C callers unless the compiler proves an existing
call has become invalid, which would indicate this plan is drifting outside
internal refactoring.
