# Split Panes: Two Terminals Side by Side in One Tab, Backed by Stable Session IDs

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that
will help a fresh contributor.

Revision 3 (2026-09-28). Revisions 1 and 2 were reviewed by an independent
advisor before any code was written; the findings that changed the plan are
recorded in `Decision Log` and `Surprises & Discoveries`.

## Purpose / Big Picture

Today a Laban tab shows exactly one terminal. After this change a user can
press **Cmd+D** to split the current tab vertically: the terminal area is
divided into a left and a right half, each running its own shell, each with
its own scrollback, cursor and process. Clicking in a half or pressing
**Cmd+Option+] / [** moves keyboard focus between the halves. **Cmd+Shift+D**
closes the focused half and gives its space back to the survivor. Quitting and
relaunching Laban brings both halves back, still running, exactly as single
terminals do today, because each half is an ordinary background session in
the `labpty` daemon.

This is the first milestone of the long-term direction in
`docs/product/spec.md` ("split panes backed by stable session IDs", first
under "Later Milestones" in `docs/product/mvp.md`). It builds the **real data
model** from spec sections 3, 5 and 8 (a recursive pane tree that stores only
session IDs, and a focused-pane concept) while shipping only the smallest
user-visible slice on top of it: one vertical split per tab, a fixed 50/50
divider, no drag, no nesting, no horizontal splits. Those follow in later
plans; nothing here has to be undone for them.

You will know this works when, in the running app, Cmd+D on a fresh tab shows
two prompts side by side separated by a one-pixel divider, typing goes only to
the focused half, the bundled `laban` CLI lists two sessions for that tab with
the focused one marked, and after Cmd+Q and relaunch both halves show the same
content and the same running processes.

### Term glossary (plain language, used throughout this plan)

- **Tab**: one row in the left sidebar. Type `Tab` in
  `Sources/LabanCore/Tab.swift`. Today it has a single stored `sessionId`.
- **Session**: one shell process with its own PTY, parser state and
  scrollback. Type `Session` in `Sources/LabanCore/Session.swift`; `Session.ID`
  is a `String`. Sessions live in `SessionRegistry`
  (`Sources/LabanCore/SessionRegistry.swift`), keyed by ID.
- **PTY** (pseudo-terminal): the kernel object a shell reads keystrokes from
  and writes output to. Resizing a PTY is the `TIOCSWINSZ` system call; the
  shell then receives the `SIGWINCH` signal and redraws. Closing the PTY sends
  the shell `SIGHUP`, which normally makes it exit.
- **libghostty**: the C library (vendored under `.external/`) that turns the
  bytes a shell writes into a grid of cells. "Reflow" is libghostty
  re-wrapping lines when the column count changes.
- **Pane**: one rectangular region of a tab's terminal area that displays one
  session. New concept introduced by this plan. A pane is identified by the
  session ID it displays; there is no separate pane ID.
- **Pane tree**: pure data describing how a tab's terminal area is divided.
  A leaf holds a session ID; a split holds an axis, a fraction and two child
  trees. New type `PaneTree`, this plan.
- **Focused pane**: the pane in the active tab that receives keyboard input.
  New concept; stored per tab as `focusedSessionId`.
- **labpty**: the tiny per-user daemon (`Sources/Labpty/`, C) that owns PTY
  master file descriptors so shells survive app restarts. It identifies a
  session by a caller-chosen string, the **logical session ID**. labpty is not
  modified by this plan.
- **laband**: the optional larger daemon (`Sources/Laband/`) that runs
  libghostty out of process and serves rendered snapshots. Also not modified.
  Which daemon (or none) is in use is the **terminal backend**, chosen in
  Settings → Terminal Sessions (`AppKitTerminalBackend`: `inProcess`,
  `laband`, `labpty`).
- **AppSessionCoordinator**: the app-side object
  (`Sources/LabanApp/AppSessionCoordinator.swift`) that opens, reattaches,
  resizes and writes to daemon sessions. Today most of its maps are keyed by
  tab ID and it passes the tab ID as the daemon's logical session ID.
- **TerminalBitmapView**: the single AppKit view per window
  (`Sources/LabanApp/TerminalBitmapView.swift`, ~9900 lines) that draws the
  sidebar and the terminal area into one Metal surface and receives all
  keyboard and mouse input. There is no per-tab view.
- **TerminalSurfaceController**: the pure-Swift frame builder
  (`Sources/LabanCore/TerminalSurfaceController.swift`) that turns a
  `TerminalSurfaceFrameRequest` into a `TerminalSurfaceFrame`: a list of
  `FrameCommand` draw instructions plus, on the GPU path, one **cell payload**
  (a packed buffer of the whole grid that `Sources/LabanRenderer` uploads
  directly). It currently draws one terminal at a fixed origin
  `sidebarWidth + insets.left`.
- **Headless runtime**: `Sources/LabanDebug/HeadlessDebugRuntime.swift`, the
  windowless twin of `TerminalBitmapView` used by CI and agents. The repo's
  standing rule is that it must stay in feature parity with the visible app.
  It supports the `inProcess` and `laband` backends only; it has no labpty
  path.
- **Control plane**: the local HTTP-over-Unix-socket API (`/debug/state`,
  `/debug/actions`, …) described by `schemas/debug/*.json`. Intents are
  declared in `Sources/LabanCore/Intents/IntentCatalog.swift`; each has an
  **availability** (`headlessOnly`, or also `gui:true`) and a **required
  capability** (`.observe`, `.navigate`, `.input`, …). GUI-available intents
  are implemented in `Sources/LabanApp/Control/LiveIntentRouter.swift`;
  headless ones in `Sources/LabanDebug/DebugRuntimeRequests.swift` and the
  `Debug*Actions.swift` files next to it. `schemas/debug/discovery-endpoints.json`
  is **generated** by `swift run LabanControlGen --write` and checked by
  `./scripts/check`; never hand-edit it.
- **Workspace state**: the JSON file `workspace.json` written at quit and read
  at launch (`Sources/LabanCore/Persistence/WorkspaceState.swift`,
  `PersistenceStore.swift`). Today each tab is a flat `TabState` with one
  implied session.
- **Focus reporting (DECSET 1004)**: a program can ask the terminal to send
  it a short escape sequence when the terminal gains or loses keyboard focus.
  Laban sends these when the active tab changes
  (`lastReportedFocusBySession` in `TerminalBitmapView`).
- **IME / preedit**: when typing Chinese, Japanese or Korean with a macOS
  input method, the not-yet-committed text ("marked text" or "preedit") is
  drawn underlined at the cursor. Only one pane can be composing at a time.
- **Transcript**: a per-session file of raw output bytes under
  `transcripts/`, written by `TranscriptHost`
  (`Sources/LabanCore/Persistence/TranscriptHost.swift`) for diagnostics and
  the debug "cast" endpoint. Today it is keyed by tab ID.
- **Dirty generation**: a counter each `Session` increments whenever its grid
  content changes. The frame loop compares it with the last value it drew
  (`lastSyncedGeneration` in `TerminalSurfaceController.swift:589`) and skips
  work when unchanged. A restored session that reuses an ID and starts at the
  same counter value is therefore invisible to the frame loop unless the
  cache is cleared.
- **MRU**: most recently used. A per-tab list of pane session IDs ordered by
  when they were last focused, so closing a pane can return focus to the one
  the user was in before.
- **Session-scoped control access**: a control-plane client (an agent) may
  hold a token that is scoped to one session ID (ADR 0024). Projections such
  as `filteredTabs` in
  `Sources/LabanCore/Control/Projections/ControlStateProjections.swift:427-432`
  then show only the tab that contains that session.
- **Present-link (ADR 0026)**: the renderer rule that a frame is presented
  to the screen only through the display link, never synchronously from the
  frame builder. Not changed here; cited because renderer edits must respect
  it.

## Progress

- [x] M0 (2026-09-28; baseline `./scripts/check` passed): Stable session identity. Session IDs are persisted and injectable;
      a tab's first session ID equals the tab ID; daemon logical IDs are
      session IDs everywhere (GUI and headless); launch-time
      ensure/sweep/unclaimed use the set of all session IDs. ADR 0036 written.
- [x] M1: `PaneTree` value type + tests (LabanCore, no UI).
- [x] M2: `Tab` carries `panes` + `focusedSessionId`; stored `Tab.sessionId`
      deleted; session-level lifecycle hooks; per-tab runtime maps re-keyed
      by session; `AppModel.splitPane/closePane/focusPane`.
- [x] M3: Persistence schema v2 (`PaneState`), v1 migration, per-tab decode
      fallback, transcripts keyed by session; restore round-trip tests.
- [x] M4: Headless control plane: `pane.split`, `pane.close`, `pane.focus`
      intents (headless-only), state projection + schema, discovery regen,
      parity tests. Needed before any rendering test can drive a split.
- [x] M5: Per-session terminal size; resize on split/close/tab switch; spawn
      size for a new pane.
- [x] M6: Multi-pane rendering (draw-command path), all visible panes dirty
      and marked rendered, divider, unfocused cursor, per-pane selection,
      preedit in focused pane; GUI falls back from cell payload when split;
      laband backend refuses splits.
- [x] M7: Input routing: focus follows click, per-pane mouse/selection/IME
      geometry, focus reports on pane change, scroll wheel to pane under
      pointer, scroll indicator and find chip follow focus.
- [x] M8: GUI commands: menu items, shortcuts, `AppCommand` cases, error
      surfacing; localisation strings.
- [x] M9 (2026-09-28 15:26Z independent full re-review: direct E2E, both child-survival restart tests, and persistence relaunch passed): E2E: headless scenario in `scripts/test-e2e`; labpty restart test
      with a split tab in `Tests/LabanAppTests/LabanAppTests.swift`.
- [x] M10 (2026-09-28 15:26Z complete independent Review Gate passed on `8994441a`): Docs: `docs/product/mvp.md` Later Milestones, `dev-process.md`
      endpoint list; Review Gate.

### PR review follow-up (2026-09-28)

- [x] R1: Aggregate pane attention without changing focused metadata or journal identity; acknowledge all visible panes and retire per-session caches.
- [x] R2: Preserve background restore sizes and retry attach registration by session identity; handle duplicate workspace session IDs safely.
- [x] R3: Route right-button gestures to their originating pane, honor synchronized output in every visible pane, and clear stale selection/find presentation on focus.
- [x] R4: Reject final-pane close consistently; repair explicit-session headless actions, resize/focus reports, and pane-sized casts.
- [x] R5: Strengthen real-shell E2E and missing restore/router/coordinate tests; correct unsupported downgrade claims and remaining presentation defects.
- [x] R6: Independent regressions, E2E, restart and mutation checks passed in the earlier review. Its bounded full-gate loop stopped after an adoption timeout; the fresh repository check under R10 now passes. The historical timeout remains documented below.

### Second PR re-review follow-up (2026-09-29)

- [x] R7: Preserve per-pane capture snapshots and replay split captures, including capture started after splitting.
- [x] R8: Cache a new pane's dimensions even when its tab is in the background; verify cast dimensions before tab selection.
- [x] R9: Keep left-button drag and release bound to the pane receiving the press, including a keyboard focus change.
- [x] R10: All 173 targeted regression tests and the uncached repository check passed at `861144d9`; independent source review found no unresolved issues. Evidence: `.artifacts/split-panes/second-review-fixes/`.

## Decision Log

- Decision: Split capture snapshots use frame-plus-hashed-session filenames and optional per-pane presentation on their timeline events. Terminal replay rebuilds each pane from its own PTY stream and combines their recorded geometry and visual settings; session creation records the initial grid. Legacy creation events fall back to the latest resize dimensions.
  Rationale: Frame-only snapshot names overwrite sibling snapshots. Pane dimensions, cursor styles and opacity cannot be reconstructed from the focused terminal alone. Optional fields preserve old capture decoding, including tabs opened after a resize.
  Date/Author: 2026-09-29 / PR re-review follow-up.

- Decision: Build the recursive `PaneTree` from spec section 3 now, even
  though this plan only ever produces a tree of depth one.
  Rationale: The alternative considered was representing the second pane as
  a hidden `Tab` so that every tab-keyed map keeps working. That saves only
  the re-keying (mechanical, well-tested) while forcing every tab-enumerating
  code path (sidebar, `moveTab`, Ctrl-Tab cycling, tab journal, restore
  ordering, CLI listing, `/debug/state` tab counts) to skip hidden tabs, all
  of which is thrown away when the real tree lands. Rendering, per-session
  sizing and pointer geometry cost the same either way.
  Date/Author: 2026-09-28 / plan author.

- Decision: A pane has no ID of its own; it is identified by the session ID it
  shows. Restarting an exited pane (a later plan) reuses the same session ID
  with a new process, matching spec section 5's "generation" idea.
  Rationale: Spec section 5 says the tree "only stores session IDs". A
  separate pane ID would be a second stable identifier persisted for no
  reader. One session is shown in at most one pane. Invariant, asserted in
  debug builds and tested: the set of IDs in `SessionRegistry` equals the
  union of all tabs' leaf IDs.
  Date/Author: 2026-09-28 / plan author.

- Decision: **Every** tab's first session ID equals the tab ID, for new tabs
  and for migrated ones; further panes mint fresh UUIDs. The daemon logical
  session ID is always the session ID.
  Rationale (revised after advisor review): Session IDs are minted fresh on
  every launch today (`ControlSessionLaunchCoordinator.prepareLaunch`,
  `Sources/LabanApp/Control/ControlSessionLaunchCoordinator.swift:33`;
  restore builds `Session.fixture(size:)` with a random ID at
  `Sources/LabanApp/MainWindowController.swift:365-367`), and tab ID ≠
  session ID already (`AppModel.swift:305-311`). The daemon key is the tab ID
  only because the coordinator passes `tab.id`. Making the first session ID
  equal the tab ID for every tab means: an unsplit tab keeps exactly today's
  daemon key, so pre-upgrade daemon sessions reattach, an older binary can
  still read a v2 workspace for unsplit tabs, the launch-time "unclaimed
  labpty sessions" check needs only its known set widened, and the adopt path
  keeps working. Revision 1 applied this only to migrated tabs, which would
  have made every relaunch offer to adopt every post-upgrade tab.
  Date/Author: 2026-09-28 / plan author, after advisor review.

- Decision: Delete the stored `Tab.sessionId`; do not replace it with a
  computed property. Add `focusedSessionId` and `allSessionIds`.
  Rationale (revised): revision 1 proposed a computed `sessionId` returning
  the focused session so ~121 read sites in 24 files kept compiling. The
  advisor showed two of them would silently break: `tabIndexUnlocked(forTab:sessionId:)`
  (`AppModel.swift:1636-1648`) matches `tab.sessionId == sessionId`, so
  metadata from the unfocused pane would be dropped, and the `attach*`
  callbacks would mark the whole tab exited when the unfocused shell exits.
  A deleted field makes the compiler list every site so each gets an explicit
  "focused" or "all" decision.
  Date/Author: 2026-09-28 / plan author, after advisor review.

- Decision: labpty and laband are not modified.
  Rationale: Every labpty RPC is already per session (open, list, resize,
  write, attach, detach, terminate) keyed by logical session ID; resize is a
  per-session `TIOCSWINSZ`. Pane layout is view state and must not leak into
  the process ADR 0006 says must not churn. Capacity: `LABPTY_MAX_SESSIONS` is
  64 (`Sources/Labpty/include/labpty_internal.h:53`) and splits consume
  sessions faster. The app does **not** pre-count (the list omits sessions
  mid-teardown, and other Laban instances share the daemon); it handles the
  open failure from `openSession` and reports it. Raising the cap is a
  separate additive change.
  Date/Author: 2026-09-28 / plan author.

- Decision: Keep one `TerminalBitmapView` per window and render all panes into
  the single Metal frame at different origins. When a tab is split, the GUI
  uses the draw-command path (`canSkipTerminalCommands = false`) instead of
  the GPU cell payload; single-pane tabs are unchanged.
  Rationale: The sidebar is drawn inside the same frame, so per-pane NSViews
  would first require extracting the sidebar. The hover preview
  (`hoverPreviewOverlayCommands`) already draws a second session at an
  arbitrary origin in one frame. The cell payload
  (`TerminalSurfaceFrame.cellPayload`, one grid per frame,
  `TerminalSurfaceController.swift:270-290`; consumed by
  `RendererBackend.render(_:cellPayload:)`) is single-grid by contract, and
  `.cellPayloadPreferred` skips terminal draw commands entirely
  (`TerminalSurfaceController.swift:1193-1198`). Multi-payload rendering is
  a renderer change with its own ADR (0026 present-link, 0032 Slug default
  apply) and is deferred; the draw-command path is the pre-0032 production
  path and is what headless already tests. Measure the frame cost of a split
  tab in the perf trace loop and record it in `Surprises & Discoveries`.
  Date/Author: 2026-09-28 / plan author, after advisor review.

- Decision: The `laband` backend refuses `pane.split` with error
  `unsupportedBackend` in this plan.
  Rationale: laband rendering goes through `snapshotFrame(for: activeTab)`
  and `makeFrame(remoteSnapshot:)`, which take exactly one remote snapshot per
  frame (`TerminalBitmapView.swift:2099, 3829-3840, 4281`;
  `TerminalSurfaceController.swift:1254`). Supporting two remote snapshots
  per frame is real work with no user waiting for it; labpty is the shipped
  default tier. The refusal is explicit so the headless laband scenarios stay
  green and the gap is visible in `/debug/state`.
  Date/Author: 2026-09-28 / plan author, after advisor review.

- Decision: Focus after `closePane` goes to the most recently focused
  surviving pane (per-tab MRU list), per spec section 8.
  Rationale: cheap (two entries at depth one), and avoids a documented
  divergence from the spec.
  Date/Author: 2026-09-28 / plan author.

- Decision: Cmd+W keeps its meaning "close tab" and closes every pane in the
  tab. Cmd+Shift+D ("Close Pane") is disabled when the tab has one pane
  (spec section 10: inapplicable commands disable rather than fall through).
  Rationale: changing Cmd+W is a shipped-behaviour change under
  `docs/product/mvp.md` and would need spec approval; a disabled menu item is
  the spec's own pattern.
  Date/Author: 2026-09-28 / plan author.

- Decision: `pane.*` intents are `headlessOnly`, like `tab.new`, `tab.close`
  and `tab.select`. GUI users get menu commands; agents driving the GUI get
  nothing new.
  Rationale: `Tests/LabanAppTests/CatalogParityTests.swift:119-145` pins that
  no GUI intent requires `.input` and that the GUI `.navigate` set is exactly
  `notifications.test` and `terminal.scrollViewport`. Those allowlists
  encode the control-plane threat model (ADR 0024) and are not changed here.
  Date/Author: 2026-09-28 / plan author, after advisor review.

- Decision: The divider is fixed at fraction 0.5 and not draggable. The
  `fraction` field exists in the tree and is persisted so a later plan adds
  the drag gesture without a schema change. The divider occupies the pixel
  column at `floor(width * fraction)`; the first pane gets columns
  `[0, floor(width*fraction))`, the second `[floor(width*fraction)+dividerWidth, width)`.
  Date/Author: 2026-09-28 / plan author.

- Decision: When one pane's shell exits, the pane stays open and shows the
  exited banner that `FrameProducer` already draws per session from the
  snapshot (`Sources/LabanCore/FrameProducer.swift:560`); the tab's own
  status, title, progress and cwd come from the **focused** pane only and are
  **re-derived whenever focus changes** (a `refreshTabMetadata(fromFocused:)`
  step in `focusPane`), so focusing an already-exited pane flips the tab to
  exited. Attention (bell, unseen output) from any pane marks the tab,
  including panes of background tabs.
  Rationale: closing the pane automatically would lose the exit output.
  Tab-level metadata must come from one session or it flickers between two;
  focused is what the user is looking at. Without the re-derive step the
  focus filter on `attach*` would drop the exit event at the moment it fires
  and the tab would say "running" forever.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: `Session.ID` stays a `String`; the plan contains the resulting
  tab-ID/session-ID confusion with tests rather than a new type.
  Rationale: because a tab's first session ID equals the tab ID, passing a
  tab ID where a session ID is expected (for example
  `Sources/LabanDebug/DebugCastEndpoints.swift:23-32`) works until the first
  pane is closed, then fails. Every such site is a latent bug that no
  ordinary test sees. A distinct `SessionID` wrapper type would make the
  compiler find them but touches the frozen labpty client protocol types and
  ~30 files; it is deferred to a follow-up and noted in ADR 0036. Instead M2
  adds a **"close the first pane, exercise the survivor"** test family
  (typing, resize, cast endpoint, transcript, find, persist and restore,
  agent detection) that fails on any such confusion.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: Session-keyed caches are cleared whenever sessions are replaced
  wholesale (`AppModel.closeAllSessions` / `replaceTabs`), not only on the
  view's per-tab create/close path.
  Rationale: with stable IDs, an in-process relaunch
  (`DebugPersistenceEndpoints.persistenceRelaunch`,
  `Sources/LabanDebug/DebugPersistenceEndpoints.swift:83-104`) restores a
  session with the same ID and the same dirty generation as before; the
  frame loop's `lastSyncedGeneration` (`TerminalSurfaceController.swift:589`,
  cleared today only from `TerminalBitmapView.swift:5698/5733`) would skip it
  and show a stale frame. The plan's new `lastSentSizeBySession` has the same
  hazard.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: Persisted attach approvals now survive an app restart for the
  same daemon shell, because approvals match on session ID
  (`Sources/LabanControl/ControlAttachApprovalStore.swift:106`) and session
  IDs are now stable. This is accepted and recorded in ADR 0036 as an
  amendment to the ADR 0024 threat model.
  Rationale: the approval was for "this shell"; the shell is the same one.
  Making approvals launch-scoped again would need a launch nonce in the
  record, which is a separate change if wanted.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: For a session-scoped control client, tab projections are
  **per pane**: `filteredTabs` returns the tab containing the scoped session,
  the tab's title/cwd/process/status/attention fields are taken from the
  scoped session (not the focused one), scoped `activeSessionId` equals the
  scoped ID, and `window.screenshot` is denied with `sessionNotVisible` when
  the tab is split (even if the scoped pane is visible).
  Rationale: "focused" would hide an agent's own tab whenever the other pane
  has focus; "all" would leak the other pane's title, cwd and screen to a
  token that was approved for one session only (ADR 0024). Cropping a
  screenshot to the pane is possible but not needed by any caller yet.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: `tabs[].sessionId` stays in the control-plane state object as an
  optional, deprecated alias equal to `focusedSessionId`.
  Rationale: existing readers (`Tests/LabanAppTests/LiveControlObserveTests.swift:427`,
  `Tests/LabanDebugTests/GetTextEndpointTests.swift:14`,
  `docs/process/dev-process.md:328`, `Sources/LabanAgent/main.swift:877`)
  break otherwise, and the workspace file keeps its flat fields for the same
  reason. The schema marks it optional; removal is a later cleanup.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: Under the `laband` backend a restored split tab keeps its tree
  and renders its **focused pane only**, full width, with a one-line notice
  in the pane ("Split view is not available on the laband backend"); no
  assertion. `pane.split` is still refused there.
  Rationale: the Terminal Sessions menu restarts the app and restores the
  workspace under the new backend
  (`Sources/LabanApp/TerminalBackendMenuController.swift:94-132`), so a
  split workspace **will** be opened under laband; an assert would crash the
  restore.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: The workspace file's flat `TabState` fields describe the pane
  whose session ID equals the tab ID (the first-created pane), not the
  focused pane.
  Rationale: an older binary reattaches daemon ID `tab.id`; if the flat
  fields described a different pane, that binary would show one shell with
  another shell's cwd and agent metadata. If the first-created pane has been
  closed, the flat fields describe the focused pane and the older binary
  spawns a fresh shell, which is the same as today's behaviour for a missing
  daemon session.
  Date/Author: 2026-09-28 / plan author, after advisor review (rev 3).

