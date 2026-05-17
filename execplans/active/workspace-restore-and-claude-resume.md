# Workspace Restore And Claude Resume Autopilot

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then make Laban restore its tabs, working directories, and terminal
scrollback after quit-and-relaunch, and automatically resume an in-flight
Claude Code conversation in a tab without any user clicks.

## Purpose / Big Picture

Today, quitting Laban destroys every tab and every running process. On
relaunch the user starts from an empty window. For a user who keeps an
agent CLI conversation (Claude Code, Codex) open all day, this is the most
disruptive thing the app does: their conversation, working context,
scrollback, and tab layout are all gone.

After this change, the user can:

1. Open Laban, create N tabs (a Claude conversation in one, a Codex
   conversation in another, a shell in a third, a `make` build in a
   fourth).
2. Quit Laban with Cmd-Q (or have the OS kill it, or reboot the Mac).
3. Relaunch Laban. The same window appears, the same tabs are present in
   the same order, each tab is sitting in its previous working directory,
   the scrollback shown on each tab matches what was visible at quit, and
   **both the Claude tab and the Codex tab are already resumed** — each
   conversation is loaded back into a fresh agent process via that
   agent's own resume invocation (`claude --resume <id>` for Claude,
   `codex resume <id>` for Codex), with no clicks and no visible "press
   Enter to continue" friction.
4. Type the next message into either agent and it responds with full
   prior context. The shell tab is at a fresh prompt with prior
   scrollback visible above. The `make` tab shows the previous output
   but is not re-executing (the build was finished; we don't
   second-guess the user).

The single most user-visible outcome is the agent moment: quit
mid-thought in Claude or Codex, relaunch, keep typing. No other macOS
terminal does this today for either agent, let alone both.

This work also reframes what "crash recovery" means for Laban: the on-disk
state is the source of truth, and every change is persisted within ~200ms.
A SIGKILL, panic, or power loss costs at most that quarter-second window.
There is no "your last session crashed" prompt; relaunch silently restores.

## Progress

- [x] (2026-05-17) Author this ExecPlan from a grilling session that
  resolved the design decisions captured in the Decision Log below.
- [ ] **M0** — workspace.json round-trip: persist tab list, cwd, launch
  command, selection, sidebar visibility; restore tabs on launch as fresh
  shells in saved cwds; ⇧-at-launch escape hatch.
- [ ] **M1** — transcript capture and render-on-restore: PTY byte tee
  writes append-only per-tab `.bin` files; last ~1MB byte-replays through
  libghostty-vt on restore; older history renders as text-only scrollback;
  alt-buffer-at-quit skips restore.
- [ ] **M2** — agent (Claude + Codex) session id capture and
  autoresume + JSONL mirror: detect `claude` and `codex` processes
  via descendant-tree polling (`DispatchSourceTimer` +
  `proc_listpids` + `proc_pidpath` + `proc_pidinfo` fd scan), capture
  agent name and session id, persist per tab; on restore rewrite
  launch command to the agent's resume form (`claude --resume <id>`
  for Claude, `codex resume <id>` for Codex) and auto-execute
  silently when the agent process was alive at quit, prefill in the
  prompt otherwise; non-agent restored tabs get a fresh shell prompt
  (no prefill); mirror agent JSONL on lifecycle events as a
  diagnostic snapshot.

## Decision Log

These decisions were resolved through a design grilling. They are
load-bearing — changing them invalidates implementation choices made
downstream. Record any change to these decisions here with rationale.

- Decision: Fidelity target is "workspace returns" (tabs + cwds + launch
  command + Claude `--resume` autopilot + scrollback as readable text).
  Live process preservation is explicitly out of scope.
  Rationale: This matches the proven gmax pattern and Anthropic's own
  recommended embedding path (`claude --resume <id>`). Live process
  preservation requires either an out-of-process supervisor daemon (real
  engineering — months, ADR-worthy) or a multiplexer wrapper. The user
  ruled out tmux explicitly; building a supervisor is a separate product.
  In-flight tool calls dying at quit is the accepted cost.
  Date/Author: 2026-05-17 / Grilling session.

- Decision: Transcript storage uses one append-only binary file per tab
  (raw PTY output bytes), capped at 10MB with head-truncation. Metadata
  uses a single `workspace.json` written via `Codable` and atomic rename.
  No SQLite, no Core Data.
  Rationale: Total persisted volume is small (well under 10MB metadata at
  10-tab scale; ~10MB × tab-count for transcripts). Single writer, no
  concurrent access, no FTS, no joins, no schema invariants beyond what
  Codable enforces. SQLite is overkill and adds a dependency for no
  benefit. Append-only writes are the cheapest possible IO pattern;
  reading is page-cache-backed. Atomic rename gives equivalent crash
  safety to a SQLite transaction for the single-writer case.
  Date/Author: 2026-05-17 / Grilling session.

- Decision: Persist as raw bytes; render on restore by byte-replaying the
  last 1MB through libghostty-vt for color and style fidelity, and
  text-stripping everything older into the scrollback buffer. If the
  alt-buffer flag was set at the last persisted frame (the tab was in
  vim/htop/less when Laban quit), skip restore entirely — show an empty
  terminal with "process exited" marker.
  Rationale: Plain-text scrollback restore makes Claude's color-rich
  output look flat (loses tool-call dimming, diff coloring, syntax
  highlighting); the brand moment requires it to look identical. Full
  byte replay across the entire transcript is slow for large histories
  and meaningless for ended TUI sessions. Hybrid bounds restore cost to
  one screen's worth of bytes regardless of history size. Alt-buffer
  skip is what `docs/product/spec.md` section 12 already commits to.
  Date/Author: 2026-05-17 / Grilling session.

- Decision: Restore is silent at launch (no "your last session crashed"
  prompt). Holding ⇧ at launch starts a fresh workspace, archiving the
  prior state to `workspace.json.previous`. Per-tab restore failures
  show a placeholder with the error visible; the rest of the workspace
  restores normally.
  Rationale: The brand moment requires zero clicks between quit and
  "right where I left it." Detecting unclean shutdown reliably on macOS
  is impossible (SIGKILL and power loss bypass `applicationWillTerminate`);
  Firefox specifically backed out of crash-prompt UX after user complaints.
  The escape hatch costs one menu item and protects against bug-induced
  restore loops. Browsers (Chrome on crash, Firefox always, Safari always)
  and gmax all converged on silent.
  Date/Author: 2026-05-17 / Grilling session.

- Decision: Restore policy is asymmetric and **agent-aware** — Claude
  and Codex both get the autopilot, with equal support. A tab with a
  captured agent session id auto-rewrites its launch to the agent's
  resume invocation (`claude --resume <id>` for Claude,
  `codex resume <id>` for Codex). If the agent process was alive at
  quit the rewrite executes silently, otherwise it is pre-filled in
  the prompt and the user hits ENTER. Every non-agent tab — and every
  agent tab where session-id capture failed — restores its transcript
  and presents a fresh shell prompt with **no pre-fill, no
  auto-execute**.
  Rationale: An earlier draft proposed a Zellij-style "Press ENTER to
  re-run" pattern for non-Claude tabs whose process was alive at quit.
  The codex review correctly pointed out we don't actually have the
  user's typed command — we only persist the *shell* launch command
  (e.g., `/bin/zsh -l`). Pre-filling that on restore is nonsense; the
  user typed `make` inside the shell, and capturing that requires OSC
  133 shell integration (separate scope). With non-Claude prefill
  removed, the only auto-execute is `claude --resume X`, which is
  non-destructive (just loads conversation context). The Zellij safety
  pattern becomes redundant.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: Capture agent session id via periodic descendant-tree
  polling. For each tab, a `DispatchSourceTimer` fires every 500ms.
  On each tick the timer walks the tab's child process's descendant
  tree (using `proc_listpids(PROC_PPID_ONLY, ppid, ...)` recursively),
  resolves each pid's executable path via `proc_pidpath`, and on a
  match against any of the configured agent binary basenames
  (`claude`, `codex` — extensible to others later) queries that
  process's open file descriptors via
  `proc_pidinfo(PROC_PIDLISTFDS, ...)` and
  `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO, ...)`. The first open fd
  whose vnode path ends in `.jsonl` yields the session id — the
  filename stem — regardless of where the file lives on disk. We
  deliberately do **not** require the path to contain `/.claude/` or
  `/.codex/`.
  Rationale: The earlier draft of this plan proposed
  `EVFILT_PROC | NOTE_EXEC` registered on each tab's child pid. That
  design is wrong: the shell `fork()`s and the *child* `execvp`s
  claude, so NOTE_EXEC on the shell pid never fires for the child.
  NOTE_FORK + cascading re-registration on each new child has a real
  race window (the child may exec before re-registration completes)
  and adds code surface for every fork in the system, not just claude.
  Polling sidesteps the race entirely. Cost analysis: 10 tabs × one
  `proc_listpids` per 500ms = 20 syscalls/sec at the discovery layer;
  each syscall is ~1µs on Apple Silicon; total CPU is ~0.002% of one
  core. Detection latency is bounded at 500ms — well inside the time
  the user spends reading Claude's startup banner. Robust to every
  invocation style: `claude`, `npx claude`, `direnv exec . claude`,
  `time claude`, `codex`, `npx codex`, custom paths. The reviewer's
  blocker on the kqueue design is dissolved. The path-detection
  refinement (match any `.jsonl` open fd rather than a
  vendor-prefixed path) handles `CLAUDE_CONFIG_DIR` and analogous
  Codex env-var redirection, future Claude/Codex path
  reorganization, and gracefully no-ops when sessions are disabled
  (zero `.jsonl` fds → no detection, tab restores as fresh agent
  without the resume invocation).
  Date/Author: 2026-05-17 / Codex review response.

