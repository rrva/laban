# ExecPlan: Codex Terminal-Capability Integration

## Why this matters

Laban is a macOS terminal emulator. OpenAI Codex is a coding-agent TUI that
runs *inside* a terminal. An audit of what Codex's TUI emits versus what Laban
supports found that Laban already handles almost everything Codex needs (kitty
keyboard protocol, bracketed paste, synchronized output, truecolor, inline
scrollback via scroll-regions + reverse-index, cursor position reports). Two
gaps remained, both about escape sequences that the vendored VT parser
(libghostty-vt) recognizes but never answers or surfaces:

1. **Default foreground/background color query (`OSC 10;?` / `OSC 11;?`).**
   On startup Codex asks the terminal "what are your default foreground and
   background colors?" so it can pick a light or dark theme that matches the
   window. libghostty-vt parses the query but its handler for it is a no-op
   (`stream_terminal.zig`, the `.query` arm of `colorOperation`). Laban stays
   silent, so Codex falls back to a dark-theme assumption. On a light Laban
   window Codex renders with the wrong theme (low-contrast, mismatched accents).
   **After this change:** Laban replies with its theme's actual fg/bg, so Codex
   adapts correctly. Observable: in a Codex session on a light theme, Codex's UI
   uses dark-on-light instead of its dark-mode palette.

2. **Desktop notifications (`OSC 9;<text>`).** Codex emits an `OSC 9` desktop
   notification on events like "agent turn complete" and "approval requested".
   Laban only had a bell-driven attention dot; it dropped `OSC 9` entirely.
   **After this change:** Laban surfaces an `OSC 9` notification as a native
   macOS user notification plus a per-tab attention badge, so a user who
   switches away from a Codex tab is told when Codex needs them or finishes.

   Note: Codex only *emits* `OSC 9` when its `notification_method` is `osc9`, or
   when it auto-detects a terminal on its allowlist (Ghostty/iTerm2/kitty/Warp/
   WezTerm). Every terminal on that auto-allowlist *also* makes Codex enable an
   inline-image protocol (kitty graphics) that Laban cannot render — so Laban
   must NOT masquerade as one of those (it would flood the screen with base64
   image data). Instead the user opts in with one line in `~/.codex/config.toml`:

   ```toml
   [tui]
   notification_method = "osc9"
   ```

   This is documented for the user; Laban's job is to handle `OSC 9` correctly
   when it arrives.

Both features are delivered in Laban's own C bridge (a "side-channel scanner"
on the raw PTY byte stream), the same established pattern as the existing
`osc133.c` and `tab_status.c` scanners — NOT by patching the vendored
libghostty-vt. This keeps the vendored library untouched (no rebuild, no new
patch under `patches/`) and matches how Laban already surfaces OSC sequences
libghostty parses but does not deliver.

### Terms

- **libghostty-vt**: vendored C/Zig terminal library at `.external/libghostty-vt`
  that parses the VT byte stream. Laban embeds its VT-only C API. ADR 0001.
- **Side-channel scanner**: a small byte-state-machine in `Sources/LabanTerminalCore`
  that scans the same PTY output bytes libghostty sees, to act on sequences the
  VT API does not expose. Existing examples: `osc133.c`, `tab_status.c`.
- **PTY output stream**: bytes the child process (the shell, or Codex) writes to
  its stdout. They arrive in `laban_vt_write_capture` (`capture.c`) and are fed
  to libghostty via `ghostty_terminal_vt_write`. An app's query (`OSC 10;?`) is
  part of this stream; the terminal answers by writing back to the PTY via
  `laban_write_terminal_response` (`terminal_effects.c`).

## Where the work happens

- `Sources/LabanTerminalCore/osc_host.c` (NEW): the combined scanner. Recognizes
  `OSC 9`, `OSC 10`, `OSC 11`. For `OSC 10;?` / `OSC 11;?` it writes a color
  reply. For `OSC 9;<text>` (excluding ConEmu `OSC 9;4;` progress reports) it
  fires a notification callback.
- `Sources/LabanTerminalCore/session_internal.h`: scanner struct + state enum +
  new `LabanSession` fields + `laban_scan_osc_host` declaration.