- Decision: Retain the single-pane frame request initializer's selection and preedit fields as a compatibility adapter; explicit pane requests own per-pane values for split rendering. Existing single-grid tests and screenshot callers keep their current API.
  Rationale: Removing those initializer arguments would churn unrelated renderer clients without strengthening split isolation. The split path always consumes pane-local selection and composition.
  Date/Author: 2026-09-28 / implementation.

- Decision: The dirty-render mutation gate disables unfocused visible sessions using `session.id == activeSessionId`. Its originally specified `tabId == activeTabId` check is correct once enumeration includes every leaf, so cannot demonstrate a regression. Production now uses `item.isVisible` to express that invariant directly.
  Date/Author: 2026-09-28 / implementation.


## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed. See "Review gate and review-fix loop" in
`PLANS.md`. All commands run from the repository root. `BASE` is the commit
this plan branched from; the executing agent records it here before M0:
`BASE = f145b0a6`.

- [x] `git diff --stat $BASE -- Sources/Labpty Sources/Laband` prints nothing.
- [x] `grep -rn "let sessionId: Session.ID\|var sessionId: Session.ID" Sources/LabanCore/Tab.swift` prints zero hits; `grep -c "focusedSessionId" Sources/LabanCore/Tab.swift` prints at least `2`.
- [x] `swift test --filter PaneTreeTests` exits 0 with at least 8 tests passed.
- [x] `swift test --filter AppSessionCoordinatorTests` exits 0 and output contains `testSplitTabOpensTwoDistinctLogicalSessions` and `testResizeSendsDifferentSizesPerSession`.
- [x] `swift test --filter PersistenceRoundTripTests` exits 0 and output contains `testV1WorkspaceMigratesToSingleLeafTree`, `testSplitTabRoundTrips` and `testCorruptPaneTreeFallsBackPerTab`.
- [x] `swift test --filter AppModelTests` exits 0 and output contains `testRegistryEqualsUnionOfLeaves`, `testUnfocusedPaneExitDoesNotChangeTabStatus` and `testClosePaneFocusesMostRecentlyFocusedSurvivor`.
- [x] `swift test --filter SplitPaneHeadlessTests` exits 0 and output contains `testTwoPanesRenderAtDistinctOrigins`, `testOutputInUnfocusedPaneMarksFrameDirty` and `testBothPanesWriteTranscripts`.
- [x] `swift test --filter CatalogParityTests` exits 0, and the only diff in `Tests/LabanAppTests/CatalogParityTests.swift` is the required `Tab.sessionId` → `focusedSessionId` reference migration (allowlists unchanged).
- [x] `swift run LabanControlGen --check` exits 0.
- [x] `python3 -c "import json;s=json.load(open('schemas/debug/state.schema.json'));t=s['\$defs']['tab'];assert 'panes' in t['required'] and 'focusedSessionId' in t['required'] and 'sessionId' not in t['required'] and 'sessionId' in t['properties']"` exits 0.
- [x] `./scripts/test-e2e` exits 0 and stdout contains `split-pane scenario: ok`.
- [x] `./scripts/test-labanapp-survives-restart` exits 0 and `grep -n "func testSplitTabSurvivesLabanAppRestartViaLabpty" Tests/LabanAppTests/LabanAppTests.swift` prints one hit.
- [x] `swift test --filter HeadlessRestoreInjectionTests` exits 0 and output contains `testSplitTabSurvivesPersistenceRelaunchWithLiveFrame`.
- [x] `swift test --filter SurvivorPaneTests` exits 0 and output contains `testTypingAfterFirstPaneClosed`, `testCastEndpointAfterFirstPaneClosed`, `testTranscriptAfterFirstPaneClosed`, `testFindAfterFirstPaneClosed`, `testRestoreAfterFirstPaneClosed`, `testResizeAfterFirstPaneClosed`, `testAgentDetectionAfterFirstPaneClosed`.
- [x] `swift test --filter LiveControlObserveTests` exits 0 and output contains `testScopedClientSeesOwnPaneMetadataInSplitTab` and `testScopedScreenshotDeniedInSplitTab`.
- [x] `swift test --filter LabandSplitRestoreTests` exits 0 and output contains `testSplitWorkspaceRestoresFocusedPaneUnderLaband`.
- [x] `./scripts/check` exits 0 (uncached follow-up at `861144d9`, 2026-09-29).
- [x] `ls docs/adr/0036-pane-layout-is-view-state-above-session-tiers.md` succeeds and `grep -c "0036" docs/adr/README.md` prints at least `1`.
- [x] Mutation: in `Sources/LabanCore/PaneTree.swift`, make `removing(leaf:)` return the removed child instead of the survivor; run `swift test --filter PaneTreeTests`; expect a failure naming `testRemoveLeafCollapsesToSurvivor`; revert.
- [x] Mutation: in `Sources/LabanCore/TerminalSurfaceController.swift`, force every pane's origin to the first pane's origin; run `swift test --filter SplitPaneHeadlessTests`; expect `testTwoPanesRenderAtDistinctOrigins` to fail; revert.
- [x] Mutation: in `TerminalSurfaceController.syncSessions`, replace the `item.isVisible` dirty check with `session.id == activeSessionId`; run `swift test --filter SplitPaneHeadlessTests`; expect `testOutputInUnfocusedPaneMarksFrameDirty` to fail; revert.

