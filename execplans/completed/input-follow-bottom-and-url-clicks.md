# Follow Prompt On Input And Click Plain URLs

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

Users who scroll back to read history should return to the live prompt as soon as
they start typing, matching common terminal behavior in iTerm. Users should also
be able to command-click ordinary visible `http://` and `https://` text links,
not only OSC 8 hyperlinks emitted by terminal programs.

After this change, typing, native text insertion, paste, and forwarded terminal
key input snap the active viewport to the bottom before sending input. Link hit
testing first honors terminal-provided OSC 8 hyperlink metadata and then falls
back to parsing the visible terminal row for a plain HTTP(S) URL under the
clicked cell.

## Progress

- [x] Reviewed `docs/product/mvp.md` and existing scroll/link implementation.
- [x] Confirmed OSC 8 command-click support already exists but plain text URL hit
      testing is missing.
- [x] Add scroll-to-bottom-on-input helper and AppKit call sites.
- [x] Add plain HTTP(S) URL detection for terminal snapshots.
- [x] Add focused tests for both behaviors.
- [x] Run targeted tests and update this plan with results.

## Context and Orientation

`Sources/LabanApp/TerminalBitmapView.swift` is the AppKit terminal view. It owns
keyboard input, native text insertion, paste, mouse gestures, scroll animation,
and command-click hyperlink activation. Wheel scrolling changes libghostty's
authoritative viewport through `Session.scrollViewport(deltaRows:)`, where
negative rows move toward older scrollback and positive rows move toward the
active bottom.

`Sources/LabanApp/TerminalScrollInput.swift` holds pure helpers for scroll math
that are easy to unit test. It already converts a `ViewportState` into
`appliedRows`, where `0` means the active bottom and negative values mean the
user is reading older history.

`Sources/LabanCore/TerminalHyperlink.swift` currently reads only OSC 8 hyperlink
metadata from `LabanSnapshot`. Plain visible URLs have no `hyperlink_id`, so
`TerminalBitmapView.externalHyperlinkURI(at:)` cannot find them today.

## Plan of Work

1. In `Session.swift`, add a pure `ViewportState` helper that returns the
   positive `scrollViewport` delta needed to reach the active bottom from a
   viewport state, plus a `Session.scrollViewportToActiveBottom()` convenience.
   Add unit tests that prove bottom returns zero and older-history offsets
   return a positive delta.
2. In `TerminalBitmapView`, add a private helper that snaps a session to the
   active bottom, resets the smooth-scroll controller, clears fractional scroll
   residual, and invalidates render. Call it before terminal input leaves the
   view: encoded key events, plain bytes from text insertion, paste, and the
   special forwarded image-paste key.
3. Extend `TerminalHyperlink` with plain URL hit testing. The function should
   reconstruct the clicked row from snapshot cells, map each visible cell column
   to a string index range, find HTTP(S) URL tokens in that row, trim common
   trailing punctuation, and return the URL only when the clicked column lies
   inside the token.
4. Keep OSC 8 behavior first in `TerminalHyperlink.uri(atRow:col:in:)` so
   terminal-authored links win over fallback text parsing.
5. Run targeted Swift tests for `TerminalScrollInputTests`,
   `TerminalHyperlinkOpeningTests`, and `HyperlinkPlumbingTests`.

## Validation and Acceptance

Targeted validation:

```sh
cd /Users/dev/wrk/laban
rtk swift test --filter TerminalScrollInputTests
rtk swift test --filter TerminalHyperlinkOpeningTests
rtk swift test --filter HyperlinkPlumbingTests
rtk swift test --filter ViewportStateTests
rtk swift test --filter LabanDebugSmokeTests.testRuntimeTypingAfterScrollbackReturnsViewportToBottom
```

Acceptance:

- `TerminalScrollInputTests` proves the computed input-follow delta snaps from
  older scrollback to the active bottom.
- `HyperlinkPlumbingTests` proves OSC 8 links still work and plain visible
  HTTP(S) URLs can be hit-tested by cell.
- `TerminalHyperlinkOpeningTests` continues proving only HTTP(S) links open in
  an external browser and command-click activation stays single-click only.

Completed validation:

- `rtk swift test --filter ViewportStateTests` passed.
- `rtk swift test --filter HyperlinkPlumbingTests` passed.
- `rtk swift test --filter LabanDebugSmokeTests.testRuntimeTypingAfterScrollbackReturnsViewportToBottom` passed after the test setup was made deterministic with `feedOutput`.
- `rtk swift test --filter TerminalHyperlinkOpeningTests` passed.
- `rtk swift test --filter TerminalScrollInputTests` passed.
- `rtk swift test` passed: 455 tests, 2 skipped, 0 failures.
- `rtk ./scripts/check` passed, including boundary/docs/debug-contract checks,
  full tests, app build, smoke-runtime, and e2e.

## Outcomes & Retrospective

The two reported iTerm gaps were still valid in narrower forms: Laban already
handled OSC 8 command-click links but not plain visible HTTP(S) URLs, and input
paths did not explicitly snap a scrolled viewport back to the prompt before
writing. Both are now implemented. Headless debug input and paste use the same
active-bottom snap as the AppKit view so autonomous verification follows the
same session behavior.

## Idempotence and Recovery

All edits are local source/test changes. Re-running the test commands is safe.
If a test fails, inspect only files touched by this plan and avoid reverting
unrelated untracked files in the working tree.
