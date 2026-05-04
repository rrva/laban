# Make Tabs Track Agent Sessions Clearly

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then improve Laban's tab titles and sidebar rows for users
juggling many coding-agent terminal sessions.

## Purpose / Big Picture

Laban's MVP has vertical tabs, one shell session per tab, terminal title
updates, and process exit state. The current sidebar still shows only a
one-based number plus the first ten title characters. That is not enough for a
daily-driver workflow where several tabs may all run similar `claude`,
`cursor`, shell, test, or build processes across different repos, worktrees,
branches, and tasks.

After this work, each tab row should quickly answer three questions:

1. What task or session is this?
2. Which repo, worktree, or branch is it in?
3. Does it need attention?

The first milestone keeps MVP scope: it separates terminal title data from the
display title, bounds hostile title text, reflects exit/activity state, and
renders a compact two-line vertical tab row when space allows. Later milestones
add cwd, repo, branch, process, search, rename/freeze, and optional agent
metadata for Claude Code and Cursor-style sessions.

## Progress

- [x] (2026-05-04) Reviewed MVP title/sidebar requirements in
  `docs/product/mvp.md`: stable tab identity, bounded title, close affordance,
  terminal title updates, and visible exit state.
- [x] (2026-05-04) Inspected current code in `Sources/LabanCore/Tab.swift`,
  `Sources/LabanCore/AppModel.swift`, `Sources/LabanCore/SidebarProducer.swift`,
  `Sources/LabanTerminalCore/session.c`, and
  `Sources/LabanDebug/HeadlessDebugRuntime.swift`.
- [x] (2026-05-04) Incorporated web-backed research on Apple Terminal, VS
  Code, iTerm2, Kitty, WezTerm, tmux, Warp, Claude Code, and Cursor tab/session
  conventions.
- [x] (2026-05-04) Add a title metadata model with separate raw terminal title, user title,
  display title, title source, activity state, and exit state.
- [x] (2026-05-04) Update title extraction and AppModel updates so terminal title changes
  update metadata without changing tab/session identity.
- [x] (2026-05-04) Render bounded, non-overlapping sidebar rows with index, primary title,
  status/attention indicator, and a compact secondary metadata line when
  available.
- [x] (2026-05-04) Expose title metadata through debug state/session endpoints and tests.
- [x] (2026-05-04) Add debug-only `setTabTitle`, `freezeTabTitle`,
  `clearTabTitle`, and `setTabMetadata` actions so headless tests can drive
  title precedence and injected workspace/process metadata without adding UI.
- [ ] Add cwd/repo/process metadata discovery without shell-integration
  injection. The model, resolver, debug response fields, and debug injection
  path exist; real non-invasive discovery probes remain deferred.
- [ ] Add manual rename/freeze/color and search/filter after the core metadata
  model is stable. Model/debug rename and freeze exist; color, AppKit UI, and
  search/filter remain deferred.
- [ ] Add optional agent-aware metadata hooks for Claude Code and Cursor-style
  sessions.
- [ ] Feed title/metadata changes into the capture/replay plan so UI state is
  reproducible.
- [ ] Pass the Review Gate before marking this ExecPlan complete.

## Decision Log

- Decision: Treat terminal titles as one source of metadata, not as the tab's
  durable identity.
  Rationale: OSC 0/1/2 title changes can come from shell prompts, tmux/screen,
  ssh, TUI apps, or hostile output. The MVP already says title updates must
  not change tab identity, session identity, focus, or ordering. Storing raw
  terminal title separately lets Laban show it when useful without letting it
  erase a user/task title.
  Date/Author: 2026-05-04 / Codex.

- Decision: Optimize tab rows for task, workspace, and attention before
  agent-specific metrics.
  Rationale: The common failure mode with multiple coding agents is losing
  track of which task belongs to which repo/worktree/branch and whether it
  needs attention. Context percent, cost, token, or line-count badges may be
  useful later, but they add noise and require explicit agent integration.
  Date/Author: 2026-05-04 / Codex.

