# Make Laban fully compatible with Claude Code fullscreen rendering

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they hold information a fresh
contributor needs.

## Purpose / Big Picture

Claude Code is a full-screen terminal UI ("TUI": a program that paints the whole
terminal grid with cursor-addressing escape sequences instead of printing line by
line). When a user runs `claude` inside Laban, several interactions are wrong
today. After this change a user can:

- **Dismiss a leftover text selection with a single click while Claude Code is
  running.** Today a click is swallowed by mouse reporting and the highlighted
  text stays painted.
- **Scroll back through history with Shift+mouse-wheel while Claude Code (or any
  mouse-tracking TUI) is running.** Today every wheel tick is forwarded to the
  app and Laban's own scrollback never moves, so there is no way to scroll back.
- **Have window focus changes reach Claude Code** (so it can dim/refresh) when
  using the default daemon-backed session tier.
- **See Claude Code repaint without tearing** on the daemon multi-client tier
  (the in-process tier is already correct).

How to see it working is described per milestone in *Concrete Steps* and
*Validation and Acceptance*. The two user-reported symptoms (click-to-deselect,
scrollback) are Milestones 1 and 2.

This plan is grounded in a **real captured Claude Code session**, recorded with
Laban's "Toggle PTY Capture" menu command, at:

```
~/Library/Logs/Laban/captures/appkit-2026-05-28T19-30-47Z/
  streams/pty-output.bin        96810 B  bytes Claude Code emitted
  streams/terminal-response.bin    20 B  bytes Laban auto-replied (XTVERSION + DA1)
  timeline.ndjson                        input/frame/snapshot event timeline
```

A captured-session artifact can be re-derived any time with Laban's capture
toggle; the byte counts below were measured from this artifact.

## Progress

- [x] (2026-05-28) Captured a real Claude Code session and decoded the exact
  sequences it emits; audited each capability against current code.
- [x] (2026-05-28) Resolved the scrollback product decision with the user:
  Shift+wheel scrolls Laban scrollback; plain wheel keeps forwarding to the app.
- [x] (2026-05-28) **M0 [P0] Route mouse input (wheel/click/drag) to the daemon PTY
  on the labpty/laband tier.** DONE. Mouse was encoded then dropped on the default
  backend, so no TUI received any mouse events. Fixed by forwarding the encoded bytes
  to the daemon (mirroring paste/keys) in the live view (`TerminalBitmapView`: all
  four wheel/down/drag/up handlers + the three rightMouse handlers, via
  `forwardEncodedMouseToDaemon`) and the headless runtime (`DebugMouseActions`
  wheel + click, via `forwardEncodedInputToDaemon`). Verified: app builds;
  `HeadlessMouseRoutingTests.testHeadlessMouseWheelReachesChildOverLabandBackend`
  passes and fails when the forward is removed (mutation-checked); paste-routing
  regression still green.
- [x] (2026-05-29) M1 [P1] Click clears a committed selection under mouse tracking.
  DONE. After b71ea98 reworked the handlers (deferred clicks), a press under tracking
  hits `mouseDown`'s `.deferUnderTracking` case, which set `pendingTrackingClick`
  without clearing the committed selection (and `mouseUp`'s `pendingTrackingClick`
  branch forwarded the click but never cleared it), so the highlight stayed painted.
  Fixed by clearing the active-tab selection there (scoped: `syncSelectionStateToActiveTab`
  → null fields → `persistSelectionStateForCurrentTab` → record `clearSelection`).
  Verified by new red/green test
  `TerminalBitmapViewSelectionTests.testClickClearsSelectionWhenMouseTrackingIsActive`;
  all 19 selection + mouse-input tests pass (incl. multi-tab persistence and
  shift-under-tracking); non-shift drag still selects natively via `mouseDragged`.
- [ ] M2 [P2, optional] Shift+wheel scrolls Laban's OWN scrollback as an escape hatch
  (nice-to-have once M0 makes plain wheel reach the app).
- [ ] ~~M2b~~ SUPERSEDED by M0. With mouse forwarding fixed, plain wheel reaches the
  app and the app scrolls (iTerm2 behavior); Laban no longer needs to scroll its own
  scrollback under mouse tracking, so the `mvp.md` contract edit is unnecessary.
- [x] (2026-05-29) M3 [P1] Focus events (mode 1004) reach the daemon-backed
  (labpty/laband) PTY. DONE. `reportFocus` called `sendFocus`, which in fixture mode
  (the daemon tier) only encodes and drops the bytes — so a focus-aware app never saw
  CSI I / CSI O over the daemon. Fixed by branching on the tier in `reportFocus`
  (`TerminalBitmapView`): on the remote tier `encodeFocus` + `sessionCoordinator.write`,
  in-process keeps `sendFocus`; the tab-switch caller now resolves the outgoing `Tab`.
  Verified by new red/green test
  `HeadlessFocusRoutingTests.testHeadlessFocusInReachesChildOverLabandBackend`
  (mutation-checked); mouse + paste routing still green; app builds.
