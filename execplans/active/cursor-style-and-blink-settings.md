# User-Configurable Cursor Style and Blink as an Owned Wake Source

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current
as work proceeds.

This is Stage 1 of a two-stage idle-energy design. Stage 2 — fully parking
the display link when the focused terminal is idle — is its own ExecPlan
(`execplans/active/display-link-full-park.md`) and depends on the blink
ownership built here. This plan is self-contained.

## Purpose / Big Picture

A user can open Laban's Settings window (⌘,) and choose their cursor shape
(block, bar, or underline) and whether it blinks. Today neither is
configurable: the cursor is whatever the running program last requested, and
blink is sampled from wall-clock time inside the per-frame render tick.

The energy motivation: a profiling session found focused-idle Laban burns
roughly 400 ms CPU per minute, dominated by an 8 Hz display-link floor kept
alive partly so `TerminalBitmapView.advanceFrame()` can sample cursor blink.
This plan makes blink an *owned, optional wake source*: a dedicated ~2 Hz
timer that exists only when (blink enabled AND window visible AND cursor
visible), not a passenger on the display-link tick. With the defaults (solid
block, blink off), a fully idle focused terminal needs zero blink wakeups.
Stage 2 will rely on this timer to park the display link entirely.

Observable after this change: Settings gains a "Cursor:" popup
(Block / Bar / Underline) and a "Blink cursor" checkbox that apply
immediately and survive relaunch; `printf '\e[3 q'` switches the cursor to
underline (program override) and `printf '\e[0 q'` reverts it to the user's
configured style; with blink on, the cursor toggles every 500 ms and stays
solid while typing.

## Progress

- [x] (2026-06-10) Researched code paths and authored this plan.
- [x] (2026-06-10) Milestone 1: `CursorSettings` model in LabanCore + spec.md
  scope. `CursorSettingsTests` 13/13 green. Commit 02d1bad.
- [x] (2026-06-10) Milestone 2: DECSCUSR override tracking + style resolution
  + all four FrameProducer cursor paths render the resolved style.
  `CursorStyleResolverTests` 11/11, `CursorOverrideScannerTests` 12/12,
  `FrameProducerTests` 26/26 green. Commit 107a2c2.
- [x] (2026-06-10) Milestone 3: blink extracted from `advanceFrame` into a
  gated 500 ms timer (`CursorBlinkDriver`); phase resets on keyboard input;
  `cursorBlinkTimerActive` journaled. `CursorBlinkPolicyTests` 9/9,
  `CursorBlinkDriverTests` 12/12 green. Commit cc58305.
- [x] (2026-06-10) Milestone 4: Settings window cursor-style popup + blink
  checkbox; `CursorSettings.didChangeNotification` observer repaints and
  re-gates the timer. `CursorSettingsUITests` 12/12 green. Commit d730fc3.
- [x] (2026-06-10) Milestone 5: headless request passes user cursor settings;
  `/debug/state` exposes `cursorSettings` (style/blinkEnabled/styleOverridden/
  blinkOverridden); `state.schema.json` mirrored;
  `CursorSettingsHeadlessTests` E2E (bar -> DECSCUSR 2 block -> DECSCUSR 0
  revert) 2/2 green.
- [ ] Review Gate passed.

## Decision Log

Settled with the product owner before this plan was written:

- Decision: Defaults are solid block, blink OFF.
  Rationale: Matches today's look exactly, and a fully idle focused terminal
  then needs zero blink wakeups by default — the point of Stage 1.
  Date/Author: 2026-06-09 / product owner.
- Decision: The user setting is the *default* appearance; a program's
  DECSCUSR request overrides while active and reverts on reset.
  Rationale: Programs like vim signal mode through cursor shape; the user
  choice governs the quiescent state.
  Date/Author: 2026-06-09 / product owner.
- Decision: Blink must be a cleanly owned wake source — a dedicated ~2 Hz
  timer active only when (blink enabled AND window visible AND cursor
  visible) — never sampled on the 8 Hz display-link tick.
  Rationale: Stage 2 parks the link entirely and needs blink to keep
  working without it.
  Date/Author: 2026-06-09 / product owner.

Implementation decisions made while writing this plan:

