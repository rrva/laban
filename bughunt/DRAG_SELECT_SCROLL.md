# Drag-select past one screen in a fullscreen renderer

## Symptom

In a fullscreen mouse-tracking app (Claude Code, vim, tmux copy-mode, less),
holding the left button and dragging **below the bottom edge** should scroll the
app's view and grow the selection past one screen — that is how you copy text
spanning more than a screen. This works in iTerm2 and Ghostty (you "select a bit
too much" because the reported cell is clamped to the last row, but it also
scrolls). In Laban it did nothing: you could not select/copy more than one
screen.

## Root cause

Not a coordinate bug. libghostty's encoder (`src/input/mouse_encode.zig`)
already clamps an out-of-viewport position to the last grid cell (`posToCell`)
and still emits a motion report when a button is held outside the viewport
(`posOutOfViewport` + `any_button_pressed`). It was simply never called for this
gesture.

Commit `b71ea98` made a plain left-drag under mouse tracking start a
**Laban-native** selection ("shift-free selection") instead of forwarding it to
the app. So the app never received the drag and could not autoscroll. Laban's
own drag autoscroll also refuses to scroll *down* past the live bottom
(`TerminalScrollInput.canApplyDragAutoscroll`), and the content below the
viewport lives in the *app's* buffer, not Laban's scrollback — so a native
selection could never grow below the screen. This also violated the MVP contract
(`docs/product/mvp.md`: under mouse tracking, mouse events go to the app).

## Fix (ADR 0016)

Under mouse tracking, a plain (no-Shift) left press/drag/release is forwarded to
the app as SGR reports (iTerm2/Ghostty model). The press is sent on `mouseDown`
and `trackedMouseButton` is claimed, so the existing motion/release forward paths
fire for the whole gesture. Shift still forces Laban-native selection; the
wheel→DECSET 1007 behavior from `b71ea98` is preserved. See
`docs/adr/0016-left-drag-under-mouse-tracking-forwards-to-app.md`.

## How the reference apps scroll (tmux)

`window-copy.c → window_copy_drag_update`: on each drag report, extend the
selection; if the reported row is `0` or `screen_size_y-1`, scroll
(`window_copy_cursor_up/down`). A 50 ms `dragtimer` (`window_copy_scroll_timer`)
re-arms itself to keep scrolling while the button is held at the edge. The
terminal's only job is to keep forwarding clamped bottom-row reports.

## Repro / verification

`drag_select_scroll_repro.py` is a minimal Claude-Code-style renderer that does
exactly this: alt screen, mouse 1002+1006, its own scroll buffer, tmux-style
edge autoscroll (per-report + held-at-edge timer), and a side-channel log of
every received event.

```sh
MOUSE_TUI_LOG=~/laban-mouse-tui.log python3 bughunt/drag_select_scroll_repro.py
tail -f ~/laban-mouse-tui.log    # in another pane
```

Drag the left button below the bottom edge. The log is ground truth:

- **Fixed Laban / iTerm2 / Ghostty:** a stream of `mouse.motion` + `edge-scroll`
  lines; the final `selection.text` spans more than one screen.
- **Broken Laban (pre-fix):** no `mouse.motion` during the drag (the drag was
  captured for a native selection), so the app never scrolls.

The app-side logic is unit-verifiable without a GUI by piping synthetic SGR
sequences into the script (stdin need not be a TTY); the routing decision is
covered by `TerminalMouseInputTests` and
`TerminalBitmapViewSelectionTests.testPlainDragUnderMouseTrackingForwardsToAppInsteadOfSelectingLocally`.
