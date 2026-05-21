# Surface Terminal Bells As Tab Attention

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Terminal programs can emit BEL (`0x07`) when a long-running job finishes or an
interactive program wants attention. Laban already exposes that low-level event
through `Session.onBell`; after this change, a bell in an inactive tab appears
as a quiet sidebar attention marker. Selecting the tab clears the marker. Bells
in the active tab do not make sound, flash the viewport, or compete with the
existing agent status dot.

## Progress

- [x] Inspected existing sidebar attention flow for unseen output, exit status,
  and OSC 21337 agent status.
- [x] Add bell attention metadata to tabs and clear it on selection.
- [x] Wire `Session.onBell` into `AppModel` for new and restored sessions.
- [x] Render bell attention in the sidebar below agent status and above generic
  unseen output.
- [x] Add focused model, resolver, sidebar, and debug-state tests.
- [x] Run validation, update RPG features for touched code, move this ExecPlan
  to `execplans/completed/`, and commit.

## Outcomes & Retrospective

Bell attention is now part of tab metadata, is set by `Session.onBell` for
inactive tabs, and is cleared when the tab is selected. The sidebar renders it
as a red dot in the existing badge position, while OSC 21337 agent indicators
continue to take priority. The debug state and action schemas expose
`bellAttention` for headless verification.

## Decision Log

- Decision: Bells are surfaced only as inactive-tab attention.
  Rationale: Active-tab bells are usually already visible in context, while
  inactive-tab bells are the useful "come back here" signal. This avoids sound,
  focus theft, and viewport flashing.
  Date/Author: 2026-05-21 / Codex.

- Decision: The OSC 21337 agent indicator dot stays higher priority than bell
  attention.
  Rationale: Agent status is a richer, app-specific signal. Bell is a generic
  terminal event and should not cover an explicit agent dot.
  Date/Author: 2026-05-21 / Codex.

## Context and Orientation

`Sources/LabanCore/Session.swift` exposes `onBell`, a callback that receives a
monotonically increasing bell count when libghostty parses BEL. `AppModel`
owns tabs and sessions and is responsible for attaching per-session callbacks
when tabs are created or restored. `TabTitleMetadata` stores sidebar-visible
tab state such as `unseenOutput`, `activityState`, and agent metadata.

`SidebarProducer` renders the vertical tab sidebar from `model.tabs`.
`TabTitleResolver.statusBadge(for:)` decides whether a tab gets a small
top-right legacy attention badge. `SidebarProducer` gives the OSC 21337 agent
indicator dot priority over that badge, so bell attention should flow through
the same legacy badge slot.

## Plan of Work

1. Add `bellAttention: Bool` to `TabTitleMetadata`, defaulting to `false`, and
   include it in the initializer.
2. Add a helper on `TabMetadataSynchronizer` that marks a tab's
   `bellAttention` only when the tab is running and inactive, then resolves the
   title metadata.
3. Update `AppModel` to attach `Session.onBell` for every session it creates or
   restores. The callback must hop back into `AppModel` and mark the matching
   tab. Active-tab bells should leave `bellAttention` false.
4. Clear `bellAttention` alongside `unseenOutput` when a tab becomes selected
   or when a replacement active tab is chosen after closing another tab.
5. Update `TabTitleResolver.statusBadge(for:)` so `bellAttention` returns a
   red attention marker, but only after waiting/agent/nonzero-exit priority and
   before generic unseen output.
6. Add tests:
   - `TabTitleMetadataTests` for the bell badge priority.
   - `SidebarProducerTests` for rendered bell attention and agent-dot priority.
   - `AppModelTests` proving inactive BEL sets the marker and selecting the tab
     clears it.
   - `LabanDebugTitleTests` proving headless debug state exposes the marker.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk swift test --filter AppModelTests
rtk swift test --filter TabTitleMetadataTests
rtk swift test --filter SidebarProducerTests
rtk swift test --filter TerminalSurfaceControllerTests
rtk swift test --filter LabanDebugTitleTests
rtk swift test --filter DebugActionDecodingTests
rtk ./scripts/check-docs
```

Acceptance:

- Feeding BEL to an inactive fixture session marks that tab with
  `titleMetadata.bellAttention == true`.
- Feeding BEL to the active session does not set bell attention.
- Selecting a bell-marked tab clears the bell marker.
- The sidebar renders the red legacy marker for bell attention when no agent
  indicator dot is present.
- An OSC 21337 agent indicator dot continues to render instead of the bell
  marker.

Validated on 2026-05-21:

- `rtk swift test --filter AppModelTests`
- `rtk swift test --filter TabTitleMetadataTests`
- `rtk swift test --filter SidebarProducerTests`
- `rtk swift test --filter TerminalSurfaceControllerTests`
- `rtk swift test --filter LabanDebugTitleTests`
- `rtk swift test --filter DebugActionDecodingTests`
- `rtk ./scripts/check-docs`

## Idempotence and Recovery

The edits are additive and local to tab metadata, model callback wiring, sidebar
rendering, and tests. Re-running the tests is safe. If callback tests become
flaky, verify that `Session.onBell` is attached during tab creation and cleared
automatically by `Session.close()`.