- Decision: Keep shell integration injection out of the MVP slice.
  Rationale: `docs/product/mvp.md` explicitly says no shell integration
  wrappers or OSC 133 injection are required in the MVP. This plan may parse
  metadata that processes already emit, such as OSC title and OSC 7 cwd, but
  injecting shell hooks is a later opt-in layer.
  Date/Author: 2026-05-04 / Codex.

- Decision: Use a composed display-title algorithm with explicit source
  precedence.
  Rationale: Mature terminal/editor tools separate title, description, cwd,
  process, progress, and status. Laban should compute a display title from
  multiple sources instead of relying on whichever signal arrived last.
  Date/Author: 2026-05-04 / Codex.

- Decision: Make same-repo/branch collision warnings a later high-value agent
  feature.
  Rationale: It directly helps users running multiple AI agents, because two
  sessions editing the same branch can conflict. It requires trustworthy repo
  and branch metadata plus worktree awareness, so it should not block the MVP
  title model.
  Date/Author: 2026-05-04 / Codex.

## Research Notes

The research behind this plan supports three broad conclusions:

- Mature terminals expose more than one title signal. Apple Terminal can build
  window titles from working directory, active process, shell command, profile,
  TTY, dimensions, and command key. VS Code separates terminal title and
  description and supports variables such as cwd, process, sequence, task, and
  progress. iTerm2 can search by title, command, host, user, profile,
  directory, and badge labels.
- OSC titles are useful but insufficient. Kitty and WezTerm both expose richer
  cwd/process/user-var metadata, and tmux distinguishes window names from pane
  titles while also tracking current, last, activity, bell, silence, and zoom
  flags.
- Claude Code and Cursor-style agent workflows make task label, repo,
  worktree, branch, attention state, and last activity more valuable than raw
  shell title. Claude Code can expose status-line metadata and supports
  session naming. Cursor's agent tabs optimize around separate histories,
  generated titles, user rename, and avoiding conflicts between tabs editing
  the same files.

Sources used while shaping this plan:

- Apple Terminal title settings:
  `https://support.apple.com/guide/terminal/change-the-title-shown-in-a-terminal-window-trml15228/mac`
- VS Code terminal appearance:
  `https://code.visualstudio.com/docs/terminal/appearance`
- VS Code shell integration:
  `https://code.visualstudio.com/docs/terminal/shell-integration`
- iTerm2 shell integration:
  `https://iterm2.com/documentation-shell-integration.html`
- iTerm2 badges and search:
  `https://iterm2.com/3.0/documentation-one-page.html`
- Kitty shell integration:
  `https://sw.kovidgoyal.net/kitty/shell-integration/`
- Kitty launch title/cwd options:
  `https://sw.kovidgoyal.net/kitty/generated/launch/`
- WezTerm pane metadata:
  `https://wezterm.org/config/lua/PaneInformation.html`
- WezTerm process/cwd/user variables:
  `https://wezterm.org/recipes/passing-data.html`
- tmux status/window flags:
  `https://manpages.debian.org/testing/tmux/tmux.1.en.html`
- Warp tabs:
  `https://docs.warp.dev/terminal/windows/tabs`
- Claude Code status line:
  `https://code.claude.com/docs/en/statusline`
- Claude Code CLI reference:
  `https://code.claude.com/docs/en/cli-reference`
- Cursor agent tabs:
  `https://docs.cursor.com/agent/chat/tabs`

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [ ] Run `./scripts/check` from the repository root; expect exit 0 and final
  output `check passed`.
- [ ] Run `swift test --filter TabTitleMetadataTests`; expect tests for title
  source precedence, hostile title bounding, manual title preservation,
  terminal-title fallback, repo/cwd fallback, process fallback, and `Tab N`
  fallback.
- [ ] Run `swift test --filter SidebarProducerTests`; expect tests proving row
  text is bounded, long titles do not overlap the close affordance, two-line
  rows fit within stable row height, active/exited/unseen states are rendered,
  and hit testing still selects/closes the intended tab.
- [ ] Run `swift test --filter LabanDebugTitleTests`; expect debug state and
  session responses to include `displayTitle`, `titleSource`, `terminalTitle`,
  `activityState`, `lastActivityAt`, and exit status where available.