- Decision: Track "program overrode the cursor" with a byte scanner in
  Laban's C session shim, not by inspecting libghostty state.
  Rationale: The vendored libghostty-vt collapses DECSCUSR 0 ("default") to
  steady block (`.external/libghostty-vt/src/terminal/stream_terminal.zig`
  maps `.default` to `.block`, blink false), so a snapshot reporting (block,
  steady) is indistinguishable from an explicit `DECSCUSR 2` or "never
  touched"; without a flag, a user preference of bar would wrongly survive
  nvim's normal-mode `CSI 2 q`. The shim already runs three byte scanners
  over child output (`laban_vt_write_capture` in
  `Sources/LabanTerminalCore/capture.c`); a fourth follows the pattern.
  Date/Author: 2026-06-10 / Claude.
- Decision: Track *two* flags — style and blink — and watch DEC private
  mode 12 (`CSI ? 12 h/l`) for the blink flag. Clear both on
  `DECSCUSR 0`/no param, RIS (`ESC c`), DECSTR (`CSI ! p`), and
  alternate-screen exit (`CSI ? 1049 l`, `? 1047 l`, `? 47 l`).
  Rationale: Mode 12 can enable blink without DECSCUSR and must keep
  working under a user blink-off setting. libghostty itself reverts the
  style on these reset paths; clearing on alt-screen exit covers a
  full-screen program that crashed without sending its reset.
  Date/Author: 2026-06-10 / Claude.
- Decision: Detached (laband) sessions get the user default style but NOT
  program overrides in this plan.
  Rationale: The snapshot ring
  (`Sources/LabanCore/LabandSnapshotRingLayout.swift`) carries no cursor
  style; remote viewers today always draw a filled block that blinks
  unconditionally. Rendering the user's style/blink remotely is a strict
  improvement; ring override bits are a follow-up ABI change. laband is
  post-MVP, so this is not an mvp.md regression.
  Date/Author: 2026-06-10 / Claude.
- Decision: When the window stops being visible, the blink timer parks and
  the phase resets to visible (solid).
  Rationale: Today's M-7 comment says the phase "advances internally", but
  the display link is parked when invisible, so the phase actually freezes
  arbitrarily. Deterministic "solid when unfocused" matches today's default
  look; Laban has no hollow/hidden unfocused cursor and this plan adds none.
  Date/Author: 2026-06-10 / Claude.

Implementation decisions made while executing this plan:

- Decision: The resign-key/settings-change sync path
  (`syncBlinkDriverFromWindowState`) passes `cursorVisible: true` when no
  fresh snapshot is at hand.
  Rationale: That sync runs outside a rendered frame, so the latest
  `surfaceFrame.cursorVisible` is unavailable; treating the cursor as
  visible is conservative (the window-visibility gate is false on resign,
  so the timer still stops), and the next rendered frame re-syncs with the
  real snapshot value.
  Date/Author: 2026-06-10 / Claude.
- Decision: "Driver flipped since last rendered frame" is a `pendingFlip`
  flag on `CursorBlinkDriver`, consumed once per `advanceFrame`
  (`consumePendingFlip()`); `noteInput()` and timer stop clear it.
  Rationale: The flip closure calls `advanceFrame()` directly for immediate
  paint, but the frame guard still needs a per-frame edge signal that
  survives the call ordering; a consumed flag gives exactly-once semantics
  without timestamps.
  Date/Author: 2026-06-10 / Claude.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. Run all commands from the repository root.

- [ ] `rtk swift test --filter CursorSettingsTests` exits 0, 0 failures.
- [ ] `rtk swift test --filter CursorStyleResolverTests` exits 0; the suite
  contains test names containing `ExplicitOverrideWins` and
  `UserDefaultAppliesWhenNoOverride`.
- [ ] `rtk swift test --filter CursorBlinkPolicyTests` exits 0; a test name
  contains `TimerOffWhenBlinkDisabled`.
- [ ] `rtk swift test --filter CursorOverrideScannerTests` exits 0; the
  suite covers DECSCUSR set, DECSCUSR 0 clear, RIS clear, and a sequence
  split across two writes.
- [ ] `rtk swift test --filter FrameProducerTests` exits 0 (including the
  pre-existing `testFrameProducerShapesAndBlinksCursorStyles`).
