# Font-Resize Flicker (Alt-Screen TUIs) — Not a Laban Renderer Bug

Status: **diagnosed, won't fix (upstream semantics)**. Verified 2026-07-19;
user reproduced the identical behavior in Terminal.app.

## Symptom

With a fullscreen alt-screen TUI (Claude Code), increasing the font size
(`Cmd+=`) produces visible flicker/jumpiness: the screen goes mostly blank
for ~60–80 ms per font step. Decreasing the font size never flickers.

## Verdict

The renderer and present path are **exonerated**. The blank frames are real
terminal-model data loss inherited from libghostty-vt resize semantics,
which deliberately match Terminal.app. The TUI repaints after SIGWINCH
(~60–80 ms), which is the visible blank window.

## Evidence (composite two-channel capture)

Captured with the composite capture mode (no renderer perturbation):

```sh
LABAN_CAPTURE_DIR=<dir> LABAN_CAPTURE_SCREENSHOTS=composite \
  .build/laban/Laban.app/Contents/MacOS/LabanApp
# Cmd+Shift+R to start/stop
```

- `window/grab-*.png` (composited window, what hit the screen) and
  `frames/*.snapshot.json` (terminal model) **agree exactly** at every
  flicker frame — e.g. grab-000192 (52 KB, near-blank) matches snapshot
  frame 781, where the model itself has lost the header rows.
- PNG sizes oscillate (86→52→98 KB…) only during font-*increase* phases;
  font-*decrease* phases are monotone. This mirrors the model asymmetry.

## Mechanism (libghostty-vt, vendored pin 46d54ed)

1. `laban_session_resize` → `ghostty_terminal_resize` → `Terminal.resize`
   resizes the alt screen with `reflow = false` (hardcoded,
   `.external/libghostty-vt/src/terminal/Terminal.zig:2906-2911`).
2. Height shrink: `PageList.resizeWithoutReflow` `.lt` branch
   (`PageList.zig:2078-2095`) trims trailing *blank* rows only
   (Terminal.app parity, per code comment); a fullscreen TUI has text on
   nearly every row, so the top Δrows are converted to history.
3. Alt screen is `no_scrollback`, so `Screen.resize`
   (`Screen.zig:1772-1777`) immediately `eraseHistory()` — the top rows are
   physically deleted from the model.
4. Height grow (font decrease) adds blank rows at the bottom; top-anchored
   content is untouched. Hence the asymmetry.

## Why not patched

- Behavior is intentional upstream (Terminal.app parity); reproduced in
  Terminal.app by the user.
- A fix means a fourth vendored patch adding bottom-trim with tracked-pin
  relocation to `PageList` (strict integrity invariants, cursor clamping
  edge cases) plus rebase cost on every ghostty pin bump — to cosmetically
  cover a window the TUI repaints over anyway.
- An app-side present-hold would show *stale* frames and muddy the
  model/screen correspondence that made this diagnosable.

If this ever becomes worth fixing, the correct seam is libghostty
`PageList`/`Screen.resize` (pin top-anchored rows on alt-screen shrink),
not the Laban renderer.

## Re-diagnosis recipe

Composite capture as above; correlate `session.resized` events
(`cellHeight` delta = font direction; `pixelWidth/Height` stay constant
during font bumps) with grab sizes and `frames/*.snapshot.json` content.