- [ ] Run `swift test --filter LabanSessionTests`; expect terminal title bytes
  copied from libghostty remain bounded/owned and do not change session ID or
  tab ID.
- [ ] Run `./scripts/test-e2e`; expect title updates, exit state, and bounded
  sidebar rendering to be covered in the headless debug flow.
- [ ] Grep `Sources/LabanCore/Tab.swift`; expect `Tab` to store title metadata
  separately from stable IDs and session ID.
- [ ] Grep `Sources/LabanCore/SidebarProducer.swift`; expect no hard-coded
  `prefix(10)` truncation as the only title bound. Truncation must be based on
  available row width and close-control reservation.
- [ ] Feed a fixture or debug action with a title longer than 500 characters;
  expect the debug response and sidebar row to remain bounded and the app not
  to resize the sidebar.
- [ ] Manually run the AppKit app, create at least three tabs with similar
  shells, set different terminal titles, close one process, and verify the
  sidebar still makes the active task, title source, and exited state legible.

Review status: NOT REVIEWED

Local execution note: the executing agent ran the Review Gate commands that are
available locally, including `./scripts/check`, but did not mark the gate as
passed. Per this plan, the Review Gate still needs a fresh-state reviewer.

## Surprises & Discoveries

- Observation: Ghostty does not reliably surface an extremely large 5000-byte
  OSC title in a fixture snapshot, while a 600-byte title is accepted and is
  enough to prove Laban's hostile-title bounding behavior.
  Evidence: `swift test --filter LabanSessionTests` initially failed the new
  title-copy test with a nil snapshot title for the 5000-byte case; changing
  the fixture to 600 bytes made the bounded owned-copy test pass.

## Context and Orientation

The relevant current implementation is small:

- `Sources/LabanCore/Tab.swift` defines `Tab` with stable `id`, `position`,
  `title`, `isActive`, and stable `sessionId`.
- `Sources/LabanCore/AppModel.swift` creates, selects, closes, repositions, and
  retitles tabs. `updateTitle(_:forTab:)` currently writes directly into
  `tab.title`.
- `Sources/LabanCore/SidebarProducer.swift` draws the vertical sidebar. It
  currently renders `"\(tab.position) \(tab.title.prefix(10))"` and a close
  glyph. It does not render status, metadata, or two-line rows.
- `Sources/LabanTerminalCore/session.c` copies
  `GHOSTTY_TERMINAL_DATA_TITLE` into `LabanSnapshot.title` during snapshot.
- `Sources/LabanApp/TerminalBitmapView.swift` snapshots the active session and
  uses `FrameProducer` and `SidebarProducer` to render the visible frame.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` builds debug state and
  session responses. In session responses it may prefer snapshot title over
  tab title.
- `docs/product/mvp.md` requires terminal title changes to update tab label
  and window UI, title bytes to be bounded/owned safely, and process-exited
  state to be visible.

Definitions used in this plan:

- Raw terminal title means title text reported by terminal escape sequences,
  usually OSC 0, OSC 1, or OSC 2, as surfaced by libghostty through
  `GHOSTTY_TERMINAL_DATA_TITLE`.
- Display title means the title Laban chooses for the visible tab row and
  window title after applying source precedence and bounding.
- User title means a manual title chosen by the user or provided at launch.
- Frozen title means a user title that automatic title updates cannot replace.
- Title source means the reason the display title was chosen, such as
  `user`, `agent`, `repo`, `cwd`, `process`, `terminal`, or `fallback`.
- Activity state means a compact UI state such as `active`, `background`,
  `unseenOutput`, `running`, `idle`, `waiting`, or `exited`.
- Agent metadata means optional metadata emitted by tools such as Claude Code
  or Cursor-like agents, for example task label, session ID, model, context
  percent, cost, lines changed, or awaiting-input state.

## Title Model

Add a metadata model in `Sources/LabanCore`, for example
`TabTitleMetadata.swift`:

```swift
public enum TabTitleSource: String, Codable, Equatable {
  case user
  case agent
  case repo
  case cwd
  case process
  case terminal
  case fallback
}

public enum TabActivityState: String, Codable, Equatable {
  case active
  case background
  case running
  case idle
  case unseenOutput
  case waiting
  case exited
}