- [ ] `rtk swift test --filter CrossBackendBitmapTests` exits 0 (pins that
  the default configuration changes no rendered pixels).
- [ ] `rtk swift test` (full suite) exits 0.
- [ ] `grep -n "advanceCursorBlinkState" Sources/LabanApp/TerminalBitmapView.swift`
  returns zero hits.
- [ ] `grep -n "cursorBlinkInterval" Sources/LabanApp/TerminalBitmapView.swift`
  returns zero hits (the 0.5 s constant lives in
  `Sources/LabanCore/CursorBlinkPolicy.swift`).
- [ ] `grep -n "^## 23" docs/product/spec.md` returns one hit whose heading
  mentions cursor.
- [ ] `grep -n "cursorSettings" schemas/debug/state.schema.json` returns at
  least one hit.
- [ ] `./scripts/build-app` exits 0 and produces `.build/laban/Laban.app`.
- [ ] Mutation check: in `Sources/LabanCore/CursorSettings.swift`, flip the
  blink default from `false` to `true`; run
  `rtk swift test --filter CursorSettingsTests`; expect at least one
  failure; revert.
- [ ] Headless check: `swift build --product laban-agent`, run
  `.build/debug/laban-agent --headless --debug-server=127.0.0.1:0` in the
  background, `curl` the printed `/debug/state` URL; the JSON contains a
  `cursorSettings` object with `style` and `blinkEnabled` keys. Kill the
  agent afterwards.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Context and Orientation

Laban is a macOS terminal app (Swift + a C shim around the vendored
`libghostty-vt` terminal-emulation library in `.external/libghostty-vt/`).
Terms used below:

- **DECSCUSR** ("DEC Set Cursor Style") is the escape sequence
  `ESC [ Ps SP q` (CSI, a digit, a literal space, then `q`) a program
  writes to request a cursor shape: 0 = default, 1/2 = blinking/steady
  block, 3/4 = blinking/steady underline, 5/6 = blinking/steady bar. vim
  and nvim use it to show editing mode.
- **Display link**: the per-window frame timer (`CADisplayLink`, macOS 14+)
  driving `TerminalBitmapView.advanceFrame()`; policy in
  `Sources/LabanCore/TerminalIdlePolicy.swift` runs it at 8 Hz idle /
  120 Hz active and parks it when the window is not visible to the user.
- **Snapshot**: the C struct `LabanSnapshot`
  (`Sources/LabanTerminalCore/include/LabanTerminalCore.h`) extracted from
  libghostty per frame; it already carries `cursor_style`
  (`LABAN_CURSOR_STYLE_BLOCK`=0, `_BAR`=1, `_UNDERLINE`=2,
  `_BLOCK_HOLLOW`=3) and `cursor_blinking`, populated in
  `Sources/LabanTerminalCore/snapshot.c`.

How the cursor works today (verified in source):

- `Sources/LabanCore/FrameProducer.swift` emits cursor draws in four
  places: `commands(from:)` (~line 284), `overlayCommands(from:)`
  (~line 390), and `fillTerminalCellPayload(...)` (~line 857) read
  `snapshot.cursor_style` and gate on
  `snapshot.cursor_blinking == 0 || cursorBlinkVisible`; the remote
  (laband) overload `commands(from: LabandSnapshotResponse, ...)`
  (~line 1416) draws a plain full-cell rect with no style at all.
- `FrameProducer.cursorRects(style:cellRect:)` (~line 1482) converts a
  style into rects (full cell, ~16%-thick bar or underline, four edge rects
  for hollow). Both backends — `MetalRenderer.buildCursorInstanceList`
  (`Sources/LabanRenderer/MetalRenderer.swift` ~line 2702) and
  `Sources/LabanRenderer/SoftwareRenderer.swift` (~line 54) — consume the
  resulting `.cursor(CGRect, color:)` commands as opaque rects, so **no
  renderer changes are needed** for the three styles.
