# Selection stays pinned while a mouse-tracking app scrolls

## Symptom

In a fullscreen TUI (e.g. Claude Code), drag-select some text, then scroll the
mouse wheel. The selection highlight stays nailed to the same screen position
while the text slides underneath it, so it ends up highlighting *different*
text. iTerm does not do this — it clears the selection the moment the content
scrolls.

## What the capture proves

Capture: `~/Library/Logs/Laban/captures/appkit-2026-05-31T10-47-26Z`

- `mouseTracking: True` — the app (Claude Code) owns its own scrollback.
- 15 `updateSelection` events, all at `anchorRow:5 / focusRow:5` (cols 30–42).
  The selection is stored in **viewport-relative** coordinates.
- 41 `mouseWheel` events encoded as SGR mouse reports and **forwarded to the
  child**: `ESC[<64;43;13M` (wheel-up) and `ESC[<65;43;13M` (wheel-down).
- **Zero `clearSelection`** — the selection is never invalidated.
- `frames/frame-*.snapshot.json` row 5 `visibleText` cycles as you scroll:
  `const g = JSON.parse(...)` → `import { readFileSync ... }` → `` (blank) →
  back — i.e. the child repainted scrolled content into the same cells while
  the selection sat on row 5 the whole time.

## Mechanism

1. The app is on the **alternate screen** with mouse tracking on, so it owns
   scrollback. Laban has no scrollback to move here: `viewportOffset` stays 0.
2. Drag-select records a local selection at **viewport row 5** (viewport-
   relative coords; see `TerminalSelectionInput.swift`, `TerminalSelection.swift`).
3. Scroll → Laban encodes the wheel as an SGR mouse report and forwards it to
   the child. Laban's own `viewportOffset` does not change.
4. The child repaints scrolled content into the same grid cells.
5. Laban keeps painting the highlight at viewport row 5 because (a) the coords
   are viewport-relative and `viewportOffset` is unchanged, so
   `visibleRow()` still returns 5, and (b) nothing clears the selection on a
   forwarded wheel / alt-screen content change.

Result: a stale highlight pinned to the grid while text scrolls beneath it.

## Why "store absolute scrollback coordinates" is NOT the fix here

That change addresses a *different* case — tracking a selection through
**Laban's own** scrollback on the **primary** screen. In this repro the app
moves its content by repainting cells; there is no scrollback row to anchor to
and no signal that "row 5 became row 4". No terminal can track that. The sane
fix is what iTerm does: **invalidate the selection when the wheel is forwarded
to a mouse-tracking app, or when alt-screen content under the selection
changes.** (The primary-screen absolute-coordinate tracking is a separate,
worthwhile improvement, but it is orthogonal to this symptom.)

## Repro program

`selection_scroll_repro.py` — the smallest possible "fullscreen app that
manages its own scrollback". It reproduces the exact capture conditions:
alternate screen + mouse tracking (`?1002h` + SGR `?1006h`) + app-owned
repaint-on-wheel.

```
python3 bughunt/selection_scroll_repro.py
```

1. Run it in Laban. Drag-select a word on a numbered line.
2. Scroll the wheel (don't click). The highlight stays put; the numbered lines
   slide under it.
3. Run the identical steps in iTerm — the selection clears on scroll.
4. `q` (or Ctrl-C) to quit.

The A/B between the two terminals is the whole point.
