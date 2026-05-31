# Honor Focus, Color Scheme, and Cursor Terminal State

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Terminal programs can ask the emulator for focus-change reports, query whether
the host is using a light or dark color scheme, and choose cursor shape and
blink behavior. libghostty-vt already parses these requests, but Laban only
plumbs part of that state through to the application. After this change, a
program that enables DEC private focus reporting mode `1004` receives `CSI I`
when the active terminal gains focus and `CSI O` when it loses focus; a program
that sends `CSI ? 996 n` gets a light/dark answer that matches `Theme.current`;
and cursor style sequences such as `CSI 5 SP q` render as bar, underline, block,
or hollow-block cursors with blink on/off phases.

## Progress

- [x] Inspected libghostty-vt local headers and implementation for focus
  encoding, color-scheme reports, and render-state cursor style/blink.
- [x] Identified Laban gaps: `focus_reporting` is hardcoded to 0 in snapshots,
  color-scheme callback returns false, and cursor snapshots expose only
  position/visibility.
- [x] Add C ABI and session state for focus reporting, color-scheme updates, and
  cursor style/blink snapshot fields.
- [x] Add Swift wrappers and AppModel/AppKit plumbing.
- [x] Add focused terminal-core and frame-producer tests.
- [x] Run targeted tests and `./scripts/check`.

## Outcomes & Retrospective

The implementation now honors focus reporting mode `1004`, answers the
color-scheme query from the current Laban theme, reports color-scheme changes
when mode `2031` is active, and renders DECSCUSR cursor shape plus blink state.
The behavior is covered by terminal-core tests for encoded terminal responses
and snapshot state, plus frame-producer tests for cursor shape and blink
suppression.

## Decision Log

- Decision: Translate cursor style into cursor rectangles in `FrameProducer`
  instead of changing the renderer command language.
  Rationale: Existing renderers already draw cursor rectangles efficiently.
  Bar, underline, block, and hollow block can be expressed with one or more
  cursor rectangles, keeping capture/replay and renderer backends smaller.
  Date/Author: 2026-05-06 / Codex.

- Decision: Store Laban's current light/dark scheme in `LabanSession` and update
  it from `AppModel.applyThemePalette`.
  Rationale: The C terminal-core callback cannot read Swift `Theme.current`
  directly. AppModel already synchronizes palette changes into sessions, so the
  same path should synchronize the color-scheme answer.
  Date/Author: 2026-05-06 / Codex.

## Context and Orientation

`Sources/LabanTerminalCore/session.c` owns the libghostty-vt terminal and
registers effect callbacks. `effect_color_scheme` currently returns false, so
the terminal ignores color-scheme DSR queries. `laban_session_snapshot` builds a
`LabanSnapshot` consumed by Swift render code, but it only includes cursor
position and visibility. `Sources/LabanCore/Session.swift` wraps the C ABI.
`Sources/LabanCore/AppModel.swift` already applies `Theme.current` to each
session by sending OSC palette sequences. `Sources/LabanApp/TerminalBitmapView.swift`
owns AppKit focus notifications and the display-link frame loop.

Focus reporting mode is DEC private mode `1004`. When a terminal program enables
it with `CSI ? 1004 h`, the emulator sends `CSI I` for focus gained and `CSI O`
for focus lost. Color-scheme query is `CSI ? 996 n`; libghostty-vt responds
with `CSI ? 997 ; 1 n` for dark and `CSI ? 997 ; 2 n` for light. Cursor style
is set by DECSCUSR sequences such as `CSI 2 SP q` for steady block,
`CSI 3 SP q` for blinking underline, and `CSI 5 SP q` for blinking bar.

## Plan of Work

Add C snapshot fields for `cursor_style` and `cursor_blinking`, plus Laban
cursor-style constants. Query `GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE`
and `GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING` while building snapshots.

Add C APIs to query focus-reporting mode and encode/send focus events. Use
`ghostty_focus_encode`; return zero bytes when mode `1004` is disabled or the
session has exited. Update snapshot `focus_reporting` from
`GHOSTTY_MODE_FOCUS_EVENT`.

Add a C color-scheme API that stores light/dark on each session. Make the
registered color-scheme effect return that value. When the stored value changes
and DEC private mode `2031` is active, emit the same color-scheme report that
Ghostty sends on host color-scheme changes.

In Swift, add wrappers on `Session`, call `setColorScheme` from
`AppModel.applyThemePalette`, observe AppKit window focus changes in
`TerminalBitmapView`, and send focus events for the active session when the
window or active tab changes. In the frame loop, keep a cursor-blink phase and
pass it into `FrameProducer`.

## Concrete Steps

Work from `/Users/dev/wrk/laban`. Prefix shell commands with `rtk`.

1. Edit `Sources/LabanTerminalCore/include/LabanTerminalCore.h` and
   `Sources/LabanTerminalCore/session.c`.
2. Edit `Sources/LabanCore/Session.swift`, `Sources/LabanCore/AppModel.swift`,
   `Sources/LabanCore/FrameProducer.swift`, and
   `Sources/LabanApp/TerminalBitmapView.swift`.
3. Add or update tests in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`
   and `Tests/LabanCoreTests/FrameProducerTests.swift`.
4. Run:

   ```sh
   rtk swift test --filter LabanSessionTests
   rtk swift test --filter FrameProducerTests
   rtk ./scripts/check
   ```

## Validation and Acceptance

Acceptance is:

- A fixture session that receives `CSI ? 1004 h` reports focus mode active, and
  `laban_session_encode_focus(..., focused: true/false)` returns `ESC [ I` and
  `ESC [ O`.
- A fixture session that receives `CSI ? 996 n` returns dark or light
  color-scheme bytes based on the stored session color scheme.
- A fixture session with mode `2031` enabled receives a color-scheme report when
  Laban changes the stored color scheme.
- A fixture snapshot after DECSCUSR sequences exposes the expected cursor style
  and blink flag.
- `FrameProducer` emits bar/underline/hollow/block cursor rectangles and hides
  blinking cursors when the blink phase is off.
- `./scripts/check` passes.

Validation performed on 2026-05-06 from `/Users/dev/wrk/laban`:

```sh
rtk swift test --filter LabanSessionTests
rtk swift test --filter FrameProducerTests
rtk git diff --check
rtk ./scripts/check
```

`./scripts/check` passed after running 342 XCTest tests with 2 skipped, plus
the smoke runtime and debug E2E checks.

## Idempotence and Recovery

The changes are additive. If a test fails halfway through, rerun the same
targeted command after fixing the code. No destructive setup is required.