- Blink lives in `Sources/LabanApp/TerminalBitmapView.swift`:
  `cursorBlinkInterval` (0.5 s) / `cursorBlinkVisible` /
  `lastCursorBlinkToggleAt` (~lines 293–295),
  `advanceCursorBlinkState(now:)` (~line 1120), and `advanceFrame`
  computing `cursorBlinkFrame = advanceCursorBlinkState() &&
  windowVisibleToUser` (~line 1201, the "(M-7)" comment). Lines ~1523–1527
  reset the phase to visible when the snapshot stops blinking.
- Defaults today: libghostty's mode 12 (blink) defaults false and style
  defaults to block, so an untouched terminal shows a steady filled block.
  An unfocused window keeps drawing the cursor filled; Laban never hides or
  hollows it.

Program output reaches the terminal through `laban_vt_write_capture` in
`Sources/LabanTerminalCore/capture.c`: it runs three byte scanners
(`laban_scan_tab_status`, `laban_scan_osc133`, `laban_scan_osc_host`)
behind a `memchr(bytes, 0x1B, len)` fast path, then calls
`ghostty_terminal_vt_write`. Scanner state lives in
`Sources/LabanTerminalCore/session_internal.h`. DECSCUSR detection goes
here. This path serves the Local (in-process) and Background (labpty)
backends; Detached (laband) viewers read ring snapshots instead (see
Decision Log).

Settings precedents to copy: persistence —
`Sources/LabanCore/Persistence/RestoreOnLaunchSettings.swift` (a tiny enum
over `UserDefaults.standard` using `object(forKey:) as? Bool ?? default` so
an absent key yields the intended default; the font-size keys in
`Sources/LabanRenderer/FontAtlas.swift` follow the same shape). UI —
`Sources/LabanApp/SettingsWindowController.swift` builds an `NSGridView` of
labeled popup/checkbox rows whose actions apply immediately, refreshing
from live values on `present()`.

Headless and debug infrastructure (hard rule: feature parity):
`Sources/LabanDebug/HeadlessDebugRuntime.swift` renders through the same
`TerminalSurfaceController.makeFrame` with a `TerminalSurfaceFrameRequest`
(currently hardcoding `cursorBlinkVisible: true`, ~line 689). The debug
HTTP server serves `/debug/state` (payload in
`Sources/LabanDebug/DebugStateEndpoints.swift`, schema
`schemas/debug/state.schema.json`) and `/debug/render`, whose frame-command
dump includes rects with source `"cursor"` — how tests assert cursor
geometry without a screen. The headless binary is `laban-agent`
(`Sources/LabanAgent/main.swift`).

Regression contract: `docs/product/mvp.md` requires cursor visibility and
position behaviors (~line 283); the defaults here reproduce today's look,
and `Tests/LabanCoreTests/CrossBackendBitmapTests.swift` pins it. New scope
must flow through `docs/product/spec.md` (numbered sections ending at
"## 22. Find requirements") — Milestone 1 adds the cursor section.

## Plan of Work

### Milestone 1 — Settings model and spec.md scope

Create `Sources/LabanCore/CursorSettings.swift` (LabanCore, not LabanApp,
so `LabanDebug` can reach it without AppKit — hard rule in `AGENTS.md`):
`public enum CursorSettings` with nested
`public enum Style: String, CaseIterable { case block, bar, underline }`, a
`labanStyleValue: Int32` mapping to `LABAN_CURSOR_STYLE_*`, UserDefaults
keys `LabanCursorStyle` (string) and `LabanCursorBlink` (bool) read via
`object(forKey:)` with defaults `.block` / `false` (copy the
`RestoreOnLaunchSettings` missing-key pattern), and setters posting a
`didChangeNotification`.

Add `## 23. Cursor appearance settings` to `docs/product/spec.md` after
section 22: user-selectable style and blink toggle in Settings, defaults
block/no-blink, DECSCUSR override precedence, blink as a gated dedicated
timer, headless observability via `/debug/state`. Use the terse
requirements voice of sections 15–22.

Tests: `Tests/LabanCoreTests/CursorSettingsTests.swift` — defaults on a
clean domain, set/read round-trip, style↔`Int32` mapping. Remove the keys
in `setUp` so tests are hermetic.

### Milestone 2 — DECSCUSR override tracking and style resolution

