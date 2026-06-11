# 20. Pasteboard Paste Sanitize Survives Bracketed Mode

Date: 2026-06-11

## Status

Accepted.

## Context

The additional terminal-support spec (Test 8) requires that escape sequences
inside pasted text be delivered literally between the bracketed-paste fences.
Laban's C encoder honors that since `paste.c` stopped delegating bracketed
encoding to ghostty's stripping encoder: inside `CSI 200~`/`CSI 201~` the
payload is byte-exact except an embedded end fence, whose ESC becomes a space
(the one sequence that can break out of the bracket).

The AppKit pasteboard path, however, runs `TerminalPaste.sanitize`
(`TerminalBitmapView.swift`, the post-CVE-2026-26982 baseline) before the
encoder: every C0 control except HT/LF/CR, plus DEL and C1, is dropped — ESC
included — in bracketed and non-bracketed mode alike. The reason is the
echo-back attack, which bracketed paste does not stop: the receiving
application commonly echoes pasted bytes back to the terminal, and a malicious
clipboard payload's CSI/OSC sequences would then be interpreted as if the
terminal had received them from the app — recoloring the screen, setting the
title, or moving the cursor. Ghostty strips ESC in its paste encoder
"regardless of bracketed paste mode" for the same reason; mainstream terminals
deviate from the spec's MUST here deliberately.

When the Claude-Code multiline-paste exemption landed (`d8ed764`) its
reasoning leaned on this invariant ("sanitizePaste already stripped everything
except tab / LF / CR"), which is what surfaced the tension with Test 8.

## Decision

Keep the pasteboard sanitize unconditional. A ⌘V paste never delivers ESC to
the child, even when the app has bracketed paste enabled. Spec Test 8 is
satisfied at the C encoder seam — debug/headless paste endpoints and any
programmatic `writePaste` caller get literal delivery, and the encoder's
end-fence neutralization guards bracket integrity for those callers — and is
deliberately NOT satisfied end-to-end through the macOS pasteboard.

## Consequences

- The conformance deviation is on purpose and recorded; do not "fix" Test 8 by
  removing or bracket-gating `TerminalPaste.sanitize` without superseding this
  ADR. The decision trades a spec MUST for immunity to clipboard escape
  injection (CVE-2026-26982 class).
- Non-pasteboard paste surfaces (debug runtime, tests, future programmatic
  callers) deliver bytes literally inside the fence; the only mutation is
  end-fence neutralization in `paste.c`.
- The non-bracketed pasteboard path keeps the full legacy posture: Swift
  sanitize first, then ghostty's stripping encoder.

## Applies To New Code

Any new user-facing paste entry point (menu action, drop handler, services
integration) must run `TerminalPaste.sanitize` before encoding, regardless of
bracketed-paste state. Programmatic/debug paste APIs may pass raw bytes; the
C encoder's end-fence neutralization is the floor that must remain.
