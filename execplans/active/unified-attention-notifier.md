# Unified Attention Notifier

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban already has several ways for a background tab to ask for the user's
attention: BEL sets a passive tab badge, OSC terminal notifications can raise a
native macOS banner, and agent/title metadata can classify a tab as needing
action. Today those paths are partly separate. After this change, terminal
events flow through one attention event and policy layer, so the tab UI, tab
journal, debug state, and macOS notifications all explain the same decision.
Users can configure which attention classes are allowed to post macOS
notifications, while existing tab badges remain synchronized with the model.

## Progress

- [x] (2026-06-23T12:14:59Z) Read `PLANS.md`, product/debug/observability docs, and mapped current BEL, OSC notification, title-attention, settings, and debug-state paths.
- [x] (2026-06-23T12:26:01Z) Add a shared attention event, category, policy, and decision model.
- [x] (2026-06-23T12:26:01Z) Route BEL attention, OSC agent notifications, and `TabAttentionClassifier` state transitions through the shared policy.
- [x] (2026-06-23T12:26:01Z) Replace the current single attention checkbox with category settings for needs-action, completion, passive/BEL, and sound.
- [x] (2026-06-23T12:26:01Z) Expose notification decisions through debug/headless state and tab-journal notes with suppression reasons.
- [x] (2026-06-23T12:26:01Z) Add focused regression tests for BEL passive attention, OSC routing, needs-action transitions, suppression, dedupe, settings, and debug evidence.
- [x] (2026-06-23T12:37:10Z) Focused notifier tests passed, `rtk ./scripts/check` passed, and RPG structural sync was refreshed. Semantic lift still reports the repo's broader pre-existing backlog, so a full lift pass is deferred.

## Decision Log

- Decision: Keep `TabTitleMetadata` as the source of truth for tab attention
  classification and make the notifier observe transitions rather than invent
  a parallel state machine.
  Rationale: `TabAttentionClassifier` already defines `.none`, `.passive`,
  `.done`, and `.needsAction`; using those states keeps sidebar/title badges and
  macOS notification decisions synchronized.
  Date/Author: 2026-06-23 / Codex

- Decision: Treat BEL as passive by default, OSC urgent notifications and title
  awaiting-input transitions as needs-action candidates, and non-urgent OSC
  notifications as completion candidates.
  Rationale: BEL is semantically weak and can be noisy. OSC notifications and
  title-derived agent waits carry stronger intent and should be configurable
  without forcing BEL banners.
  Date/Author: 2026-06-23 / Codex

## Context and Orientation

`Sources/LabanCore/AppModel.swift` owns tabs and sessions. It already listens
for BEL through `Session.onBell`, for OSC terminal notifications through
`Session.onOSCNotification`, and for title-derived awaiting-input transitions
through `detectAwaitMarkerTransitions()`. `TabMetadataSynchronizer.noteBell(...)`
sets `TabTitleMetadata.bellAttention` only for inactive running tabs.
`TabAttentionClassifier.classify(...)` converts tab metadata into user-visible
attention states: `.needsAction` for urgent/waiting/awaiting input, `.done` for
non-urgent notification metadata, `.passive` for unseen output or BEL, and
`.none` for inactive quiet or active tabs.

`Sources/LabanApp/MainWindowController.swift` wires AppKit callbacks from the
model to `AgentNotificationPoster`, which currently posts macOS notifications
directly for OSC agent notifications and for the new BEL attention callback.
`Sources/LabanApp/SettingsWindowController.swift` exposes user preferences.
`Sources/LabanApp/AgentNotificationPoster.swift` is the AppKit/UserNotifications
sink.

Debug and observability requirements come from `docs/process/dev-process.md`
and `docs/process/observability.md`: attention behavior must be visible through
debug state or tab-journal artifacts. The tab-state journal already records tab
metadata state changes and note entries for banner posted/suppressed decisions.
This work should preserve that journal and add enough structured decision data
for a headless test or a future agent to explain why a macOS notification did or
did not post.

Definitions used in this plan:

- Attention event: a single model-level fact that a tab entered an attention
  class or received an explicit terminal notification.
- Attention policy: the code that decides whether an event may post a macOS
  notification, should only update tab UI, or should be suppressed.
- Sink: an output surface such as tab metadata, tab journal, debug state, or
  macOS Notification Center.