Follow-up validation (2026-09-29): R7–R10 pass at source commit `861144d9`. All 173 targeted tests passed, and an independent source review found no unresolved findings. `LABAN_CHECK_NO_MEMO=1 ./scripts/check` exited 0, including the previously failing adoption case, coverage (45.90% MC/DC against the 45% floor), sanitizer tests, runtime smoke and the split-pane E2E scenario. Optional TLA+/CBMC tools were unavailable and MSan is unsupported on macOS; the repository check applied its normal skip policy. Evidence: `.artifacts/split-panes/second-review-fixes/targeted-final.log`, `check-final.log` and `summary.json`. The complete independent mechanical Review Gate, including mutation checks, was not repeated in its entirety; those checklist items retain the earlier evidence below. This passing run does not establish the root cause of the historical adoption timeout.

Historical review status: FAILED on 2026-09-28 20:26Z for the third complete uncached follow-up review of `26b444b6c85895a605e17e210dfecbbee569462b` against `BASE = f145b0a6`. Every gate command ran, including `LABAN_CHECK_NO_MEMO=1 ./scripts/check` and all three reversible mutations. The repository check failed in one serial AppKit case; every other gate item passed. This is the third failed review of the `./scripts/check` item in the PR review follow-up loop: stop the automatic review-fix cycle and surface the unresolved failure to a human reviewer under `PLANS.md`. Evidence: `.artifacts/split-panes/pr-review-final-gate-3/` (command logs, `results.json`, `static.json`, `suite-summary.json`, mutation diffs and hashes).

Historical review findings (2026-09-28):

- `LABAN_CHECK_NO_MEMO=1 ./scripts/check` exits 1. `Tests/LabanAppTests/LabanAppTests.swift:263` calls `waitForLocalSnapshotText` after replaying `READY` and writing `hi\n` through the adopted session. The helper fails at line 907 in `testAdoptUnclaimedLabptySessionReattachesExistingChild`: `timed out waiting for got hi; last=READY` (11.181 seconds for the case). Evidence: `check-no-memo.log:3381–3382`. The cause is not established; the observed host load does not prove this is harmless or unrelated to the implementation.
- All 19 targeted suites passed 289 cases, zero failures and zero skips: the ten required suites contributed 169 cases, seven additional feature suites 104, and the two audit/viewport timing suites 16. They ran in one equivalent union filter, with individual suite counts and every required passing test name verified in `suite-summary.json`. `SplitDaemonTests.swift` extends `AppSessionCoordinatorTests`; its background split-restore case passed among that suite's 17 cases. `PaneTreeTests` passed nine cases.
- Source inspection of the latest test repairs confirms that the persistence fixture now awaits a saved workspace and retains window-ID/tab-count assertions. Only the 100,000-line bulk-output case requests 60 seconds; every other output-wait helper caller retains the ten-second default. All 100,000 count/order assertions remain. The earlier audit and precise-scroll repairs retain their behavioral assertions. Static gate checks and direct `swift run LabanControlGen --check` passed; catalog allowlists are unchanged.
- Direct `./scripts/test-e2e` exited 0 and printed `split-pane scenario: ok`. Direct `./scripts/test-labanapp-survives-restart` exited 0, passed both restart cases, and printed `child survived`.
- The uncached check passed all 2,058 parallel-safe cases and all 268 headless cases. The serial AppKit target executed 729 cases: 719 passed, nine skipped, one failed. Eight skips require a vector/Slug renderer and one is an opt-in benchmark. The previously failing persistence, high-volume output, audit and viewport cases passed. Missing TLA+ caused skipped specification proofs and compile-only trace smoke; missing CBMC caused compile-only decoder smoke and skipped contract proofs. MemorySanitizer replay is unsupported on macOS and skipped. Model-action coverage and ASan/UBSan fuzz replay ran. GPU-serial, coverage, sanitizer-suite, runtime-smoke and embedded E2E stages were not reached after the serial failure.
- All three reversible mutations produced their required named failures: `testRemoveLeafCollapsesToSurvivor`, `testTwoPanesRenderAtDistinctOrigins`, and `testOutputInUnfocusedPaneMarksFrameDirty`. The original source bytes were restored after each mutation; `mutations.json` records matching SHA256 pairs. The restored tree/split suites passed all 14 cases. `final-source-restoration.json` confirms both source files match the reviewed commit exactly.
- One subsequent targeted triage run of `LabanAppTests.LabanAppTests/testAdoptUnclaimedLabptySessionReattachesExistingChild` passed (one case, zero skips). This is evidence of intermittency, not a passing fourth full gate or proof of the cause; the gate remains FAILED. Evidence: `adoption-targeted-triage.log` and `.json`. No source fixes or unrelated process changes were made. Build/test ownership was released after restoration and this single triage run.