- Decision: Equal support for Claude and Codex as first-class
  resumable agents in v1. Both are detected, both have their session
  ids captured, both have their JSONL mirrored, both get the
  silent-or-prefilled `resume` autopilot on restore. The only thing
  that differs per agent is the binary name (matched in the detector)
  and the resume command form: `claude --resume <id>` versus
  `codex resume <id>` (codex uses a subcommand, not a flag — verified
  against the codex CLI source at
  `github.com/openai/codex/blob/main/codex-rs/cli/src/main.rs`). The
  design generalises cleanly because both agents have the same
  shape: append-only JSONL transcript on disk, UUID session id,
  CLI-level resume by id. Adding a third agent in the future is one
  entry in the `AgentSupport` table — no schema migration, no
  detector changes.
  Rationale: User requirement; Claude and Codex serve overlapping
  audiences and a Laban that only worked for one would feel partial.
  The implementation cost over Claude-only is small (the detector's
  binary-name match is now `["claude", "codex"]` instead of
  `["claude"]`; the launch planner picks the resume invocation from
  a per-agent formatter; the mirror writes go to the same directory
  with the agent name persisted alongside).
  Date/Author: 2026-05-17 / User requirement.

- Decision: Mirror agent JSONL on lifecycle events (agent process
  exit, tab close, Laban quit) **and on a 5-minute periodic timer
  while an agent process is observed alive** in a tab, to
  `~/Library/Application Support/Laban/agent-mirror/<tab-id>.jsonl`.
  The mirror covers post-clean-quit reboot scenarios (lifecycle
  fires before quit) and bounds the mid-session loss window to 5
  minutes (periodic timer fires during long-running sessions). It
  does **not** protect against mid-session SIGKILL/power loss in
  the gap between two periodic ticks — at most 5 minutes of recent
  agent state may be lost if both Laban and Claude's own JSONL go
  down inside that window. The mirror is **best-effort diagnostics
  only** in M2 — the supported restore path is the agent's own
  `resume` invocation, period. Auto-fallback (copy the mirror back
  to the agent's expected path on "session not found" and retry)
  is deferred to a separately-scoped M2.5 follow-up; M2 does not
  ship it.
  Rationale: Anthropic issue #54907 documents JSONL files disappearing
  after macOS reboot in some setups. The lifecycle triggers cover
  the post-clean-quit reboot scenario; the periodic 5-min snapshot
  bounds the mid-session loss window so that a Laban SIGKILL or a
  machine reboot during an active agent conversation loses at most
  ~5 minutes of agent state rather than the entire session.
  Periodic-snapshot cost is one `cp` per active agent tab per 5
  minutes — a one-Claude-tab-open-all-day user sees ~96 extra `cp`
  calls per day, each sub-millisecond. Battery impact unmeasurable.
  Continuous tailing was rejected as over-engineering: tail
  semantics for files another process is appending to are tricky
  (truncation, rotation, partial-line reads), and the 5-min bound
  is enough for "you didn't lose your whole day's conversation"
  without becoming a streaming-replicator. Auto-fallback was
  deferred because the codex review correctly flagged that copying
  the mirror to the agent's expected path makes Laban
  version-coupled to agent internals — a future Claude or Codex
  release that reorganizes session layout would break the fallback
  silently. M2 ships the mirror so the fallback can be added as a
  tested follow-up if telemetry shows users hitting "session not
  found" with non-trivial frequency. The mirror is still useful at
  M2 for manual recovery — users can copy it back themselves if
  the agent has lost the original.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: `AgentSupport` table holds a per-agent
  `extractSessionId(vnodePath: String) -> String?` closure, not just
  binary name + resume-command. The default implementation matches
  the path against the agent's known JSONL layout (`.claude/projects/
  <encoded-cwd>/<uuid>.jsonl` for Claude with `CLAUDE_CONFIG_DIR`
  override; analogous for Codex with whatever its env-var override
  is) AND validates that the extracted stem is a UUID (or other
  agent-defined session-id shape). A `.jsonl` open fd whose path or
  filename does not match returns `nil` — the detector treats it as
  "not the session log."
  Rationale: The codex review correctly flagged that "any `.jsonl`
  open fd is the session id" is too loose — `claude` or `codex` may
  open arbitrary `.jsonl` files (configs, caches, data) that aren't
  the session log. Misidentifying one as the session id would write
  garbage to `agent.sessionId` and produce a guaranteed-to-fail
  resume invocation. The per-agent matcher + UUID validation keeps
  the detector general (the AgentSupport table is the single source
  of truth) while making each agent's path expectations explicit and
  testable. If a future agent uses non-UUID session ids, that's one
  new entry in the table with its own validator.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: Agent liveness is tracked **separately** from
  `processStatus`. `AgentInfo` carries a `wasRunningAtQuit: Bool`
  field maintained by the detector: set true on the first detection,
  set false on a tick where no matching agent descendant is found,
  re-set true if the agent reappears. At quit time the persistence
  layer reads the current value into the saved state. The restore
  launch planner uses `agent.wasRunningAtQuit` (not
  `tab.processStatus`) to decide silent vs prefilled resume.
  Rationale: `processStatus` tracks the *shell* (the tab's direct
  child), which is always alive while the tab is open. The agent
  (claude/codex) runs as a grandchild and has its own independent
  lifetime — the user may have exited claude with Ctrl-D 20 minutes
  before quitting Laban. Using shell processStatus would make a
  long-dead Claude conversation auto-resume silently, which is
  wrong. The detector already observes agent existence on every
  tick; recording its own observation is the source of truth.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: The `AgentSessionDetector` timer **never stops**. Each
  500ms tick: (1) walk the descendant tree; (2) if a matching agent
  descendant is found and its session id is unchanged, no-op; (3) if
  found with a new session id, update the tab's `AgentInfo`; (4) if
  not found, set `wasRunningAtQuit = false` while preserving the
  previously-captured `name`/`sessionId`/`jsonlPath`. The timer
  continues for the life of the tab so we observe agent restarts,
  re-launches, and Ctrl-D exits uniformly.
  Rationale: The earlier draft said "stops the timer once a session
  id is captured" and also "re-arms on the next tick's discovery" —
  which is self-contradictory because a stopped timer has no next
  tick. Never-stop is simpler, costs almost nothing (one
  `proc_listpids` per 500ms per tab), and yields the liveness
  signal the launch planner needs.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: Persistence ring-buffer overflow policy is **drop
  oldest**. If the per-session in-memory ring fills before the
  persistence drain queue can process it (pathological case:
  sustained PTY output faster than disk can absorb), the C
  callback's `memcpy` overwrites the oldest bytes in the ring,
  advancing the head pointer. The callback never blocks and never
  returns an error.
  Rationale: The codex review flagged that ring overflow was
  unspecified. Three options exist: drop oldest (lossy but bounded
  memory, never blocks PTY drain), block the callback (blocks PTY
  drain — defeats the whole reason for async sink), or grow the
  ring unboundedly (memory bomb). Drop-oldest matches every other
  "we can't lose the producer" subsystem in Laban (log ring
  buffers, capture streams). The user-visible effect under sustained
  overload is "older bytes don't make it into the transcript file" —
  the agent moment is still preserved because the on-screen output
  is rendered live by libghostty-vt; the transcript is only used on
  restore. Telemetry should count overflow events; non-zero counts
  indicate the ring size needs raising.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: The byte-replay cutoff at restore is **not** an exact
  `file_size - 1MB` offset. After computing the nominal cutoff, the
  TranscriptRenderer walks forward through the file looking for the
  first `\n` (ASCII LF, 0x0A); the byte-replay window starts at the
  first byte *after* that LF. Everything before is text-stripped.
  If no LF exists between the nominal cutoff and EOF (degenerate
  case), the entire suffix is text-stripped and no byte replay
  happens.
  Rationale: The codex review correctly flagged that cutting the
  byte stream at an arbitrary offset can land mid-escape-sequence
  or mid-multibyte-UTF-8, producing garbage in the first replayed
  frame. ASCII LF is the safest universal resync point: it can
  never appear inside a VT escape sequence (escapes don't contain
  LF) and it always marks a UTF-8-aligned position. The forward
  walk from nominal cutoff has bounded cost (typically <1KB until
  the next LF in real terminal output) and gives a clean replay
  starting point.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: Scope is single-plane (live tabs only) **and single-window**
  through M2. No "recently closed tab" ring buffer, no library of saved
  workspaces. Laban's current app shell (`Sources/LabanApp/AppDelegate.swift`
  line 5 holds exactly one `MainWindowController`) is single-window;
  persisting state for windows that do not exist would be premature.
  The `WorkspaceState` schema retains a `windows: [WindowState]` array
  for forward compatibility — M0/M1/M2 always produce and consume an
  array of length 1; multi-window support can be added later by
  changing the implementation without a schema migration. Window
  frame/size/zoom is left to macOS's built-in UI Preservation when
  multi-window arrives.
  Rationale: The brand-defining moment is live-plane restore. Recently-
  closed and library planes are quality-of-life features layered on
  top, not part of the differentiating outcome. Each additional plane
  multiplies UI surface, menu items, and identity-management work.
  `workspace.json` schema is forward-compatible (Codable optional
  fields) so adding planes later is additive. Spec.md commits only to
  the live plane.
  Date/Author: 2026-05-17 / Grilling session.

- Decision: Persistence subsystem is separate from the existing capture
  subsystem (`schemas/capture/`). They share an in-process "PTY byte tee"
  abstraction in `Sources/LabanTerminalCore/pty_io.c` so that PTY output
  bytes can fan out to libghostty-vt, persistence, and (optionally) a
  capture stream from a single read. Storage formats, retention, and
  privacy semantics remain independent.
  Rationale: Capture answers "what happened in this run, can I replay
  or diagnose it?" Persistence answers "what should I show the user on
  relaunch?" They have opposite retention policies (capture keeps
  everything in a bounded run; persistence trims to 10MB and lives
  forever), different reliability requirements (persistence must never
  lose bytes within the debounce window; capture can tolerate loss
  because tests fail loudly), and different privacy contracts (captures
  may be attached to bug reports and need redaction; persistence is
  user-private and never leaves the device). Conflating storage forces
  each side to pay for the other's requirements.
  Date/Author: 2026-05-17 / Grilling session.

- Decision: The persistence PTY-byte callback registered through
  `laban_session_set_persistence_callback` performs **no disk IO,
  truncation, or fsync**. It copies bytes into a per-session in-memory
  ring buffer (with a short critical section under the session lock or
  a lock-free SPSC ring) and returns. A dedicated
  `DispatchQueue(label: "laban.persistence", qos: .utility)` drains
  every active ring buffer on the 200ms debounce tick, performs the
  appends, the head-truncation pass when over the 10MB cap, and the
  atomic-rename writes of `workspace.json`.
  Rationale: The callback runs inside `laban_session_drain_locked_`
  (`Sources/LabanTerminalCore/pty_io.c` line 91), which holds the
  session lock and feeds bytes to `ghostty_terminal_vt_write` for the
  current frame. Any synchronous Swift IO, file truncation, or fsync
  here would block PTY drain and stall rendering — the codex review
  correctly flagged this. The async-sink pattern keeps the hot path
  bounded to a memcpy plus a ring-buffer index update.
  Date/Author: 2026-05-17 / Codex review response.

- Decision: Do not propose or implement tmux/screen as a session-
  persistence layer or launch wrapper. The supervisor-daemon path for
  live-process preservation is explicitly closed by user preference;
  if revisited it must be a custom Laban-owned daemon, not a
  multiplexer.
  Rationale: User-stated preference (reason unstated; plausible reasons
  include not wanting a runtime dependency on tmux being installed, the
  complexity of running two VT parsers in series, and ADR-0001/0002's
  commitment to Laban owning its terminal stack end-to-end).
  Date/Author: 2026-05-17 / Grilling session.

- Decision: Atomic writes use `Data.write(to:options:.atomic)` only —
  no `F_FULLFSYNC`. The durability contract is process-crash-safe
  (survives Cmd-Q, Force Quit, Laban panics, OOM kills, and most
  kernel panics via the filesystem journal). It does **not** survive
  hard power loss within the 200ms debounce window.
  Rationale: Power-loss durability requires `F_FULLFSYNC` on the
  temp file before rename. That call forces the SSD controller to
  commit its own write cache to NAND, taking ~0.5–2ms per call and
  defeating the controller's coalescing. At our cadence (max 5
  writes/sec for `workspace.json`, similar per active transcript)
  the battery and write-amplification impact is small but real, and
  it defends only against power-loss scenarios where users already
  expect some data loss. Chrome, VS Code, and Sublime ship the same
  contract; only databases promising ACID durability use
  `F_FULLFSYNC`. If telemetry later shows power-loss-related session
  loss is a real failure mode for our users, revisit by adding
  `F_FULLFSYNC` to the `workspace.json` metadata write only
  (transcript bytes can stay on the cheap path).
  Date/Author: 2026-05-17 / Codex review response.

- Decision: On restore, if a tab's saved `cwd` does not exist or is
  unreachable, fall back to `$HOME`, set `TabState.cwdFallbackApplied
  = true`, and show a one-line banner in the tab: "Could not restore
  working directory `<original cwd>`; using `~`."
  Rationale: Common cause is unmounted external storage between quit
  and relaunch (USB stick removed, network volume disconnected). A
  silent fall-through to home would confuse the user; a visible
  banner is honest and actionable. Persisting the fallback flag
  makes the behavior testable and observable in headless runs.
  Date/Author: 2026-05-17 / Codex review response.

## Context and Orientation

A novice reader should understand the following before editing:

### What Laban currently does

Laban is a macOS-native terminal application. It is built as a SwiftPM
project. The application shell is in `Sources/LabanApp/` (AppKit /
SwiftUI hybrid). Per-session terminal state lives in
`Sources/LabanTerminalCore/` (a C library) and `Sources/LabanCore/`
(Swift wrappers). The core data model is `AppModel` in
`Sources/LabanCore/AppModel.swift` — it owns the list of tabs and which
tab is selected, and it is the entry point for tab creation, selection,
and teardown. The `Tab` type is in `Sources/LabanCore/Tab.swift`.

Each tab has exactly one `Session` (`Sources/LabanCore/Session.swift`),
which wraps a C `LabanSession` struct declared in
`Sources/LabanTerminalCore/session_internal.h`. A session owns the PTY
master file descriptor, the child process pid, the libghostty-vt
terminal parser, scrollback state, title state, and exit status.

PTY launch is performed by `laban_session_spawn` in
`session_lifecycle.c`. It uses `openpty()` on the parent side and a
`fork()` + `execvp()` on the child side, per ADR-0002. The child is the
session leader of its own process group.

PTY output is read in `laban_session_drain_locked_` in
`Sources/LabanTerminalCore/pty_io.c`. Each chunk read off the PTY is
passed to `laban_vt_write_capture` (in `capture.c`), which:

1. Emits the bytes to the optional capture callback
  (`s->capture_callback`) — this is how the existing test-capture
  subsystem records PTY output.
2. Writes the bytes to the optional `s->capture_fd` file (also for
  testing).
3. Scans for tab-status markers (`laban_scan_tab_status`).
4. Hands the bytes to libghostty-vt (`ghostty_terminal_vt_write`) for
  parsing and rendering.

The PTY byte tee for persistence will hook in at this same site.

Laban currently does not persist any tab state across launches. Quit
destroys the AppModel. Relaunch starts with an empty workspace and
opens one default tab.

### What needs to be added

1. A **PersistenceStore** Swift class that owns the on-disk state under
  `~/Library/Application Support/Laban/`. Reads `workspace.json` on
  launch, writes it atomically on debounced changes. Reads and writes
  per-tab `.bin` transcript files.
2. A **WorkspaceState** Codable struct that is the on-disk schema.
3. An additional consumer of PTY bytes in `pty_io.c` / `capture.c`
  that writes bytes to a per-tab transcript file. This consumer is
  set up at session-create time by Swift code in `Session.swift` or
  `AppModel.swift`.
4. An **alt-buffer flag tracker**. libghostty-vt knows when the
  alternate screen buffer is active; this state must be exposed to
  Swift and persisted in `workspace.json` per tab. If libghostty-vt
  does not currently expose alt-buffer state through its C ABI, add a
  small bridge in `session_internal.h` and the relevant `.c` file.
5. A **restore renderer** that, on launch, for each restored tab:
  - Opens the tab's `.bin` file.
  - Computes `last_screen_offset = max(0, file_size - 1MB)`.
  - Text-strips bytes `[0, last_screen_offset)` and feeds them to
    libghostty-vt as scrollback (via existing scrollback-write path or
    by feeding stripped text as plain bytes).
  - Feeds bytes `[last_screen_offset, file_size)` to libghostty-vt
    raw, so it parses escapes and rebuilds the visible screen.
  - If `altBufferAtQuit` was true for that tab, skip the above and
    show an "exited" placeholder instead.
6. An **AgentSessionDetector** Swift class that polls each tab's
  descendant process tree on a 500ms `DispatchSourceTimer`. Each
  tick: `proc_listpids(PROC_PPID_ONLY, parentPid, ...)` enumerates
  immediate children, recurses to a depth cap of 4 to handle
  `npx claude`, `direnv exec . claude`, `time claude`, `npx codex`,
  and similar wrappers, and resolves each pid via `proc_pidpath`.
  On a match against any configured agent binary basename
  (`claude`, `codex` in v1), queries the process's open file
  descriptors via `proc_pidinfo(PROC_PIDLISTFDS, ...)` and
  `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO, ...)`. The first open fd
  whose path ends in `.jsonl` yields the session id (filename stem).
  Persists `(agentName, sessionId, jsonlPath)` in the tab's
  metadata. The kqueue-based design (`EVFILT_PROC | NOTE_EXEC`) was
  rejected because the shell `fork`s and the *child* `exec`s the
  agent — NOTE_EXEC on the shell's pid never fires for the child.
  See Decision Log for the full rationale.
7. A **launch command rewriter** that, on restore, examines each tab:
  - If the tab had `processStatus == "running"` and a captured
    agent session id, rewrite the launch command to that agent's
    resume form (`claude --resume <id>` or `codex resume <id>`) and
    execute silently.
  - If the tab had `processStatus != "running"` and a captured
    agent session id, pre-fill the prompt with the resume command
    and require ENTER.
  - Otherwise — including any non-agent tab and any agent tab where
    detection failed — present a fresh shell with no pre-fill.
8. An **AgentJSONLMirror** writer that copies the captured JSONL file
  to `~/Library/Application Support/Laban/agent-mirror/<tab-id>.jsonl`
  on three events: the agent process exits, the tab is closed, or
  Laban quits. One mirror file per tab; the agent type is recorded
  in `workspace.json`, not in the directory structure.
9. (Deferred to M2.5 follow-up; not in M2.) A **restore fallback**
  that, on `claude --resume X` or `codex resume X` exit-non-zero
  with a "session not found" indication, copies the mirror back to
  the agent's expected JSONL path and retries once.

### What persists where

```text
~/Library/Application Support/Laban/
  workspace.json              ← all metadata, one file
  workspace.json.previous     ← created by ⇧-at-launch when archiving
  transcripts/
    <tab-uuid-1>.bin          ← raw append-only PTY output bytes
    <tab-uuid-2>.bin
  agent-mirror/
    <tab-uuid-1>.jsonl        ← snapshot of Claude or Codex JSONL on lifecycle
