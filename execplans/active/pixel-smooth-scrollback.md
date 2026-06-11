# Pixel-smooth scrollback scrolling with a Settings toggle

This ExecPlan is a living document maintained in accordance with `PLANS.md` (repository root). Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Scrolling Laban's scrollback with a trackpad today moves content in whole-cell jumps. An on-glass benchmark (`Tools/ScrollSmoothnessBench/scrollbench`, which screen-captures the window while injecting synthetic pixel scroll events and measures per-frame content displacement) showed: Chrome moves the same content ~25 px every frame; Laban moves exactly one cell (38 physical px) or two (76 px) with 37% of frames showing zero motion — at a flawless 120 fps in both apps. The choppiness is a scroll-model choice, not a performance problem.

After this change, precise (trackpad/pixel) scrolling tracks the finger continuously with sub-cell rendering and settles onto a whole-row boundary when input stops. A "Scroll" popup in the existing Settings window (⌘,) selects between **Pixel-smooth** (new default) and **Line-quantized** (the previous behavior). Verification is objective: re-running scrollbench against Laban must show near-zero zero-motion frames and per-frame displacement variance comparable to Chrome.

## Progress

- [x] Worktree created from local `main`, `.rpg/graph.json` skip-worktree set.
- [x] ScrollSettings + Settings window popup row (`ScrollSettingsTests`: 5 green).
- [x] TerminalScrollInput fractional helpers + unit tests (29 green).
- [x] TerminalBitmapView precise-input fork + settle state machine.
- [x] Damage safety (`fractionalScrollOffset`) + device-pixel alignment of `contentYOffset`.
- [x] View-level tests (sticky-bottom regression, tracking, settle, quantized parity — `TerminalBitmapViewPreciseScrollTests`: 5 green; ScrollToBottom 4 + AttentionDamage 3 + SpanParity 14 + IdlePolicy 25 all green).
- [x] Full test suite (`swift test` exit 0) + `./scripts/build-app` green.
- [x] Committed and merged to `main` (0237d14) and installed; owner field-tested both modes.
- [x] Field-test fix: settle gated on gesture/momentum phases + on-glass re-base for resumed gestures (mid-gesture settle jank; 3 new view tests, 1 new helper test).
- [ ] On-glass scrollbench A/B captured (pixel-smooth vs line-quantized).

## Context and Orientation

Laban is an AppKit macOS terminal. The terminal grid lives in libghostty behind `Sources/LabanCore/Session.swift`; the view layer is `Sources/LabanApp/TerminalBitmapView.swift`. Scrollback position is split across two layers:

- The **viewport offset** (integer rows back from the live bottom) lives in libghostty; the view moves it with `Session.scrollViewport(deltaRows: Int)`.
- The view keeps a smooth-scroll model: `targetScrollRows: Double` (where the user wants to be, ≤ 0; 0 = live bottom), `displayedScrollRows: Double` (animated position), `appliedScrollRows: Int` (integer rows actually applied to libghostty), and `scrollVelocityRowsPerSec: Double`. A critically-damped controller (ω = 50 rad/s) in `advanceFrame` moves `displayedScrollRows` toward `targetScrollRows`. Every frame, the fractional remainder `subCellRows = displayedScrollRows - Double(appliedScrollRows)` becomes a pixel shift `contentYOffset` that `Sources/LabanCore/FrameProducer.swift` adds to every row/selection/cursor position. So fractional rendering already exists and is exercised by notched-wheel glide animations.

The bug-shaped choice: in `scrollWheel(with:)`, precise input (`event.hasPreciseScrollingDeltas`) is quantized to whole rows by `TerminalScrollInput.decide` (truncation + residual-pixel accumulator) and then `displayedScrollRows = Double(appliedScrollRows)` zeroes the fraction — exactly when input is pixel-accurate.

Terms: "precise input" = trackpad/continuous events where `scrollingDeltaY` is in pixels. "Settle" = animating the resting position onto a whole row so text sits on exact cell boundaries when not moving. "Damage" = the renderer's notion of which regions changed; "full damage" repaints everything.

