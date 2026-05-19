# Copy Selection From Scrollback

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Users can select terminal text that extends above or below the currently
visible viewport, then press Cmd-C and get the entire selected text in the
macOS clipboard. Before this change, copy only read `LabanSnapshot.cells`,
which contains the visible terminal grid, so rows outside that grid were
silently dropped. The fix reuses the existing scrollback text extractor for
offscreen rows while preserving the existing snapshot-based behavior for rows
that are visible.

## Progress

- [x] 2026-05-19: Diagnosed that `TerminalSelection.selectedText(from:)` clips
  to visible snapshot rows and both UI/debug copy call that path.
- [x] 2026-05-19: Add a failing regression test that selects rows extending outside the
  viewport and expects offscreen rows to be included.
- [x] 2026-05-19: Add a scrollback-aware selected-text helper in `Sources/LabanCore`.
- [x] 2026-05-19: Route `TerminalBitmapView.copy(_:)`, debug copy, and selection debug text
  through the helper.
- [x] 2026-05-19: Run focused tests and affected selection/debug suites.
- [x] 2026-05-19: Attempt the project check script and document the unrelated formatter blocker.
- [x] 2026-05-19: Refresh the RPG graph and re-lift the changed copy/selection entities.

## Decision Log

- Decision: Keep `TerminalSelection.segments(rows:cols:)` viewport-clipping for
  rendering, and add a separate copy extraction path instead of changing
  selection coordinates globally.
  Rationale: Rendering selection rectangles should only draw visible rows.
  Changing selection storage to absolute rows would touch input, rendering,
  debug endpoints, and replay behavior. A copy-specific helper fixes the
  user-visible bug with a smaller risk surface.
  Date/Author: 2026-05-19 / Codex

## Context and Orientation

`Sources/LabanCore/TerminalSelection.swift` defines `TerminalSelection`.
Its existing `selectedText(from:)` reads text from a `LabanSnapshot`, which is
the visible terminal grid. `segments(rows:cols:)` intentionally clips rows to
the viewport so rendering does not draw offscreen rectangles.

`Sources/LabanCore/Session.swift` exposes `Session.scrollbackBlock(rowOffset:maxRows:)`.
That function returns a `ScrollbackBlock` containing plain UTF-8 terminal text
and byte offsets for each extracted row. Terminal find already uses this path.

`Sources/LabanApp/TerminalBitmapView.swift` implements Cmd-C. It currently asks
the active session for a snapshot and then calls `selection.selectedText(from:)`.
`Sources/LabanDebug/DebugClipboardActions.swift` and
`Sources/LabanDebug/DebugSelectionEndpoints.swift` use the same snapshot-only
selection text path for headless/debug behavior.

## Plan of Work

Add a new extraction method that takes a `Session`, a current visible
`LabanSnapshot`, and the current `ViewportState`. For visible rows, it should
delegate to the existing snapshot extraction so wide-cell spacer tails and
cell-accurate clipping stay unchanged. For offscreen rows, it should map the
selection row to an absolute row in the full scrollback text, pull the relevant
row from `Session.scrollbackBlock`, and clip first/last rows by terminal column
using Swift `Character` iteration. Middle rows remain full rows, matching the
existing multi-row selection behavior.

Then update UI copy and debug copy/selection text to use this helper. Leave
rendering callers on `segments(rows:cols:)`.

## Concrete Steps

Run commands from `/Users/rrj/wrk/laban/.codex/worktrees/copy-paste`.

1. Add a focused test to `Tests/LabanCoreTests/TerminalSelectionTests.swift`.
2. Run the focused test and observe failure before production code changes:

   ```bash
   rtk swift test --filter TerminalSelectionTests/testSelectedTextIncludesRowsOutsideVisibleViewport
   ```

3. Implement the helper in `Sources/LabanCore/TerminalSelection.swift`.
4. Update copy callers in:
   - `Sources/LabanApp/TerminalBitmapView.swift`
   - `Sources/LabanDebug/DebugClipboardActions.swift`
   - `Sources/LabanDebug/DebugSelectionEndpoints.swift`
5. Re-run focused and broader verification.

## Validation and Acceptance

The new focused test
`TerminalSelectionTests/testSelectedTextIncludesRowsOutsideVisibleViewport`
must fail before the helper exists and pass after the fix. It should prove that
a selection beginning above the visible viewport and ending inside it includes
the offscreen rows in copied text.

Run:

```bash
rtk swift test --filter TerminalSelectionTests
rtk swift test --filter DebugClipboardActionsTests
rtk ./scripts/check
```

If a named debug test target does not exist, replace it with the closest debug
clipboard/selection test discovered in `Tests/`.

Validation run on 2026-05-19:

```bash
rtk swift test --filter TerminalSelectionTests/testSelectedTextIncludesRowsOutsideVisibleViewport
# passed: 1 test, 0 failures

rtk swift test --filter TerminalSelectionTests
# passed: 17 tests, 0 failures

rtk swift test --filter LabanDebugSmokeTests/testCopyActionIncludesRowsOutsideVisibleViewport
# passed: 1 test, 0 failures

rtk swift test --filter LabanDebugSmokeTests
# passed: 47 tests, 0 failures

rtk swift test --filter TerminalBitmapViewSelectionTests
# passed: 11 tests, 0 failures

rtk ./scripts/check
# failed at the formatter gate on pre-existing files outside this change:
# Sources/LabanApp/UpdateAutoChecker.swift
# Sources/LabanDebug/DebugHTTPServer.swift
# Sources/LabanCore/AsciinemaCast.swift
# Tests/LabanDebugTests/DebugCastEndpointTests.swift
# Tests/LabanCoreTests/AgentJSONLMirrorTests.swift
# Tests/LabanCoreTests/AgentSessionDetectorTests.swift
# Tests/LabanCoreTests/PersistenceRoundTripTests.swift
# Tests/LabanCoreTests/TranscriptRoundTripTests.swift
```

## Surprises & Discoveries

- Observation: A fresh worktree may be missing `.external`, which prevents
  `swift test` from finding `ghostty/vt/terminal.h`.
  Evidence: The first focused test run failed during C compilation. Creating
  `.external -> /Users/rrj/wrk/laban/.external` restored the vendored headers.

- Observation: The repository-wide `./scripts/check` currently fails before it
  can complete because the formatter reports issues in unrelated files.
  Evidence: The formatter output names files outside this change set, and none
  of the reported files are touched by this ExecPlan.

## Outcomes & Retrospective

Cmd-C, debug copy, and the debug selection endpoint now copy selected rows that
extend beyond the visible viewport by reading the existing scrollback extractor
for offscreen rows. Rendering selection rectangles remains viewport-clipped.
The new core and debug regressions cover a selection that starts above the
visible viewport and ends inside it.

## Idempotence and Recovery

All steps are additive or small caller rewrites. If a test command fails, fix
the failing file and re-run the same command. Do not modify `.rpg/graph.json`
manually; use RPG update tooling after code edits.
