# User-Facing Bug Audit — 2026-06-19

**Scope:** Rendering, UX/usability, accessibility, terminal-core, and app-integration bugs in the Laban macOS terminal application.
**Verification:** All findings below were independently re-verified by multiple agents reading the actual source, tests, and documentation. Status reflects the verified state.
**Intended audience:** Claude Code / coding agents picking up fixes.

---

## How to use this document

Each entry has:

- **ID** — short reference tag.
- **Severity** — Critical / High / Medium.
- **Status** — Verified / Corrected (with note).
- **Subsystem** — where the fix primarily lives.
- **User impact** — what the user does and what goes wrong.
- **Root cause** — concise technical explanation.
- **Evidence** — exact file paths and line numbers plus a short code excerpt.
- **Fix direction** — suggested approach; adapt as needed.
- **Test gap** — what automated coverage is missing.
- **Related docs / plans** — cross-references.

> **Note:** A few original claims were refined during re-verification. Those are marked **Corrected** with the nuance spelled out.

---

## Critical

### BUG-01 — Selection highlight stays pinned while a mouse-tracking fullscreen app scrolls

- **Severity:** Critical
- **Status:** Verified
- **Subsystem:** LabanApp / input & selection
- **User impact:** In Claude Code, vim, tmux copy-mode, or any mouse-tracking TUI, the user drag-selects text, then scrolls the wheel without clicking. The wheel events are forwarded to the app as SGR mouse reports, but the local selection rectangle stays glued to the same viewport cells while the app repaints scrolled content underneath. The highlight ends up on different text, so ⌘C copies the wrong content.
- **Root cause:** `scrollWheel(with:)` explicitly preserves committed local selections across forwarded wheel events, with a comment claiming this matches iTerm2/kitty. `dismissLocalSelectionForForwardedInput()` is only called for forwarded press/drag, not wheel. The existing tests assert the buggy behavior.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:4359–4371` — comment: *“Keep any committed local selection across the forwarded wheel, matching iTerm2/kitty: a scroll notch shouldn't discard a selection…”*
  - `Sources/LabanApp/TerminalBitmapView.swift:4783–4791` — `dismissLocalSelectionForForwardedInput()` comment: *“Forwarded *wheel* scrolls deliberately do not call this.”*
  - `Tests/LabanAppTests/TerminalBitmapViewSelectionTests.swift:532–558` — `testWheelScrollPreservesSelectionWhenMouseTrackingIsActive` asserts the buggy behavior.
  - `bughunt/SELECTION_SCROLL_BUG.md` — capture evidence shows `anchorRow:5 / focusRow:5` while child repaints row 5.
- **Fix direction:** Clear local selection on any forwarded wheel scroll that moves the underlying grid content. Update `TerminalBitmapViewSelectionTests.swift` to assert the correct iTerm2 behavior. Consider preserving selection only for scroll events that do not change grid content (e.g., alt-scroll in cursor-key mode that only moves the cursor).
- **Test gap:** No test covers wheel-forwarding + selection invalidation. Existing tests encode the wrong behavior.
- **Related docs:** `bughunt/SELECTION_SCROLL_BUG.md`

---

### BUG-02 — Terminal surface is invisible to VoiceOver / assistive technology

- **Severity:** Critical
- **Status:** Verified
- **Subsystem:** LabanApp / accessibility
- **User impact:** A user enables VoiceOver and focuses the terminal window. The main terminal surface exposes no role, label, value, text content, cursor position, selection state, or scrollback information. Screen-reader users cannot read output, navigate tabs, or discover the find UI.
- **Root cause:** `TerminalBitmapView` is a custom `NSView` that implements `NSTextInputClient` for IME but never overrides any `NSAccessibility` methods (`isAccessibilityElement`, `accessibilityRole`, `accessibilityLabel`, `accessibilityValue`, `accessibilityChildren`, `accessibilityString`, focus/selection announcements).
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:14–15` — class declaration lists `NSTextInputClient`, `NSMenuItemValidation`, `QLPreviewPanelDataSource`, `QLPreviewPanelDelegate`; no `NSAccessibility` protocol conformance or overrides.
  - Grep for `accessibilityRole`, `accessibilityLabel`, `accessibilityValue`, `isAccessibilityElement`, `accessibilityChildren` in the file returns only the Reduce Motion references at `:182` and `:527–530`.
  - `Sources/LabanApp/TerminalFindChipView.swift:34–49` and `Sources/LabanApp/TerminalCaptureIndicator.swift:45–54` are the only accessibility labels in the app.
