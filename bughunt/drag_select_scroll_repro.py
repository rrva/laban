#!/usr/bin/env python3
"""
mouse-report-tui — a minimal "Claude Code-style" fullscreen renderer for
testing a terminal emulator's mouse-reporting drag behavior.

It mimics how an app like Claude Code, vim, tmux copy-mode or less behaves:
it enables SGR mouse drag tracking, owns the alternate screen, and manages
its OWN scroll buffer. When a left-button DRAG report lands on the top or
bottom visible row it autoscrolls (tmux window_copy_drag_update style:
scroll on each motion report at the edge, plus a 50ms held-at-edge timer)
and extends a selection across the scroll. This is the behavior that lets
you select/copy text spanning more than one screen inside a fullscreen TUI.

It SELF-REPORTS everything it receives to a side-channel log so a human (or
an agent) can verify what the terminal actually forwarded:

    every parsed mouse event (raw bytes + action/button/col/row),
    every autoscroll tick, the live scroll offset and selection range,
    and the final extracted selection text on mouse-up.

See bughunt/DRAG_SELECT_SCROLL.md for the bug + the fix (ADR 0016).

USAGE (inside the terminal under test — Laban, iTerm, Ghostty, ...):

    MOUSE_TUI_LOG=~/laban-mouse-tui.log python3 bughunt/drag_select_scroll_repro.py

  Then press the LEFT mouse button on a line and drag DOWNWARD past the
  bottom edge of the window. A correct terminal keeps forwarding clamped
  bottom-row drag reports, so this TUI scrolls down and the selection
  grows past one screen. Watch the log in another pane:

    tail -f ~/laban-mouse-tui.log

  Press q (or Ctrl-C) to quit. The alt screen + mouse modes are restored.

The log is the ground truth: if the terminal does NOT forward the drag
(e.g. it captured it for a native selection instead), the log shows no
.motion events during the drag and the TUI never scrolls.
"""

import os
import re
import select
import shutil
import sys
import termios
import time
import tty

LOG_PATH = os.environ.get("MOUSE_TUI_LOG", os.path.expanduser("~/laban-mouse-tui.log"))

ESC = "\x1b"
# SGR mouse report: ESC [ < Cb ; Cx ; Cy (M|m)
SGR_RE = re.compile(r"\x1b\[<(\d+);(\d+);(\d+)([Mm])")

# --- the document this fullscreen app "owns" and scrolls through itself ---
NLINES = 500
_filler = "the quick brown fox jumps over the lazy dog "
DOC = [f"line {i:04d}  " + (_filler * 3)[: 60].rstrip() for i in range(NLINES)]


