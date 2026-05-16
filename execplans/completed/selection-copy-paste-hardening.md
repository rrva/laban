# Harden Selection Copy/Paste Across Tabs And Scrolling

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Terminal selection is part of the MVP copy/paste workflow. A user should be
able to select visible terminal text, copy exactly that text, switch tabs
without one tab's selection leaking into another, and scroll while a selection
is active without copying the wrong visible cells. This plan investigates those
edge cases by code inspection and by driving the app through the debug runtime,
then fixes any discovered bugs with regression coverage.

## Progress

- [x] (2026-05-16) Read `AGENTS.md`, `docs/product/mvp.md`,
  `docs/process/dev-process.md`, and prior selection ExecPlans to confirm that
  visible selection, copy, paste, and autonomous debug verification are MVP
  scope.
- [x] (2026-05-16) Used RPG `context_pack` and `plan_change` to identify the
  relevant selection, copy, tab, scrollback, and debug runtime entities.
- [x] (2026-05-16) Inspect AppKit selection state ownership for stale selections during tab
  switch, tab close, resize, hyperlink activation, and terminal mouse tracking.
- [x] (2026-05-16) Inspect headless/debug selection state ownership for stale selections
  during tab switch, fixture reset, scrollback, and copy.
- [x] (2026-05-16) Add focused regression tests for the discovered AppKit
  stale-selection race, inactive cached-selection resize bug, scroll-while-
  selected behavior, and debug closed-tab selection pruning.
- [x] (2026-05-16) Run real app/debug-server scenarios that select text, switch
  tabs, select other text, switch back, copy, and verify selected text plus
  frame commands; run the AppKit event-path regression that scrolls while a
  selection is active and verifies copied text remains attached to the selected
  content.
- [x] (2026-05-16) Run focused tests and the project check script. Completed focused tests:
  `TerminalSelectionTests`, `TerminalSelectionInputTests`,
  `TerminalBitmapViewSelectionTests`, `LabanDebugSmokeTests`, and
  `./scripts/test-e2e`; completed full gate: `./scripts/check`.
- [x] (2026-05-16) Complete a final objective-to-evidence audit before closing
  the goal, mapping every requested scenario to code inspection, regression
  tests, E2E debug-server coverage, and the final project check.

## Context and Orientation

Selection currently spans these files:

- `Sources/LabanCore/TerminalSelection.swift` defines selected cell ranges,
  highlight rectangles, and selected text extraction from a snapshot.
- `Sources/LabanApp/TerminalSelectionInput.swift` maps AppKit mouse points to
  terminal cells and records the viewport offset at selection time.
- `Sources/LabanApp/TerminalBitmapView.swift` owns visible AppKit selection
  gestures, copy from `NSPasteboard`, paste into the active terminal, tab
  selection UI, and scrollback input.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift`,
  `Sources/LabanDebug/DebugSelectionActions.swift`,
  `Sources/LabanDebug/DebugSelectionEndpoints.swift`, and
  `Sources/LabanDebug/DebugClipboardActions.swift` expose deterministic
  selection and clipboard behavior for headless tests.
- `Tests/LabanCoreTests/TerminalSelectionTests.swift`,
  `Tests/LabanAppTests/TerminalSelectionInputTests.swift`, and
  `Tests/LabanDebugTests/LabanDebugSmokeTests.swift` contain existing selection
  coverage.

The current AppKit selection points store `viewportOffsetAtCapture`; when the
viewport scrolls, `TerminalSelectionInput.terminalSelection` translates the
stored row by the difference between the captured offset and the current
offset. This should make the highlight stay attached to content instead of a
fixed screen row.

## Plan of Work

First, inspect the AppKit code paths that mutate selection state:
`beginSelection`, `extendSelection`, `mouseDown`, `mouseDragged`, `mouseUp`,
`scrollWheel`, `advanceFrame`, `setFrameSize`, `pruneClosedTabState`, and
`copy`. Record whether selection state is per active tab, per session, or
view-global at every boundary.

Second, inspect the debug/headless path. Confirm whether `selectionBySession`
is keyed by stable session ID, whether tab switching changes the active
selection projection correctly, whether fixture reset and tab close prune
closed selections, and whether debug `copy` uses the active session selection
only.

Third, add regression coverage where code inspection shows a missing invariant.
Prefer deterministic tests in `LabanDebugSmokeTests` for end-to-end selection
flows and focused AppKit/core tests for coordinate translation.

Fourth, run real app-style debug scenarios with `scripts/run-debug-script` or
`scripts/test-e2e`. The scenarios must cover:

- select text in tab A, switch to tab B, select different text, switch back to
  tab A, and copy tab A's original selection;
- select text, scroll the viewport while selection remains active, and verify
  the selection projection and copy text;
- verify selection frame commands exist only for the active tab's selection.

## Surprises & Discoveries

- Observation: AppKit selection state was cached per tab, but the cache was
  saved and restored from `advanceFrame`. A tab could become active before the
  next render frame, so `copy(_:)` could apply tab A's selected coordinates to
  tab B's active session.
  Evidence: `rtk swift test --filter TerminalBitmapViewSelectionTests` failed
  before the fix with `testNewTabClearsSelectionBeforeNextFrame` copying
  `"TWO"` from the new tab, and
  `testMenuTabSelectionRestoresSelectionBeforeNextFrame` leaving the pasteboard
  at `"sentinel"` instead of copying tab A's selection.

- Observation: A column-changing resize cleared only the currently visible
  selection fields. Selections cached for inactive tabs survived even though
  terminal reflow invalidates grid coordinates.
  Evidence: the same focused test run failed
  `testColumnChangingResizeClearsCachedInactiveSelections` by copying `"ONE"`
  after the resize.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk swift test --filter TerminalSelectionTests
rtk swift test --filter TerminalSelectionInputTests
rtk swift test --filter TerminalBitmapViewSelectionTests
rtk swift test --filter LabanDebugSmokeTests
rtk ./scripts/test-e2e
rtk ./scripts/check
```