```

### Terms used in this plan

- **PTY byte tee** — a fan-out point inside the PTY-read loop. One
  inbound buffer of bytes; multiple outbound consumers (libghostty-vt,
  persistence transcript writer, optional capture stream). Implemented
  as a small linked list of `(callback, userdata)` pairs invoked in
  order for every chunk read off the PTY.
- **Workspace** — for the purposes of this plan, the live state of one
  Laban window: an ordered list of tabs plus per-window UI state
  (selected tab, sidebar visibility). Multi-window means multiple
  `Window` entries in `workspace.json`.
- **Session id (Claude)** — the UUID Anthropic's `claude` CLI assigns
  to a conversation. Stored on disk as the filename of a JSONL file
  under `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
  Re-invokable via `claude --resume <session-id>`.
- **Alt-buffer flag** — VT terminal state. The "alternate screen
  buffer" is what full-screen TUIs (vim, htop, less) switch to so
  they can take over the terminal without scrolling the user's prior
  shell history. If a tab was in alt-buffer when Laban quit, restoring
  scrollback would mean painting half-finished `vim` state, which is
  wrong; we skip restore in that case.
- **Render-on-restore** — the act, at app launch, of reading a tab's
  persisted transcript and feeding it back through libghostty-vt so
  the user sees the previous scrollback rebuilt. Distinct from
  *byte capture* (writing bytes to disk as they arrive).

