# Keep Native Text Input In Charge During IME Composition

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Users composing text with an input method editor should see candidate windows at the cursor, commit text cleanly, and keep composition ownership inside AppKit until the IME is done. After this change, committed marked text clears the marked state, command-modified keyDown events route through native text input while text is marked, and IME candidate positioning uses the cursor cell instead of the screen origin.

## Progress

- [x] Read `TerminalBitmapView` layer setup and `NSTextInputClient` methods.
- [x] Read `TerminalInputView` routing and existing key routing tests.
- [x] Swap Metal layer install order so `self.layer` is set before `wantsLayer`.
- [x] Clear marked text on commit in `insertText`.
- [x] Route keyDown through native text input when marked text exists.
- [x] Compute `firstRect(forCharacterRange:)` from the terminal cursor cell.
- [x] Add focused routing/geometry tests where the behavior can be unit-tested.
- [x] Run focused App tests and the full package suite.

## Context and Orientation

`TerminalBitmapView` implements `NSTextInputClient`, the AppKit protocol used by IMEs. `hasMarkedText()` reports whether an IME composition is active. When it is active, AppKit should receive keyDown events first so composition can finish or transform; terminal app commands should not preempt the IME. `firstRect(forCharacterRange:)` returns a screen-space rectangle where macOS places the candidate window. Returning `.zero` sends it to the screen origin. The view renders terminal rows top-down through `FrameProducer`: row 0 is at the top of the terminal area, so a cursor row maps to `originY + (rows - 1 - cursorRow) * cellHeight` in view coordinates.

## Plan of Work

Add a `route(hasMarkedText:)` overload to `TerminalKeyDescriptor` and use it from `TerminalBitmapView.keyDown(with:)`. When `hasMarkedText` is true and the event is a key press, return `.nativeText` before command routing. In `insertText`, call `unmarkText()` before sending committed bytes or key events. In `firstRect(forCharacterRange:)`, snapshot the active session, compute the cursor cell view rect, convert it through the window into screen coordinates, and return that rectangle. Swap layer setup to assign `self.layer` before setting `wantsLayer = true`.

Add unit coverage for routing and cursor-rect math in the App tests. Full `NSTextInputClient` behavior still requires AppKit integration, so the tests cover the pure routing and geometry decisions.

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter TerminalKeyInputTests
rtk swift test
```

Acceptance: command keys normally remain app commands, command keys route to native text while marked text exists, and cursor rect math returns the expected cell rectangle for a top-down terminal grid.

Validated on 2026-05-05:

```sh
rtk swift test --filter TerminalKeyInputTests
rtk swift test
```