class TUI:
    def __init__(self):
        self.offset = 0           # index of the top visible document line
        self.anchor = None        # selection start (docrow, col)
        self.focus = None         # selection end   (docrow, col)
        self.edge_dir = 0         # held-at-edge autoscroll direction (-1/0/+1)
        self.last_col = 0         # column of the last motion (for timer extend)
        self.cols, self.rows = self._term_size()
        self.content_rows = max(1, self.rows - 1)  # last row is the status bar
        self.buf = ""             # partial-escape-sequence input buffer
        self.log = open(LOG_PATH, "a", buffering=1)
        self._logln(f"==== run start cols={self.cols} rows={self.rows} "
                    f"content_rows={self.content_rows} doc={NLINES} ====")

    # ---- plumbing ----------------------------------------------------------
    def _term_size(self):
        sz = shutil.get_terminal_size((80, 24))
        return sz.columns, sz.lines

    def _logln(self, msg):
        self.log.write(f"{time.time():.3f} {msg}\n")

    def _w(self, s):
        sys.stdout.write(s)

    def enter(self):
        self._w(ESC + "[?1049h")   # alternate screen — we own the screen
        self._w(ESC + "[?1000h")   # basic mouse button tracking
        self._w(ESC + "[?1002h")   # button-event (drag) tracking
        self._w(ESC + "[?1006h")   # SGR extended coordinates
        self._w(ESC + "[?25l")     # hide cursor
        sys.stdout.flush()

    def leave(self):
        self._w(ESC + "[?1002l")
        self._w(ESC + "[?1000l")
        self._w(ESC + "[?1006l")
        self._w(ESC + "[?25h")
        self._w(ESC + "[?1049l")   # restore primary screen
        sys.stdout.flush()

    # ---- scrolling / selection model --------------------------------------
    def max_offset(self):
        return max(0, NLINES - self.content_rows)

    def scroll(self, delta):
        new = max(0, min(self.offset + delta, self.max_offset()))
        changed = new != self.offset
        self.offset = new
        return changed

    @staticmethod
    def _ordered(a, b):
        return (a, b) if a <= b else (b, a)

    def _selected(self, docrow, col):
        if self.anchor is None or self.focus is None:
            return False
        lo, hi = self._ordered(self.anchor, self.focus)
        return lo <= (docrow, col) <= hi

    def selection_text(self):
        if self.anchor is None or self.focus is None:
            return ""
        lo, hi = self._ordered(self.anchor, self.focus)
        out = []
        for row in range(lo[0], hi[0] + 1):
            if not (0 <= row < NLINES):
                continue
            line = DOC[row]
            start = lo[1] if row == lo[0] else 0
            end = hi[1] if row == hi[0] else len(line) - 1
            out.append(line[start:end + 1])
        return "\n".join(out)

    # ---- rendering ---------------------------------------------------------
    def render(self):
        parts = []
        for r in range(self.content_rows):
            docrow = self.offset + r
            parts.append(ESC + f"[{r + 1};1H" + ESC + "[2K")
            if 0 <= docrow < NLINES:
                line = DOC[docrow][: self.cols]
                rendered = []
                for c, ch in enumerate(line):
                    if self._selected(docrow, c):
                        rendered.append(ESC + "[7m" + ch + ESC + "[27m")
                    else:
                        rendered.append(ch)
                parts.append("".join(rendered))
            else:
                parts.append("~")
        sel = ""
        if self.anchor and self.focus:
            sel = f"sel {self.anchor}->{self.focus}"
        status = (f" offset={self.offset}/{self.max_offset()}  {sel}  "
                  f"edge={self.edge_dir}   [drag below bottom to grow selection]  q=quit ")
        parts.append(ESC + f"[{self.rows};1H" + ESC + "[7m" + ESC + "[2K"
                     + status[: self.cols] + ESC + "[27m")
        self._w("".join(parts))
        sys.stdout.flush()

    # ---- mouse handling ----------------------------------------------------
    def handle_mouse(self, cb, cx, cy, final):
        col = cx - 1                      # viewport-relative, 0-based
        vrow = cy - 1
        button = cb & 0b11
        motion = bool(cb & 0b100000)      # bit 5 = drag/motion
        is_release = (final == "m")
        docrow = self.offset + max(0, min(vrow, self.content_rows - 1))
        self.last_col = col

        if is_release:
            action = "release"
        elif motion:
            action = "motion"
        else:
            action = "press"

        self._logln(f"mouse.{action} raw=ESC[<{cb};{cx};{cy}{final} "
                    f"button={button} vrow={vrow} col={col} -> docrow={docrow} "
                    f"offset={self.offset}")

        if action == "press" and button == 0:
            self.anchor = (docrow, col)
            self.focus = (docrow, col)
            self.edge_dir = 0
            return

        if action == "motion" and button == 0:
            self.focus = (docrow, col)
            # tmux-style: scroll on each motion report that lands on an edge row.
            if vrow >= self.content_rows - 1:
                self.edge_dir = 1
                if self.scroll(1):
                    self.focus = (self.offset + self.content_rows - 1, col)
                    self._logln(f"  edge-scroll down -> offset={self.offset} "
                                f"focus={self.focus}")
            elif vrow <= 0:
                self.edge_dir = -1
                if self.scroll(-1):
                    self.focus = (self.offset, col)
                    self._logln(f"  edge-scroll up -> offset={self.offset} "
                                f"focus={self.focus}")
            else:
                self.edge_dir = 0
            return

        if action == "release":
            self.focus = (docrow, col)
            self.edge_dir = 0
            text = self.selection_text()
            self._logln(f"  selection.final anchor={self.anchor} focus={self.focus} "
                        f"lines={text.count(chr(10)) + 1 if text else 0}")
            self._logln(f"  selection.text<<<\n{text}\n>>>")
            return

    def autoscroll_tick(self):
        """Held-at-edge continuous scroll (tmux dragtimer, 50ms)."""
        if self.edge_dir == 0:
            return False
        if self.scroll(self.edge_dir):
            vrow = self.content_rows - 1 if self.edge_dir > 0 else 0
            self.focus = (self.offset + vrow, self.last_col)
            self._logln(f"autoscroll.tick dir={self.edge_dir} -> offset={self.offset} "
                        f"focus={self.focus}")
            return True
        self.edge_dir = 0      # hit a bound; stop the timer
        return False

    # ---- input feed --------------------------------------------------------
    def feed(self, data):
        """Return False to request quit."""
        self.buf += data
        # quit keys
        if "q" in self.buf or "\x03" in self.buf:
            self._logln("quit requested")
            return False
        while True:
            m = SGR_RE.search(self.buf)
            if not m:
                # drop everything up to a lone ESC to avoid unbounded growth
                if len(self.buf) > 64 and ESC not in self.buf:
                    self.buf = ""
                break
            self.handle_mouse(int(m.group(1)), int(m.group(2)),
                              int(m.group(3)), m.group(4))
            self.buf = self.buf[m.end():]
        return True


def main():
    tui = TUI()
    is_tty = sys.stdin.isatty()
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd) if is_tty else None
    try:
        if is_tty:
            tty.setraw(fd)
        tui.enter()
        tui.render()
        idle_ticks = 0
        while True:
            timeout = 0.05 if tui.edge_dir != 0 else (None if is_tty else 0.0)
            r, _, _ = select.select([fd], [], [], timeout)
            if r:
                data = os.read(fd, 4096)
                if not data:                      # EOF (piped self-test)
                    # drain a bounded number of held-at-edge ticks, then stop
                    while tui.autoscroll_tick() and idle_ticks < NLINES:
                        idle_ticks += 1
                    break
                if not tui.feed(data.decode("latin-1", "replace")):
                    break
            else:
                # timer fired with no input: continuous held-at-edge scroll
                if not tui.autoscroll_tick() and not is_tty:
                    idle_ticks += 1
                    if idle_ticks > 2:
                        break
            tui.render()
    finally:
        tui.leave()
        if is_tty and old is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        tui._logln("==== run end ====")
        tui.log.close()


if __name__ == "__main__":
    main()
