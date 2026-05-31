# Quiet Idle Tabs, A Calm "Needs You" Signal

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(at the repository root, `/Users/rrj/wrk/laban/PLANS.md`). Keep `Progress` and
`Validation and Acceptance` current as work proceeds. Add optional sections only
when they contain information that will help a fresh contributor.

## Purpose / Big Picture

Today every tab in Laban's vertical sidebar shows a small blue dot the entire
time a long-running program is open — `claude`, `codex`, a REPL, an editor,
`ssh`. The dot is technically truthful ("a command is executing here") but it is
lit on *every* tab almost *all* the time, so it carries no actionable
information. When you have several agent tabs open, you cannot tell at a glance
which one is just chugging along versus which one is **stopped waiting for you**
(an approval prompt, a "needs input" pause, a finished task).

After this change:

- **Idle and actively-focused tabs are visually quiet** — no dot. A dot means
  *something you have not seen yet*, the way it does in iTerm2, tmux, Warp,
  Ghostty, and web browsers.
- **A tab that needs your action** (an agent asked for permission / input, a
  command failed, a background task finished) shows a **distinct, calm signal**:
  a reserved-colour marker, a faint row-background tint, and a slow "breathing"
  pulse — never a stressful flash. The signal **clears when you open that tab**.
- The pulse honours the system **Reduce Motion** setting (it becomes a steady,
  full-strength marker instead of animating) and never relies on colour alone.

You can see it working by opening two tabs, running a command that prints a
shell-integration "needs input" / approval marker in the unfocused one, and
watching only that tab gain a gently pulsing tinted row while the focused tab
stays quiet — then selecting it and watching the signal clear.

## Background Knowledge (read this first; it is self-contained)

You do not need any prior Laban context. These terms appear throughout:

- **Sidebar**: Laban's vertical list of open tabs on the left. It is **not**
  built from AppKit views. It is drawn as a list of *frame commands* (mostly
  "draw this glyph at this point in this colour") through the same Metal GPU
  renderer as the terminal grid. The "dot" is literally the bullet character
  `"●"` drawn as a glyph. Code: `Sources/LabanCore/SidebarProducer.swift`.
- **OSC sequence**: an "Operating System Command" escape sequence a program
  prints into the terminal to talk to the terminal app. Three matter here:
  - **OSC 133** ("shell integration"): the shell emits `ESC ] 133 ; A …` at the
    prompt, `ESC ] 133 ; C …` when a command *starts*, and `ESC ] 133 ; D ; <n>`
    when it *finishes* with exit code `<n>`. Laban reduces these to a phase
    machine: `idle → atPrompt → running → finished`
    (`Sources/LabanCore/ShellIntegrationState.swift`). **A long-lived foreground
    program keeps the phase pinned at `running` for its whole lifetime** — this
    is exactly why the blue dot never goes out.
  - **OSC 21337** (iTerm2 "set tab status"): a program can push an indicator
    colour + a short status label. Stored in `TabAgentStatus.indicatorColor`
    (`Sources/LabanCore/TabTitleMetadata.swift:72`).
  - **OSC 9** (desktop notification): a program (e.g. Codex) posts "turn
    complete" / "approval requested". Stored as `TabNotification`
    (`Sources/LabanCore/TabTitleMetadata.swift:132`) with an `urgent` flag and a
    repeat `count`.
- **Active / focused tab**: the one currently selected and on screen. Its
  `Tab.isActive` is true and its id equals `activeTabId` in the sidebar.

**Why the redesign (the UX rationale, embedded so you need no external links):**
An indicator earns attention only when it is *conditional* — present when
something is true, absent otherwise. A signal that is always on is, by
definition, never informative and trains the eye to ignore it (the same reason
every alert looking identical makes none of them urgent). The established
convention across terminals and browsers is that a per-tab dot marks **unseen
activity on a background tab and clears on focus**; an idle tab shows nothing.
For the "needs you" case, calm-attention design says: differentiate
*action-required* from *passive activity* by shape **and** colour **and**
motion; make motion a slow ease-in-out "breath" (~1.5 s per cycle) that never
drops to zero opacity, because sub-second on/off flashing reads as an alarm; and
under Reduce Motion, replace the animation with a static high-contrast marker
rather than removing the signal. (Sources consulted are listed in the Decision
Log for posterity; the principles above are restated in full here so this plan
stays self-contained.)