public struct TabWorkspaceMetadata: Codable, Equatable {
  public var cwd: String?
  public var repoName: String?
  public var repoRoot: String?
  public var worktreeName: String?
  public var branch: String?
  public var isDirty: Bool
}

public struct TabProcessMetadata: Codable, Equatable {
  public var foregroundProcess: String?
  public var foregroundCommand: String?
  public var pid: Int?
}

public struct TabAgentMetadata: Codable, Equatable {
  public var agentName: String?
  public var sessionName: String?
  public var sessionId: String?
  public var taskLabel: String?
  public var model: String?
  public var contextPercent: Int?
  public var awaitingInput: Bool
}

public struct TabTitleMetadata: Codable, Equatable {
  public var userTitle: String?
  public var titleFrozen: Bool
  public var terminalTitle: String?
  public var displayTitle: String
  public var titleSource: TabTitleSource
  public var workspace: TabWorkspaceMetadata
  public var process: TabProcessMetadata
  public var agent: TabAgentMetadata
  public var activityState: TabActivityState
  public var lastActivityAt: Date?
  public var lastOutputAt: Date?
  public var unseenOutput: Bool
  public var exitStatus: Int?
}
```

Adjust exact names for existing style, but preserve the separation between raw
terminal title, user title, computed display title, source, workspace, process,
agent, activity, and exit metadata.

Keep `Tab.id` and `Tab.sessionId` immutable. Title changes must not replace,
reorder, or recreate tabs.

## Display Title Algorithm

Create `TabTitleResolver` in `Sources/LabanCore`. It should be pure and
unit-tested. It receives `TabTitleMetadata`, fallback position, and optional
row width constraints. It returns:

- `displayTitle`
- `titleSource`
- `subtitle` or compact secondary metadata string
- `statusBadge` or activity state

Source precedence:

1. If `userTitle` is present and non-empty, use it. If `titleFrozen` is true,
   never replace it automatically.
2. Else if agent `taskLabel` or `sessionName` is present, use that.
3. Else if repo/worktree metadata is present, use `repoName@worktreeName` or
   `repoName`.
4. Else if cwd is present, use the final path component or a middle-truncated
   path tail.
5. Else if foreground process is present, use process name or command.
6. Else if bounded terminal title is present and useful, use it.
7. Else use `Tab N`.

"Useful terminal title" means:

- not empty after trimming whitespace;
- not a generic shell name if better cwd/repo/process metadata exists;
- bounded to a maximum scalar count before storage and before drawing;
- contains no control characters except normal whitespace normalization.

Recommended secondary metadata:

```text
repo@worktree | branch* | process | 14s
```

Rules:

- Show repo/worktree before branch.
- Show dirty marker as `*` only after branch in MVP. Defer dirty counts to
  hover/details until git polling is proven cheap.
- Show foreground process if known.
- Show last output age or last activity age in compact form: `14s`, `8m`,
  `2h`.
- For exited sessions, show `exited 0`, `exited 1`, or `sig 15`.
- Do not show token/context/cost metrics in the default row until agent
  metadata is opt-in and reliable.

## Milestones

### Milestone 1: Core Metadata And Title Resolution

Add the model and pure title resolver.

Implementation requirements:

- Add `TabTitleMetadata`, `TabTitleSource`, `TabActivityState`, workspace,
  process, and agent metadata types under `Sources/LabanCore`.
- Change `Tab` to store `titleMetadata: TabTitleMetadata`. Keep a computed
  `title` property only if it avoids broad churn:

  ```swift
  public var title: String {
    get { titleMetadata.displayTitle }
    set { titleMetadata.userTitle = newValue; titleMetadata.displayTitle = newValue }
  }
  ```

  Prefer explicit metadata access in new code.

- Initialize new tabs with fallback `displayTitle = "Tab N"` and
  `titleSource = .fallback`.
- Add `TabTitleResolver.resolve(...)`.
- Add string sanitization helpers:
  - strip C0/C1 control characters;
  - collapse internal newlines/tabs to spaces;
  - trim leading/trailing whitespace;
  - bound stored terminal/user/agent strings to a constant such as 256
    Unicode scalars;
  - bound displayed title/subtitle to the available row width.
- Update `AppModel.updateTitle` so terminal title updates write
  `terminalTitle`, recompute display title, and do not overwrite user/frozen
  title.
- Add `AppModel.renameTab`, `AppModel.freezeTitle`, and
  `AppModel.clearUserTitle` as model methods, even if the UI for them lands
  later. Tests can use these methods.

Acceptance for this milestone:

- `swift test --filter TabTitleMetadataTests` passes.
- Existing `AppModelTests.testTitleUpdateDoesNotChangeTabIdentity` still
  passes and additionally verifies session ID remains stable.

### Milestone 2: Terminal Title, Exit, And Activity Updates

Connect session snapshots and process exit state into metadata.

Implementation requirements:

- In the AppKit frame loop, when a session snapshot has a non-empty title,
  call the new `AppModel.updateTerminalTitle` or equivalent with the active
  tab ID.
- In headless runtime session/state building, do not use snapshot title as an
  untracked replacement for tab title. Update metadata through the same model
  method, then read `displayTitle`.
- When session status is exited, set `activityState = .exited` and record
  `exitStatus`.
- When a background session gets output or render dirty state, set
  `unseenOutput = true` and update `lastOutputAt`. Clear unseen output when
  the tab is selected. If background-output tracking is too expensive in this
  milestone, record a Surprise and implement it in Milestone 4, but do not fake
  the state.
- Update the window title for the active tab from `displayTitle`, not raw
  `terminalTitle`.

Acceptance for this milestone:

- A fixture that emits OSC title updates changes the tab display title when no
  better title source exists.
- A manual title survives later terminal title changes.
- An exited session shows an exited state in model/debug state.

### Milestone 3: Sidebar Row Rendering

Render enough metadata to distinguish many similar sessions without clutter.

Recommended default row:

```text
3  auth retry cleanup        !
   laban@cobra | main* | claude | 14s
