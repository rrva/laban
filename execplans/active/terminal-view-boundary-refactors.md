# Terminal View Boundary Refactors

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress`, `Decision Log`, and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

The AppKit terminal view, headless debug runtime, renderer, model, and C
terminal core have grown into large ownership clusters. This plan breaks the
highest-risk clusters into behavior-preserving modules so the codebase reads as
deliberate subsystems rather than accumulated feature patches. The first slice
extracts clipboard and paste policy from `TerminalBitmapView`, because it is
small enough to verify directly and already has focused tests.

## Progress

- [x] Read every text file in `Sources/` and recorded binary resource metadata.
- [x] Identified the highest-impact refactoring targets and ranked them.
- [x] Chose clipboard/paste policy extraction as the first bounded slice.
- [x] Extract AppKit clipboard decisions out of `TerminalBitmapView`.
- [x] Update focused AppKit tests to exercise the extracted policy directly.
- [x] Run targeted Swift tests for the changed behavior.
- [x] Replace captured-write tuple returns in `Session` with named result types.
- [x] Run targeted Core, AppKit, and Debug tests for captured input writes.

## Decision Log

- Decision: Start with an extraction that changes ownership boundaries without
  changing terminal behavior.
  Rationale: Clipboard paste is security-sensitive, already tested, and
  currently contributes policy code to a large rendering/input view. Moving it
  first improves structure while keeping the blast radius low.
  Date/Author: 2026-05-10 / Codex

- Decision: Keep captured-write result values structurally identical at call
  sites while changing the public API from tuples to named types.
  Rationale: `.result` and `.bytes` remain ergonomic, but signatures now
  communicate durable API concepts that can be documented, extended, and tested
  without relying on anonymous tuple shapes.
  Date/Author: 2026-05-10 / Codex

## Context and Orientation

`Sources/LabanApp/TerminalBitmapView.swift` owns rendering cadence, resize
handling, tab synchronization, selection, mouse input, keyboard input,
clipboard commands, hyperlink opening, and capture recording. Clipboard policy
currently lives in the view as static helpers:

- pasteboard text preflight and size limits
- image-bearing pasteboard detection
- Claude Code tab recognition for image paste forwarding
- paste sanitization forwarding

`Sources/LabanCore/TerminalPaste.swift` owns terminal-safe paste sanitization
and byte limits. `Sources/LabanCore/Session.swift` owns the actual paste write
through libghostty. `Tests/LabanAppTests/TerminalKeyInputTests.swift` already
checks the AppKit pasteboard and Claude Code forwarding decisions.

`Sources/LabanCore/Session.swift` also exposes captured input writes for keys,
mouse events, and paste. Those APIs were tuple-shaped even though they are
cross-target contracts used by AppKit, debug automation, capture logging, and
tests.

## Plan of Work

Create a `TerminalClipboard` helper in `Sources/LabanApp/` for AppKit-facing
clipboard policy. Move the pasteboard read result type, text preflight,
image-paste detection, Claude Code recognition, and paste sanitization wrapper
into that helper. Leave `TerminalBitmapView.copy(_:)`, `paste(_:)`, and the
actual `Session` writes in the view for now, because those methods still depend
on AppKit responder actions, alert presentation, capture recording, and active
session lookup.

Update `TerminalBitmapView` to call `TerminalClipboard` instead of holding the
policy as static methods. Update focused AppKit tests to reference
`TerminalClipboard` directly so future policy edits do not need to instantiate
or name the rendering view.

Replace the tuple returns from `sendKeyCapturingBytes(_:)`,
`sendMouseCapturingBytes(_:)`, and `writePasteCapturingBytes(_:)` with named
`Session.Captured*Write` result types. Keep existing member names so behavioral
call sites remain unchanged except where a synthetic fallback value must be
constructed explicitly.

## Validation and Acceptance

Run these commands from `/Users/rrj/.codex/worktrees/4b01/laban`:

```sh
swift test --filter TerminalClipboardTests
swift test --filter TerminalKeyInputTests
swift test --filter TerminalPasteTests
swift test --filter SessionKeyEncodingTests
swift test --filter LabanDebugSmokeTests
swift test
```

Acceptance: the tests pass, oversized pasteboard strings are refused before
string decoding, image-bearing pasteboards are detected, Claude Code tabs are
recognized for image forwarding, and `TerminalBitmapView` no longer owns the
static clipboard policy implementation. Captured key, mouse, and paste writes
return named `Session.Captured*Write` values while preserving `.result` and
`.bytes` behavior.

Validation completed on 2026-05-10:

```sh
swift test --filter TerminalClipboardTests
swift test --filter TerminalKeyInputTests
swift test --filter TerminalPasteTests
swift test --filter SessionKeyEncodingTests
swift test --filter LabanDebugSmokeTests
swift test
```

All commands passed. The full `swift test` run executed 406 tests with 2
skipped and 0 failures. The first build required the documented worktree setup
symlink:

```sh
ln -s /Users/rrj/wrk/laban/.external .external
```

The build emitted the existing `TerminalBitmapView.kickDisplayFromBackground()`
main-actor warning; this slice did not change that path.