This work is **refinement of already-shipped indicators**, not new product
scope: `docs/product/spec.md §7` already states the OSC 133 state machine feeds
"status indicators and bell badges". No `spec.md` change is required.

## Progress

Milestones are independently shippable. M1 alone resolves the user's primary
complaint and should be committed before M2/M3 begin.

- [ ] **M1 — Quiet the always-on dot (subtraction; no animation).**
  - [ ] Remove the implicit `shellPhase == .running` blue dot from
    `SidebarProducer.shellPhaseIndicatorColor`.
  - [ ] Suppress *all* right-edge status indicators on the active/focused tab.
  - [ ] Tests: a running, unfocused tab with no other signal renders **no**
    indicator glyph; a failed-command tab still renders red; the focused tab
    renders nothing.
- [ ] **M2 — A distinct, static "needs you" tier (colour + shape + row tint).**
  - [ ] Add a pure `TabAttention` classifier (`none / passive / done /
    needsAction`) in `LabanCore`.
  - [ ] Render `needsAction` with a reserved marker + a faint row-background
    tint; render `done` as the existing accent diamond; keep `passive` muted.
  - [ ] Expose the derived attention level in the debug/headless state for
    autonomous verification.
  - [ ] Tests for classification, rendered tint/marker, focus-clear, and debug
    state.
- [ ] **M3 — Calm breathing pulse (animation), Reduce-Motion-aware.**
  - [ ] Thread a frame `now: Date` and a `reduceMotion: Bool` into the sidebar
    command path (keeping `LabanCore` AppKit-free).
  - [ ] Pulse only the `needsAction` marker's alpha between a floor and full,
    on a shared phase anchor so all such tabs breathe in unison.
  - [ ] Keep the render loop ticking only while a `needsAction` tab is visible;
    let it idle otherwise (must not regress the idle-CPU budget).
  - [ ] Read Reduce Motion in the AppKit layer; when on, render a steady marker.
  - [ ] Tests for the pure pulse function and an idle-loop assertion.

## Decision Log

- Decision: Fix the complaint primarily by *removing* the implicit
  shell-phase-running dot and by *never* showing a status indicator on the
  focused tab, rather than by trying to make the agent clear its own dot.
  Rationale: The always-on dot's root cause is OSC 133 `running` staying latched
  for a foreground program's whole life (`ShellIntegrationState.apply`,
  `.commandStart → .running`). We cannot make third-party programs emit a
  "clear". Removing the implicit dot and quieting the focused tab is robust
  regardless of which signal (shell-phase blue or a stale OSC 21337 colour) was
  responsible.
  Date/Author: 2026-05-31 / Claude.

- Decision: The breathing pulse is computed inside the existing immediate-mode
  Metal sidebar (per-frame alpha on a glyph), not via Core Animation or a new
  AppKit tab bar.
  Rationale: The sidebar is already redrawn each frame through the GPU renderer
  and the render loop already runs at vsync (it drives cursor blink the same
  way). A per-frame alpha is therefore the *cheapest* option here; adding Core
  Animation or rebuilding the tab list as `NSView`s purely for one pulse would be
  a large architectural reversal. (Field note: native AppKit chrome is generally
  preferred for accessibility/theming, and most terminals keep chrome native and
  reserve the GPU for the grid; Laban already chose the WezTerm-style "draw
  chrome in the grid" path, so we build within it. Tab-list VoiceOver support is
  a pre-existing, separate concern and explicitly out of scope here.)
  Date/Author: 2026-05-31 / Claude.

- Decision: Only the `needsAction` marker pulses; the row tint is steady and the
  `done`/`passive` markers are static.
  Rationale: A pulse must mean exactly one thing ("act here"). A steady tint is
  calmer than a pulsing background and still draws the eye when scanning many
  tabs.
  Date/Author: 2026-05-31 / Claude.

- Sources consulted (for posterity; principles are restated in-plan above):
  iTerm2 indicator docs; tmux window-flag monitoring; Warp tab/notification
  docs; the Ghostty per-tab-attention discussion (#10692, the same
  multiple-agent scenario); Nielsen Norman Group on indicators vs notifications
  and on notification fatigue; Apple Human Interface Guidelines on
  notifications/badging and on Motion/Reduce Motion; WCAG 2.1 SC 1.4.1 (do not
  use colour alone). Apple Core Animation/ProMotion docs informed the "build
  within the existing GPU loop" decision.

