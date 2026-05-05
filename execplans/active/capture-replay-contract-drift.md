# Repair Capture Replay And Wait Contract Drift

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Capture replay and debug waits are verification infrastructure. After this change, a corrupted timeline cannot be silently treated as a passing replay, tab close events affect the replay model, and `/debug/wait` can look for text in the requested session instead of only the active tab. The observable result is that malformed NDJSON throws, replayed closed tabs no longer remain selectable, and session-scoped text waits work across background tabs.

## Progress

- [x] Read `Sources/LabanDebug/CaptureReplayRunner.swift` timeline loading and terminal replay.
- [x] Read `Sources/LabanDebug/HeadlessDebugRuntime.swift` wait condition dispatch.
- [x] Stream and strictly decode `timeline.ndjson`.
- [x] Replay `tab.closed` events into `AppModel`.
- [x] Honor `sessionId` and `tabId` for `textVisible` waits.
- [x] Add focused regression tests for malformed timeline lines, closed-tab replay, and session-scoped waits.
- [x] Run focused debug tests and the full package suite.

## Outcomes & Retrospective

`CaptureReplayRunner` now streams `timeline.ndjson` in chunks and throws `CaptureReplayError.malformedTimelineLine` with a line number on the first malformed event. Terminal replay applies `tab.closed`, removes the captured tab and session mappings, and tolerates AppModel's final-tab close sentinel. `HeadlessDebugRuntime` resolves `textVisible` waits by explicit `sessionId`, then `tabId`, then active tab. Regression tests cover all three contract points.

## Context and Orientation

Capture timelines are newline-delimited JSON files where each line is one `CaptureTimelineEvent`. `CaptureReplayRunner.run()` loads these events and reconstructs enough terminal state to compare terminal snapshots, frame commands, and screenshots. Before this change, `loadTimeline()` read the entire timeline into a `String` and used `try?` per line, so invalid lines disappeared. Terminal replay also handled `tab.created` and `tab.selected` but not `tab.closed`, so replay state could diverge from the captured application. Separately, `HeadlessDebugRuntime.wait(_:)` supports a `textVisible` condition, but it checks only `model.activeTab` even when the request includes `sessionId`.

## Plan of Work

In `CaptureReplayRunner`, replace whole-file `String` loading with chunked `FileHandle` reads. Decode each non-empty line with `JSONDecoder`; if a line cannot decode, throw a replay error that includes the line number. Add a `tab.closed` case in terminal replay that closes the mapped replay tab, removes the captured tab and session mappings, and tolerates the final-tab close sentinel.

In `HeadlessDebugRuntime`, add a small helper for resolving a wait target tab from `sessionId`, then `tabId`, then the active tab. Use it for `textVisible` so background-session waits are scoped correctly and an explicitly missing session does not accidentally fall back to the active tab.

Add tests in `Tests/LabanDebugTests/CaptureReplayTests.swift` and `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`. The replay tests should fail before the changes: a malformed timeline currently passes, and a stale post-close selection can still select a closed tab during replay. The wait test should create two sessions, keep text in the background session, and assert a `textVisible` wait with that background `sessionId` succeeds.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter LabanDebugTests
rtk swift test
```

Acceptance: malformed timeline input throws instead of producing a passing report; terminal replay passes when a stale selection follows a `tab.closed` event because the closed tab mapping is gone; and `textVisible` waits can target a background session by `sessionId`.