C shim (pattern: `osc133.c`): add a `LabanCursorOverrideScanner` struct
(small CSI state machine: ESC → `[` → optional `?` → digits → final byte)
and session fields `cursor_style_overridden` / `cursor_blink_overridden` to
`session_internal.h`, zeroed in session init (`session_lifecycle.c`). New
`Sources/LabanTerminalCore/decscusr.c` implements
`laban_scan_cursor_override(LabanSession *s, const uint8_t *bytes,
size_t len)`: `CSI Ps SP q` with Ps 1–6 sets both flags; Ps 0 or absent
clears both; `CSI ? 12 h/l` sets the blink flag only; RIS, DECSTR, and
alt-screen exit clear both (sequences in the Decision Log). State must
survive chunk boundaries, like the existing scanners. Call it from
`laban_vt_write_capture` next to `laban_scan_osc133` and add its ground
state to the `scan_needed` short-circuit. Extend `LabanSnapshot` with
`int cursor_style_explicit;` and `int cursor_blink_explicit;`, populated in
`snapshot.c` (the struct is in-memory only — not an ABI break).

Swift resolution: new `Sources/LabanCore/CursorStyleResolver.swift` — a
pure `resolve(userStyle:userBlinkEnabled:snapshotStyle:snapshotBlinking:
styleExplicit:blinkExplicit:) -> (style: Int32, blinking: Bool)` returning
the snapshot value when the matching explicit flag is set, else the user
value. `TerminalSurfaceFrameRequest` gains
`userCursorStyle: CursorSettings.Style = .block` and
`userCursorBlinkEnabled: Bool = false`; `makeFrame` resolves once per
frame; `TerminalSurfaceFrame.cursorBlinking` becomes the *resolved* blink
(currently `snapshot.cursor_blinking != 0`, ~line 612) and the frame gains
`cursorVisible: Bool` for Milestone 3's timer gate. The three
`LabanSnapshot` FrameProducer paths gain
`resolvedCursor: (style: Int32, blinking: Bool)? = nil` (`nil` preserves
snapshot-driven behavior so existing call sites compile unchanged; the
blink gate becomes `!resolved.blinking || cursorBlinkVisible`). The remote
overload (~line 1416) uses `cursorRects(style: userStyle, ...)` instead of
the bare full-cell rect.

Tests: `Tests/LabanCoreTests/CursorStyleResolverTests.swift` (precedence
matrix; include names `testExplicitOverrideWins...` and
`testUserDefaultAppliesWhenNoOverride...` for the gate);
`Tests/LabanTerminalCoreTests/CursorOverrideScannerTests.swift` driving a
`Session.fixture` with real escape bytes (copy the idiom from
`FrameProducerTests.testFrameProducerShapesAndBlinksCursorStyles`, which
writes `"\u{1B}[5 q"`), covering set, clear, RIS, and a split-across-writes
sequence; extend `FrameProducerTests` with a user-style/no-override case
per style and a remote styled-cursor case.

### Milestone 3 — Blink ownership extraction

New `Sources/LabanCore/CursorBlinkPolicy.swift` (AppKit-free, mirroring
`TerminalIdlePolicy`): `static let blinkInterval: TimeInterval = 0.5` and
`static func timerShouldRun(blinkActive:windowVisibleToUser:cursorVisible:)
-> Bool` (AND of all three). New
`Sources/LabanApp/CursorBlinkDriver.swift`: owns a main-queue
`DispatchSourceTimer` at `blinkInterval`; exposes `phaseVisible: Bool`,
`onPhaseFlip: (() -> Void)?`, `noteInput()` (phase → visible, restart the
interval so the cursor stays solid while typing), and
`sync(blinkActive:windowVisibleToUser:cursorVisible:)` which starts/stops
the timer per `CursorBlinkPolicy` and resets the phase to visible whenever
it stops.

