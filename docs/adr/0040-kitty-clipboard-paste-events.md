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
  answered from the snapshot with the requested MIME types, and the snapshot
  is then dropped. A list-only read gets the last paste's types without a
  grant, as Kitty does; it reveals no data. Every other read is denied
  (EPERM), so a remote program still cannot read the clipboard unasked. The
  live pasteboard is never read from the effect.
- **Large replies go through an ordered output queue.** libghostty writes a
  read reply in one call, and an image is megabytes of base64: past the
  64 KiB response buffer a labpty viewer forwards from, and past the 20 ms
  bounded PTY write. Responses over 16 KiB are queued (capped at 96 MiB), and
  while anything is queued, later responses and input queue behind it so the
  child never reads them inside the sequence. A PTY-backed session pumps the
  queue from its drain loop, also waking on writability. A labpty viewer's
  feed sends it to the daemon in 16 KiB chunks, keeping a chunk refused for
  backpressure, with one follow-up poll at a time, and the coordinator queues
  keystrokes behind it. If the daemon accepts nothing for 3 s (a
  canonical-mode reader never can), the queue is dropped so input is not
  trapped; keystrokes typed during that stall are lost. Output queued by the
  reattach catch-up read is discarded like its other responses; an overflow
  read is new bytes and keeps its queue.
- **OSC 52 stays with osc_host.c.** libghostty routes an OSC 52 `?` to the
  effect as an unnamed, passwordless, single `text/plain` read. The effect
  leaves a read of that shape unanswered and sets a flag, and the write_pty
  effect drops libghostty's empty OSC 52 fallback reply. A Kitty read of the
  same shape is answered EPERM by libghostty, which the drop lets through.
  ADR 0014's behavior is unchanged.

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
- The snapshot lives until the paste's data read (one read may request
  several types), the next paste event, or session teardown. A grant left
  unused by one paste and used after the next is served the newer snapshot;
  both came from the user's own pastes.
- Multi-client `laband` viewers do not parse output, never see mode 5522, and
  fall back to the text paste.
- A failed encode falls back to the ordinary paste. The headless runtime
  sends events only when it parses locally (not through laband).
- Verified by `KittyClipboardPasteEventTests` (event, granted read, denied
  unsolicited read, OSC 52 silent in every framing and on replay, large reply
  queued whole and in order), `OutputQueuePumpTests` (2 MB through a real
  PTY), `testLabptyChildReadsALargePastedImageThroughPasteEvents` (300 KB
  image end to end through labpty), `HeadlessKittyPasteEventTests`, and
  `PasteEventClipboardTests`, and
  `testLabptyStalledQueuedReplyIsDroppedSoInputFlowsAgain`.

## Applies To New Code

A libghostty effect that reaches host state from the reader thread must not
touch AppKit; serve it from data captured on the main thread at a user action.
A new libghostty effect that overlaps an osc_host.c protocol must leave the
existing owner's wire behavior unchanged.