- [x] (2026-05-29) M4 [P1] Synchronized output (mode 2026) coalesces on the laband
  snapshot tier. DONE. In-process already honored 2026 via `TerminalRenderGate`, but the
  daemon's published snapshots never carried the state (`slotFlags` only stamped
  cursor flags) and the app's gate read the fixture session's always-false flag, so
  every mid-BSU frame tore. Stamp-the-bit fix (daemon keeps publishing; the app's 1s
  watchdog bounds the hold): `LabanSnapshot.synchronized_output` set in `snapshot.c`
  from `GHOSTTY_MODE_SYNC_OUTPUT` → `slotFlags` stamps the reserved `SlotFlag.synchronizedOutput`
  bit → `readSnapshot` decodes it into `LabandSnapshotResponse.synchronizedOutput` →
  `TerminalBitmapView` feeds `remoteFrame.snapshot.synchronizedOutput` into the gate
  when a remote frame is present. Verified by new red/green
  `LabandSnapshotSyncOutputRingTests.testSynchronizedOutputFlagCrossesTheRing`
  (mutation-checked); in-process sync gate, laband control protocol, and headless
  routing suites all green (16 tests); app builds.
- [x] (2026-05-29) M5 [P2] Regression test pinning kitty-keyboard Shift+Enter encoding.
  DONE (test-only; the encoding already worked). Added
  `LabanSessionKeyEncodingTests.testKittyShiftEnter`: with the kitty disambiguate flag
  pushed (`CSI >1u`), Shift+Enter encodes `CSI 13;2u`, guarding against a regression to
  a bare CR (which would submit the prompt instead of inserting a newline).
- [x] (2026-05-29) M6 [P2] Headless/autonomous coverage for focus reporting. DONE as
  part of M3: added a headless `windowFocus` action (`DebugWindowActions.windowFocus`,
  `DebugAction.windowFocus`) mirroring the app's NSWindow focus observers with the same
  tier-aware encode+forward, which `HeadlessFocusRoutingTests` exercises over the laband
  backend. Satisfies the AGENTS.md headless-parity rule for focus.
- [ ] M7 [P2] OSC 9;4 progress reports surface a tab/Dock busy affordance.
- [ ] M8 [investigate] Does terminal identity (TERM_PROGRAM / versioned XTVERSION)
  gate Claude Code's wheel-scroll? Idle A/B capture to confirm; advertise identity
  regardless as correct hygiene.

## Context and Orientation

A novice should read this section fully before touching code.

### What Claude Code actually emits (from the capture)

Decoded from `streams/pty-output.bin`:

- **Synchronized output, DEC private mode 2026** — `CSI ?2026h` (begin) and
  `CSI ?2026l` (end) appear **885 times each**. Claude Code wraps essentially
  every repaint in this Begin-Synchronized-Update / End-Synchronized-Update
  ("BSU"/"ESU") bracket. A compliant terminal buffers all drawing between BSU and
  ESU and presents it in one shot, so the user never sees a half-drawn frame.
- **Mouse tracking** — `CSI ?1000h ?1002h ?1003h ?1006h` (full button + motion
  tracking, SGR-encoded) and `CSI ?1004h` (focus reporting).
- **Keyboard** — Kitty keyboard protocol pushed (`CSI >1u`) and popped (`CSI <u`),
  and xterm `modifyOtherKeys` set (`CSI >4;2m`). These drive Shift+Enter and
  disambiguated Ctrl combinations. (Verified already working in Laban — see
  Milestone 5.)
- **Color** — truecolor `SGR 38;2;r;g;b` / `48;2;…` used 1707 times. No 256-color,
  no styled (`4:3` curly) or colored (`58`) underline in this session.
- **Queries Claude Code sent, and Laban's replies** (from
  `streams/terminal-response.bin`, 20 bytes total):
  - XTVERSION `CSI >0q` → Laban replied `ESC P >| laban ESC \` (correct).
  - Primary Device Attributes `CSI c` → Laban replied `CSI ?62;22c` (correct).
  - A DEC cursor-position request `CSI ?6n` got no reply, but Claude Code
    rendered 885 frames without hanging, so it is **non-blocking** (not a gap).
  - Background-color query OSC 11 (used for light/dark theme detection) fires at
    process startup, *before* the capture began, so its absence here proves
    nothing; the reply path is verified working (see "Reply path" below).

### The buffer question (why scrollback is subtle)

Claude Code renders its REPL using absolute cursor positioning (`CSI H`, row/col
moves) and a scroll region (`CSI 2;33r` set 16×, Scroll-Up `CSI …S` 16×). In the
capture there is exactly **one** `CSI ?1049h` (enter alternate screen) at byte
offset 5863 and **zero** `CSI ?1049l` (leave). That is *not* proof of a permanent
alternate screen: the bytes before offset 5863 are already a full-screen TUI
painted in the **normal/primary buffer**, and the stream simply ends mid-frame
("still thinking…") before any leave. So Claude Code uses the normal buffer for
its main REPL and may toggle the alternate screen for sub-views.

The user clarified the desired behavior (see *Decision Log*): **plain wheel keeps
forwarding to the app; Shift+wheel always scrolls Laban's scrollback.** This is
the iTerm2 / Terminal.app / kitty convention, needs no buffer-type detection, and
does not change the shipped plain-wheel contract.

### The reply path (why query/response is NOT a gap)

libghostty-vt parses VT input and generates capability replies (DA, XTVERSION,
OSC 11/10/4, DSR). Laban forwards them to the PTY via
`laban_session_drain_response` (`Sources/LabanTerminalCore/terminal_effects.c:144`,
declared in `Sources/LabanTerminalCore/include/LabanTerminalCore.h:688`). The
capture's `terminal-response.bin` (XTVERSION + DA1) confirms this path works for
the captured tier. No work is needed here.

### Session tiers (why "remote" milestones matter)

Laban can run a terminal session in three tiers (ADR 0006, ADR 0007):

- **in-process** — libghostty-vt runs inside the app process.
- **labpty** — a small daemon owns the PTY; the app reads a shared byte-ring.
- **laband** — a daemon owns the PTY *and* publishes authoritative snapshots to
  multiple clients.

The **default is `labpty`** whenever the `labpty` executable is present
(`Sources/LabanApp/MainWindowController.swift:399` `automaticTerminalBackend()`
returns `.labpty`). So the user's normal Claude Code session runs on the daemon
tier, which is why focus events (M3) and synchronized output (M4) must be fixed on
the remote path, not just in-process. A known prior bug of exactly this shape —
the app generating bytes that never reached the daemon PTY — was the paste fix in
commit `ecd12cc`; Milestone 3 mirrors that fix.

### Key files

```
Sources/LabanApp/TerminalBitmapView.swift   mouse/selection/scroll (~2096-2600),
                                            reportFocus (~511-520),
                                            clearAllSelectionState (1278),
                                            paste tier split (~1988-2000)