In `TerminalBitmapView`: delete `advanceCursorBlinkState`,
`cursorBlinkInterval`, `lastCursorBlinkToggleAt`, and the ~1523–1527 phase
reset; `cursorBlinkVisible` reads `driver.phaseVisible`;
`cursorBlinkFrame` becomes "driver flipped since last rendered frame" (the
flip closure also calls `advanceFrame()` directly so a flip paints
immediately instead of waiting up to 125 ms for an 8 Hz tick). After each
frame call `driver.sync(blinkActive: surfaceFrame.cursorBlinking,
windowVisibleToUser:, cursorVisible: surfaceFrame.cursorVisible)`; also
call it from the window key/occlusion observers beside
`updateDisplayLinkRunState()`. Hook `driver.noteInput()` at the top of
`keyDown(with:)` (~line 2607) and in `insertText(_:replacementRange:)` so
IME commits count as typing. M-7's outcome (no blink-driven frames when
invisible) holds because the timer never runs then. Add
`cursorBlinkTimerActive` to the render-journal policy snapshot in
`Sources/LabanApp/RenderJournal.swift` for observability
(`docs/process/observability.md`).

Tests: `Tests/LabanCoreTests/CursorBlinkPolicyTests.swift` (truth table;
include `testTimerOffWhenBlinkDisabled`);
`Tests/LabanAppTests/CursorBlinkDriverTests.swift` (flip toggles phase and
fires the callback; `noteInput` forces visible; `sync` with any gate false
stops the timer and resets phase; the timer is never scheduled when
`blinkActive` is false).

### Milestone 4 — Settings UI and persistence

In `SettingsWindowController.swift`: add a `cursorStylePopUp`
(Block / Bar / Underline) and a "Blink cursor" checkbox as two grid rows
after the Font row; actions write `CursorSettings`; `refresh()` re-reads
them. In `TerminalBitmapView`, observe
`CursorSettings.didChangeNotification` (pattern: the existing
`themeChangeObserver`): set `renderInvalidated = true` and re-run
`driver.sync(...)` so a settings flip repaints and re-gates the timer
immediately. The view reads `CursorSettings.style` / `.blinkEnabled` when
building each `TerminalSurfaceFrameRequest`.

Tests: `Tests/LabanAppTests/CursorSettingsUITests.swift` following
`RendererModeSettingsTests.swift` — selecting a row writes the defaults
key; the notification fires; `refresh()` reflects externally changed
defaults.

### Milestone 5 — Headless parity and verification artifacts

`HeadlessDebugRuntime.renderFrameUnlocked` passes
`userCursorStyle: CursorSettings.style` and
`userCursorBlinkEnabled: CursorSettings.blinkEnabled` in its request.
Headless reads the same `UserDefaults.standard`; E2E runs inject via
argument-domain defaults (`laban-agent --headless ... -LabanCursorStyle bar
-LabanCursorBlink YES`), which `UserDefaults.standard` honors without a new
endpoint. Extend `StateResponse` (`DebugStateEndpoints.swift` /
`DebugModels.swift`) with a `cursorSettings` object (`style`,
`blinkEnabled`, plus per-active-session `styleOverridden` /
`blinkOverridden` from the latest snapshot) and mirror it in
`schemas/debug/state.schema.json` (schemas rule in `AGENTS.md`).

End-to-end test in `Tests/LabanDebugTests`: start a headless runtime with
style bar; assert via the frame-command dump that the cursor rect is
bar-shaped (width < cell width); write `\u{1B}[2 q` into the session and
assert a full-cell rect (override); write `\u{1B}[0 q` and assert it
reverts to the bar.

Commit after each milestone (atomic, single-line reason-statement messages,
e.g. `Blink must own its wakeups so the display link can park`).

## Concrete Steps

Run everything from the repository root (`/Users/rrj/wrk/laban`).

1. Implement each milestone, then run its focused tests; each should end
   `Test Suite ... passed` with 0 failures:

       rtk swift test --filter CursorSettingsTests
       rtk swift test --filter CursorStyleResolverTests
       rtk swift test --filter CursorOverrideScannerTests
       rtk swift test --filter CursorBlinkPolicyTests
       rtk swift test --filter CursorBlinkDriverTests
       rtk swift test --filter FrameProducerTests
       rtk swift test --filter CrossBackendBitmapTests

2. Full suite and bundle build (never plain `swift build` for the app, and
   never `open` the bundle — install and let the user relaunch):

       rtk swift test
       ./scripts/build-app

3. Headless end-to-end probe:

       swift build --product laban-agent
       .build/debug/laban-agent --headless --debug-server=127.0.0.1:0 \
         -LabanCursorStyle bar &
       curl -s http://127.0.0.1:<printed-port>/debug/state | rtk jq .cursorSettings
       kill %1

   Expected: `{"style":"bar","blinkEnabled":false, ...}`.

