# Split Panes 2: Any Layout, Draggable Dividers, Directional Focus, Zoom and Equalize

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that
will help a fresh contributor.

Revision 1 (2026-10-01). Builds on the completed first split-panes plan,
`execplans/active/split-panes.md` (checked in). Everything this plan needs from
it is restated in `Context and Orientation`; you do not have to read it, but
its `Decision Log` explains why panes look the way they do.

## Purpose / Big Picture

Today a Laban tab can be split exactly once, left and right, 50/50. That is
not enough for anyone coming from iTerm2, Ghostty, kitty, WezTerm or tmux, where
split panes are a basic expectation. After this change a user can:

- split the focused pane **right** (Cmd+D) or **down** (Cmd+Shift+D),
  repeatedly, building any grid such as an editor on the left and two shells
  stacked on the right;
- **drag any divider** with the mouse to resize the panes on either side; the
  shells are resized once, when the drag ends, not on every mouse movement;
- **move focus by direction** with Cmd+Option+Arrow keys to the natural
  neighbouring pane, in the way tmux, iTerm2 and Ghostty do;
- **resize from the keyboard** with Cmd+Control+Arrow keys;
- **zoom** the focused pane to fill the tab (Cmd+Shift+Return) and back,
  while the other panes keep running;
- **equalize** all panes in the tab (Cmd+Control+=);
- **close the focused pane with Cmd+W**, as in iTerm2 and Ghostty. Cmd+W in a
  tab with only one pane still closes the tab, so unsplit tabs behave exactly
  as they always have. Cmd+Option+W always closes the whole tab.

Every one of these layouts survives Cmd+Q and relaunch with the shells still
running, because each pane is an ordinary background session in the `labpty`
daemon and the layout is plain data saved in `workspace.json`.

You will know this works when, in the installed app, you can build the
three-pane layout above from a fresh tab with keyboard shortcuts alone, drag
the vertical divider to about one third, move focus around with
Cmd+Option+Arrows, zoom and unzoom the editor pane, quit, relaunch, and see the
same layout with the same running processes. `laban state` shows the nested
tree. The headless scenario `fixtures/debug-script-split-pane-2.scenario.json`
does the same thing without a window and saves screenshots.

### Term glossary (plain language, used throughout this plan)

- **Tab**: one row in the left sidebar. Type `Tab` in
  `Sources/LabanCore/Tab.swift`. It has `panes` (a pane tree),
  `focusedSessionId` and `focusHistory`.
- **Session**: one shell process with its own pseudo-terminal, parser state and
  scrollback. Type `Session` in `Sources/LabanCore/Session.swift`;
  `Session.ID` is a `String`. Sessions live in `SessionRegistry`, keyed by ID.
- **PTY** (pseudo-terminal): the kernel object a shell reads keystrokes from
  and writes output to. Resizing it is the `TIOCSWINSZ` system call; the shell
  then gets `SIGWINCH` and redraws. Every resize makes full-screen programs
  such as `vim` or `top` repaint, which is why we avoid resizing on every drag
  tick.
- **Pane**: one rectangular region of a tab's terminal area that shows one
  session. A pane has no ID of its own; it is identified by its session ID.
- **Pane tree**: the pure-data description of how a tab's terminal area is
  divided. Type `PaneTree` in `Sources/LabanCore/PaneTree.swift`:
  `.leaf(sessionId:)` or `.split(axis:fraction:first:second:)`.
- **Axis**: `PaneAxis.vertical` means the divider is a vertical line and the
  children sit left (`first`) and right (`second`). `PaneAxis.horizontal`
  means the divider is a horizontal line and the children sit top (`first`)
  and bottom (`second`). The view and the renderer are **not** flipped: y grows
  upward (`TerminalBitmapView` is a plain bottom-left-origin view), so "top" is
  the larger y and the `first` child of a horizontal split owns the high-y end
  of its container. Debug-API coordinates (`click`, `mouseDrag`) are top-down
  and are converted at the headless edge. (Revision 1 of this plan claimed the
  opposite; see `Surprises & Discoveries`.)
- **Fraction**: the share of the split's extent given to `first`, a number
  between 0 and 1.
- **Pane path**: new in this plan. The route from the root of the tree to one
  split node, written as a list of sides, for example `[.second]` means "the
  split that is the root's second child". The root split's path is `[]`. A path
  addresses a divider unambiguously, which a session ID cannot do once trees
  are nested.
- **Divider**: the 1-pixel line drawn between the two children of a split.
  The **grab zone** is a few pixels either side of it that accept a mouse drag.
- **Focused pane**: the pane in the active tab that receives keyboard input.
  `Tab.focusedSessionId`.
- **Focus history** (MRU, most recently used): `Tab.focusHistory`, session IDs
  ordered by when they were last focused, most recent last.
- **Zoom**: a temporary state where one pane fills the whole terminal area of
  its tab and the others are hidden but keep running. New field
  `Tab.zoomedSessionId`.
- **Visible layout**: new in this plan. The list of pane rectangles actually
  shown: the whole tree's layout normally, or one full-area rectangle for the
  zoomed pane. Everything that draws, hit-tests or resizes uses this.
- **labpty**: the small per-user daemon (`Sources/Labpty/`, C) that owns the
  PTYs so shells survive app restarts. It has no idea panes exist. It is
  **not modified** by this plan.
- **laband**: the optional larger daemon (`Sources/Laband/`) that runs the
  terminal parser out of process and sends rendered snapshots back. It also
  refuses splits today and is **not modified**.
- **Terminal backend**: which daemon (or none) is in use, chosen in Settings
  (`inProcess`, `laband`, `labpty`; labpty is the default).
  `sessionCoordinator?.usesRemoteSnapshots == true` means laband.
- **TerminalBitmapView**: the single AppKit view per window
  (`Sources/LabanApp/TerminalBitmapView.swift`, about 9,900 lines) that draws
  the sidebar and all panes into one Metal surface and receives all keyboard
  and mouse input. There is no per-pane view.
- **TerminalSurfaceController**: the pure-Swift frame builder
  (`Sources/LabanCore/TerminalSurfaceController.swift`). Split tabs go through
  `makeSplitFrame`, which emits draw commands for each pane and one `.rect`
  per divider. Single-pane tabs can instead use the faster GPU **cell
  payload**, which encodes exactly one grid.
- **Headless runtime**: `Sources/LabanDebug/HeadlessDebugRuntime.swift`, the
  windowless twin of `TerminalBitmapView` used by CI and agents. A standing
  rule in `AGENTS.md` is that it must stay in feature parity with the app.
- **Control plane / intents**: the local HTTP-over-Unix-socket API. Actions
  are declared in `Sources/LabanCore/Intents/IntentCatalog.swift`; headless
  implementations live in `Sources/LabanDebug/DebugPaneActions.swift` and
  `DebugRuntimeRequests.swift`. `schemas/debug/discovery-endpoints.json` is
  generated by `swift run LabanControlGen --write`; never hand-edit it.
- **Workspace state**: `workspace.json`, written at quit and read at launch
  (`Sources/LabanCore/Persistence/WorkspaceState.swift`). `TabState` already
  stores `panes` and `focusedSessionId` (schema version 2).
- **Application command / route**: the keyboard path.
  `TerminalInputView.swift` turns a key event into a `TerminalInputRoute`; for
  Command chords `routeCommand()` returns `.appCommand(AppCommand)` and
  `TerminalBitmapView.perform(_:)` (around line 6995) dispatches it. Menu
  items in `Sources/LabanApp/MenuCommands.swift` call the same `@objc`
  selectors.

## Progress

- [x] M0: Record `BASE` (done by the orchestrator, commit ff5ccfa2); baseline `./scripts/check` green.
- [x] M1: `PaneTree` geometry: paths, dividers with containers, fraction by
      path, minimum extents, equalize, directional neighbour; tests.
- [x] M2: `Tab.zoomedSessionId` and `Tab.visibleLayout(in:)`; every layout
      caller switched to it; `allSessionIds.count` sites audited.
- [x] M3: `AppModel` API: unrestricted split (both axes, nested, minimum
      size), directional focus, set fraction, nudge divider, equalize, zoom;
      tests.
- [x] M4: Persistence: nested and mixed-axis trees and `zoomedSessionId`
      round-trip; tests.
- [x] M5: Headless control plane: `pane.split` both axes, `pane.focus`
      directions, `pane.resize`, `pane.equalize`, `pane.zoom`; state
      projection and schema; discovery regenerated; divider drag through
      headless mouse actions.
- [x] M6: Rendering: nested layouts, zoom uses the single-pane path, divider
      drag preview line, sidebar zoom badge; headless tests. (The GUI half of
      "pass `dividerPreview` during a drag" lands with the M7 drag handler; the
      request field and headless path are done.)