Sources/LabanCore/Session.swift             sendFocus (~762), ViewportState (~1306)
Sources/LabanApp/AppSessionCoordinator.swift  terminalClient (remote tier handle)
Sources/LabanTerminalCore/terminal_effects.c  laban_session_send_focus (~262),
                                              laban_session_drain_response (~144)
Sources/laband/main.swift                   publishSnapshot (~306-317), drain (~471)
Sources/LabanCore/LabandSnapshotRingLayout.swift  ring layout + flags (~97)
Sources/LabanCore/LabandProtocol.swift      laband wire protocol
Tests/LabanTerminalCoreTests/LabanSessionKeyEncodingTests.swift  key-encoding tests
```

## Decision Log

- Decision: In a mouse-tracking TUI, **plain wheel forwards to the app; Shift+wheel
  scrolls Laban's local scrollback.** Do NOT make plain wheel scroll local
  scrollback in the normal buffer (the other option offered).
  Rationale: User chose the Shift+wheel escape hatch (the iTerm2/Terminal.app/kitty
  convention). It is minimal, mirrors the existing Shift+click selection override
  (`TerminalBitmapView.swift:2375`), and preserves the shipped `docs/product/mvp.md`
  lines 243–245 plain-wheel contract, so it needs no spec.md scope change.
  Date/Author: 2026-05-28, with the user.
- Decision: Treat query/response paths (OSC 11/10/4, DA, XTVERSION, DSR) as **not a
  gap**. Rationale: the capture proves the `laban_session_drain_response` reply path
  works; the one unanswered query (`CSI ?6n`) is non-blocking.
  Date/Author: 2026-05-28.
- Decision: Treat curly/colored underline (SGR `4:3`, `58`) and 256-color as
  **out of scope** for Claude Code compatibility. Rationale: not emitted in the
  captured session (truecolor only). Revisit only if a later capture shows them.
  Date/Author: 2026-05-28.
- Decision (M2b): the *plain* wheel scrolls Laban's scrollback while a mouse-tracking
  app is in the normal/primary buffer; alt-screen apps still receive the plain wheel.
  Rationale: the capture showed Claude Code did not scroll on forwarded wheel events,
  and Laban cannot force it; matching iTerm2/Terminal.app makes the wheel always do
  something useful. The user explicitly opted in, accepting the `mvp.md:243-245`
  contract edit. Requires exposing alternate-screen state through `ViewportState`.
  Date/Author: 2026-05-28, with the user.

## Plan of Work

Seven milestones, each a single behavioral changeset (one reason per commit, per
AGENTS.md). M1–M4 are P1 (M1, M2 are the user-reported symptoms); M5–M7 are P2.
Milestones are independent except M6, which composes with M3. None requires a new
ADR; M4 touches the laband ring layout (a `schemas/`-adjacent contract) and must
preserve the ADR 0007 labpty protocol freeze.

### M0 [P0] Route mouse input to the daemon PTY on the labpty/laband tier

Root cause (confirmed by code + capture + an iTerm2/Laban A/B diagnostic): on the
default daemon-backed tier the local `Session` is fixture-mode (the daemon owns the
real PTY — see `Sources/LabanApp/TerminalBitmapView.swift:1981`). The mouse path
`session.sendMouseCapturingBytes` (`Sources/LabanCore/Session.swift:879`) calls
`laban_session_send_mouse_encoded` (`Sources/LabanTerminalCore/mouse_input.c:162`),
which in fixture mode **encodes but does not write to any PTY** (`mouse_input.c:195`
gates the write on `!s->fixture_mode`) and returns the encoded bytes. The view's
mouse handlers — `scrollWheel` (`:2098`), `mouseDown` (`:2313`), `mouseDragged`
(`:2422`), `mouseUp` (`:2498`) — then record those bytes in the input timeline but
**never call `sessionCoordinator.write(...)`** to forward them to the daemon. So all
mouse events (wheel, click, drag) are encoded, logged, and dropped. Evidence: the
capture has 124 `mouseWheel` events with non-empty `encodedHex` yet `pty-input.bin`
is 0 bytes; the `/tmp/mousediag.py` A/B shows iTerm2 delivers `\e[<64;…M` on the
wheel while Laban delivers nothing. Keystrokes and paste already do the remote
forward (paste at `:1989-2000`, key/image-paste at `:2022-2028`); mouse was never
wired.

Fix: mirror the paste/key remote split in all four mouse handlers. After
`let sent = session.sendMouseCapturingBytes(me)`, when
`sessionCoordinator?.terminalClient != nil` and `!sent.bytes.isEmpty`, forward via
`sessionCoordinator.write(sent.bytes, to: activeTab, session: session, size: model.terminalSize)`.
`sendMouseCapturingBytes` already encodes-only in fixture mode, so the local-VT
contamination concern that motivated the paste split does not arise; this is purely
additive. The in-process tier is unchanged (its `send_mouse_encoded` still writes
locally). Consider centralizing the "encode then deliver to the right PTY" decision
so wheel/down/drag/up share one code path rather than four copies.

Acceptance: after the fix, `/tmp/mousediag.py` in Laban receives `\e[<64;…M` /
`\e[<65;…M` on the wheel (matching iTerm2), and Claude Code's transcript scrolls on
the mouse wheel under Laban just as it does under iTerm2. Clicks and drags also reach
TUIs.

### M1 [P1] Click clears a committed selection under mouse tracking

Root cause: in `TerminalBitmapView.mouseDown`
(`Sources/LabanApp/TerminalBitmapView.swift:2382-2412`), when
`vs.mouseTracking` is true and the click is not Shift-modified, the code calls
`cancelSelectionDragForMouseTracking()` and forwards the press to the PTY, then
returns. `cancelSelectionDragForMouseTracking()` (`:2912`) resets only transient
drag state (`stopDragAutoscroll`, `localSelectionMouseGestureActive`,
`lastDragPoint`, `selectionOriginCell`) — it never clears `selectionAnchor` /
`selectionFocus`. The render path reads the selection unconditionally
(`currentTerminalSelection`, used at `:973`), so a selection committed via
Shift+drag stays painted after a dismissal click. The non-tracking path already
clears on a bare click (`beginSelection` sets focus nil at `:2235` and records
`clearSelection` at `:2237`); the mouse-tracking path lacks the equivalent.

Fix: inside the `vs.mouseTracking` branch, immediately after the
`cancelSelectionDragForMouseTracking()` call (line ~2388), if a committed
selection exists clear it **via `clearAllSelectionState()` (`:1278`)** — not by
nulling the fields directly — then record a `clearSelection` input event, then
fall through to forwarding the press as today. `clearAllSelectionState()` is
required because the selection is also persisted per-tab in `selectionsByTab` via
`persistSelectionStateForCurrentTab()` (`:1189`); merely nulling the live fields
would let `restoreSelectionState()` (`:1198`) repaint the stale selection on the
next tab switch or view rebuild.

### M2 [P1] Shift+wheel scrolls Laban scrollback while mouse tracking is on

Root cause: `TerminalBitmapView.scrollWheel`
(`Sources/LabanApp/TerminalBitmapView.swift:2114`) forwards the wheel to the PTY
whenever `vs.mouseTracking && !localSelectionMouseGestureActive`, with no Shift
escape hatch. The local-scroll path that scrolls Laban's scrollback lives just
below at `:2149` (`TerminalScrollInput.decide` → `scrollViewport`).

Fix: gate the forward branch so it does **not** trigger when Shift is held —
`vs.mouseTracking && !localSelectionMouseGestureActive && !event.modifierFlags.contains(.shift)`
— so a Shift+wheel event falls through to the existing local-scroll path. This
mirrors the Shift+click selection override at `:2375`. Plain (unmodified) wheel
behavior is unchanged (still forwarded), preserving `docs/product/mvp.md:243-245`.

**Boundary note (important):** Laban already forwards plain wheel ticks to the app
as correct SGR wheel-press events (`ESC[<64;col;row M` / `ESC[<65;…M`,
capture-verified). Whether Claude Code *scrolls* in response is Claude Code's own
input handling — Laban cannot force it. In the capture, Claude Code was mid-
generation ("thinking") and only animated its spinner; it did not scroll on the
124 forwarded wheel events. So M2 (Shift+wheel → Laban scrollback) is the complete
*Laban-side* fix: it guarantees the user can always scroll back regardless of what
the app does with the plain wheel.

### M2b [P1] Plain wheel scrolls Laban scrollback in the normal buffer

Decided in (user opted in). Apps that enable mouse tracking but do not bind the
wheel to scroll (Claude Code's REPL) should let the **plain** wheel scroll Laban's
scrollback while in the **normal/primary buffer** — matching iTerm2/Terminal.app,
which forward the wheel only in the alternate screen. True alt-screen apps (vim,
htop) keep receiving the plain wheel; Shift+wheel (M2) still scrolls Laban
everywhere as the universal escape hatch.

Steps:
1. **Expose alternate-screen state through `ViewportState`.** Add
   `int alternate_screen` to `LabanViewportState`
   (`Sources/LabanTerminalCore/include/LabanTerminalCore.h`), populate it in
   `laban_session_viewport_state` (`Sources/LabanTerminalCore/snapshot.c:743`) via
   `ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)`
   compared to `GHOSTTY_TERMINAL_SCREEN_ALTERNATE`, and surface it on
   `ViewportState` (`Sources/LabanCore/Session.swift:1306-1318`, mirroring the
   existing `mouseTracking` field). Plumb the bit across the laband ring so the
   remote tier reports it too (the ring already carries an `alternateScreen` flag at
   `LabandSnapshotRingLayout.swift:97` — reuse/route it into `ViewportState`).
2. **Combined `scrollWheel` gate.** With M2 + M2b, the forward-to-app branch at
   `TerminalBitmapView.swift:2114` becomes:
   `vs.mouseTracking && vs.alternateScreen && !localSelectionMouseGestureActive && !event.modifierFlags.contains(.shift)`.
   When that is false, fall through to the local-scroll path (`:2149`). Net result:
   alt-screen app + plain wheel → forward; normal-buffer app + plain wheel → Laban
   scrollback; Shift+wheel → Laban scrollback always.
3. **Update the product contract.** This changes the shipped
   `docs/product/mvp.md:243-245` plain-wheel behavior, so update that text (and note
   it in `docs/product/spec.md` if direction-level) to describe the new
   alt-screen-gated forwarding. The user explicitly requested this behavior, which
   AGENTS.md permits; updating the contract keeps `./scripts/check` and the
   regression story honest rather than leaving the change as a contract violation.

Caveat carried from the capture: it is not proven whether Claude Code's *steady*
REPL is normal-buffer or alt-screen (the capture entered alt-screen at offset 5863
while mid-generation and never left). If the steady REPL turns out to be
alt-screen, M2b's gate will still forward the plain wheel there and only Shift+wheel
(M2) will scroll Laban — a clean idle-state capture would confirm. M2 guarantees a
working path regardless.

### M3 [P1] Focus events (mode 1004) reach the daemon-backed PTY

Root cause: `reportFocus` (`Sources/LabanApp/TerminalBitmapView.swift:511-520`)
calls `session.sendFocus(focused:)` unconditionally, which routes through
`Session.swift:762` → C `laban_session_send_focus`
(`Sources/LabanTerminalCore/terminal_effects.c:262`). That encodes `CSI I` /
`CSI O` against the *in-process* libghostty terminal and writes to the in-process
PTY — but on the default labpty/laband tier the child PTY is owned by the daemon,
so the focus bytes never reach Claude Code.

Fix: in `reportFocus`, branch on the backend tier exactly like the paste split at
`TerminalBitmapView.swift:1988-2000`: when `sessionCoordinator?.terminalClient`
is non-nil (remote tier), encode the focus bytes and send them through the
terminal client to the daemon PTY; otherwise keep the in-process call. This is the
same fix shape as commit `ecd12cc` (paste over remote PTY). Mode-1004 gating
itself already lives in the C encoder, which no-ops when 1004 is off, so the app
side just needs to deliver the bytes to the right PTY.

### M4 [P1] Synchronized output (2026) coalesces on the laband snapshot tier

Root cause: the in-process path honors mode 2026 end-to-end (verified — not a
gap), but the laband multi-client tier does not. The daemon's `publishSnapshot`
(`Sources/laband/main.swift:306-317`, called from the drain path at `:471`)
publishes a new snapshot generation on every PTY drain, including mid-BSU, and the
"synchronized output active" flag never crosses the snapshot ring, so clients
present half-drawn frames → tearing on every Claude Code repaint.

Fix (stamp-the-bit, not defer-publish): carry the libghostty "synchronized output
active" flag across the laband snapshot ring
(`Sources/LabanCore/LabandSnapshotRingLayout.swift`, `Sources/LabanCore/LabandProtocol.swift`),
and have the **app-side** render gate suppress presentation while the bit is set,
reusing the existing bounded synchronized-output watchdog the in-process gate
already owns (so a missing ESU cannot hang the last frame). Do NOT make the daemon
defer publishing (that would need a new daemon-side ESU watchdog and risks hanging
the last frame). Verify whether the labpty byte-ring tier needs the same treatment
or already routes through the in-process VT (if it does, it is already correct).
Preserve the ADR 0007 labpty Phase 1 protocol freeze; if the ring layout gains a
field, bump the layout the same way existing flags were added (see the
`alternateScreen` flag at `LabandSnapshotRingLayout.swift:97`).

### M5 [P2] Regression test for kitty Shift+Enter

Kitty Shift+Enter encoding (`CSI 13;2u`, so Claude Code inserts a newline instead
of submitting) already works — verified by feeding `CSI >1u` then encoding Enter
with Shift and observing bytes `[27,91,49,51,59,50,117]`. There is no test pinning
it. Add `testKittyShiftEnter` to
`Tests/LabanTerminalCoreTests/LabanSessionKeyEncodingTests.swift`, following the
existing `testKittyShiftBackspace` pattern (it already has
`makeFixtureSession`/`feedVT`/`encodeKey` helpers). Test-only; no behavior change.

### M6 [P2] Headless coverage for focus reporting (composes with M3)

Focus is the only terminal-input class with zero headless/autonomous coverage and
no shared (LabanCore) gating — the AppKit-only focus logic and its remote-routing
decision (M3) cannot be regression-tested. Per the AGENTS.md hard rule
("user-visible terminal behavior needs autonomous verification;
`HeadlessDebugRuntime` stays in feature parity with `MainWindowController`"), lift
the focus gating/dedup decision into LabanCore and expose a headless debug
endpoint that drives focus-in/out and asserts the bytes reach the (in-process or
remote) PTY. Land after M3.

### M8 [investigate→P2] Advertise terminal identity (TERM_PROGRAM + versioned XTVERSION)

CONFIRMED Laban-specific (user A/B, 2026-05-28): Claude Code's content **does**
mouse-scroll under iTerm2 in a fullscreen TUI, but **not** under Laban. This rules
out the busy-thinking confound and proves Claude Code has working wheel-scroll that
something in Laban suppresses. Combined with the `less --mouse` proof (Laban's wheel
bytes are valid), the difference is one of:
(a) iTerm2 sends a *different* byte sequence on the wheel (e.g. translates wheel →
    arrow keys for alt-screen apps — "alternate scroll"); Laban sends SGR mouse. If
    so, the fix is Laban implementing the same translation, and Claude Code would
    scroll natively. This is the preferred real fix.
(b) iTerm2 and Laban send identical SGR mouse bytes, but iTerm2 advertises identity
    (`TERM_PROGRAM=iTerm.app`, `LC_TERMINAL=iTerm2`, versioned XTVERSION) that Claude
    Code gates wheel-scroll on; Laban advertises none. If so, the fix is advertising
    identity (below).
Diagnostic to decide (a) vs (b): run `/tmp/mousediag.py` (echoes the raw bytes a
terminal sends on a wheel tick under Claude Code's mode set, plus identity env) in
iTerm2 and in Laban and diff. This is the gating next step for M8.

Original hypothesis (user): Claude Code does not scroll because Laban advertises too
little to be recognized. Concrete advertisement gaps found:

- `TERM_PROGRAM` / `TERM_PROGRAM_VERSION` are **not set** (`Sources/LabanCore/Session.swift:312`
  sets only `TERM=xterm-256color`, `COLORTERM=truecolor`; C side
  `Sources/LabanTerminalCore/session_lifecycle.c:55-59`).
- XTVERSION reply is the bare string `laban` with no version
  (`Sources/LabanTerminalCore/terminal_effects.c:101`).
- DA1/DA2 are deliberately conservative VT220 (`terminal_effects.c:80-90`).

Assessment: a Laban *encoding* bug and a *missing VT capability* are both RULED OUT
— `less --mouse` scrolls on Laban's exact wheel bytes with Laban's exact
environment (see Surprises & Discoveries). So if Claude Code does not scroll, the
cause is Claude-Code-side: either it was mid-generation in the capture (the
confound), it gates wheel-scroll on terminal *identity* (modern CLIs key behavior on
`TERM_PROGRAM` / versioned XTVERSION — `less` does not, but Claude Code might), or it
simply does not bind wheel-to-scroll in its main transcript (relying on terminal
scrollback, which is exactly the M2b case). Identity is the only Laban-addressable
candidate left, and it cannot be confirmed from the existing capture.

Plan:
1. **Decisive test first.** Capture a clean *idle* Claude Code session (let it
   finish responding, then scroll) in Laban and in a reference terminal
   (Ghostty/iTerm2); diff `pty-output.bin` to see whether Claude Code scrolls on the
   wheel at all and whether identity changes it. This converts hypothesis to fact
   and tells us if M8 is even needed.
2. **Cheap, independently-correct change regardless:** export
   `TERM_PROGRAM=Laban` and `TERM_PROGRAM_VERSION=<build version>` to the child
   environment (`Session.swift:312` map and the C `session_lifecycle.c` env build),
   and return a versioned XTVERSION (e.g. `laban(<version>)`) from
   `laban_effect_xtversion`. Real terminals set these; doing so is correct hygiene
   and doubles as the falsifiable test — if it makes Claude Code scroll, the
   hypothesis is confirmed.
3. If identity is confirmed to be the gate and an honest `TERM_PROGRAM=Laban` is
   still unrecognized by Claude Code, the remaining fix is upstream (Claude Code
   adding Laban to its known-terminal table), not a Laban change — note that
   outcome here rather than spoofing another terminal's identity.

This is bounded as an investigation; promote to a P2 change only if step 1 shows it
helps. M2b remains the guaranteed Laban-side scrollback fix independent of M8.

### M7 [P2] OSC 9;4 progress affordance

Claude Code emits the ConEmu/Windows-Terminal progress protocol while working
(`ESC]9;4;3;BEL` indeterminate/busy, `ESC]9;4;0;BEL` reset — 3× in the capture).
Laban has no OSC 9 handling. Optionally surface a busy affordance on the tab
(and/or Dock) by scanning OSC 9;4 alongside the existing OSC 133 scan in
`Sources/LabanTerminalCore/osc133.c`. Pure enhancement.

## Concrete Steps

Work from the repository root
(`/Users/rrj/wrk/laban/.claude/worktrees/abstract-fluttering-dolphin`). Build with
`./scripts/build-app` (not `swift build`). Run the full gate with `./scripts/check`.

For each milestone: make the edit, add/adjust the test named in *Validation*, run
`./scripts/build-app`, run the relevant test, then `./scripts/check`. Commit with a
single-line reason message (why, not what). Update `Progress` here when a milestone
changes state.

This section will be expanded with exact diffs and observed transcripts as each
milestone is implemented (PLANS.md requires capturing evidence as work proceeds).

## Validation and Acceptance

Acceptance is phrased as observable behavior. "Replay the capture" means feeding
`~/Library/Logs/Laban/captures/appkit-2026-05-28T19-30-47Z/streams/pty-output.bin`
into a session through the headless/debug harness
(`docs/process/dev-process.md`) until `session.viewportState().mouseTracking == true`.

- **M1**: Replay the capture to enable mouse tracking; establish a committed
  selection (Shift+drag, or set `selectionAnchor`+`selectionFocus` and persist into
  `selectionsByTab`) and assert `currentTerminalSelection(sessionId:)` is non-nil;
  inject a plain (no-modifier) left mouseDown+mouseUp inside the grid; assert
  `currentTerminalSelection(sessionId:)` becomes nil, `selectionsByTab` has no entry
  for the active tab (switch tabs and back: still nil), and a `clearSelection` event
  was recorded. Negative control: a Shift-click preserves the selection.
- **M2**: With mouse tracking on, a plain wheel tick still forwards a `CSI <…M`
  mouse event to the PTY (unchanged); a **Shift+wheel** tick forwards nothing and
  instead changes `session.viewportState().viewportOffset` (scrollback moves). Unit
  test the gate decision and assert the byte/scroll outcome for both cases.
- **M3**: On the labpty tier, focus-in then focus-out delivers `CSI I` then `CSI O`
  to the daemon PTY (assert via the daemon's received-bytes / capture
  `pty-input.bin`). With mode 1004 off, nothing is sent. In-process tier behavior
  unchanged.
- **M4**: Replay the capture on the laband tier and assert no snapshot generation is
  published while the synchronized-output bit is set (no mid-BSU publish); the
  presented frame count drops toward the ESU count, not the per-drain count. The
  bounded watchdog still presents if an ESU never arrives.
- **M5**: `swift test` runs `testKittyShiftEnter`; it fails if the encoding
  regresses to a bare CR and passes on `CSI 13;2u`.
- **M6**: A headless debug request drives focus changes and asserts the delivered
  bytes; runs in CI without a window.
- **M7**: OSC `9;4;3` sets a visible busy state on the active tab; `9;4;0` clears it.

Every milestone must keep `./scripts/check` green and must not break any behavior
required by `docs/product/mvp.md`.

## Review Gate

A separate fresh-state agent must verify the following before this ExecPlan is
marked done (see PLANS.md "Review gate and review-fix loop"). Prefer mechanical
checks.

- [ ] M1: grep `TerminalBitmapView.swift` shows a `clearAllSelectionState()` call
  inside the `vs.mouseTracking` branch of `mouseDown` (between the
  `cancelSelectionDragForMouseTracking()` call and the `return`), and a
  `recordInput(... command: "clearSelection")` adjacent. Run the M1 test: expect pass;
  revert the new clear line, rerun: expect fail; restore.
- [ ] M2: the forward condition in `scrollWheel` includes
  `!event.modifierFlags.contains(.shift)` (or equivalent). Run the M2 test for both
  plain and Shift cases: expect pass.
- [ ] M2b: `ViewportState` exposes an `alternateScreen` field populated from
  `GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN`; the `scrollWheel` forward condition also
  requires `vs.alternateScreen`. Test: with `mouseTracking==true && alternateScreen==false`,
  a plain wheel tick changes `viewportOffset` and forwards no mouse bytes; with
  `alternateScreen==true`, a plain wheel tick forwards a `CSI <…M` and does not scroll.
  `docs/product/mvp.md:243-245` updated to describe alt-screen-gated forwarding.
- [ ] M3: `reportFocus` branches on `sessionCoordinator?.terminalClient` and, on the
  remote branch, sends focus bytes through the client (not `session.sendFocus`).
  Run the M3 headless test: expect `CSI I`/`CSI O` observed at the daemon PTY.
- [ ] M4: replaying the capture on the laband tier publishes no snapshot generation
  while the sync bit is set; `./scripts/check` green.
- [ ] M5: `swift test --filter testKittyShiftEnter` exits 0.
- [ ] Whole: `./scripts/check` exits 0; `docs/product/mvp.md` behaviors unaffected
  (spot-check mouse-tracking forward of a plain wheel/click still works).

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Surprises & Discoveries

- Observation: The original hypothesis that Claude Code stays in the normal buffer
  was challenged by an adversarial verifier that read the raw bytes and found one
  `?1049h` / zero `?1049l`. Re-reading the bytes before offset 5863 showed a
  full-screen TUI already painted in the normal buffer, and the stream ends
  mid-frame, so neither "permanent normal buffer" nor "permanent alt-screen" is
  provable from one capture. The user's chosen Shift+wheel design sidesteps the
  ambiguity entirely (no buffer-type detection needed).
  Evidence: `pty-output.bin` bytes 5463–6063; `timeline.ndjson` ~150 forwarded
  `mouseWheel` events (`ESC[<64;…M`/`ESC[<65;…M`) at frames 22682+.
- Observation: Synchronized output 2026 is used far more heavily than expected
  (885 BSU/ESU pairs), making the laband-tier tearing a real per-frame defect, not
  an edge case.
  Evidence: `pty-output.bin` contains 885× `CSI ?2026h` and 885× `CSI ?2026l`.
- Observation: The query/response reply path already works
  (`laban_session_drain_response`); the capture shows correct XTVERSION and DA1
  replies. This removed a feared P0 ("Claude Code hangs on an unanswered query").
  Evidence: `terminal-response.bin` = `ESC P >| laban ESC \ CSI ?62;22c`.
- Observation: Plain wheel ticks ARE forwarded to Claude Code with correct SGR
  encoding, but Claude Code did not scroll in response. It was mid-generation the
  whole capture and emitted only spinner repaints — so "the app ignores the wheel"
  is *not yet proven*; a clean idle-state capture is needed to settle it. Either
  way, Laban cannot force the app to scroll, so the robust fix is Laban-side
  scrollback (M2, and optionally M2b).
  Evidence: `timeline.ndjson` — 124 `mouseWheel` events (indices 554–4023) yield
  only 76/65/115-byte `?2026h…still thinking…?2026l` spinner frames, no scroll
  redraw. Forwarded bytes: `ESC[<64;45;12M` / `ESC[<65;45;12M`.
- Observation (M0 follow-up): on the **laband** authoritative-snapshot tier the local
  Session's libghostty terminal is not fed the daemon's raw bytes, so
  `session.viewportState().mouseTracking` stays false there (confirmed: a headless
  `mouseWheel` over laband took the local-scroll path, returning `actionResult(ok:true)`
  rather than the tracked-wheel result). Consequence: even with M0's delivery fix,
  the mouse-forward GATE never fires on laband, so mouse forwarding is still inert on
  that tier until mouse-mode state is plumbed from the daemon into the client viewport
  state. The default/user tier is **labpty** (byte-ring), where the local VT parses
  raw bytes so `mouseTracking` is correct and M0 fully fixes the symptom. The M0
  regression test injects mouse-mode via `feedOutput` to exercise the forward path on
  laband regardless. Tracking item: plumb daemon mouse-mode → client viewport state on
  the laband tier (separate from M0).
- Observation: **Laban's wheel byte sequence is proven correct against a known-good
  open-source TUI.** Feeding the EXACT bytes Laban emits (`ESC[<65;10;10M` wheel-down)
  into `less --mouse` (less 668) in a PTY, with Laban's environment
  (`TERM=xterm-256color`, no `TERM_PROGRAM`), scrolls `less` as expected (view moved
  from LINE-0001..0023 to LINE-0024..0031). This rules out a Laban encoding bug and a
  missing VT capability — `less` enables `?1006h`+`?1049h` and scrolls with nothing
  more than Laban already provides. Conclusion: Claude Code's non-scroll is
  Claude-Code-side (busy-thinking confound, identity gating per M8, or no transcript
  wheel-scroll), not a Laban defect. `less --mouse`, `fzf`, and `vim`/`nvim`
  (`:set mouse=a`) are deterministic open-source fixtures for regression-testing
  Laban mouse forwarding (M2/M2b).
  Evidence: PTY experiment run 2026-05-28 (`/tmp/lessscroll.txt`, 80×24).

## Idempotence and Recovery

Each milestone is an additive, independently revertable edit; re-running
`./scripts/build-app` and `./scripts/check` is safe and repeatable. M4 is the only
milestone touching a shared wire layout (the laband ring) — make it additive (new
flag/field), preserve the ADR 0007 protocol freeze, and keep older clients working;
if it destabilizes, it can be reverted without affecting M1–M3. The capture
artifact is read-only input; nothing here mutates it.

## Interfaces and Dependencies

- libghostty-vt owns VT parsing, mouse/key encoding, and capability replies
  (ADR 0001). Do not reimplement these; the app delivers app-originated bytes
  (focus, paste, mouse) to the correct PTY and consumes the "synchronized output
  active" signal.
- The remote tier boundary is `AppSessionCoordinator.terminalClient`; M3 (and the
  paste precedent `ecd12cc`) route app-originated bytes through it.
- The laband snapshot contract is `LabandSnapshotRingLayout` /  `LabandProtocol`;
  M4 extends it additively under the ADR 0007 freeze.
- Tests: `Tests/LabanTerminalCoreTests/…` for encoder/unit coverage; the
  headless debug harness (`docs/process/dev-process.md`) for M1–M4, M6 acceptance.