4. Optional idle-energy spot check (blink off vs on, 30 s window each):
   `scripts/bench-idle-cpu 30`. Expected: blink-off idle CPU% unchanged
   from baseline; blink-on adds only ~2 wakeups/second of cost.

## Validation and Acceptance

Acceptance is behavior, verified in this order:

1. **Defaults preserve today's look.** With no
   `LabanCursorStyle`/`LabanCursorBlink` defaults set, a fresh build shows
   a steady filled block cursor exactly as before;
   `rtk swift test --filter CrossBackendBitmapTests` passes unmodified.
2. **Style picks apply and persist.** In Settings (⌘,), set Cursor to Bar:
   the shell cursor becomes a thin vertical bar without restart. After
   quit and relaunch (the user relaunches the installed app — agents must
   not `open` the bundle): still a bar.
3. **DECSCUSR override and revert.** With user style Bar,
   `printf '\e[3 q'` makes the cursor an underline; `printf '\e[0 q'`
   reverts to the bar (not block). Opening and quitting nvim ends back at
   the user's bar. The same is assertable headlessly via `/debug/render`
   cursor-rect geometry (Milestone 5 test).
4. **Blink behavior.** With "Blink cursor" on, the cursor toggles roughly
   every 500 ms; while typing it stays solid; after ~1 s pause blinking
   resumes; turning the checkbox off makes it solid again.
5. **Blink is an owned, gated wake source.** `CursorBlinkPolicyTests` and
   `CursorBlinkDriverTests` pass, proving the timer is never scheduled when
   blink is disabled, the window is invisible, or the cursor is hidden. The
   render journal (enable `LabanRenderJournalEnabled`, dump via Debug menu)
   shows `cursorBlinkTimerActive: false` and no `cursorBlinkFrame: true`
   entries while idle with blink off.
6. **Unfocused windows keep today's behavior.** Focusing another app
   leaves the Laban cursor drawn, filled, and solid — no hollow or hidden
   cursor; with blink on, blinking stops while unfocused and resumes
   solid-first on refocus.
7. **Headless parity.** The step-3 transcript returns the configured
   settings from `/debug/state`, and the Milestone 5 LabanDebugTests case
   passes — settings affect headless rendering identically to the window
   path (hard rule: `HeadlessDebugRuntime` parity with
   `MainWindowController.makeAndShow`).
8. **Full suite.** `rtk swift test` passes with 0 failures.

## Idempotence and Recovery

All changes are additive files plus local edits; milestones land as
separate commits so a failed milestone reverts alone. The `resolvedCursor`
parameter is optional-with-nil-default, so partial Milestone 2 work never
changes existing rendering. Re-running any test or build command is safe.
Do not reset the working tree (other agents' edits may be present). If a
defaults experiment leaves stray keys, clean with
`defaults delete <bundle-id> LabanCursorStyle` (and `LabanCursorBlink`).
Build-stamp caveat from `AGENTS.md`: before debugging a fix that "doesn't
work", confirm the running bundle's `LABANBuildCommit` matches HEAD.

## Interfaces and Dependencies

Must exist at completion (signatures are normative and given in full in the
Plan of Work):

- `Sources/LabanCore/CursorSettings.swift`,
  `Sources/LabanCore/CursorStyleResolver.swift`, and
  `Sources/LabanCore/CursorBlinkPolicy.swift` — pure LabanCore types, no
  AppKit (the resolver and policy take no UserDefaults either).
- `Sources/LabanApp/CursorBlinkDriver.swift` — the only blink-timer owner.
- `Sources/LabanTerminalCore/decscusr.c` plus the `LabanSnapshot` fields
  `cursor_style_explicit` / `cursor_blink_explicit` in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`.
- `TerminalSurfaceFrameRequest.userCursorStyle` /
  `.userCursorBlinkEnabled`; `TerminalSurfaceFrame.cursorBlinking`
  (resolved) and new `.cursorVisible`.
- `schemas/debug/state.schema.json`: `cursorSettings` object.
- No new external dependencies; no changes inside
  `.external/libghostty-vt/`.