### Hard rules from AGENTS.md that this work must honor

- The project must be autonomously verifiable. Validation below
  includes headless tests for each milestone.
- Terminal session identity must survive tab selection, view rebuilds,
  resize, and UI refresh. Restored tabs must satisfy this.
- Native text input wins over raw modifier interpretation. The ENTER-
  to-execute pattern for restored commands must integrate with the
  existing input pipeline; it must not bypass it.
- Keep changesets focused on one behavioral reason. Each milestone
  ships independently with its own observable acceptance.
- Commit messages: single-line reason statements (why, not what).
  Do not start with "Because" (per saved feedback memory).
- Use `./scripts/build-app` for builds (not `swift build`).

## Milestones

### M0 — Workspace.json round-trip

**Scope.** Persist enough metadata that quitting and relaunching
Laban brings back the same single window's tabs in the same order,
each in its previous working directory.
Tabs come back as **fresh shells**. This proves out the metadata
layer end to end and provides the foundation everything else plugs
into.

**Explicitly in scope for M0:**

- **Single window.** Laban's current app shell holds exactly one
  `MainWindowController` (see `Sources/LabanApp/AppDelegate.swift`
  line 5). M0 restores that one window's tabs. The schema retains a
  `windows: [WindowState]` array — M0 always writes a one-element
  array and reads only the first element — so adding multi-window
  later is an implementation change with no schema migration.
- Per-window selected tab — `selectedTabId` so the same tab is
  focused after relaunch.
- The ⇧-at-launch escape hatch — without it the user has no way to
  recover from a corrupt or unwanted restore.

**Explicitly NOT in M0** (each listed milestone or follow-up below
adds these):

- No transcript capture or scrollback restore (M1 adds).
- No alt-buffer flag tracking (M1 adds).
- No Claude process detection (M2 adds).
- No `claude --resume` rewriting (M2 adds).
- No JSONL mirror (M2 adds).
- No JSONL auto-restore fallback for "session not found"
  (deferred to M2.5 follow-up).
- No "press ENTER to re-run" pre-fill logic for non-Claude tabs
  (dropped entirely — see Decision Log; the only auto-execute is
  `claude --resume X`).
- No scroll position, find state, or selection restore (deferred
  beyond M2; fidelity rung iii).
- No "recently closed tab" or library plane — these are future
  planned planes (S2/S3 in the Decision Log), out of M0/M1/M2 scope.
- No multi-window persistence (schema is forward-compatible; add when
  the app shell grows to multiple windows).
- No window frame/size/zoom persistence — left to macOS's built-in
  `NSWindowRestorable` mechanism.

**New files.**

- `Sources/LabanCore/Persistence/WorkspaceState.swift` — `Codable`
  structs: `WorkspaceState`, `WindowState`, `TabState`. Includes
  `schemaVersion: Int` (= 1), `windows: [WindowState]`.
- `Sources/LabanCore/Persistence/PersistenceStore.swift` — class with
  methods `load() -> WorkspaceState?`, `save(_ state: WorkspaceState)`,
  `archiveCurrent()` (renames `workspace.json` →
  `workspace.json.previous`). Atomic write via
  `Data.write(to:options:.atomic)`.
- `Sources/LabanCore/Persistence/PersistenceCoordinator.swift` —
  observes `AppModel` changes, debounces 200ms on a background
  dispatch queue, and calls `PersistenceStore.save`. Subscribes to
  `applicationWillTerminate` for a synchronous final flush.

**Modifications.**

- `Sources/LabanCore/AppModel.swift` — emit a change signal on tab
  add/remove/reorder, tab selection, and cwd change. Add
  `restore(from: WorkspaceState)` initializer path.
- `Sources/LabanApp/AppDelegate.swift` — at launch, check `⇧` modifier
  via `NSEvent.modifierFlags`. If pressed, call
  `PersistenceStore.archiveCurrent()` and create a fresh empty
  workspace. Otherwise, call `PersistenceStore.load()` and if
  non-nil pass it to `AppModel.restore(from:)`.
- `Sources/LabanApp/AppDelegate.swift` — implement
  `applicationWillTerminate` to call
  `PersistenceCoordinator.flushSync()`.

**Schema (M0).**

```json
{
  "schemaVersion": 1,
  "windows": [
    {
      "id": "win-7E2F",
      "selectedTabId": "tab-A1B2",
      "tabs": [
        {
          "id": "tab-A1B2",
          "cwd": "/Users/rrj/wrk/laban",
          "launchCommand": "/bin/zsh -l",
          "lastActiveAt": "2026-05-17T14:23:11Z"
        }
      ]
    }
  ]
}
```

**Acceptance (M0).** From a fresh state:

1. Delete `~/Library/Application Support/Laban/` if it exists.
2. Build and launch Laban: `./scripts/build-app && open -W .build/...`
  (path per existing build convention; use whatever
  `./scripts/build-app` produces).
3. Create three tabs. In each, run `cd /tmp` (tab 1), `cd ~/Documents`
  (tab 2), leave default cwd (tab 3). Switch the selection to tab 2.
