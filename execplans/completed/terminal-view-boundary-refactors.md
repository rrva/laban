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
- [x] Extract render gate decisions out of `TerminalBitmapView`.
- [x] Extract text-input cursor geometry out of `TerminalBitmapView`.
- [x] Extract selection input geometry and word-boundary policy out of `TerminalBitmapView`.
- [x] Extract input-capture metadata formatting out of `TerminalBitmapView`.
- [x] Extract resize automation configuration out of `TerminalBitmapView`.
- [x] Extract display-kick coalescing out of `TerminalBitmapView`.

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

- Decision: Keep text-input geometry independent from the rendering view while
  leaving screen-coordinate conversion in `TerminalBitmapView`.
  Rationale: Cursor-cell geometry is pure terminal grid math and can be tested
  without naming the view. Converting that rect through AppKit window/screen
  APIs still belongs in the `NSTextInputClient` implementation.
  Date/Author: 2026-05-10 / Codex

- Decision: Move selection hit-testing, clamped drag points, viewport-offset
  translation, and word-boundary scans behind a selection input helper.
  Rationale: Mouse event handling still belongs in `TerminalBitmapView`, but
  the grid math and snapshot row scanning are independent policies that deserve
  focused tests and stable names.
  Date/Author: 2026-05-10 / Codex

- Decision: Move input-capture byte formatting, modifier labels, and app-command
  capture names into a small metadata helper.
  Rationale: The view should decide when to record input events, while stable
  capture vocabulary and byte serialization should be testable without the
  rendering view.
  Date/Author: 2026-05-10 / Codex

- Decision: Move resize automation environment parsing and defaults into a
  dedicated helper.
  Rationale: AppKit window mutation and probe recording belong in the view, but
  interpreting `LABAN_RESIZE_*` debug knobs is pure configuration policy and
  should be covered without a live window.
  Date/Author: 2026-05-10 / Codex

- Decision: Move off-main display-kick coalescing into a non-view helper.
  Rationale: Session dirty callbacks are `@Sendable` and can run off the main
  actor, while `TerminalBitmapView` is main-actor isolated through `NSView`.
  Keeping the locks in an explicitly sendable helper preserves coalescing and
  removes the Swift concurrency warning without pushing every dirty event onto
  the main queue.
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

Synchronized-output and output-settle gates are render-loop policy decisions.
They decide when to hold or release a frame, but they do not need direct access
to AppKit, renderer state, or the terminal view.

Text-input cursor geometry is a small pure policy used by
`TerminalBitmapView.firstRect(forCharacterRange:actualRange:)`. The live method
still needs the active session snapshot and AppKit coordinate conversion, but
the terminal-grid rect calculation does not depend on the view.

Selection input state combines AppKit points, terminal grid dimensions,
libghostty viewport offsets, and snapshot cell scanning. Those policies were
embedded in `TerminalBitmapView`, even though they can be checked without a
live view.

Input-capture metadata is emitted by `TerminalBitmapView.recordInput`, but the
byte hex strings, byte lengths, modifier names, and app-command names are pure
debug-contract formatting.

Resize automation is debug infrastructure for reproducing AppKit resize
glitches. `TerminalBitmapView` must still drive the live window and probes, but
the environment configuration is independent of rendering.

Display-kick coalescing bridges background PTY reader callbacks to main-actor
frame advancement. The coalescing state is thread-safe infrastructure and does
not need to live on the AppKit view.

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

Move synchronized-output and output-settle hold types plus decision functions
into `Sources/LabanApp/TerminalRenderGate.swift`. Keep `advanceFrame()` in the
view responsible for applying those decisions to the live session.

Move text-input cursor geometry into
`Sources/LabanApp/TerminalTextInputGeometry.swift`. Keep
`TerminalBitmapView.firstRect(forCharacterRange:actualRange:)` responsible for
reading the active cursor snapshot and converting the helper's local rect to
screen coordinates.

Move selection hit-testing, clamped drag-point construction, viewport-offset
translation, and word-boundary scanning into
`Sources/LabanApp/TerminalSelectionInput.swift`. Keep
`TerminalBitmapView` responsible for live mouse events, active session snapshot
lifetimes, and mutating the current selection state.

Move input-capture metadata formatting into
`Sources/LabanApp/TerminalInputCaptureMetadata.swift`. Keep
`TerminalBitmapView.recordInput` responsible for creating and sending
`InputEventEnvelope` values.

Move resize automation configuration into
`Sources/LabanApp/TerminalResizeAutomation.swift`. Keep
`TerminalBitmapView` responsible for scheduling the timer, resizing the live
window, recording probe frames, and honoring auto-quit.

Move display-kick coalescing into
`Sources/LabanApp/TerminalDisplayKickCoalescer.swift`. Keep
`TerminalBitmapView` responsible for deciding what frame work to run on the
main actor.

## Validation and Acceptance

Run these commands from `/Users/rrj/.codex/worktrees/4b01/laban`:

```sh
swift test --filter TerminalClipboardTests
swift test --filter TerminalHyperlinkOpeningTests
swift test --filter TerminalKeyInputTests
swift test --filter TerminalMouseInputTests
swift test --filter TerminalInputCaptureMetadataTests
swift test --filter TerminalDisplayKickCoalescerTests
swift test --filter TerminalResizeAutomationTests
swift test --filter TerminalSelectionInputTests
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
the App target. Render gate policy is covered through
`TerminalBitmapViewSyncOutputTests` without calling static helpers on the
terminal rendering view. Text-input cursor geometry is covered through
`TerminalKeyInputTests` without calling a static helper on the rendering view.
Selection grid hit-testing, clamped drag points, viewport-offset translation,
and word-boundary scans are covered through `TerminalSelectionInputTests`.
Input-capture byte formatting, modifier labels, and app-command names are
covered through `TerminalInputCaptureMetadataTests`. Resize automation
environment parsing, delay conversion, step parsing, and auto-quit flags are
covered through `TerminalResizeAutomationTests`. Display-kick coalescing and
main-actor handoff are covered through `TerminalDisplayKickCoalescerTests`.

Validation completed on 2026-05-10:

```sh
swift test --filter TerminalClipboardTests
swift test --filter TerminalHyperlinkOpeningTests
swift test --filter TerminalKeyInputTests
swift test --filter TerminalMouseInputTests
swift test --filter TerminalInputCaptureMetadataTests
swift test --filter TerminalDisplayKickCoalescerTests
swift test --filter TerminalResizeAutomationTests
swift test --filter TerminalSelectionInputTests
swift test --filter TerminalBitmapViewSyncOutputTests
swift test --filter TerminalPasteTests
swift test --filter SessionKeyEncodingTests
swift test --filter LabanDebugSmokeTests
swift test
```

All targeted commands passed. Full `swift test` intermittently exited early
with `xctest` signal code 5 without a reported test assertion failure; each
immediate rerun passed. The latest successful full run executed 422 tests with
2 skipped and 0 failures. The first build required the documented worktree
setup symlink:

```sh
ln -s /Users/rrj/wrk/laban/.external .external
```

The previous `TerminalBitmapView.kickDisplayFromBackground()` main-actor warning
was resolved by moving off-main display-kick coalescing out of the AppKit view.
