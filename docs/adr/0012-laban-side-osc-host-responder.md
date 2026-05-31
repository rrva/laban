# 12. Laban-Side OSC Host Responder for Parsed-But-Undelivered Sequences

Date: 2026-05-30

## Status

Accepted.

Extends the observe-only side-channel scanner pattern (`osc133.c`,
`tab_status.c`) to also *answer* and *surface* OSC sequences. Does not change the
ADR 0001 boundary (libghostty still owns VT parsing) and does not patch the
vendored library (contrast ADR 0011).

## Context

The vendored libghostty-vt (ADR 0004 pin) parses several OSC sequences but its
VT-only C API neither delivers nor answers them. Two of these matter for the
OpenAI Codex agent TUI running inside Laban:

- **`OSC 10;?` / `OSC 11;?`** — default foreground/background colour query. Codex
  probes this at startup to match its light/dark theme to the host window. In
  libghostty the handler is a no-op (`stream_terminal.zig`, the `.query` arm of
  `colorOperation`), so Laban stayed silent and Codex fell back to a dark-theme
  assumption — wrong on a light window.
- **`OSC 9;<text>`** — desktop notification (Codex "agent turn complete",
  "approval requested"). libghostty parses it; the VT API has no notification
  callback, so Laban dropped it (only BEL drove a tab attention dot).

The full apprt embedding API (`ghostty.h`) exposes clipboard/notification
callbacks, but Laban deliberately links only the VT-only API (ADR 0001). Two
existing Laban-side scanners already act on sequences the VT API omits, but both
are **observe-only**. Answering `OSC 10/11` requires *writing a reply back to the
PTY* — a capability the existing scanners did not exercise.

## Decision

Add a Laban-side raw-stream scanner, `Sources/LabanTerminalCore/osc_host.c`
(`laban_scan_osc_host`), run from `laban_vt_write_capture` **after**
`ghostty_terminal_vt_write` so a colour *set* earlier in a read chunk is applied
before a query later in the chunk reads it back. It:

- replies to `OSC 10;?` / `OSC 11;?` with the session's effective
  foreground/background colour, read side-effect-free via
  `ghostty_terminal_get(GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND/BACKGROUND)` (NOT
  `ghostty_render_state_colors_get`, which would consume render dirtiness), and
  written through the existing `laban_write_terminal_response` reply path. When
  no colour is configured it synthesises a black/white pair from the session's
  light/dark `color_scheme` so the querying app always gets a usable answer. The
  reply uses the xterm `rgb:RRRR/GGGG/BBBB` form, ST-terminated; Codex's parser
  accepts 2- or 4-hex with BEL or ST.
- delivers `OSC 9;<text>` to a new `LabanOSCNotificationCallback`
  (`laban_session_set_osc_notification_callback`), excluding ConEmu progress
  reports (`OSC 9;4;…`). `Session.onOSCNotification` re-exposes it in Swift;
  `AppModel.onAgentNotification` broadcasts it on the main queue and raises the
  per-tab attention indicator. The AppKit host posts a native macOS banner
  (`AgentNotificationPoster`); `HeadlessDebugRuntime` records an
  `agent.notification` event — the feature-parity requirement.

The OSC 10/11 reply is **always on** (no callback needed); it is terminal
behaviour. Codex only emits `OSC 9` when `~/.codex/config.toml` sets
`[tui] notification_method = "osc9"`; Laban must NOT masquerade as a terminal on
Codex's auto-OSC9 allowlist (Ghostty/iTerm2/kitty/WezTerm), because each of those
identities also makes Codex enable kitty-graphics, which Laban cannot render.

The alternative — patching libghostty's `.query` no-op (à la ADR 0011) — was
rejected for this change: the side-channel keeps the vendored library and its
build untouched, reuses the established scanner pattern, and can draw on
Laban-side state (theme colours, the AppModel notification surface) that the VT
layer does not hold.

## Consequences

- Codex (and any TUI) that queries `OSC 10/11` gets Laban's real theme colours
  and adapts light/dark correctly; `OSC 9` notifications reach a native banner
  and a tab badge. Verified by `LabanSessionTests.testOSC*` and
  `AppModelTests.testOSC9DesktopNotificationReachesAgentNotificationHook`.
- A second OSC parser now runs over the byte stream alongside libghostty. It is a
  bounded byte-state-machine with overflow guards (`OSC_HOST_PAYLOAD_MAX`), the
  same shape as `osc133.c`; cost is one extra linear scan per chunk.
- This is the first side-channel scanner that writes back to the PTY. Replies go
  through `laban_write_terminal_response`, the same path the libghostty WRITE_PTY
  effect uses (CPR/DA/XTVERSION), so they share its capture/backpressure
  handling and run under the same `SESSION_LOCK`.
- Lives in the shared C core, so all three session tiers (in-process, `laband`,
  `labpty`) inherit it, like the CPR/DA replies.

## Applies To New Code

When the VT-only libghostty API parses a sequence but does not deliver or answer
it, and the gap can be closed from Laban-side state or surfaced to the app layer,
prefer a Laban-side raw-stream scanner (`osc_host.c` / `osc133.c` / `tab_status.c`
pattern) over patching vendored libghostty. A scanner that *answers* must reply
through `laban_write_terminal_response` (never write the PTY directly), read
terminal state through side-effect-free getters (not the render-state snapshot),
and carry a C-bridge regression test using the `feedOutput` / `drainResponse`
harness. A scanner that *surfaces* state to the UI must be wired into both
`MainWindowController.makeAndShow` and `HeadlessDebugRuntime` (parity), with the
headless side recording an observable debug event.
