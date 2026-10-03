# 40. Kitty Clipboard Paste Events (OSC 5522)

Date: 2026-10-03

## Status

Accepted.

Extends ADR 0014 (OSC 52 bridge) with a second, MIME-typed clipboard
protocol. Keeps ADR 0014's OSC 52 behavior and ADR 0020's paste sanitize.

## Context

Over SSH a remote program cannot read the Mac clipboard, and OSC 52 carries
only text, so a coding agent on a remote host cannot receive a pasted
screenshot. Kitty's clipboard protocol (OSC 5522,
<https://sw.kovidgoyal.net/kitty/clipboard/>) carries any MIME type in-band,
so it works through SSH and jump hosts. Its *paste events* (DEC private mode
5522) fit a user paste exactly: when the program has enabled them, the
terminal answers ⌘V with an event listing the clipboard's MIME types and a
one-time password, and the program reads the representations it wants with
that password, without a permission prompt because the user just pasted.
Kitty ships this; Ghostty has it in development, and wrappers such as
claude-clipboard-ssh use it to feed images to Claude Code on a remote host.

The libghostty-vt pin (ADR 0034) already implements the protocol: parsing,
MIME lists, passwords and grants, paste events through
`ghostty_terminal_paste`, and a synchronous `clipboard_read` effect. Laban had
not installed that effect.

Two constraints:

- **The read is synchronous** and runs on the PTY reader / labpty feed thread
  with the session lock held. `NSPasteboard` belongs on the main thread
  (ADR 0014), and the main thread takes the session lock to render, so the
  effect cannot hop to main.
- **Installing the effect also routes OSC 52 `?` to it**, and libghostty
  answers an OSC 52 read the effect does not serve with an empty clipboard.
  ADR 0014 has osc_host.c own OSC 52 reads and drop them silently while read
  is disabled.

## Decision

Install libghostty's `clipboard_read` effect (`clipboard_events.c`) and serve
**only** reads that follow a user paste event.

- **⌘V while mode 5522 is on.** The AppKit paste (and the headless `paste`
  action) snapshots the pasteboard on the main thread as MIME items
  (`image/png`, converting the TIFF screenshots macOS puts there, and
  `text/plain`, sanitized per ADR 0020), and calls
  `laban_session_encode_paste_event`. That copies the items into the session
  (capped at 64 MiB, 8 items), runs `ghostty_terminal_paste`, and returns the
  event bytes instead of writing them, so the caller sends them through the
  same route as any paste (the PTY in process, the daemon for labpty). This
  replaces the text paste and the image ⌃V forwarding for that program.
- **Reads.** A read with `granted` set (it carried the event's password) is
  answered from the snapshot with the requested MIME types. A list-only read
  gets the snapshot's types. Every other read is denied (EPERM), so a remote
  program still cannot read the clipboard unasked. The live pasteboard is
  never read from the effect.
- **OSC 52 stays with osc_host.c.** The effect recognizes an OSC 52 read by
  the osc_host scanner state (it fires while osc_host flushes that OSC into
  libghostty), does not reply, and the write_pty effect drops libghostty's
  empty fallback reply. ADR 0014's behavior is unchanged.

Patching libghostty to skip OSC 52 reads, or moving OSC 52 reads into
libghostty, was rejected: the first adds a vendored patch (ADR 0011's cost),
the second changes ADR 0014's silent-deny to an empty reply.

## Consequences

- A program that enables mode 5522 (kitten clipboard, claude-clipboard-ssh)
  can receive pasted images and text over SSH. Agents that do not speak the
  protocol are unaffected; ADR 0039 covers them.
- Paste-event text is sanitized like every other paste (ADR 0020). Image data
  is delivered as-is: it is what the program asked for and is never rendered
  as terminal input.
- The snapshot lives in the session until the next paste event or session
  teardown, so a program can read several types after one paste.
- Multi-client `laband` viewers do not parse output, never see mode 5522, and
  fall back to the text paste.
- Verified by `KittyClipboardPasteEventTests` (event, granted read, denied
  unsolicited read, OSC 52 still silent), `HeadlessKittyPasteEventTests`
  (debug-runtime parity), and `PasteEventClipboardTests` (pasteboard snapshot).

## Applies To New Code

A libghostty effect that reaches host state from the reader thread must not
touch AppKit; serve it from data captured on the main thread at a user action.
A new libghostty effect that overlaps an osc_host.c protocol must leave the
existing owner's wire behavior unchanged.