4. Quit with Cmd-Q.
5. Inspect `~/Library/Application Support/Laban/workspace.json` —
  expect `windows` is an array of length 1, that one window has
  three tabs with the three cwds and `selectedTabId` matching tab 2.
6. Relaunch Laban.
7. Observe: three tabs in the same order, tab 2 selected. Each tab
  is at a fresh shell prompt. Run `pwd` in each tab — outputs match
  the saved cwds.
8. Relaunch with ⇧ held. Observe: empty workspace, one default tab.
  `~/Library/Application Support/Laban/workspace.json.previous`
  exists with the prior content.

**Test (M0).** Add headless test in `Tests/LabanCoreTests/`:
`PersistenceRoundTripTests.swift` — constructs an `AppModel` with
three tabs, calls `PersistenceCoordinator.flushSync()`, reads
`workspace.json` from a temp directory, calls
`AppModel.restore(from:)` in a new model, asserts equality of
window/tab structure and selection.

### M1 — Transcript capture and render-on-restore

**Scope.** Capture PTY output bytes to per-tab transcript files,
restore scrollback on launch with the hybrid render policy (text
for old bytes, byte-replay for last ~1MB, skip if alt-buffer was
active at quit).

**New files.**

- `Sources/LabanCore/Persistence/TranscriptWriter.swift` — owns a
  per-tab in-memory ring buffer (default 256KB) and a file handle to
  `transcripts/<tab-id>.bin` opened for append. The C persistence
  callback (registered via `laban_session_set_persistence_callback`)
  calls a `writeChunk(_:)` method that does **only** `memcpy` into the
  ring buffer under a short critical section, then returns.
  **Overflow policy: drop oldest.** If the ring is full when
  `writeChunk` arrives, the new bytes overwrite the oldest bytes
  and the head pointer advances. The callback never blocks, never
  returns an error, never allocates. A drop counter is incremented
  so telemetry can detect sustained-overflow conditions.
  A dedicated drain dispatch queue (`label: "laban.persistence",
  qos: .utility`) ticks on 200ms debounce, drains the ring into the
  file via `write(2)`, optionally calls `fsync(2)`, and runs the
  head-truncation pass when the file exceeds 10MB (re-writes via temp
  + atomic rename to drop the oldest 1MB). Disk IO never runs on the
  PTY callback's caller.
- `Sources/LabanCore/Persistence/TranscriptRenderer.swift` — given a
  file path and a target `Session`, performs the hybrid restore.
  Reads file size, computes `nominal_cutoff = max(0, size - 1MB)`,
  then **walks forward from `nominal_cutoff` to the next ASCII LF
  (0x0A)** to find a safe resync point. The byte-replay window
  starts at the byte *after* that LF. If no LF exists between
  `nominal_cutoff` and EOF, the entire suffix is text-stripped and
  no byte replay happens (degenerate but safe — terminal output
  almost always contains newlines).
  For the prefix (older bytes):
    1. Strip ANSI escape sequences and other non-printable control
       bytes via a small pure-Swift stripper (CSI introducers `ESC [`
       through final byte, OSC introducers `ESC ]` through `BEL` or
       `ST`, SS2/SS3, simple control bytes outside `\t\n\r`). The
       stripper does not need to be perfect — it only handles the
       common cases that produce visible scrollback. Bytes that
       survive stripping are valid UTF-8 text plus newlines.
    2. Feed the stripped bytes through `ghostty_terminal_vt_write`
       on the target session. libghostty-vt scrolls plain text into
       its scrollback buffer by its normal rules — no special
       scrollback-injection API is required. The result is text
       visible in the scrollback when the user scrolls up.
  For the suffix (last 1MB):
    1. Feed bytes through `ghostty_terminal_vt_write` directly. The
       parser handles escape sequences normally and rebuilds the
       visible screen with original color and style.
  If `altBufferAtQuit` was true:
    1. Skip both prefix and suffix. The terminal stays empty. The
       UI separately renders the "process exited" marker from the
       persisted `processStatus`.

**Modifications.**

- `Sources/LabanTerminalCore/pty_io.c` — add a second callback slot
  specifically for persistence:
  `LabanPersistenceBytesCallback s->persistence_callback`. The
  persistence consumer is registered by `Session.swift` at
  session-create time. Invoked from `laban_vt_write_capture` after
  the existing capture callback, before the libghostty-vt write.
  **The callback contract is: copy bytes to caller-supplied buffer
  and return; do no IO.** This is mechanically enforced because the
  Swift implementation in `TranscriptWriter.writeChunk(_:)` only does
  a `memcpy` into its ring buffer.
- `Sources/LabanTerminalCore/session_internal.h` — add the
  persistence callback fields and the bridge function
  `laban_session_set_persistence_callback`.
- `Sources/LabanCore/Session.swift` — at create time, instantiate a
  `TranscriptWriter` keyed by the tab's UUID and register a C
  callback that bridges the bytes to it. The callback path must not
  spawn dispatch work, perform synchronous IO, or call into
  AppModel/UI — its single job is feeding the ring buffer. The
  persistence drain queue (owned by `TranscriptWriter`) does the
  actual disk work on its own schedule.
- `Sources/LabanTerminalCore/session_internal.h` and one of the
  `.c` files — add `laban_session_alt_buffer_active(s) -> int`
  bridging libghostty-vt's alt-buffer state. If libghostty-vt's C
  ABI does not expose this, add a small shim by reading the bit
  via whatever struct/field is reachable (consult libghostty-vt
  headers in `.external/`); if there is no clean route, add an
  upstream gap to `docs/process/...` and persist the flag via the
  existing tab-status scan path that already detects similar
  state.
- `Sources/LabanCore/AppModel.swift` — on tab close and on quit,
  capture `altBufferAtQuit` and `processStatus` into the saved
  tab state.
- `Sources/LabanCore/Persistence/PersistenceCoordinator.swift` —
  drives the restore sequence. Strict order per tab:
  1. Construct the `Session` and spawn its shell in the saved (or
     fallback) cwd.
  2. Call `TranscriptRenderer.render(file: ..., into: session)`.
     Text-stripped scrollback is fed first; the byte-replay window
     is fed second. libghostty-vt processes both before the first
     visible frame is rendered.
  3. (M2) Ask `RestoreLaunchPlanner` for the launch instruction
     and apply it (`executeNow` writes bytes + newline;
     `prefillPrompt` writes bytes only; `noPrefill` no-ops).
  4. Mark the session ready for display.

  Steps 1–4 happen per tab on a background queue; the
  selected tab is processed first so the user sees their focused
  tab fastest. All other tabs hydrate concurrently.

**Cwd-gone fallback (M1).**

When restoring a tab, before spawning the shell, stat the saved
`cwd`. If it does not exist, is not a directory, or is not
readable by the current user:

1. Replace the spawn `cwd` with `FileManager.default.homeDirectoryForCurrentUser`.
2. Set `TabState.cwdFallbackApplied = true` in the restored tab
  metadata (the next persist will write this back, so the next
  restore will not re-show the banner unless the user re-saved a
  different cwd).
3. Render a one-line banner in the tab's pane (above scrollback
  or as a non-destructive overlay row): "Could not restore
  working directory `<original cwd>`; using `~`." The banner is
  dismissible by any user input and does not block the prompt.

Persist `cwdFallbackApplied: Bool` (optional, defaults to false)
in `TabState` so headless tests can assert the fallback was taken
without parsing UI text.

**Schema additions (M1).**

```json
"tabs": [
  {
    ...
    "transcriptPath": "transcripts/tab-A1B2.bin",
    "altBufferAtQuit": false,
    "processStatus": "running",
    "exitCode": null
  }
]
```

**Acceptance (M1).**

1. Open Laban, in tab 1 run `ls -la`, `pwd`, `date`, `seq 1 50`.
2. In tab 2 run `vim` (do not quit vim).
3. Quit Laban.
4. Inspect `~/Library/Application Support/Laban/transcripts/` —
  expect two `.bin` files, one per tab, sizes >0.
5. Inspect `workspace.json` — tab 1 has `altBufferAtQuit: false`,
  tab 2 has `altBufferAtQuit: true`.
6. Relaunch Laban.
7. Observe: tab 1 shows the prior `ls`/`pwd`/`date`/`seq 1 50` output
  in scrollback, with `seq`'s last screen visible at the bottom in
  its original color rendering. Tab 2 is an empty terminal with a
  "process exited" marker (no fake vim).
8. Scroll up in tab 1 to confirm older history is present as text
  (color may be flat for output older than the 1MB cutoff; recent
  output retains color and styling).

**Test (M1).** Add `Tests/LabanCoreTests/TranscriptRoundTripTests.swift`:
- Spawn a fixture session, write a known byte stream, invoke
  `PersistenceCoordinator.flushSync()`, assert the `.bin` file
  contents match.
- Restore the session into a fresh `AppModel`, assert the rendered
  scrollback's text equals the original.
- Repeat with a stream that enters alt-buffer mode at the end;
  assert `altBufferAtQuit: true` is persisted and that restore
  skips byte-replay.