## Plan of Work

1. Add shared types in `Sources/LabanCore`, likely `AttentionNotification.swift`
   or similar:
   - `AttentionNotificationCategory` with cases for `needsAction`,
     `completion`, and `passive`.
   - `AttentionNotificationSource` with cases for `bell`, `osc`, and
     `tabAttention`.
   - `AttentionNotificationEvent` carrying tab ID, source, category, title,
     body, stable dedupe key, and timestamp.
   - `AttentionNotificationDecision` carrying the event, action (`posted`,
     `suppressed`), and suppression reason.

2. Add settings in `Sources/LabanApp` so user preferences can decide whether
   macOS banners are allowed for needs-action, completion, passive/BEL, and
   sound. Preserve the existing `LabanAttentionSystemNotifications` key as a
   migration path: if it is present and true, passive/BEL notifications should
   be enabled.

3. Update `AppModel` so BEL, OSC, and attention-class transitions call one
   attention callback with `AttentionNotificationEvent` instead of separate
   `onAgentNotification` and `onBellAttention` callbacks. Preserve current
   behavior while routing:
   - Restore-burst suppression still suppresses stale OSC banners.
   - A real OSC notification merged into an existing synthetic awaiting-input
     episode should post only if urgent.
   - BEL posts only on a false-to-true `bellAttention` transition.
   - A tab entering `.needsAction` through `TabAttentionClassifier` can emit a
     needs-action event without relying on an OSC notification.

4. Update `MainWindowController` to install one attention handler. The handler
   should evaluate focus and settings, write a tab-journal note with the
   posted/suppressed reason, record a bounded last-decision list on the model,
   and call `AgentNotificationPoster` only for postable decisions.

5. Update `AgentNotificationPoster` so it accepts one decision/event shape and
   uses stable identifiers and `threadIdentifier` by tab. It should keep the
   bundle guard and authorization behavior, respect the sound setting, and
   include tab ID/event metadata in `userInfo` for future click-to-focus wiring.

6. Expose recent notification decisions through debug state. The minimal
   acceptable shape is a bounded `attentionNotifications` array in
   `/debug/state` entries or root state containing tab ID, source, category,
   action, reason, title, body, and timestamp. If schemas exist for that
   response, update them with the new fields.

7. Add tests:
   - Core tests for event emission on BEL, OSC urgent/non-urgent, and
     `TabAttentionClassifier` needs-action transitions.
   - App tests for settings defaults/migration and policy decisions.
   - Debug tests that verify recent decisions are visible through debug state or
     tab journal.

## Concrete Steps

Work from `/Users/rrj/wrk/laban`.

Before building, confirm there is no concurrent Swift build:

```sh
rtk pgrep -fl "swift build"
```

Run focused tests while developing:

```sh
rtk swift test --filter 'AttentionNotification|AppModelTests/test.*Attention|TabAttentionEndToEndTests|TabTitleEndToEndTests'
```

Run the full repo gate before considering the plan complete:

```sh
rtk ./scripts/check
```

## Validation and Acceptance

The implementation is complete only when all of these are true:

- A BEL in a background running tab raises the existing passive tab badge and,
  when passive/BEL notifications are enabled, produces one macOS-notification
  decision. Repeating BEL while the tab is already marked does not produce a
  second decision. Viewing the tab clears the badge and allows a later BEL to
  notify again.
- An urgent OSC notification updates tab metadata and routes through the same
  policy path as BEL; a non-urgent OSC notification routes as a completion
  category.
- A tab that transitions into `.needsAction` because of
  `TabAttentionClassifier` emits a needs-action notification event without
  requiring an OSC notification.
- Frontmost-tab notifications are suppressed with a recorded reason.
- User settings can independently allow or suppress needs-action, completion,
  passive/BEL, and sound.
- The tab journal and debug/headless state expose enough decision data to
  answer whether a notification was posted, suppressed, and why.
- The focused tests and `rtk ./scripts/check` pass.

## Idempotence and Recovery

All changes are source edits and tests. Re-running tests and `scripts/check` is
safe. Do not launch the installed app from the shell. If a build is already
running, wait for it to finish before running another build in the same
worktree. Existing untracked files unrelated to this plan, such as
`scripts/emoji-scroll-demo`, must remain untouched.
