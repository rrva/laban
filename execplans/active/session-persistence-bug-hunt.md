# Session Persistence Bug Hunt

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

The persistence code should be safe under restore, debug relaunch, transcript writer swaps, corrupt workspace files, and command-line persistence bypasses. This bug hunt focuses on defects that can lose user state, duplicate session output, or crash during persistence/session synchronization.

## Progress

- [x] Inspected persistence, transcript, agent mirror, restore planner, app launch, and debug relaunch paths.
- [x] Identified a stale C callback hazard when `TranscriptHost` re-attaches a writer for the same tab without detaching the prior session first.
- [x] Patch transcript re-attach to clear the previous session callback before releasing its bridge.
- [x] Add a regression that feeds the old session after re-attach and verifies stale bytes are ignored.
- [x] Patch nil-session detach to clear the callback from the host's registered session fallback.
- [x] Add a regression that detaches with `nil`, feeds the still-live session, and verifies the stale writer is not called.
- [x] Harden corrupt workspace archive naming against same-second collisions.
- [x] Fix the restore E2E assertion so wrapped native resume commands are still recognized.
- [x] Run targeted persistence tests, strict format lint, and the full Swift test suite.

## Surprises & Discoveries

- Observation: `TranscriptHost.attachTranscriptWriter` replaces and releases the old bridge before it clears the old session's persistence callback.
  Evidence: The host had no record of the session associated with a tab id, so it could not detach the previous session during a same-tab writer swap. The existing `testRingSurvivesWriterDetach` explicitly re-attaches without detaching first but only feeds the new session, leaving the stale old-session callback untested.

- Observation: `TranscriptHost.detachTranscriptWriter(forTabId:in:)` accepted `nil` for the session and released the bridge without using any host-owned fallback.
  Evidence: once `sessionsByTab` was added for re-attach safety, the same table exposed a safer detach path: when the caller does not have a `Session`, the host can still clear the registered callback before releasing its bridge.

- Observation: the full suite exposed an E2E test false negative for the native Claude resume command.
  Evidence: `WorkspaceRestoreEndToEndTests.testAgentRestoreExecutesNativeResumeWithoutDestructiveOriginalFlags` saw `clear && command claude --resume ... --model so\nnnet`; the command was written, but the 80-column terminal snapshot wrapped `sonnet` across a row boundary before the literal substring check.

## Context and Orientation

`Sources/LabanCore/Persistence/TranscriptHost.swift` owns a Swift bridge object used as `userdata` for the C persistence callback registered by `Session.setPersistenceCallback`. The C session stores the raw callback pointer and userdata; Swift must ensure that userdata remains alive for as long as the C session can call it. When a tab's writer is replaced, the old session callback must be cleared before the old bridge is released.

`Sources/LabanCore/Persistence/PersistenceStore.swift` renames corrupt `workspace.json` files to a timestamped sidecar. If two corrupt loads happen within the same timestamp value, the move can collide and leave the corrupt file in place.

## Plan of Work

In `TranscriptHost`, track the `Session` associated with each tab id through a weak reference. During same-tab attach, clear the previous session's persistence callback before releasing its bridge. During detach, use the explicit session argument when available and fall back to the tracked session when the argument is `nil`.

In `PersistenceStore.load`, add a UUID suffix to the corrupt archive filename so repeated corrupt loads cannot collide.

Add tests in `RecentByteRingIntegrationTests` and `PersistenceRoundTripTests`.

Normalize line breaks in the workspace-restore native-resume assertion so it still verifies the command shape and destructive-flag stripping when the terminal wraps a long command across rows.

## Validation and Acceptance

Run from `/Users/dev/wrk/laban`:

```sh
rtk swift test --filter 'RecentByteRingIntegrationTests|PersistenceRoundTripTests|TranscriptRoundTripTests'
rtk swift format lint --strict Sources/LabanCore/Persistence/TranscriptHost.swift Sources/LabanCore/Persistence/PersistenceStore.swift Tests/LabanCoreTests/RecentByteRingIntegrationTests.swift Tests/LabanCoreTests/PersistenceRoundTripTests.swift Tests/LabanAppTests/WorkspaceRestoreEndToEndTests.swift
rtk swift test
```

Acceptance: the old session can emit after a same-tab writer swap without crashing and without recording stale bytes; corrupt workspace loads always move the bad file aside.

Validation completed on 2026-05-19:

```sh
$ rtk swift test --filter 'RecentByteRingIntegrationTests|PersistenceRoundTripTests|TranscriptRoundTripTests'
Test Suite 'Selected tests' passed
Executed 40 tests, with 0 failures

$ rtk swift format lint --strict Sources/LabanCore/Persistence/TranscriptHost.swift Sources/LabanCore/Persistence/PersistenceStore.swift Tests/LabanCoreTests/RecentByteRingIntegrationTests.swift Tests/LabanCoreTests/PersistenceRoundTripTests.swift Tests/LabanAppTests/WorkspaceRestoreEndToEndTests.swift
# no output; exit 0

$ rtk swift test
Test Suite 'All tests' passed
Executed 629 tests, with 3 tests skipped and 0 failures
```
