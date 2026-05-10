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
- [x] Extract external hyperlink opening policy out of `TerminalBitmapView`.
- [x] Move pure mouse input geometry/modifier helpers out of `TerminalBitmapView`.
- [x] Move AppKit frame/resize debug probes out of `TerminalBitmapView`.

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

- Decision: Move hyperlink URL allow-listing and command-click policy without
  moving terminal hit-testing.
  Rationale: URL safety and activation policy are pure AppKit-facing decisions,
  while locating a URI in the terminal grid still depends on view geometry and
  snapshots. Keeping that split avoids pulling rendering state into the helper.
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

`Sources/LabanApp/TerminalBitmapView.swift` also held external hyperlink URL
filtering, injected opener dispatch, hover cursor policy, and command-click
activation checks. `Tests/LabanAppTests/TerminalHyperlinkOpeningTests.swift`
already covered those decisions without needing a live terminal view.

`TerminalMouseInput` was already a pure helper covered by
`Tests/LabanAppTests/TerminalMouseInputTests.swift`, but it lived at the bottom
of the terminal rendering view file.

The AppKit frame and resize probes are diagnostic support objects used by the
view, not the view itself. Keeping them in the same file made the primary view
harder to scan before reaching the actual `TerminalBitmapView` declaration.

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

Create a `TerminalHyperlinkOpening` helper in `Sources/LabanApp/` for external
browser URL filtering, opener dispatch, hover cursor style, and command-click
activation. Keep `TerminalBitmapView.externalHyperlinkURI(at:)` in the view
because it depends on terminal geometry, active session snapshots, and sidebar
exclusion.

Move `TerminalMouseInput` into `Sources/LabanApp/TerminalMouseInput.swift`
without changing its API. The view keeps using the helper for geometry,
modifier-mask conversion, and tracked button checks.

Move `AppKitFrameProbe` and `AppKitResizeProbe` into
`Sources/LabanApp/AppKitTerminalProbes.swift`. Keep their construction,
recording calls, and artifact formats unchanged.

## Validation and Acceptance

Run these commands from `/Users/rrj/.codex/worktrees/4b01/laban`:

```sh
swift test --filter TerminalClipboardTests
swift test --filter TerminalHyperlinkOpeningTests
swift test --filter TerminalKeyInputTests
swift test --filter TerminalMouseInputTests
swift test --filter TerminalBitmapViewSyncOutputTests
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
`.bytes` behavior. External hyperlink URL filtering and activation policy are
covered through `TerminalHyperlinkOpeningTests` without calling static helpers
on the terminal rendering view. Mouse geometry and modifier helpers live in
their own source file and remain covered by `TerminalMouseInputTests`. AppKit
diagnostic probes live in their own source file and continue to compile through
the App target.

Validation completed on 2026-05-10:

```sh
swift test --filter TerminalClipboardTests
swift test --filter TerminalHyperlinkOpeningTests
swift test --filter TerminalKeyInputTests
swift test --filter TerminalMouseInputTests
swift test --filter TerminalBitmapViewSyncOutputTests
swift test --filter TerminalPasteTests
swift test --filter SessionKeyEncodingTests
swift test --filter LabanDebugSmokeTests
swift test
```

All targeted commands passed. The first full `swift test` run after hyperlink
extraction exited early with `xctest` signal code 5 without a reported test
assertion failure; rerunning `swift test` immediately afterward passed with 406
tests, 2 skipped, and 0 failures. The first build required the documented
worktree setup symlink:

```sh
ln -s /Users/rrj/wrk/laban/.external .external
```

The build emitted the existing `TerminalBitmapView.kickDisplayFromBackground()`
main-actor warning; this slice did not change that path.