Previous failed review: FAILED on 2026-09-28 20:15Z for the fresh complete re-review of `cee5bc4a3cbd0e1b5fbb5d618fe694ac3a8772d5` against `BASE = f145b0a6`. Every gate command ran, including `LABAN_CHECK_NO_MEMO=1 ./scripts/check` and all three reversible mutations. The uncached repository check failed in two parallel-shard cases; every other gate item passed. Evidence: `.artifacts/split-panes/pr-review-final-gate-2/` (`results.json`, `static.json`, complete command logs, mutation diffs and hashes).

Previous review findings (second uncached follow-up at `cee5bc4a`):

- `LABAN_CHECK_NO_MEMO=1 ./scripts/check` exits 1 in the 2,058-case parallel-safe shard. `Tests/LabptyTests/LabptyDaemonTests.swift:1852–1853`, `testHighVolumeOutputIsNotSplitOrLost`, reports output only through approximately `line-073992` before its expected `line-100000`, then throws POSIX timeout (16.700 seconds; two failure assertions, one unexpected). `Tests/LabanCoreTests/PersistenceRoundTripTests.swift:444`, `testPersistenceCoordinatorDebouncedSave`, fails to unwrap the saved `WorkspaceState` (6.165 seconds). Evidence: `check-no-memo.log:2124`, `:2142` and `:2155`. The earlier serial AppKit timing fixes are not implicated by these failures; those 16 tests passed their direct suites, and this full check did not reach the serial shard.
- All ten required targeted suites passed 169 cases. Nine additional nonempty suites brought the total to 289 passed cases, zero failures and zero skips. These include all five `PaneReviewHeadlessTests`, native right-button/selection/synchronized-output/precise-scroll regressions, `ControlDefaultOnTests`, `WorkspaceRestoreEndToEndTests`, `HeadlessIntentRouterTests`, and the 16 repaired audit/viewport tests. `SplitDaemonTests.swift` extends `AppSessionCoordinatorTests`; its background split-restore case passed among that suite's 17 cases, without counting an empty standalone filter. Every required test name is present in the logs.
- Source inspection of `cee5bc4a` found that the audit tests now await an event for their own newly created session, retaining intent/capability/surface assertions; the viewport tests wait for the precise-scroll target to settle, retaining the live-bottom assertions. Both changes preserve production behavior. All static checks and direct `swift run LabanControlGen --check` passed. The catalog diff is only the required session reference migration, with unchanged allowlists.
- Direct `./scripts/test-e2e` exited 0 and printed `split-pane scenario: ok`. Direct `./scripts/test-labanapp-survives-restart` exited 0, passed both restart cases, and printed `child survived`.
- The no-memo repository check reran its supported early stages, including model-action coverage and ASan/UBSan fuzz replay. Missing TLA+ caused skipped specification checks and compile-only trace smoke; missing CBMC caused compile-only decoder smoke and skipped contract proofs (`cbmc/goto-cc/goto-instrument` absent). MemorySanitizer replay is unsupported on macOS and was skipped. The parallel shard reported two failing cases and three failure assertions among its 2,058 scheduled cases, with no test skips logged. Serial AppKit/headless, GPU-serial, coverage, sanitizer-suite, runtime-smoke and embedded E2E stages were not reached after that failure.
- All three mutations produced the required named failures: `testRemoveLeafCollapsesToSurvivor`, `testTwoPanesRenderAtDistinctOrigins`, and `testOutputInUnfocusedPaneMarksFrameDirty`. The two mutated source files were restored byte-for-byte after each mutation and match `cee5bc4a`; SHA256 pairs are in `mutations.json`. The restored tree/split suites passed all 14 cases. The executing agent began separate repairs in the two failing test files after the baseline gate had completed; those uncommitted repairs are outside this reviewed SHA and are not validated by this failed gate.
- Host-load evidence at 20:13:49Z recorded load averages `171.46 / 158.40 / 106.12` on eight logical CPUs (`host-load.txt`). This is relevant scheduling context, not proof that either failure is harmless. No unrelated process was stopped. Build/test ownership was released after mutation restoration and the 14-case restoration run.

Previous failed review: FAILED on 2026-09-28 19:58Z for PR #2 review fixes at `2910166facab03cee87ca57d0b645ea4b8f6c651` against `BASE = f145b0a6`. A fresh independent reviewer ran every gate command, with `LABAN_CHECK_NO_MEMO=1` for the repository check. The repository check failed in two serial AppKit tests; all other gate items passed. Evidence: `.artifacts/split-panes/pr-review-final-gate/`.

Previous review findings (PR review fixes at `2910166f`):

- `LABAN_CHECK_NO_MEMO=1 ./scripts/check` exits 1. `Tests/LabanAppTests/ControlSecurityFloorTests.swift:126`, `testSessionObserveAppStateLightsIndicatorAndAudit`, observes the latest privileged audit intent as `selection.read` rather than `app.state`. `Tests/LabanAppTests/ViewportFollowDriftTests.swift:191`, `testAltScreenRoundTripWhileScrolledBackThenReturn`, observes viewport offset `4` rather than `0` after the first streamed burst. Evidence: `check-no-memo.log:3178` and `check-no-memo.log:4612` under the evidence directory. Both require diagnosis before the full fresh gate can pass.
- The required ten targeted suites passed 169 cases; seven additional nonempty regression suites brought targeted verification to 273 passed cases, zero failures and zero skips. Every required gate test name is present. The extra `SplitDaemonTests` filter selected zero tests because that file extends `AppSessionCoordinatorTests`; its `testBackgroundSplitRestoreDoesNotResizeDaemonPanesToFullWidth` passed under the coordinator filter. `suite-summary.json` records individual counts.
- `AppModel.tabWithPaneAttention` now delegates unfocused blocking-state classification to `TabAttentionClassifier`, preserving the focused title and scoped metadata. `testUnfocusedPaneBlockingTitleSurvivesAcknowledgement` passed, covering persistent blocking attention after acknowledgement and its removal when the title clears. `PaneReviewHeadlessTests` passed all five cases; native selection/right-button routing, synchronized-output recovery, precise scrolling and IME regressions also passed.
- Static gate checks and direct `swift run LabanControlGen --check` passed. Direct `./scripts/test-e2e` printed `split-pane scenario: ok`; direct restart validation passed both tests and printed `child survived`.
- The no-memo repository check reran its stages without cached passes. Its 2,058-test parallel-safe shard passed; the serial app target ran 729 tests with 9 skips and 2 failures. Eight skips require a vector/Slug renderer and one is an opt-in benchmark. Missing CBMC caused compile-only decoder smoke and skipped contract proofs; missing TLA+ caused skipped specs and compile-only trace smoke; MSan replay is unsupported on macOS. Model-action coverage and ASan/UBSan fuzz replay ran. Later coverage, sanitizer, runtime smoke and embedded E2E stages were not reached because the serial shard failed.
- All three mutations failed in their required tests: removed-child retention in `testRemoveLeafCollapsesToSurvivor`, shared pane origin in `testTwoPanesRenderAtDistinctOrigins`, and focused-only dirty checks in `testOutputInUnfocusedPaneMarksFrameDirty`. Exact source bytes were restored after every mutation, recorded by SHA256 in `mutations.json`; mutation diffs and full output are alongside it. All 14 restored tree/split tests passed in `restored-suites.log`; final source bytes match the reviewed commit.

Previous passing review (before PR review fixes): implementation `8994441a3ce6ad1bf30ccd7ce7d3becdb3dd0ecf` passed its complete fresh-state mechanical re-review on 2026-09-28 15:26Z against `BASE = f145b0a6`, including all three mutations. Evidence: `.artifacts/split-panes/final-review-2/`. That run's normal `./scripts/check` reused memoized heavy-stage results; it is not evidence that the current uncached gate passed.

Previous review findings (resolved; retained for the review-fix history):

- `./scripts/check` exits 1 in its `test-split` parallel-safe shard. `Tests/LabanCoreTests/TerminalSurfaceControllerTests.swift:1528` (`testSyncSessionsHoveredInactiveTabKeepsReportingModelChanged`) expects only the hovered session in `pendingResult.dirtySessionIds`, but receives both the hovered and active sessions; line 1541 then expects an empty dirty set and receives the still-dirty active session. The setup at lines 1467–1471 marks only the second/background session rendered. The new intentional pending-visible-output handling in `Sources/LabanCore/TerminalSurfaceController.swift:785–787` now retains the active session's initial dirty state. Settle the active session in this preview-focused fixture while preserving production deferred-frame behavior, then rerun the full gate. Evidence: `.artifacts/split-panes/final-review/check.log:2096`.
- All other gate commands passed: ten targeted suites ran 163 tests with every required name present and no skipped test cases; control generation and static checks passed; direct `./scripts/test-e2e` printed `split-pane scenario: ok`; both legacy and split restart tests passed and printed `child survived`.
- All three reversible mutations failed in the exact required tests: survivor collapse at `PaneTreeTests.swift:17–18`, shared pane origin at `SplitPaneHeadlessTests.swift:84`, and focused-only dirtiness at `SplitPaneHeadlessTests.swift:98`. Each original source file was restored byte-for-byte immediately afterward, and the restored suites then passed all 14 tests. Mutation diffs, complete output, exit statuses, and restored-source verification are under `.artifacts/split-panes/final-review/`.
- The repository check reports the optional TLA+ jar absent and reuses memoized unchanged `cbmc`, `cbmc-contracts`, `trace`, `model-coverage`, `fuzz`, and `fuzz-msan` results. Its later coverage, sanitizer, runtime smoke, and embedded E2E stages are not reached because `test-split` fails; the direct full E2E command above passed independently. No skip flags or environment overrides were supplied by this reviewer.

## Surprises & Discoveries

- The PR review follow-up reached the `PLANS.md` bound of three failed reviews of the uncached `./scripts/check` item. The first failure involved audit/scroll timing assumptions (repaired in `cee5bc4a`), the second persistence/bulk-output timing assumptions (repaired in `26b444b6`), and the third adopted-session input round-trip (`LabanAppTests.swift:263`, helper failure at line 907). All prior repaired cases passed on the third run; the adoption case then passed once in isolated triage. The cause remains unresolved, and host load alone does not establish it. The automatic full-gate retry loop stopped at that point. After the user requested the second review fixes, the fresh uncached repository check under R10 passed, including adoption; the historical timeout cause remains unresolved. Full historical evidence is under `.artifacts/split-panes/pr-review-final-gate-3/`.

- The second uncached follow-up gate encountered host load averages near 190 on eight logical CPUs and timed out in two parallel-shard fixtures. `testPersistenceCoordinatorDebouncedSave` waited for a separate timer rather than a persisted workspace; it now polls the actual saved result. The 100,000-line daemon test retains every count/order assertion but allows 60 seconds for that bulk transfer; the helper's other callers retain their ten-second budget. Both targeted tests passed under the continuing host load (`.artifacts/split-panes/pr-review-load-green.log`). These are validation fixture repairs, not daemon or persistence implementation changes.

- The first uncached follow-up gate found two timing-sensitive existing tests: the audit assertion read an earlier session's `selection.read` before its own async `app.state` write, and the viewport follow assertion ran while precise scrolling still animated. Repeating only `ControlSecurityFloorTests|ViewportFollowDriftTests` reproduced both on the third run (`.artifacts/split-panes/pr-review-timing-repro/3.log`). The tests now await their session's audit entry and scroll convergence before asserting; production paths are unchanged. Their full assertions remain intact, and all 16 tests passed ten consecutive repeats (160 test executions; `.artifacts/split-panes/pr-review-timing-green/`). A fresh complete gate is required after this test repair.

