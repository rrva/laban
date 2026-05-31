# Claude Code Image Clipboard Paste

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Claude Code can accept images in its terminal prompt by handling `Ctrl+V` and
reading the macOS clipboard itself. Laban's `Cmd+V` paste path currently reads
only text from `NSPasteboard`, so an image-only clipboard is ignored before
Claude Code can see the key gesture. After this change, pressing `Cmd+V` in a
Laban tab that is running Claude Code forwards a synthetic terminal `Ctrl+V`
key when the pasteboard contains image data. Normal text paste remains
unchanged, and non-Claude tabs still ignore non-text clipboard data.

## Progress

- [x] Confirmed the current AppKit paste path only reads `.string` from
  `NSPasteboard` and treats image-only clipboards as empty.
- [x] Confirmed Laban routes terminal control chords through the libghostty key
  encoder rather than the text paste path.
- [x] Added an AppKit pasteboard image detector and Claude Code tab detector in
  `Sources/LabanApp/TerminalBitmapView.swift`.
- [x] Forwarded image clipboard `Cmd+V` to Claude Code as terminal `Ctrl+V`.
- [x] Updated the MVP paste contract to document this narrow exception.
- [x] Added focused tests for the routing decision and key encoding.
- [x] Ran targeted Swift tests for the changed paths.
- [x] Ran the repository check gate.

## Decision Log

- Decision: Do not serialize clipboard images into terminal input or temporary
  files in this change.
  Rationale: Claude Code's documented terminal path on macOS is `Ctrl+V`,
  where Claude Code reads the local clipboard. Forwarding that key for
  image-bearing pasteboards preserves terminal boundaries and avoids inventing
  a Laban-specific file-transfer policy.
  Date/Author: 2026-05-08 / Codex

## Context and Orientation

`Sources/LabanApp/TerminalBitmapView.swift` owns AppKit clipboard commands.
Its `paste(_:)` method currently calls `readPasteboardString(_:)`, sanitizes
text with `TerminalPaste.sanitize(_:)`, then writes through
`Session.writePasteCapturingBytes(_:)`. `Sources/LabanApp/TerminalInputView.swift`
owns keyboard routing; control-modified keys become `KeyEvent`s and are encoded
by `Sources/LabanCore/Session.swift` through libghostty. `AppModel` stores each
tab's current title and foreground process metadata, which can identify a
Claude Code tab from `foregroundProcess == "claude"`, a foreground command
whose executable is `claude`, or an OSC title/display title containing
`Claude Code`.

## Plan of Work

Add a static pasteboard helper in `TerminalBitmapView` that detects image data
without reading arbitrary image bytes. Add a static tab helper that recognizes
Claude Code from process metadata or title metadata. In `paste(_:)`, once the
active tab and session are known, check for an image-bearing pasteboard and a
Claude Code-looking tab before the text paste path. If both are true, send a
terminal key event equivalent to `Ctrl+V` and record it as terminal input.
Leave the existing text paste path unchanged.

Update `docs/product/mvp.md` so the current boundary remains clear: ordinary
paste is still text-only, but Claude Code image clipboards are a narrow
compatibility exception that forwards the documented terminal key instead of
transporting image bytes.

## Validation and Acceptance

Run these commands from `/Users/dev/wrk/laban`:

```sh
rtk swift test --filter TerminalKeyInputTests
rtk swift test --filter LabanSessionKeyEncodingTests
rtk swift test --filter TerminalPasteTests
```

Acceptance: the tests pass, `Ctrl+V` encodes to the terminal SYN byte, AppKit
helpers identify image pasteboards and Claude Code tabs, oversized text paste
still refuses before decoding, and existing paste sanitization tests still pass.

Validation completed on 2026-05-08:

```sh
rtk swift test --filter TerminalKeyInputTests
rtk swift test --filter LabanSessionKeyEncodingTests
rtk swift test --filter TerminalPasteTests
rtk ./scripts/check-docs
rtk ./scripts/check
```

All commands passed. The full check emitted existing Swift/Xcode warnings about
main-actor isolation and missing module-cache `.pcm` paths during the app build,
but completed with `check passed`.

## Outcomes & Retrospective

`Cmd+V` with an image-bearing pasteboard now remains a no-op for ordinary
terminal tabs, but in a tab recognized as Claude Code it sends terminal
`Ctrl+V` (`0x16`) so Claude Code can read the local clipboard image itself.
Text paste still uses the existing sanitized bracketed-paste path.
