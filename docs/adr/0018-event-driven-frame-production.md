# 18. Event-Driven Frame Production; the Display Link Is a Transient Animation Timer

Date: 2026-06-10

## Status

Accepted

## Context

Laban historically drove all terminal painting from a vsync-aligned display
link (`CADisplayLink` on macOS 14+, created in
`TerminalBitmapView.startDisplayLink()`), parked only when the window was
unfocused or fully occluded. While focused and visible,
`TerminalIdlePolicy` kept the link ticking at an 8 Hz floor even when nothing
on screen could change. That floor was a settled architectural choice: a
guaranteed periodic repaint meant any missed invalidation was silently
repaired within 125 ms.

Instruments traces put the price of that guarantee on a focused, fully idle
window at ~110 ms/min of main-thread CPU (the
`syncSurfaceMetadata`/`snapshot`/`renderDirty` per-tick cluster plus
`updateDisplayLinkRunState`) and ~124 ms/min of fixed main-runloop wake cost
at 8 wakes/s — for zero visible benefit. The push path (per-session reader
threads firing `onDirty` through the kick coalescer) already painted occluded
windows correctly with the link parked, proving frame production does not
need a periodic clock.

The risk of removing the floor is the frozen-frame bug class — historically
this repository's worst: any state change that should repaint but fails to
wake the parked link leaves the user staring at a stale frame indefinitely,
with no periodic tick to repair it.

## Decision

Frame production is event-driven; the display link is a transient animation
timer, not a guaranteed periodic repaint.

- The link runs only while something is actually animating: smooth scroll,
  the sidebar attention pulse, the 150 ms post-output hold, or the owned
  cursor-blink timer's floor while blink is enabled. A focused, visible,
  quiescent terminal parks the link completely
  (`TerminalIdlePolicy.displayLinkShouldRun(windowVisibleToUser:scrollAnimating:attentionAnimating:terminalOutputActive:cursorBlinkActive:idleFloorEnabled:)`).
- Animation visibility means the Laban application is active and the terminal
  window is visible, not miniaturized, and at least partly unoccluded. It is
  intentionally independent of `NSWindow.isKeyWindow`: a same-application
  auxiliary window such as Settings may own keyboard focus without hiding the
  terminal's pixels. PTY/input focus remains key-window based. Application
  activation is an explicit wake because the terminal receives no new
  key-window notification when Settings stays key across an app switch.
- Every state change that can alter pixels wakes the frame loop explicitly.
  The wake sources are enumerated and tagged (`FrameWakeSource` in
  `Sources/LabanApp/TerminalBitmapView.swift`); each rendered frame's render
  journal entry records which source produced it (`Entry.wakeSource`).
- Model-level mutations that change pixels without terminal bytes fire
  `AppModel.onSurfaceStateChanged` (tab open/close/reorder/select, resolved
  git branches, daemon surface signals, agent status), which the view
  subscribes through the display-kick coalescer.
- View-local invalidations outside `advanceFrame`'s own flow must use
  `invalidateRenderAndWake()` (or be directly followed by their own wake). A
  bare `renderInvalidated = true` with no wake is a frozen-frame bug.
- The 8 Hz visible-idle floor survives only behind the
  `LabanDisplayLinkIdleFloor` user default (bool, default false): an instant,
  no-rebuild rollback (`defaults write com.rrva.Laban
  LabanDisplayLinkIdleFloor -bool YES` + relaunch) for the frozen-frame risk
  class. The floor constant (`idleDisplayLinkFramesPerSecond = 8`) stays in
  `TerminalIdlePolicy` for that parachute path.
- The pre-macOS-14 `CVDisplayLink` fallback cannot pause cheaply and keeps
  the pre-park behavior; the policy change is inert there.
- A temporary 30 s safety-net timer runs while parked: if a session's dirty
  generation advanced with no frame syncing it, the net repaints and logs
  `render.displayLink.safetyNetRepair` — a bug signal naming a missed wake.
  It is removed once the soak criteria in
  `execplans/active/display-link-full-park.md` Milestone 5 are met.

## Consequences

- Focused-idle main-thread CPU and wakeups drop to the event-driven floor
  (~0–2 wakeups/s with cursor blink off, the default).
- A missed wake is now a user-visible frozen frame instead of a silent 125 ms
  hiccup. The compensating controls are the wake-source audit table and
  per-source tests in the ExecPlan, the `wakeSource` journal field, the
  parachute default, and (temporarily) the safety-net repair signal.
- The render journal's `displayLink.reason` ladder gains `"parked"` (visible,
  quiescent, floor off) so dumps distinguish the new state from
  `"notVisible"` and floor-on `"idle"`.
- Opening a same-application auxiliary window no longer interrupts a live
  terminal animation; deactivating Laban, hiding/minimizing the terminal, or
  fully occluding it still parks animation work.

## Applies To New Code

Any new subsystem that mutates user-visible state MUST wake the frame loop:
model-level changes fire `AppModel.onSurfaceStateChanged` (or arrive as
terminal bytes, which bump the session dirty generation and ride the
`onSessionDirty` push); view-local invalidations call
`invalidateRenderAndWake()`. Never assume a display-link tick will pick a
change up — there is none while parked. New animation states must be added to
`TerminalIdlePolicy.displayLinkShouldRun` inputs and reconciled in
`updateDisplayLinkRunState()`, and need a wake source that starts them.