- **Fix direction:** Implement `NSAccessibility` for `TerminalBitmapView`. Minimum viable: expose the visible grid as an accessibility element with role `AXTextArea`, label "Terminal", value = visible text, and live-region-style updates for selection/cursor. Better: expose per-cell or per-line children and support VoiceOver navigation, selection, and focus.
- **Test gap:** No tests assert accessibility roles, labels, values, focus, or selection announcements. `TerminalBitmapViewWakeTests.swift:192–204` only tests that Reduce Motion option changes wake the frame loop.
- **Related docs:** `docs/product/mvp.md` (regression contract does not require rich accessibility, but basic NSAccessibility for the terminal surface is missing entirely).

---

### BUG-03 — Export Cast / Capture crashes if Library directory lookup fails

- **Severity:** Critical
- **Status:** Verified
- **Subsystem:** LabanApp / export & persistence
- **User impact:** The user chooses *Export Last 10 s as Cast* (⌘E) or starts a PTY capture. If `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)` returns an empty array (restricted/sandboxed account, missing home volume, unusual environment), the app crashes instead of showing an error or falling back to a temp directory.
- **Root cause:** Both `castDirectory()` and `captureDirectory()` force-unwrap `.first!`. `AppDelegate.revealLogFolder(_:)` correctly guards with `first?`; these two helpers do not.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:5946–5948`
    ```swift
    return FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Logs/Laban/casts", isDirectory: true)
    ```
  - `Sources/LabanApp/TerminalBitmapView.swift:6208–6210`
    ```swift
    let logs = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Logs/Laban/captures", isDirectory: true)
    ```
- **Fix direction:** Guard with `first ?? FileManager.default.temporaryDirectory` or similar fallback, and surface a user-visible error if the directory cannot be created. Align with `AppDelegate.revealLogFolder(_:)`.
- **Test gap:** No test exercises empty `.libraryDirectory` results or fallback paths.
- **Related docs:** `docs/process/dev-process.md` (capture/replay artifacts).

---

### BUG-04 — Multiple Laban.app instances can run simultaneously

- **Severity:** Critical
- **Status:** Verified
- **Subsystem:** LabanApp / build & bundle configuration
- **User impact:** The user launches `Laban.app` twice (e.g., from Finder and `open -n`, or a restart shortcut respawns before the old process exits). Two instances can fight over the same daemon socket, workspace persistence file (`~/Library/Application Support/Laban/workspace.json`), agent observers, and capture/cast directories, leading to silent data corruption or confusing state.
- **Root cause:** The generated `Info.plist` does not set `LSMultipleInstancesProhibited`.
- **Evidence:**
  - `scripts/build-app:138–189` generates the bundle `Info.plist` with keys: `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundleName`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion`, `CFBundleIconFile`, `LSMinimumSystemVersion`, `LABANBuildCommit`, `LABANBuildDate`, `LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption`, `NSHighResolutionCapable`, `NSHumanReadableCopyright`, `CFBundleURLTypes`. No `LSMultipleInstancesProhibited`.
  - Grep across repo returns zero matches for `LSMultipleInstancesProhibited`.
  - Verified in generated `.build/laban/Laban.app/Contents/Info.plist`.
- **Fix direction:** Add `LSMultipleInstancesProhibited` = `true` to the generated `Info.plist` in `scripts/build-app`. Confirm single-instance behavior with a manual or automated test. If intentional multi-instance support is desired, document it and separate per-instance resources (sockets, workspace files).
- **Test gap:** No automated test launches two instances and checks socket/workspace isolation.
- **Related docs:** `scripts/build-app`

---

### BUG-05 — Daemon/labpty crash loses every session with no user-facing recovery

- **Severity:** Critical
- **Status:** Verified
- **Subsystem:** LabanCore / LabanApp — PTY client & session coordination
- **User impact:** The user is running tabs through the `labpty`/`laband` backend. If the daemon crashes or is killed, existing tabs become unresponsive dead sessions. Long-running processes are lost without clear feedback; there is no dialog, banner, or auto-restart.
- **Root cause:** `PTYLabClient` detects a dead socket, respawns a fresh daemon, and reconnects, but the new daemon has no in-memory session catalog. `AppSessionCoordinator` only reconnects/re-creates sessions silently. The only user-facing recovery flow (`MainWindowController.promptToAdoptUnclaimedLabptySessions`) handles orphan sessions found at launch, not a crash of an already-attached daemon.
- **Evidence:**
  - `Sources/LabanCore/PTYLabClient.swift:484–492` — comment: *“The socket is gone — labpty most likely crashed mid-session… Sessions from the dead daemon are not recovered (labpty keeps its catalog in memory only); higher layers re-create sessions against the new daemon. Without a hook we surface the error.”*
  - `Sources/LabanApp/AppSessionCoordinator.swift` — no UI recovery path; logs errors silently.