### M2 — Agent (Claude + Codex) session id capture, autoresume, JSONL mirror

**Product-scope anchor.** M2 introduces agent-aware terminal
behavior — detecting `claude`/`codex` processes inside tabs and
rewriting their launch on restore — which is **not** described in
`docs/product/spec.md` as written. Per `AGENTS.md`:

> Do not add product behavior outside the product docs unless the
> user asks for it or it is required to keep an MVP behavior
> working.

M2 ships under the **user-asked-for-it** clause. The user's verbatim
requirements from the grilling session that produced this plan:

> "I want something brand-defining" — (in the context of the Claude
> session autopilot)

> "I want it to work for codex as well as for claude. both should
> have equal support. they are similar."

These statements authorize the M2 scope. If product direction
shifts away from agent-awareness, M2 should be revisited; in the
meantime, future work that introduces *additional* agent-aware
behavior should either fold into a future spec.md update covering
agent-host policy or carry its own user-authorization quote.

**Scope.** Detect when a `claude` or `codex` process runs in a tab,
capture its session id and JSONL path, persist them, and on restore
auto-rewrite the launch command to the agent's resume invocation
(silent execution when the agent was alive at quit; prefilled
otherwise). Mirror the JSONL on lifecycle events as a diagnostic
snapshot. Claude and Codex are equal first-class citizens; adding a
third agent later is one entry in `AgentSupport`.

**New files.**

- `Sources/LabanApp/AgentSupport.swift` — table of supported agents.
  Each entry is
  `(name: AgentName, binaryBasenames: [String],
  resumeCommand: (String) -> String,
  extractSessionId: (vnodePath: String) -> String?)`.
  Initial entries:
    - `.claude` → basenames `["claude"]`,
      resume: `{ id in "claude --resume \(id)" }`,
      extract: match `vnodePath` against
      `(.+/)?\.claude/projects/[^/]+/([0-9a-f-]{36})\.jsonl$`
      (UUID-shape stem under `.claude/projects/`); also honor
      `CLAUDE_CONFIG_DIR` if set in Laban's own environment by
      substituting the prefix.
    - `.codex` → basenames `["codex"]`,
      resume: `{ id in "codex resume \(id)" }` (verified against
      `github.com/openai/codex` cli `main.rs` — codex uses a
      subcommand, not a `--resume` flag),
      extract: match against
      `(.+/)?\.codex/sessions/.+/([0-9a-f-]{36})\.jsonl$`
      (verify the exact subpath against `~/.codex/` layout at
      implementation time; the regex anchors on `.codex/sessions/`
      and a UUID stem — adjust if the upstream layout differs).
  Single source of truth. Adding a new agent later is a single
  entry; no other code changes. Agents whose session ids are not
  UUIDs need their own extractor; the default UUID-shape check
  rejects them.
- `Sources/LabanApp/AgentSessionDetector.swift` — for each active
  session, owns a `DispatchSourceTimer` firing every 500ms on a
  background queue. On each tick:
  1. Calls `proc_listpids(PROC_PPID_ONLY, parentPid, ...)` to
    enumerate immediate children of the tab's shell pid; recurses
    once or twice for typical wrapper depth (`npx`, `direnv`,
    `time`). Caps recursion at depth 4 to bound the worst case.
  2. For each descendant pid, calls
    `proc_pidpath(pid, buf, sizeof(buf))` to resolve its executable
    path. Matches the basename against the union of all
    `AgentSupport.binaryBasenames` (currently `claude`, `codex`).
  3. On a match, queries
    `proc_pidinfo(PROC_PIDLISTFDS, ...)` and
    `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO, ...)` to enumerate the
    process's open file descriptors and resolve each to its vnode
    path.
  4. For each `.jsonl` open fd, call the matched agent's
    `AgentSupport.extractSessionId(vnodePath:)`. The first fd whose
    extractor returns a non-nil session id wins. The extractor
    enforces both the agent's known path layout and a UUID-shape
    check, so unrelated `.jsonl` files the process may have open
    (configs, caches, data) are filtered out. If no `.jsonl` fd
    matches, no detection is made on this tick and the tab restores
    later as a fresh agent invocation without the resume form.
    Captures `(agentName, sessionId, jsonlPath,
    wasRunningAtQuit: true)` and notifies the tab via a delegate.

  **Timer never stops.** Each subsequent tick:
  - If the previously-matched agent descendant is still alive and
    its session id is unchanged, no-op.
  - If a matched descendant is alive but the session id has
    changed (user invoked `claude --resume Y` after the original
    session ended), update the tab's `AgentInfo` to the new id.
  - If no matched agent descendant is found (user Ctrl-D'd
    `claude`), set `wasRunningAtQuit = false` while preserving the
    previously-captured `name`/`sessionId`/`jsonlPath`. The
    `RestoreLaunchPlanner` uses this to decide silent vs prefilled
    resume on next launch.

  Race handling: if `proc_pidinfo` returns no `.jsonl` fd on the
  first match (the agent process exec'd but has not yet opened its
  log file), the next tick retries — the timer's never-stop policy
  handles this naturally. The window between exec and JSONL-open in
  observed `claude` and `codex` versions is well under one tick
  (500ms).
- `Sources/LabanApp/AgentJSONLMirror.swift` — copies the captured
  `jsonl_path` to `agent-mirror/<tab-id>.jsonl` using `FileManager`
  atomic copy. Idempotent. One mirror file per tab regardless of
  agent — the agent type is recorded in `workspace.json`. Fires on:
  - The agent process exits (detector observes
    `wasRunningAtQuit: true → false` transition).
  - The tab is closed.
  - Laban quits (`applicationWillTerminate`).
  - **A 5-minute periodic `DispatchSourceTimer` while the agent is
    observed alive in the tab.** The periodic timer starts when
    the detector first captures an `AgentInfo` for the tab and is
    cancelled when the agent dies, when the tab closes, or at
    quit. Bounds mid-session loss to ~5 minutes if Laban or the
    machine crashes during an active agent conversation.
- `Sources/LabanApp/RestoreLaunchPlanner.swift` — given a
  `TabState`, computes the launch instruction. The decision uses
  `tab.agent?.wasRunningAtQuit`, **not** `tab.processStatus`
  (which tracks the shell, always alive, not the agent — see
  Decision Log).
  - `executeNow(command:)` — run the command immediately, no
    visible prompt prefill. Used **only** for the agent's resume
    invocation (looked up via
    `AgentSupport[agent.name].resumeCommand(agent.sessionId)`)
    when `tab.agent` is non-nil *and*
    `tab.agent.wasRunningAtQuit == true`.
  - `prefillPrompt(command:)` — feed the command bytes into the
    PTY as input without a trailing newline; the prompt shows the
    command and the user presses ENTER to run it. Used **only**
    when `tab.agent` is non-nil and
    `tab.agent.wasRunningAtQuit == false` (the user had exited
    the agent before quitting Laban, but we have the session id
    captured); the pre-filled command is the agent's resume
    invocation.
  - `noPrefill` — fresh shell, no command pre-fill. Used for every
    other case: non-agent tabs (running or dead), agent tabs where
    session id capture failed, never-started tabs.

  We do **not** pre-fill the persisted `launchCommand` for non-agent
  tabs. The persisted command is the *shell's* launch (e.g.
  `/bin/zsh -l`), not the user's typed command (e.g. `make build`).
  Pre-filling the shell command is nonsense; capturing the user's
  typed command requires OSC 133 shell integration which is separate
  scope.

**Modifications.**

- `Sources/LabanCore/Persistence/WorkspaceState.swift` — add an
  optional nested `agent: AgentInfo?` field per `TabState`, where
  `AgentInfo` holds `(name: AgentName, sessionId: String,
  jsonlPath: String)` and `AgentName` is an enum with `.claude` and
  `.codex` cases (Codable as the lowercase string).
- `Sources/LabanCore/AppModel.swift` — wire the
  `AgentSessionDetector` to mark a tab's `agent` field when a
  detection fires; route `AgentJSONLMirror` to all three lifecycle
  events.
- `Sources/LabanApp/AppDelegate.swift` — on restore, after each tab
  is constructed and its transcript rendered, ask
  `RestoreLaunchPlanner` for the launch instruction. For
  `executeNow` write the bytes to the new tab's PTY followed by a
  newline. For `prefillPrompt` write the bytes to the PTY with no
  newline (the user supplies ENTER). For `noPrefill` do nothing —
  the shell prompt is already visible from the freshly spawned
  shell.
- **Auto-fallback for "session not found" is NOT in M2.** The
  mirror snapshots are written on lifecycle events and persisted
  to disk so that a future M2.5 follow-up can ship the
  auto-restore path. In M2, if the agent's resume invocation fails
  at restore time, the user sees the failure in scrollback and the
  `noPrefill` shell prompt is available — they can manually
  recover by copying the mirror file from
  `~/Library/Application Support/Laban/agent-mirror/<tab-id>.jsonl`
  back to the agent's expected path themselves.

