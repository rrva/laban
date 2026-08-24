# OSC 133 prompt-reset of stuck interactive modes

## Purpose / Big Picture

When a mouse-tracking TUI (vim, less, an agent TUI over ssh, …) dies without
sending its teardown sequences (`CSI ? 1002 l`, `CSI ? 1006 l`, focus-report
off `CSI ? 1004 l`, cursor show `CSI ? 25 h`), the terminal keeps those modes
on forever. In Laban the user then sees two symptoms at the returned shell
prompt:

- Drag-selecting text is routed to the (dead) app as SGR mouse reports
  (`ESC[<0;13;28M` … `ESC[<32;…M` … `ESC[<…m`), which zsh echoes as visible
  garbage text. Confirmed with capture
  `~/Library/Logs/Laban/captures/appkit-2026-08-23T13-05-58Z`:
  `streams/pty-input.bin` contains a full drag gesture encoded as SGR mouse
  reports and `streams/pty-output.bin` shows zsh echoing them.
- Focus changes inject `ESC[I` / `ESC[O` into the prompt line, and the cursor
  can stay invisible.

Neither libghostty-vt nor Laban clears these modes on child exit (child exit
is invisible to the VT layer), and libghostty-vt does not implement DECSTR
(`CSI ! p`), so nothing ever recovers.

This plan adds a **prompt-reset policy** to LabanTerminalCore: Laban already
scans the raw PTY output stream for OSC 133 ("semantic prompt") shell
integration markers in `Sources/LabanTerminalCore/osc133.c`. When a command
*ends* (`OSC 133 ; D`) the scanner records which interactive modes are
currently on; when the next prompt *starts* (`OSC 133 ; A`) it clears exactly
those modes. A shell prompt never legitimately needs mouse reporting, focus
reporting, or a hidden cursor, and the modes are re-asserted by any
well-behaved TUI on its next launch, so clearing at the prompt is safe.

After this change: kill a mouse-tracking TUI (e.g. drop the ssh connection
under a fullscreen app), return to the prompt, drag-select text — a native
Laban selection starts instead of escape-sequence garbage being typed.

## Orientation for a novice

- `Sources/LabanTerminalCore/` is a C target wrapping the vendored
  libghostty-vt parser (`.external/libghostty-vt/`). Do not modify the
  vendored library; this policy lives entirely in Laban's sidecar layer.
- `Sources/LabanTerminalCore/capture.c` (`laban_vt_write_capture`) feeds every
  output byte chunk through four raw-stream scanners before/while writing to
  libghostty. One of them is `laban_scan_osc133` in
  `Sources/LabanTerminalCore/osc133.c`, which parses `ESC ] 133 ; <action>
  BEL/ST` and fires a callback into Swift (`Sources/LabanCore/Session.swift`).
- The scan path always runs under the session lock:
  `laban_session_feed_output` / fixture writes take `SESSION_LOCK(s)`
  (`Sources/LabanTerminalCore/session_lifecycle.c:884`) before calling
  `laban_vt_write_capture`. Functions ending in `_locked` require that lock.
- libghostty modes are read with `laban_session_mode_active_locked(s,
  GHOSTTY_MODE_*, &active)` and written with
  `ghostty_terminal_mode_set(s->terminal, GHOSTTY_MODE_*, bool)`. The relevant
  mode constants (`GHOSTTY_MODE_X10_MOUSE` 9, `GHOSTTY_MODE_NORMAL_MOUSE`
  1000, `GHOSTTY_MODE_BUTTON_MOUSE` 1002, `GHOSTTY_MODE_ANY_MOUSE` 1003,
  `GHOSTTY_MODE_FOCUS_EVENT` 1004, `GHOSTTY_MODE_CURSOR_VISIBLE` 25) come from
  `.external/libghostty-vt/include/ghostty/vt/modes.h`. Clearing the *event*
  modes is sufficient; the *format* modes (1005/1006/1015/1016) are inert once
  no event mode is on and are left alone.