- **Fix direction:** Surface a non-modal banner or alert when a daemon crash is detected, listing affected tabs and offering to restart shells in new sessions. Optionally persist daemon session metadata to disk so recovery can reattach.
- **Test gap:** No automated test simulates a daemon crash during an active session and checks user-visible recovery.
- **Related docs:** `docs/adr/README.md` (PTY ownership decisions)

---

### BUG-06 — Raw → canonical PTY mode flip silently drops input

- **Severity:** Critical
- **Status:** Verified
- **Subsystem:** Labpty / PTY I/O
- **User impact:** The user exits a raw-mode TUI (vim, less, nano) back to the shell and immediately types or pastes a long line. Some bytes can be silently dropped; the user sees no error but keystrokes are lost.
- **Root cause:** When raw mode resets, `session->canonical_pending_estimate` is zeroed. Bytes written in raw mode that the child never read stay physically queued in the slave, but are dropped from Labpty's estimate. After the flip, canonical-mode `FIONREAD` reports only completed lines, so the next canonical preflight can over-admit into a near-full queue and the line discipline truncates overflow.
- **Evidence:**
  - `Sources/Labpty/main.c:843–855` — code and comment explicitly describe the limitation.
  - `docs/adr/0008-labpty-write-input-backpressure-contract.md:89–99` — documents this as **KNOWN LIMITATION (M3)** and states it is not fixed because the accurate fix is too costly on the hot input path.
- **Fix direction:** Either carry over a conservative pending estimate from raw mode, or add a bounded drain-after-flip that re-syncs the estimate with the actual slave queue. At minimum, surface an error or stall rather than silently dropping bytes.
- **Test gap:** `Tests/LabptyTests/LabptyAdversarialTests.swift` pins a simpler truncation case, but not the raw→canonical carry-over overflow.
- **Related docs:** `docs/adr/0008-labpty-write-input-backpressure-contract.md`

---

## High

### BUG-07 — Window resize clears selection only on column change; row-only resize leaves stale selection

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanApp / selection
- **User impact:** The user selects text and resizes the window vertically (or zooms font size) so the number of rows changes but column count stays the same. The selection anchor/focus coordinates are left intact, so the rendered highlight can point at wrong cells or reference rows that no longer exist.
- **Root cause:** `setFrameSize(_:)` only compares `cols` to `lastAppliedCols`; it does not check `rows`.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:3257–3261`
    ```swift
    let cols = max(1, termW / cellWidth)
    if cols != lastAppliedCols, lastAppliedCols != 0 {
        // Reflow invalidates grid-anchored selection coordinates.
        clearAllSelectionState()
    }
    ```
- **Fix direction:** Also clear selection when `rows` changes, or better, reproject selection coordinates after reflow instead of discarding them.
- **Test gap:** `Tests/LabanAppTests/TerminalBitmapViewSelectionTests.swift:121–153` tests only the column-change case.

---

### BUG-08 — Font-size zoom clears selection on column change only (not unconditionally)

- **Severity:** High
- **Status:** Corrected
- **Subsystem:** LabanApp / selection
- **User impact:** Original report claimed zoom unconditionally wipes selection. Re-verification shows `applyFontSize(_:)` uses the same column-change guard as `setFrameSize`, so selection survives zoom that preserves column count.
- **Root cause:** `applyFontSize(_:)` checks `cols != lastAppliedCols` before clearing.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:3363–3366`
    ```swift
    let cols = max(1, termW / cellWidth)
    if cols != lastAppliedCols, lastAppliedCols != 0 {
        clearAllSelectionState()
    }
    ```
- **Fix direction:** Same as BUG-07: handle row change and/or reproject coordinates.
- **Test gap:** No test verifies selection behavior across font-size changes.

---

