# Tab-State Journal and Earlier "Needs You" Attention

## Purpose

When a coding agent (Claude Code, Codex) running inside a Laban tab finishes a
turn and waits for the user, Laban shows a "needs you" badge on the tab and
posts a macOS notification banner. Today both fire only when the agent itself
emits a desktop-notification escape sequence (OSC 9 or OSC 777 — "OSC" is an
"Operating System Command", an in-band escape sequence a terminal program
writes into its output stream). Claude Code debounces that sequence by ~6
seconds, so the user learns the agent is waiting ~6 seconds late.

PTY capture `appkit-2026-06-12T06-21-05Z` (a Laban capture artifact under
`~/Library/Logs/Laban/captures/`) proved the gap: the agent rendered its
question prompt and flipped its terminal title to `✳ Test AskUserQuestion
tool` at t=22.35s, but only emitted
`ESC ] 777 ; notify ; Claude Code ; Claude needs your permission BEL` at
t=28.35s. Laban delivered the banner immediately on receipt — the lag is
upstream. Diagnosing this also exposed an observability hole: the capture
timeline records PTY bytes, frames, and input, but records *nothing* about
when Laban itself changed what a tab showed (badge, title, status, banner).

After this change:

1. **Tab-state journal** — Laban keeps an always-on, bounded, in-memory
   journal of every change to what each tab visibly shows (title metadata,
   status, selection, notification badge), timestamped on the same clock as
   capture timelines. It is queryable over the debug HTTP server
   (`GET /debug/tab-journal`), dumpable from the app's Debug menu, and
   mirrored into `timeline.ndjson` while a capture runs.
2. **Earlier "needs you"** — Laban raises the urgent badge/banner the moment
   the agent's terminal title flips to the awaiting-input marker (a leading
   `✳`), ~6 seconds before the agent's own OSC notification, which is then
   deduplicated.

## Orientation