- PR #2 review follow-up: 211 targeted model, daemon, persistence, native-input and headless regressions passed. The strengthened real-shell scenario resolves actual session IDs from prior responses, asserts focus IDs, uses encoded output markers to avoid command-echo false positives, closes the original pane and types into the surviving sibling. Its 14 steps passed and the screenshot was inspected (`.artifacts/split-panes/pr-review-scenario/`). Independent source review found one remaining background blocking-title attention edge; a new regression reproduced both incorrect `.done` and missing attention after acknowledgement, and the aggregation now uses the shared attention classifier. The final mechanical gate remains pending.

- The first mechanical gate exposed a hover-preview fixture that never rendered the active terminal before asserting that only the preview remained dirty. Preserving pending visible pane output correctly made that initial dirty state observable. Taking the initial snapshot and marking it rendered repairs the fixture without weakening assertions or production dirty tracking; all 50 surface-controller and five split-pane tests pass (`.artifacts/split-panes/hover-fixture-red.log` and `hover-fixture-green.log`).

- Starting a labpty parser feed removed the descriptor just stored by `ensureSession`; the new independent-size test observed unchanged widths 100/49 after requesting 43/57. Restoring the descriptor after replacing the feed fixes daemon resize immediately.
- The headless laband renderer previously built frames from its local placeholder. It now passes the focused remote snapshot into the shared remote renderer, including the split-layout compatibility notice.
- A bounded headless render-cost comparison (20 warmed frames per layout, identical 24-row ASCII content in each pane) recorded median total/command-extraction/render times of 7.124/4.468/2.551 ms for one pane and 5.770/3.031/2.683 ms for two. Artifacts and trace packets are under `.artifacts/split-panes/perf/`. This measures the headless command path, not Metal GPU-cell throughput; the latter remains disabled for splits.
- The real-shell screenshot at `.artifacts/split-panes/scenario/screenshots/09-two-live-panes.png` was inspected: independent LEFT/RIGHT text, one divider, hollow unfocused cursor, solid focused cursor. The scenario asserts the surviving tree is a leaf after close.


- Observation: Session IDs are not stable across launches today, so "split
  panes backed by stable session IDs" first requires making them stable.
  Evidence: `ControlSessionLaunchCoordinator.prepareLaunch` mints
  `UUID().uuidString` (`Sources/LabanApp/Control/ControlSessionLaunchCoordinator.swift:33`);
  the laband/labpty restore factory builds `Session.fixture(size:)` with a
  random ID (`Sources/LabanApp/MainWindowController.swift:365-367`); the
  daemon key is stable only because the coordinator passes `tab.id`
  (`AppSessionCoordinator.swift:684-700, 718-740`). `Session.fixture` already
  accepts an optional `sessionID:` (`Session.swift:294`), so the plumbing
  exists at the bottom and is missing in the middle.

- Observation: The headless runtime uses a different daemon key than the GUI.
  Evidence: `HeadlessDebugRuntime.terminalClientLogicalSessionId(for:)`
  returns `tab.id` for laband and `tab.sessionId` otherwise
  (`HeadlessDebugRuntime.swift:729-731`). M0 unifies both on the session ID.

- Observation: Splitting a tab with today's transcript host would stop the
  first pane's transcript.
  Evidence: `TranscriptHost.attachTranscriptWriter(to:tabId:)` replaces the
  writer for that tab ID and clears the earlier session's persistence
  callback (`Sources/LabanCore/Persistence/TranscriptHost.swift:60-101`).

- Observation: Only one session per tab is ever polled for dirtiness or
  marked rendered, so an unfocused pane would freeze.
  Evidence: `TerminalSurfaceController.syncSessions` iterates
  `snapshot.tabSessions` (one session per tab) and sets `activeTerminalDirty`
  only for `tabId == activeTabId` (`TerminalSurfaceController.swift:721-803`);
  `markRendered` is called for the active tab's session only
  (`TerminalBitmapView.swift:4538`, `HeadlessDebugRuntime.swift:910-912`).

- Observation: There are no file-size or function-complexity ratchets in this
  repo (unlike sibling repos); the only cap in `./scripts/check` is
  `AGENTS.md ≤ 150 lines`. Editing the large files needs no extraction first.

- Observation (rev 3): "first session ID == tab ID" makes tab-for-session
  mix-ups invisible to tests until the first pane is closed.
  Evidence: `Tab.ID` and `Session.ID` are both `String`;
  `Sources/LabanDebug/DebugCastEndpoints.swift:23-32` resolves a `tabId` and
  passes it to the transcript ring lookup, which succeeds only while the
  first pane exists. Hence the `SurvivorPaneTests` family.

- Observation (rev 3): switching the terminal backend from the menu restarts
  the app and restores the workspace under the new backend
  (`Sources/LabanApp/TerminalBackendMenuController.swift:94-132`), so "laband
  refuses splits" is not enough; a split workspace must still open there.

- Observation (rev 3): the bell path is `NSSound.beep()`
  (`TerminalBitmapView.swift:4986`); there is no transient status surface.
  In-tab messages go through `AppModel.postTabNotice` (`AppModel.swift:1087`).

## Outcomes & Retrospective

The complete automated Review Gate passed on `8994441a`: two independent terminals share one tab, preserve session identity and processes across restore/restart, render and route input independently, and keep scoped control access isolated. Persistence migration and first-pane removal are covered by direct tests, and all three required deliberate regressions are detected. The first review's pending-output fixture failure was repaired by settling its initial active frame while preserving production dirty tracking.

The original planned scope passed. The PR #2 review fixes passed independent targeted, E2E, restart and mutation verification, but their full gate remains FAILED on the intermittent adopted-session input/output test after three attempts; see the current Review Gate findings. Divider dragging, deeper or horizontal splits, spatial navigation, laband split rendering, and the multi-payload GPU path remain deferred. Content-hash memoization made the full repository gate inexpensive to repeat; direct feature suites and end-to-end commands provided fresh execution evidence alongside it.

## Context and Orientation

### How one terminal reaches the screen today

1. `AppModel` (`Sources/LabanCore/AppModel.swift`) owns `_tabs: [Tab]` and a
   `SessionRegistry`. `Tab.sessionId` is a stored `let`. `session(forTab:)`
   (~413) looks the session up. `activeTab` is the tab with `isActive`.
   `surfaceSessionSnapshot()` (~389-410) produces one `(tabId, session)` pair
   per tab for the frame loop. `tabIndexUnlocked(forTab:sessionId:)`
   (~1636-1648) matches callbacks to tabs by `tab.sessionId == sessionId`.
2. `AppModel.resize(viewportWidth:viewportHeight:cellWidth:cellHeight:)`
   (~1678) computes one `LabanTerminalSize`, stores it in `currentSize`, and
   calls `session.resize(size)` on **every** session. `currentSize` is also
   the spawn size for every tab factory (~641, ~675, ~713, ~851).
   `terminalSize` is read in `TerminalBitmapView` (~15 sites),
   `HeadlessDebugRuntime`, `DebugCastEndpoints`, `DebugPersistenceEndpoints`,
   `DebugWindowActions` and `MainWindowController`.
3. Per-tab runtime maps in `AppModel` (~233-255): `agentByTab`,
   `launchCommandByTab`, `launchArgvByTab`, `cwdFallbackAppliedByTab`,
   `launchEnvironmentByTab`. Lifecycle hooks are `onTabCreated(Tab.ID, Session)`
   and `onTabClosed(Tab.ID)` (~108-111). Per-tab session callbacks
   (`attachSessionCallbacks(session:tabId:)` ~1885 and the following
   `attachTabStatus`, cwd, clipboard, shell integration, bell, OSC notify
   hooks) write tab-level state with no session filter.
4. `AppSessionCoordinator` keeps `infoByTabId`, `infoByLocalSessionId`,
   `labptyDescriptorByTabId`, `labptyFeedByTabId`, `cwdByTabId`,
   `launchCwdOverrideByTabId`, `labptyRecoveryNotedTabIds`, degradation
   marks, and closures `argvProvider(tabId)` / `launchEnvironmentProvider`.
   It opens daemon sessions with `logicalSessionId: tab.id`. `resize(tabs:in:size:)`
   (~455) pushes one size to every daemon session. The laband orphan sweep
   (~536) compares daemon IDs against `infoByTabId.values.logicalSessionId`.
   labpty "unclaimed" detection is called from `MainWindowController.swift:1153`
   with `knownTabIds: Set(model.tabs.map(\.id))`; `adoptLabptySessions`
   (~585-606) creates a tab whose ID equals the logical ID.
5. Launch order in `MainWindowController` (~541-546): `ensureSessions(for: model.tabs)`
   (one session per tab, via `session(forTab:)`) then `sweepOrphanedSessions()`.
   Anything not ensured is swept. New-tab creation in `TerminalBitmapView`
   (~5700-5717) ensures the daemon session and rolls the tab back on failure;
   `closeTab` (~5726) is the only `coordinator.terminate` call site.
6. Other per-tab hosts: `TranscriptHost` (writers and recent-byte rings by
   tab ID; `recentByteRing(forTabId:)` read by `DebugCastEndpoints.swift:32`
   and `TerminalBitmapView.swift:9245`), `AgentObserverHost.detectorsByTab`
   (`Sources/LabanCore/Persistence/AgentObserverHost.swift:20, 41-44`),
   `AgentJSONLMirror` (`timersByTab`, `jsonlPathByTab`),
   `ControlSessionLaunchCoordinator.sessionIDsByTabID`,
   `MainWindowController.registerAttachShell` / `scheduleAttachShellRetries`
   (~320-338, ~1500-1535), `TabMetadataSynchronizer` caches
   (`processIdentityByTab`, `terminalTitleOwnerByTab`,
   `acknowledgedCommandCountByTab`, `Sources/LabanCore/TabMetadataSynchronizer.swift:91-99`).
7. Rendering: `TerminalBitmapView` builds a `TerminalSurfaceFrameRequest`
   (`TerminalSurfaceController.swift:79`) with one `selection`, one
   `preedit`, one viewport. `makeFrame` draws the active session at origin
   `sidebarWidth + request.insets.left` (~1134 draw origin, ~1227 glyph-effect
   origin) with a terminal-area background from `x: sidebarWidth` (~1118).
   `makeFrame(remoteSnapshot:)` (~1254) is the laband variant with one
   snapshot. `TerminalSurfaceFrame` (~270-290) carries one `sessionId`,
   `rows`, `cols`, `gridOriginY`, `damage`, `cellPayload`.
   `syncSessions` (~721-803) decides dirtiness per tab. Focus reports are
   sent inline in the render loop by comparing against
   `lastRenderedActiveTabId` (`TerminalBitmapView.swift:3518-3527`).