### BUG-09 — Kitty inline images are not displayed

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanCore / LabanRenderer — terminal capability
- **User impact:** Agent TUIs (Kimi Code, Codex, Claude Code) that return images via the Kitty graphics protocol render as blank/placeholder instead of pictures.
- **Root cause:** `FrameProducer` never queries libghostty’s Kitty-graphics store or emits `FrameCommand.texturedQuad`. `SoftwareRenderer` and `MetalRenderer` accept `.texturedQuad` but skip drawing it.
- **Evidence:**
  - `Sources/LabanCore/FrameProducer.swift` — emits `.rect`, `.glyphRun`, `.cursor`, `.selection`, `.findMatch`, `.findSelected`, `.preedit`; no `.texturedQuad` production.
  - `Sources/LabanRenderer/SoftwareRenderer.swift:70–73`
    ```swift
    case .texturedQuad:
      // Kitty graphics / image quads are deferred; command is accepted
      // but not drawn by the software renderer in this shard.
      break
    ```
  - `Sources/LabanRenderer/MetalRenderer.swift:3120–3121` and `:3330–3331` — also `break` on `.texturedQuad`.
  - `execplans/active/kimi-code-terminal-capability-gaps.md` — lists inline images as gap ADV-01.
- **Fix direction:** Wire libghostty Kitty-graphics placements into `FrameProducer` as `.texturedQuad` commands, then implement quad rendering in `MetalRenderer` (and optionally `SoftwareRenderer`).
- **Test gap:** No test renders a Kitty image and asserts pixels.
- **Related docs:** `execplans/active/kimi-code-terminal-capability-gaps.md`

---

### BUG-10 — tmux / screen DCS passthrough is dropped

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanTerminalCore — OSC host scanner
- **User impact:** Running an agent under `tmux` or `screen` silently breaks OSC 8 hyperlinks, OSC 9 desktop notifications, OSC 9;4 progress bars, and OSC 10/11 color replies, because tmux wraps these in `DCS tmux; … ST` envelopes.
- **Root cause:** `osc_host.c` treats any `DCS/SOS/PM/APC` body as a string to skip; it never unwraps `DCS tmux; … ST` envelopes and re-feeds the inner OSC sequences to the host scanners.
- **Evidence:**
  - `Sources/LabanTerminalCore/osc_host.c:564–577`
    ```c
    case OH_STRING:
        /* DCS/SOS/PM/APC body: jump to its BEL/ESC terminator. */
        i = laban_scan_skip_to_esc_or_bel(bytes, len, i);
        ...
    case OH_STRING_AFTER_ESC:
        if (b == '\\') sc->state = OH_NORMAL;        /* ST */
        ...
    ```
  - `Sources/LabanTerminalCore/session_internal.h:131` — `OH_STRING` documented as "inside a DCS/SOS/PM/APC string: skip, do not scan".
  - `execplans/active/kimi-code-terminal-capability-gaps.md` confirms the gap.
- **Fix direction:** Detect `DCS tmux;` (and similar `screen*` / `tmux` passthrough prefixes), strip the envelope, and recursively feed the inner bytes back through the OSC host scanner.
- **Test gap:** No test verifies OSC passthrough inside tmux/screen envelopes.
- **Related docs:** `execplans/active/kimi-code-terminal-capability-gaps.md`

---

### BUG-11 — Emoji / grapheme cluster width fidelity is unverified

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanCore / LabanRenderer — terminal capability
- **User impact:** Agent TUIs compute column widths with `Intl.Segmenter` and assume RGI emoji = 2 cols. If Laban’s cell assignment disagrees, rainbow headers, table borders, and progress bars drift by a column.
- **Root cause:** No conformance test compares Laban’s rendered cell widths against the agent-TUI expectation set.
- **Evidence:**
  - `execplans/active/kimi-code-terminal-capability-gaps.md:68–73` — M1 "Terminal-capability conformance suite" and M4 "Emoji / grapheme width fidelity: measure, then fix-or-document" are explicitly pending.
  - No `TerminalWidthConformance`, grapheme-width, or agent-TUI fixture tests under `Tests/`.
- **Fix direction:** Build a conformance fixture (RGI emoji, ZWJ sequences, CJK, combining marks) and assert Laban’s `cols` per grapheme cluster matches a reference model (e.g., `wcwidth` with Unicode 15 + RGI emoji = 2). Expose mismatches as a test failure or documented deviation.
- **Test gap:** Entirely missing.
- **Related docs:** `execplans/active/kimi-code-terminal-capability-gaps.md`

---