- `Sources/LabanTerminalCore/capture.c`: call `laban_scan_osc_host` after
  `ghostty_terminal_vt_write` (so a same-chunk color *set* is applied before a
  query reads it back).
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h`: public
  `LabanOSCNotificationCallback` typedef + `laban_session_set_osc_notification_callback`.
- `Sources/LabanCore/Session.swift`: `onOSCNotification: ((String) -> Void)?`
  property + C trampoline registration (mirrors `onBell`).
- `Sources/LabanCore/AppModel.swift`: forward the session notification to a
  model-level hook (mirrors the `onBell` → `bellAttention` path) and set a tab
  attention flag.
- `Sources/LabanApp/` (notifier): post a native macOS user notification via an
  injectable poster, wired in both `MainWindowController.makeAndShow` and
  `HeadlessDebugRuntime` per the parity hard-rule.

The color responder (feature 1) is pure C and needs no Swift. The notification
surface (feature 2) needs the Swift wiring above.

## Color reply format (feature 1)

Codex's parser (`codex-rs/tui/src/terminal_probe.rs`) accepts `rgb:RR/GG/BB`
(2 hex digits/channel) and `rgb:RRRR/GGGG/BBBB` (4 hex/channel), terminated by
either BEL (`\x07`) or ST (`\x1b\\`). It requires BOTH an `OSC 10` and an
`OSC 11` reply or it discards the result and defaults to dark. It picks light
vs dark by luminance of the background (`0.299R+0.587G+0.114B > 128`).

Laban replies with the 4-hex form, ST-terminated, for each query:

```
\x1b]10;rgb:RRRR/GGGG/BBBB\x1b\\      (foreground)
\x1b]11;rgb:RRRR/GGGG/BBBB\x1b\\      (background)
```

Each 8-bit channel `c` is written as `c` repeated to 4 hex digits (`%02x%02x`,
i.e. value*257), the canonical xterm widening.

Color source: `ghostty_terminal_get(terminal,
GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND/BACKGROUND, &rgb)` — the **effective**
color (OSC override or configured default), side-effect-free (does NOT touch
render-state dirtiness). Laban's `ThemePaletteInjector` feeds `OSC 10`/`OSC 11`
sets at session start, so this returns the exact theme fg/bg. If the getter
reports no value, fall back by `s->color_scheme`: dark → fg white / bg black,
light → fg black / bg white, so Codex always receives a usable pair.

## Notification payload (feature 2)

`OSC 9;<text>` with BEL or ST terminator. `<text>` is plain UTF-8 (e.g. "Agent
turn complete", "Approval requested: …"). Skip `OSC 9;4;…` (ConEmu progress).
The scanner caps `<text>` at a bounded buffer and passes it to the callback.

## Decision Log

- **Side-channel scanner, not a libghostty patch.** The user chose the
  side-channel approach. It avoids modifying/rebuilding vendored Zig and reuses
  the `osc133.c` / `tab_status.c` pattern. Trade-off: duplicates a little OSC
  parsing; acceptable and self-contained. A libghostty patch (à la ADR 0011)
  was the alternative.
- **Read color via `ghostty_terminal_get` (effective color), not render-state.**
  `ghostty_render_state_colors_get` requires `ghostty_render_state_update`,
  which consumes terminal row dirtiness and would steal frames from the
  renderer if called in the responder. The terminal-level effective-color
  getter has no such side effect.
- **Scan after `ghostty_terminal_vt_write`.** So a color *set* earlier in the
  same read chunk is applied before a query later in the chunk reads it back.
- **Do not masquerade as an OSC-9 terminal.** Every terminal on Codex's
  auto-OSC9 allowlist also turns on kitty-graphics, which Laban can't render.
  The user enables `OSC 9` via Codex config instead.

## Progress

- [x] Feature 1: `osc_host.c` color responder + scanner struct/fields + capture wiring + public header
- [x] Feature 1: C-bridge tests (set-then-query for fg and bg; no-reply for a set; light/dark fallback) — `LabanSessionTests.testOSC*`
- [x] Feature 2: `OSC 9` notification callback through C + Session.swift + AppModel attention/hook
- [x] Feature 2: native macOS notifier (`AgentNotificationPoster`) wired into MainWindowController + HeadlessDebugRuntime records `agent.notification` events (parity)
- [x] Feature 2: tests for OSC 9 parse (`testOSC9NotificationFiresCallbackAndIgnoresProgress`, `AppModelTests.testOSC9DesktopNotificationReachesAgentNotificationHook`)
- [x] `./scripts/build-app` green; `swift test` (LabanSessionTests + AppModelTests, 109 tests) green
- [x] ADR 0012 records the OSC side-channel *responder* boundary
- [ ] Optional follow-up: surface the recorded `agent.notification` events through a dedicated `GET /debug/...` endpoint (they already land in `/debug/events`)

## Outcomes & Retrospective

Both gaps are closed in Laban's own C bridge + Swift, with the vendored
libghostty-vt untouched. The audit's biggest surprise — that the kitty keyboard
protocol, synchronized output, inline scrollback, CPR, and truecolor were all
already supported — meant the real Codex work was just these two OSC seams.
User-facing reminder: Codex only emits `OSC 9` when `~/.codex/config.toml` has
`[tui] notification_method = "osc9"` (it must not be auto-detected, because every
terminal on Codex's auto-OSC9 allowlist also turns on kitty-graphics, which Laban
does not render). The OSC 10/11 color reply needs no Codex config and fixes the
theme-adaptation bug outright.

## Validation and Acceptance

C-bridge tests (in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`, using
the existing `feedOutput` / `drainResponse` helpers):

- Feed `OSC 11;#1a2b3c` (set bg) then `OSC 11;?`; drain must equal
  `\x1b]11;rgb:1a1a/2b2b/3c3c\x1b\\`.
- Feed `OSC 10;?` after setting fg; drain must echo the fg in `rgb:RRRR/GGGG/BBBB`.
- Feed only an `OSC 11;#…` set (no `?`); drain must be empty (sets are libghostty's job).
- With no theme configured, a query on a dark-scheme session must reply with a
  black background / white foreground (fallback), and light-scheme the inverse.
- Feed `OSC 9;Agent turn complete`; the registered notification callback fires
  with that exact text. Feed `OSC 9;4;1;50` (progress); the callback must NOT fire.

End-to-end: run Codex in a light-themed Laban tab → Codex uses a light theme.
Switch away from a Codex tab with `notification_method = "osc9"`; when Codex
finishes a turn, a macOS notification appears and the tab shows an attention badge.

Commands:

```
./scripts/build-app          # builds the app + C bridge
swift test                   # runs the XCTest suites
```