8. Input: `TerminalBitmapView.keyDown` → `route` → `.appCommand(AppCommand)`;
   the `AppCommand` enum is in `Sources/LabanApp/TerminalInputView.swift:7`.
   `performKeyEquivalent` (~6680) handles only Ctrl-Tab. Menu items are in
   `Sources/LabanApp/MenuCommands.swift`. `sendKeyEvent` (~6848) and
   `sendBytes` (~6890) target `model.activeTab` → `session(forTab:)`.
   Mouse/selection/IME geometry (`TerminalMouseInput`, `TerminalSelectionInput`,
   `TerminalTextInputGeometry`) subtract `sidebarWidth` from x. Cursor styles
   are block/bar/underline (`CursorSettings.swift:19-22`); a hollow block
   exists only as a program-requested style (`FrameProducer.swift:2150`) and
   a program's explicit style beats the user's.
9. Persistence: `snapshotForPersistence(windowId:)` (~956) writes one flat
   `TabState` per tab and `transcripts/<tabId>.bin`. `PersistenceStore.load`
   (~85-104) has no version check; any decode error renames the file as
   corrupt and returns nil. Restore: `replaceTabs(from:)` (~802),
   `createRestoredTab(id:)` (~767, ~842), `restoredDeferredSessionFactory`
   (`MainWindowController.swift:365`).
10. Control plane: `Sources/LabanCore/Control/Projections/ControlStateProjections.swift`
    derives `activeSessionId` from `activeTab?.sessionId`;
    `schemas/debug/state.schema.json` `$defs.tab` requires `sessionId`.
    `SessionResponse` already carries `tabId`. `tab.new/close/select` are
    `headlessOnly`. `scripts/check-debug-contract` cross-checks routes,
    schemas and `docs/process/dev-process.md`.

### What is already in place that this plan reuses

- `SessionRegistry` is keyed by session ID and holds N sessions.
- `Session.fixture(size:sessionID:)` accepts an explicit ID.
- `FrameProducer` takes `originX`/`originY`; the hover preview draws a second
  session in the same frame.
- labpty's protocol has no tab concept; `LABPTY_E_SESSION_ID_IN_USE` exists,
  so reusing an ID for a live session is rejected, not silently merged.
- `Tests/LabanAppTests/LabanAppTests.swift:65
  testLabanAppRestartPreservesChildViaLabpty` and
  `scripts/test-labanapp-survives-restart` already prove a shell survives an
  app restart; M9 adds a split variant.

## Plan of Work

### M0: Stable session identity

Goal: after M0 nothing is user-visible, but every session has an ID that is
chosen before spawn, persisted, and used as the daemon key by both the GUI and
headless runtimes. The first session of a tab has ID equal to the tab ID.

1. `SessionLaunchContext` (`Sources/LabanCore/Control/SessionLaunchContext.swift`)
   and `ControlSessionLaunchCoordinator.prepareLaunch(tabID:isAgentAttached:)`
   gain a `sessionID: Session.ID` parameter; the coordinator stops minting.
   `sessionIDsByTabID` becomes `sessionIDs: Set<Session.ID>` with
   `noteSessionClosed(sessionID:)`.
2. All session factories in `AppModel` (default init ~305, `createTab` ~629,
   `createAgentAttachedTab` ~671, `createTab(runningArgv:)` ~711,
   `createRestoredTab` ~767/842) and the `restoredDeferredSessionFactory` in
   `MainWindowController` take an explicit session ID. New tabs mint one
   UUID and use it for both tab and first session. `RestoredSessionSpec`
   gains `sessionId`.
3. `AppSessionCoordinator`: re-key `infoByTabId` → `infoBySessionId`,
   `labptyDescriptorByTabId` → `…BySessionId`, `labptyFeedByTabId` →
   `…BySessionId`, `cwdByTabId` → `cwdBySessionId`, `launchCwdOverrideByTabId`
   → `…BySessionId`, `labptyRecoveryNotedTabIds` → `…SessionIds`, degradation
   marks by session. `infoByLocalSessionId` becomes redundant; remove it.
   The `argvProvider(tabId)` and `launchEnvironmentProvider(tabId)` closures
   take `(tabId, sessionId)` so a second pane can carry its own launch
   environment.
   Every method that takes `Tab` to find a daemon session takes
   `sessionId: Session.ID` (plus `tab` where argv/env providers need it).
   `logicalSessionId` is the session ID. `ensureSessions(for tabs:)` ensures
   **every** `tab.allSessionIds` (in M0 that is still one per tab) before the
   sweep runs. `unclaimedLabptySessions(knownTabIds:)` becomes
   `knownSessionIds:` and `MainWindowController.swift:1153` passes the union
   of all tabs' session IDs. `adoptLabptySessions` creates a tab with
   `id == sessionId == logicalId`.
4. `HeadlessDebugRuntime.terminalClientLogicalSessionId(for:)` returns the
   session ID for every backend.
5. `TranscriptHost`, `AgentObserverHost`, `AgentJSONLMirror`: key by session
   ID (`attachTranscriptWriter(to:sessionId:)`, `recentByteRing(forSessionId:)`,
   `transcriptURL(forSessionId:)`). With first-session-ID == tab-ID the
   on-disk `transcripts/<id>.bin` paths of existing tabs are unchanged.
6. Write `docs/adr/0036-pane-layout-is-view-state-above-session-tiers.md`
   (Accepted) now, so M1–M10 are reviewed against it: the daemon logical
   session ID is the session ID; a tab's first session ID equals the tab ID;
   pane trees live in `LabanCore` app state and `workspace.json`; labpty and
   laband have no pane concept and must not acquire one; a pane is addressed
   by its session ID; `Session.ID` remains a `String` and a distinct wrapper
   type is deferred; persisted attach approvals (ADR 0024) now match the
   same daemon shell across app restarts. Add the line to `docs/adr/README.md`.

Verification: `AppSessionCoordinatorTests` gains
`testFirstSessionLogicalIdEqualsTabId`; `HeadlessRestoreInjectionTests` and
`WorkspaceRestoreEndToEndTests` still pass unchanged (proving the on-disk and
daemon keys did not move for single-pane tabs);
`./scripts/test-labanapp-survives-restart` passes.

### M1: `PaneTree` value type

Create `Sources/LabanCore/PaneTree.swift`:

    public enum PaneAxis: String, Codable, Sendable { case horizontal, vertical }
    public indirect enum PaneTree: Equatable, Codable, Sendable {
      case leaf(sessionId: Session.ID)
      case split(axis: PaneAxis, fraction: Double, first: PaneTree, second: PaneTree)
    }
    public struct PaneRect: Equatable { public let sessionId: Session.ID; public let rect: CGRect }

`vertical` means the divider is a vertical line (left/right). `horizontal`
round-trips through Codable but no UI produces it in this plan.

Pure operations: `leafSessionIds()` in-order; `contains(_:)`;
`splitting(leaf:axis:newSessionId:newFirst:) -> PaneTree?` (nil if not a
leaf; new session second by default); `removing(leaf:) -> PaneTree?`
(collapse to survivor; nil when removing the only leaf);
`settingFraction(ofSplitContaining:to:)` clamped 0.1…0.9;
`layout(in:dividerWidth:) -> [PaneRect]` using the pixel rule in the Decision
Log, integer-aligned; `dividerRects(in:dividerWidth:)`.

Codable shape: `{"leaf":{"sessionId":"…"}}` or
`{"split":{"axis":"vertical","fraction":0.5,"first":{…},"second":{…}}}`.
Unknown shape throws `DecodingError.dataCorrupted`.

Tests `Tests/LabanCoreTests/PaneTreeTests.swift` (≥ 8): split leaf → two
leaves in order; split non-leaf → nil; `testRemoveLeafCollapsesToSurvivor`;
remove only leaf → nil; layout of 1000×600 at 0.5 with divider 1 →
`[0,500)` and `[501,1000)`; fraction clamp; Codable round-trip both cases;
unknown key throws.

### M2: Tab, AppModel and session-level lifecycle

`Tab`: delete `public let sessionId`; add `public var panes: PaneTree`,
`public var focusedSessionId: Session.ID`, `public var focusHistory: [Session.ID]`
(MRU, most recent last, runtime-only), computed `allSessionIds`. Keep an
`init(... firstSessionId:)` convenience that builds a single leaf, plus the
full init asserting `panes.contains(focusedSessionId)`.

Fix every compile error the deletion produces with an explicit choice:

- "Which session receives input / defines title, status, cwd, progress,
  process identity, hover preview, undo-close snapshot" → `focusedSessionId`.
- "Which sessions to close, ensure, resize, sweep-protect, persist, transcript,
  poll for dirtiness, count in `allSessions`, match in
  `tabIndexUnlocked`" → `allSessionIds`.
- `tabIndexUnlocked(forTab:sessionId:)` matches `tab.allSessionIds.contains`.
- `surfaceSessionSnapshot()` yields **every** session of every tab, each
  item carrying `tabId`, `isFocused` and `isVisible` (visible = in the active
  tab). Background tabs' unfocused panes must still be polled so unseen
  output marks the tab and `markRendered` bookkeeping stays correct.

Lifecycle hooks: add `onSessionCreated: ((Tab.ID, Session) -> Void)?` and
`onSessionClosed: ((Tab.ID, Session.ID) -> Void)?`; `onTabCreated`/`onTabClosed`
remain and fire around them. `MainWindowController` and the hosts subscribe
to the session hooks for transcript, agent observer, attach-shell retries and
control launch identity.

Per-tab callbacks: `attachSessionCallbacks(session:tabId:)` and the
`attach*` helpers take `sessionId` and check `tab.focusedSessionId == sessionId`
before writing tab-level status/title/cwd/progress. Bell and unseen-output
attention are applied for any session. `TabMetadataSynchronizer` caches
(`processIdentityByTab` etc.) become keyed by session, and
`acknowledgedCommandCount` is compared against the focused session only.

Per-tab runtime maps (`agentByTab`, `launchCommandByTab`, `launchArgvByTab`,
`cwdFallbackAppliedByTab`, `launchEnvironmentByTab`) become `…BySession`.

New `AppModel` API (all under `withModelLock`, all firing surface-changed and
journal hooks like `createTab`):

    public enum PaneError: Error { case notALeaf, unknownSession, unsupportedBackend, daemonRefused(String) }
    public func splitPane(inTab: Tab.ID, axis: PaneAxis, openSession: (Session.ID, LabanTerminalSize, cwd: String?) throws -> Session) throws -> Session.ID
    public func closePane(inTab: Tab.ID, sessionId: Session.ID, terminate: (Session.ID) -> Void)
    public func focusPane(inTab: Tab.ID, sessionId: Session.ID)
    public func focusAdjacentPane(inTab: Tab.ID, forward: Bool)

`splitPane` mints a UUID, computes the new pane's size from the tree layout
(M5 supplies `paneSize(for:in:)`; until then the current single size), calls
`openSession` (the caller wires the coordinator's ensure path so daemon
creation and rollback stay all-or-nothing as in `TerminalBitmapView.swift:5700-5717`),
resolves the cwd the way `resolveInheritedCwdUnlocked` does
(`AppModel.swift:935`: workspace cwd first, then process metadata; under
labpty the local session is a parser-only viewer and `processMetadata()` is
nil), registers the session, updates the tree, pushes the new ID on
`focusHistory`, sets focus, fires `onSessionCreated`. On throw the tree is
untouched. `closePane` calls `terminate`, unregisters, removes from tree; if
the tree becomes nil it falls through to `closeTab`; otherwise focus goes to
the last surviving entry of `focusHistory`. `invalidateSessionSyncCache` runs
in both. `focusPane` ends with `refreshTabMetadata(fromFocused:)`, which
re-derives status, title, cwd, progress and process identity from the newly
focused session (Decision Log).