Governing constraints:
- `Tests/LabanCoreTests/FrameProducerSpanParityTests.swift`: the macOS-26 Span glyph path must emit byte-identical FrameCommands to the legacy loop. This plan changes nothing in FrameProducer.
- `docs/adr/0018-event-driven-frame-production.md`: no periodic ticks; every state change that can alter pixels must explicitly wake the frame loop. The settle uses a `DispatchWorkItem` wake (precedent: `scheduleOutputSettleWake` in TerminalBitmapView.swift), NOT an idle-policy change.
- `Tests/LabanAppTests/TerminalBitmapViewScrollToBottomTests.swift`: streaming re-engage semantics at the live bottom must hold unchanged.

## Plan of Work

1. **Settings.** New `Sources/LabanCore/ScrollSettings.swift` modeled on `Sources/LabanCore/CursorSettings.swift`: `enum Mode: String, CaseIterable { case pixelSmooth, lineQuantized }`, UserDefaults key `LabanScrollMode`, static `mode` (default `.pixelSmooth`, read via `object(forKey:) as? String`), `setMode`, `didChangeNotification`. Add a "Scroll:" popup row to `Sources/LabanApp/SettingsWindowController.swift` like the cursor-style popup. The scroll path reads `ScrollSettings.mode` per wheel event (live-apply, no observer).

2. **Pure helpers** in `Sources/LabanApp/TerminalScrollInput.swift` (keep `decide` untouched for notched wheels/alt-scroll/quantized mode):
   - `preciseRowsDelta(scrollingDeltaY:cellHeightPx:) -> Double` = `-(deltaY/cellHeight)`, 0 on non-positive cell height.
   - `clampedFractionalTarget(_:maxScrollbackRows:) -> Double` clamps to `[-maxScrollback, 0]`.
   - `gestureDesiredAppliedRows(displayedRows:targetRows:) -> Int` = round-to-nearest, **held ≤ −1 while `targetRows < 0`**. This is the sticky-bottom fix: without it, `displayed ∈ (−0.5, 0)` rounds to 0, which routes through `snapScrollToActiveBottom` → `resetSmoothScrollState`, destroying the accumulation on every event so slow scrolls can never leave the bottom.
   - `settledTargetRows(displayedRows:) -> Double` = `min(0, rounded(.toNearestOrAwayFromZero))`.
   - `preciseSettleAction(...) -> SettleAction` (`none | settleNow | armQuiescence`): momentum ended/cancelled → settleNow; gesture/momentum active → none; otherwise fraction pending → armQuiescence.

3. **scrollWheel fork** in `Sources/LabanApp/TerminalBitmapView.swift` (~3829–3897). When `event.hasPreciseScrollingDeltas && ScrollSettings.mode == .pixelSmooth`: cancel pending settle; `scrollResidualPx = 0`; accumulate fractional `targetScrollRows` (clamped); assign `displayedScrollRows = targetScrollRows` and zero velocity **before** `applyScrollStep(toDesiredApplied: gestureDesiredAppliedRows(...), resetOnClamp: true)`; do **not** reassign `displayedScrollRows` afterwards (that reassignment is the quantization being removed). Keep side-effects: ScrollDiagnostics note, `recordInput` with integer applied delta, drag-extend selection when applied rows changed, `renderInvalidated = true`, fall through to `advanceFrame(wake: .scrollWheel)`. All other branches verbatim.

4. **Settle state machine.** `preciseScrollSettleWork: DispatchWorkItem?`, 0.15 s quiescence; new `FrameWakeSource.scrollSettle` case (distinct from output-settle `.settleWake` for render-journal attribution). `settlePreciseScrollToWholeRow()` sets `targetScrollRows = settledTargetRows(displayedScrollRows)` and calls `advanceFrame(wake: .scrollSettle)`; the existing controller animates the ≤ half-row error (~80 ms) and the existing idle policy un-parks/re-parks the display link. Per precise event: momentum ended/cancelled → settle now; else re-arm the timer if a fraction is pending. Harden: cancel + settle on window resign-key; cancel in deinit.

5. **Damage + sharpness.** `shouldForceFullDamage` gains `fractionalScrollOffset: Bool` (call site passes `subCellRows != 0`) so an output/blink-driven partial-damage frame can never composite against a held fraction. Round `scrollContentYOffset` to whole device pixels via `backingScaleFactor` so glyphs never land on subpixel positions.

