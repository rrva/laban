# 16. Left-Drag Under Mouse Tracking Forwards To The App

Date: 2026-06-02

## Status

Accepted. Reverses the left-drag half of commit `b71ea98` ("a plain drag must
select text natively without the Shift bypass") and restores the MVP regression
contract (`docs/product/mvp.md`: "When terminal mouse tracking is active, mouse
events go to the terminal app rather than starting local text selection").
Preserves the *other* half of `b71ea98`: wheel input under mouse tracking still
drives the app's alternate-scroll (DECSET 1007) and Shift-wheel still scrolls
Laban's own scrollback.

## Context

When a fullscreen renderer (Claude Code, vim, tmux copy-mode, less) turns on
mouse tracking, *the app* interprets pointer events to run its own selection and
to scroll its own buffer. To select text spanning more than one screen the app
must keep receiving drag reports as the pointer leaves the bottom edge: it
clamps the reported cell to the last row and autoscrolls (tmux
`window_copy_drag_update` + a 50 ms `dragtimer`; the same model in iTerm2 and
Ghostty). This is the only way to copy multi-screen text in such an app — the
content below the viewport lives in the *app's* buffer, not Laban's scrollback,
so Laban cannot reveal it by scrolling its own viewport.

`b71ea98` introduced a "shift-free selection under tracking" behavior: a plain
left-drag was withheld (`pendingTrackingClick`) and, once it passed the click
tolerance, converted into a *Laban-native* selection instead of being forwarded.
A bare click was forwarded as a deferred press+release. This let users select
text without holding Shift, but it had two consequences:

- The app never received the drag, so it could never autoscroll its own
  selection. Laban's own drag autoscroll (`canApplyDragAutoscroll`) refuses to
  scroll *down* past the live bottom, so a native selection could not grow below
  the screen at all — multi-screen copy in a fullscreen renderer was impossible.
- It contradicted the MVP contract above, which already specifies that mouse
  events go to the app under tracking.

The encoder side was never the problem: libghostty's `mouse_encode.zig` already
clamps an out-of-viewport position to the last grid cell (`posToCell`) and still
emits a motion report when a button is held and the pointer is outside the
viewport (`posOutOfViewport` + `any_button_pressed`). It simply was never called
for this gesture.

## Decision

Under mouse tracking, a plain (no-Shift) left press/drag/release is **forwarded
to the app** as SGR mouse reports, the iTerm2/Ghostty model.

**Routing (`TerminalMouseInput.leftMouseDownDisposition`).** The disposition for
`mouseTracking && !shift` becomes `.forwardToApp` (was `.deferUnderTracking`).
Shift still returns `.localSelection`, and no-tracking still returns
`.localSelection`.

**Press on down (`TerminalBitmapView.mouseDown`).** The `.forwardToApp` case
dismisses any committed local selection (a forwarded press is a deliberate
pointer action, like a bare click), claims `trackedMouseButton = .left`, and
forwards a press report immediately via `forwardMousePress`. There is no longer
a withheld/deferred press: a bare click reports press-on-down and release-on-up,
the order apps expect.

**Motion and release reuse the existing forward paths.** Because
`trackedMouseButton` is now `.left`, the existing `mouseDragged` motion-forward
block and `mouseUp` release-forward block fire for the whole gesture. libghostty
clamps the cell and keeps reporting once the pointer leaves the viewport, so the
app sees bottom-row drag reports and runs its own autoscroll.

**Remote session encoding.** On `laband`, the viewer's local libghostty
instance is only a renderer mirror; it may not have parsed the child's `DECSET
1002/1006` mouse-mode output. The daemon snapshot contract therefore carries
the concrete mouse tracking mode and output format, and the viewer applies
those as explicit mouse-encoder options when forwarding mouse input to the
remote PTY. A boolean "mouse tracking active" is not enough: tmux copy-mode
needs button-event tracking plus SGR formatting preserved so a held drag below
the viewport encodes as a clamped bottom-row SGR motion report. `labpty` keeps
the byte-ring output parsed into the local viewer session, so its mouse mode is
still local state; its regression coverage must drive the real app-side
`TerminalBitmapView` + `AppSessionCoordinator(labptyClient:)` path.

**Removed machinery.** `pendingTrackingClick`/`PendingTrackingClick` and
`forwardDeferredTrackingClick` are deleted — forwarding the press on down makes
the click-vs-drag deferral unnecessary.

Shift remains the native-selection escape hatch (select + ⌘C copies via Laban),
and forwarded selections can still reach the host clipboard through the app's
own copy or the OSC 52 bridge (ADR 0014).

## Consequences

- Multi-screen selection and copy work in fullscreen renderers: dragging below
  the bottom edge forwards clamped bottom-row reports and the app autoscrolls.
  Matches iTerm2/Ghostty (including the "selects a bit too much" last-row
  artifact inherent to clamping).
- Plain left-drag under tracking no longer produces a Laban-native selection;
  users who want Laban's own selection hold Shift. Verified by
  `TerminalBitmapViewSelectionTests.testPlainDragUnderMouseTrackingForwardsToAppInsteadOfSelectingLocally`
  (forwarded, nothing local to copy) and
  `testShiftDragStartsLocalSelectionWhenMouseTrackingIsActive` (Shift still
  selects).
- A bare click under tracking still clears a leftover selection and forwards the
  click (`testClickClearsSelectionWhenMouseTrackingIsActive`).
- Wheel behavior is unchanged: forwarded scroll / DECSET 1007 under tracking and
  Shift-wheel local scrollback both still pass
  (`testWheelScrollPreservesSelectionWhenMouseTrackingIsActive`,
  `testShiftWheelScrollsLocalScrollbackUnderMouseTracking`).
- Disposition unit covered by `TerminalMouseInputTests.testLeftPressUnderTrackingForwardsToApp`.
- A standalone fixture (`bughunt/drag_select_scroll_repro.py`, a Claude-Code-style
  renderer that enables 1002+1006, owns the alt screen, autoscrolls on edge drag
  reports tmux-style, and logs every received event to a side channel) provides
  an end-to-end check that the forwarded drag reaches the app and drives its
  scroll; see `bughunt/DRAG_SELECT_SCROLL.md`.

## Applies To New Code

When a fullscreen app holds the mouse (mouse tracking), forward pointer gestures
to it rather than interpreting them locally; the app owns its selection and
scroll, and the terminal's job is only to forward clamped reports (libghostty
already clamps and reports out-of-viewport motion when a button is held). Keep
Shift as the universal native escape hatch (selection and scrollback), matching
iTerm2/Terminal.app/kitty. Do not gate a behavior the MVP regression contract
already specifies behind a newer convenience that silently overrides it.