Cache clearing: `closeAllSessions` and `replaceTabs(from:)` call a new
`AppModel.onSessionsReplaced` hook; `TerminalSurfaceController` clears
`lastSyncedGeneration` and its sibling per-session caches on it, and the
coordinator clears `lastSentSizeBySession` (Decision Log).

Tests: `AppModelTests` gains `testRegistryEqualsUnionOfLeaves`,
`testUnfocusedPaneExitDoesNotChangeTabStatus`,
`testFocusingExitedPaneMarksTabExited`,
`testClosePaneFocusesMostRecentlyFocusedSurvivor`, "close last pane closes
tab", "split rolls back when openSession throws".
`AppSessionCoordinatorTests` gains `testSplitTabOpensTwoDistinctLogicalSessions`
(moved here from M5 because this is where a split first opens a daemon
session).

New `Tests/LabanAppTests/SurvivorPaneTests.swift`: each test creates a tab
(first session ID == tab ID), splits, **closes the first pane**, then
exercises the survivor whose ID differs from the tab ID:
`testTypingAfterFirstPaneClosed`, `testResizeAfterFirstPaneClosed`,
`testCastEndpointAfterFirstPaneClosed` (`recentByteRing(forSessionId:)`
via `DebugCastEndpoints`), `testTranscriptAfterFirstPaneClosed`,
`testFindAfterFirstPaneClosed`, `testRestoreAfterFirstPaneClosed`,
`testAgentDetectionAfterFirstPaneClosed`. Any site that still passes a tab
ID where a session ID belongs fails one of these.

### M3: Persistence schema v2

- `WorkspaceSchema.currentVersion = 2`.
- `PaneState: Codable, Equatable` with `sessionId, cwd, launchCommand,
  transcriptPath, altBufferAtQuit, cwdFallbackApplied, repoFingerprint,
  processStatus, exitCode, shellPid, agent`.
- `TabState` gains `panes: PaneTree?`, `focusedSessionId: String?`,
  `paneStates: [PaneState]?`. The flat fields stay and describe the pane
  whose session ID equals the tab ID, or the focused pane if that one has
  been closed (Decision Log). An older binary reading a v2 file reattaches
  daemon ID `tab.id` and therefore gets the pane the flat fields describe;
  unsplit tabs are byte-for-byte today's behaviour; a split tab's other pane
  is left running in labpty and appears as adoptable. Downgrading while using laband is not supported: older laband clients sweep the sibling session as an orphan. Export the workspace and use labpty before downgrading.
- Decoding: `TabState` implements `init(from:)` so a malformed `panes` value
  falls back to a single leaf `.leaf(sessionId: id)` and logs, instead of
  failing the whole workspace (`PersistenceStore.load` treats any throw as
  corruption). Test `testCorruptPaneTreeFallsBackPerTab`.
- Migration: `panes == nil` → `.leaf(sessionId: id)`, `focusedSessionId = id`,
  `paneStates = [PaneState(from flat fields)]`. Test
  `testV1WorkspaceMigratesToSingleLeafTree` with a literal v1 JSON string.
- `snapshotForPersistence` emits one `PaneState` per leaf; restore creates
  one session per `PaneState` with its persisted ID and rebuilds the tree.
  `pendingAgentRestoreCandidatesByTab` and `HeadlessDebugRuntime` restore
  (~357) iterate `paneStates`.
- Test `testSplitTabRoundTrips`; `WorkspaceRestoreEndToEndTests` gains a
  split restore case.

### M4: Headless control plane

Intents (`IntentCatalog.swift`, category `pane`, availability `headlessOnly`,
capability `.input` for split/close and `.navigate` for focus, sensitivity
`.nonSensitiveState`):

- `pane.split` input `{ tabId?: string, axis?: "vertical"|"horizontal" }`,
  output: action result with `sessionId`.
- `pane.close` input `{ tabId?, sessionId? }`.
- `pane.focus` input `{ tabId?, sessionId }` or `{ tabId?, direction: "next"|"previous" }`.

Implement in `Sources/LabanDebug/DebugRuntimeRequests.swift` (new enum cases
and decoding) and a new `Sources/LabanDebug/DebugPaneActions.swift` modelled
on `Sources/LabanDebug/DebugTabActions.swift`. Errors map to the existing
error envelope with codes `notALeaf`, `unknownSession`, `unsupportedBackend`,
`daemonRefused`. Add request payload types in
`Sources/LabanCore/Intents/DebugRequestPayloads.swift` and entries in
`schemas/debug/action.schema.json`. Then `swift run LabanControlGen --write`
to regenerate `schemas/debug/discovery-endpoints.json`, and add the actions
to the list in `docs/process/dev-process.md` so `scripts/check-debug-contract`
passes. Do not touch `CatalogParityTests` allowlists.

State projection (`Sources/LabanCore/Control/Projections/ControlStateProjections.swift`,
`Sources/LabanCore/Control/Projections/ControlResponseModels.swift`,
`Sources/LabanDebug/DebugModels.swift`): each tab gains `panes` (M1 Codable
shape) and `focusedSessionId`; `sessionId` stays as an optional deprecated
alias equal to `focusedSessionId` (Decision Log). The state schema has no
version field; none is added. `activeSessionId` at the top level stays and
equals the active tab's focused session. Update `schemas/debug/state.schema.json`
`$defs.tab` (`panes` and `focusedSessionId` required; `sessionId` optional
with a `description` marking it deprecated) and `docs/process/dev-process.md:328`.
`schemas/debug/tab-journal.schema.json` does not embed tab objects and is
unchanged. `Sources/LabanAgent/main.swift:877` reads the model `Tab` and is
updated to `focusedSessionId`.

Session-scoped access (Decision Log): in `ControlStateProjections.swift`,
`filteredTabs` (~427) matches `tab.allSessionIds.contains(scoped)`; the tab
projection takes a `metadataSessionId` parameter that is the scoped session
when scoped and the focused session otherwise, and title/cwd/process/status/
attention are read from that session; scoped `activeSessionId` (~33-45)
equals the scoped ID; attention filtering (~59-68) considers only the scoped
session. In `Sources/LabanApp/Control/LiveIntentRouter.swift:550`,
`windowScreenshotResponse` returns `sessionNotVisible` when the scoped
session's tab has more than one pane.

Mouse actions in `Sources/LabanDebug/DebugMouseActions.swift` gain optional
`sessionId` so a scenario can click "in pane X".

Tests: `Tests/LabanDebugTests/HeadlessIntentRouterTests.swift` gains the
three intents; `Tests/LabanDebugTests/DiscoveryEndpointParityTests.swift`
and `Tests/LabanCLITests/CLICatalogDriftTests.swift` pass after regen;
`Tests/LabanAppTests/LiveControlObserveTests.swift` gains
`testScopedClientSeesOwnPaneMetadataInSplitTab` and
`testScopedScreenshotDeniedInSplitTab`; `Tests/LabanDebugTests/GetTextEndpointTests.swift:14`
keeps working through the alias.

### M5: Per-session terminal size

- `AppModel`: `currentSize` is replaced by `sizeBySession: [Session.ID: LabanTerminalSize]`
  plus `terminalAreaSize: LabanTerminalSize` (the full area, used as the
  spawn size for a new single-leaf tab and for hidden tabs).
  `resize(layout: [PaneRect], cellWidth:cellHeight:deferFindRescan:)` resizes
  only the listed sessions, keeping the capture-timeline event
  (`CaptureTimelineEvent.sessionResized`) and per-session find rescan.
  `paneSize(for sessionId: in tab:) -> LabanTerminalSize` computes from the
  tree without applying. `terminalSize` becomes `terminalSize(for:)`; the
  compiler finds the remaining sites (`DebugCastEndpoints`,
  `DebugPersistenceEndpoints`, `DebugWindowActions`, `MainWindowController`).
- Background (non-active) tabs keep the whole-area single-leaf layout so an
  unsplit hidden tab behaves exactly as today; a hidden split tab is resized
  when it becomes active (`selectTab` path calls the same resize entry).
- Resize call sites: `TerminalBitmapView.setFrameSize` (~5915) and the
  second path (~6092-6120) compute the terminal-area rect and call
  `activeTab.panes.layout(in:dividerWidth: 1)`; **also** `splitPane`,
  `closePane` and tab selection trigger a resize of the active tab's panes.
  `lastAppliedCols/Rows` become per-session for the selection-invalidating
  reflow check. `sessionCoordinator.resize(sizesBySession:)` sends only
  changed sizes (`lastSentSizeBySession`).
- `HeadlessDebugRuntime` mirrors with its fixed `sidebarWidth = 200`.

Test: `AppSessionCoordinatorTests.testResizeSendsDifferentSizesPerSession`.

### M6: Multi-pane rendering

`TerminalSurfaceFrameRequest` gains
`panes: [TerminalSurfacePaneRequest]` (`sessionId, rect, isFocused,
selection, preedit, preeditCaretCells`) and `dividers: [CGRect]`; the
top-level `selection`, `preedit`, `preeditCaretCells` fields are removed.

`TerminalSurfaceController`:
- `syncSessions` marks the frame dirty when **any** visible session's
  generation changed, and `syncSurfaceMetadata(forTab:)` runs for the
  focused session only.
- `makeFrame`: loop over `request.panes`; origin `pane.rect.minX + insets.left`,
  `pane.rect.minY + insets.top`; viewport from `pane.rect`. Emit one `.rect`
  per divider (sidebar separator colour, `source: .terminal`).
  `TerminalSurfaceFrame` gains `paneSessionIds: [Session.ID]`; its
  single-grid fields describe the focused pane and `cellPayload` is nil when
  `panes.count > 1` (`canSkipTerminalCommands` is false then).
- `makeFrame(remoteSnapshot:)` (laband) renders only the pane request whose
  `isFocused` is true, at full width, and when `panes.count > 1` appends a
  one-line notice run at the top of the pane reading "Split view is not
  available on the laband backend" (Decision Log). No assertion.
- Cursor: add `isFocusedPane: Bool` to the cursor resolution input in
  `FrameProducer`; when false the cursor draws as hollow block regardless of
  program or user style.
