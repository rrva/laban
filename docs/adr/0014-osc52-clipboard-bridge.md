# 14. OSC 52 Clipboard Bridge (write-on, read-opt-in)

Date: 2026-05-31

## Status

Accepted.

Extends the ADR 0012 Laban-side OSC host responder (`osc_host.c`) to a third
direction — the system clipboard — adding both the *write* (set clipboard) and
*read* (query clipboard) halves of OSC 52. Does not change the ADR 0001 boundary
(libghostty still owns VT parsing) and does not patch the vendored library
(contrast ADR 0011).

## Context

The codex-compatibility inventory (session `f710dcd1`) flagged OSC 52 as the
last unimplemented terminal-capability gap after OSC 10/11 and OSC 9 shipped
(ADR 0012). The vendored libghostty-vt (ADR 0004 pin) parses `OSC 52` internally
as `clipboard_contents`, but the VT-only C API Laban links registers no
clipboard sink, so the sequence is parsed and dropped — the bridge even
documented this in a `terminal_effects.c` comment.

`OSC 52 ; Pc ; Pd ST` carries a selection list `Pc` (`c` clipboard, `p` primary,
`s`, `q`, `0`-`7`) and a payload `Pd` that is either base64 (set the selection)
or a lone `?` (query it). Its headline use is **copy from a program reached over
SSH**: an editor or coding agent on the remote host has no access to the local
macOS pasteboard, so it emits `OSC 52 ; c ; <base64>` and the terminal places the
data on the host clipboard. OpenAI Codex uses OSC 52 exactly this way — a
fallback when its native `arboard` clipboard is unreachable (i.e. over SSH),
capped at 100 KB raw (`codex-rs/tui/src/clipboard_copy.rs`).

The *read* direction (`OSC 52 ; c ; ?`) is the inverse and is a known
exfiltration vector: it lets a remote program pull the host clipboard over the
wire. xterm gates it behind `allowWindowOps`; many terminals ship it off.

Two constraints shaped the design:

- **AppKit boundary.** `NSPasteboard` lives in `LabanApp`; the C scanner and
  `AppModel` live in the AppKit-free core. So the clipboard touch must cross the
  same seam OSC 9 uses: C callback → `Session` → `AppModel` closure → the AppKit
  host (and `HeadlessDebugRuntime` for parity).
- **Lock ordering / thread.** The scanner fires on the PTY reader thread with
  the session lock held. `NSPasteboard` work must hop to the main queue (matching
  `attachOSCNotification`), so a synchronous "read the clipboard now" callback
  off the reader thread is unsafe. The read path is therefore an async
  request/response: a read callback asks the host, the host answers later.

- **Payload size.** Clipboard data dwarfs the inline notification/colour payload
  (`OSC_HOST_PAYLOAD_MAX`, 512 B). OSC 52 needs its own buffer.

## Decision

Recognise `OSC 52` in `laban_scan_osc_host` and bridge it to the macOS clipboard,
keeping all base64 + `NSPasteboard` work in Swift and the C side limited to byte
buffering and the PTY reply envelope.

**Scanner (`osc_host.c`, `session_internal.h`).** `52` joins the "interesting"
set. Its payload accumulates in a *separate, lazily heap-allocated* buffer
(`osc52_buf`, grown to `OSC_HOST_OSC52_MAX` = 256 KiB, freed at destroy) rather
than the 512 B inline buffer; a payload past the cap is dropped, never truncated.
On the terminator the payload `<Pc>;<Pd>` is split on the first `;`:

- `Pd == "?"` → fire `LabanOSCClipboardReadCallback(selection)` **only if**
  `osc52_read_enabled` (default 0). Otherwise drop silently — no reply.
