# Fix the verified user-facing bugs from the 2026-06-19 audit

This ExecPlan is a living document maintained in accordance with `../../PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add
optional sections only when they contain information that will help a fresh
contributor.

## Purpose / Big Picture

Laban is a native macOS terminal emulator (Swift/AppKit + Metal, VT parsing
delegated to vendored `libghostty-vt`). A bug audit
(`docs/quality/user-facing-bugs-audit-2026-06-19.md`) listed 28 findings. Each
was independently re-verified against the *current* source by a fan-out
verification workflow (one reader per finding plus an adversarial refutation
pass). The result: **22 findings are real and worth fixing, 6 were corrected**
(one fully refuted, one already fixed, four are unreachable "defensive-only"
items). This plan fixes the 22 real ones and records the corrections so nobody
re-investigates them.

After this change a user will be able to: copy the *right* text after scrolling
inside a TUI; resize the window vertically without a stale highlight; copy and
search CJK/emoji from scrollback without column drift; navigate the terminal
with VoiceOver and see a focus ring; export a cast on a restricted account
without a crash; learn when the daemon dies instead of silently losing tabs; and
not have a second app instance corrupt the workspace file. Every fix is
demonstrated by an automated test, a debug-state check, or a documented manual
observation, per the `AGENTS.md` autonomous-verifiability rule.

Three audited findings — **BUG-09 (Kitty inline images), BUG-10 (tmux/screen DCS
passthrough), BUG-11 (emoji width conformance)** — are already owned by
`execplans/active/kimi-code-terminal-capability-gaps.md` (its milestones M2, M3,
M4). This plan does **not** duplicate them; it cross-references that plan and
treats them as out of scope here.

## Verification provenance (do not re-investigate)

Verified 2026-06-19 by workflow `verify-bug-audit` (55 agents). Verdicts:

| ID | Audit status | Verified verdict | Action here |
|---|---|---|---|
| BUG-01 | Verified | confirmed | M1 |
| BUG-02 | Verified | confirmed | M4 |
| BUG-03 | Verified | confirmed | M3 |
| BUG-04 | Verified | confirmed (see runtime-lock caveat) | M5 |
| BUG-05 | Verified | confirmed | M5 |
| BUG-06 | Verified | confirmed (ADR-gated) | M6 |
| BUG-07 | Verified | confirmed | M1 |
| BUG-08 | Corrected | confirmed (corrected nuance holds) | M1 |
| BUG-09 | Verified | confirmed | **kimi-code plan (M2)** |
| BUG-10 | Verified | confirmed | **kimi-code plan (M3)** |
| BUG-11 | Verified | confirmed | **kimi-code plan (M4)** |
| BUG-12 | Verified | confirmed | M2 |
| BUG-13 | Verified | confirmed | M2 |
| BUG-14 | Verified | **partially-confirmed**: mid-response crash already fixed by commit `4232c1b`; connect-time/non-transient startup still fatal | M5 (rescoped) |
| BUG-15 | Verified | **refuted**: all cited `baseAddress!` preceded by `isEmpty` guards; non-empty buffers have non-nil base | **none** |
| BUG-16 | Verified | confirmed | M5 |
| BUG-17 | Verified | confirmed-present but **unreachable** (Metal pre-allocates `colorAttachments[0]`) | M3 (defensive-only) |
| BUG-18 | Verified (guarded) | confirmed-present but **unreachable** (`MAP_FAILED` guard) | M3 (defensive-only) |
| BUG-19 | Verified | confirmed | M3 |
| BUG-20 | Verified | confirmed | M3 |
| BUG-21 | Corrected | confirmed (distinct signatures unthrottled) | M7 |
| BUG-22 | Verified | confirmed | M4 |
| BUG-23 | Verified | confirmed | M4 |
| BUG-24 | Verified | confirmed | M2 |
| BUG-25 | Verified | confirmed | M2 |
| BUG-26 | Verified | confirmed-present but **unreachable** (fixed PUA constants) | M3 (defensive-only) |
| BUG-27 | Verified | confirmed | M5 |
| BUG-28 | Corrected | confirmed-present but **unreachable** (upstream bound + CBMC contract) | M3 (defensive-only) |

**Not fixed and why:** BUG-15 is not a bug — leave the code untouched (changing
it risks introducing the very crash the audit feared). BUG-17/18/26/28 cannot
crash in normal use; they are bundled into M3 as a single low-risk
"defensive-clarity" sweep only, not as crash fixes.

## Progress

- [x] (2026-06-19) Audit re-verified by fan-out workflow; 22 of 28 findings
      confirmed actionable, 6 corrected (1 refuted, 1 already fixed, 4
      defensive-only). Plan authored.
- [x] (2026-06-19) M1 — Selection correctness across scroll and resize
      (BUG-01, 07, 08). Added red/green selection coverage for forwarded
      wheel, alt-scroll, row-only resize, and row-count-changing font zoom;
      implemented row-aware selection invalidation and forwarded-wheel
      dismissal.
- [ ] M2 — Wide-character / emoji fidelity in find, copy, word-select, IME
      (BUG-12, 13, 24, 25).
- [x] (2026-06-19) M3 — Crash & robustness hardening (BUG-03, 19, 20)
      + defensive-clarity sweep (BUG-17, 18, 26, 28). Added bitmap invalid-
      dimension and selection zero-cell regression coverage; hardened cast/
      capture directory fallback, bitmap layout/context creation, selection
      geometry, mmap guards, menu key scalars, and labpty pending-input
      invariant documentation.
- [ ] M4 — Accessibility for the terminal surface (BUG-02, 22, 23).
- [ ] M5 — App lifecycle & data safety (BUG-04, 05, 14, 16, 27).
- [ ] M6 — Raw→canonical input-drop integrity (BUG-06; ADR + formal-spec gated).
- [x] (2026-06-19) M7 — GPU-failure notification rate limiting
      (BUG-21). Added defaults-backed global throttling and disable preference
      for GPU cell payload failure notifications.
- [ ] Review Gate passed.

Milestones are independently shippable; M1–M4 are highest user value and have no
inter-dependencies, so they may land in any order or in parallel. Each milestone
ends with `./scripts/build-app` green and `swift test` green.

## Context and Orientation

Read this as if you know nothing about Laban. Every path is repository-relative
from the repo root `~/wrk/laban`. Build with `./scripts/build-app` (assembles the
bundle; **never** `swift build`). Run tests with `swift test`. Do **not**
`open`/launch `Laban.app` from a shell — it grabs the single-instance lock; for
live checks install with `LABAN_INSTALL_PATH="$HOME/Laban-<task>.app"
./scripts/install-app` and let the user launch it.

### Terms

- **Local selection**: the highlight Laban draws itself over grid cells when the
  user drag-selects. Distinct from a selection the child app tracks.
- **Mouse-tracking app / forwarded wheel**: a fullscreen TUI (vim, tmux, Claude
  Code) that asks the terminal to send mouse events as escape sequences ("SGR
  mouse reports"). When such an app is active, Laban *forwards* the scroll wheel
  to it instead of scrolling its own scrollback.
- **Reflow**: re-wrapping grid text when the column count changes on resize. It
  invalidates grid-anchored selection coordinates.
- **Scrollback fallback path**: when a selection or find result reaches rows that
  have scrolled out of the live viewport, Laban reconstructs text from a
  `String`-based scrollback buffer that (unlike the live "snapshot" path) does
  **not** carry per-cell display-width metadata. This is the root cause shared by
  BUG-12/13.
- **Wide cell / spacer tail**: a CJK ideograph or RGI emoji occupies two terminal
  columns; libghostty marks the first cell `LABAN_CELL_WIDE_WIDE` and the second
  `LABAN_CELL_WIDE_SPACER_TAIL` (an empty placeholder). Width-correct code skips
  spacer tails and advances two columns per wide cell.
- **labpty / daemon**: `labpty` is the out-of-process PTY backend; `PTYLabClient`
  (in `LabanCore`) talks to it over a unix socket; `AppSessionCoordinator` (in
  `LabanApp`) owns reconnection.
- **Headless parity (hard rule)**: any new subsystem must be wired into both
  `Sources/LabanApp/MainWindowController.swift` `makeAndShow` and
  `Sources/LabanDebug/HeadlessDebugRuntime.swift`, with an HTTP debug endpoint for
  autonomous verification.

### Key files (verified during the audit re-verification)

| Area | File |
|---|---|
| Terminal view: scroll/wheel forward, selection clear, resize, zoom, IME, accessibility, automation-quit, GPU-failure notifications, cast/capture dirs | `Sources/LabanApp/TerminalBitmapView.swift` |
| Selection hit-testing & word bounds | `Sources/LabanApp/TerminalSelectionInput.swift` |
| Selection tests (encode some wrong behavior) | `Tests/LabanAppTests/TerminalBitmapViewSelectionTests.swift` |
| Scrollback selection text extraction | `Sources/LabanCore/TerminalSelection.swift` |
| Scrollback find column math | `Sources/LabanCore/TerminalFind.swift` |
| Preedit (IME) mask width | `Sources/LabanCore/FrameProducer.swift` |
| Session I/O (BUG-15, refuted) | `Sources/LabanCore/Session.swift` |
| PTY client reconnect/retry | `Sources/LabanCore/PTYLabClient.swift` |
| Session coordination / recovery | `Sources/LabanApp/AppSessionCoordinator.swift` |
| Startup + fatal alert | `Sources/LabanApp/AppDelegate.swift` |
| Bundle Info.plist generation | `scripts/build-app` |
| Menu key equivalents | `Sources/LabanApp/MenuCommands.swift` |
| Resize automation env var | `Sources/LabanApp/TerminalResizeAutomation.swift` |
| Metal render-pass attachments | `Sources/LabanRenderer/MetalRenderer.swift` |
| Software surface allocation | `Sources/LabanRenderer/BitmapSurface.swift` |
| labpty byte-ring mmap | `Sources/LabanCore/LabptyByteRingReader.swift`, `LabptyByteRingWriter.swift` |
| labpty raw→canonical flip | `Sources/Labpty/main.c`; ADR `docs/adr/0008-labpty-write-input-backpressure-contract.md`; specs `specs/labpty/`, proofs `proofs/labpty/` |

## Plan of Work

### M1 — Selection correctness across scroll and resize (BUG-01, 07, 08)

**Why it matters:** the user drag-selects, scrolls or resizes, presses ⌘C, and
gets the wrong text. This is visible on every scroll/resize.

**BUG-01 — wheel-forwarded selection stays pinned.** In
`Sources/LabanApp/TerminalBitmapView.swift`, `scrollWheel(with:)` forwards the
wheel to a mouse-tracking app (the `mouseTracking` branch around lines
4359–4399, which calls `forwardEncodedMouseToDaemon()`), and the alt-screen
alt-scroll branch around lines 4402–4443, but neither calls
`dismissLocalSelectionForForwardedInput()` (around lines 4780–4791). A comment
claims this matches iTerm2/kitty; `bughunt/SELECTION_SCROLL_BUG.md` (with
`selection_scroll_repro.py`) proves iTerm2 actually *clears* the selection on a
forwarded wheel. Fix: call `dismissLocalSelectionForForwardedInput()` in both the
`mouseTracking` wheel-forward branch and the alt-scroll branch, immediately after
forwarding. Correct the two misleading comments. Then rewrite the test
`testWheelScrollPreservesSelectionWhenMouseTrackingIsActive`
(`Tests/LabanAppTests/TerminalBitmapViewSelectionTests.swift:532–558`) to assert
the selection IS cleared — it currently pins the bug.

**BUG-07 / BUG-08 — resize/zoom clears selection on column change only.**
`setFrameSize(_:)` (~lines 3257–3261) and `applyFontSize(_:)` (~lines 3363–3366)
both clear selection only when `cols != lastAppliedCols`; a row-only change (tall
resize, or a font change that keeps column count) leaves stale anchor/focus
coordinates that may reference rows that no longer exist. BUG-08's audit nuance
is confirmed: zoom does *not* unconditionally wipe selection; it shares BUG-07's
row-change gap. Fix: in both functions, also clear (or, better, reproject)
selection when the row count changes. Minimum viable: clear on `rows !=
lastAppliedRows` (add a `lastAppliedRows` field mirroring `lastAppliedCols`).
Extend the existing column-only test at
`TerminalBitmapViewSelectionTests.swift:121–153` with a row-only-change case and
a font-zoom case.

**Acceptance:** new/updated tests in `TerminalBitmapViewSelectionTests.swift`
fail before the change and pass after; each asserts selection state is cleared
after (a) a forwarded wheel under mouse tracking, (b) a row-only frame resize,
(c) a font-size change that alters row count.

### M2 — Wide-character / emoji fidelity in find, copy, word-select, IME (BUG-12, 13, 24, 25)

**Why it matters:** CJK/emoji content drifts by a column in find highlights and
truncates on copy from scrollback; double-clicking an emoji word mis-selects; the
IME caret sits one cell left. Shared root cause: code that counts one column per
grapheme cluster instead of per display width.

- **BUG-13 — scrollback copy.** `Sources/LabanCore/TerminalSelection.swift`
  `plainLineText(from:startCol:endCol:)` (~lines 279–292) iterates `for character
  in row` with `col + 1` per `Character`. The viewport path `snapshotLineText`
  (~lines 236–255) correctly checks `cell.wide == LABAN_CELL_WIDE_SPACER_TAIL`.
  This path is reachable when a selection spans off-viewport rows with scrollback.
- **BUG-12 — scrollback find.** `Sources/LabanCore/TerminalFind.swift`
  `rowBuffer(fromUTF8Row:)` (~lines 194–216) advances `column` by `+1` per
  grapheme (documented as `NOTE (L-1)`).
- **BUG-24 — word selection.** `Sources/LabanApp/TerminalSelectionInput.swift`
  `wordBounds` (~lines 118–168): `cellScalar` returns `nil` for
  `LABAN_CELL_WIDE_SPACER_TAIL`, halting expansion; it examines only the first
  scalar of a cell; `isWord` accepts only `CharacterSet.alphanumerics` plus
  `|-_./:~@`, so CJK/emoji are not word constituents.
- **BUG-25 — IME preedit.** `Sources/LabanApp/TerminalBitmapView.swift`
  `markedTextCaretCells` (~lines 3487–3491) uses grapheme count; `FrameProducer`
  preedit mask width (`Sources/LabanCore/FrameProducer.swift:472`) is
  `CGFloat(text.count) * cw`.

**Approach:** introduce one shared, locale-independent display-width helper and
use it in all four sites. The audit and `TerminalFind.swift`'s `NOTE (L-1)`
caution that `wcwidth` is locale-dependent and unreliable; instead the scrollback
extractor must carry per-row column metadata, or reuse the same width model the
terminal core uses for the snapshot path. Concretely:

1. Decide the width source (Decision Log entry required): either (a) thread the
   per-cell width array the snapshot already has through the scrollback
   `String`+row-offset structure, or (b) add a pinned Unicode-width table in
   `LabanCore` shared by find/selection/preedit. Prefer (a) for find/copy (exact,
   matches the live grid) and (b) only if (a) is infeasible for scrollback.
2. Width-aware iteration: skip spacer tails, advance two columns per wide cell, in
   `plainLineText` and `rowBuffer(fromUTF8Row:)`.
3. Word selection: treat a wide cell + its spacer tail as one unit; include
   CJK/emoji as word constituents (Unicode word-boundary segmentation, e.g.
   `Unicode.WordBoundary`/`String.enumerateSubstrings(.byWords)`), and fix
   `cellScalar` to not bail on spacer tails.
4. IME: compute caret offset and mask width from cell widths (2 for wide, 1 for
   narrow), not grapheme count, in both `markedTextCaretCells` and
   `FrameProducer` preedit.

**Coordination with the kimi-code plan:** BUG-11 (the width-conformance suite,
`TerminalWidthConformanceTests`) lands in `kimi-code-terminal-capability-gaps.md`
M4. M2 here should *consume* the same reference width model so find/copy/IME
agree with the conformance fixture. If M4 has not landed, add a focused fixture
in `Tests/LabanCoreTests` covering ASCII, CJK wide, RGI emoji, ZWJ sequence,
combining mark for these four paths specifically.

**Acceptance:** new tests in `Tests/LabanCoreTests/TerminalFindTests.swift`,
`Tests/LabanCoreTests` (selection), and a preedit test assert correct columns for
a line with a leading wide CJK char and an RGI emoji; word-selection test
double-click-selects a full emoji/CJK word. Each fails before, passes after.

### M3 — Crash & robustness hardening (BUG-03, 19, 20) + defensive-clarity sweep (BUG-17, 18, 26, 28)

**Real crashes to fix:**

- **BUG-03 — export/capture crash.** `Sources/LabanApp/TerminalBitmapView.swift`
  `castDirectory()` (~5946–5948) and `captureDirectory()` (~6208–6210) force-
  unwrap `urls(for:.libraryDirectory,in:.userDomainMask).first!`. The surrounding
  `do/catch` does not catch a fatal force-unwrap. Mirror `AppDelegate`'s safe
  pattern (~line 207, `first?`): guard with `?? FileManager.default.temporaryDirectory`
  and surface a user-visible error if creation fails.
- **BUG-19 — BitmapSurface overflow + CG force-unwrap.**
  `Sources/LabanRenderer/BitmapSurface.swift` (~22–43) computes
  `byteCount = height*width*4` and `bytesPerRow = width*4` as unchecked `Int`
  multiplications, and (~71–78) force-unwraps `CGContext(...)!`/`CGColor(...)!`.
  Use `multipliedReportingOverflow(by:)`, reject zero/overflow dimensions
  gracefully (return a failable init or a 1×1 fallback), and `guard let` the CG
  objects with an error path.
- **BUG-20 — selection divide-by-zero.**
  `Sources/LabanApp/TerminalSelectionInput.swift` (~37–38, 63–64, 77–78) divides
  by `cellWidth`/`cellHeight` in `cols`, `terminalCell(at:)`, `clampedPoint(at:)`
  with no zero guard. Add `guard cellWidth > 0, cellHeight > 0 else { return
  nil/default }` (or clamp denominators to ≥1).

**Defensive-clarity sweep (verified unreachable — clarity only, NOT crash fixes;
keep behavior identical):**

- **BUG-17** `Sources/LabanRenderer/MetalRenderer.swift:701,715,729,1166,1434,
  1586,1781` `colorAttachments[0]!` — Metal pre-allocates index 0. Replace with
  `guard let` returning a frame-skip, or leave with a one-line comment noting the
  invariant. Low priority.
- **BUG-18** `Sources/LabanCore/LabptyByteRingReader.swift:47` `map = mapped!`
  after a `MAP_FAILED` guard (and `LabptyByteRingWriter.swift:39`) — drop the
  redundant `!`.
- **BUG-26** `Sources/LabanApp/MenuCommands.swift:204,212` — replace
  `UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!` with `.map(String.init) ?? ""`
  or a literal.
- **BUG-28** `Sources/Labpty/main.c:819–820` — add `assert(tail <=
  LABPTY_WRITE_INPUT_MAX);` before the `memcpy` to document the upstream invariant
  (zero runtime cost; do not change control flow).

**BUG-15 is intentionally untouched** (refuted; the `baseAddress!` sites are all
`isEmpty`-guarded). Do not "harden" it.

**Acceptance:** a test constructs a `BitmapSurface` with zero and with overflow-
inducing dimensions and asserts a graceful failure (no crash). A test calls the
selection hit-test helpers with `cellWidth == 0` and asserts a nil/default rather
than a trap. For BUG-03, a test (or a documented manual check with an injected
empty-`urls` provider) exercises the fallback. The defensive sweep is verified by
`swift test` staying green (behavior unchanged) and a grep confirming the
redundant `!`s are gone.

### M4 — Accessibility for the terminal surface (BUG-02, 22, 23)

**Why it matters:** VoiceOver users cannot read the terminal at all; Full
Keyboard Access users cannot see focus; low-vision users get no contrast/transparency
adaptation. BUG-02 is the critical one.

- **BUG-02 — NSAccessibility.** `Sources/LabanApp/TerminalBitmapView.swift`
  (class decl ~lines 14–15) implements `NSTextInputClient` etc. but no
  `NSAccessibility`. Use the existing patterns from
  `Sources/LabanApp/TerminalFindChipView.swift:34–49` and
  `TerminalCaptureIndicator.swift:45–54`. Minimum viable: override
  `isAccessibilityElement` → true, `accessibilityRole` → `.textArea`,
  `accessibilityLabel` → "Terminal", `accessibilityValue` → the visible grid text
  (reuse the snapshot text extraction), and post a value-changed notification on
  output. Better (follow-up, not required for this milestone): per-line children,
  cursor/selection exposure, VoiceOver navigation.
- **BUG-22 — focus ring.** Same file, `acceptsFirstResponder` ~line 3398, no
  `drawFocusRingMask`/`focusRingType`. Implement `drawFocusRingMask()` +
  `focusRingMaskBounds` and/or set `focusRingType` so AppKit draws a standard
  ring when the view is first responder.
- **BUG-23 — display settings.** Same file caches only `reduceMotion` (~line 182)
  and the observer (~527–530) updates only `reduceMotion`. Observe
  `accessibilityDisplayShouldIncreaseContrast`,
  `accessibilityDisplayShouldDifferentiateWithoutColor`, and
  `accessibilityDisplayShouldReduceTransparency`, and adjust rendering: stronger
  selection/cursor outlines for Increase Contrast, non-color-only cues for
  Differentiate Without Color, opaque backgrounds for Reduce Transparency.

**Parity:** expose accessibility state queries through `HeadlessDebugRuntime`
(new `GET /debug/accessibility` returning role/label/value + the three display
flags) so the fix is autonomously verifiable; wire the same into
`MainWindowController` (hard rule).

**Acceptance:** a `LabanAppTests` test asserts `isAccessibilityElement`,
`accessibilityRole == .textArea`, a non-empty `accessibilityLabel`, and that
`accessibilityValue` contains text the terminal printed. A test toggles the
simulated display options and asserts the cached flags update (mirroring the
existing `TerminalBitmapViewWakeTests` reduce-motion test). `GET
/debug/accessibility` returns the expected JSON. Focus ring verified by a debug-
state assertion that `focusRingType != .none` (or a manual screenshot).

### M5 — App lifecycle & data safety (BUG-04, 05, 14, 16, 27)

- **BUG-04 — multiple instances.** `scripts/build-app` (~138–189) generates the
  bundle `Info.plist` without `LSMultipleInstancesProhibited`. Add
  `LSMultipleInstancesProhibited = true`. **Caveat (from re-verification):** the
  app already grabs a runtime single-instance lock (a windowless shell launch is
  known to grab it; see project memory / `MEMORY.md` "No GUI launch"). First
  confirm what that runtime lock does on a second launch (where it lives — search
  for the lock acquisition) and whether the plist key is complementary or
  redundant; document the finding in the Decision Log. If a second instance can
  still reach the workspace file before the lock resolves, the plist key closes
  that window at the Launch Services layer.
- **BUG-05 — daemon-crash recovery.** `Sources/LabanCore/PTYLabClient.swift`
  (~484–492) respawns a fresh daemon with no session catalog;
  `Sources/LabanApp/AppSessionCoordinator.swift` reconnects silently;
  `MainWindowController.promptToAdoptUnclaimedLabptySessions` only handles launch-
  time orphans. Surface a non-modal banner when a crash of an already-attached
  daemon is detected, listing affected tabs and offering to restart shells. The
  tab-state journal already supports banner notes (see `AGENTS.md` Runtime
  Artifacts → tab-journal); reuse that path so the banner is autonomously
  observable via `GET /debug/tab-journal`.
- **BUG-14 — fatal startup (rescoped).** The mid-response force-close case is
  already fixed (commit `4232c1b`: `hello()` wrapped in
  `withReconnectRetryLocked`, 6 attempts ~620 ms). Remaining real gap: the initial
  socket connect in the `PTYLabClient` constructor (~line 59) has no retry, and
  any labpty init error still routes to `AppDelegate.showStartupFailure`
  (`Sources/LabanApp/AppDelegate.swift:92–99`, 214–220) → modal alert →
  `NSApp.terminate(nil)`. Apply the reconnect-retry policy to the initial connect,
  and on persistent failure show a retry dialog (or degrade to the in-process
  backend) instead of terminating.
- **BUG-16 — undo for close tab.** No `UndoManager`/`registerUndo` anywhere. Wire
  `NSResponder.undoManager` for the window/tab controller and register undo for
  close-tab (re-open with the same shell + working directory) as the highest-
  impact first action. Paste/drag-drop undo are out of scope for this milestone.
- **BUG-27 — automation auto-quit notice.**
  `Sources/LabanApp/TerminalBitmapView.swift` (~606–614 `LABAN_AUTO_QUIT_AFTER_SECONDS`,
  ~638–644 `config.autoQuit`) and `TerminalResizeAutomation.swift:27`
  (`LABAN_RESIZE_AUTO_QUIT`) call `NSApp.terminate(nil)` unconditionally. Show an
  on-screen notice (status indicator or banner) while auto-quit is armed so a
  leaked env var does not look like a spontaneous crash.

**Acceptance:** BUG-04 — assert the generated `.build/laban/Laban.app/Contents/Info.plist`
contains `LSMultipleInstancesProhibited=true` (a build/script test or a grep in
the Review Gate). BUG-05/14 — a `PTYLabClient`/coordinator test simulates a dead
socket on an attached daemon and asserts a recovery banner is journaled (not
silent), and a startup test simulates a transiently unreachable socket and
asserts retry-then-recover rather than terminate. BUG-16 — a test closes a tab,
invokes undo, and asserts a tab with the same shell/cwd reappears. BUG-27 — a
test asserts the armed-auto-quit notice is present in debug state before
termination fires.

### M6 — Raw→canonical input-drop integrity (BUG-06; ADR + formal-spec gated)

**Why it matters:** exiting a raw-mode TUI and immediately pasting a long line can
silently drop bytes. Real and present: `Sources/Labpty/main.c` (~843–856) zeroes
`canonical_pending_estimate` on the raw-mode reset (line ~855), and ADR
`docs/adr/0008-labpty-write-input-backpressure-contract.md` (~89–99) documents
this as **KNOWN LIMITATION (M3)**, deliberately unfixed because an accurate
`FIONREAD`-per-write fix is costly on the hot input path.

**This milestone is gated.** `main.c`'s write-input backpressure is a formally
specified state machine (`specs/labpty/`, CBMC proofs in `proofs/labpty/`; see
`docs/process/formal-specs.md`). Changing it requires: (1) an ADR update or new
ADR superseding the limitation in 0008, (2) updating the TLA+ spec and the CBMC /
trace-conformance harness, (3) the mutation-adequacy gates staying green.
Proposed approach, lowest-risk first:

1. **Surface, don't drop (minimum).** When the post-flip canonical preflight would
   over-admit, stall or return a bounded backpressure signal instead of letting
   the line discipline truncate. This converts a silent data-loss bug into a
   visible flow-control event without the hot-path cost of `FIONREAD`.
2. **Carry-over estimate (better).** On the raw→canonical flip, carry a
   conservative `canonical_pending_estimate` derived from bytes written-but-
   unread in raw mode, instead of zeroing.
3. **Bounded drain-after-flip (most accurate).** Re-sync the estimate against the
   actual slave queue once, immediately after the flip.

Pick one in a Decision Log entry. Add a regression test in
`Tests/LabptyTests/LabptyAdversarialTests.swift` reproducing the raw→canonical
carry-over overflow (the existing suite pins only a simpler truncation case).

**Acceptance:** the new adversarial test feeds bytes in raw mode that the child
never reads, flips to canonical, writes a long line, and asserts no bytes are
silently dropped (or a visible backpressure/stall occurs). CBMC proofs and
mutation gates (`check-cbmc-mutants`, `check-trace-mutants`, `coverage-labpty`)
stay green. ADR 0008 updated.

### M7 — GPU-failure notification rate limiting (BUG-21)

`Sources/LabanApp/TerminalBitmapView.swift`: the notification function (~2532–2555)
uses a unique-UUID identifier (`identifier: "gpu-cell-payload-\(UUID().uuidString)"`,
~line 2547); the caller `autoDumpGPUCellPayloadFailure` (~2442–2479) dedups only
*identical* signatures within 60 s. Distinct signatures post unthrottled. Fix:
use a stable signature-based identifier so the system coalesces, add a global rate
limit (e.g. one notification per N minutes total), and add a user preference to
disable GPU-failure notifications. Consider batching distinct failures into one
summary.

**Acceptance:** a test posts several distinct-signature failures in quick
succession and asserts at most one notification within the global window; a
preference toggle suppresses them entirely.

## Decision Log

- Decision: Exclude BUG-09/10/11 from this plan.
  Rationale: they are already owned by
  `execplans/active/kimi-code-terminal-capability-gaps.md` (M2/M3/M4);
  duplicating would fork ownership. M2 here consumes M4's width model.
  Date/Author: 2026-06-19, plan author.
- Decision: Do not modify BUG-15's `Session.swift` force-unwraps.
  Rationale: re-verification refuted the finding — every `baseAddress!` is
  `isEmpty`-guarded and non-empty buffers have a non-nil base; a speculative
  rewrite risks introducing the crash the audit feared.
  Date/Author: 2026-06-19, plan author.
- Decision: Treat BUG-17/18/26/28 as defensive-clarity only, bundled in M3.
  Rationale: each is verified unreachable (Metal pre-allocates index 0;
  `MAP_FAILED` guard; fixed PUA scalar constants; upstream length bound + CBMC
  contract). Behavior must stay identical.
  Date/Author: 2026-06-19, plan author.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is considered complete. The executing agent must not mark the plan done until
this gate passes. See `../../PLANS.md` "Review gate and review-fix loop".

- [ ] `./scripts/build-app` exits 0 on a clean checkout at the review commit.
- [ ] `swift test` exits 0; record the passed count.
- [ ] M1: `Tests/LabanAppTests/TerminalBitmapViewSelectionTests.swift` contains a
      test asserting selection is CLEARED after a forwarded wheel under mouse
      tracking, and after a row-only resize. Mutate the fix (revert the
      `dismissLocalSelectionForForwardedInput()` call) → that test FAILS → revert
      the mutation → PASSES.
- [ ] M2: a test asserts correct find/copy column for a line beginning with a wide
      CJK char in the scrollback fallback path; mutating the width helper to
      `+1`-per-grapheme makes it FAIL.
- [ ] M3: a test constructs `BitmapSurface` with zero dimensions and with
      overflow-inducing dimensions and asserts no crash; `grep -n
      'colorAttachments\[0\]!' Sources/LabanRenderer/MetalRenderer.swift` and
      `grep -n 'mapped!' Sources/LabanCore/LabptyByteRingReader.swift` reflect the
      decided defensive treatment.
- [ ] M4: a test asserts `TerminalBitmapView.isAccessibilityElement == true`,
      `accessibilityRole == .textArea`, non-empty label, and value containing
      printed text; `GET /debug/accessibility` route exists and
      `grep -n 'accessibilityRole\|drawFocusRingMask\|IncreaseContrast'
      Sources/LabanApp/TerminalBitmapView.swift` shows all three areas wired;
      parity grep in `HeadlessDebugRuntime.swift` and `MainWindowController.swift`.
- [ ] M5: the generated `.build/laban/Laban.app/Contents/Info.plist` contains
      `LSMultipleInstancesProhibited`; a daemon-crash test journals a recovery
      banner (visible via tab-journal); a close-tab undo test reopens the tab.
- [ ] M6 (if attempted): `Tests/LabptyTests/LabptyAdversarialTests.swift` has a
      raw→canonical carry-over test that FAILS before the fix and PASSES after;
      CBMC/mutation/coverage labpty gates green; ADR 0008 updated. (If M6 is
      deferred, this item is marked N/A with a note in Progress.)
- [ ] M7: a test asserts distinct-signature GPU failures coalesce to ≤1
      notification per global window.
- [ ] No regression to MVP behavior in `docs/product/mvp.md`.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- Every milestone is additive and independently revertible. M1–M4 touch disjoint
  files from M5–M7 except for `TerminalBitmapView.swift` (shared by M1, M3-cast,
  M4, M5-autoquit, M7) — edit distinct functions and commit per milestone to keep
  changesets focused (one behavioral reason per commit, per `AGENTS.md`).
- Re-running `./scripts/build-app` and `swift test` is safe and repeatable.
- M6 is the only risky milestone (formal specs + CBMC); if it destabilizes the
  proofs, stop at approach (1) "surface, don't drop" or defer M6 entirely — the
  other six milestones do not depend on it.
- A regenerated `.rpg/graph.json` alone marks the build `+dirty`; if a built
  bundle "doesn't work", verify `Info.plist:LABANBuildCommit` matches HEAD before
  debugging source.

## Artifacts and Notes

- Source audit: `docs/quality/user-facing-bugs-audit-2026-06-19.md`.
- Re-verification: workflow `verify-bug-audit` (2026-06-19, 55 agents) — verdicts
  table above. 22/28 confirmed actionable; BUG-15 refuted; BUG-14 partially fixed
  (commit `4232c1b`); BUG-17/18/26/28 unreachable (defensive-only).
- Cross-referenced plan: `execplans/active/kimi-code-terminal-capability-gaps.md`
  (owns BUG-09/10/11).
- M1 executor validation (2026-06-19): `swift test --filter
  TerminalBitmapViewSelectionTests` failed before the fix with the new M1
  assertions, then passed after the fix (23 tests, 0 failures);
- M3 executor validation (2026-06-19): red test confirmed
  `LabanRendererSmokeTests/testBitmapSurfaceInvalidDimensionsFallBackToOnePixel`
  trapped on the old precondition; after the fix,
  `swift test --filter LabanRendererSmokeTests`, `swift test --filter
  TerminalSelectionInputTests`, `git diff --check`, and `./scripts/build-app`
  passed. Static checks: `mapped!` is absent from the labpty byte-ring reader/
  writer; Metal `colorAttachments[0]!` sites now carry the documented descriptor
  invariant; `TerminalBitmapView` Library-directory lookups use `.first` with a
  temporary-directory fallback and logged fallback path. No injectable
  `FileManager.urls` provider exists for a BUG-03 unit test, so coverage is the
  source-level static check plus build validation.
  `./scripts/build-app` exited 0. Review Gate remains unchecked for the required
  separate verifier.
- M7 executor validation (2026-06-19): `swift test --filter
  GPUCellPayloadFailureNotificationPolicyTests`, `git diff --check`, and
  `./scripts/build-app` passed. The notification request identifier is now
  stable (`gpu-cell-payload-failure`), the global throttle timestamp is shared
  through `UserDefaults`, and `LabanDisableGPUFailureNotifications` suppresses
  GPU-failure notification requests before the beep/banner path. Review Gate
  remains unchecked for the required separate verifier.