- `Sources/LabanCore/` — platform-neutral model layer (no AppKit). `AppModel`
  owns tabs; each `Tab` has `titleMetadata: TabTitleMetadata`
  (`Sources/LabanCore/TabTitleMetadata.swift`) carrying the display title,
  agent status, progress, and `notification: TabNotification?` (the "needs
  you"/"done" badge). All UI-visible mutations funnel through
  `AppModel.notifyWorkspaceMutation()` / `notifySurfaceStateChanged()`.
- `Sources/LabanDebug/` — debug HTTP server + headless runtime
  (`HeadlessDebugRuntime`), kept in feature parity with the AppKit window
  (hard rule in `AGENTS.md`). Routes live in `DebugHTTPServer.swift`; response
  schemas in `schemas/debug/`.
- `Sources/LabanApp/` — AppKit app. `MainWindowController` wires `AppModel`
  callbacks; `AgentNotificationPoster` posts banners;
  `MenuCommands.swift` builds the Debug menu; `RenderJournal.swift` is the
  existing per-frame journal this plan's journal is modeled on.
- Captures: `CaptureSink` protocol + `CaptureTimelineEvent` in
  `Sources/LabanCore/CaptureTypes.swift`; recorder in
  `Sources/LabanDebug/CaptureRecorder.swift`. Timestamps are epoch
  nanoseconds from `CaptureClock.nowNs()`.

## Design

### Part A — `TabStateJournal` (LabanCore)

New file `Sources/LabanCore/TabStateJournal.swift`:

- `TabStateJournalEntry: Codable, Equatable, Sendable` with `seq: Int`,
  `timeNs: UInt64`, `tabId: String`, `kind: String` (`"state"` or `"note"`);
  state entries carry `isSelected: Bool`, `status: String`, and
  `metadata: TabTitleMetadata?`; note entries carry `note: String?` and
  `text: String?`.
- `TabStateJournal` (final class, internal lock): bounded append-only ring
  (capacity 4096, trim from front), monotonic `seq` that keeps counting after
  trimming so `since` cursors stay valid.
  - `recordDiff(tabs:activeTabId:)` — compares each tab's projection
    (status + isSelected + metadata, all `Equatable`) against the last
    recorded projection; appends one `state` entry per changed tab; evicts
    last-known state for closed tabs; returns the appended entries so the
    caller can mirror them to a running capture.
  - `note(tabId:note:text:)` — appends a `note` entry (e.g. `banner.posted`).
  - `snapshot(since:tabId:)` — entries with `seq >= since`, optional tab
    filter, plus `next` cursor.
  - `dump(to:)` — writes `tab-journal-<stamp>.ndjson`, one entry per line.

`AppModel` gains `public let tabJournal = TabStateJournal()` and calls
`recordTabJournal()` from both notify funnels; that helper snapshots `tabs`
(model lock), diffs into the journal, and mirrors each new entry to
`captureSink` as a `CaptureTimelineEvent(kind: .tabMetadata)`.
`CaptureEventKind` gains `tabMetadata = "tab.metadata"`;
`CaptureTimelineEvent` gains `urgent/count/selected/note` optionals (it
already has `title`, `status`, `text`, `tabId`).

Queryability:

- `GET /debug/tab-journal?since=N&tabId=…` (new
  `Sources/LabanDebug/DebugTabJournalEndpoints.swift`, route registered in
  `DebugHTTPServer.swift`, schema `schemas/debug/tab-journal.schema.json`
  modeled on `events.schema.json`).
- Debug menu "Dump Tab Journal" in `Sources/LabanApp/MenuCommands.swift`,
  writing via `tabJournal.dump` under `RenderJournal.defaultDumpRoot()`.
- Banner notes: the `onAgentNotification` consumer in
  `MainWindowController.swift` journals `banner.posted` /
  `banner.suppressed.frontmost`; `HeadlessDebugRuntime` journals the same in
  its parity wiring.

### Part B — earlier "needs you" from the title marker

Claude Code's terminal title is a live status: a braille spinner
(`⠂ Claude Code`) while working, and `✳ <label>` from the instant it waits
for the user.

**Discovery (changed the design):** Laban already has a stateless attention
system — `TabAttentionClassifier` (`Sources/LabanCore/TabAttention.swift`)
derives a per-tab attention level (`none`/`passive`/`done`/`needsAction`)
purely from `TabTitleMetadata` at render time, and already treats Codex's
`[ ! ]` title prefix as `needsAction` (`hasActionRequiredTitle`). The
sidebar marker, row tint, and attention pulse all flow from it, and it
clears the instant the title flips back or the tab is focused. So:

- **Sidebar (stateless):** add Claude Code's leading `✳` to
  `TabAttentionClassifier` via `awaitingInputTitleMarkers`, matched inside
  the now-public `hasActionRequiredTitle`. The background tab's `needsAction`
  marker appears the moment the title flips — no badge mutation, no episode
  state, instant clear on flip-back/focus.
- **Banner (edge-triggered, episodes):** `AppModel.detectAwaitMarkerTransitions`
  (called from `runSurfaceMetadataSync` whenever a sync changed the model —
  the chokepoint both the local parse and laband poll paths cross) keeps
  `awaitEpisodeByTab` keyed on the same `hasActionRequiredTitle` predicate.
  Title gains a marker → post `onAgentNotification("Awaiting your input")`
  once, unless the user is watching the tab (`AppModel.isTabFrontmost`,
  wired in `MainWindowController` to the same app-active + tab-selected
  closure the banner poster uses; headless wires `{ _ in false }`) or the
  restore-suppression window is open. The agent's own debounced OSC
  notification arriving during a covered episode applies the badge as
  normal but skips the second banner
  (`AgentNotificationOutcome.appliedBannerAlreadyPosted`).
  The `TabNotification` badge is deliberately untouched by episodes — it
  stays owned by real notifications, so all existing badge semantics
  (count accumulation, seen-clearing) are unchanged.

The marker match is a deliberate heuristic on Claude Code's title
convention, scoped to the leading scalar of the OSC-supplied terminal title.
No feature flag; reverting the commit is the kill switch. This also gives
Codex `[ ! ]` waits a banner for the first time (it never sends OSC 9 in
unrecognized terminals), which is consistent rather than accidental.

## Progress

- [x] Diagnosis: capture analysis pinpointing the 6s upstream debounce
- [x] ExecPlan written
- [x] A1: `TabStateJournal` + entry model + unit tests
- [x] A2: AppModel funnel integration + capture mirroring (`tab.metadata`)
- [x] A3: `/debug/tab-journal` endpoint + schema
- [x] A4: Debug menu dump + banner notes (app + headless parity)
- [x] B1: classifier ✳ marker + banner episodes + OSC banner dedupe
- [x] B2: unit tests for classifier/episodes/dedupe/suppression
- [x] E2E: `TabAttentionEndToEndTests` (needsAction on flip; banner once;
      OSC dedupe; journal ordering; `/debug/tab-journal` cursor)
- [x] Docs: dev-process.md artifact shape + endpoint; observability.md signal
- [x] Full build (`./scripts/build-app`) + test suite green (1570 tests, 0
      failures, 2026-06-12)
- [ ] Manual validation in the installed app (user-driven: real Claude Code
      AskUserQuestion turn, banner at title-flip time, no duplicate)

## Validation and Acceptance

1. `swift test --filter TabStateJournalTests` — diff/dedupe, ring bound,
   cursor, eviction tests pass.
2. `swift test --filter AppModelTests` — journal entries on notification
   mutations; synthetic raise once per episode; real OSC dedupe; flip-back
   clears synthetic-only unseen badge; restore suppression honored.
3. `swift test --filter TabAttentionEndToEndTests` — real-shell headless
   runtime: child prints spinner title then `✳` title; `/debug/tab-journal`
   shows a state entry whose metadata carries the urgent notification, with
   `timeNs` within 2s of the title bytes; a following OSC 777 produces no
   second banner event and no count bump; with a capture running,
   `timeline.ndjson` contains `tab.metadata` events.
4. Manual: install (`scripts/install-app`), run a Claude Code question turn,
   background the window — banner arrives at title-flip time (not +6s);
   Debug ▸ Dump Tab Journal writes an ndjson whose badge entry timestamp
   matches; the agent's later OSC adds no duplicate banner.

## Surprises & Discoveries

- `TabAttentionClassifier` already implements stateless title-marker
  attention (Codex `[ ! ]`) with sidebar pulse integration and render-loop
  parking (`anyNeedsAction`). The first Part B draft (synthetic
  `TabNotification` + stale-clear logic) duplicated this poorly and was
  reworked to extend the classifier instead; episodes now exist only for the
  edge-triggered banner. Lesson: search for an existing classifier before
  adding stateful attention.
- Title changes do NOT pass the `notifyWorkspaceMutation` /
  `notifySurfaceStateChanged` funnels on the local path — they land inside
  the frame loop's `syncSessions` cluster via `runSurfaceMetadataSync`. The
  journal therefore records from that chokepoint too, not just the funnels.

- First live journal inspection (dump 2026-06-12T120015007Z, 739 entries /
  27.5 min) found a pre-existing bug the capture pipeline never showed: ~40
  `banner.posted` notes inside the first 200ms of a relaunch. Restored agents
  re-emit their OSC notifications on resume; the grace window suppressed the
  *badges* (`.ignored`) but `attachOSCNotification` fired the banner
  broadcast unconditionally, posting a burst of stale macOS notifications at
  every launch. Fixed by broadcasting only on `.applied`. The same dump
  verified the merge dedupe and stale-badge retirement working in production,
  and explained a "needs you ×2" badge as two genuinely-unseen notifications
  (PR-merged + waiting-for-input) — honest accumulation, not a bug.

## Decision Log

- Journal is **always on** (no defaults gate, unlike `RenderJournal`):
  entries are transition-driven and small; post-hoc diagnosability is the
  feature. Bounded at 4096 entries.
- Journal records at the two notify funnels rather than per-mutator hooks:
  the funnels are exactly the UI-invalidation signal, so "journal entry" ≡
  "what the tab showed changed"; diff-dedupe makes double-notify harmless.
- ~~Earlier needs-you splits by nature of the signal: the *sidebar* level is
  a pure function of metadata (extend `TabAttentionClassifier`, zero state),
  while the *banner* is an edge-triggered side effect.~~ **Reversed
  2026-06-12 after dogfooding**: unlike Codex's transient `[ ! ]`, Claude
  Code's `✳` is the *resting* title of every idle agent tab, so the
  stateless classifier rule turned every restored tab yellow on relaunch
  (no restore-grace) and re-yellowed viewed tabs the moment they were
  backgrounded again (no seen-memory — "viewing" doesn't change the title).
  Now the flip is treated purely as an edge: it raises the urgent
  `TabNotification` badge (classifier already maps that to needsAction) and
  posts the banner, both behind `isTabFrontmost` + restore-grace; viewing
  clears the badge and it stays cleared; a flip back to working retires an
  unseen synthetic badge; the agent's own OSC merges into the badge (text
  refresh, no count bump, no second banner). The classifier keeps only the
  `[ ! ]` rule, which is safe statelessly because Codex removes it when
  unblocked.
- Marker detection lives in AppModel after metadata sync (not in the C title
  scanner): it must see the post-resolution `terminalTitle` regardless of
  whether the title arrived via local parse or the laband daemon poll.
- The synthetic banner broadcast hops to the main queue (matching the real
  OSC path and `onAgentNotification`'s documented contract). A synchronous
  broadcast deadlocked the headless runtime: `state()` holds the runtime
  `NSLock` through the sync pass, and the headless notification consumer
  re-takes that same lock.
- OSC 777 badge text is "Title: body" (the parser folds the notify title
  in), e.g. "Claude Code: Claude needs your permission" — tests must match
  the folded form.