### BUG-12 — Find columns are wrong for wide CJK / emoji in scrollback fallback

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanCore / find
- **User impact:** The user searches scrollback history containing CJK or emoji. Find highlights are drawn at the wrong coordinates because column math is off by a factor of two for wide characters.
- **Root cause:** `rowBuffer(fromUTF8Row:)` advances `column` by `+1` per grapheme cluster regardless of actual East Asian Width. The snapshot path correctly handles `LABAN_CELL_WIDE_WIDE`, but the scrollback fallback does not.
- **Evidence:**
  - `Sources/LabanCore/TerminalFind.swift:194–216`
    ```swift
    // NOTE (L-1): this advances one column per grapheme, so a wide
    // CJK/emoji cell left of a match under-reports the column in the
    // scrollback-fallback path vs the width-correct snapshot path. A
    // locale-independent fix needs the extractor to carry per-row column
    // metadata (wcwidth is locale-dependent and unreliable here); deferred.
    ```
- **Fix direction:** Carry per-row column metadata in the scrollback extractor, or compute width using the same model as the terminal core. Avoid locale-dependent `wcwidth` by using a pinned Unicode width table.
- **Test gap:** `Tests/LabanCoreTests/TerminalFindTests.swift` tests ASCII scrollback only; no wide-character scrollback column assertions.

---

### BUG-13 — Selection text extraction from scrollback is wrong for wide characters

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanCore / selection
- **User impact:** The user selects and copies text from scrollback that contains CJK or emoji. Column-based start/end bounds map to the wrong substring, truncating or skipping characters.
- **Root cause:** `plainLineText(from:startCol:endCol:)` iterates by Swift `Character` and treats each as one column. The viewport path handles `LABAN_CELL_WIDE_WIDE`, but the scrollback fallback does not.
- **Evidence:**
  - `Sources/LabanCore/TerminalSelection.swift:279–292`
    ```swift
    private static func plainLineText(from row: String, startCol: Int, endCol: Int) -> String {
      ...
      for character in row {
        let nextCol = col + 1
        ...
      }
    }
    ```
- **Fix direction:** Use the same width-aware iteration in the scrollback fallback as the snapshot path, skipping wide-character spacer tails and advancing two columns for wide cells.
- **Test gap:** No test verifies wide-character selection/copy accuracy in scrollback.

---

### BUG-14 — Launch failure is fatal if the labpty daemon is transiently stalled

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanApp / LabanCore — startup
- **User impact:** The user launches Laban while an existing `labpty` daemon is busy (e.g., `handle_open` blocking the single-threaded poll loop). If the retry window does not outlast the stall, the app shows a modal error dialog and terminates. There is no graceful degrade to in-process backend or "try again" path.
- **Root cause:** `MainWindowController.makeAndShow` throws on failure; `AppDelegate.showStartupFailure` presents an alert and calls `NSApp.terminate(nil)`. `PTYLabClient.withReconnectRetryLocked` retries transient drops only after the initial connection.
- **Evidence:**
  - `Sources/LabanApp/AppDelegate.swift:92–99`
  - `Sources/LabanApp/AppDelegate.swift:214–220` — `showStartupFailure` → `alert.runModal()` → `NSApp.terminate(nil)`.
  - `Sources/LabanCore/PTYLabClient.swift:374–398` — retry helper exists but is not applied to the initial launch handshake.
  - `prompt-exports/labpty-stale-daemon-client-connect-handoff.md` documents the fatal modal.
- **Fix direction:** Apply the reconnect retry policy to the initial launch handshake, or fall back to the in-process backend when the daemon is temporarily unreachable. If all else fails, show a retry dialog instead of terminating.
- **Test gap:** No automated test for startup under a stalled daemon.
- **Related docs:** `prompt-exports/labpty-stale-daemon-client-connect-handoff.md`

---

### BUG-15 — Session I/O force-unwraps `Data` base addresses

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanCore / Session
- **User impact:** Typing, pasting, sending mouse reports, or replaying captured output can crash the session if a `Data`/`[UInt8]` buffer yields a nil base address.
- **Root cause:** `withUnsafeBytes { $0.baseAddress! }` is used throughout `Session.write`, `feedOutput`, `replayPtyOutput`, `captureInput`, and paste encoding paths. Empty inputs are guarded, but the force unwrap remains a latent crash point.
- **Evidence:**
  - `Sources/LabanCore/Session.swift:479` — `try body(buffer.baseAddress!)` (string-array buffer, not Data).
  - `Sources/LabanCore/Session.swift:538, 552, 591, 703, 1202, 1242, 1278, 1296` — `buf.baseAddress!.assumingMemoryBound(to: UInt8.self)` / `inputBuf.baseAddress!...`.
- **Fix direction:** Replace force unwraps with `guard let baseAddress = buf.baseAddress else { return }` (empty input early return) or use `Data.copyBytes` / `Array` overloads that avoid the issue.
- **Test gap:** No test exercises empty/zero-length input through these paths.

