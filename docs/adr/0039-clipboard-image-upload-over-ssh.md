# 39. Clipboard Image Upload Over SSH

Date: 2026-10-03

## Status

Accepted. Extends the ⌘V image-only branch of `TerminalBitmapView.paste(_:)`
(the ⌃V pass-through for local TUIs) and reuses the ADR 0020 user-paste path
for the result. Does not touch the ADR 0014 OSC 52 bridge.

## Context

Coding agents such as Claude Code and Codex accept a pasted image in two ways:
reading the macOS pasteboard themselves (Laban forwards ⌃V for an image-only
clipboard so a local TUI can do that), or being given an image *file path*.
Over SSH the first is impossible — the remote process cannot see this Mac's
pasteboard, and OSC 52 read is text-only and off by default (ADR 0014). Users
were reduced to `scp`-ing screenshots by hand and typing the path.

Laban already knows when a pane's foreground process is `ssh`, and that process
already holds an authenticated route to the host the user is typing into. A
second, non-interactive `ssh` with the same options to the same destination can
write the image there and print where it went.

Two facts constrained the design:

- The tab metadata's `foregroundArguments` is lossy: capped at 16 elements and
  each element title-sanitized (whitespace collapsed, 256-scalar cap). Re-using
  it could silently change an option value such as a `ProxyCommand`.
- OpenSSH keeps the *first* value it sees for an option, and its `getopt` loop
  restarts after the destination, so options may follow the host and the first
  non-option after it starts the remote command.

## Decision

On ⌘V, when the pasteboard has **no text** and **an image**, and the focused
pane's foreground process is a parseable `ssh`, Laban uploads the image to that
destination and pastes the remote path. A mixed text+image pasteboard still
pastes its text (H-7), and an image-only paste in any other pane still forwards
⌃V. A pane whose foreground process is `ssh` is never a *local* Claude Code, so
the ⌃V forward cannot have helped it. The decision is
`ClipboardPasteAction.decide` (LabanCore).

**Argv.** Read fresh at paste time from the kernel (`KERN_PROCARGS2` via
`LibprocIntrospector`) for the tab's foreground pid, uncapped and unsanitized;
`proc_pidpath` must name an `ssh` binary (guards pid reuse), and that same
binary runs the upload, so `ssh` invoked by absolute path or from Homebrew is
respected. The session metadata cap stays at 16 because nothing here reads it.

**Parsing (`SSHCommandLine`, LabanCore).** Mirrors OpenSSH's option grammar:
bundled flags (`-At`), joined arguments (`-p22`, `-oKey=value`), options after
the destination, `--`. It keeps connection options (`-J -i -F -o -p -l -c -m
-b -B -E -e -I -S -P -C -q -4 -6 …`), drops the remote command, strips
session-shaping flags (`-t -T -N -f -n -M -A -X -Y -v`) and forwards (`-L -R -D
-w`), and **refuses** (no upload, today's behavior) on `-O -W -Q -G -V -s`, an
unknown option, a missing option argument, or no usable destination. It then
prepends, so they win under first-value-wins:
`-T -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes
-o ControlMaster=no -o PermitLocalCommand=no -o RemoteCommand=none`.
`ControlMaster=no` still reuses an existing master socket.

**Remote command (`SSHImageUploadScript`).** One `sh -c '…'` with a
single-quoted script, so it means the same under sh, bash, zsh, and fish login
shells: `umask 077`, `mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/laban/paste"`,
`cat >` a fresh `<uuid>.png`, `printf %s` the path. The reply is accepted only
if its last non-empty stdout line is a printable absolute path ending in
`/<that uuid>.png` (tolerating shell startup files that print in
non-interactive sessions).

**Upload.** PNG bytes (the pasteboard's `.png` representation, else TIFF
re-encoded), capped at 20 MB, are piped on stdin off the main thread with a
30 s timeout. The running ssh's `SSH_AUTH_SOCK` is passed through.

**Consent.** The first upload to a destination (keyed by destination plus
`-l`/`-p`) asks "Upload the clipboard image to <destination>?"; "Upload" is
remembered in `UserDefaults` (`sshImageUpload.approvedDestinations`), "Cancel"
is not.

**Result.** The path goes through the same `pasteUserText` path as ⌘V text, so
`TerminalPaste.sanitize` and bracketed paste apply (ADR 0020), and only into the
pane that asked — if focus moved during the upload nothing is pasted. A status
toast (the generalized OSC 52 copy pill) shows "Uploading image to …" and, on
failure, "Couldn't upload image: <reason>"; a failure pastes nothing. EventLog
records `paste.image.sshUpload.started/succeeded/failed/declined/ignored` with
byte count, duration, and failure kind — never the image, destination, or argv.

## Threat Model

- **User-initiated only.** Triggered by ⌘V with an image-only pasteboard; no
  terminal output or remote program can start an upload.
- **Same host.** The destination and connection options are the ones the user
  is already connected with; nothing is sent anywhere new.
- **No prompts, no side effects.** `BatchMode=yes` means no password,
  passphrase, or host-key prompt can appear (an unknown host key fails);
  forwards, agent/X11 forwarding, TTYs, `LocalCommand`, and a configured
  `RemoteCommand` are all disabled for the upload.
- **Per-destination consent** before the first upload.
- **Private files.** `0600` files in a `0700` directory under the user's own
  cache dir; names are unguessable UUIDs.

Known gaps: ssh running inside a *local* tmux/screen is invisible (the
foreground process is the multiplexer), so that pane keeps the ⌃V forward;
mosh and other non-OpenSSH transports are not handled; uploaded files are never
cleaned up on the remote; a `-p`-less alias that resolves to the same host as
another alias is asked about separately. `HeadlessDebugRuntime` has no image
clipboard (its debug clipboard is text-only), so it has no image paste to
mirror; the decision, parser, script, and reply validation are LabanCore and
unit-tested, and the remote script is executed under each local shell in tests.

## Consequences

- An image-only ⌘V in a pane running `ssh` pastes a remote path such as
  `/home/me/.cache/laban/paste/<uuid>.png` that a remote agent can read.
- The first ⌘V per destination shows a modal; failures cost a toast, not a
  paste.
- Remote disks accumulate pasted images under `~/.cache/laban/paste` until the
  user removes them.

## Applies To New Code

A feature that acts on a pane's foreground process must read its argv fresh
from the kernel, not from title metadata. Re-running a user's `ssh` must parse
with OpenSSH's grammar, refuse what it cannot reproduce, and put forced options
before the user's. Anything a remote host prints back must be validated against
what Laban asked for before it is pasted, and the paste must go through the
ADR 0020 user-paste path.