- [x] M7: GUI input: divider hover cursor, drag-preview-commit, keyboard
      chords, menu items, accessibility splitter elements. (Also fixed the
      layout's vertical orientation and per-pane mouse geometry, see Surprises.)
- [ ] M8: End-to-end: headless scenario, nested-split restart test through
      labpty, four-pane frame-cost measurement.
- [ ] M9: Docs (`mvp.md`, `spec.md`, `dev-process.md`), Review Gate.

## Decision Log

- Decision: Keyboard mapping follows iTerm2 and Ghostty. Cmd+D splits right,
  Cmd+Shift+D splits down (it was Close Pane), Cmd+W closes the focused pane
  and, when it is the tab's only pane, the tab. Cmd+Option+W always closes the
  whole tab.
  Rationale: chosen by the user on 2026-10-01. Muscle memory from the two most
  common macOS terminals matters more than keeping a three-day-old chord.
  `docs/product/mvp.md` requires a "close active tab" shortcut; a single-pane
  tab still closes on Cmd+W, and Cmd+Option+W closes any tab, so the regression
  contract holds. The first plan's decision to keep Cmd+W as "close tab" is
  superseded by this one.
  Date/Author: 2026-10-01 / user, recorded by plan author.

- Decision: Cmd+Option+Left/Right move pane focus when the active tab has more
  than one visible pane and keep switching tabs when it has one.
  Cmd+Option+Up/Down move pane focus when split and do nothing otherwise. At
  the edge of a split layout the chord does nothing; it never falls through to
  tab switching. Cmd+Shift+[ / ] and Control+Tab always switch tabs.
  Rationale: chosen by the user on 2026-10-01. Falling through at an edge
  would make the same chord do two different things depending on which pane
  is focused, which is the kind of surprise that makes people lose their place.
  Date/Author: 2026-10-01 / user, recorded by plan author.

- Decision: Address splits by **path** (`[PaneSide]`), not by session ID.
  Rationale: the existing `settingFraction(ofSplitContaining:)` only finds a
  split whose direct child is the named leaf. In `A | (B / C)` the root split
  has no leaf child on its right, so its divider could not be dragged. A path
  names every split, is stable while the user drags, and is visible to agents
  through the `panes` tree already in `/debug/state`.
  Date/Author: 2026-10-01 / plan author.

- Decision: Directional navigation ranks candidates by (has perpendicular
  overlap, **smaller directional distance**, larger perpendicular overlap,
  smaller perpendicular centre distance, more recent in focus history).
  Rationale: `docs/product/spec.md` section 9 lists overlap length before
  directional distance. With columns `A | B | C` where `B` is split top and
  bottom, moving right from `A` would then pick `C` (full-height overlap)
  over the adjacent `B` halves, jumping over a pane. Putting distance second
  fixes this and matches tmux. Section 9 of the spec is updated in M9 to
  say so.
  Date/Author: 2026-10-01 / plan author.

- Decision: Divider drags preview, then commit (spec section 4). While the
  mouse is down, only a translucent preview line moves; the tree and the PTY
  sizes change once, on mouse-up.
  Rationale: every PTY resize makes full-screen programs repaint and
  re-wraps long lines. Resizing at mouse-move rate would make `vim` and `top`
  flicker and would flood the daemon with resize calls.
  Date/Author: 2026-10-01 / plan author.

- Decision: Minimum pane size is 10 columns by 3 rows. A split that would make
  either half smaller is refused with the tab notice "Not enough room to
  split this pane". A divider drag or keyboard nudge is clamped so neither
  side's subtree drops below its minimum extent. Shrinking the window can
  still make panes smaller than that; the terminal is then clamped to at
  least 1 column and 1 row as it is today.
  Rationale: spec section 4 asks for a minimum-length clamp. Refusing to
  split is clearer than creating a pane too small to show a prompt. Refusing
  to let a window shrink is not something any terminal does.
  Date/Author: 2026-10-01 / plan author.

- Decision: `PaneTree.layout` keeps a sanity clamp, widened from 0.1–0.9 to
  0.05–0.95, and `settingFraction(at:to:)` accepts any finite value in that
  range. The real limit comes from minimum extents, computed by the caller
  that knows the cell size.
  Rationale: with nested trees a 0.1 floor on an outer split can be stricter
  than the 10-column minimum in a wide window, and looser in a narrow one.
  The old `testFractionClamped` asserts 0.1 and 0.9; it is updated in M1.
  Persisted fractions so far are all 0.5, so no saved layout changes.
  Date/Author: 2026-10-01 / plan author.

- Decision: Zoom is per tab, persisted in `workspace.json`, and leaves
  hidden panes at their last size. Any structural or focus-changing pane
  command (split, close, focus by direction, next/previous, click on a
  different pane is impossible while zoomed) unzooms first. Closing the
  zoomed pane unzooms. Zoom with one pane is a no-op and the menu item is
  disabled.
  Rationale: resizing hidden panes to zero would make every full-screen
  program in them repaint twice, and their scrollback would re-wrap. Leaving
  them at their last size is what iTerm2 and Ghostty do. Unzooming before
  navigation avoids a state where focus is on a pane you cannot see.
  Date/Author: 2026-10-01 / plan author.

- Decision: A zoomed tab renders through the existing single-pane path, so it
  gets the GPU cell payload. The test for "is this a split frame" changes from
  `allSessionIds.count > 1` to "visible layout has more than one pane".
  Rationale: zoom exists to give one pane the whole screen; it should get the
  fast path too. The single-pane path already draws the focused session
  across the full terminal area, which is exactly the zoomed layout.
  Date/Author: 2026-10-01 / plan author.

- Decision: The zoom indicator is a small badge in the tab's sidebar row,
  drawn by `SidebarProducer`, reading "⤢ N" where N is the number of panes in
  the tab. Nothing is drawn over terminal content.
  Rationale: a zoomed tab looks identical to a single-pane tab; without a
  marker people forget the other panes exist. Drawing on top of the terminal
  would cover output.
  Date/Author: 2026-10-01 / plan author.

- Decision: Equalize gives every leaf along a run of same-axis splits an
  equal share. The weight of a node along an axis is 1 for a leaf or for a
  split of the other axis, and the sum of its children's weights for a split
  of the same axis; a split's fraction becomes
  `weight(first) / (weight(first) + weight(second))`.
  Rationale: `A | (B | C)` should give each of A, B, C one third, not A one
  half. This is what tmux `select-layout even-horizontal` and Ghostty
  `equalize_splits` do.
  Date/Author: 2026-10-01 / plan author.

- Decision: Keyboard divider nudge (Cmd+Control+Arrow) moves the nearest
  enclosing divider on that side of the focused pane by 2 cells, and does
  nothing if no such divider exists. The divider is "on that side" if the
  focused pane is inside `first` and the arrow points towards `second`
  (Right for vertical, Down for horizontal), or the reverse.
  Rationale: one cell is too slow to be useful; 2 cells keep text aligned.
  Moving the divider on the side the arrow points to is the tmux
  `resize-pane` convention.
  Date/Author: 2026-10-01 / plan author.

- Decision: The divider is exposed to VoiceOver as an `NSAccessibilityElement`
  with role `.splitter`, value equal to the fraction as a percentage, and
  increment/decrement actions that call the same nudge as the keyboard.
  Rationale: spec section 4 asks for keyboard-accessible dividers. There are
  no per-pane `NSView`s, so these must be explicit accessibility children of
  `TerminalBitmapView`.
  Date/Author: 2026-10-01 / plan author.

- Decision: Still out of scope: the laband backend (it keeps refusing splits
  and shows only the focused pane of a restored split tab), a GPU cell payload
  that encodes several grids, dragging panes to rearrange them, swapping
  panes, and moving a pane into another tab.
  Rationale: the first plan measured the draw-command path for two panes at a
  similar cost to one pane in headless mode; M8 measures four panes and
  records it. If four panes become a visible problem, the multi-grid payload
  gets its own plan and ADR, because it touches the present-link (ADR 0026)
  and Slug renderer (ADR 0032) contracts.
  Date/Author: 2026-10-01 / plan author.

- Decision: The new `pane.*` intents stay `headlessOnly`, like the existing
  ones.
  Rationale: `Tests/LabanAppTests/CatalogParityTests.swift` pins that no GUI
  intent requires `.input` and pins the GUI `.navigate` set. Those
  allowlists encode the control-plane threat model (ADR 0024) and are not
  changed here.
  Date/Author: 2026-10-01 / plan author.

- Decision: `settingFraction(at:to:)` returns nil only when the path does not
  name a split; a non-finite value on a valid path returns the tree unchanged
  (the same behaviour the old `settingFraction(ofSplitContaining:to:)` had).
  `fractionRange` returns `0.5...0.5` for a zero-extent container.
  Rationale: nil is reserved for the "bad path" error callers map to `notSplit`.
  Date/Author: 2026-10-01 / executing agent.

- Decision: `Tab` also exposes `visiblePaneCount` (1 while zoomed, otherwise the
  leaf count), and `isZoomed` is true only when `zoomedSessionId` is still in the
  tree. Renderer and view gates that used `allSessionIds.count == 1` or `> 1`
  use `visiblePaneCount`, so they need no geometry. `AppModel.surfaceSessionSnapshot`
  marks a session visible only if its tab is active and (not zoomed or it is the
  zoomed pane). `resizeTabLayoutsUnlocked` also resizes inactive zoomed tabs
  (`visiblePaneCount == 1`) so their zoomed pane tracks window resizes.
  `paneSize(for:in:)` returns a hidden pane's remembered `sizeBySession` entry.
  Rationale: hidden panes must keep their last size (Decision above), and
  inactive single-visible-pane tabs already resized with the window.
  Date/Author: 2026-10-01 / executing agent.

- Decision: M3 behaviour details the plan left open.
  (1) `splitPane` only unzooms once the split is accepted: a refused or failed
  split leaves the tree, registry and zoom untouched. (2) The 10x3 minimum is
  not checked while the pixel area is still zero (before the view's first
  layout), because nothing can be measured; the view resizes afterwards.
  (3) `focusPane(inTab:direction:)` unzooms only when it finds a neighbour; at
  an edge it changes nothing, zoom included, matching "the chord does nothing
  at the edge". `focusPane(inTab:sessionId:)` itself unzooms when the target
  is not the zoomed pane, so control-plane `pane.focus` by ID cannot leave
  focus on a hidden pane. (4) `nudgeDivider` returns false while zoomed (the
  dividers are hidden) and works in whole pixels (`floor(extent*fraction)` plus
  or minus `cells` cell extents) so two cells is exactly two columns; clamped
  fractions get half a pixel added to the lower bound so the layout's floor
  cannot leave a pane one column under the minimum. (5) Equalize keeps zoom.
  (6) The sync-cache invalidation the plan asks for in `setPaneZoom` is done by
  firing `onSessionsReplaced`, which `TerminalSurfaceController` already wires
  to `invalidateSessionSyncCache()`; the model cannot call the controller.
  (7) `TabState.zoomedSessionId` is also dropped on decode when the tab has
  only one pane, and restore sizes a persisted zoomed pane to the full area.
  Rationale: keep every command atomic and let the existing hooks carry the
  redraw.
  Date/Author: 2026-10-01 / executing agent.

- Decision: M5 behaviour details the plan left open.
  (1) `pane.focus` with a direction word that finds no neighbour is a successful
  no-op (200), mirroring the keyboard chord; an unknown word is 400. (2)
  `pane.resize` with a `direction` and no `path` that finds no divider, or whose
  divider is at its limit, is also a 200 no-op because `nudgeDivider` cannot tell
  the two apart; a `path` without `fraction`, or neither, is 400, and any path
  component other than `first`/`second` is `notSplit`. (3) The headless drag keeps
  its proposal in `HeadlessDebugRuntime.dividerDrag` (`beginDividerDrag`,
  `updateDividerDrag`, `commitDividerDrag`, `cancelDividerDrag`); the one-shot
  `mouseDrag` action runs all three, and M6's preview rendering and multi-point
  test drive the same methods directly. A click or drag that names a `sessionId`
  skips divider hit-testing, so scripts can still address a pane by ID. (4)
  `TabResponse.zoomedSessionId` is optional and omitted (not `null`) when the tab
  is not zoomed; the schema allows both. `schemas/debug/action.schema.json` is
  hand-maintained, so it was edited directly.
  Rationale: keep every command atomic, idempotent and symmetrical with the GUI.
  Date/Author: 2026-10-01 / executing agent.

- Decision: M6 behaviour details the plan left open.
  (1) `TerminalSurfaceFrameRequest.dividerPreview` carries the finished rect, built by
  `PaneDivider.previewRect(axis:container:fraction:)` (3 pixels thick, centred on the
  proposed cut, spanning the container). The GUI drag in M7 must use the same helper.
  (2) `Theme` has no focus-ring accent; the sidebar's selected-row stripe and drop
  accent use `Theme.current.blue`, so the preview is that colour at alpha 0xB3
  (`TerminalSurfaceController.dividerPreviewAlpha`). It is appended after the
  dividers and skipped while the tab is zoomed. (3) The preview position is the
  clamped fraction: `AppModel.clampedSplitFraction(inTab:path:fraction:)` (new,
  public) exposes what `setSplitFraction` will apply, and the headless
  `updateDividerDrag` stores it, so the line never shows a position the commit
  would refuse. M7's GUI drag should call the same method. (4) The zoom badge
  `SidebarProducer.zoomBadgeText(paneCount:)` ("\u{2922} N") is drawn on the title line
  right-aligned just left of the status slot (the slot itself keeps the attention
  marker / close glyph), and the title truncates by badge width plus one cell. (5)
  `SidebarCacheSignature.Entry` gained `zoomedPaneCount` so the memoised sidebar
  rebuilds when a tab zooms or unzooms. (6) The badge is not added to
  `Localizable.xcstrings`: it is a symbol and a number built in `LabanCore`, which has
  no access to `L10n` (app target), and no string audit reads the catalog for unused
  keys, so a catalog entry would be dead. (7) Tests live in `SplitPaneHeadlessTests`
  (so the Review Gate filter finds them) with `lastFramePaneSessionIds` on the
  headless runtime to show which frame path ran.
  Rationale: keep the preview honest, the sidebar cache correct and the GUI and
  headless paths identical.
  Date/Author: 2026-10-01 / executing agent.

- Decision: M7 fixes the layout orientation instead of papering over it at each
  consumer. `PaneTree.partition` for a horizontal split places `first` at the high-y
  end (render and view space, y up); sizes are unchanged (`first` is still
  `floor(extent * fraction)` tall). `directionalNeighbour` treats `.up` as larger y.
  `PaneDivider.previewRect` and the new `PaneDividerDrag` (shared by the view and the
  headless runtime) measure a horizontal fraction down from the container's top. The
  headless runtime converts debug coordinates (top-down) with `windowHeight - y` in
  `paneHit`, `dividerHit` and drag updates. The view's `terminalMouseGeometry`,
  `selectionGeometry` (new `GridGeometry.originY`) and IME `firstRect` subtract or add
  the pane's `minY`. `PaneTreeTests` rects that hard-coded the old y-down arrangement
  (`testDividersCarryPathsInNestedTree`, `testSettingFractionByPath`,
  `testPreviewRectCentresOnProposedPositionAndSpansContainer`) were corrected, not
  weakened.
  Rationale: one coordinate space (the renderer's) for every layout rect keeps every
  later consumer correct by construction. Flipping inside `Tab.visibleLayout` would
  have left `PaneTree` and the controller in different spaces.
  Date/Author: 2026-10-01 / executing agent.

- Decision: M7 behaviour details the plan left open.
  (1) The AppCommand names the headless key path logs are
  `TerminalInputCaptureMetadata.captureName`'s: `splitPaneDown`, `closePaneOrTab`,
  `togglePaneZoom`, `equalizePanes`, and `focusPane`/`paneOrTabNavigation`/
  `nudgeDivider` plus `Left|Right|Up|Down`. Cmd+Control+Left/Right no longer fall into
  the Cmd+Arrow readline line-edit bytes (`commandLineEditingBytes` excludes Control,
  in the app and the headless mirror). (2) The drag preview shows from the press (on
  the divider's own position) and follows the pointer; a release commits only when the
  clamped fraction differs from where the drag began, so a click changes nothing and
  moves no focus. A double-click equalizes and consumes the rest of the gesture.
  Escape cancels. The preview position is `AppModel.clampedSplitFraction`. (3) Pane
  navigation treats the laband backend like an unsplit tab (it only ever shows the
  focused pane), so Cmd+Option+Left/Right keep switching tabs there; the split items
  stay disabled on laband. (4) Menus: File has "Close Tab" (retitled "Close Pane" in a
  split tab) on Cmd+W with Cmd+Option+W as its alternate item (shown while Option is
  held), then Split Pane Right/Down. View gets a "Pane" submenu. "Select Pane Left"
  and "Select Pane Right" carry no key equivalent (see Surprises); "Select Pane
  Above/Below" carry Cmd+Option+Up/Down. "Focus Next/Previous Pane" were renamed
  "Select Next/Previous Pane" and moved into the Pane submenu, so the old strings are
  gone from the catalog. Menu items that need a direction carry it in
  `representedObject`. (5) Accessibility increment and decrement address their own
  divider through the new `AppModel.nudgeDivider(inTab:path:towardsSecond:cells:)`
  rather than the focused pane's nearest divider, because VoiceOver can focus a
  divider the focused pane does not border; both overloads share one two-cell step.
  The splitter elements are cached by tab, path, rect and fraction and rebuilt as soon
  as any of them changes. (6) "Not enough room to split this pane" and "Pane divider"
  are localised through `L10n`; the notice is built in the view because `LabanCore`
  has no `L10n`.
  Rationale: keep every command atomic and the GUI and headless paths symmetrical.
  Date/Author: 2026-10-01 / executing agent.

## Review Gate

A separate agent with fresh state must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed. See "Review gate and review-fix loop" in
`PLANS.md`. All commands run from the repository root. The executing agent
records `BASE` here in M0: `BASE = 958c85b502529fd194ef73ba966b2bb782e1511b`.

- [ ] `git diff --stat $BASE -- Sources/Labpty Sources/Laband` prints nothing.
- [ ] `swift test --filter PaneTreeTests` exits 0 and output contains
      `testDividersCarryPathsInNestedTree`, `testSettingFractionByPath`,
      `testEqualizeGivesThreeColumnsOneThirdEach`,
      `testDirectionalNeighbourPrefersAdjacentOverWiderOverlap`,
      `testDirectionalNeighbourUsesHistoryOnTie` and
      `testMinimumExtentSumsAlongAxisAndMaxesAcross`.
- [ ] `swift test --filter AppModelTests` exits 0 and output contains
      `testSplitDownNestsInsideVerticalSplit`, `testSplitRefusedBelowMinimumSize`,
      `testZoomResizesOnlyZoomedPane`, `testSplitWhileZoomedUnzoomsFirst`,
      `testCloseZoomedPaneUnzooms` and `testDividerNudgeClampsToMinimumExtent`.
- [ ] `swift test --filter PersistenceRoundTripTests` exits 0 and output
      contains `testNestedMixedAxisTreeRoundTrips` and
      `testZoomedSessionRoundTripsAndInvalidZoomIsDropped`.
- [ ] `swift test --filter SplitPaneHeadlessTests` exits 0 and output contains
      `testThreePaneLayoutRendersThreeOriginsAndTwoDividers`,
      `testZoomedTabUsesSinglePaneFrame` and `testDividerDragCommitsOnRelease`.
- [ ] `swift test --filter HeadlessIntentRouterTests` exits 0 and output
      contains `testPaneResizeByPath`, `testPaneFocusByDirection`,
      `testPaneZoomToggle` and `testPaneEqualize`.
- [ ] `swift test --filter TerminalKeyInputTests` exits 0 and output contains
      `testCommandShiftDSplitsDown`, `testCommandWClosesPaneOrTab`,
      `testCommandOptionWClosesTab` and
      `testCommandOptionArrowNavigatesPanesOnlyWhenSplit`.
- [ ] `swift test --filter DebugRuntimeKeyInputTests` exits 0 and its new
      cases mirror the four key cases above.
- [ ] `swift test --filter CatalogParityTests` exits 0 and
      `git diff $BASE -- Tests/LabanAppTests/CatalogParityTests.swift` prints
      nothing.
- [ ] `swift run LabanControlGen --check` exits 0.
- [ ] `./scripts/test-e2e` exits 0 and stdout contains
      `split-pane-2 scenario: ok`.
- [ ] `./scripts/test-labanapp-survives-restart` exits 0 and
      `grep -n "func testNestedSplitSurvivesLabanAppRestartViaLabpty" Tests/LabanAppTests/LabanAppTests.swift`
      prints one hit.
- [ ] `LABAN_CHECK_NO_MEMO=1 ./scripts/check` exits 0.
- [ ] The screenshots `03-three-panes.png`, `05-dragged.png` and
      `06-zoomed.png` under the scenario's artifact directory were opened and
      show, respectively: three panes and two dividers; a left pane about one
      third wide; one pane filling the terminal area with no divider.
- [ ] Mutation: in `PaneTree.directionalNeighbour`, swap the order of the
      directional-distance and overlap-length comparisons; expect
      `testDirectionalNeighbourPrefersAdjacentOverWiderOverlap` to fail;
      revert.
- [ ] Mutation: in `Tab.visibleLayout(in:)`, ignore `zoomedSessionId`; expect
      `testZoomResizesOnlyZoomedPane` and `testZoomedTabUsesSinglePaneFrame` to
      fail; revert.
- [ ] Mutation: in the GUI drag handler, call `model.setSplitFraction` from
      `mouseDragged` instead of `mouseUp`; expect
      `testDividerDragCommitsOnRelease` (headless) and
      `testDividerDragDoesNotResizeBeforeRelease` (AppKit) to fail; revert.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Surprises & Discoveries

- Observation: `Cmd+Option+Left/Right` already switch tabs, and
  `commandLineEditingBytes` deliberately skips them so they never reach the
  shell.
  Evidence: `Sources/LabanApp/TerminalInputView.swift`, `routeCommand()`
  (`.arrowRight where modifiers.contains(.alt)` → `.selectNextTab`) and the
  comment above `commandLineEditingRoute()`.

- Observation: `Cmd+=` with Control is currently treated as "Bigger Text",
  because the `.equal` case does not look at Control.
  Evidence: `routeCommand()`, `case .equal: return .appCommand(.increaseFontSize)`.
  M7 adds the Control check before that case.

- Observation: the first plan's restriction to one vertical split lives in
  three places, not in the tree.
  Evidence: `AppModel.splitPane` (`guard axis == .vertical, _tabs[idx].allSessionIds.count == 1`,
  `Sources/LabanCore/AppModel.swift` around line 709),
  `TerminalBitmapView.validateMenuItem` (`allSessionIds.count == 1` around line
  9756), and the menu offering only "Split Pane Right". `PaneTree.splitting`
  already handles any leaf at any depth.

- Observation: the ranking tuple needs tolerances when comparing floating-point
  rects. Overlap and centre offset are compared with a 1 pixel tolerance and
  directional distance with 0.5, otherwise a one-pixel difference caused by the
  divider (for example a 300 and a 299 pixel tall stacked pane) would beat the
  focus-history tie-break. The history test uses a 601 pixel tall area so the
  halves are exactly equal.
  Evidence: `PaneTree.directionalNeighbour`, `testDirectionalNeighbourUsesHistoryOnTie`.

- Observation: the remaining `allSessionIds.count` sites after M2 are deliberate:
  `AppModel.splitPane` (M3 rewrites it), `TerminalBitmapView` 9326 (focus next
  pane) and 9756/9759 (`validateMenuItem`, M7), `LiveIntentRouter` 551,
  `ControlStateProjections` 67 and `DebugPaneActions` 30 (all marked unchanged
  in the table).

- Observation: the plan's premise "the view's coordinate system is flipped
  (`isFlipped` is true), so top is the smaller y" is wrong. `TerminalBitmapView`
  does not override `isFlipped`, the sidebar rows are placed at
  `height - (i + 1) * rowHeight - topInset`, `terminalGridOriginY` measures from the
  pane's bottom, and the Metal and software renderers are y-up. M1 laid a
  horizontal split out with `first` at the smaller y, which is the *bottom* on
  screen: Split Down would have put the new pane above the old one and
  Cmd+Option+Up/Down would have moved the wrong way. It was invisible until M7 because
  the tests only compared layout rects with each other and the first plan only
  split left/right. The mouse, selection and IME geometry in the view also ignored a
  pane's `minY`, so a pane stacked above another mapped clicks to the wrong row.
  Evidence: `PaneTree.partition` (now places `first` at the high-y end),
  `PaneTree.directionalNeighbour` (`.up` now means larger y),
  `TerminalBitmapViewDividerTests.testSplitDownPlacesNewPaneBelowTheOriginal` and
  `testSelectionInUpperPaneUsesItsOwnOrigin` (the latter fails if the pane origin is
  dropped from `selectionGeometry`).

- Observation: Cmd+Option+Left/Right cannot be menu key equivalents. They are the
  hold-to-peek tab gesture (`peekCommitModifiers`), and the Tab menu deliberately
  carries no key equivalent for them because AppKit would match the chord ahead of
  `keyDown`. The same reasoning applies to "Select Pane Left/Right".
  Evidence: the comment above `previousItem` in `MenuCommands.swift`.

## Outcomes & Retrospective

(fill in at milestones and at completion)

## Context and Orientation

### What the first plan built (all in the tree at `fda71c45`)

1. **Pane tree.** `Sources/LabanCore/PaneTree.swift` defines `PaneAxis`,
   `PaneTree` and `PaneRect`. Operations: `leafSessionIds()` (in order),
   `contains`, `splitting(leaf:axis:newSessionId:newFirst:)` (works at any
   depth), `removing(leaf:)` (collapses the survivor upward),
   `settingFraction(ofSplitContaining:to:)` (only finds a split with a direct
   leaf child; clamps 0.1–0.9), `layout(in:dividerWidth:)` and
   `dividerRects(in:dividerWidth:)`. The private `partition` cuts a rect at
   `floor(extent * fraction)`, then a divider of `dividerWidth` pixels, then
   the rest. Tests: `Tests/LabanCoreTests/PaneTreeTests.swift` (nine cases).
2. **Tab.** `Sources/LabanCore/Tab.swift`: `panes`, `focusedSessionId`,
   `focusHistory` (runtime MRU), computed `allSessionIds`, and
   `focusing(_:)` (a copy with another focused session, used to address
   daemon calls).
3. **AppModel** (`Sources/LabanCore/AppModel.swift`, around lines 695–815):
   `PaneError { notALeaf, unknownSession, unsupportedBackend, daemonRefused }`;
   `splitPane(inTab:axis:openSession:)` (currently refuses unless vertical and
   unsplit); `makePaneSession(id:inTab:size:cwd:)`; `closePane(inTab:sessionId:terminate:)`
   (focus returns to the last entry in `focusHistory`);
   `focusPane(inTab:sessionId:)` (saves and restores per-pane title metadata
   and status, acknowledges attention, then calls `resizeTabLayoutsUnlocked()`);
   `focusAdjacentPane(inTab:forward:)` (cycles in-order leaves).
   Sizes: `currentSize` is the full terminal area; `sizeBySession` holds each
   pane's size; `terminalRects(for:)` (around line 60) lays out a tree in a
   zero-origin area with `paneInsets`; `resizePanes(in:insets:cellWidth:cellHeight:)`
   (around line 1905) is called by the view on window resize;
   `resizeTabLayoutsUnlocked()` (around line 1945) resizes the active tab and
   every single-pane tab; `resize(layout:cellWidth:cellHeight:)` sends a resize
   only for sessions whose size changed and records a capture timeline event.
   `postTabNotice(forTab:note:text:)` shows a one-line message in a tab.
4. **Rendering.** `TerminalSurfaceController.makeFrame` sends a tab with more
   than one session to `makeSplitFrame` (around line 1043), which lays out the
   tab, draws each pane's background, terminal content and cursor (hollow when
   unfocused) at the pane's origin, then one `.rect` per divider in
   `Theme.current.dim0`. The request carries `panes: [TerminalSurfacePaneRequest]`
   and `dividers: [CGRect]`; when empty, the controller computes them from the
   tree. `syncSessions` treats an item as visible when its tab is active.
5. **Input.** `TerminalBitmapView.paneHit(at:)` (around line 8296) and
   `focusedPaneRect` (around line 8286) lay out the active tab inside
   `x >= sidebarWidth`. `mouseDown` focuses the pane under the pointer; mouse,
   selection and IME geometry are per pane. Commands `splitPaneRight`,
   `closePane`, `focusNextPane`, `focusPreviousPane` are at around lines
   9295–9345 and are enabled in `validateMenuItem` (around line 9754). Key
   routes are in `TerminalInputView.routeCommand()`; capture names in
   `TerminalInputCaptureMetadata.swift`; the headless mirror is
   `Sources/LabanDebug/DebugRuntimeKeyInput.swift` and the `appCommand`
   handling in `Sources/LabanDebug/DebugInputActions.swift` (around line 220).
6. **Headless.** `HeadlessDebugRuntime.paneHit(x:y:sessionId:)` (around line
   1114) and a layout call around line 963. `DebugPaneActions.apply` handles
   `pane.split` (accepts an `axis` string), `pane.close`, and `pane.focus`
   (`sessionId` or `direction: next|previous`). `DebugMouseActions` accepts a
   `sessionId` to click in a given pane.
7. **Persistence.** `TabState` in `WorkspaceState.swift` stores `panes`,
   `focusedSessionId` and `paneStates`; decoding validates pane identities
   and falls back to a single leaf per tab on error. Because `PaneTree` is a
   recursive `Codable` enum, nested and horizontal trees already encode.
8. **Control plane.** `pane.split`, `pane.close`, `pane.focus` in
   `IntentCatalog.swift` (around line 869), `headlessOnly`. The state
   projection (`Sources/LabanCore/Control/Projections/ControlStateProjections.swift`)
   emits each tab's `panes` and `focusedSessionId`.

### Every place that assumes "split means two side-by-side panes"

Run `grep -rnE "allSessionIds\.count|panes\.layout|dividerRects" Sources` to
list them. At `fda71c45` they are:

| Site | Today | After this plan |
| --- | --- | --- |
| `AppModel.swift` `splitPane` guard | vertical only, unsplit only | any axis, any leaf, minimum size check |
| `AppModel.swift` `terminalRects(for:)`, `resizePanes`, `resizeTabLayoutsUnlocked` | whole tree | `visibleLayout` |
| `TerminalSurfaceController.swift` `makeFrame` (`allSessionIds.count > 1`, two places around 1172 and 1512) | split path when >1 session | split path when visible layout >1 |
| `TerminalSurfaceController.swift` `makeSplitFrame` layout and dividers | whole tree | `visibleLayout`, dividers empty when zoomed |
| `TerminalBitmapView.swift` around 2153 and 4278 (`allSessionIds.count == 1` gates the cell payload) | | visible layout count == 1 |
| `TerminalBitmapView.swift` around 4330 (frame request panes), `focusedPaneRect`, `paneHit` | whole tree | `visibleLayout` |
| `TerminalBitmapView.validateMenuItem` | split enabled only when unsplit | enabled unless laband; see M7 |
| `HeadlessDebugRuntime.swift` around 963 and 1122 | whole tree | `visibleLayout` |
| `ControlStateProjections.swift` around 67 and 386 | | 386 uses `visibleLayout`; 67 (scoped attention) unchanged |
| `LiveIntentRouter.swift` around 551 (scoped screenshot allowed only when unsplit) | | unchanged: hidden panes still exist |
| `DebugPaneActions.swift` `lastPane` check | | unchanged |

## Plan of Work

### M0: Baseline

Record `BASE` (`git rev-parse HEAD`) in the Review Gate and run
`./scripts/check`. Do not start until it is green.

### M1: Pane tree geometry

All additions go in `Sources/LabanCore/PaneTree.swift`; all are pure
functions with no AppKit dependency.

1. `public enum PaneSide: String, Codable, Sendable { case first, second }`
   and `public typealias PanePath = [PaneSide]`.
2. `public enum PaneDirection: String, Codable, Sendable { case left, right, up, down }`
   with a computed `axis` (`left/right` → `.vertical`, `up/down` →
   `.horizontal`) and `towardsSecond` (`right` and `down` are true).
3. `public struct PaneDivider: Equatable { path: PanePath; axis: PaneAxis; rect: CGRect; container: CGRect; fraction: Double }`.
   `container` is the rect the split occupies; drag math converts a pointer
   position into `(pointer - container.min) / container.extent`.
4. `public func dividers(in:dividerWidth:) -> [PaneDivider]` replaces the
   body of `dividerRects` (which becomes `dividers(...).map(\.rect)`, so
   existing callers keep working).
5. `public func settingFraction(at path: PanePath, to value: Double) -> PaneTree?`
   returns nil if the path does not name a split; clamps to 0.05…0.95.
   Rewrite `settingFraction(ofSplitContaining:to:)` on top of it.
6. `public func path(toLeaf id: Session.ID) -> PanePath?`.
7. `public func minimumExtent(along axis: PaneAxis, leafMinimum: CGFloat, dividerWidth: CGFloat) -> CGFloat`:
   a leaf is `leafMinimum`; a split of the same axis is the sum of both
   children plus `dividerWidth`; a split of the other axis is the maximum of
   both children.
8. `public func fractionRange(at path: PanePath, in rect: CGRect, minimumWidth: CGFloat, minimumHeight: CGFloat, dividerWidth: CGFloat) -> ClosedRange<Double>?`:
   for the split at `path`, finds its container (via `dividers`) and returns
   the range that keeps `first` and `second` at or above their minimum
   extents. If the container is too small for both, it returns the single
   value that splits the shortfall evenly, so a drag can never invert.
9. `public func equalized() -> PaneTree` using the weight rule in the Decision
   Log.
10. `public func directionalNeighbour(of id: Session.ID, direction: PaneDirection, in rect: CGRect, dividerWidth: CGFloat, history: [Session.ID]) -> Session.ID?`.
    Lay the tree out. Candidates are panes entirely on the requested side of
    the focused pane: for `.right`, `candidate.minX >= focused.maxX`, and the
    other three directions by symmetry. Discard candidates with zero
    perpendicular overlap unless there are no others. Rank by the tuple in the
    Decision Log; history rank is the index in `history` (higher is more
    recent; absent is -1). Return nil if there is no candidate.
11. `public func nudgeTarget(for id: Session.ID, direction: PaneDirection) -> PanePath?`:
    walk from the leaf toward the root; return the first split whose axis is
    `direction.axis` and where the leaf is in `first` when `towardsSecond`
    (or in `second` when not).
12. Widen the clamp in `partition` from 0.1…0.9 to 0.05…0.95.

Tests in `Tests/LabanCoreTests/PaneTreeTests.swift`, added next to the
existing nine (update `testFractionClamped` to the new bounds):

- `testDividersCarryPathsInNestedTree`: `A | (B / C)` in 1000×600 gives two
  dividers with paths `[]` and `[.second]`, axes vertical and horizontal, and
  the second divider's container is the right half.
- `testSettingFractionByPath`: set `[.second]` to 0.25 and check C's rect.
- `testSettingFractionAtLeafPathReturnsNil`.
- `testEqualizeGivesThreeColumnsOneThirdEach`: `A | (B | C)` → widths within
  one pixel of 333.
- `testEqualizeMixedAxisTreatsOtherAxisAsOne`: `A | (B / C)` → root 0.5.
- `testDirectionalNeighbourPrefersAdjacentOverWiderOverlap`: `A | (B / C) | D`
  built as `A | ((B / C) | D)`; right from A gives B or C, never D.
- `testDirectionalNeighbourUsesHistoryOnTie`: right from A with history
  `[C, A]` gives C; with `[B, A]` gives B.
- `testDirectionalNeighbourAtEdgeIsNil`.
- `testMinimumExtentSumsAlongAxisAndMaxesAcross`.
- `testFractionRangeKeepsBothSidesAboveMinimum`.
- `testNudgeTargetFindsNearestEnclosingSplitOnThatSide`.

### M2: Zoom state and the visible layout

1. `Tab` gains `public var zoomedSessionId: Session.ID?` (default nil) and
   `public func visibleLayout(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneRect]`,
   which returns `[PaneRect(sessionId: zoomed, rect: rect)]` when
   `zoomedSessionId` is set and still in the tree, and `panes.layout(...)`
   otherwise. Add `public var isZoomed: Bool` and
   `public func visibleDividers(in:dividerWidth:) -> [PaneDivider]` (empty
   when zoomed).
2. Replace every "whole tree" call in the table in `Context and Orientation`
   with `visibleLayout` / `visibleDividers`, and every "split frame" test
   (`allSessionIds.count > 1` or `== 1` in the renderer and view) with the
   visible layout count. Leave the rows marked "unchanged" alone.
3. `AppModel.resizeTabLayoutsUnlocked()` resizes only sessions in the visible
   layout. Hidden (zoomed-away) panes keep their entry in `sizeBySession`.
4. `TerminalSurfaceController.syncSessions` marks an item visible only when it
   is in the active tab's visible layout.

No user-visible change yet: nothing sets `zoomedSessionId`.

### M3: AppModel pane API

In `Sources/LabanCore/AppModel.swift`. Each method takes the model lock, ends
with `resizeTabLayoutsUnlocked()` where geometry changes, and calls
`notifyWorkspaceMutation()` after the lock, like the existing pane methods.

1. `PaneError` gains `tooSmall` and `notSplit`.
2. `splitPane`: delete the `axis == .vertical, count == 1` guard. If the tab
   is zoomed, unzoom first. Split `focusedSessionId`. Before opening the
   session, lay out the new tree with `terminalRects(for:)` and throw
   `tooSmall` if either new pane is under 10 columns or 3 rows (use
   `Self.size(rect:cellWidth:cellHeight:)`). Rename nothing else; the
   existing rollback on `openSession` failure stays.
3. `public func focusPane(inTab:direction:)`: unzoom if zoomed, call
   `directionalNeighbour` with `terminalRects` geometry and `focusHistory`, and
   `focusPane(inTab:sessionId:)` on the result. Return `Bool` (moved or not)
   so the view can ignore no-ops. `focusAdjacentPane` also unzooms first.
4. `public func setSplitFraction(inTab:path:fraction:) throws`: clamp `fraction`
   into `fractionRange(at:...)` computed with the current cell size (minimum
   width `10 * cell_width`, height `3 * cell_height`, plus the pane insets),
   then apply. Throws `notSplit` for a bad path.
5. `public func nudgeDivider(inTab:direction:cells: Int = 2) -> Bool`: find
   `nudgeTarget` for the focused pane, convert `cells` into a fraction delta
   of that split's container extent, call `setSplitFraction`. Moving towards
   `second` grows `first`.
6. `public func equalizePanes(inTab:)`.
7. `public func setPaneZoom(inTab:zoomed: Bool?)`: `nil` toggles. Zooming a
   one-pane tab is a no-op. Zooming sets `zoomedSessionId = focusedSessionId`.
   Call `invalidateSessionSyncCache` so the newly visible panes draw their
   latest content on unzoom.
8. `closePane`: if the closed pane is zoomed, or the tree drops to one leaf,
   clear `zoomedSessionId`.

Tests in `Tests/LabanCoreTests/AppModelTests.swift` (use the same fixture
sessions the existing pane tests use):
`testSplitDownNestsInsideVerticalSplit`, `testSplitRefusedBelowMinimumSize`
(tiny `currentSize`, expect `tooSmall` and an unchanged tree and registry),
`testFocusByDirectionMovesToNeighbour`, `testZoomResizesOnlyZoomedPane`
(zoom; the zoomed session's size equals the full area; the hidden session's
size is unchanged), `testSplitWhileZoomedUnzoomsFirst`,
`testCloseZoomedPaneUnzooms`, `testEqualizeResizesAllPanes`,
`testDividerNudgeClampsToMinimumExtent`, `testSetFractionByUnknownPathThrows`.

### M4: Persistence

`TabState` (`Sources/LabanCore/Persistence/WorkspaceState.swift`) gains
`zoomedSessionId: String?`. Encode it; decode it with `decodeIfPresent` and
drop it (set nil, keep the rest of the tab) if it is not in the tree. The
schema version stays 2: the field is optional and older binaries ignore
unknown keys. `snapshotForPersistence` writes it and restore sets it on the
tab.

Tests in `Tests/LabanCoreTests/PersistenceRoundTripTests.swift`:
`testNestedMixedAxisTreeRoundTrips` (three panes, `A | (B / C)` with
fractions 0.3 and 0.6, focus on C) and
`testZoomedSessionRoundTripsAndInvalidZoomIsDropped`.

### M5: Headless control plane

1. `PaneActionRequest` (in `Sources/LabanCore/Intents/DebugRequestPayloads.swift`)
   gains `path: [String]?`, `fraction: Double?`, `zoomed: Bool?`; `direction`
   now also accepts `left|right|up|down`.
2. `IntentCatalog.swift`: update the `pane.split` summary to "Split the
   focused pane left/right or top/bottom.", and add `pane.resize` (`.input`),
   `pane.equalize` (`.input`) and `pane.zoom` (`.input`), all `headlessOnly`,
   category `pane`, sensitivity `.nonSensitiveState`. They resize other
   processes' PTYs, which is why they are `.input` like split and close.
3. `DebugPaneActions.apply`: `pane.split` passes `axis` through and maps
   `tooSmall` to error code `tooSmall` (400). `pane.focus` with a direction
   word calls `focusPane(inTab:direction:)`. `pane.resize` with `path` and
   `fraction` calls `setSplitFraction`, or with `direction` alone calls
   `nudgeDivider`; bad path → `notSplit` (400). `pane.equalize` and
   `pane.zoom` call their model methods. Add the new action names to the
   router in `DebugRuntimeRequests.swift`.
4. State projection: each tab gains optional `zoomedSessionId`. Update
   `ControlResponseModels.swift`, `Sources/LabanDebug/DebugModels.swift` and
   `schemas/debug/state.schema.json` (`$defs.tab.properties.zoomedSessionId`,
   type `["string","null"]`, not required). Add the new actions to
   `schemas/debug/action.schema.json` and to the endpoint list in
   `docs/process/dev-process.md`, then run
   `swift run LabanControlGen --write`.
5. Divider drag parity: `HeadlessDebugRuntime` gains
   `dividerHit(x:y:) -> PaneDivider?` with the same grab zone as the GUI (3
   pixels either side). In `DebugMouseActions`, a drag whose start point hits
   a divider performs the same preview-then-commit as the GUI: no tree change
   during intermediate points, `setSplitFraction` once at the end. A plain
   click on a divider does nothing.

Tests in `Tests/LabanDebugTests/HeadlessIntentRouterTests.swift`:
`testPaneResizeByPath`, `testPaneFocusByDirection`, `testPaneZoomToggle`,
`testPaneEqualize`, `testPaneSplitTooSmallReturnsError`. Then
`DiscoveryEndpointParityTests` and `Tests/LabanCLITests/CLICatalogDriftTests.swift`
must pass after regeneration.

### M6: Rendering

1. `makeSplitFrame` already loops over any number of panes. With M2 it uses
   the visible layout and visible dividers; confirm with a three-pane test.
2. Drag preview: `TerminalSurfaceFrameRequest` gains
   `dividerPreview: CGRect?`. When set, `makeSplitFrame` appends one extra
   `.rect` after the dividers, 3 pixels wide (or tall) centred on the
   proposed position, coloured `Theme.current.accent` (use whatever accent
   colour `Theme` exposes for focus rings; if none, `dim0` at 60% alpha).
   Headless and GUI both pass it during a divider drag.
3. Zoom badge: `SidebarProducer` draws "⤢ N" right-aligned in the row of a
   zoomed tab, in the same style and slot as the row's existing secondary
   indicator, and the row's title truncation accounts for its width. Add the
   badge string to localisation (it is a symbol and a number, so it needs no
   translation, but add it so the string audit passes).

Tests in `Tests/LabanDebugTests/SplitPaneHeadlessTests.swift` (real shells,
as the existing cases do):
`testThreePaneLayoutRendersThreeOriginsAndTwoDividers` (type `printf A`,
`printf B`, `printf C` into the three panes and find each glyph run inside
its pane rect), `testZoomedTabUsesSinglePaneFrame` (frame has no divider
rect, the zoomed pane's text starts at the terminal-area origin, and the
frame's `paneSessionIds` is empty or one element), `testDividerDragCommitsOnRelease`
(drag from the divider through two points; after the intermediate points the
tree fraction is unchanged and the frame has a preview rect; after release
the fraction matches the release point within one cell and no preview rect
remains), `testUnzoomShowsOutputWrittenWhileHidden`.

### M7: GUI input, commands and accessibility

In `Sources/LabanApp/TerminalBitmapView.swift` unless noted.

1. **Divider hover.** `dividerHit(at:) -> PaneDivider?` with a 3-pixel grab
   zone, using `activeTab.visibleDividers(in: terminalArea)`. In
   `mouseMoved` (and `resetCursorRects` if the view uses cursor rects), show
   `NSCursor.resizeLeftRight` over vertical dividers and
   `NSCursor.resizeUpDown` over horizontal ones. Dividers take priority over
   terminal mouse reporting and selection: a press in the grab zone never
   reaches the shell.
2. **Drag.** `mouseDown` on a divider starts a `DividerDrag` (path, axis,
   container, allowed range from `fractionRange`). `mouseDragged` updates
   only the preview fraction and invalidates the frame. `mouseUp` calls
   `model.setSplitFraction(inTab:path:fraction:)` once, clears the preview
   and refreshes per-pane geometry the way `paneFocusChanged()` does. Escape
   during a drag cancels it. A double-click on a divider calls
   `equalizePanes`.
3. **Commands.** `AppCommand` (`TerminalInputView.swift` line 8) gains
   `splitPaneDown`, `closePaneOrTab`, `focusPane(PaneDirection)`,
   `paneOrTabNavigation(PaneDirection)`, `nudgeDivider(PaneDirection)`,
   `togglePaneZoom`, `equalizePanes`. Add their names to
   `TerminalInputCaptureMetadata.swift`.
   `routeCommand()` changes, in this order inside the `switch`:
   - `.d`: shift → `.splitPaneDown`, else `.splitPaneRight`.
   - `.w`: alt → `.closeTab`, else `.closePaneOrTab`.
   - `.equal where modifiers.contains(.control)` → `.equalizePanes`, placed
     before the existing `.equal` case.
   - `.enter where modifiers.contains(.shift)` → `.togglePaneZoom`.
   - arrows with `.control` → `.nudgeDivider(direction)`, placed before the
     arrow-with-alt cases.
   - `.arrowLeft/.arrowRight where alt` → `.paneOrTabNavigation(.left/.right)`
     (was `.selectPreviousTab/.selectNextTab`); `.arrowUp/.arrowDown where alt`
     → `.paneOrTabNavigation(.up/.down)`.
   `perform(_:)` handles `.paneOrTabNavigation(d)`: if the active tab's
   visible layout (ignoring zoom, so a zoomed split still counts as split) has
   more than one pane, call `model.focusPane(inTab:direction:)` and then
   `paneFocusChanged()`; otherwise, for left and right only, select the
   previous or next tab as before. `.closePaneOrTab` closes the focused pane
   when the tab has more than one pane and otherwise runs today's close-tab
   path. Splits catch `PaneError.tooSmall` and post the notice
   "Not enough room to split this pane".
4. **Menus** (`Sources/LabanApp/MenuCommands.swift`). File menu: "Split Pane
   Right" ⌘D, "Split Pane Down" ⇧⌘D, "Close" ⌘W (its title becomes "Close
   Pane" or "Close Tab" in `validateMenuItem`, the same in-place retitle the
   Debug capture item uses), "Close Tab" ⌥⌘W. New "Pane" submenu under the
   View menu: "Select Pane Left/Right/Above/Below" (⌥⌘ arrows), "Select Next
   Pane" ⌥⌘], "Select Previous Pane" ⌥⌘[, "Zoom Pane" ⇧⌘↩ (checked when
   zoomed), "Equalize Panes" ⌃⌘=, and a "Resize Pane" submenu with "Move
   Divider Left/Right/Up/Down" (⌃⌘ arrows). Remove "Focus Next/Previous Pane"
   from the File menu (they move here). `validateMenuItem`: split items are
   enabled unless the backend is laband; pane navigation, zoom and equalize
   are enabled when the tab has more than one pane; move-divider items when
   `nudgeTarget` exists for that direction.
5. **Localisation.** Add every new title to the source that
   `scripts/gen-localizable-xcstrings.py` reads (find "Split Pane Right" to see
   where) and regenerate `Sources/LabanApp/Resources/Localizable.xcstrings`.
6. **Headless key parity.** `Sources/LabanDebug/DebugRuntimeKeyInput.swift`
   mirrors every new route, and `DebugInputActions.swift` maps the new
   `appCommand` names to the M5 actions (`closePaneOrTab` → `pane.close` when
   split, else the existing close-tab path).
7. **Accessibility.** `accessibilityChildren()` on `TerminalBitmapView`
   appends one `NSAccessibilityElement` per visible divider (role
   `.splitter`, frame converted to screen coordinates, value = fraction as a
   0–100 number, `accessibilityPerformIncrement/Decrement` → `nudgeDivider` in
   the direction that grows/shrinks `first`). Rebuild them when the layout
   changes; do not keep stale elements.

Tests:
- `Tests/LabanAppTests/TerminalKeyInputTests.swift`:
  `testCommandShiftDSplitsDown`, `testCommandWClosesPaneOrTab`,
  `testCommandOptionWClosesTab`,
  `testCommandOptionArrowNavigatesPanesOnlyWhenSplit` (route plus `perform`
  on an unsplit and a split tab), `testCommandControlEqualEqualizesNotZoom`.
- `Tests/LabanDebugTests/DebugRuntimeKeyInputTests.swift`: the same four
  routes.
- A new `Tests/LabanAppTests/TerminalBitmapViewDividerTests.swift`:
  `testDividerDragDoesNotResizeBeforeRelease`,
  `testPressOnDividerIsNotSentToMouseTrackingApp`,
  `testAccessibilitySplitterPerDivider`.

### M8: End-to-end and measurement

1. `fixtures/debug-script-split-pane-2.scenario.json`, modelled on
   `fixtures/debug-script-split-pane.scenario.json` (no `"fixture"` key, so
   real shells run). Steps: `tab.new`; `pane.split` vertical; screenshot
   `01-two`; `pane.split` horizontal (splits the right pane); screenshot
   `03-three-panes`; `pane.focus` direction `left` and assert the focused ID
   is the first pane; type `printf LEFT` there and wait for it; mouse drag on
   the root divider to x = one third of the terminal area; assert root
   fraction within 0.02 of 0.333; screenshot `05-dragged`; `pane.zoom`;
   screenshot `06-zoomed`; assert `zoomedSessionId`; `pane.zoom` again;
   `pane.equalize`; assert root fraction 0.5; `pane.close` on the bottom-right
   pane; assert two leaves. Wire it into `scripts/test-e2e` so it prints
   `split-pane-2 scenario: ok`.
2. `Tests/LabanAppTests/LabanAppTests.swift`: add
   `testNestedSplitSurvivesLabanAppRestartViaLabpty` next to
   `testSplitTabSurvivesLabanAppRestartViaLabpty`: build `A | (B / C)` with
   root fraction 0.3, run `sleep 600` in each pane, zoom B, restart the app,
   assert all three child PIDs are alive, the tree and fractions match, and B
   is still zoomed. Wire it into `scripts/test-labanapp-survives-restart`.
3. Measure frame cost the way the first plan did (20 warmed headless frames,
   identical 24-row ASCII content per pane) for one, two and four panes, and
   record the medians in `Surprises & Discoveries` with the artifact path
   under `.artifacts/split-panes-2/perf/`. If four panes cost more than twice
   one pane, note it as the trigger for a multi-grid payload plan; do not
   start that work here.

### M9: Docs and review

- `docs/product/mvp.md`, "Later Milestones" item 1: say that nesting, both
  split directions, divider dragging, directional navigation, zoom and
  equalize are delivered by this plan, and that laband split rendering and a
  multi-grid GPU payload remain deferred.
- `docs/product/spec.md`: in section 9, change the ranking tuple to the one
  in the Decision Log and give the three-column example; in section 4, note
  the 10×3 minimum and the double-click-to-equalize; in section 17 add the
  pane shortcuts, including Cmd+W closing the focused pane.
- `docs/process/dev-process.md`: the new actions (done in M5; check).
- Run the Review Gate with a fresh agent.

## Concrete Steps

All commands run from `/Users/rrj/wrk/laban`.

    git rev-parse HEAD                       # record as BASE
    ./scripts/check                          # baseline, must be green

    # Fast loops
    swift test --filter PaneTreeTests
    swift test --filter AppModelTests
    swift test --filter PersistenceRoundTripTests
    swift test --filter HeadlessIntentRouterTests
    swift test --filter SplitPaneHeadlessTests
    swift test --filter TerminalKeyInputTests
    swift test --filter DebugRuntimeKeyInputTests
    swift test --filter TerminalBitmapViewDividerTests
    swift run LabanControlGen --write && swift run LabanControlGen --check
    ./scripts/check-debug-contract
    ./scripts/test-e2e
    ./scripts/test-labanapp-survives-restart

    # Manual checks in the real app
    ./scripts/build-app && ./scripts/install-app

    # Before the PR
    ./scripts/format && LABAN_CHECK_NO_MEMO=1 ./scripts/check

Expected `PaneTreeTests` tail once M1 is done (counts grow as tests are
added):

    Test Suite 'PaneTreeTests' passed at ...
         Executed 20 tests, with 0 failures (0 unexpected) in 0.0xx seconds

Commit once per milestone with a single-line reason, for example
`Let any pane split in either direction so tabs can hold real layouts` (M3),
`Resize panes by dragging a divider and commit the PTY size on release` (M7).
M7's keyboard remap is its own commit:
`Close the focused pane with Cmd+W and split down with Cmd+Shift+D`.

## Validation and Acceptance

Automated: every Review Gate item.

Manual, in the installed app on the labpty backend (the default):

1. New tab. Cmd+D, then Cmd+Shift+D. Three panes: one on the left, two
   stacked on the right. The bottom-right pane has the solid cursor.
2. Cmd+Option+Left: focus moves to the left pane. Cmd+Option+Right: focus
   moves to whichever right pane was focused last (bottom-right).
   Cmd+Option+Up: top-right. Cmd+Option+Up again: nothing happens, and the
   tab does not change.
3. In a single-pane tab, Cmd+Option+Right still switches to the next tab.
4. Hover the vertical divider: the cursor becomes a left-right resize arrow.
   Run `top` in the left pane and drag the divider. While dragging, a
   highlighted line follows the mouse and `top` does not redraw. On release,
   `top` redraws once at the new width.
5. Cmd+Control+Right in the left pane widens it by two columns.
   Cmd+Control+= makes all three panes share the space evenly.
6. Cmd+Shift+Return in the left pane: it fills the terminal area, the sidebar
   row shows "⤢ 3", and the GPU renderer is active (`laban state` shows the
   cell payload in use, if the field exists; otherwise check that the frame
   has no divider). Cmd+Shift+Return again restores the layout, and output
   written in the hidden panes meanwhile is visible.
7. `laban state` shows the nested `panes` tree with fractions, and
   `zoomedSessionId` while zoomed.
8. Cmd+Q, relaunch: same layout, same fractions, same zoom state, `top` still
   running, no "unclaimed sessions" dialog.
9. Cmd+W in the top-right pane closes only that pane. Cmd+W twice more leaves
   one pane, then closes the tab. Cmd+Option+W on a split tab closes the
   whole tab.
10. Make the window very small and press Cmd+D repeatedly: eventually the
    notice "Not enough room to split this pane" appears and no new session is
    created (`laban state` session count unchanged).
11. With VoiceOver on, Control+Option+arrows reach a "splitter" element and
    Control+Option+Shift+Up/Down (increment/decrement) move the divider.

## Idempotence and Recovery

- Every milestone is additive until M7's key remap; M1–M6 can land and ship
  without changing any shortcut.
- The workspace schema version does not change. A file written by this plan
  opens in the previous binary: nested trees decode (the type is unchanged),
  and the unknown `zoomedSessionId` key is ignored. Before testing restore on
  your real workspace, copy `workspace.json` (Application Support folder named
  in `PersistenceStore.swift`) aside.
- labpty sessions are never terminated by layout changes; only closing a pane
  terminates its session. If a test leaves sessions behind, the next launch
  offers to adopt them, and `laban status` lists them.
- `./scripts/test-e2e` and the restart test clean their own `.tmp/<run-id>`
  directories.

## Artifacts and Notes

Expected shape of a nested tab in `laban state --json` (abridged):

    "panes": {"split": {"axis": "vertical", "fraction": 0.333,
      "first":  {"leaf": {"sessionId": "T1"}},
      "second": {"split": {"axis": "horizontal", "fraction": 0.5,
        "first":  {"leaf": {"sessionId": "S2"}},
        "second": {"leaf": {"sessionId": "S3"}}}}}},
    "focusedSessionId": "S3",
    "zoomedSessionId": null

A `pane.resize` request for the right-hand split:

    {"action": "pane.resize", "path": ["second"], "fraction": 0.7}

## Interfaces and Dependencies

No new libraries. Must exist at the end of the plan:

    // Sources/LabanCore/PaneTree.swift
    public enum PaneSide: String, Codable, Sendable { case first, second }
    public typealias PanePath = [PaneSide]
    public enum PaneDirection: String, Codable, Sendable { case left, right, up, down }
    public struct PaneDivider: Equatable {
      public let path: PanePath; public let axis: PaneAxis
      public let rect: CGRect; public let container: CGRect; public let fraction: Double
    }
    extension PaneTree {
      public func dividers(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneDivider]
      public func settingFraction(at path: PanePath, to value: Double) -> PaneTree?
      public func path(toLeaf id: Session.ID) -> PanePath?
      public func minimumExtent(along axis: PaneAxis, leafMinimum: CGFloat, dividerWidth: CGFloat) -> CGFloat
      public func fractionRange(at path: PanePath, in rect: CGRect, minimumWidth: CGFloat,
                                minimumHeight: CGFloat, dividerWidth: CGFloat) -> ClosedRange<Double>?
      public func equalized() -> PaneTree
      public func directionalNeighbour(of id: Session.ID, direction: PaneDirection, in rect: CGRect,
                                       dividerWidth: CGFloat, history: [Session.ID]) -> Session.ID?
      public func nudgeTarget(for id: Session.ID, direction: PaneDirection) -> PanePath?
    }

    // Sources/LabanCore/Tab.swift
    public var zoomedSessionId: Session.ID?
    public var isZoomed: Bool
    public func visibleLayout(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneRect]
    public func visibleDividers(in rect: CGRect, dividerWidth: CGFloat = 1) -> [PaneDivider]

    // Sources/LabanCore/AppModel.swift
    public enum PaneError: Error { case notALeaf, unknownSession, unsupportedBackend,
                                   daemonRefused(String), tooSmall, notSplit }
    @discardableResult public func focusPane(inTab: Tab.ID, direction: PaneDirection) -> Bool
    public func setSplitFraction(inTab: Tab.ID, path: PanePath, fraction: Double) throws
    @discardableResult public func nudgeDivider(inTab: Tab.ID, direction: PaneDirection, cells: Int = 2) -> Bool
    public func equalizePanes(inTab: Tab.ID)
    public func setPaneZoom(inTab: Tab.ID, zoomed: Bool?)

    // Sources/LabanApp/TerminalInputView.swift, AppCommand gains
    case splitPaneDown, closePaneOrTab, togglePaneZoom, equalizePanes
    case focusPane(PaneDirection), paneOrTabNavigation(PaneDirection), nudgeDivider(PaneDirection)

    // Control plane (headlessOnly): pane.resize, pane.equalize, pane.zoom;
    // pane.split accepts axis "horizontal"; pane.focus accepts left|right|up|down.

Unchanged and must stay unchanged: `Sources/Labpty/`, `Sources/Laband/`, the
labpty protocol, ADR 0036's rule that daemons have no pane concept, and the
`CatalogParityTests` allowlists.
