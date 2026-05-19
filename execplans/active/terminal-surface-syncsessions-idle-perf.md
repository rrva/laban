# Optimize Terminal Surface Session Sync

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

An idle Laban window should spend as little time as possible checking terminal
session state while preserving the MVP contract that tab identity, session
identity, titles, output activity, and exit state remain correct. The hot path is
`TerminalSurfaceController.syncSessions(...)`, which runs from the AppKit frame
loop and the headless debug runtime. This work reduces repeated model lookups
and tab scans in that path, then proves the result with focused tests and an
idle `sample(1)` capture of `LabanApp` launched with `--no-persistence-restore`.

## Progress

- [x] (2026-05-19 05:28Z) Read the MVP regression contract sections covering
  tab/session identity, title updates, output activity, and exit state.
- [x] (2026-05-19 05:28Z) Located the current hot path in
  `Sources/LabanCore/TerminalSurfaceController.swift`.
- [x] (2026-05-19 05:39Z) Optimize the sync path while preserving the returned
  `TerminalSurfaceSessionSyncResult` semantics.
- [x] (2026-05-19 05:39Z) Add focused regression and performance-shape
  coverage.
- [x] (2026-05-19 05:39Z) Run focused Swift tests.
- [x] (2026-05-19 05:39Z) Launch `LabanApp --no-persistence-restore` and capture an idle
  `sample(1)` profile.
- [x] (2026-05-19 05:44Z) Rebase the worktree onto local `main` and rerun
  focused tests, build, and idle sampling on the rebased base.

## Decision Log

- Decision: Keep the optimization inside `LabanCore` by adding model-level
  batch helpers instead of moving AppKit frame-loop policy into the model.
  Rationale: `TerminalSurfaceController` already owns rendering sync cadence,
  while `AppModel` owns tab/session storage and locking. A narrow helper can
  reduce repeated locking and linear scans without changing product behavior or
  broadening AppKit dependencies.
  Date/Author: 2026-05-19 / Codex

## Context and Orientation

`Sources/LabanCore/TerminalSurfaceController.swift` builds shared terminal
surface frames for AppKit and headless debug code. Its
`syncSessions(captureFrame:polling:markInactiveDirtyRendered:noteOutputOnDirty:recordTitleChanges:now:)`
method currently copies tabs, asks `AppModel` for the active tab, then loops
over each tab and performs additional `AppModel` lookups and metadata syncs.

`Sources/LabanCore/AppModel.swift` owns tab state behind an `NSRecursiveLock`,
maps tabs to `Session` instances through `SessionRegistry`, and exposes helpers
such as `syncTitle`, `syncProcessMetadata`, `syncExitState`, and `noteOutput`.
Those helpers each lock and often scan the tab array.

The MVP regression contract in `docs/product/mvp.md` requires stable tab IDs,
stable session IDs, independent sessions per tab, terminal title updates,
visible process-exited state, and no accidental session restart or teardown
from view rebuilds, resize, or UI refresh.

## Plan of Work

Add a narrow `AppModel` helper that returns tab/session pairs and applies the
metadata updates needed by `TerminalSurfaceController.syncSessions(...)` with
less repeated lookup work. Update `TerminalSurfaceController.syncSessions(...)`
to use the helper while leaving polling, dirty detection, inactive dirty
marking, capture timeline events, and return values unchanged.

Add focused tests under `Tests/LabanCoreTests/TerminalSurfaceControllerTests.swift`
that exercise the optimized sync path for dirty session reporting, active dirty
state, inactive dirty marking, title capture, and model change reporting. If
the implementation adds a reusable model helper, cover the behavior through the
public controller path rather than by testing private implementation detail.

## Surprises & Discoveries

