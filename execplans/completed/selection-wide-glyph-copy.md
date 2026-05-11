# Preserve Wide Glyph Text When Copying Selections

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Selection copy should return the characters the user sees. Wide glyphs such as CJK characters occupy two terminal cells: the first cell stores the character and the second is a spacer tail. After this change, selecting `中A` copies `中A`, not `中 A`.

## Progress

- [x] Read `Sources/LabanCore/TerminalSelection.swift` selected-text extraction.
- [x] Confirm `FrameProducer` treats `LABAN_CELL_WIDE_SPACER_TAIL` as part of the preceding wide glyph.
- [x] Skip spacer-tail cells when constructing selected text.
- [x] Add a regression test for copying a wide glyph followed by a narrow glyph.
- [x] Run focused selection tests and the full package suite.

## Outcomes & Retrospective

`TerminalSelection.selectedText(from:)` now ignores `LABAN_CELL_WIDE_SPACER_TAIL` cells instead of turning them into spaces. Normal empty cells still copy as spaces and the existing per-row right trim is unchanged. The new regression test writes `中A`, selects all visible cells, and verifies the copied text is exactly `中A`.

## Context and Orientation

`TerminalSelection.selectedText(from:)` walks selected cells in a `LabanSnapshot`, appending cell UTF-8 text when present and a space when the selected cell is empty. That matches normal empty terminal cells, but wide glyph spacer tails are intentionally empty cells that visually belong to the preceding character. The C ABI exposes this through `LabanCell.wide` with value `LABAN_CELL_WIDE_SPACER_TAIL`.

## Plan of Work

Update `TerminalSelection.selectedText(from:)` so cells whose `wide` field is `LABAN_CELL_WIDE_SPACER_TAIL` are skipped instead of converted into spaces. Keep all other empty cells as spaces so interior spacing and right-trim behavior remain unchanged. Add a fixture-session test in `Tests/LabanCoreTests/TerminalSelectionTests.swift` that writes `中A`, selects the visible span, and asserts the copied text is exactly `中A`.

## Validation and Acceptance

Run from `/Users/rrj/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter TerminalSelectionTests
rtk swift test
```

Acceptance: the new test fails before the change by copying `中 A`, then passes after spacer tails are skipped. Existing trailing-space selection tests must still pass.
