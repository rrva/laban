# Close the remaining gaps against the additional terminal-support spec

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

A clean-room terminal compatibility spec (delivered as
`/tmp/terminal-support-additional.md`, summarized below) describes everything a
terminal must support so a modern agent TUI — alternate screen, SGR styling,
kitty keyboard, SGR mouse, OSC 8/52, query/reply sequences — behaves natively.
An audit of Laban against that spec found it already supports nearly all of it
through the vendored VT library (libghostty-vt, see "Terms") and Laban's own
C bridge: alternate screen, scroll regions, synchronized output (mode 2026),
bracketed paste (mode 2004), focus reporting (mode 1004), kitty CSI-u and
xterm modifyOtherKeys keyboard protocols, SGR mouse with all four tracking
modes, every required SGR attribute including curly/dotted/dashed underlines
and underline colors, OSC 8 hyperlinks, OSC 52 clipboard, DA1/DA2, DECRQM,
CPR, XTVERSION, OSC 10/11 color queries (in request order), cursor styles
(DECSCUSR), and TERM/COLORTERM/TERM_PROGRAM/TERM_PROGRAM_VERSION advertising.

Four gaps remain. After this change:

1. **OSC 12 cursor-color query** — an app that asks `OSC 12 ; ? ST` ("what is
   your cursor color?") gets an `OSC 12 ; rgb:RRRR/GGGG/BBBB ST` reply instead
   of silence (spec §16.5).
2. **DECXCPR (`CSI ? 6 n`)** — the DEC-private cursor-position report is
   answered as `CSI ? row ; col R`. Today only the plain `CSI 6 n` form is
   answered; the `?` form is silently dropped. Apps prefer the `?` form
   because a plain `CSI row ; col R` reply is ambiguous with modified
   function-key input (spec §16.4, Test 23).
3. **Bracketed paste delivers escape bytes literally** — pasting text that
   contains `ESC [ 31 m` while bracketed paste (mode 2004) is on delivers
   those bytes unchanged between the `CSI 200~`/`CSI 201~` fenceposts, instead
   of replacing ESC with a space. Only an embedded end-marker `ESC [ 2 0 1 ~`
   is neutralized (its ESC becomes a space) because it is the one sequence
   that could break out of the paste bracket and inject commands (spec §9,
   Test 8).
4. **Hover motion under any-motion mouse tracking (mode 1003)** — when an app
   enables `CSI ? 1003 h` + `CSI ? 1006 h`, moving the pointer with no button
   held sends `CSI < 35 ; col ; row M` reports. Today Laban forwards press,
   drag, release, and wheel but never no-button motion (spec §12, Test 18).

## Terms

- **libghostty-vt**: the vendored C/Zig terminal library at
  `.external/libghostty-vt` that parses the VT byte stream and encodes
  keyboard/mouse/paste input. Laban embeds its VT-only C API (ADR 0001).
  `.external/` is shared between worktrees via symlink; the library is built
  by `scripts/fetch-libghostty-vt` which applies local patches from
  `patches/` and runs `zig build -Demit-lib-vt -Doptimize=ReleaseFast`.
- **OSC host scanner**: `Sources/LabanTerminalCore/osc_host.c`, a byte state
  machine that scans the same PTY output bytes libghostty sees and *answers*
  sequences libghostty parses but does not deliver (OSC 7/9/10/11/52/99/777).
  It interleaves `ghostty_terminal_vt_write` flushes so replies land in
  request order (ADR 0012 and the `flush_vt_pending` helper).
- **Fixture session**: a `LabanSession` created with `fixture_mode` so no real
  child process is spawned. Tests feed bytes with `laban_session_vt_write`-
  style helpers (`writeBytes`) and read Laban's replies with
  `laban_session_drain_response` (`drainResponse`) — see
  `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`.
- **DECXCPR**: DEC extended cursor position report. Request `CSI ? 6 n`,
  reply `CSI ? row ; col R` (1-indexed, honoring origin mode).

## Where the work happens

1. OSC 12: `Sources/LabanTerminalCore/osc_host.c` only —
   `osc_host_interesting()` adds 12, `dispatch_osc_host()` routes 12 to
   `respond_osc_color_query()`, which reads
   `GHOSTTY_TERMINAL_DATA_COLOR_CURSOR` and falls back to the foreground
   fallback (dark scheme → white, light → black) when no cursor color is set.
2. DECXCPR: new vendored patch
   `patches/libghostty-vt-0003-decxcpr-cursor-position-report.patch` touching
   three files inside `.external/libghostty-vt`:
   - `src/terminal/device_status.zig`: add entry
     `.{ .name = "cursor_position_dec", .value = 6, .question = true }`.
   - `src/terminal/stream_terminal.zig`: handle `.cursor_position_dec` in
     `deviceStatus()` with the same position computation as
     `.cursor_position` but the `\x1B[?{};{}R` reply format.
   - `src/termio/stream_handler.zig`: same addition (this file is not part of
     the lib-vt build but its `switch (req)` is exhaustive, so full-Ghostty
     builds would break without it).
   `scripts/fetch-libghostty-vt` gains the `git apply` line for 0003. The
   shared `.external` clone gets the patch applied and rebuilt in place
   (`zig build -Demit-lib-vt -Doptimize=ReleaseFast` from
   `.external/libghostty-vt`). A new ADR records the decision; the patch is
   upstreamable (upstream Ghostty also drops `CSI ? 6 n`).
3. Paste: `Sources/LabanTerminalCore/paste.c`,
   `laban_session_encode_paste_locked`. When bracketed paste is active, build
   `\x1b[200~` + payload + `\x1b[201~` directly, neutralizing any embedded
   `\x1b[201~` by replacing its ESC with a space; when not bracketed, keep
   delegating to `ghostty_paste_encode` (which strips unsafe control bytes
   and converts `\n` to `\r` — unchanged legacy semantics).
4. Hover motion: `Sources/LabanApp/TerminalBitmapView.swift`. `mouseMoved`
   additionally forwards a no-button motion `MouseEvent` when mouse tracking
   is active, deduplicated per terminal cell at the view level. The
   libghostty mouse encoder already drops the event unless the app enabled
   any-motion tracking (mode 1003) — `shouldReport` in
   `.external/libghostty-vt/src/input/mouse_encode.zig` — and already encodes
   no-button motion as button code 35, so the view does not gate on the
   specific tracking mode. The remote (laband/labpty) tier reuses the
   existing `remoteMouseEncoding(for:)` + `forwardEncodedMouseToDaemon`
   path, exactly like the drag handler.

## What is explicitly NOT a gap (verified during the audit)

- Reply ordering (spec §16): `laban_scan_osc_host_vt_write` interleaves VT
  writes with scanner dispatch so OSC replies precede a same-chunk DA1/CPR
  fence. Covered by `testOSCColorReplyPrecedesCursorPositionReplyWithinOneChunk`.
- DECRQM (`CSI ? mode $ p`): answered inside libghostty-vt via the session's
  `write_pty` effect for all spec-listed modes (1000/1002/1003/1004/1006/
  1049/2004/2026).
- Kitty keyboard push/pop/query, modifyOtherKeys, DA1/DA2, XTVERSION, ENQ:
  handled by libghostty-vt + `terminal_effects.c`.
- Environment advertising (spec §17): `TerminalIdentity`
  (`Sources/LabanCore/TerminalIdentitySettings.swift`) sets
  TERM_PROGRAM/TERM_PROGRAM_VERSION (honest `Laban` identity or
  `ghostty-compat`), and `build_spawn_env` filters inherited identity vars
  and sets `TERM=xterm-256color`, `COLORTERM=truecolor`.
- Multiplexer passthrough (spec §15): applies to multiplexers sitting between
  app and terminal; Laban is the outer terminal (laband/labpty pass raw
  bytes through unmodified), so no work is needed.
- Empty bracketed paste (Test 9) already emits both fenceposts.

## Progress

- [x] (2026-06-11) Audit of spec vs codebase; gap list confirmed (4 items).
- [x] (2026-06-11) Worktree rebased onto local main (terminal-identity work
      landed there and closed the spec §17 gap before this plan started).
- [ ] OSC 12 cursor-color query responder + tests.
- [ ] Bracketed paste literal passthrough + tests.
- [ ] DECXCPR vendored patch 0003 + fetch-script line + rebuild + ADR + tests.
- [ ] Hover motion forwarding under mode 1003 + tests.
- [ ] `./scripts/build-app` green; full `swift test` green.

## Decision Log

- Decision: answer OSC 12 in the OSC host scanner, not a vendored patch.
  Rationale: identical seam to the shipped OSC 10/11 responder (ADR 0012);
  the cursor color is exposed by `GHOSTTY_TERMINAL_DATA_COLOR_CURSOR`.
  Date/Author: 2026-06-11 / Claude.
- Decision: answer DECXCPR with a vendored patch (0003), not a scanner.
  Rationale: the reply must honor origin mode and land in exact stream order
  with other parser-emitted replies (DA1 sentinel batches); libghostty
  already owns both. The scanner would duplicate CSI parsing and re-derive
  cursor state. Precedent: ADR 0011 (patch 0001). Upstreamable.
  Date/Author: 2026-06-11 / Claude.
- Decision: in bracketed mode, preserve all pasted bytes except neutralizing
  embedded `ESC[201~`. Rationale: the spec (and xterm/kitty behavior) demand
  literal delivery inside the fence; the end-marker is the only sequence
  that can escape the fence, so neutralizing just it keeps the
  paste-injection defence without corrupting legitimate pastes (e.g.
  ANSI-colored snippets). Non-bracketed paste keeps the strict ghostty
  stripping. Date/Author: 2026-06-11 / Claude.
- Decision: hover motion is gated by the libghostty mouse encoder, not the
  view. Rationale: `shouldReport` already implements per-mode rules
  (1000 drops motion, 1002 needs a button, 1003 takes all); duplicating that
  in Swift invites drift. The view only dedups per cell to avoid flooding
  identical reports. Date/Author: 2026-06-11 / Claude.

## Validation and Acceptance

C-bridge tests in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`
(fixture session + `writeBytes` + `drainResponse`):

- Feed `OSC 12;#112233 BEL` then `OSC 12;? BEL`: drain equals
  `\x1b]12;rgb:1111/2222/3333\x1b\\`; the set alone replies nothing.
- With no cursor color set, dark scheme replies `rgb:ffff/ffff/ffff`, light
  scheme `rgb:0000/0000/0000`.
- Feed `CSI 4;7 H` then `CSI ? 6 n`: drain equals `\x1b[?4;7R`. Plain
  `CSI 6 n` still replies `\x1b[4;7R` (no `?`).
- Enable mode 2004, encode a paste containing `hello \x1b[31m world`: encoded
  bytes are `\x1b[200~hello \x1b[31m world\x1b[201~` (ESC preserved).
- Encode a bracketed paste containing `\x1b[201~`: the embedded end marker's
  ESC is replaced by a space; the fence still closes exactly once at the end.
- Non-bracketed paste still strips ESC and converts `\n` to `\r`.

App-level test (`Tests/LabanAppTests`): with a session that has modes
1003+1006 enabled, a synthesized `mouseMoved` over the terminal grid causes
`CSI < 35 ; col ; row M` to be written; a second `mouseMoved` within the same
cell writes nothing; tracking disabled writes nothing.

Commands:

```
./scripts/build-app
swift test
```

Manual end-to-end: run an app that enables 1003 (e.g. a TUI with hover
highlighting) and confirm hover reports arrive; `printf '\x1b[?6n'` inside a
raw-mode probe receives `\x1b[?row;colR`.

## Outcomes & Retrospective

(to be filled in when the plan completes)