---

### BUG-16 — No undo support for destructive actions

- **Severity:** High
- **Status:** Verified
- **Subsystem:** LabanApp / LabanCore
- **User impact:** The user accidentally closes a tab (⌘W), pastes a large block, or drag-drops files. macOS users expect Cmd+Z to undo these actions, but nothing happens.
- **Root cause:** No `UndoManager` / `registerUndo` usage anywhere in `Sources/LabanApp` or `Sources/LabanCore`.
- **Evidence:** Grep for `UndoManager` and `registerUndo` returns zero matches.
- **Fix direction:** Wire `NSResponder.undoManager` for the main window/tab controller. Register undo for: close tab (re-open with same shell/directory), paste (send backspace/delete), drag-drop (no-op or revert). Start with close-tab as the highest-impact action.
- **Test gap:** No undo tests exist.

---

## Medium

### BUG-17 — Metal renderer force-unwraps render-pass attachments

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanRenderer / Metal
- **User impact:** A render frame on the Metal backend (resize, tab switch, keystroke, scroll) could crash if `colorAttachments[0]` is unexpectedly nil.
- **Root cause:** `MTLRenderPassDescriptor.colorAttachments[0]!` is force-unwrapped at seven sites.
- **Evidence:**
  - `Sources/LabanRenderer/MetalRenderer.swift:701, 715, 729, 1166, 1434, 1586, 1781`.
- **Fix direction:** Use `guard let attachment = pass.colorAttachments[0] else { return/fallback }` and surface a renderer failure rather than crashing.
- **Test gap:** No test simulates attachment allocation failure.

---

### BUG-18 — labpty byte-ring reader force-unwraps `mmap` result

- **Severity:** Medium
- **Status:** Verified (guarded)
- **Subsystem:** LabanCore / labpty byte-ring
- **User impact:** Launching or reattaching to a labpty session could crash if `mmap` returns nil after a non-`MAP_FAILED` guard.
- **Root cause:** `map = mapped!` after checking `mapped != MAP_FAILED`.
- **Evidence:**
  - `Sources/LabanCore/LabptyByteRingReader.swift:42–47`
    ```swift
    guard mapped != MAP_FAILED else { ... }
    map = mapped!
    ```
- **Fix direction:** The guard makes this safe in practice, but still replace `!` with a bounded cast or keep the optional unwrapped via `guard`. Defensive cleanup only.
- **Test gap:** None.

---

### BUG-19 — BitmapSurface allocation can overflow and force-unwraps Core Graphics objects

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanRenderer / software surface
- **User impact:** Extremely large or zero-dimension surfaces (e.g., huge window resize, large-scale screenshot/capture) can crash during renderer initialization.
- **Root cause:** `byteCount = height * width * 4` and `bytesPerRow = width * 4` are unchecked `Int` multiplications. `CGContext(...)!` and `CGColor(...)!` are force-unwrapped.
- **Evidence:**
  - `Sources/LabanRenderer/BitmapSurface.swift:22–43`
  - `Sources/LabanRenderer/BitmapSurface.swift:71–78`
- **Fix direction:** Use `multipliedReportingOverflow(by:)` / `addingReportingOverflow`, fail gracefully on overflow, and guard `CGContext`/`CGColor` creation with `guard let` + error path.
- **Test gap:** No test exercises extreme dimensions.

---

### BUG-20 — Selection hit-testing divides by cell metrics without zero checks

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / selection input
- **User impact:** If a degenerate font or resize path ever produces `cellWidth == 0` or `cellHeight == 0`, any mouse click or drag in the terminal crashes from division by zero / infinity.
- **Root cause:** `cols`, `terminalCell(at:)`, and `clampedPoint(at:)` divide by `cellWidth`/`cellHeight` without guarding against zero.
- **Evidence:**
  - `Sources/LabanApp/TerminalSelectionInput.swift:37–38, 63–64, 77–78`
- **Fix direction:** Add `guard cellWidth > 0, cellHeight > 0 else { return nil/default }` or clamp denominators to ≥1.
- **Test gap:** No test exercises zero cell metrics.

---

### BUG-21 — GPU cell payload failure notifications can spam Notification Center