```

Implementation requirements:

- Update `SidebarProducer` to accept tabs with metadata and render:
  - one-based position;
  - primary display title;
  - close affordance;
  - status/attention marker;
  - optional secondary metadata line if `rowHeight` and sidebar width allow.
- Increase row height if needed, but keep it stable. Dynamic content must not
  resize rows frame-to-frame.
- Reserve width for position, attention marker, and close affordance before
  truncating title text.
- Use right truncation for human titles and task labels.
- Use middle truncation for paths/cwd/worktree names.
- Ensure no text overlaps the close affordance at sidebar width 200 and at a
  narrower stress width such as 140.
- Use restrained status markers:
  - active tab: existing left blue rail;
  - unseen output: small dot or `*`;
  - waiting/needs input: `?` or `!`;
  - exited nonzero: `!`;
  - exited zero: dim status.
- Do not add animated spinners, thumbnails, or multi-icon stacks in this
  milestone.

Acceptance for this milestone:

- `swift test --filter SidebarProducerTests` passes for long title bounds,
  secondary line placement, close affordance reservation, active rail,
  attention marker, and hit testing.
- The visible AppKit sidebar shows at least index, display title, close
  affordance, and exited/unseen state.

### Milestone 4: Debug State And E2E Coverage

Expose title metadata to agents.

Implementation requirements:

- Update debug state tab responses to include:
  - `displayTitle`
  - `titleSource`
  - `terminalTitle`
  - `userTitle`
  - `titleFrozen`
  - `activityState`
  - `lastActivityAt`
  - `lastOutputAt`
  - `unseenOutput`
  - `exitStatus`
  - `workspace` fields that are currently known
  - `process` fields that are currently known
  - `agent` fields that are currently known
- Keep existing `title` for compatibility, mapping it to `displayTitle`.
- Update relevant debug schemas if they exist for the state/session response.
- Add debug actions for tests:
  - `setTabTitle`
  - `freezeTabTitle`
  - `clearTabTitle`
  - optional `setTabMetadata` only in debug/headless mode for fixtures.
- Extend `scripts/test-e2e` or debug smoke tests to:
  - set a long terminal title and verify bounding;
  - set a user title and verify later terminal title does not replace it;
  - close or exit a controlled session and verify exited state appears.

Acceptance for this milestone:

- `swift test --filter LabanDebugTitleTests` passes.
- `/debug/state` and `/debug/sessions` expose display title and source.
- E2E coverage verifies bounded titles and title precedence.

### Milestone 5: Cwd, Repo, Branch, And Process Metadata

Add non-invasive metadata discovery.

Implementation requirements:

- Parse OSC 7 cwd if libghostty exposes it directly; otherwise add a small
  terminal-core or Swift-side parser only if bytes are already available in a
  safe place. Do not inject shell hooks for OSC 7 in this milestone.
- For local processes, discover cwd and foreground process with macOS APIs
  only if the lookup is reliable and cheap enough. Cache and throttle. If
  reliable foreground process discovery is not ready, use the session launch
  cwd and process fallback.
- Detect git repo root and branch from cwd using non-blocking or background
  work:
  - resolve repo root with `git rev-parse --show-toplevel`;
  - resolve branch with `git symbolic-ref --short HEAD` or equivalent;
  - resolve worktree name from repo path or `git worktree list --porcelain`;
  - mark dirty cheaply with `git status --porcelain` only on a throttle.
- Never run git checks on every frame. Use a background queue, debounce cwd
  changes, and cache results per repo path.
- Add a timeout to all subprocess metadata probes.
- Metadata probe failures should leave fields nil and add bounded debug
  events, not block rendering or input.

Acceptance for this milestone:

- Tests use temp git repos/worktrees to verify repo name, branch, dirty marker,
  and worktree-derived subtitle.
- A non-git cwd falls back cleanly to cwd tail.
- Metadata polling does not run during every render frame.

### Milestone 6: Manual Rename, Freeze, Color, And Search

Add controls that help humans keep long-running sessions organized.

Implementation requirements:

- Add model methods and debug actions first:
  - rename tab;
  - freeze/unfreeze automatic title;
  - assign a small color marker;
  - search/filter tabs by title, repo, branch, cwd, process, status, or agent
    metadata.
- Add AppKit UI only after model/debug behavior is tested:
  - context menu on tab row for rename, freeze, color, close;
  - inline rename or a small modal;
  - search command if the sidebar has enough structure.
- Manual rename must not prevent raw terminal title from being stored as
  secondary metadata. It only prevents automatic display-title replacement.
- Color should render as a small stripe/dot, not a full saturated row.

Acceptance for this milestone:

- Debug tests can rename/freeze/search tabs without AppKit.
- AppKit manual rename survives terminal title changes.
- Search by repo/title/status works over at least three tabs.

### Milestone 7: Agent-Aware Metadata

Add opt-in metadata for Claude Code and Cursor-style sessions.

Implementation requirements:

- Do not scrape terminal scrollback with an LLM to infer task titles.
- Prefer explicit metadata:
  - launch-provided title or task label;
  - environment variables set by wrappers;
  - terminal user variables if supported later;
  - Claude status-line JSON bridged by a small optional script;
  - process argv such as `claude --name <name>` when visible.
- Add fields for:
  - agent name;
  - session name;
  - task label;
  - model;
  - context percent;
  - cost/duration summary;
  - awaiting input/approval;
  - lines changed.
- Default row should show only agent/process and attention state. Context,
  cost, and line deltas belong in hover/details or search unless the user opts
  in.
- Detect same repo/branch collisions:
  - if two live tabs have same repo root and branch and no distinct worktree,
    set a subtle conflict marker;
  - include both tab positions in debug metadata;
  - do not block the user.

Acceptance for this milestone:

- Debug tests can inject agent metadata and see it affect display title/source
  and secondary metadata.
- Same repo/branch collision is detected in a fixture with two tabs.
- The default row remains readable without agent metadata.

### Milestone 8: Capture/Replay Integration

Make title and metadata transitions reproducible.

Implementation requirements:

- Coordinate with `execplans/active/full-capture-replay.md`.
- Record title metadata changes as capture timeline events:
  - terminal title update;
  - user title change;
  - title freeze/unfreeze;
  - cwd/repo/branch/process update;
  - activity state change;
  - agent metadata update.
- Replay should reproduce `displayTitle`, `titleSource`, row subtitle, and
  status markers for captured frames.
- Renderer-only replay should capture sidebar frame commands so title rendering
  regressions are visible without a live terminal.

Acceptance for this milestone:

- A capture with title changes replays to the same debug state title metadata
  and sidebar command text.

## Concrete Steps

Run commands from the repository root:

```sh
pwd
# /Users/rrj/wrk/laban/.claude/worktrees/still-glowing-cobra

