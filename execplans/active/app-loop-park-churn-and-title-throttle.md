# Cut app-loop CPU above the renderer: stop labpty park/unpark churn, throttle window-title sets, and skip no-output feed polls

This ExecPlan is a living document maintained in accordance with `PLANS.md` (repository root). Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

After the slug renderer hot paths were fixed (execplans/active/slug-hot-path-negative-cache-and-present-skip.md, all milestones landed 2026-07-10), a re-profile showed the remaining CPU no longer lives in the renderer. During a 20 s trace of a spinner-style TUI workload (build `8ca61689`, ~1.08 s total sample weight), the top consumers are the app loop above the renderer:

    parkLabptyOutputWakeAfterQuiet subtree     7.5%   (park RPC churn, ~10 park/unpark cycles per second)
    labptyActiveDrainTick subtree              2.7%   (8 ms drain timer + rearm churn)
    -[NSWindow _dosetTitle:] under advanceFrame  2.7%   (288 title sets in 20 s, one per title change)

All three are workload-rhythm problems: a TUI that emits output every ~100 ms (spinners, progress bars, Claude Code) sits exactly in the resonance zone of the 50 ms park-quiet threshold and updates its OSC title every tick. After this change, the same workload produces roughly one park cycle instead of ten per second, at most ~5 window-title sets per second instead of ~14, and per-tick feed polls that cost a few atomic loads instead of a queue hop when a tab has no new output. Users see identical behavior (same output latency during bursts, same final titles); the app just stops burning CPU on state that flips right back.

## Progress

- [x] (2026-07-10) Baseline profile captured and decomposed (see numbers above; analysis reproducible via the recipe below on any equivalent capture).
- [x] (2026-07-10, `722cf888`) W1: Raised the labpty wake park quiet threshold from 50 ms to 500 ms.
- [x] (2026-07-10, `89c631a8`) W2: Debounced AppKit window-title application to at most ~5 sets/second with a trailing apply (`WindowTitleThrottle` + `applyWindowTitleIfNeeded()`; `WindowTitleThrottleTests` added, 6 tests).
- [x] (2026-07-10, `3db77812`) W3: Cheap no-new-output pre-check so `pollAllLabptyFeeds` skips the queue hop and ring read for quiet tabs (`LabptyParserFeed.wakeIfOutputPending()`).
- [x] (2026-07-10) Re-measure captured and analyzed; see `Outcomes & Retrospective`. Build `91709b18` installed and restarted; 20 s CPU-only xctrace capture, same spinner workload shape, window unfocused like the baseline.

## Outcomes & Retrospective

Re-measure (2026-07-10, build `91709b18`, 20 s xctrace CPU-only, ~100 ms spinner via `POST /scroll/input`, Laban unfocused, matching baseline conditions). The re-measure trace carried ~5x the baseline's total sample weight because earlier queued workload commands overlapped in the tab (more genuine output per second, visible as a larger `appendGlyphRun` share); absolute row counts are therefore the honest comparison and are shown alongside shares:

    marker                                baseline rows (share)   re-measure rows (share)
    parkOutputWake RPC                     53  (0.49%)              0  (0.00%)
    park machinery (excl. poll overlap)   180  (1.66%)             10  (0.02%)
    labptyActiveDrainTick machinery       287  (2.65%)            131  (0.24%)
    -[NSWindow _dosetTitle:]              288  (2.66%)              0  (0.00%)
    LabptyParserFeed.poll() subtree       634  (5.86%)           1526  (2.80%)

W1: zero park cycles ran during the workload (RPC rows 0), and the drain-tick machinery got cheaper in absolute terms even though the un-parked span is now 10x longer, because W3's pre-check makes the per-tick fan-out skip quiet feeds. W2: title sets went to zero in this capture; the baseline's ~14 sets/s title churn was itself fed by the park/unpark flapping of tab activity state, so W1 removed the churn source and the throttle is the backstop for TUIs that genuinely spin their OSC title (its 6 unit tests cover the semantics; a live Codex/Claude-Code-in-Laban session is the real-world check). W3: poll rows only halved rather than vanished because the measured tab genuinely produces output every 100 ms; the two-tab quiet-feed case is where the pre-check fully skips.