- **Severity:** Medium
- **Status:** Corrected
- **Subsystem:** LabanApp / renderer diagnostics
- **User impact:** Original report claimed unthrottled spam. Re-verification found `autoDumpGPUCellPayloadFailure` deduplicates identical failure signatures within 60 seconds, so repeated identical failures do not spam. However, each *distinct* failure signature still creates a unique notification with no independent rate limit or user toggle.
- **Root cause:** `postGPUCellPayloadFailureNotification` creates a notification with a unique UUID identifier. The 60-second same-signature dedup is in the caller, not the notification logic.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:2532–2554`
  - `Sources/LabanApp/TerminalBitmapView.swift:2442–2479` — 60-second dedup by signature.
- **Fix direction:** Add a global rate limit (e.g., one notification per N minutes total) and/or a user preference to disable GPU failure notifications. Consider batching multiple distinct failures into a single summary notification.
- **Test gap:** No test for notification throttling or batching.

---

### BUG-22 — No visible keyboard focus ring on the terminal view

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / accessibility & focus
- **User impact:** Users with Full Keyboard Access or those switching apps/spaces cannot tell whether the terminal has focus.
- **Root cause:** `TerminalBitmapView.acceptsFirstResponder == true` but no `drawFocusRingMask`, `focusRingType`, or `focusRingMaskBounds` overrides.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:3398`
- **Fix direction:** Implement `drawFocusRingMask()` and/or set `focusRingType` so AppKit draws a standard focus ring around the terminal surface.
- **Test gap:** No focus-ring tests.

---

### BUG-23 — Other accessibility display settings are ignored

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / accessibility
- **User impact:** Users who enable Increase Contrast, Differentiate Without Color, or Reduce Transparency see no change in Laban. Color-blind/low-vision users may not distinguish selection vs. cursor or attention pulses.
- **Root cause:** Only `accessibilityDisplayShouldReduceMotion` is read and observed.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:182` — caches only `reduceMotion`.
  - `Sources/LabanApp/TerminalBitmapView.swift:527–530` — observer updates only `reduceMotion`.
  - No references to `accessibilityDisplayShouldIncreaseContrast`, `accessibilityDisplayShouldDifferentiateWithoutColor`, or `accessibilityDisplayShouldReduceTransparency`.
- **Fix direction:** Observe all accessibility display options and adjust rendering: use stronger outlines for Increase Contrast, avoid color-only cues for Differentiate Without Color, disable transparency for Reduce Transparency.
- **Test gap:** No tests for these options.

---

### BUG-24 — Double-click word selection breaks on wide-character spacer tails

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / selection input
- **User impact:** Double-clicking an emoji/CJK word selects partial grapheme clusters or stops at spacer-tail cells.
- **Root cause:** `wordBounds` stops expanding when `cellScalar` returns `nil` for a `LABAN_CELL_WIDE_SPACER_TAIL` cell, and `cellScalar` only examines the first Unicode scalar of a cell. `isWord` accepts only `CharacterSet.alphanumerics` plus `|-_./:~@`.
- **Evidence:**
  - `Sources/LabanApp/TerminalSelectionInput.swift:118–168`
- **Fix direction:** Treat wide cells and their spacer tails as a single unit; include CJK/emoji as word constituents; use Unicode word-boundary segmentation (`Unicode.WordBoundary` or ICU `ubrk`).
- **Test gap:** No word-selection tests for wide characters or ZWJ emoji clusters.

---

### BUG-25 — Preedit caret and mask width are mispositioned for wide characters

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / LabanCore — IME preedit
- **User impact:** Using an IME or dictation to compose CJK text places the underlined preedit caret one cell to the left of where it should be, and the preedit highlight mask is too narrow.
- **Root cause:** `markedTextCaretCells` counts grapheme clusters (`ns.substring(to: caretUTF16).count`), not terminal display columns. `FrameProducer.appendPreedit` computes `runWidth = CGFloat(text.count) * cw`, also assuming one cell per grapheme cluster.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:3487–3491` — caret cells = grapheme count.
  - `Sources/LabanCore/FrameProducer.swift:472` — mask width = `CGFloat(text.count) * cw`.
- **Fix direction:** Compute caret offset and mask width using terminal cell widths (2 for wide CJK/emoji, 1 for narrow) rather than grapheme count.
- **Test gap:** No preedit tests for wide characters.

---

### BUG-26 — MenuCommands force-unwraps UnicodeScalar for arrow-key equivalents

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / menus
- **User impact:** Menu setup could crash if `UnicodeScalar(UInt32(NSLeftArrowFunctionKey))` ever returns nil.
- **Root cause:** Force unwrap of `UnicodeScalar` initializer.
- **Evidence:**
  - `Sources/LabanApp/MenuCommands.swift:204, 212`
    ```swift
    keyEquivalent: String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)
    ```