swift test --filter TabTitleMetadataTests
swift test --filter SidebarProducerTests
swift test --filter LabanDebugTitleTests
swift test --filter LabanSessionTests
./scripts/test-e2e
./scripts/check
```

During implementation, run focused tests after each milestone. Before marking
this ExecPlan complete, run every Review Gate check and update `Progress` with
the results.

## Validation and Acceptance

This plan is complete only when:

- Terminal title changes update tab/window display through the title metadata
  model.
- Raw terminal title is stored separately from display title.
- User/manual title survives later terminal title changes.
- Long/hostile title text is sanitized, bounded, and cannot overlap controls
  or resize the sidebar.
- The sidebar row shows index, display title, close affordance, and visible
  activity/exited state.
- When workspace/process metadata is known, the sidebar can show a compact
  secondary line without layout shifts.
- Debug state exposes title source and metadata fields.
- Tests cover title precedence, bounding, sidebar layout, and debug state.
- `./scripts/check` passes.

Validation run, 2026-05-04:

```text
swift test --filter TabTitleMetadataTests
# passed: 7 tests

swift test --filter SidebarProducerTests
# passed: 16 tests

swift test --filter LabanDebugTitleTests
# passed: 5 tests

swift test --filter LabanSessionTests
# passed: 29 tests