- empty `Pd` → ignored (xterm clears the selection here; Laban refuses so a stray
  sequence cannot wipe the user's clipboard).
- otherwise → fire `LabanOSCClipboardWriteCallback(selection, base64)` with the
  raw base64 (not decoded — the C side does no base64).

**Reply (`laban_session_respond_clipboard_osc52`).** Assembles
`ESC ] 52 ; <selection> ; <base64> ST` and writes it through
`laban_write_terminal_response` (the ADR 0012 reply path: shared capture,
backpressure, `SESSION_LOCK`).

**Codec (`OSC52Clipboard`, LabanCore).** A pure, unit-tested base64 + size-policy
type shared by the `Session` bridge and the headless runtime. `decodeWrite`
rejects invalid base64 and anything over 192 KiB (the decoded ceiling matching
the 256 KiB wire cap); `encodeRead` produces the reply payload.

**Bridge + app wiring.** `Session.onClipboardWrite` (decoded `Data`),
`Session.onClipboardReadRequest` (selection), `Session.clipboardReadEnabled`, and
`Session.respondClipboardRead(selection:data:)` mirror the OSC 9 callback
plumbing. `AppModel` re-broadcasts on the main queue via `onClipboardWrite`,
`clipboardReadProvider`, and `osc52ReadEnabled`. The AppKit host
(`MainWindowController`) writes/reads `NSPasteboard` via new
`TerminalClipboard.writeOSC52` / `osc52ReadData` helpers; `HeadlessDebugRuntime`
records a `clipboard.osc52Write` event and serves its debug clipboard — the
feature-parity requirement.

**Security stance: write-on, read-opt-in.** Write is always honoured when a
handler is set — copy-from-remote is the point, and a remote setting your
clipboard is a nuisance at worst. Read defaults **off** (`osc52ReadEnabled =
false`); a `?` query is dropped with no reply unless the host opts in, so a
remote program cannot read the host clipboard unasked. This matches xterm's
`allowWindowOps` posture. Paste *into* a remote program already works through
normal bracketed paste and does not use OSC 52 read, so the headline
"copy-paste over SSH" works out of the box with read still disabled.

The alternative — patching libghostty to surface its parsed `clipboard_contents`,
or linking the apprt `ghostty.h` clipboard callbacks — was rejected for the same
reasons as ADR 0012: the side channel keeps the vendored library and the ADR 0001
VT-only boundary intact and reuses the established scanner pattern.

## Consequences

- A program copying via `OSC 52 ; c ; <base64>` (e.g. Codex over SSH) lands on
  the macOS pasteboard; a `?` read query is answered on the PTY only when the
  host enables read. Verified by `LabanSessionTests.testOSC52*` (scanner + reply
  via `feedOutput`/`drainResponse`), `OSC52ClipboardTests` (codec), and
  `HeadlessClipboardOSC52Tests` (event-stream parity).
- OSC 52 carries the first *heap-allocated, growable* scanner buffer; it is lazy
  (only allocated once a session actually receives OSC 52) and freed in
  `free_ghostty_resources`. All other host-scanner payloads remain inline.
- All base64 lives in Swift (`OSC52Clipboard` via Foundation); the C core never
  encodes or decodes base64, only buffers bytes and frames the reply.
- Lives in the shared C core, so all three session tiers inherit the scanner.
  The clipboard *touch*, however, is wired only for the in-process tier (the
  AppKit host and the headless runtime), as OSC 9 is.
- Read remains off until a future preference exposes `osc52ReadEnabled`; the
  provider is already wired so flipping it on needs no re-plumbing.

## Applies To New Code

A side-channel scanner that bridges to a host resource (clipboard, filesystem,
notifications) follows the ADR 0012 rules **plus**: keep encoding/serialisation
(here, base64) in a pure LabanCore type that is unit-tested independently of the
C bridge and the AppKit layer; size-cap any unbounded payload in both the C
buffer and the decoder; and make any read-back of host state that crosses a trust
boundary **opt-in and default-deny**, dropping the request silently when denied
rather than replying with empty or stale data.
