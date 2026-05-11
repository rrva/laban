# Make terminal lock ownership explicit and split AppModel responsibilities

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

This change makes Laban's terminal-session internals easier to audit for
deadlocks and thread-safety regressions. The C terminal core currently calls
lock-taking public entry points from code that already holds the session lock.
After this change, nested terminal-core operations use explicitly named
`*_locked` helpers, so a maintainer can see which functions require the caller
to hold the session lock.

The Swift `AppModel` currently owns tab state, session lifetime, reader threads,
and metadata synchronization in one file. This change keeps `AppModel` as the
public model facade while moving session/runner ownership into a small session
registry and title/process/exit synchronization into a metadata synchronizer.
The app behavior should not change.

## Progress

- [x] Read `docs/product/mvp.md`, `PLANS.md`, all C files under
  `Sources/LabanTerminalCore/`, and the current `AppModel`/session sync code.
- [x] Refactor terminal-core key, paste, focus, and mode paths to use explicit
  locked helpers instead of re-entering public-ish functions while the session
  lock is held.
- [x] Split `AppModel` by moving session/runner ownership into
  `SessionRegistry` and metadata sync state into `TabMetadataSynchronizer`.
- [x] Run focused terminal-core and AppModel tests, then record validation here.

## Decision Log

- Decision: Keep the session mutex recursive for this refactor, but remove
  terminal-core's internal dependence on recursive re-entry.
  Rationale: C capture and tab-status callbacks still execute while the session
  lock is held. Removing recursive mutexes entirely needs a separate callback
  contract change. The immediate win here is making internal lock ownership
  explicit without changing callback behavior.
  Date/Author: 2026-05-11 / Codex.

- Decision: Keep `AppModel` as the public API surface and extract private helper
  types rather than renaming the model or changing call sites.
  Rationale: Existing AppKit, debug, and tests call `AppModel` directly. A
  private split reduces file responsibility and lock-order ambiguity without
  widening the behavior change.
  Date/Author: 2026-05-11 / Codex.

## Context and Orientation

The C terminal core lives in `Sources/LabanTerminalCore/`. `SESSION_LOCK(s)` in
`session_internal.h` acquires `LabanSession.lock` and automatically unlocks on
scope exit. A helper whose name ends in `_locked` means the caller must already
hold that lock and the helper must not lock it again.

The Swift app model lives in `Sources/LabanCore/AppModel.swift`. It exposes tab
operations to AppKit and debug code. One `Session` wraps one C `LabanSession`.
One `SessionRunner` drains a live PTY on a background thread and must be stopped
before its `Session` closes.

## Plan of Work

First update terminal-core internals:

- In `terminal_effects.c`, rename the internal mode query to
  `laban_session_mode_active_locked` and route synchronized-output, focus, and
  color-scheme paths through it.
- In `key_input.c`, add locked helpers for encode/send and make public wrappers
  acquire the lock exactly once.
- In `paste.c`, add locked helpers for bracketed-paste query, encode, and
  write-and-capture paths.
- In `terminal_effects.c`, add locked helpers for focus encode/send.
- Keep the public C header unchanged.

Then split Swift responsibilities:

- Add `Sources/LabanCore/SessionRegistry.swift` to own `Session` and
  `SessionRunner` dictionaries, capture-sink propagation, dirty callbacks, and
  close ordering.
- Add `Sources/LabanCore/TabMetadataSynchronizer.swift` to own process identity,
  terminal-title ownership, throttled process metadata polling, git branch
  refresh, exit-state sync, and output activity updates.
- Update `AppModel.swift` to delegate to these helpers while keeping existing
  public methods and behavior.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/6627/laban`:

```sh
swift test --filter LabanTerminalCoreTests
swift test --filter AppModelTests
swift test --filter TerminalSurfaceControllerTests
```

Acceptance is all three commands exiting 0. `LabanTerminalCoreTests` proves the
C ABI behavior did not change. `AppModelTests` proves tab/session lifecycle and
metadata behavior did not change. `TerminalSurfaceControllerTests` proves the
render-loop sync path still works after delegating model metadata work.

Completed on 2026-05-11:

```sh
swift test --filter LabanTerminalCoreTests
swift test --filter AppModelTests
swift test --filter TerminalSurfaceControllerTests
git diff --check
swift format lint --strict Sources/LabanCore/AppModel.swift Sources/LabanCore/SessionRegistry.swift Sources/LabanCore/TabMetadataSynchronizer.swift
./scripts/check-boundaries
./scripts/check-docs
```

All completed commands exited 0.

Additional checks:

- `swift format lint --strict --recursive --parallel Sources Tests` still fails
  on existing unrelated test style issues in `Tests/LabanDebugTests/` and
  `Tests/LabanAppTests/TerminalResizeAutomationTests.swift`.
- `./scripts/check-debug-contract` still reports documented debug endpoints
  missing from discovery. This change does not touch debug endpoint discovery.

During validation, `.external/` was absent in this worktree, so it was symlinked
from `/Users/rrj/wrk/laban/.external` as documented in `AGENTS.md`.

## Idempotence and Recovery

The changes are source-only. If the C refactor fails to compile, restore the
public wrappers to lock once and move shared bodies into static or internal
`*_locked` helpers. If the Swift split fails, keep `AppModel`'s public methods
unchanged and move only the private state back behind the same method names.
