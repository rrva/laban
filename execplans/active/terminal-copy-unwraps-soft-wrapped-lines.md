# Terminal copy rejoins soft-wrapped lines into their logical lines

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(at the repository root). Keep `Progress` and `Validation and Acceptance`
current as work proceeds.

## Purpose / Big Picture

When a program prints a line longer than the terminal is wide, the terminal
breaks it across several visual rows so it fits on screen. That break is a
*soft wrap*: the program did not send a newline, the terminal inserted one
purely for display. A *hard* line break is the opposite — the program actually
emitted a newline (Enter / `\n`).

Today, when a user drags a mouse selection across wrapped output in Laban and
copies it (⌘C), every visual row becomes its own line in the clipboard: the
copied text contains a literal `\n` at each soft-wrap point — i.e. at whatever
column width the terminal happened to be. Pasting that text reproduces the
terminal's wrapping, not the text the program meant. This is the exact
complaint that motivated this work: copying wrapped output out of a coding
agent running inside Laban yields newlines chopped in at the window width.

After this change, copying a selection that lies within the visible screen
**rejoins** soft-wrapped rows back into one logical line. Only the newlines the
program actually emitted survive in the clipboard. This matches the default
behavior of every mature terminal (Ghostty's `selectionString` uses
`unwrap=true` by default; kitty joins lines whose continuation bit is set;
WezTerm reconstructs logical lines from wrapped physical lines).

How to see it working after the change:

1. Build and install Laban (`./scripts/install-app`), quit and relaunch it.
2. Make the window narrow (say ~40 columns). Run a command that prints one long
   line with no embedded newlines, e.g. `printf 'A%.0s' {1..120}; echo`.
   The single 120-character line wraps across ~3 visual rows.
3. Drag-select across all the wrapped rows and press ⌘C.
4. Paste into any text field. Before this change you get the text split with
   `\n` at column ~40 and ~80. After this change you get one unbroken
   120-character line.

The same behavior is exercised automatically by a unit test
(`testSelectedTextJoinsSoftWrappedRowsWithoutNewline`) that fails before the
change and passes after.

## Scope and non-goals

- **In scope:** copying a selection whose rows are all currently visible on
  screen (the viewport). This is the overwhelmingly common case and the one in
  the bug report. It is served by `TerminalSelection.selectedText(from:)`,
  which reads a real libghostty snapshot.
- **Out of scope (documented limitation):** a selection that extends into
  scrollback rows that have scrolled *off* the top of the screen. Those rows
  are reconstructed from a plain-text scrollback extraction
  (`laban_session_scrollback_extract`) that does not currently carry per-row
  wrap flags, so they keep the old one-`\n`-per-row behavior. Closing this gap
  would require extending the scrollback-extract ABI to emit per-row wrap bits;
  it is recorded in *Surprises & Discoveries* as a follow-up.
- **No new setting.** The behavior is unconditional, matching other terminals.
  A future toggle for "copy with literal wraps" can be added if anyone wants
  it, but it is not part of this plan.

## Context and Orientation

Laban is a macOS terminal app. Its terminal emulation core is a vendored
library, **libghostty-vt** (Ghostty's terminal core, written in Zig), under
`.external/libghostty-vt/`. Laban wraps it with a C shim in
`Sources/LabanTerminalCore/` that exposes a C ABI (`LabanTerminalCore.h`) and
is imported into Swift.

The pieces that matter here:

- **`Sources/LabanTerminalCore/include/LabanTerminalCore.h`** declares the
  `LabanSnapshot` C struct — a frozen view of the screen grid: dimensions
  (`rows`, `cols`), the flat `cells` array, the `utf8_storage` byte pool the
  cells point into, and a per-row `dirty_rows` byte array (one byte per row).
  This struct is produced by the C shim and read directly from Swift.

- **`Sources/LabanTerminalCore/snapshot.c`** builds a `LabanSnapshot` from
  libghostty in `laban_session_snapshot`. It iterates rows with a render-state
  row iterator. For each row it already calls
  `ghostty_row_get_multi(raw_row, 1, row_keys, row_values, NULL)` to read
  `GHOSTTY_ROW_DATA_HYPERLINK`. libghostty exposes the wrap state on the same
  raw row via `GHOSTTY_ROW_DATA_WRAP` (output type `bool *`), defined in
  `.external/libghostty-vt/include/ghostty/vt/screen.h:247`:
  *"Whether this row is soft-wrapped."* The shim does not currently read it.

- **`Sources/LabanCore/TerminalSelection.swift`** turns a selection
  (`anchor`/`focus` cell coordinates) into text. `segments(rows:cols:)` returns
  one `(row, startCol, endCol)` tuple per selected **visible** row, in
  top-to-bottom order with contiguous row numbers. `selectedText(from snap:)`
  extracts each segment's text with `snapshotLineText(...)` (which right-trims
  trailing whitespace) and joins the rows with `"\n"`. This blind join is what
  inserts a newline at every soft-wrap point.