## Context and Orientation

Assume no prior knowledge. Key files (full repository-relative paths):

- `Sources/LabanCore/TabTitleMetadata.swift` — the per-tab state model. Relevant
  fields on `TabTitleMetadata` (struct starts line 144): `agentStatus`
  (`TabAgentStatus`, has `indicatorColor`), `activityState` (`TabActivityState`
  enum: `active/background/running/idle/unseenOutput/waiting/exited`),
  `bellAttention: Bool`, `notification: TabNotification?` (has `urgent`,
  `count`), `unseenOutput: Bool`, `exitStatus: Int?`, `shellPhase`
  (`ShellIntegrationPhase`), `lastCommandExitCode: Int?`. `TabAgentMetadata`
  (line 96) has `awaitingInput: Bool`.
- `Sources/LabanCore/ShellIntegrationState.swift` — the OSC 133 phase reducer.
  `apply(.commandStart)` sets `phase = .running` (line 54) and only
  `apply(.commandEnd)` moves it to `.finished` (line 56). This is the latch that
  keeps the dot lit.
- `Sources/LabanCore/SidebarProducer.swift` — draws the sidebar. The indicator
  is chosen by specificity in `commands(...)` (signature at line 61). The
  current right-edge indicator block is lines 187–234. The shell-phase colour
  helper is `shellPhaseIndicatorColor(_:)` at lines 422–430:

  ```swift
  static func shellPhaseIndicatorColor(_ meta: TabTitleMetadata) -> UInt32? {
    if meta.shellPhase == .running { return Theme.current.blue }   // <- the always-on blue dot
    if let exit = meta.lastCommandExitCode, exit != 0 { return Theme.current.red }
    return nil
  }
  ```

  The per-row background colour `bg` is already computed per tab in `commands`
  (it is passed as each glyph's `background:`); the row-tint feature blends `bg`
  toward the attention colour. Hover replaces the indicator slot with a close
  `"✕"` via `showCloseX` (line 186), so attention rendering stays inside the
  `if !showCloseX { … }` block.
- `Sources/LabanCore/TerminalSurfaceController.swift` — `sidebarCommands(...)`
  (lines 537–555) calls `SidebarProducer(...).commands(...)`. `makeFrame(...)`
  (lines 313–338) is the per-frame entry that calls `sidebarCommands`.
- `Sources/LabanApp/TerminalBitmapView.swift` — the AppKit view that owns the
  render loop. Cursor blink is the model to mirror for animation:
  - `cursorBlinkInterval = 0.5` (line 235); state `cursorBlinkVisible`,
    `lastCursorBlinkToggleAt` (lines 236–237); `advanceCursorBlinkState(now:)`
    (lines 818–831); `cursorBlinkFrame = advanceCursorBlinkState() &&
    windowVisibleToUser` (line 885).
  - The display link runs continuously but VRR-throttled (macOS 14+
    `CADisplayLink` with `CAFrameRateRange(min:24,max:120)`, lines 584–591;
    `CVDisplayLink` fallback). Each tick calls `advanceFrame()` (line 640).
  - **Idle gate** (line 1032): `guard terminalDirty || renderInvalidated ||
    tabChanged || cursorBlinkFrame else { return }`. When all are false,
    `advanceFrame` returns before doing any render work — this is what keeps idle
    CPU low (see `execplans/completed/appkit-idle-cpu-render-budget.md`).
    `renderInvalidated` (declared line 135) is reset to false after a render
    (line 1148). The sidebar command call happens via
    `surfaceController.makeFrame(request, …)` at line 1086.
- `Sources/LabanRenderer/MetalRenderer.swift` — consumes glyph colours.
  Foreground colour is a `UInt32` laid out `0xRRGGBBAA`; the **alpha is the low
  byte**. `rgbaToFloat4`/`MTLClearColor` extract it as `Double(c & 0xFF)/255.0`
  (≈ lines 728–732), and the glyph blend honours per-glyph alpha (alpha-blended
  add). So fading a glyph = modulate the low byte of its colour.
- `Sources/LabanDebug/DebugModels.swift` — `TabResponse` (lines 103–126) is the
  JSON shape the headless/debug `/debug/state` endpoint returns per tab. It
  already includes `activityState`, `unseenOutput`, `bellAttention`,
  `shellPhase`, `lastCommandExitCode`, `agent`. We add the derived attention
  level here for verification. `Sources/LabanDebug/HeadlessDebugRuntime.swift`
  must stay in parity with the AppKit path (an `AGENTS.md` hard rule).

Constraint to respect throughout: `SidebarProducer` and everything in
`LabanCore` must **not** import AppKit. `NSWorkspace`
(`accessibilityDisplayShouldReduceMotion`) is AppKit, so Reduce-Motion is read in
`Sources/LabanApp/TerminalBitmapView.swift` and threaded down as a plain `Bool`.

## Plan of Work

### Milestone 1 — Quiet the always-on dot (subtraction only)

Scope: the smallest change that makes idle/focused tabs quiet. No new state, no
animation.

1. In `Sources/LabanCore/SidebarProducer.swift`, edit `shellPhaseIndicatorColor`
   to **delete the `.running → Theme.current.blue` branch**. Keep the
   failed-exit red branch. Result: a running foreground program no longer
   produces a dot; a failed command still does.
2. In `commands(...)`, wrap the right-edge indicator block (lines 187–234) so it
   is skipped for the **active tab**. There is already a per-row notion of the
   active tab (the row whose id equals `activeTabId`); add `&& tab.id !=
   activeTabId` to the existing `if !showCloseX` guard (or compute
   `let isActiveRow = tab.id == activeTabId` and gate on `!isActiveRow`). The
   focused tab you are looking at needs no "come back here" marker.
3. Leave OSC 21337 agent dots, OSC 9 notifications, bell, and unseen-output
   badges exactly as they are for now (M2 reorganises them). The only visible M1
   change: no blue running dot anywhere, and no indicator on the focused tab.

Tests (extend existing `Tests/LabanCoreTests/SidebarProducerTests.swift`):
- A tab with `shellPhase == .running` and no notification/bell/unseenOutput/
  nonzero-exit, **unfocused**, produces zero indicator glyphs (assert no
  `glyphRun` whose `text` is one of `● ◆ ! * •` at the right-edge slot).
- The same metadata with `lastCommandExitCode = 1` still produces a red marker.
- Any attention metadata on the **active** tab produces zero right-edge
  indicator glyphs.

### Milestone 2 — A distinct, static "needs you" tier

Scope: introduce a single, pure classification of "how much does this tab want
attention", and render three visually-distinct, static tiers. Still no motion.

1. Add a pure classifier in `LabanCore` (new file
   `Sources/LabanCore/TabAttention.swift`), AppKit-free and fully testable:

   ```swift
   public enum TabAttention: String, Equatable, Codable, Sendable {
     case none        // focused tab, or idle/at-prompt/running with nothing unseen
     case passive     // unseen output / bell on a background tab — low salience
     case done        // a background task finished (informational)
     case needsAction // agent asked for permission/input, or a command failed
   }

   public enum TabAttentionClassifier {
     /// Pure. `isActive` is whether this tab is the focused/selected tab.
     public static func classify(_ m: TabTitleMetadata, isActive: Bool) -> TabAttention {
       if isActive { return .none }
       if (m.notification?.urgent ?? false)
         || m.activityState == .waiting
         || m.agent.awaitingInput
         || (m.activityState == .exited && (m.exitStatus ?? 0) != 0)
         || ((m.lastCommandExitCode ?? 0) != 0) { return .needsAction }
       if m.notification != nil { return .done }   // non-urgent notification = "done"
       if m.unseenOutput || m.bellAttention { return .passive }
       return .none
     }
   }
   ```

2. In `SidebarProducer.commands(...)`, replace the ad-hoc indicator precedence
   (M1's block) with a single switch on
   `TabAttentionClassifier.classify(meta, isActive: tab.id == activeTabId)`:
   - `.needsAction`: draw a reserved marker glyph (keep the `"◆"` shape the
     notification path already uses) in `Theme.current.red`, **and** tint the
     whole row by blending `bg` a small fraction (e.g. 12–16%) toward red. The
     first info line shows the existing short label (`needs you ×N` when a
     notification count exists, else `needs input` / `exited <code>`).
   - `.done`: draw `"◆"` in `Theme.current.cursor` (accent); no row tint; first
     info line `done ×N`. (Matches today's non-urgent notification look.)
   - `.passive`: keep a muted marker — the existing `*`/`•`/dim `●` — no tint.
   - `.none`: draw nothing.
   - An explicit OSC 21337 `agentStatus.indicatorColor` still wins over
     `.passive` (an agent that *explicitly* set a colour is more specific than
     generic unseen output), but `.needsAction`/`.done` (real attention) win over
     it. Encode this ordering directly in the switch and cover it with a test.
3. Add a small helper to blend two `0xRRGGBBAA` colours by a fraction (pure,
   in `SidebarProducer` or `Theme`), for the row tint.
4. Surface the derived level for verification:
   - Add `attention: String` to `TabResponse`
     (`Sources/LabanDebug/DebugModels.swift`), populated from
     `TabAttentionClassifier.classify(tab.titleMetadata, isActive: tab.isActive)`
     wherever `TabResponse` is built. Keep `HeadlessDebugRuntime` and the AppKit
     path in parity.

Tests:
- `Tests/LabanCoreTests/` new `TabAttentionTests`: each branch of `classify`
  (focused→none; urgent notification→needsAction; waiting→needsAction;
  awaitingInput→needsAction; nonzero exit→needsAction; non-urgent
  notification→done; unseenOutput→passive; plain running→none).
- `SidebarProducerTests`: a `needsAction` tab renders the red `◆` and a tinted
  row background (assert at least one glyph's `background` differs from the
  untinted `bg` by the expected blend); a `done` tab renders the accent `◆` with
  untinted `bg`; explicit `indicatorColor` beats `.passive` but not
  `.needsAction`.
- A debug-state test (mirror `LabanDebugTitleTests`) asserting
  `TabResponse.attention` reports `needsAction` for a waiting unfocused fixture
  tab and `none` after it is selected.

### Milestone 3 — Calm breathing pulse (animation)

Scope: make only the `needsAction` marker breathe, cheaply, and correctly under
Reduce Motion and the idle-CPU budget.

1. Make the pulse a **pure function** in `LabanCore` (e.g. in
   `TabAttention.swift`) so it is unit-testable without a running app:

   ```swift
   public enum AttentionPulse {
     /// Shared, fixed anchor so every needsAction tab breathes in unison.
     public static let period: TimeInterval = 1.5
     public static let floor: Double = 0.55   // never fully fades out (calm, not blink)
     /// Returns an alpha in [floor, 1.0] following a raised-cosine ("breath").
     public static func alpha(at now: Date) -> Double {
       let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
       let phase = t / period * 2 * Double.pi
       let unit = (1 - cos(phase)) / 2          // 0→1→0, smooth ease in/out
       return floor + (1 - floor) * unit
     }
     /// Apply alpha to the low byte of a 0xRRGGBBAA colour.
     public static func applyAlpha(_ color: UInt32, _ a: Double) -> UInt32 {
       let byte = UInt32((min(max(a, 0), 1) * 255).rounded())
       return (color & 0xFFFF_FF00) | byte
     }
   }
   ```

2. Thread a tiny animation context into the sidebar command path **without**
   importing AppKit into `LabanCore`:
   - Add `now: Date = Date()` and `reduceMotion: Bool = false` parameters to
     `SidebarProducer.commands(...)` (line 61) and to
     `TerminalSurfaceController.sidebarCommands(...)` (line 537). Plumb them
     through `makeFrame` via `TerminalSurfaceFrameRequest` (add two fields).
   - In `SidebarProducer`, when a row classifies as `.needsAction` and
     `!reduceMotion`, set the marker glyph colour to
     `AttentionPulse.applyAlpha(Theme.current.red, AttentionPulse.alpha(at: now))`.
     When `reduceMotion` is true, use full-opacity red (steady). The row tint
     stays steady in both cases.
3. Drive it from the render loop in
   `Sources/LabanApp/TerminalBitmapView.swift`, mirroring cursor blink:
   - Read Reduce Motion: `let reduceMotion =
     NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. Observe
     `NSWorkspace.shared.notificationCenter` for
     `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` to refresh it
     and invalidate a frame on change.
   - Pass `now: Date()` (the same wall-clock cursor blink uses) and `reduceMotion`
     into the request used at line 1086.
   - Add an `attentionAnimating` signal to the idle gate (line 1032): compute
     `let attentionFrame = anyVisibleNeedsActionTab && windowVisibleToUser &&
     !reduceMotion`, and include `|| attentionFrame` in the guard so the loop
     keeps rendering **only while** a `needsAction` tab is visible. When none is
     (the tab was opened/cleared, or Reduce Motion is on), the term is false and
     the loop idles exactly as before. `anyVisibleNeedsActionTab` is computed
     from the model via `TabAttentionClassifier.classify` over the tabs (cheap;
     no per-pixel work).
   - Optional refinement (note, do not over-engineer): a 1.5 s breath does not
     need 120 Hz. If profiling shows the pulse is costly, lower the display
     link's `preferredFrameRateRange` while only-attention frames are driving, or
     quantise: only invalidate when `alpha` crosses a coarse step. Ship the
     simple version first and measure.

Tests:
- `AttentionPulseTests`: `alpha(at:)` equals `floor` at the anchor (phase 0),
  `1.0` at the half-period, and `floor` again at the full period; output is
  always within `[floor, 1.0]`; `applyAlpha` only changes the low byte.
- An idle-budget assertion (extend the harness used by
  `appkit-idle-cpu-render-budget`): with no `needsAction` tab present the render
  loop performs zero render work across N ticks; with one present and Reduce
  Motion off, it renders each tick; with Reduce Motion on it idles.
- Manual/screenshot acceptance (below) for the human "is it calm?" check, since
  pixel-exact animation is not unit-assertable.

## Concrete Steps

Run everything from the repository root `/Users/rrj/wrk/laban`.

Build the app (per project convention, **not** `swift build`):

```sh
./scripts/build-app
```

Run the focused test suites as each milestone lands (mirrors the idiom used by
`execplans/completed/terminal-bell-attention-ui.md`):

```sh
rtk swift test --filter SidebarProducerTests
rtk swift test --filter TabAttentionTests          # new, M2/M3
rtk swift test --filter AttentionPulseTests        # new, M3
rtk swift test --filter TabTitleMetadataTests
rtk swift test --filter TerminalSurfaceControllerTests
rtk swift test --filter LabanDebugTitleTests
rtk swift test --filter DebugActionDecodingTests
rtk swift test --filter AppModelTests
rtk ./scripts/check-docs
```

After each milestone: update this `Progress` section, refresh the `.rpg`
features for touched entities per `docs/process/rpg-graph-maintenance.md`, and
commit with a single-line reason message (e.g. `An always-on running dot on
every tab carries no signal`). Do not launch the GUI from the shell to verify;
install the build and let the user launch it, or use the headless/debug path
below.

Headless verification of the new state (no GUI), using the debug runtime
described in `docs/process/dev-process.md`:

1. Start a headless session, create two tabs, keep tab A focused.
2. Feed tab B a fixture byte stream that sets a "needs action" condition (an
   OSC 9 urgent notification, or an OSC 133 `D;1` failed command, or a waiting
   state) so `classify` returns `needsAction`.
3. `GET /debug/state` and assert `tabs[B].attention == "needsAction"` and
   `tabs[A].attention == "none"`.
4. Select tab B; `GET /debug/state` again and assert `tabs[B].attention` is now
   `none` (cleared on focus).

## Validation and Acceptance

Phrase acceptance as observable behaviour.

**M1 (must hold before M2):**
- Open a tab and run a long-lived program (`claude` / a REPL). The sidebar shows
  **no** dot for that tab while it runs. Previously it showed a persistent blue
  dot. The failing-command red marker still appears when a command exits
  non-zero in a background tab.
- `rtk swift test --filter SidebarProducerTests` passes, including the new
  no-indicator-while-running and no-indicator-on-active-tab tests, which fail
  before the change and pass after.

**M2:**
- A background tab in a "needs you" condition shows a red `◆` and a faintly
  red-tinted row; a background tab that merely *finished* a task shows an accent
  `◆` with no tint; a background tab with only unseen output shows the muted
  marker; the focused tab shows nothing.
- `GET /debug/state` reports `attention` per tab matching the rendered tier, and
  it flips to `none` when the tab is selected.
- `rtk swift test --filter TabAttentionTests` and the extended
  `SidebarProducerTests` / debug-state tests pass (fail before, pass after).

**M3:**
- With Reduce Motion **off**, the `needsAction` marker breathes smoothly (~1.5 s
  per cycle) and never fully disappears; it is visibly calmer than a blink. With
  Reduce Motion **on** (System Settings → Accessibility → Display → Reduce
  Motion), the same tab shows a steady, full-strength red marker with no
  animation. Selecting the tab clears the signal and the animation stops.
- Idle CPU is unchanged when no tab needs action: the render loop performs no
  render work across ticks (assert via the idle-budget harness; the existing
  idle-CPU test still passes).
- `rtk swift test --filter AttentionPulseTests` passes (fails before, passes
  after). Capture a short screen recording or a few frame screenshots of the
  pulsing tab as the evidence artifact and attach under `Artifacts and Notes`.

Record the date and the exact commands run under `Progress`/here when validated,
as the bell-attention plan did.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is marked done. Each item is mechanically checkable.

- [ ] `grep -n "Theme.current.blue" Sources/LabanCore/SidebarProducer.swift`
  returns **no** hit inside `shellPhaseIndicatorColor` (the running-blue branch
  is gone).
- [ ] In `Sources/LabanCore/SidebarProducer.swift`, the right-edge indicator
  rendering is guarded so it cannot run for the row whose id equals
  `activeTabId` (grep for the guard; expect the active-tab exclusion present).
- [ ] `Sources/LabanCore/TabAttention.swift` exists and `TabAttentionClassifier`
  / `AttentionPulse` import no AppKit (`grep -n "import AppKit"
  Sources/LabanCore/TabAttention.swift` → zero hits; same for
  `SidebarProducer.swift`).
- [ ] `rtk swift test --filter TabAttentionTests` → exit 0.
- [ ] `rtk swift test --filter AttentionPulseTests` → exit 0; and the test
  asserts `AttentionPulse.alpha(at:)` ∈ `[0.55, 1.0]` with `floor` at phase 0
  and `1.0` at the half-period.
- [ ] `rtk swift test --filter SidebarProducerTests` → exit 0, including a test
  proving a running, unfocused tab with no other signal yields zero right-edge
  indicator glyphs.
- [ ] `TabResponse` in `Sources/LabanDebug/DebugModels.swift` has an `attention`
  field, and a debug-state test asserts it is `needsAction` for a waiting
  unfocused fixture and `none` after selection.
- [ ] The idle-CPU budget test (from
  `execplans/completed/appkit-idle-cpu-render-budget.md`) still passes (no
  regression when no tab needs action).
- [ ] `rtk ./scripts/check-docs` → exit 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

All edits are additive or local: a deletion in one helper (M1), one new pure
file plus a switch and a debug field (M2), two threaded parameters and a
render-loop term (M3). Re-running the tests is safe and repeatable. If the pulse
ever appears to "stick on" (loop never idles), the cause is the
`attentionAnimating` term in the idle gate not going false — verify
`anyVisibleNeedsActionTab` recomputes from the live model and that selecting the
tab clears the underlying attention state (notification/waiting/exit). If a
build lacks `NSWorkspace` Reduce-Motion behaviour, the `reduceMotion` Bool simply
defaults to `false` and the pulse runs; nothing else depends on it. To back out
any milestone, revert its commit — milestones are independent and M1 stands
alone.

## Interfaces and Dependencies

End-state signatures that must exist:

- `SidebarProducer.shellPhaseIndicatorColor(_ meta: TabTitleMetadata) -> UInt32?`
  — no longer returns a colour for `shellPhase == .running`.
- `SidebarProducer.commands(tabs:activeTabId:height:topInset:hoveredTabId:dragIndicator:now:reduceMotion:) -> [FrameCommand]`
  (two new trailing params, defaulted).
- `TerminalSurfaceController.sidebarCommands(activeTabId:viewportHeight:topInset:hoveredTabId:dragIndicator:now:reduceMotion:) -> [FrameCommand]`
  (two new trailing params, defaulted); `TerminalSurfaceFrameRequest` gains
  `now: Date` and `reduceMotion: Bool`.
- `LabanCore.TabAttention` (enum) and
  `TabAttentionClassifier.classify(_:isActive:) -> TabAttention` — pure,
  AppKit-free.
- `LabanCore.AttentionPulse.alpha(at:) -> Double`,
  `AttentionPulse.applyAlpha(_:_:) -> UInt32` — pure.
- `LabanDebug.TabResponse.attention: String`.

Dependencies: no new third-party libraries. Uses existing `Theme` colours
(`red`, `cursor`), the existing Metal glyph alpha path (`0xRRGGBBAA`, low byte =
alpha), the existing display-link render loop, and AppKit's
`NSWorkspace.accessibilityDisplayShouldReduceMotion` (read only in the
`LabanApp` layer).