6. **Tests.** `Tests/LabanAppTests/TestScrollWheelEvent.swift` gains `phase`/`momentumPhase` overrides (prerequisite — unbacked NSEvent accessors crash). Extend `Tests/LabanAppTests/TerminalScrollInputTests.swift` for every helper (including `gestureDesiredAppliedRows(-0.2, target: -0.2) == -1`). New `Tests/LabanAppTests/TerminalBitmapViewPreciseScrollTests.swift` (harness pattern from ScrollToBottomTests): sticky-bottom regression (10 × +0.25-cell events from bottom → `linesBack > 0`), fractional 1:1 tracking, settle to whole row, fractional return-to-bottom re-engages follow-output, line-quantized mode unchanged. New `Tests/LabanAppTests/ScrollSettingsTests.swift`.

## Concrete Steps

Working directory: repo root (worktree).

    swift test --filter TerminalScrollInputTests
    swift test --filter TerminalBitmapViewPreciseScrollTests
    swift test --filter TerminalBitmapViewScrollToBottomTests
    swift test --filter TerminalAttentionDamageTests
    swift test --filter FrameProducerSpanParityTests
    swift test
    ./scripts/build-app

On-glass A/B (after `./scripts/install-app` and a user relaunch of Laban; fill scrollback with `/bin/cat ~/scroll-test.txt`):

    Tools/ScrollSmoothnessBench/scrollbench --app Laban --direction up --duration 6 --velocity 1500
    defaults write <bundle-domain> LabanScrollMode lineQuantized   # then re-run

## Validation and Acceptance

- All listed test filters pass; full `swift test` passes; `./scripts/build-app` succeeds.
- Pixel-smooth mode benchmark: zero-motion frames collapse from ~234/625 toward ~0; displacement/slot stddev drops from ~12.6 px toward Chrome's ~7 px; max single-frame jump < one cell height; after injection stops, the render journal's ScrollSnapshot `contentYOffset` returns to 0 within ~250 ms (150 ms quiescence + ~80 ms settle).
- Line-quantized mode benchmark reproduces today's histogram (whole-cell displacements only).
- Manual trackpad: slow scroll up from the bottom leaves the bottom (sticky-bottom check); flick momentum settles on a whole row; finger held mid-gesture settles after ~150 ms; scrolling during streaming output shows no stale-pixel tearing.

## Decision Log

- Decision: Keep the libghostty viewport integer and render the fraction via the existing `contentYOffset`; no FrameProducer or C-bridge changes.
  Rationale: the fractional pipeline already exists and is parity-tested; touching FrameProducer risks the Span parity contract for zero benefit.
  Date/Author: 2026-06-11 / Claude + rrj.
- Decision: Settle via DispatchWorkItem wake instead of extending TerminalIdlePolicy.
  Rationale: a static fraction changes no pixels, so no frames are needed until the settle retargets; ADR 0018 wants explicit wakes, and `scheduleOutputSettleWake` is the in-repo precedent.
  Date/Author: 2026-06-11 / plan review.
- Decision: Default `pixelSmooth`, user-visible toggle in Settings (not a hidden default).
  Rationale: owner finds readability-while-scrolling subjective and wants easy A/B; hidden defaults are "too hidden".
  Date/Author: 2026-06-11 / rrj.
- Decision: The settle never runs while gesture or momentum phases are active, and a resuming gesture re-bases its accumulation on the on-glass position (`targetScrollRows = displayedScrollRows` before applying a delta when they diverge).
  Rationale: field test — the per-event quiescence timer fired under a slow/resting finger (event gaps > 150 ms with fingers still down), crept the content to a whole row mid-gesture, and the rounded retarget shifted the base so the next finger movement jumped. Whole-row alignment applies to lifted fingers only; phaseless streams still settle via the timer.
  Date/Author: 2026-06-11 / rrj field test + fix.

## Surprises & Discoveries

- Observation: Laban sustains a perfect 120 fps during scrolling; the choppiness is purely the whole-row scroll model.
  Evidence: scrollbench slot histogram `1x:625` (no missed vsyncs), displacement histogram `{38: 342, 0: 234, 76: 49}`.
- Observation: rounding small fractions to 0 routes through `snapScrollToActiveBottom` → `resetSmoothScrollState`, which would reset accumulation every event near the bottom (sticky bottom). Fixed via `gestureDesiredAppliedRows` holding applied ≤ −1 while target < 0.
- Observation: Serena MCP's project root stays pinned to the main checkout after entering a git worktree; symbolic edits silently landed in the main working tree. Recovered by exporting `git diff` from main (via `rtk proxy` — plain `git diff` output is rewritten by the rtk token filter and is not a valid patch), applying it in the worktree, verifying byte-identity, then `git checkout --` of the six files in main.
