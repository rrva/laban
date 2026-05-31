#!/usr/bin/env python3
"""Minimal repro for the "selection stays pinned while text scrolls" bug.

It mimics exactly what Claude Code's fullscreen TUI does, which is what the
capture appkit-2026-05-31T10-47-26Z recorded:

  * switches to the ALTERNATE SCREEN  (\x1b[?1049h)
  * turns on MOUSE TRACKING           (\x1b[?1002h + SGR \x1b[?1006h)
  * owns its OWN scrollback: on a wheel event it repaints the visible window
    shifted by a few lines. It never uses the terminal's scrollback and never
    emits newlines that push rows into history -- it just redraws cells in
    place. The wheel byte sequence is consumed by THIS program, not the
    terminal.

Because the app moves its content by repainting, the terminal has no way to
know that "row 5" became "row 4". A terminal therefore has two sane choices
when the user has a selection and then scrolls a mouse-tracking app:

  (a) clear the selection            <- what iTerm does
  (b) leave the highlight pinned to the same grid cells while the text under
      it changes                     <- the Laban bug this repro demonstrates

HOW TO USE
  1. Run this inside Laban:           python3 selection_scroll_repro.py
  2. Drag-select a word or two on one of the numbered lines.
  3. Scroll the mouse wheel (up or down) WITHOUT releasing/clicking.
       -> Laban: the highlight box stays put while the numbered lines slide
          underneath it, so it now highlights different text.
       -> iTerm: the selection clears the moment the content scrolls.
  4. Press q (or Ctrl-C) to quit.

Run the identical steps in iTerm to see the contrast. The point of the repro
is the A/B, so it deliberately does nothing clever -- it is the smallest
possible "fullscreen app that manages its own scrollback".
"""

import os
import sys
import termios
import tty

# --- escape sequences -------------------------------------------------------
ALT_SCREEN_ON = "\x1b[?1049h"
ALT_SCREEN_OFF = "\x1b[?1049l"
HIDE_CURSOR = "\x1b[?25l"
SHOW_CURSOR = "\x1b[?25h"
# 1002 = report button press/release + motion while a button is held.
# 1006 = SGR extended encoding (\x1b[<b;x;y;M / m). This is the same pair
#        Claude Code enables, and it makes the wheel arrive as buttons 64/65.
MOUSE_ON = "\x1b[?1002h\x1b[?1006h"
MOUSE_OFF = "\x1b[?1002l\x1b[?1006l"
CLEAR = "\x1b[2J"
HOME = "\x1b[H"


def build_content(n):
    """n distinct, selectable lines. The leading number makes the scroll
    direction and amount unmistakable when text slides under a pinned box."""
    words = ("the quick brown fox jumps over the lazy dog while the "
             "five boxing wizards jump quickly past the sphinx of quartz")
    out = []
    for i in range(n):
        # rotate the sentence so each line reads differently
        ws = words.split()
        rot = ws[i % len(ws):] + ws[: i % len(ws)]
        out.append(f"Line {i:04d} | " + " ".join(rot))
    return out


def render(top, lines, rows, cols):
    """Repaint the visible window in place -- the crux of the repro.
    No scroll region, no newlines into history: pure cell overwrite, exactly
    like a TUI driving its own scrollback."""
    buf = [HOME]
    view_rows = rows - 1  # last row is the status bar
    for r in range(view_rows):
        idx = top + r
        text = lines[idx] if 0 <= idx < len(lines) else "~"
        buf.append("\x1b[K" + text[: cols])  # clear-to-eol then the line
        if r < view_rows - 1:
            buf.append("\r\n")
    # status bar (inverted), pinned to the bottom row
    status = (f" top={top}/{max(0, len(lines) - view_rows)}  "
              f"drag-select a word, then SCROLL the wheel  |  q to quit ")
    buf.append("\r\n\x1b[7m" + status[: cols].ljust(cols) + "\x1b[0m")
    sys.stdout.write("".join(buf))
    sys.stdout.flush()


def parse_mouse(seq):
    """Parse one SGR mouse report '\x1b[<b;x;y;M|m'. Returns button int or None.
    Wheel-up = 64, wheel-down = 65 (low 2 bits select direction)."""
    # seq looks like '<64;43;13M'
    try:
        body = seq[1:-1]  # strip leading '<' and trailing M/m
        b = int(body.split(";", 1)[0])
        return b
    except (ValueError, IndexError):
        return None


def main():
    lines = build_content(300)
    top = 0
    step = 3  # lines per wheel notch

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    sys.stdout.write(ALT_SCREEN_ON + HIDE_CURSOR + MOUSE_ON + CLEAR)
    sys.stdout.flush()
    try:
        tty.setraw(fd)
        cols, rows = os.get_terminal_size()
        render(top, lines, rows, cols)
        while True:
            ch = os.read(fd, 1)
            if not ch:
                break
            if ch in (b"q", b"\x03"):  # q or Ctrl-C
                break
            if ch != b"\x1b":
                continue
            # read the rest of an escape sequence
            nxt = os.read(fd, 1)
            if nxt != b"[":
                continue
            seq = b""
            while True:
                c = os.read(fd, 1)
                seq += c
                if c in (b"M", b"m", b"~") or c.isalpha():
                    break
            s = seq.decode("latin1", "replace")
            if not s.startswith("<"):
                continue
            btn = parse_mouse(s)
            cols, rows = os.get_terminal_size()
            view_rows = rows - 1
            max_top = max(0, len(lines) - view_rows)
            if btn == 64:      # wheel up
                top = max(0, top - step)
            elif btn == 65:    # wheel down
                top = min(max_top, top + step)
            else:
                continue
            render(top, lines, rows, cols)
    finally:
        sys.stdout.write(MOUSE_OFF + SHOW_CURSOR + ALT_SCREEN_OFF)
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