swift test --filter AppModelTests
# passed: 14 tests

swift test --filter TerminalTitleTests
# passed: 13 tests

swift test --filter LabanDebugSmokeTests
# passed: 30 tests

./scripts/test-e2e
# test-e2e passed

./scripts/check
# check passed
```

## Idempotence and Recovery

The metadata model is additive. If a milestone is interrupted, existing tabs
should still display a fallback `Tab N` title. Avoid deleting `Tab.title`
compatibility until all call sites use metadata or tests prove the computed
property is enough.

Metadata probes must be best-effort. A failed cwd/git/process probe should not
prevent tab creation, terminal input, rendering, or close. Disable a probe with
a feature flag or nil result if it becomes slow or flaky.

Do not introduce shell integration injection in the MVP milestones. If a later
agent-aware milestone needs wrappers, keep them opt-in and document how to
disable them.

## Security And Privacy

Title and metadata may contain private paths, branch names, task descriptions,
prompts, repository names, and agent session IDs.

Rules:

- Store bounded strings.
- Do not include full environment variables in title metadata.
- Do not run git or process probes outside local paths owned by the session.
- Do not send title metadata to network services.
- Do not infer task labels by sending scrollback to an LLM.
- Keep debug output local and bounded.

## Interfaces and Dependencies

This plan uses existing Swift, AppKit, LabanCore, LabanDebug, and
LabanTerminalCore code. Do not add a new UI framework or external dependency
for title metadata.

New or updated interfaces at completion:

- `TabTitleMetadata`
- `TabTitleResolver`
- `TabActivityState`
- `TabTitleSource`
- `AppModel.updateTerminalTitle`
- `AppModel.renameTab`
- `AppModel.freezeTitle`
- Debug fields for title metadata in state/session responses
- Optional later metadata probes for cwd, repo, branch, process, and agent
  fields

## Outcomes & Retrospective

Milestones 1 through 4 now have a working MVP slice. `Tab` stores
`TabTitleMetadata` separately from stable IDs and session ID, `AppModel`
updates terminal title/user title/activity/exit metadata without replacing
identity, the sidebar renders width-bounded two-line rows with status markers,
and debug state/session responses expose title metadata while preserving the
legacy `title` field as `displayTitle`.

Deferred work remains for real cwd/repo/branch/process discovery, AppKit rename
UI, color/search controls, agent-aware metadata, capture/replay integration,
and fresh-state Review Gate signoff.