**Schema additions (M2).**

```json
"tabs": [
  {
    ...
    "agent": {
      "name": "claude",
      "sessionId": "0fa31a8c-...-...",
      "jsonlPath": "/Users/rrj/.claude/projects/.../0fa31a8c-...-....jsonl"
    }
  }
]
```

The `agent` field is optional; non-agent tabs omit it. `name` is
the lowercase agent name (`"claude"` or `"codex"`).

**Acceptance (M2).** Run the scenario twice — once with Claude,
once with Codex — to confirm equal support.

**Claude scenario:**

1. Open Laban, in tab 1 run `claude`. Have a brief conversation
  (e.g. "What's 2+2?", wait for reply).
2. While Claude is still running, quit Laban.
3. Inspect `workspace.json` — tab 1's `agent` field is
  `{"name": "claude", "sessionId": "...", "jsonlPath": "..."}`.
4. Inspect `~/Library/Application Support/Laban/agent-mirror/` —
  expect `<tab-id>.jsonl` exists with the conversation contents.
5. Relaunch Laban.
6. Observe: tab 1 is selected, scrollback shows the prior Claude
  conversation rendered with original color, and **Claude is
  already running** (no visible "press ENTER to resume" prompt).
  The prompt is in a fresh state ready for the next message.
7. Type a follow-up message into Claude (e.g. "And 3+3?"). Claude
  responds with awareness of the prior turn.

**Codex scenario:**

1. Open Laban, in tab 1 run `codex`. Have a brief conversation
  (e.g. "What's 2+2?", wait for reply).
2. While Codex is still running, quit Laban.
3. Inspect `workspace.json` — tab 1's `agent` field is
  `{"name": "codex", "sessionId": "...", "jsonlPath": "..."}`.
4. Inspect `~/Library/Application Support/Laban/agent-mirror/` —
  expect `<tab-id>.jsonl` exists with the conversation contents.
5. Relaunch Laban.
6. Observe: tab 1 is selected, scrollback shows the prior Codex
  conversation rendered with original color, and **Codex is
  already running** (no visible "press ENTER to resume" prompt).
  The shell history shows `codex resume <id>` was executed.
7. Type a follow-up message into Codex. Codex responds with
  awareness of the prior turn.

**Negative scenario:**

8. Open Laban, run a non-agent command (`tail -f /var/log/system.log`),
  quit while it's running, relaunch. Observe: the tab restores with
  the prior scrollback visible, a fresh shell prompt at the
  bottom, and **no command prefilled**. The non-agent prefill
  pattern was deliberately not shipped (see Decision Log).

**Test (M2).** Add `Tests/LabanAppTests/AgentSessionDetectorTests.swift`:
- Spawn a synthetic process named `claude` (a small Swift helper
  binary) that opens a file at a temp path ending in `.jsonl`;
  assert the detector reports the right `agentName: .claude` and
  `sessionId`.
- Repeat with the helper renamed to `codex`; assert detection
  reports `agentName: .codex`.
- Spawn two helper processes in the same descendant tree (one
  `claude`, one `codex`); assert both are detected and the most
  recent one wins as the tab's `agent`.

Add `Tests/LabanAppTests/RestorePlannerTests.swift`:
- For each combination of (processStatus, agentName, hasSessionId),
  assert the planner returns the expected instruction. Specifically:
  - `(running, .claude, true)` → `executeNow("claude --resume <id>")`.
  - `(running, .codex, true)` → `executeNow("codex resume <id>")`.
  - `(exited_clean, .claude, true)` → `prefillPrompt("claude --resume <id>")`.
  - `(exited_clean, .codex, true)` → `prefillPrompt("codex resume <id>")`.
  - `(running, nil, _)` → `noPrefill`.
  - `(exited_*, _, false)` → `noPrefill`.

Add an end-to-end fixture in `fixtures/` that replays a captured
Claude session and one that replays a captured Codex session;
verify the restore path produces the expected final state for each.

## Plan of Work

Sequence each milestone independently. Land M0, ship, validate.
Land M1, ship, validate. Land M2, ship, validate. Do not bundle
milestones into a single PR — each is independently observable and
independently reversible.

Inside each milestone, the order is:

1. Add types and ABI (compile-only, no behavior).
2. Wire into the read/write hot paths with a feature flag or
  default-off conditional, behind which the new code is exercised
  but the user-visible behavior is unchanged.
3. Write the headless test that exercises the new path.
4. Flip the default to on for normal launches.
5. Validate acceptance manually with the recipe in this plan.
6. Update Progress with milestone completion timestamp.

## Concrete Steps

For each milestone, run:

```sh
./scripts/build-app
```

from the repo root after each round of edits. Run the test suite
with whatever the project convention is (check `scripts/check` if
present); the existing convention per AGENTS.md is to confirm
`check passed`.

```sh
./scripts/check
```

For the manual acceptance runs, the persistence directory to
inspect is:

```sh
ls -la "$HOME/Library/Application Support/Laban/"
cat "$HOME/Library/Application Support/Laban/workspace.json" | jq .
```

To reset to a clean state between manual runs:

```sh
rm -rf "$HOME/Library/Application Support/Laban/"
```

## Validation and Acceptance

The user-visible behavior at completion of all three milestones is:

- Cmd-Q + relaunch reconstructs the prior single-window workspace
  silently.
- Claude tabs and Codex tabs that were running at quit auto-resume
  their conversation (no clicks). The resume invocation differs by
  agent: `claude --resume <id>` for Claude, `codex resume <id>` for
  Codex.
- Claude or Codex tabs whose agent had exited cleanly before quit
  show the prior transcript with their respective resume command
  pre-filled in the shell prompt, awaiting ENTER.
- Non-agent tabs come back with their transcript visible and a
  fresh shell prompt, no pre-fill regardless of whether the prior
  process was running at quit.
- vim/htop/less tabs come back as empty terminals with an "exited"
  marker, not a fake half-restored TUI state.
- Holding ⇧ at launch starts a fresh workspace and archives the
  prior state to `workspace.json.previous`.
- The persistence directory at
  `~/Library/Application Support/Laban/` contains `workspace.json`,
  `transcripts/<tab-id>.bin` files, and (for agent tabs) an
  `agent-mirror/<tab-id>.jsonl` file each.
- All headless tests pass; `./scripts/check` reports passed.

## Idempotence and Recovery

- All persistence writes use `Data.write(to:options:.atomic)` —
  POSIX `write-tmp + close + rename`. The atomic *rename* always
  produces either the prior file or the new file, never a half
  state. What it does **not** guarantee:
  - **Process-crash safety (SIGKILL, Force Quit, OOM, Laban
    panic)**: the prior `workspace.json` is always intact, but
    writes from inside the 200ms debounce window may be lost
    because they had not yet flushed from Swift's debounce queue
    to disk. *The prior file is intact; the most recent few
    hundred ms of state may not be.*
  - **Kernel panic**: same as process crash, plus the OS buffer
    cache may not have written the renamed file's data blocks to
    disk yet — APFS's journal recovers filesystem consistency
    (the rename is journaled atomically) but may discard recent
    data writes that had not been flushed. Prior file intact;
    rename may roll back.
  - **Hard power loss (power-button hold, wall unplug)**: same as
    kernel panic, plus the SSD's own write cache may not have
    committed to NAND. Without `F_FULLFSYNC` we cannot bound how
    much recent state survives — could be the last few seconds,
    could be more.
  This matches the durability contract Chrome, VS Code, and
  Sublime ship; see Decision Log for the rationale and the
  revisit trigger. If `F_FULLFSYNC` is added later, it is on the
  `workspace.json` write only (transcript bytes stay on the cheap
  path).
- `workspace.json.previous` is overwritten on every ⇧-at-launch
  archive — it is a single rolling backup, not a history.
- Transcript `.bin` files are append-only. A truncation event
  (head-eviction at 10MB cap) rewrites the file via temp + rename
  to remain crash-safe.
- Agent JSONL mirror copies (Claude and Codex) are atomic via
  `FileManager.replaceItemAt`. On failure (disk full,
  permissions), the mirror is skipped but the rest of the
  shutdown completes; the user loses one snapshot of diagnostic
  state for that tab, nothing else.
- A corrupt `workspace.json` (failed Codable decode) at launch
  causes a fall-through to fresh empty workspace; the corrupt file
  is renamed to `workspace.json.corrupt-<timestamp>` so a developer
  can inspect it. The user sees an empty workspace, not a crash
  loop.
- `rm -rf ~/Library/Application Support/Laban/` is a safe full
  reset.

## Review Gate

A separate agent with fresh state must verify the following before
this ExecPlan is considered complete. The executing agent must not
mark the plan as done until this gate has passed. See the "Review
gate and review-fix loop" section in PLANS.md for the full process.

Per-milestone gates:

**M0 gate**

- [ ] `grep -rn "workspace.json" Sources/` — at least one hit in
  `Sources/LabanCore/Persistence/` or `Sources/LabanApp/`.