- **Fix direction:** Use optional binding or hard-coded string literals for function-key equivalents.
- **Test gap:** None.

---

### BUG-27 — Automation env vars can terminate the app without warning

- **Severity:** Medium
- **Status:** Verified
- **Subsystem:** LabanApp / automation
- **User impact:** If `LABAN_AUTO_QUIT_AFTER_SECONDS` or `LABAN_RESIZE_AUTO_QUIT=1` leak into normal use, the app appears to quit spontaneously with no confirmation.
- **Root cause:** Both paths call `NSApp.terminate(nil)` unconditionally.
- **Evidence:**
  - `Sources/LabanApp/TerminalBitmapView.swift:606–614` — auto-quit after seconds.
  - `Sources/LabanApp/TerminalBitmapView.swift:638–644` — `config.autoQuit` terminates.
  - `Sources/LabanApp/TerminalResizeAutomation.swift:27` — maps `LABAN_RESIZE_AUTO_QUIT`.
- **Fix direction:** Add an on-screen notice (e.g., status bar icon or banner) when automation termination is armed, or require an additional confirmation/env var before terminating.
- **Test gap:** No test verifies user-visible notice before auto-termination.

---

### BUG-28 — Daemon-side input `memcpy` lacks explicit local upper-bound check

- **Severity:** Medium
- **Status:** Corrected
- **Subsystem:** Labpty / protocol
- **User impact:** Original report suggested a possible buffer overflow. Re-verification confirmed the upstream protocol decoder rejects payloads larger than `LABPTY_WRITE_INPUT_MAX`, and a CBMC contract also bounds the output length, so an overflow is not reachable. However, the local `memcpy` site still lacks an explicit assertion, which is a defensive-coding/style issue.
- **Root cause:** `memcpy(session->pending_input, request.bytes + sent, tail)` in `main.c` does not locally assert `tail <= LABPTY_WRITE_INPUT_MAX`.
- **Evidence:**
  - `Sources/Labpty/main.c:818–820`
  - `Sources/Labpty/labpty_protocol.c:342` — upstream bound.
  - `Sources/Labpty/include/labpty_internal.h` — `LABPTY_WRITE_INPUT_MAX = 64 * 1024`.
- **Fix direction:** Add a local `assert(tail <= LABPTY_WRITE_INPUT_MAX)` or explicit guard to make the safety property obvious at the call site.
- **Test gap:** `Tests/LabptyTests/LabptyProtocolPropertyTests.swift:348–355` already verifies the encoder rejects oversize payloads.

---

## Suggested prioritization for a fix sprint

1. **BUG-01** + **BUG-07/08** — selection correctness is user-visible on every scroll/resize.
2. **BUG-02** — accessibility is a hard blocker for screen-reader users and required for native macOS citizenship.
3. **BUG-03** — crash on export is a sharp edge.
4. **BUG-04** — single-instance enforcement prevents data corruption.
5. **BUG-09** + **BUG-10** + **BUG-11** — agent-TUI capability gaps directly impact product strategy.
6. **BUG-05** + **BUG-14** — daemon resilience and startup reliability.
7. **BUG-06** — silent input drop is subtle but severe for power users.
8. **BUG-12** + **BUG-13** + **BUG-24** + **BUG-25** — wide-character/emoji consistency across find, copy, selection, and IME.
9. **BUG-15** + **BUG-17** + **BUG-19** + **BUG-20** — harden crash-prone force unwraps and divides.
10. **BUG-16**, **BUG-22**, **BUG-23**, **BUG-27** — UX polish and accessibility depth.

---

## Cross-cutting themes

1. **Wide-character / emoji paths are inconsistent.** Cell width is handled correctly in some places (viewport snapshot) but wrong or missing in scrollback, find, selection copy, IME caret, IME mask, and word selection.
2. **Force-unwraps in core paths.** Several crash points exist in I/O, export, renderer setup, and menu setup. Many are guarded in practice but remain latent risks.
3. **Selection semantics are fragile around resize and scroll.** Selection is either discarded too aggressively or preserved incorrectly.
4. **Accessibility is largely absent.** Only Reduce Motion is honored; the terminal surface, focus ring, and display options are unimplemented.
5. **Agent-TUI conformance is incomplete.** Kitty images, tmux/screen passthrough, and emoji width fidelity are gaps documented in `execplans/active/kimi-code-terminal-capability-gaps.md`.