- Observation: The first idle sample after the batch-model change still showed
  `Session.consumeTitle()` and `Session.processMetadata()` allocating Swift
  arrays while called from `syncSessions`. Replacing those temporary arrays with
  `withUnsafeTemporaryAllocation` kept the C ABI unchanged and removed the
  `Array.init(repeating:count:)` frames from the final `syncSessions` sample.
  Evidence: `.artifacts/cpu/syncsessions-idle-sample.txt` showed array
  allocation under `Session.consumeTitle()`, while
  `.artifacts/cpu/syncsessions-idle-sample-final.txt` shows the same calls
  through temporary stack allocation.
- Observation: `AppModel.surfaceSessionSnapshot()` became the largest remaining
  `syncSessions` frame in the final sample. It is bounded to tab count and now
  carries each tab's index into metadata sync, so per-tab ID rescans are avoided
  on the common path while still falling back if the tab list changed.
  Evidence: `.artifacts/cpu/syncsessions-idle-sample-final.txt` shows
  `syncSessions` under the display link, with most process time still in
  run-loop wait (`mach_msg`) rather than terminal sync.
- Observation: The post-rebase idle sample has the same shape: the main thread
  is mostly blocked in `mach_msg`, display-link work is a small fraction of the
  sample, and `syncSessions` appears only inside that display-link slice.
  Evidence: `.artifacts/cpu/syncsessions-idle-sample-after-rebase.txt`.

## Validation and Acceptance

From repository root `/Users/rrj/wrk/laban/.codex/worktrees/idle-perf-2`:

```bash
rtk swift test --filter TerminalSurfaceControllerTests
rtk swift test --filter AppModelTests
rtk swift test --filter LabanSessionTests/testSnapshotAndConsumeTitleDoNotSplitUTF8AtCapacity
```

The focused tests must pass.

Then build and launch the app without restoring persisted state, wait for idle,
and capture a sample:

```bash
rtk scripts/build-app
open -n -F "$PWD/.build/laban/Laban.app" --args --no-persistence-restore
sleep 6
PID=$(pgrep -x LabanApp | tail -1)
sample "$PID" 5 1 -file .artifacts/cpu/syncsessions-idle-sample-final.txt
kill "$PID"
```

The sample artifact must exist and must be inspected for idle hot spots. The
expected idle profile may still show normal run-loop waiting and occasional
frame-loop work, but it should not show `TerminalSurfaceController.syncSessions`
dominating idle CPU after the change.

Final evidence captured on 2026-05-19:

```text
rtk swift test --filter TerminalSurfaceControllerTests
# Executed 5 tests, with 0 failures.

rtk swift test --filter AppModelTests
# Executed 24 tests, with 0 failures.

rtk swift test --filter LabanSessionTests/testSnapshotAndConsumeTitleDoNotSplitUTF8AtCapacity
# Executed 1 test, with 0 failures.

rtk scripts/build-app
# build-app: .build/laban/Laban.app/Contents/MacOS/LabanApp

sample 68131 5 1 -file .artifacts/cpu/syncsessions-idle-sample-final.txt
# Sample analysis written to .artifacts/cpu/syncsessions-idle-sample-final.txt

rtk git rebase --autostash main
# Successfully rebased and updated refs/heads/idle-perf-2.

rtk swift test --filter TerminalSurfaceControllerTests
# Executed 5 tests, with 0 failures.

rtk swift test --filter AppModelTests
# Executed 24 tests, with 0 failures.

rtk swift test --filter LabanSessionTests/testSnapshotAndConsumeTitleDoNotSplitUTF8AtCapacity
# Executed 1 test, with 0 failures.

rtk scripts/build-app
# build-app: .build/laban/Laban.app/Contents/MacOS/LabanApp

sample 72484 5 1 -file .artifacts/cpu/syncsessions-idle-sample-after-rebase.txt
# Sample analysis written to .artifacts/cpu/syncsessions-idle-sample-after-rebase.txt
```

## Idempotence and Recovery

The code edits are source-only and can be re-run by rebuilding and retesting.
The app launch for sampling uses `--no-persistence-restore` so persisted user
state does not affect the measurement. Any sampled process started during
verification should be quit or killed after the sample is captured.