- Snapshots (`laban_session_snapshot`, fields in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`:
  `mouse_tracking`, `focus_reporting`, `cursor_visible`) derive from those
  modes, so the app picks up the reset on its next snapshot — no UI change is
  needed.
- Tests live in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`.
  `makeFixtureSession()` creates a fixture session (no real process);
  `writeBytes(session, bytes)` pushes bytes as if the program printed them.
  Run them with:
  `swift test --filter LabanSessionTests` from the repository root.

## Behavior specification

State: add one field `unsigned reset_mask` to `LabanOSC133Scanner` in
`Sources/LabanTerminalCore/session_internal.h` (zero-initialized at session
create like the rest of the struct).

Bits (defined in `osc133.c`):

- `O133_RESET_MOUSE` — at `D`, any of modes 9/1000/1002/1003 was on.
- `O133_RESET_FOCUS` — at `D`, mode 1004 was on.
- `O133_RESET_CURSOR` — at `D`, mode 25 (cursor visible) was OFF.

Rules, applied in `parse_osc133_payload` in `Sources/LabanTerminalCore/osc133.c`:

1. On `D` (command end): recompute `reset_mask` from the current mode state
   (as above). This doubles as the "a command ran" flag: a mask of 0 means
   the command left nothing stuck and the next `A` is a no-op.
2. On `A` (prompt start): if `reset_mask != 0`, clear modes 9/1000/1002/1003
   and 1004 (when the corresponding bits are set) and set mode 25 on (when
   the cursor bit is set), then zero `reset_mask`. Do this BEFORE invoking
   the OSC 133 callback so observers see post-reset state.
3. `B` and `C` do not touch the mask.
4. The scanner currently early-returns when no Swift callback is registered
   (`if (!s->osc133_callback) return;` in `laban_scan_osc133`). Remove that
   gate so the reset works in sessions without an observer (daemon,
   fixture, dump tools); the callback *dispatch* stays conditional. This
   matches `decscusr.c`, whose scanner is also behavioral and ungated.
5. Also document the side effect on the OSC 133 callback comment in
   `Sources/LabanTerminalCore/include/LabanTerminalCore.h` (the block above
   `LABAN_OSC133_PROMPT_START`, around line 424).

Ordering note (why this is safe): `laban_scan_osc133` runs on a chunk BEFORE
that chunk is written into libghostty (`capture.c` calls
`laban_scan_osc_host_vt_write` afterwards). A mode enable that arrives in the
same chunk after the `A` marker is therefore applied by libghostty after our
reset and survives; a mode that was on when `D` was scanned was genuinely set
earlier in the stream.

## Progress

- [x] Diagnose root cause from capture `appkit-2026-08-23T13-05-58Z`
- [x] Write this ExecPlan
- [x] Add `reset_mask` to `LabanOSC133Scanner` (`session_internal.h`)
- [x] Implement record-at-D / reset-at-A in `osc133.c`, ungate the scanner
- [x] Document the side effect in `include/LabanTerminalCore.h`
- [x] Add regression tests in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`
- [x] `swift test --filter LabanSessionTests` passes
- [x] `swift build` full package passes

## Validation and Acceptance

New tests in `LabanSessionTests.swift` (all use fixture sessions + snapshots):

1. `testPromptResetClearsStuckModesAfterCommandEnd`: feed `ESC[?1002h
   ESC[?1006h ESC[?1004h ESC[?25l`, then `OSC 133;D;0 BEL`, then `OSC 133;A
   BEL` → snapshot shows `mouse_tracking == 0`, `focus_reporting == 0`,
   `cursor_visible == 1`. This test never registers an OSC 133 callback, so
   it also proves the reset fires without an observer.
2. `testPromptResetSkipsBarePromptStart`: feed the same enables, then only
   `OSC 133;A BEL` (no `D`) → all modes unchanged (mouse tracking still on).
3. `testPromptResetSparesModesEnabledBetweenCommandEndAndPrompt`: feed
   `OSC 133;D;0 BEL`, then `ESC[?1002h` (separate write), then `OSC 133;A
   BEL` → `mouse_tracking == 1` (a shell deliberately enabling mouse in its
   prompt hook is not clobbered, because at `D` the mode was off).

Manual end-to-end check (optional but recommended): run the app, run
`printf '\e[?1002h\e[?1006h'` to simulate a stuck TUI, drag-select text and
observe SGR garbage at the prompt (bug repro), then run any command (e.g.
press Return) so `D`/`A` markers fire, and drag-select again — a native
selection must start and no bytes reach the pty.

Full gate: `swift test --filter LabanSessionTests` and `swift build`.

## Decision Log

- **Clear at prompt (`A` after `D`), not on child-process exit.** Child exit
  is invisible to the VT layer and would not cover the observed failure (a
  TUI inside a long-lived shell killed by a dropped ssh connection). The
  prompt marker is the only reliable "a command ran and is gone" signal.
- **Record the mask at `D`, clear at `A`.** Computing the mask at `D` rather
  than at `A` protects a shell that deliberately enables mouse reporting in
  its prompt hook (between `D` and `A`): the mode was off at `D`, so nothing
  is cleared. The mask doubling as the "a command ran" flag also means a
  bare `A` (first prompt, apps emitting their own `A` without `D`) never
  resets anything.
- **Known, accepted blind spot:** a mouse-tracking TUI that emits its own
  OSC 133 `D`…`A` cycles for internal prompts would have its mouse mode
  cleared at each internal prompt. No mainstream TUI does this; if one
  appears, the policy can gain an alt-screen exemption.
- **Do not patch libghostty-vt** (e.g. implementing DECSTR). Correct but
  orthogonal: nothing in the observed failure sent DECSTR, and the repo
  prefers keeping the vendored library diff minimal (`patches/`).
- **Scanner runs unconditionally now.** The reset is behavior, not
  observation, so it must not depend on a Swift callback being registered.
  Marginal cost: one extra vectorized ESC-scan over ESC-containing chunks in
  sessions without an OSC 133 observer, same class of cost `decscusr.c`
  already pays.
