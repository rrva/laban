# Skip Duplicate Live Session Restore

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

Starting a second copy of Laban while another copy still owns the persisted tabs must not create a second Claude or Codex process for the same captured session. After this change, Laban records each tab's shell process id in `workspace.json`; on a later launch, before typing any agent resume command into a restored tab, it checks whether that old shell still has the same agent session alive. If so, the new tab is left at a fresh prompt instead of executing or prefilling a duplicate resume command.

The launch flag `--no-persistence-restore` gives a manual escape hatch: the app and headless debug server can start fresh without loading `workspace.json`. The stronger `--no-persistence` flag skips workspace persistence, transcript persistence, and agent session mirroring for the current process.

## Progress

- [x] Inspected the app and headless restore paths.
- [x] Decided to guard only agent resume commands, not general tab reconstruction.
- [x] Persist the shell pid per tab.
- [x] Add a restore-time live agent checker.
- [x] Wire the checker into AppKit and headless restore command application.
- [x] Add `--no-persistence-restore` and `--no-persistence` launch flag support.
- [x] Add focused regression tests.
- [x] Run targeted validation.

## Decision Log

- Decision: Use the persisted shell pid plus same-session agent detection instead of a global app-instance lock.
  Rationale: The user-visible harm is duplicate resume of a specific Claude/Codex session. A process-wide lock would also block harmless launches and does not prove which session is live. Checking the old shell's descendant tree for the same agent session id directly answers the safety question.
  Date/Author: 2026-05-19 / Codex.

- Decision: `--no-persistence-restore` skips loading `workspace.json` but does not disable future persistence saves; `--no-persistence` disables restore and the persistence/session sync stack for the process.
  Rationale: The restore-only flag is a startup escape hatch. The full flag is useful for launches that must not touch persistence at all, while the existing UI toggle remains the persistent user preference.
  Date/Author: 2026-05-19 / Codex.

## Context and Orientation

`Sources/LabanApp/AppDelegate.swift` decides whether to load persisted workspace state. `Sources/LabanApp/MainWindowController.swift` and `Sources/LabanDebug/DebugPersistenceEndpoints.swift` apply `RestoreLaunchPlanner` instructions by writing commands into newly spawned restored shells. `Sources/LabanCore/Persistence/RestoreLaunchPlanner.swift` decides whether an agent tab should auto-execute, prefill, or do nothing.

`Sources/LabanCore/Persistence/AgentSessionDetector.swift` already knows how to inspect a shell process tree and find a live Claude/Codex descendant with a session id. This plan reuses that process-tree knowledge for restore suppression.

## Plan of Work

Add an optional `shellPid` field to `TabState` in `Sources/LabanCore/Persistence/WorkspaceState.swift` and populate it from `AppModel.snapshotForPersistence(windowId:)` using `Session.processMetadata()?.childPid`.

Add a `RestoreSessionActivityChecking` abstraction in `RestoreLaunchPlanner.swift`. Its production implementation should use `AgentSessionDetector` with `LibprocIntrospector` to inspect `tab.shellPid`; if the same `AgentName` and `sessionId` are currently live under that old shell, `RestoreLaunchPlanner.instruction` returns `.noPrefill`.

Wire the checker into `MainWindowController.applyRestoreLaunchPlans` and `HeadlessDebugRuntime.applyRestoreLaunchPlans`. Existing tests that call the planner without a checker keep deterministic behavior.

Add `PersistenceRestoreLaunchFlag` in core and use it from `AppDelegate` and `laban-agent`. Add a `restorePersistedState` parameter to `HeadlessDebugRuntime` so the debug server can wire persistence but intentionally skip launch-time loading when the restore-only flag is present. Use `--no-persistence` to avoid wiring the debug persistence stack at all.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk swift test --filter 'RestorePlannerTests|PersistenceRoundTripTests|AppModelTests.testSyncProcessMetadataUsesForegroundProcessForTitle|LabanDebugSmokeTests.testRuntimeCanSkipLoadingPersistedWorkspace'
# passed: 33 tests

rtk swift run LabanApp --smoke --no-persistence-restore
# printed: laban-app: smoke ok

rtk swift run LabanApp --smoke --no-persistence
# printed: laban-app: smoke ok

rtk swift run LabanApp --help | rtk rg -- '--no-persistence|--no-persistence-restore|--smoke'
# printed app help entries

rtk swift run laban-agent --help | rtk rg -- '--no-persistence|--no-persistence-restore|--persistence-dir'
# printed agent persistence flags
```

Acceptance: planner tests prove a live same-session checker suppresses both execute and prefill paths; persistence tests prove `shellPid` round-trips; debug tests prove `restorePersistedState: false` starts fresh even when a persisted workspace exists. No real Claude process is required.

## Idempotence and Recovery

The schema change is additive: old `workspace.json` files decode with `shellPid == nil`, so older state keeps existing behavior. The launch flags only change the current process startup decision and do not archive or delete persisted state.