- [ ] `grep -rn "schemaVersion" Sources/LabanCore/Persistence/` —
  expect a constant `1` and a Codable struct usage.
- [ ] Build: `./scripts/build-app` exits 0.
- [ ] Tests: `./scripts/check` exits 0; the new
  `PersistenceRoundTripTests` appears in test output with a pass.
- [ ] Manual: from clean state
  (`rm -rf "$HOME/Library/Application Support/Laban/"`), launch
  Laban, create three tabs with distinct cwds, quit, relaunch.
  Confirm `workspace.json` contains three tabs and that relaunch
  shows three tabs in the same order with `pwd` matching the
  saved cwds.
- [ ] Manual: launch with ⇧ held; confirm fresh workspace and
  presence of `workspace.json.previous`.
- [ ] `grep -rn "SQLite\|Core[ ]Data\|sqlite3" Sources/LabanCore/Persistence/ Sources/LabanApp/` —
  expect zero hits. The persistence stack must be Foundation-only.
- [ ] `grep -rn "tmux\|screen[ -]session" Sources/` — expect zero
  hits. No multiplexer dependency.

**M1 gate**

- [ ] `ls Sources/LabanCore/Persistence/` — expect both
  `TranscriptWriter.swift` and `TranscriptRenderer.swift` present.
- [ ] `grep -n "laban_session_set_persistence_callback\|persistence_callback" Sources/LabanTerminalCore/` —
  expect the ABI is declared in `session_internal.h` and invoked
  from `capture.c` / `pty_io.c`.
- [ ] Manual M1 acceptance recipe above (steps 1–8).
- [ ] Tests: `TranscriptRoundTripTests` passes; the
  alt-buffer-skip case is asserted.
- [ ] Inspect a transcript file after a session run:
  `wc -c "$HOME/Library/Application Support/Laban/transcripts/"*.bin`
  — expect non-zero bytes for tabs that produced output.
- [ ] Manual: run a session that produces >10MB of output and
  verify the file is capped (not unbounded growth):
  `dd if=/dev/urandom bs=1M count=15 | od -c` inside a tab, then
  inspect file size — expect ≤ 10MB after truncation.

**M2 gate**

- [ ] `grep -rn "proc_listpids\|proc_pidpath\|proc_pidinfo\|proc_pidfdinfo" Sources/LabanApp/` —
  expect hits in `AgentSessionDetector.swift`.
- [ ] `grep -rn "EVFILT_PROC\|NOTE_EXEC\|NOTE_FORK" Sources/LabanApp/` —
  expect zero hits. The kqueue process-notification design was
  rejected; see Decision Log for the rationale.
- [ ] `grep -rn "DispatchSourceTimer" Sources/LabanApp/AgentSessionDetector.swift` —
  expect at least one hit (the 500ms polling source).
- [ ] `grep -rn "claude --resume\|codex resume\|AgentSupport\|AgentInfo" Sources/` —
  expect hits in `AgentSupport.swift`, the launch planner, and
  schema definitions. Both Claude and Codex resume forms must be
  present.
- [ ] `grep -n '"claude"\|"codex"' Sources/LabanApp/AgentSupport.swift` —
  expect entries for both agents.
- [ ] Manual M2 acceptance: run both the Claude scenario AND the
  Codex scenario from the acceptance recipe above; both must
  silently auto-resume on relaunch. Then run the negative scenario
  (non-agent tab) and confirm no command is pre-filled.
- [ ] Tests: `AgentSessionDetectorTests` and
  `RestorePlannerTests` pass. Detector tests must include both a
  Claude case and a Codex case.
- [ ] Inspect the mirror directory after agent sessions:
  `ls -la "$HOME/Library/Application Support/Laban/agent-mirror/"`
  — expect a `.jsonl` per agent-running tab; file size > 0.
- [ ] Verify the silent auto-resume rule uses **agent liveness**,
  not shell processStatus:
  `grep -n "wasRunningAtQuit\|processStatus" Sources/LabanApp/RestoreLaunchPlanner.swift` —
  expect `wasRunningAtQuit` is read; `processStatus` must NOT
  appear in the planner's decision. `executeNow` is taken **only**
  when `tab.agent.wasRunningAtQuit == true`; dead-agent tabs with
  a session id use `prefillPrompt`; everything else uses
  `noPrefill`. Non-agent tabs never receive a pre-fill.
- [ ] Per-agent path matcher present:
  `grep -n "extractSessionId" Sources/LabanApp/AgentSupport.swift` —
  expect each agent entry supplies an extractor that returns nil
  for non-session `.jsonl` paths. Universal `.jsonl`-stem matching
  was rejected; see Decision Log.
- [ ] Periodic snapshot timer present:
  `grep -n "5.*min\|300.*second\|DispatchSourceTimer" Sources/LabanApp/AgentJSONLMirror.swift` —
  expect a periodic timer fires while the agent is observed alive.
- [ ] Detector timer never stops:
  `grep -n "cancel\(\)\|suspend\(\)" Sources/LabanApp/AgentSessionDetector.swift` —
  expect the only `cancel`/`suspend` calls are on tab teardown,
  not on session-id capture. (Self-contradictory "stop on capture
  + re-arm on next tick" wording was rejected; see Decision Log.)
- [ ] Safe replay boundary in TranscriptRenderer:
  `grep -n "0x0A\|\"\\\\n\"\|LF" Sources/LabanCore/Persistence/TranscriptRenderer.swift` —
  expect a forward walk from the 1MB nominal cutoff to the next LF.
- [ ] Ring overflow policy present:
  `grep -n "drop\|overflow\|head pointer" Sources/LabanCore/Persistence/TranscriptWriter.swift` —
  expect the drop-oldest behavior is documented in code or comment;
  expect a drop counter for telemetry.
- [ ] Confirm auto-fallback is **NOT** in M2:
  `grep -rn "session not found\|replaceItemAt.*\.claude\|replaceItemAt.*\.codex" Sources/` —
  expect zero hits. The fallback path is deferred to M2.5; M2
  ships only the mirror writes.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Interfaces and Dependencies

### C ABI additions in `Sources/LabanTerminalCore/`

```c
/* Added in session_internal.h */

typedef void (*LabanPersistenceBytesCallback)(
    void *userdata,
    LabanSession *s,
    const uint8_t *bytes,
    size_t len
);

int laban_session_set_persistence_callback(
    LabanSession *s,
    LabanPersistenceBytesCallback callback,
    void *userdata
);

/* Returns 1 when the terminal is currently in alternate-screen-buffer
 * mode, 0 otherwise. */
int laban_session_alt_buffer_active(LabanSession *s);
```

The persistence callback is invoked from `laban_vt_write_capture` for
every chunk of PTY output, after the existing capture callback and
before `ghostty_terminal_vt_write`.

### Swift types

```swift
// Sources/LabanCore/Persistence/WorkspaceState.swift

public struct WorkspaceState: Codable, Equatable {
  public var schemaVersion: Int  // = 1
  public var windows: [WindowState]
}

public struct WindowState: Codable, Equatable {
  public var id: String
  public var selectedTabId: String?
  public var tabs: [TabState]
}

public struct TabState: Codable, Equatable {
  public var id: String
  public var cwd: String
  public var launchCommand: String
  public var lastActiveAt: Date
  // M1 additions:
  public var transcriptPath: String?
  public var altBufferAtQuit: Bool?
  public var cwdFallbackApplied: Bool?  // true if restore fell back to $HOME
  public var processStatus: ProcessStatus?
  public var exitCode: Int?
  // M2 additions:
  public var agent: AgentInfo?
}

public struct AgentInfo: Codable, Equatable {
  public var name: AgentName
  public var sessionId: String
  public var jsonlPath: String
  public var wasRunningAtQuit: Bool  // detector-observed agent liveness at quit
}

public enum AgentName: String, Codable {
  case claude
  case codex
}

public enum ProcessStatus: String, Codable {
  case running, exitedClean, exitedError, neverStarted
}
```

### External system dependencies

- `proc_listpids(PROC_PPID_ONLY, ppid, ...)`, `proc_pidpath`,
  `proc_pidinfo(PROC_PIDLISTFDS, ...)`,
  `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO, ...)` from
  `<libproc.h>` — present on all macOS versions Laban targets.
  No entitlement required for descendant processes (Laban is the
  parent of each tab's shell, which is the parent of any agent
  process spawned inside).
- `DispatchSourceTimer` from Dispatch — used by
  `AgentSessionDetector` for per-tab 500ms polling.
- `FileManager.replaceItemAt` for atomic file replacement.
- `Codable` / `JSONEncoder` / `JSONDecoder` from Foundation.
- libghostty-vt for the byte-replay restore path (existing
  dependency).

No third-party packages added. No SQLite. No Core Data. No tmux.
No `EVFILT_PROC` / `NOTE_EXEC` — see Decision Log for why polling
was chosen over kqueue process notifications.