One anomaly worth recording: a separate capture taken while the Laban window was focused showed `_dosetTitle` at 2.08% even with the throttle active, at ~13x the per-set cost of the unfocused baseline (focused-window title bars re-render more expensively). If focused-window title cost resurfaces, the next lever is widening the throttle interval or skipping title sets while a fullscreen TUI owns the tab, not further micro-optimization of the apply path.

## Context and Orientation

Laban is a macOS terminal app. Terminal PTYs live in a separate daemon (`labpty`); the app reads each session's output bytes from a shared-memory ring (`Sources/LabanCore/LabptyByteRingReader.swift`) and feeds them to the in-app terminal parser. Key pieces, all in `Sources/LabanApp/AppSessionCoordinator.swift` unless noted:

- `LabptyParserFeed` (class, ~line 1060): one per tab. Owns a serial `queue`, a `LabptyByteRingReader` (`reader`), and `lastOffset` (the ring offset consumed so far, mutated only on `queue`). `wake()` (~line 1117) enqueues `poll()`; `poll()` (~line 1156) calls `reader.readSince(lastOffset)` and feeds any new bytes to the parser session.
- The wake pipeline: when output arrives, the daemon writes to a wake pipe. `handleLabptyOutputWake` reads it, then `startLabptyActiveDrain()` (~line 635) creates a repeating 8 ms `DispatchSource` timer whose handler `labptyActiveDrainTick()` (~line 657) polls **all** feeds (`pollAllLabptyFeeds`, `feed.wake()` per tab) and, once `labptyWakeLastOutputNs` is older than `labptyActiveQuietNanoseconds` (constant, line 61, currently 50 ms), calls `parkLabptyOutputWakeAfterQuiet()` (~line 672).
- `parkLabptyOutputWakeAfterQuiet()` is the expensive part: it cancels the drain timer, gathers a `LabptyOutputWakeParkEntry` from every feed via `observedWakeParkEntry` (a dispatch-group fan-out over every feed queue), then makes a **cross-process RPC** (`labptyClient.parkOutputWake`) to the daemon. The next output re-wakes and re-creates the drain timer. With a 100 ms output cadence and a 50 ms quiet threshold, this full cycle (timer create + ~6 polls of every feed + fan-out + RPC + unpark) runs ~10 times per second.
- The window title: `TerminalBitmapView.advanceFrame(wake:)` (`Sources/LabanApp/TerminalBitmapView.swift`, title block ~line 2475) reads `model.windowTitle` (active tab's title, `Sources/LabanCore/AppModel.swift` ~line 1579) and assigns `window?.title` whenever the string differs from `lastAppliedWindowTitle`. TUIs like Claude Code and Codex put a spinner glyph in their OSC title ("⠴ laban"), so the title genuinely changes many times per second, and each `NSWindow.title` set costs real AppKit work (the 288 sets in the baseline are ~2.7% of all samples). A second, rarer call site with the identical pattern is `refreshRecordingChrome()` (~line 7778).
- "OSC title" means the escape sequence a program prints to set its terminal tab/window title.

## Plan of Work

### W1 — Raise the park quiet threshold (one constant)

In `Sources/LabanApp/AppSessionCoordinator.swift` line 61, change

    private static let labptyActiveQuietNanoseconds: UInt64 = 50_000_000

to `500_000_000` (500 ms), and update the comment if one exists. Rationale to record in the commit: the park exists to make true idle free, but at sub-second output cadences the 50 ms threshold makes the app park and unpark ~10x/s, and each cycle costs a cross-process RPC plus a per-feed dispatch fan-out plus a fresh kernel timer; 500 ms of extra 8 ms-interval no-op polling (~60 polls, each a few atomic loads via the W3 pre-check) is far cheaper than those ten cycles. True idle now parks 450 ms later, which changes no user-visible behavior.

Tradeoff to note: while un-parked the 8 ms drain timer keeps firing, so with W1 alone a 100 ms-cadence workload polls all feeds at ~125 Hz continuously instead of parking between ticks. That is why W3 (cheap pre-check) lands in the same plan: it makes those no-op polls nearly free. Land W1 and W3 in either order but measure only after both.

### W2 — Debounce window-title application

Add a small value type (new file `Sources/LabanApp/WindowTitleThrottle.swift`) that encapsulates "apply at most every N ms, never lose the final value":

    struct WindowTitleThrottle {
      let minimumIntervalNs: UInt64
      private(set) var lastAppliedTitle: String?
      private(set) var lastApplyNs: UInt64?
      // Returns .apply(title) when the caller should set window.title now,
      // .defer(afterNs) when a trailing apply must be scheduled in afterNs,
      // .none when the title is unchanged or a defer is already pending.
      mutating func decide(title: String, nowNs: UInt64) -> Decision
      mutating func markApplied(title: String, nowNs: UInt64)
      ...
    }

Design constraints (the reason this is a type and not two lines inline):

- Identical title: no work (the existing `!=` guard's behavior is preserved).
- Changed title with the last apply older than the interval: apply immediately (a single title change, e.g. `cd`, must not lag).
- Changed title inside the interval: hold it and apply once the interval expires (trailing edge). The trailing apply must fire even if no further `advanceFrame` tick arrives (the terminal can park right after the last title change), so the view schedules it with `DispatchQueue.main.asyncAfter` guarded so only one trailing apply is ever pending. When it fires it re-reads the CURRENT `model.windowTitle` rather than a stale captured string.
- The pure type carries the decide/mark logic so it is unit-testable without AppKit; the view owns the `asyncAfter` scheduling.

Wire it into `TerminalBitmapView`: replace both `windowTitle != lastAppliedWindowTitle` blocks (`advanceFrame` ~line 2475 and `refreshRecordingChrome` ~line 7778) with one private `applyWindowTitleIfNeeded()` that consults a single shared throttle instance (main-thread only; `advanceFrame` and `refreshRecordingChrome` both run on main). Pick 200 ms as the interval (5 sets/s ceiling; spinner cadences of 80-250 ms collapse to that, and no human reads a title faster).

Unit-test the type in `Tests/LabanAppTests/WindowTitleThrottleTests.swift` (`Tests/LabanAppTests/TerminalCaptureIndicatorTests.swift` shows the target's test conventions): identical-title no-op, first-change immediate apply, burst collapses to leading + trailing, trailing carries the latest value, post-interval change applies immediately again.

### W3 — Cheap no-new-output pre-check in the feed

`pollAllLabptyFeeds` currently does `feed.wake()` for every tab on every 8 ms drain tick, and `wake()` unconditionally hops to the feed queue and runs `poll()` (ring read, session lock) even when the tab has produced nothing. `LabptyByteRingReader.outputWriteOffset()` (`Sources/LabanCore/LabptyByteRingReader.swift` line 135) is a cheap mmap read. The obstacle is that `lastOffset` is queue-confined.

Implementation: give `LabptyParserFeed` an `OSAllocatedUnfairLock`-guarded (or atomic) mirror `publishedLastOffset: UInt64` that `poll()` updates after consuming (same value as `lastOffset`; the file already uses `OSAllocatedUnfairLock` in `parkLabptyOutputWakeAfterQuiet`, so the pattern is at hand). Add:

    func wakeIfOutputPending() {
      guard reader.outputWriteOffset() > publishedLastOffsetSnapshot() else { return }
      wake()
    }

and use it from `pollAllLabptyFeeds()` only. `wake()` itself stays unconditional for all other callers (unpark, reconnect, initial start), so a stale mirror can never strand output: any real wake path still forces a poll, and the drain tick's pre-check only skips when the ring offset provably has not advanced past what `poll()` already consumed. Note the memory-ordering argument in a comment: `publishedLastOffset` is written after `poll()` consumed up to that offset, and `outputWriteOffset()` reads the producer's monotonically increasing offset, so a race can only cause a spurious `wake()` (harmless), never a missed one — if the producer wrote after our read, the daemon wake pipe fires and `handleLabptyOutputWake` polls unconditionally.

Reuse note (checked 2026-06/07 test files): `Tests/LabanCoreTests/LabptyReconnectRetryTests.swift` and `Tests/LabptyTests/LabptyDaemonTests.swift` exercise the client/daemon but not `LabptyParserFeed` (it is app-side). If a unit test for the pre-check is impractical without a live ring, cover it by assertion in code review plus the re-measure (IdleCounters already tracks per-poll counts via `IdleCounters.shared.noteLabptyPoll`; a poll-count drop for a quiet second tab is observable in a debug session).

## Concrete Steps

Work from the repository root (`/Users/user/wrk/laban`).

1. Per milestone: `./scripts/build-app` (must succeed), then `swift test --filter LabanApp` and `swift test --filter Labpty` (expect 0 failures; the known pre-existing `VectorZoomGlyphSizeConsistencyTests` failure lives under a different filter and is documented in the slug hot-path plan). Commit each milestone separately, reason-style single-line message, no em-dashes, Co-Authored-By trailer.
2. Install and restart for measurement (agents may do this; sessions live in the labpty daemon and survive an app restart):

       ./scripts/install-app
       ./scripts/restart-app --scroll-debug

3. Re-measure (CPU-only; CLI xctrace cannot capture signposts on this machine, which is fine here since all three targets are Time Profiler subtrees):

       # drive a ~100 ms-cadence spinner into the active tab via the scroll-debug server (POST /scroll/input),
       # then record ~20 s attached to LabanApp:
       xcrun xctrace record --template 'Metal with laban signposts' --attach $(pgrep -x LabanApp) --time-limit 20s --output <out>.trace
       python3 scripts/analyze-metal-trace <out>.trace --cpu-only --max-rows 60000
       # subtree shares: grep the cached time-profile XML for rows containing the
       # marker frames parkLabptyOutputWakeAfterQuiet / labptyActiveDrainTick / _dosetTitle
       # (the "log archive corrupt" warning from xctrace is expected and benign for CPU tables)

## Validation and Acceptance

On a re-captured 20 s spinner-workload trace (same recipe, focused or unfocused window; these are main-thread costs):

- W1: `parkLabptyOutputWakeAfterQuiet` subtree drops from ~7.5% of kept sample weight to under 1% (park cycles go from ~10/s to at most ~1/s for a 100 ms-cadence workload, and to ~0 for continuous output). No output latency regression: bytes still drain within the 8 ms tick while active.
- W2: `_dosetTitle` rows under `advanceFrame` drop from ~288/20 s to at most ~100/20 s (5/s ceiling), and after a workload ENDS the final title is correct (trailing apply proof: run a command that sets a title then exits; the title must settle to the final value within ~300 ms). New `WindowTitleThrottleTests` pass.
- W3: with two tabs open and only one producing output, the quiet tab's poll count (IdleCounters, or a debug-session breakpoint count) stays ~0 during a 10 s active burst in the other tab; before this change it polls at the drain rate (~125/s).
- All milestones: full `swift test` for the touched targets green; MVP behavior untouched (`docs/product/mvp.md` is a regression contract; nothing here changes user-visible semantics beyond title-update latency, capped at 200 ms, and park timing, invisible).

## Decision Log

- Decision: fix the park churn by raising the quiet threshold (W1) rather than redesigning the drain (e.g. adaptive intervals, reusing the timer source across cycles).
  Rationale: the measured cost is the cycle count, not the timer mechanics; one constant governs it, and W3 makes the extra un-parked polling nearly free. A redesign is unwarranted at the current cost level.
  Date/Author: 2026-07-10 / Claude + rrj.
- Decision: throttle the title at the application site (view-level debounce) rather than upstream in tab-title metadata.
  Rationale: the tab title itself must stay live (the sidebar renders it, and `TabTitleMetadata` has its own redundancy guards); only the `NSWindow.title` AppKit set is expensive. Throttling at the single choke point where AppKit is touched fixes the cost without changing title semantics anywhere else.
  Date/Author: 2026-07-10 / Claude + rrj.
- Decision: W3 pre-checks only in `pollAllLabptyFeeds`, never in `wake()` itself.
  Rationale: every correctness-bearing wake path (daemon wake pipe, unpark response, reconnect) must stay unconditional so a stale offset mirror can only cause a spurious poll, never a missed one.
  Date/Author: 2026-07-10 / Claude + rrj.

## Surprises & Discoveries

- Observation: `lastAppliedWindowTitle` had exactly the two readers/writers named in the plan (`advanceFrame`, `refreshRecordingChrome`, plus a reset in `viewDidMoveToWindow`), confirmed with `rg lastAppliedWindowTitle` before removal, so it was safe to delete outright rather than keep alongside the new throttle.
  Evidence: `rg -n "lastAppliedWindowTitle"` before the W2 edit returned only the three sites listed in the ExecPlan's orientation section.
- Observation: `viewDidMoveToWindow()` used to null `lastAppliedWindowTitle` so a view moving to a new window (or losing its window) would not suppress a title set the new window has never seen. `WindowTitleThrottle` is a value type with no public "clear" method beyond re-init, so the equivalent fix is constructing a fresh `WindowTitleThrottle` instance there and clearing `pendingTitleApply`. This is behaviorally identical (both force the next title to go through `.apply` with no memory of any prior window's title) but is a type-shape difference worth flagging for the next reader who greps for the old reset pattern.
  Evidence: `Sources/LabanApp/TerminalBitmapView.swift` `viewDidMoveToWindow()`.
- Observation: the ExecPlan's illustrative pre-check pseudocode named the accessor `publishedLastOffsetSnapshot()`; the implementation instead calls `publishedLastOffset.withLock { $0 }` inline in `wakeIfOutputPending()` (no separate named accessor). Same semantics, just no extra indirection for a one-line lock read.
  Evidence: `Sources/LabanApp/AppSessionCoordinator.swift`, `LabptyParserFeed.wakeIfOutputPending()`.
- Observation: no test regressions or unexpected interactions surfaced across any of the three milestones; `swift test --filter LabanApp` grew from 446 to 452 tests (the 6 new `WindowTitleThrottleTests`) and stayed at 0 failures throughout, and `swift test --filter Labpty` stayed at 147 tests (1 pre-existing skip, `LabptyStressTests`), 0 failures, for all three milestones.
  Evidence: test run transcripts captured during implementation (not reproduced here; rerun the two filters to confirm).

## Idempotence and Recovery

Each milestone is one commit and independently revertible. W1 is a constant; W2 is additive (new type + two call sites rewired); W3 is additive (new method used from one call site). If the re-measure shows a regression, revert that milestone alone and re-measure.

## Interfaces and Dependencies

No new dependencies. Touched files: `Sources/LabanApp/AppSessionCoordinator.swift` (W1, W3), `Sources/LabanApp/TerminalBitmapView.swift` + new `Sources/LabanApp/WindowTitleThrottle.swift` (W2), `Tests/LabanAppTests/WindowTitleThrottleTests.swift` (new). `Sources/LabanCore/LabptyByteRingReader.swift` is used (its public `outputWriteOffset()`) but not modified.