Acceptance:

- Code inspection finds no view-global selection leakage across active tabs.
- Headless selection state is keyed by session and copied only from the active
  session unless a request explicitly names another session.
- Real debug-script or E2E runs prove tab switching and scrollback scenarios
  with concrete selection text and frame-command evidence.
- Any discovered bug has a focused regression test that fails before the fix
  and passes after the fix.

Validation run on 2026-05-16 from `/Users/rrj/wrk/laban`:

```sh
rtk swift test --filter TerminalSelectionTests
# 16 tests, 0 failures

rtk swift test --filter TerminalSelectionInputTests
# 6 tests, 0 failures

rtk swift test --filter TerminalBitmapViewSelectionTests
# 5 tests, 0 failures

rtk swift test --filter LabanDebugSmokeTests
# 44 tests, 0 failures

rtk ./scripts/test-e2e
# test-e2e passed

rtk ./scripts/check
# check passed
```

The first run of `rtk swift test --filter TerminalBitmapViewSelectionTests`
before the AppKit fix failed all three initial regression tests, proving the
new tests covered real bugs. After the fix, the same test target passed. After
the final inactive-tab-close corner-case fix, the AppKit selection target and
the full `rtk ./scripts/check` gate passed again.

Final objective-to-evidence audit:

- Code inspection covered the AppKit view-global selection cache, tab
  create/select/close entry points, copy, column-changing resize, and
  scrollback translation; it also covered the debug runtime's session-keyed
  selection map and tab-close path.
- The select-tab-A, select-tab-B, switch-back-and-copy scenario is covered by
  AppKit regression tests, `LabanDebugSmokeTests`, and `scripts/test-e2e`
  section 24c, which verifies selection text, copied clipboard text, and
  selection frame commands through the HTTP debug server.
- Scroll while a selection is active is covered by
  `TerminalBitmapViewSelectionTests.testScrollWheelKeepsSelectionAttachedToContent`.
- Bugs found by inspection and failing tests were fixed, then re-tested with
  focused Swift tests, the debug-server E2E script, and the full check script.

## Outcomes & Retrospective

AppKit selection state is now synchronized at tab create/select time instead
of waiting for the next render frame. Copy now first syncs selection state to
the active tab, so immediate copy after a tab switch cannot use another tab's
selection coordinates. Column-changing resize clears both the visible
selection and inactive cached selections because terminal reflow invalidates
grid coordinates. Closing an inactive tab that was the last rendered tab no
longer clears the active tab's selection. The debug runtime now removes closed
sessions from `selectionBySession`.

Regression coverage now exercises immediate new-tab selection clearing,
immediate menu tab selection restoration, inactive selection clearing after
resize, scroll-wheel movement with an active selection, headless per-session
selection/copy behavior across tab switching, closed-tab debug selection
pruning, and an HTTP debug-server E2E tab-switch copy flow.

## Idempotence and Recovery

All test and debug-script commands are safe to rerun. Generated artifacts stay
under `.artifacts/` or system temporary directories and can be removed after
validation. Existing user or tool changes in `.rpg/graph.json` and `.codex/`
are not part of this plan and must not be reverted.