- **Snapshot source for copy:** `Sources/LabanApp/TerminalBitmapView.swift`
  `currentSelectionText()` calls `session.snapshot()` (which calls the C
  `laban_session_snapshot` on the app's local libghostty viewer session and is
  freed with `laban_snapshot_destroy`). So the snapshot feeding selection is a
  genuine libghostty snapshot and will carry the new wrap flags for free once
  the shim populates them. The daemon shared-memory "ring"
  (`laband_snapshot_ring.h`) is **not** on this path and is not touched.

- **`Sources/LabanCore/TerminalSessionClient.swift`** has an unrelated
  `LabandSnapshotResponse` DTO; it is a different representation used for
  rendering/RPC and is **not** what selection reads. Do not touch it.

Term definitions used above: *viewport* = the rows currently visible on screen;
*scrollback* = rows that have scrolled above the visible area; *cell* = one
character position in the grid; *snapshot* = an immutable copy of the grid at a
moment in time.

## Plan of Work

1. **Carry the wrap flag in the snapshot struct.** In
   `Sources/LabanTerminalCore/include/LabanTerminalCore.h`, add two fields to
   `LabanSnapshot` immediately after `dirty_row_count`:

   ```c
   /* Per-row soft-wrap flags read from libghostty (one byte per terminal row,
    * 1 = this row is soft-wrapped: its text continues onto the next row because
    * the line exceeded the terminal width and the program emitted no newline.
    * 0 = the row ends at a real (program-emitted) line break. NULL when the
    * snapshot couldn't query row state. Selection/copy uses these to rejoin a
    * wrapped logical line instead of inserting a hard newline at every visual
    * wrap. wrapped_row_count == rows on success. */
   const uint8_t *wrapped_rows;
   size_t wrapped_row_count;
   ```

2. **Populate it in the snapshot builder.** In
   `Sources/LabanTerminalCore/snapshot.c`, `laban_session_snapshot`:
   - Allocate `uint8_t *wrapped_rows = calloc((size_t)rows, sizeof(uint8_t));`
     next to the existing `dirty_rows` allocation (same NULL-tolerant pattern —
     all uses are guarded by `if (wrapped_rows)`).
   - In the per-row loop, extend the existing `ghostty_row_get_multi` call that
     reads `GHOSTTY_ROW_DATA_HYPERLINK` to also read `GHOSTTY_ROW_DATA_WRAP`,
     and store the result: `if (wrapped_rows) wrapped_rows[row_idx] = row_wrapped ? 1 : 0;`.
   - Set `snap->wrapped_rows = wrapped_rows;` and
     `snap->wrapped_row_count = wrapped_rows ? (size_t)rows : 0;` on the success
     path, next to `snap->dirty_rows` / `snap->dirty_row_count`.
   - In **both** early-exit cleanup paths that hand `dirty_rows` to
     `laban_snapshot_destroy` (the `snapshot_error` path and the
     `store_last_snapshot_dirty_rows` failure path), also set
     `snap->wrapped_rows = wrapped_rows;` so it is freed and does not leak.
   - In `laban_snapshot_destroy`, add `free((void *)snap->wrapped_rows);`.