- `hoverPreviewOverlayCacheByTabId` stays keyed by tab (a preview is of a
  tab and shows its focused pane). The per-session content caches next to it
  (`lastSyncedGeneration` and the caches its comment says are "pruned
  together with" it, `TerminalSurfaceController.swift:589-602`) are already
  keyed by session; they gain the M2 clear-on-replace hook.

`TerminalBitmapView` and `HeadlessDebugRuntime`: build `panes` from the
layout, selections from `selectionsBySession` (renamed from `selectionsByTab`
~251; headless already has `selectionBySession`), preedit only for the
focused pane; call `markRendered` for every visible session
(`TerminalBitmapView.swift:4538`, `HeadlessDebugRuntime.swift:910-912`).

Tests `Tests/LabanDebugTests/SplitPaneHeadlessTests.swift` drive the M4
intents against a headless runtime with real shells: construct it with
`HeadlessSessionMode.realShell` (`Sources/LabanDebug/DebugModels.swift:26`),
which is what a scenario gets by omitting the `"fixture"` key
(`fixtures/debug-script-exit-wake.scenario.json` is such a scenario;
`debug-script-basic` is **not**, it sets `"fixture"`):
`testTwoPanesRenderAtDistinctOrigins` (glyph runs for `LEFT` and `RIGHT`
land in the respective halves, exactly one divider rect),
`testOutputInUnfocusedPaneMarksFrameDirty` (type into pane 1, focus pane 2,
run `printf` in pane 1 via `terminal.typeText` with `sessionId`; next frame
is dirty and the text appears), `testBothPanesWriteTranscripts`
(both `transcripts/<sessionId>.bin` grow), `testUnfocusedCursorIsHollow`.
Screenshot evidence comes from `fixtures/debug-script-split-pane.scenario.json`; the fixture byte-stream grammar cannot create panes. The real-shell scenario exercises the layout and saves its PNG without extending the unrelated fixture grammar.
New `Tests/LabanDebugTests/LabandSplitRestoreTests.swift`:
`testSplitWorkspaceRestoresFocusedPaneUnderLaband` loads a v2 workspace with
a two-leaf tab into a headless runtime on the laband backend and asserts the
tree is kept, one pane renders full width, the notice text is present, and
`pane.split` returns `unsupportedBackend`.

### M7: Input routing

`TerminalBitmapView`:
- `paneHit(at:) -> PaneRect?` from the same layout call as rendering.
  `mouseDown` (~8177): focus the hit pane first if unfocused.
- `TerminalMouseInput.surfacePosition/surfaceSize`, `TerminalSelectionInput`,
  `TerminalTextInputGeometry` take `paneRect: CGRect` instead of
  `sidebarWidth`; callers pass the hit pane's rect (mouse) or the focused
  pane's (IME candidate window, accessibility).
- Focus reports: replace the `lastRenderedActiveTabId` comparison
  (~3518-3527) with `lastRenderedFocusedSessionId`; on change send focus-out
  to the old session and focus-in to the new.
- `remoteMouseEncodingByTab` → `…BySession`. Live selection state is cleared
  on pane focus change.
- Scroll wheel targets the pane under the pointer.
- `TerminalScrollIndicatorView` is positioned at the focused pane's right
  edge and fed only by the focused session's `onViewportChanged`.
- Find chip binds to the focused session.
- Hover preview of a background split tab shows its focused pane (document
  in the preview code).

Headless: mouse routing uses `paneHit`; `HeadlessMouseRoutingTests` and
`HeadlessFocusRoutingTests` gain a split case each.

### M8: GUI commands

- `AppCommand` (`Sources/LabanApp/TerminalInputView.swift:7`) gains
  `.splitPaneRight`, `.closePane`, `.focusNextPane`, `.focusPreviousPane`.
- `MenuCommands.swift`: "Split Pane Right" Cmd+D, "Close Pane" Cmd+Shift+D
  (validated: enabled only when the active tab has more than one pane),
  "Focus Next Pane" Cmd+Option+], "Focus Previous Pane" Cmd+Option+[.
- `TerminalBitmapView` handles the commands by calling the `AppModel` API
  with the coordinator's ensure/terminate closures; on `PaneError` it calls
  `AppModel.postTabNotice` (`Sources/LabanCore/AppModel.swift:1087`) with the
  error text so it appears as a tab notice like other in-tab messages.
  `Sources/LabanDebug/DebugRuntimeKeyInput.swift` maps the same keys for
  headless parity.
- Add the four strings to the source `scripts/gen-localizable-xcstrings.py`
  reads and regenerate.

### M9: End-to-end

- `fixtures/debug-script-split-pane.scenario.json` (modelled on
  `fixtures/debug-script-exit-wake.scenario.json`, which has no `"fixture"`
  key and therefore runs real shells): `tab.new`, `pane.split`, focus pane 1,
  `terminal.typeText printf LEFT\n`, focus pane 2, `printf RIGHT\n`, wait for
  both via the wait endpoint scoped by `sessionId`, screenshot, `pane.close`,
  assert state has one pane. `scripts/test-e2e` runs it and prints
  `split-pane scenario: ok`.
- Relaunch check lives in `Tests/LabanDebugTests/HeadlessRestoreInjectionTests.swift`,
  which already drives `persistenceRelaunch`: new
  `testSplitTabSurvivesPersistenceRelaunchWithLiveFrame` splits, types into
  both panes, relaunches, asserts both session IDs are preserved, the tree
  has two leaves, and a **new frame renders new output** after relaunch
  (this catches the stale `lastSyncedGeneration` hazard from the Decision
  Log). The headless runtime has no labpty, so this proves the persistence
  half only; the daemon half is the `LabanAppTests` case below.
- `Tests/LabanAppTests/LabanAppTests.swift`: add
  `testSplitTabSurvivesLabanAppRestartViaLabpty` next to
  `testLabanAppRestartPreservesChildViaLabpty` (~65): split, start `sleep`
  in each pane, restart the app, assert both child PIDs alive and both panes
  present. Wire into `scripts/test-labanapp-survives-restart`.

### M10: Docs

`docs/product/mvp.md` "Later Milestones": mark item 1 delivered by this plan
and list the deferred parts (drag divider, nesting, horizontal, spatial
navigation, laband support, multi-payload GPU path) as the next plan
`execplans/active/split-panes-2-divider-and-navigation.md` (not created
here). `docs/process/dev-process.md` gets the new actions. Run the Review
Gate.

## Concrete Steps

All commands run from `/Users/rrj/wrk/laban`.

    # Record the base commit for the Review Gate
    git rev-parse HEAD

    # Baseline (several minutes; must be green before starting)
    ./scripts/check

    # Fast loops per milestone
    swift test --filter PaneTreeTests
    swift test --filter AppModelTests
    swift test --filter PersistenceRoundTripTests
    swift test --filter AppSessionCoordinatorTests
    swift test --filter HeadlessIntentRouterTests
    swift test --filter SplitPaneHeadlessTests
    swift test --filter CatalogParityTests
    swift run LabanControlGen --write && swift run LabanControlGen --check
    ./scripts/check-debug-contract
    ./scripts/test-e2e
    ./scripts/test-labanapp-survives-restart

    # Build and install the GUI app for manual checks
    ./scripts/build-app
    ./scripts/install-app

    # Full gate before opening the PR
    ./scripts/format && ./scripts/check

Commit after each milestone with a single-line reason, for example
`Give every session a stable ID chosen before spawn so panes can share a tab`.
M0, M2 and M3 each contain one behavioural reason; do not merge them into one
commit.

## Validation and Acceptance

Automated: every Review Gate item above.

Manual, in the installed app with the labpty backend (the default):

1. New tab, Cmd+D. Two prompts side by side with a one-pixel divider. The
   right pane's cursor is solid (focused); the left is hollow.
2. Type `echo right`. It appears only in the right pane.
3. Click in the left pane, type `echo left`. Only there; cursor styles swap.
4. Run `top` in the left pane and resize the window. Both panes reflow; `top`
   redraws to the left pane's width only. Focus the right pane and wait: the
   left pane's `top` keeps updating.
5. `laban state` shows the tab with a two-leaf `panes` value,
   `focusedSessionId` equal to the right session.
6. Cmd+Q, relaunch. Both panes return; `top` still running; `echo right`
   output still visible. No "unclaimed sessions" dialog appears.
7. Cmd+Shift+D in the left pane: `top` exits, right pane fills the tab, and
   the "Close Pane" menu item is now disabled. Cmd+W closes the tab.
8. Copy a pre-upgrade `workspace.json` (schema 1) into place and launch:
   every tab restores as one pane attached to its still-running shell.
9. Switch backend to laband, Cmd+D: a status message says splits are not
   supported on this backend; nothing else changes.

## Idempotence and Recovery

- M0 changes daemon keys for no existing tab (first session ID == tab ID), so
  it can be deployed and reverted without losing shells.
- Before testing restore on a real workspace, copy the file
  `PersistenceStore.swift` names (`workspace.json` under the app's
  Application Support directory) aside; a v2 file restores under a v1 binary
  using the legacy flat pane fields (the first-created pane when still present).
- The current migration does not terminate daemon sessions. Unclaimed labpty
  panes remain adoptable. Downgrading a split workspace with laband is unsupported:
  older clients can terminate sibling sessions during orphan sweeping.
- `./scripts/test-e2e` and the restart test clean their own
  `.tmp/<run-id>` directories.

## Interfaces and Dependencies

Must exist at the end of the plan:

    // Sources/LabanCore/PaneTree.swift
    public enum PaneAxis: String, Codable, Sendable
    public indirect enum PaneTree: Equatable, Codable, Sendable
    public struct PaneRect: Equatable
    extension PaneTree {
      func leafSessionIds() -> [Session.ID]
      func contains(_: Session.ID) -> Bool
      func splitting(leaf: Session.ID, axis: PaneAxis, newSessionId: Session.ID, newFirst: Bool) -> PaneTree?
      func removing(leaf: Session.ID) -> PaneTree?
      func settingFraction(ofSplitContaining: Session.ID, to: Double) -> PaneTree
      func layout(in: CGRect, dividerWidth: CGFloat) -> [PaneRect]
      func dividerRects(in: CGRect, dividerWidth: CGFloat) -> [CGRect]
    }

    // Sources/LabanCore/Tab.swift  (no stored or computed `sessionId`)
    public var panes: PaneTree
    public var focusedSessionId: Session.ID
    public var focusHistory: [Session.ID]
    public var allSessionIds: [Session.ID] { get }

    // Sources/LabanCore/AppModel.swift
    public enum PaneError: Error
    public var onSessionCreated: ((Tab.ID, Session) -> Void)?
    public var onSessionClosed: ((Tab.ID, Session.ID) -> Void)?
    public func splitPane(inTab:axis:openSession:) throws -> Session.ID
    public func closePane(inTab:sessionId:terminate:)
    public func focusPane(inTab:sessionId:)
    public func focusAdjacentPane(inTab:forward:)
    public func resize(layout: [PaneRect], cellWidth: Int, cellHeight: Int, deferFindRescan: Bool)
    public func paneSize(for: Session.ID, in: Tab.ID) -> LabanTerminalSize
    public func terminalSize(for: Session.ID) -> LabanTerminalSize
    public var terminalAreaSize: LabanTerminalSize { get }

    // Sources/LabanApp/Control/ControlSessionLaunchCoordinator.swift
    func prepareLaunch(tabID: Tab.ID?, sessionID: Session.ID, isAgentAttached: Bool) -> SessionLaunchContext

    // Sources/LabanApp/AppSessionCoordinator.swift
    func ensureSessions(for tabs: [Tab], in: AppModel)           // every leaf
    func resize(sizesBySession: [Session.ID: LabanTerminalSize])
    func unclaimedLabptySessions(knownSessionIds: Set<Session.ID>) -> [LabptySessionDescriptor]
    // all daemon lookups keyed by Session.ID; logicalSessionId == Session.ID

    // Sources/LabanCore/TerminalSurfaceController.swift
    public struct TerminalSurfacePaneRequest
    // TerminalSurfaceFrameRequest.panes, .dividers; TerminalSurfaceFrame.paneSessionIds

    // Sources/LabanCore/Persistence/WorkspaceState.swift
    WorkspaceSchema.currentVersion == 2
    public struct PaneState: Codable, Equatable
    // TabState.panes: PaneTree?, .focusedSessionId: String?, .paneStates: [PaneState]?

    // Sources/LabanApp/TerminalInputView.swift
    // AppCommand: .splitPaneRight, .closePane, .focusNextPane, .focusPreviousPane

No new external dependencies. `Sources/Labpty` and `Sources/Laband` are not
touched.