3. **Rejoin wrapped rows in selection.** In
   `Sources/LabanCore/TerminalSelection.swift`:
   - Add a `trimTrailing: Bool = true` parameter to the private
     `snapshotLineText(...)` and only right-trim when it is true. (The default
     keeps every existing caller unchanged.)
   - Add a helper
     `private static func rowIsSoftWrapped(_ snap: LabanSnapshot, row: Int) -> Bool`
     that returns `true` iff `snap.wrapped_rows` is non-NULL,
     `0 <= row < snap.wrapped_row_count`, and `snap.wrapped_rows![row] != 0`.
   - Rewrite `selectedText(from snap:)` to walk the segments in order: for every
     segment except the last, if the row is soft-wrapped, append the row text
     **without** trailing-trim and **without** a `"\n"` separator (rejoining the
     logical line, keeping the wrapped row's trailing cells as real content); a
     non-wrapped, non-last row keeps its `"\n"`. The last row never gets a
     trailing separator (unchanged).

4. **Tests.** In `Tests/LabanCoreTests/TerminalSelectionTests.swift`, add:
   - `testSelectedTextJoinsSoftWrappedRowsWithoutNewline`: a fixture session
     sized narrow (e.g. `cols = 10`), write a 15-character run with no newline
     (`"abcdefghijklmno"`), poll, snapshot. Select from row 0 col 0 to row 1
     col 4 and assert the copied text is `"abcdefghijklmno"` (no `\n`).
   - `testSelectedTextKeepsNewlineBetweenHardBreakRows`: reuse the existing
     colored-box fixture (`selectionFixtureBytes`, three rows separated by
     `\r\n`), select all three rows, and assert the result contains `"\n"`
     between them — guarding against over-unwrapping real newlines.

## Concrete Steps

Run everything from the repository root `/Users/user/wrk/laban`.

1. Edit the four files as described in *Plan of Work*.
2. Run the focused tests:

   ```
   swift test --filter TerminalSelectionTests
   ```

   Expect all tests to pass, including the two new ones. Confirm the new
   soft-wrap test fails before step 3 (the Swift change) and passes after, e.g.
   by temporarily stashing only the `selectedText(from snap:)` change.
3. Run the broader core suites that touch selection/find/snapshot to catch
   regressions:

   ```
   swift test --filter LabanCoreTests
   ```

4. Optional manual end-to-end check: `./scripts/install-app`, relaunch Laban,
   and follow the steps in *Purpose / Big Picture*.

## Validation and Acceptance

- `swift test --filter TerminalSelectionTests` reports all tests passing.
  `testSelectedTextJoinsSoftWrappedRowsWithoutNewline` fails before the
  `TerminalSelection.selectedText(from:)` edit and passes after — this is the
  behavioral proof.
- `testSelectedTextKeepsNewlineBetweenHardBreakRows` passes, proving real
  newlines are preserved (no over-unwrapping).
- Existing selection tests (`testSelectedTextHelloMvpFromFixture`,
  `testSelectedTextRightTrimTrailingSpaces`,
  `testSelectedTextClampsOutOfRangeColumnsBeforeIndexingCells`,
  `testSelectedTextSkipsWideGlyphSpacerTail`,
  `testSelectedTextIncludesRowsOutsideVisibleViewport`) still pass unchanged.
- Manual: copying wrapped output from the visible screen pastes as one logical
  line; copying across distinct command outputs (real newlines) keeps the
  newlines.

## Idempotence and Recovery

All steps are plain source edits and test runs; re-running them is safe. If the
snapshot allocation for `wrapped_rows` ever returns NULL, the code falls back to
the previous always-`\n` behavior (every guard checks the pointer), so the
feature degrades gracefully rather than crashing.

## Decision Log

- Decision: Read libghostty's per-row `GHOSTTY_ROW_DATA_WRAP` and carry it as a
  `wrapped_rows` byte array on `LabanSnapshot`, mirroring the existing
  `dirty_rows` array; do the rejoin in `TerminalSelection.selectedText(from:)`.
  Rationale: the selection snapshot is already a real libghostty snapshot, so
  the data is one query away with no new wire format; mirroring `dirty_rows`
  reuses an established, NULL-tolerant pattern. This is exactly how Ghostty
  itself (same core) and kitty implement copy-unwrap.
- Decision: limit the fix to in-viewport selections; leave scrollback-spanning
  selections on the old behavior for now. Rationale: scrollback text comes from
  a separate plain-text extraction with no wrap bits; extending that ABI is a
  larger, separable change and the in-viewport case covers the reported bug.
- Decision: no user setting; make unwrap the default. Rationale: matches every
  mainstream terminal and is what the request asked for.

## Surprises & Discoveries

- Observation: the daemon shared-memory ring (`laband_snapshot_ring.h`) is not
  on the copy path; copy reads the app's local libghostty viewer snapshot via
  `session.snapshot()`. So no ABI-versioned ring change is needed.
- Follow-up: scrollback rows that have scrolled off-screen still copy with a
  `\n` per visual row, because `laban_session_scrollback_extract` emits plain
  text without per-row wrap flags. Closing this needs a scrollback-extract ABI
  extension (emit a per-row wrap byte alongside `row_offsets`).

## Outcomes & Retrospective

Implemented as planned with no surprises beyond those already noted. The
selection copy path reads the app's local libghostty viewer snapshot, so adding
one per-row `wrapped_rows` byte array to `LabanSnapshot` and consulting it in
`TerminalSelection.selectedText(from:)` was sufficient — no shared-memory ring
or scrollback-ABI changes. `swift test --filter LabanCoreTests` runs 689 tests
with 0 failures (3 pre-existing skips), including the two new tests. The
behavioral proof (`testSelectedTextJoinsSoftWrappedRowsWithoutNewline`) would
have failed under the previous unconditional `joined(separator: "\n")`, which
produced `"abcdefghij\nklmno"` instead of `"abcdefghijklmno"`.

Remaining: scrollback-spanning selections still copy one `\n` per visual row
(see *Surprises & Discoveries* follow-up).

## Progress

- [x] Add `wrapped_rows` / `wrapped_row_count` to `LabanSnapshot`
      (`LabanTerminalCore.h`).
- [x] Query `GHOSTTY_ROW_DATA_WRAP` and populate `wrapped_rows` in
      `snapshot.c`; free it in `laban_snapshot_destroy`; cover both cleanup
      paths.
- [x] Rejoin soft-wrapped rows in `TerminalSelection.selectedText(from:)`; add
      `trimTrailing` to `snapshotLineText` and the `rowIsSoftWrapped` helper.
- [x] Add the two tests (`testSelectedTextJoinsSoftWrappedRowsWithoutNewline`,
      `testSelectedTextKeepsNewlineBetweenHardBreakRows`).
- [x] `swift test --filter LabanCoreTests` green (689 tests, 0 failures).
