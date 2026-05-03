# Build The SwiftPM AppKit Software-Rendered MVP

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then build the first runnable Laban terminal milestone.

## Purpose / Big Picture

This work turns the planning repository into a local macOS `.app` and a
headless agent harness. After this plan is complete, a developer can launch one
AppKit window, see terminal text rendered by the software renderer, type into a
libghostty-backed shell, create and switch sidebar tabs without restarting
sessions, query local debug state, and capture a screenshot from the same
rendering path used by headless tests.

The first milestone is intentionally not a polished terminal. It is the
smallest credible implementation shape: SwiftPM, AppKit, a C terminal core
wrapping libghostty and PTY ownership, Swift app state, software bitmap
rendering, local debug endpoints, fixture-driven headless verification, and a
developer-only `.app` bundle. Production Metal rendering, Xcode project polish,
preferences, tab drag/drop, real scrollbars, accessibility polish, signing,
notarization, and packaging are deferred.

This is the umbrella plan for the full first runnable terminal milestone. Do
not hand the whole document to an execution agent as one coding task. Start
with the smaller first shard in
`execplans/active/swiftpm-libghostty-skeleton.md`, then update this umbrella
plan as each shard lands.

## Progress

- [x] Read repository guide documents: `AGENTS.md`, `README.md`, `PLANS.md`,
  `docs/README.md`, `execplans/README.md`, `execplans/active/README.md`,
  `execplans/completed/README.md`, and
  `execplans/completed/choose-implementation.md`.
- [x] Read product documents: `docs/product/mvp.md` and
  `docs/product/spec.md`.
- [x] Read process and reference documents:
  `docs/process/dev-process.md`, `docs/process/worktree-isolation.md`,
  `docs/process/observability.md`,
  `docs/process/agent-operating-guide.md`, and
  `docs/reference/prototype-implementation-notes.md`.
- [x] Read quality, fixture, and schema documents:
  `docs/quality/quality.md`, `docs/quality/tech-debt.md`,
  `fixtures/README.md`, `fixtures/colored-boxes.fixture.json`,
  `schemas/README.md`, `schemas/fixture.schema.json`,
  `schemas/artifact-manifest.schema.json`, and all JSON schemas under
  `schemas/debug/`.
- [x] Record the user-selected stack: SwiftPM, AppKit, C libghostty terminal
  core, software renderer first, local `.app` only.
- [x] Create this active ExecPlan.
- [x] Add the first execution shard at
  `execplans/active/swiftpm-libghostty-skeleton.md`.
- [x] Pin and prove the libghostty dependency. Outcome: GhosttyKit v1.3.1
  requires a live NSView* and has no headless constructor; libghostty-vt at
  commit `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b` is a standalone VT
  library with no GUI dependency. Link spike confirmed SwiftPM can link
  `libghostty-vt.a` via unsafeFlags. See
  `execplans/active/terminal-session-libghostty-vt.md` for build details.
- [x] Add the SwiftPM package skeleton and target boundaries. Package.swift,
  all target stubs, `scripts/build-app`, and `./scripts/check` exit 0.
  Documented in `execplans/active/swiftpm-libghostty-skeleton.md`.
- [x] Link libghostty-vt into LabanTerminalCore and prove
  `ghostty_terminal_new` from a Swift test. Shard:
  `execplans/active/terminal-session-libghostty-vt.md`, Milestone 1.
- [x] Add the C terminal core ABI, PTY lifecycle, libghostty-vt session
  creation, nonblocking polling, resize, input write, render-state snapshots
  with true colors and grapheme clusters, title, and exit state. Shard:
  `execplans/active/terminal-session-libghostty-vt.md`, Milestone 2.
- [x] Add Swift app state for one window, max nine tabs, stable tab/session IDs,
  session lifecycle, selection fallback, and final-tab replacement.
- [x] Add the frame-command model and deterministic software bitmap renderer.
- [x] Add the AppKit executable with one window, custom left sidebar, bitmap
  terminal view, fixed JetBrains Mono, fixed Selenized Light, keyboard input,
  and basic copy/paste.
  - Added `Session.realShell()`, made AppModel/Session/Tab/AppError public.
  - New files: SidebarProducer (LabanCore), TerminalBitmapView, MainWindowController,
    AppDelegate, MenuCommands, TerminalInputView, SidebarView (LabanApp).
  - LABAN_SMOKE=1 exits 0 before session creation.
  - SidebarProducer has 10 unit tests; all 47 suite tests pass.
- [x] Add the `laban-agent` headless executable using the same app state and
  renderer.
- [x] Sharpen AppKit bitmap presentation by making renderer surfaces
  backing-scale aware before debug-server screenshots become a baseline.
  Shard: `execplans/active/appkit-backing-scale-text-crispness.md`.
- [x] Add the debug server phase 1 endpoints:
  `/debug/health`, `/debug/state`, `/debug/screenshot`, and `/debug/actions`.
- [x] Add debug server phase 2 endpoints:
  `/debug/sessions`, `/debug/render`, and `/debug/frame-commands`.
  Shard for both debug-server phases:
  `execplans/active/headless-debug-server.md`.
- [x] Add fixture sessions first, then controlled real-shell smoke tests.
- [x] Add stable run/check/test scripts and make `./scripts/check` include the
  new SwiftPM, schema, and E2E gates.
- [x] Produce and verify the local `.app` bundle.
- [x] Cut idle AppKit CPU by making terminal rendering damage-driven and
  coalescing terminal frame commands. Shard:
  `execplans/active/appkit-idle-cpu-render-budget.md`.
- [ ] Add mouse input and scrollback behavior.

## Decision Log

- Decision: Build the first implementation as a SwiftPM repository with
  targets named `LabanTerminalCore`, `LabanCore`, `LabanRenderer`,
  `LabanDebug`, `LabanApp`, and `LabanAgent`, with the executable product for
  `LabanAgent` named `laban-agent`.
  Rationale: The user explicitly selected SwiftPM. SwiftPM keeps target
  boundaries legible to agents, gives direct Swift/C interop, supports unit
  tests, and avoids early Xcode project churn. A small bundle script can create
  a local developer `.app` until production packaging matters.
  Date/Author: 2026-05-03 / Codex.

- Decision: Make the software renderer the first complete backend, and allow a
  constrained Metal skeleton when `LabanRenderer` is introduced.
  Rationale: The user explicitly selected software rendering as the strategic
  compromise for visible AppKit output, headless screenshots, and CI
  verification. A Metal skeleton still helps keep the backend seam honest if it
  is limited to clearing, consuming `rect` commands, counting/hashing command
  streams, and reporting skipped unsupported commands. CI gates the software
  backend; local smoke may exercise Metal.
  Date/Author: 2026-05-03 / Codex.

- Decision: Use libghostty-vt (Ghostty commit
  `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b`) instead of GhosttyKit v1.3.1
  for the terminal core.
  Rationale: GhosttyKit v1.3.1 requires a live NSView* in
  `ghostty_surface_config_s`; there is no headless constructor, making it
  unusable for a C terminal core that must run without a window. libghostty-vt
  at the specified commit is a standalone VT library—no GUI dependency—that
  parses VT sequences, maintains a terminal grid, and exposes cell colors,
  cursor, and title through a C render-state API.
  Date/Author: 2026-05-03 / Codex.

- Decision: Keep terminal emulation, PTY ownership, terminal state, title,
  resize, output feeding, and input encoding inside the C
  `LabanTerminalCore` target.
  Rationale: `docs/product/mvp.md`,
  `docs/process/agent-operating-guide.md`, and the user directive all require
  Swift to see terminal snapshots rather than raw libghostty state. This
  protects session identity across tab selection, view rebuilds, resize, and
  UI refresh.
  Date/Author: 2026-05-03 / Codex.

- Decision: Do not implement a complete Metal backend, preferences, tab
  drag/drop, native scrollbars, accessibility polish, signing, notarization, or
  release packaging in this plan.
  Rationale: These are valid later features, but the MVP source of truth
  prioritizes a real terminal session, visible rendering, stable tabs,
  headless screenshots, and debug-state verification. The only Metal work
  allowed here is the limited skeleton owned by `LabanRenderer`; no
  app/sidebar/terminal code may draw outside frame commands.
  Date/Author: 2026-05-03 / Codex.

- Decision: Treat terminal output as hostile input and debug artifacts as
  sensitive local data.
  Rationale: Mature terminals gate or forbid terminal-initiated side effects
  because bytes printed by a remote program may be attacker-controlled. The MVP
  may accept bounded title updates, cell snapshots, cursor state, exit state,
  and terminal mode state from libghostty-vt, but it must not let terminal
  output trigger clipboard writes, file transfer, profile changes, app
  commands, debug-server access, window automation, or network sharing. Debug
  screenshots, logs, and state dumps may contain secrets, so they must remain
  local, opt-in, bounded, and written only under the requested artifact
  directory.
  Date/Author: 2026-05-03 / Codex.

- Decision: Preserve future structured-work and agent workflow hooks without
  adding shell integration or AI UI to the MVP.
  Rationale: Agent-oriented terminals benefit from stable work units, action
  logs, and shareable context, but the MVP explicitly defers shell integration
  markers and collaboration features. Stable tab/session IDs, bounded
  snapshots, debug actions, input logs, frame commands, and artifact manifests
  keep the path open for later command blocks or agent handoff without
  compromising the first terminal app.
  Date/Author: 2026-05-03 / Codex.

## Context and Orientation

The repository currently contains product and process contracts but no runnable
application. `./scripts/check` validates JSON syntax, keeps `AGENTS.md`
small, checks active ExecPlans for required sections, and runs
`git diff --check`.

Important source documents:

- `docs/product/mvp.md` is the current product boundary. It requires one macOS
  window, a vertical tab sidebar, one shell session per tab, create/select/close
  tab actions, title and exit state, resize, color output, fixed Selenized
  Light, bundled JetBrains Mono, keyboard input, mouse/scrollback behavior,
  selection/copy/paste, headless fixtures, screenshots, and a local `.app`.
- `docs/product/spec.md` describes later direction such as panes,
  multi-window restoration, persistence, shell integration, Kitty graphics, and
  richer accessibility. Those items are deferred unless required by the MVP.
- `docs/process/dev-process.md` makes the debug/headless harness product
  infrastructure. It requires local-only debug endpoints, headless mode,
  fixture mode, deterministic rendering, artifact capture, and E2E tests driven
  by `/debug/actions`.
- `docs/process/worktree-isolation.md` requires isolated artifact/temp
  directories, loopback debug ports, port `0` support, and a single
  machine-readable readiness line.
- `docs/process/observability.md` requires debug events, structured logs,
  basic metrics, and enough artifacts for agents to diagnose failures.
- `docs/reference/prototype-implementation-notes.md` records pitfalls:
  terminal sessions must outlive view rebuilds; PTYs must be used for
  interactive shells; terminal core encoders should own key/mouse encoding;
  native macOS text input must beat raw modifier interpretation; inherited
  `NO_COLOR` should not suppress interactive color; and stale C callback
  userdata must be avoided.
- `docs/adr/0001-libghostty-vt-owns-vt-parsing.md` records the terminal-core
  architecture: libghostty-vt owns VT parsing, `LabanTerminalCore` owns PTY and
  child process lifecycle, Swift sees owned snapshots only, and the
  libghostty-vt static archive is linked by full path.

Research-informed guardrails for the MVP:

- Terminal bytes are untrusted. Only bounded, explicitly modeled effects may
  cross from terminal output into app state: title, cells, cursor, modes,
  scrollback, exit status, and debug summaries. Clipboard writes, file transfer,
  profile mutation, app commands, debug-server access, network sharing, and
  terminal-driven window automation are out of scope.
- Accessibility polish is deferred, but the custom terminal viewport must not
  be an opaque bitmap forever. The first AppKit app milestone should leave an
  explicit path for visible text, selection, cursor position, tab labels, and
  exited state to be exposed through AppKit accessibility.
- Debug artifacts are sensitive. Headless screenshots, terminal logs, input
  logs, render traces, and state dumps stay local, opt-in, bounded, and under
  isolated artifact directories. Any future sharing or collaboration feature
  needs its own plan and privacy review.
- Shell integration and command blocks are deferred. Do not inject OSC 133 or
  shell wrappers in the MVP. Keep stable session IDs, action logs, frame
  commands, and bounded snapshots so later structured work units can be added
  without replacing the terminal core.
- Keep terminfo conservative. Use `TERM=xterm-256color` unless the app installs
  and manages a Laban-specific terminfo entry. Advertise truecolor separately.

Definitions used in this plan:

- SwiftPM means Swift Package Manager. It owns `Package.swift`, target
  dependency declarations, builds, and tests.
- AppKit means Apple's native macOS UI framework. `LabanApp` uses AppKit for
  the visible window, menus, keyboard input, clipboard, and custom views.
- libghostty means the Ghostty terminal engine library. It must own terminal
  parsing/state through the C core. The implementation must pin a concrete
  source version before writing production integration code.
- PTY means pseudo-terminal. It is the OS interface that makes a child process
  behave like it is attached to a real terminal instead of plain pipes.
- Terminal session means the C-owned object that contains a PTY, child process
  identity, libghostty state, terminal render state, input encoders, scrollback,
  title, and exit status.
- Snapshot means a bounded, owned copy of terminal state returned from C to
  Swift: rows, columns, cells, cursor, title, status, mouse/focus mode, and
  dirty state. Swift must not hold raw libghostty pointers.
- Frame command means a backend-neutral drawing instruction such as `rect`,
  `glyphRun`, `cursor`, `selection`, `clip`, or `texturedQuad`. App state and
  terminal snapshots produce frame commands. Renderers consume them.
- Software renderer means a CPU renderer that draws frame commands into an
  in-memory bitmap and can encode that bitmap as PNG. The same renderer is
  used by AppKit presentation and headless screenshots.
- Headless mode means running without a visible OS window while still creating
  sessions, advancing frames, rendering offscreen, serving debug endpoints, and
  writing artifacts.

## Target Shape

Create this SwiftPM layout:

```text
Package.swift
Sources/
  LabanTerminalCore/
    include/LabanTerminalCore.h
    session.c
    pty_macos.c
    libghostty_bridge.c
  LabanCore/
    AppModel.swift
    TabModel.swift
    SessionStore.swift
    TerminalSnapshot.swift
    FrameProducer.swift
    FixtureRunner.swift
  LabanRenderer/
    FrameCommand.swift
    SoftwareRenderer.swift
    BitmapSurface.swift
    PNGEncoder.swift
    Theme.swift
    FontAtlas.swift
  LabanDebug/
    DebugServer.swift
    DebugRoutes.swift
    DebugSchemas.swift
    ArtifactStore.swift
  LabanApp/
    main.swift
    AppDelegate.swift
    MainWindowController.swift
    SidebarView.swift
    TerminalBitmapView.swift
    TerminalInputView.swift
    MenuCommands.swift
  LabanAgent/
    main.swift
Tests/
  LabanCoreTests/
  LabanRendererTests/
  LabanDebugTests/
  LabanTerminalCoreTests/
  LabanE2ETests/
scripts/
  build-app
  run
  run-debug
  run-headless
  test
  test-e2e
  check
```

`Package.swift` should expose these products:

```swift
.library(name: "LabanCore", targets: ["LabanCore"])
.library(name: "LabanRenderer", targets: ["LabanRenderer"])
.library(name: "LabanDebug", targets: ["LabanDebug"])
.executable(name: "LabanApp", targets: ["LabanApp"])
.executable(name: "laban-agent", targets: ["LabanAgent"])
```

Use a C target named `LabanTerminalCore` with public headers under
`Sources/LabanTerminalCore/include`. Swift targets import only this C module,
not libghostty headers directly.

The dependency direction is:

```text
LabanTerminalCore
LabanRenderer
LabanCore -> LabanTerminalCore, LabanRenderer
LabanDebug -> LabanCore, LabanRenderer
LabanApp -> LabanCore, LabanRenderer, LabanDebug
LabanAgent -> LabanCore, LabanRenderer, LabanDebug
```

## Plan of Work

### Milestone 1: Pin libghostty and create the SwiftPM skeleton

First, prove that this repo can build Swift and C together and that a pinned
libghostty source or binary can be included from the C target. Do not write a
hand-rolled VT parser as a substitute for libghostty.

Implementation steps:

1. Add `Package.swift` with the targets and products listed in Target Shape.
2. Add empty or minimal source files for each target so `swift build` can
   compile.
3. Pin libghostty in a repeatable way. Acceptable first choices are:
   a checked-out git submodule under `External/libghostty`, a script that
   clones a commit into `.external/libghostty`, or a checked-in note plus build
   script if the source is too large to vendor immediately. The chosen path
   must include the exact commit or release identifier.
4. Inspect libghostty's current C API from the pinned source. Update this
   ExecPlan with the exact header paths, initialization calls, render-state
   access pattern, key/mouse encoder access pattern, and link command before
   implementing the full bridge.
5. Add the first C bridge smoke function, for example
   `laban_terminal_core_version`, so a Swift test proves Swift can call C and
   the C target can link.
6. Add `scripts/build-app` to run `swift build --product LabanApp` and create a
   developer-only bundle at `.build/laban/Laban.app`. The bundle needs
   `Contents/Info.plist`, `Contents/MacOS/LabanApp`, and resource directories,
   but it does not need signing, notarization, icons, or release packaging.

Acceptance for this milestone:

- From the repo root, `swift build` exits 0.
- From the repo root, `swift test` exits 0 with at least one Swift-to-C smoke
  test.
- From the repo root, `./scripts/build-app` creates
  `.build/laban/Laban.app/Contents/MacOS/LabanApp`.
- This ExecPlan names the exact libghostty source/version and bridge headers
  discovered.

### Milestone 2: Implement C-owned terminal sessions

Implement the narrow C ABI. Swift may create sessions, poll sessions, resize
sessions, write input bytes, destroy sessions, and request snapshots. Swift
must not own PTY file descriptors, child process cleanup, libghostty state, or
terminal encoders directly.

The public header should expose opaque handles and owned snapshots, using names
close to these. Adjust only where the pinned libghostty API requires it, and
record the change in the Decision Log.

```c
typedef struct LabanSession LabanSession;

typedef struct {
  const char *executable;
  const char *const *argv;
  const char *const *envp;
  const char *cwd;
  int fixture_mode;
} LabanLaunchConfig;

typedef struct {
  int rows;
  int cols;
  int pixel_width;
  int pixel_height;
  int cell_width;
  int cell_height;
} LabanTerminalSize;

typedef struct {
  uint32_t codepoint;
  uint32_t utf8_offset;
  uint32_t utf8_length;
  uint32_t foreground_rgba;
  uint32_t background_rgba;
  uint16_t flags;
} LabanCell;

typedef struct {
  int rows;
  int cols;
  int cursor_row;
  int cursor_col;
  int cursor_visible;
  int status;
  int exit_status;
  int mouse_tracking;
  int focus_reporting;
  int dirty;
  const char *title;
  const char *utf8_storage;
  size_t utf8_storage_len;
  const LabanCell *cells;
  size_t cell_count;
} LabanSnapshot;
```

Required functions:

```c
int laban_session_create(
  const LabanLaunchConfig *config,
  LabanTerminalSize initial_size,
  LabanSession **out_session
);

void laban_session_destroy(LabanSession *session);
int laban_session_poll(LabanSession *session);
int laban_session_resize(LabanSession *session, LabanTerminalSize size);
int laban_session_write(LabanSession *session, const uint8_t *bytes, size_t len);
int laban_session_snapshot(LabanSession *session, LabanSnapshot **out_snapshot);
void laban_snapshot_destroy(LabanSnapshot *snapshot);
```

Behavior requirements:

- `codepoint` is only a single-codepoint fast path for simple cells.
  `utf8_offset` and `utf8_length` point into `utf8_storage` for the full
  UTF-8 grapheme cluster to draw in that cell. The first skeleton may smoke
  test ASCII or box-drawing with the fast path, but this milestone is not
  complete until snapshots can carry a UTF-8 cluster without changing cell
  metrics.
- Session creation is all-or-nothing. If PTY creation, child spawn, libghostty
  initialization, encoder setup, or snapshot state creation fails, free partial
  resources and leave Swift app state unchanged.
- Interactive shell resolution follows `docs/product/mvp.md`: explicit config,
  `$SHELL`, platform account shell, then a known-safe system shell.
- Real-shell smoke mode uses a sanitized fixed shell/command and does not
  depend on user dotfiles or prompt state.
- Apply initial rows, columns, and pixel size before the shell starts
  interactive work.
- Use nonblocking PTY reads and a simple `poll` call from the frame loop. Do
  not add a complicated threading model in this milestone.
- Resize updates both libghostty state and the PTY window size. Every live
  session receives resize, including background tabs.
- EOF and platform closed-PTY errors mark the session exited and preserve an
  exit status when the OS provides one.
- Title bytes from terminal output are copied into bounded or owned storage.
- C cleanup must be safe for partially initialized sessions.

Acceptance for this milestone:

- Unit/core tests can create a fixture session, poll it, snapshot visible cells,
  resize it, and destroy it without leaks or stale references.
- A controlled real-shell smoke test can run a fixed command such as
  `/bin/sh -lc "printf 'ok\n'"`, poll until exit, and observe `ok` in the
  snapshot plus an exited status.
- A forced spawn failure leaves an existing Swift `SessionStore` unchanged.

### Milestone 3: Add Swift app state and stable tabs

Implement `LabanCore` as the authoritative Swift state for one window. It owns
tab ordering, active tab ID, session handles, fixture state, clipboard/debug
summaries, and frame advancement. It does not parse terminal escape sequences.

Required model:

- `Tab.ID` and `Session.ID` are stable strings. They do not change when titles
  change.
- A tab stores `id`, one-based display position, title, status, active flag,
  and `sessionId`.
- `AppModel` starts with one tab and one session.
- Creating a tab creates a new session and selects it atomically.
- Closing a tab tears down only that tab's session.
- Closing the final tab immediately creates a replacement tab; selection never
  points at freed state.
- The tab limit is nine. Attempts to create a tenth tab return a bounded error
  and leave state unchanged.
- Selecting a tab switches visible state only. It must not restart, resize
  incorrectly, or recreate hidden sessions.
- Resize updates all live sessions and recomputes rows/columns from fixed cell
  metrics and viewport size.

Acceptance for this milestone:

- Unit tests cover create/select/close tab, max-nine enforcement,
  final-tab replacement, selection fallback, title update without identity
  change, and resize for background sessions.
- Tests prove stale session handles are not used after tab close.

### Milestone 4: Add frame commands, the software backend, and the Metal skeleton

Implement `LabanRenderer` around a backend-neutral command stream. The command
language must support at least these command kinds from day one:

- `rect`
- `glyphRun`
- `cursor`
- `selection`
- `clip`
- `texturedQuad`

The software backend is the first complete backend. It draws into an RGBA
bitmap surface and can return a `CGImage` for AppKit and PNG bytes for
headless mode. Use fixed Selenized Light colors and bundled JetBrains Mono. If
the font file is not yet bundled, add it before marking this milestone
complete; do not silently rely on a developer's installed font.

Add a Metal skeleton when `LabanRenderer` is introduced. The skeleton may only:

- clear a render surface
- consume `rect` frame commands
- count and hash the command stream it received
- report skipped unsupported commands without pretending they were drawn

The Metal skeleton is not a complete backend, is not the CI gate, and must not
be used as an excuse to bypass software-renderer screenshots. CI gates the
software backend. Local smoke tests may exercise the Metal skeleton.

No app, sidebar, terminal, selection, or cursor code may draw directly through
AppKit, CoreGraphics, CoreText, Metal, or any other backend-specific API
outside the frame-command renderer path. Those producers create frame commands;
backends consume frame commands.

Frame-command producers:

- Sidebar chrome and tab rows produce `rect` and `glyphRun` commands tagged
  with source `sidebar` or `chrome`.
- Terminal snapshots produce background `rect`, text `glyphRun`, and `cursor`
  commands tagged with source `terminal` or `cursor`.
- Selection produces `selection` or `rect` commands tagged with source
  `selection`.
- Future images use `texturedQuad` with `resourceId`; Kitty graphics are
  deferred, but the command shape must exist.

Acceptance for this milestone:

- Renderer unit tests draw colored rectangles and glyph runs into a bitmap and
  assert non-background pixels.
- Renderer tests include a large-output or large-grid smoke case that records
  command count and render timing as diagnostic output. This is not a benchmark
  gate, but it prevents declaring the renderer viable from tiny screenshots
  alone.
- Metal skeleton tests clear a surface, consume a `rect` command, count/hash
  the command stream, and report unsupported `glyphRun`, `cursor`,
  `selection`, and `texturedQuad` commands as skipped.
- A fixture using `fixtures/colored-boxes.fixture.json` produces frame commands
  containing `hello mvp`, box-drawing glyphs, and non-monochrome colors.
- PNG encoding writes a valid PNG from the software surface.
- `/debug/frame-commands` can later serialize the command list without needing
  renderer internals.

### Milestone 5: Add the AppKit app

Implement `LabanApp` as one AppKit window with a custom left sidebar and a
bitmap terminal viewport. The view presents the exact bitmap produced by the
software renderer. Do not build a complete Metal backend, preferences, native
tab controls, tab drag/drop, real scrollbars, signing, or packaging. Any Metal
skeleton code must remain inside `LabanRenderer`; AppKit/sidebar/terminal code
must still draw only by producing frame commands.

Required UI behavior:

- One window opens with one selected tab.
- Sidebar has a new-tab affordance and one row per tab.
- Each tab row shows a stable one-based position, bounded title, status, and
  close affordance.
- Clicking sidebar rows selects tabs. Clicking a close affordance closes that
  tab. Sidebar pointer input is consumed by the sidebar and is not sent to the
  active terminal.
- Terminal viewport shows the software-rendered bitmap.
- Fixed JetBrains Mono and fixed Selenized Light are used.
- Native macOS menus include app, tab, and edit commands for new tab, close
  tab, numbered tab selection for tabs one through nine, copy, and paste.
- Application shortcuts are handled before terminal input and consume any text
  generated by the shortcut.
- Terminal text input uses AppKit's native text input path. Implement the
  terminal input view as an `NSTextInputClient` or equivalent AppKit-native
  text input receiver so layout-specific characters produced by Option chords
  are delivered as text rather than accidental Alt-modified key chords.
- Paste reads text from the macOS clipboard and writes it to the active
  terminal. Paste is text-only. If the active snapshot exposes bracketed paste
  mode later, wrap paste then; otherwise write plain text. Do not implement
  terminal-initiated clipboard read/write behavior, including OSC 52, in this
  plan.
- Basic visible-text selection and copy are implemented using visible terminal
  snapshot cells. It may be linear. It does not need semantic word expansion,
  search, or alternate-screen special behavior.
- Wheel input scrolls scrollback when terminal mouse tracking is inactive and
  is sent to the terminal core when mouse tracking is active. No native
  draggable scrollbar is required in this plan.
- The custom terminal view keeps enough model information to expose visible
  text, selected text, cursor position, tab labels, and process-exited state to
  AppKit accessibility in a follow-up without reverse-reading pixels. The full
  accessibility pass remains outside this milestone.

Acceptance for this milestone:

- Running `.build/laban/Laban.app/Contents/MacOS/LabanApp` opens one AppKit
  window.
- The window visibly displays shell output.
- Typing into the window reaches the PTY exactly once.
- An AppKit input test or debug trace proves an Option-produced character is
  delivered as text and a handled Command shortcut is not delivered to the PTY.
- Creating, selecting, and closing sidebar tabs does not restart hidden
  sessions.
- Copy/paste work for visible selected text and text clipboard contents.
- Mouse-routing checks prove sidebar clicks do not reach the PTY, local
  selection is suppressed when terminal mouse tracking is active, and wheel
  input scrolls scrollback when mouse tracking is inactive.

### Milestone 6: Add the headless harness and debug server

Implement `LabanAgent` as the headless executable product named
`laban-agent`. It must use the same `LabanCore`, frame-command producers, and
software renderer as `LabanApp`. It must not use a separate model-to-image
path.

Run modes:

```sh
.build/debug/laban-agent --headless --debug-server=127.0.0.1:0 \
  --artifacts=.artifacts/runs/<run-id> --temp-dir=.tmp/<run-id> \
  --deterministic

.build/debug/laban-agent --headless --fixture=fixtures/colored-boxes.fixture.json \
  --debug-server=127.0.0.1:0 --artifacts=.artifacts/runs/<run-id> \
  --temp-dir=.tmp/<run-id> --deterministic
```

When the debug server is enabled, stdout must print exactly one
machine-readable readiness line:

```json
{"debugServer":"http://127.0.0.1:49321","pid":12345,"runId":"abc123"}
```

Bind the server only to loopback. Use port `0` by default in scripts and tests.
Keep generated files under the requested artifact and temp directories.
Debug output may include secrets from the terminal. Do not write artifacts
outside the requested artifact directory, do not upload or share artifacts, and
bound terminal buffers, input logs, render traces, errors, and screenshots.

Phase 1 endpoints:

- `GET /debug/health` returns readiness with `ok`, `mode`, `frame`, and
  `focused`.
- `GET /debug/state` returns JSON matching `schemas/debug/state.schema.json`.
- `GET /debug/screenshot` returns a PNG of the current rendered surface.
- `POST /debug/screenshot` writes a PNG artifact and returns JSON matching
  `schemas/debug/screenshot-result.schema.json`.
- `POST /debug/actions` accepts the actions in
  `schemas/debug/action.schema.json` and returns
  `schemas/debug/action-result.schema.json`.

Phase 2 endpoints:

- `GET /debug/sessions` returns `schemas/debug/sessions.schema.json`.
- `GET /debug/render` returns `schemas/debug/render.schema.json`.
- `GET /debug/frame-commands` returns
  `schemas/debug/frame-commands.schema.json`.
- `POST /debug/render-trace` returns
  `schemas/debug/render-trace.schema.json`. The first implementation may be a
  minimal trace summary that records the current frame, surface, layout,
  command ranges, commands, render pass, resources known to the software
  renderer, requested pixel probes, and invariant results. Deep pixel
  provenance can come later, but the endpoint must exist unless
  `docs/process/dev-process.md` and the schemas are explicitly amended.

Add `/debug/wait` before relying on E2E tests so tests do not sleep
arbitrarily. Add `/debug/events`, `/debug/input-log`, `/debug/terminal-log`,
`/debug/errors`, `/debug/fixture`, and `/debug/snapshot` as soon as the
corresponding state exists. Enrich `/debug/render-trace` later, when rendering
bugs need pixel provenance beyond frame-command dumps.

Acceptance for this milestone:

- Headless mode starts without a visible OS window.
- `GET /debug/health` returns HTTP 200 after the readiness line.
- `POST /debug/actions` can create a tab, type text, advance frames, and resize
  the window.
- `GET /debug/state` shows stable tab/session IDs and correct active IDs.
- `GET /debug/screenshot` returns a non-empty PNG generated from the software
  renderer.
- `GET /debug/sessions`, `/debug/render`, and `/debug/frame-commands` expose
  bounded diagnostic state matching the checked-in schemas.
- `POST /debug/render-trace` returns a bounded schema-compatible trace summary,
  even if deep per-pixel contributor provenance is still sparse.
- Artifact output is local-only, opt-in through the run command, bounded, and
  isolated under the run-specific artifact directory. A failed run records
  enough state for diagnosis without writing outside that directory.

### Milestone 7: Add tests, scripts, and the local CI gate

Fixture sessions are the first gate. Controlled real-shell smoke tests are the
second gate. Do not depend on the user's shell prompt, dotfiles, network,
wall-clock timing, or installed terminal theme.

Add scripts with stable meanings:

```sh
./scripts/run
./scripts/run-debug
./scripts/run-headless
./scripts/test
./scripts/test-e2e
./scripts/check
```

`./scripts/check` must continue to validate JSON under `schemas/` and
`fixtures/`, enforce `AGENTS.md` size, ensure active ExecPlans have required
sections, and run `git diff --check`. Extend it to run Swift formatting or
linting if added, `swift test`, and the MVP headless E2E gate once those tests
exist.

The first E2E gate must:

1. Launch `laban-agent` headlessly with a unique run ID, debug port `0`,
   deterministic mode, and isolated artifact/temp directories.
2. Parse the readiness line for the selected debug server URL.
3. Wait for `/debug/health`.
4. Create a second tab through `/debug/actions`.
5. Type text through `/debug/actions`.
6. Advance frames or wait for visible text through `/debug/wait`.
7. Capture `/debug/screenshot`.
8. Inspect `/debug/state`, `/debug/sessions`, `/debug/render`, and
   `/debug/frame-commands`.
9. Assert the screenshot is non-empty, state has the expected active tab and
   session, typed text appears exactly once, and frame commands contain
   terminal glyph output.
10. Stop the launched process. Preserve artifacts on failure.
11. Verify terminal-output safety fixtures: terminal output can update a
    bounded title, but cannot trigger clipboard writes, file transfer, app
    commands, debug-server requests, or artifact writes outside the run
    directory.
12. Verify input and mouse fixtures: Option-produced text reaches the PTY as
    text, handled Command shortcuts do not leak to the PTY, sidebar clicks are
    consumed by the sidebar, and mouse tracking changes wheel routing.

Acceptance for this milestone:

- `./scripts/test` exits 0.
- `./scripts/test-e2e` exits 0 on macOS.
- `./scripts/check` exits 0.
- A failed E2E run writes an artifact directory containing at least final
  state, sessions, render state, frame commands, events/errors when available,
  screenshot metadata, stdout, stderr, and a manifest matching
  `schemas/artifact-manifest.schema.json`.
- Fixture coverage includes colors, box drawing, resize, title bounding, exit
  state, text-only paste, terminal mouse tracking, scrollback, app shortcut
  consumption, and terminal-output side-effect denial.

## Concrete Steps

Start from the repo root:

```sh
cd /Users/rrj/wrk/laban
```

Before editing implementation files, verify the current baseline:

```sh
./scripts/check
```

Add the SwiftPM skeleton and run:

```sh
swift build
swift test
./scripts/build-app
```

During headless/debug work, use isolated run directories:

```sh
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
./scripts/run-headless --debug-server=127.0.0.1:0 \
  --artifacts=".artifacts/runs/$run_id" \
  --temp-dir=".tmp/$run_id" \
  --deterministic
```

Expected readiness output shape:

```json
{"debugServer":"http://127.0.0.1:49321","pid":12345,"runId":"20260503T120000Z-12345"}
```

After implementing the debug server, a smoke sequence should be possible with
the selected URL:

```sh
curl -fsS "$debug_url/debug/health"
curl -fsS "$debug_url/debug/state"
curl -fsS -X POST "$debug_url/debug/actions" \
  -H 'Content-Type: application/json' \
  -d '{"action":"newTab"}'
curl -fsS -X POST "$debug_url/debug/actions" \
  -H 'Content-Type: application/json' \
  -d '{"action":"typeText","text":"printf '\''hello mvp\\n'\''\\n"}'
curl -fsS "$debug_url/debug/screenshot" > "$artifact_dir/screenshots/smoke.png"
```

Do not commit generated `.build/`, `.tmp/`, or `.artifacts/` contents unless a
specific fixture or golden file is intentionally added.

## Validation and Acceptance

This ExecPlan is complete only when all of these are true:

- `Package.swift` defines the target graph in Target Shape.
- `swift build` exits 0 on macOS.
- `swift test` exits 0 on macOS.
- `./scripts/build-app` produces a local developer `.app` at
  `.build/laban/Laban.app`.
- Launching the local `.app` opens one AppKit window with a custom left
  sidebar and visible terminal text.
- One libghostty-backed real shell can be created, resized, typed into, and
  closed.
- Creating and switching tabs preserves session identity. Hidden sessions are
  not restarted by selection, view rebuild, resize, or UI refresh.
- The software renderer draws sidebar and terminal frame commands into the
  bitmap shown by AppKit.
- `laban-agent` can run headlessly with the same app state and renderer.
- `/debug/health`, `/debug/state`, `/debug/screenshot`, `/debug/actions`,
  `/debug/sessions`, `/debug/render`, `/debug/frame-commands`, and
  `/debug/render-trace` work on loopback and return bounded responses matching
  the checked-in schemas where schemas exist.
- The headless fixture gate using `fixtures/colored-boxes.fixture.json`
  produces a non-empty screenshot, visible `hello mvp`, non-monochrome color,
  and box-drawing glyphs without replacement glyphs.
- A controlled real-shell smoke test runs without user dotfiles or prompt
  assumptions.
- Terminal-output safety is enforced: hostile terminal bytes cannot trigger
  clipboard writes, file transfer, profile changes, app commands, debug-server
  requests, network sharing, or writes outside the run artifact directory.
- Native macOS input behavior is verified: application shortcuts are consumed
  before terminal input, Option-produced text is delivered as text, and no
  hand-written terminal key escape table bypasses libghostty-vt state.
- Mouse routing is verified: sidebar pointer input is consumed by the sidebar,
  terminal mouse tracking routes events to the terminal app, and normal-mode
  wheel input scrolls scrollback.
- The first AppKit terminal view keeps model access for visible text,
  selection, cursor position, tab labels, and process-exited state so platform
  accessibility can be added without reverse-engineering rendered pixels.
- Debug and headless artifacts are local-only, opt-in, bounded, isolated per
  run, and treated as sensitive.
- `./scripts/test-e2e` launches headless, creates a tab, types text, renders a
  screenshot, and inspects state.
- `./scripts/check` exits 0.

## Idempotence and Recovery

All generated build, artifact, and temp output must stay under `.build/`,
`.artifacts/runs/<run-id>/`, and `.tmp/<run-id>/`. It is safe to delete those
directories and rerun scripts.

If libghostty cannot be fetched or built, stop after Milestone 1, add a
`Surprises & Discoveries` entry with the exact failure, and do not replace
libghostty with a hand-rolled parser. A temporary fixture-only app state may
exist only to verify SwiftPM, AppKit, renderer, or debug plumbing, and it must
be clearly marked as scaffolding that cannot satisfy terminal-core acceptance.

If an AppKit interactive run fails but headless mode works, preserve the
headless artifacts and add a focused AppKit reproduction before changing the
shared renderer or app state. If headless screenshots are blank, inspect
`/debug/render` and `/debug/frame-commands` before adding render trace.

If a test leaves a process running, stop it before finishing the turn. Preserve
artifacts on failure and clean temp directories on success.

## Interfaces and Dependencies

Do not add third-party Swift dependencies for the first debug server or
renderer unless the no-dependency path blocks measurable progress. Foundation,
AppKit, CoreGraphics, CoreText, ImageIO, and Network.framework are sufficient
for the first pass:

- AppKit: window, menus, clipboard, native text input, and bitmap view.
- CoreGraphics/CoreText: software text and rectangle drawing into a bitmap.
- ImageIO: PNG encoding for screenshots and artifacts.
- Network.framework: loopback HTTP listener for the debug server.
- Darwin/POSIX C APIs: PTY, child process, nonblocking I/O, window size, and
  signal/reap behavior.
- libghostty: terminal parsing/state, render state, terminal key encoder, and
  terminal mouse encoder.

The MVP environment defaults are conservative. The child shell should receive
`TERM=xterm-256color` and `COLORTERM=truecolor`; do not advertise a
Laban-specific terminal name unless the app also installs and manages matching
terminfo.

The C ABI must keep all libghostty and PTY ownership behind
`LabanTerminalCore.h`. Swift may hold opaque `LabanSession` pointers only
through a Swift wrapper that guarantees destroy-on-close and prevents use after
tab teardown.

Frame commands must remain renderer-backend neutral. Do not make AppKit views
or debug endpoints depend on private software-renderer or Metal internals. The
software backend is the first complete backend. The Metal skeleton consumes the
same command list, reports unsupported commands as skipped, and may be covered
by local smoke tests, but CI acceptance comes from the software backend.

## Automated Acceptance Gate

These are mechanical checks for a fresh agent or automation runner. They are
not a human review loop. The umbrella plan is complete only when each check can
be run from a clean working tree and produce the expected result.

- [ ] Run `./scripts/check` from `/Users/rrj/wrk/laban`; expect exit 0.
- [ ] Run `swift test` from `/Users/rrj/wrk/laban`; expect exit 0.
- [ ] Run `./scripts/build-app`; expect
  `.build/laban/Laban.app/Contents/MacOS/LabanApp` to exist and be executable.
- [ ] Run `./scripts/test-e2e`; expect exit 0 and a preserved or reported run
  artifact directory.
- [ ] Grep Swift files outside `Sources/LabanTerminalCore` for `ghostty`;
  expect zero direct libghostty imports or symbol references outside the C
  boundary.
- [ ] Launch headless with `--debug-server=127.0.0.1:0`; expect one readiness
  JSON line containing `debugServer`, `pid`, and `runId`.
- [ ] Query `/debug/state`; validate it against
  `schemas/debug/state.schema.json` and verify it contains one active tab and
  one active session on startup.
- [ ] Post `{"action":"newTab"}` to `/debug/actions`; then query
  `/debug/state` and verify there are two tabs, active tab is the new tab, and
  session IDs are distinct.
- [ ] Query `/debug/screenshot`; verify response `Content-Type` is `image/png`
  and the body is non-empty.
- [ ] Query `/debug/frame-commands`; validate it against
  `schemas/debug/frame-commands.schema.json` and verify at least one command
  has source `terminal`.
- [ ] Post a minimal render-trace request to `/debug/render-trace`; validate
  the response against `schemas/debug/render-trace.schema.json`.
- [ ] Run the terminal-output safety fixture; expect bounded title updates to
  work and expect terminal output not to trigger clipboard writes, app
  commands, debug-server requests, file transfer, or artifact writes outside
  the run directory.
- [ ] Run the AppKit input fixture or debug trace; expect an Option-produced
  character to reach the PTY as text and a handled Command shortcut to produce
  no PTY input.
- [ ] Run the mouse-routing fixture; expect sidebar clicks to be consumed,
  terminal mouse tracking to route wheel events to the terminal app, and
  normal-mode wheel input to scroll scrollback.
- [ ] Inspect the run artifact manifest; expect every generated file path to be
  under the run-specific artifact directory.

## Surprises & Discoveries

- Observation: This file is an umbrella plan, not the first execution shard.
  Evidence: The first shard is `execplans/active/swiftpm-libghostty-skeleton.md`
  and intentionally covers only SwiftPM scaffolding, the C smoke target,
  libghostty pin/probe, local `.app` bundling, and check-script integration.

- Observation: `CGBitmapContext` stores buffer row 0 at the TOP scanline, but
  CoreGraphics coordinates have y=0 at the BOTTOM (standard CG bottom-left origin).
  `BitmapSurface.pixel(x:y:)` must map CG y to buffer row using `(height - 1 - y)`,
  not `y` directly. The wrong formula caused spatial pixel-read tests to return stale
  zero values even after drawing; the whole-surface fill test passed by accident.
  `FrameProducer`'s row-to-y conversion `cellY = (rows-1-row)*ch` is correct because
  it produces high CG y values for top terminal rows, matching how CoreGraphics draws.

## Artifacts and Notes

The docs and schemas read while authoring this plan establish these constraints
that should not be weakened during implementation:

- `docs/product/mvp.md`: MVP behavior wins over long-term product scope.
- `docs/process/dev-process.md`: debug/headless is product infrastructure, not
  optional polish.
- `docs/process/worktree-isolation.md`: every runnable mode must support
  isolated artifacts/temp paths and debug port `0`.
- `docs/process/observability.md`: failures must leave enough bounded events,
  logs, state, render data, and screenshots for agent diagnosis.
- `docs/reference/prototype-implementation-notes.md`: preserve the proven
  session ownership, PTY, input, rendering, and cleanup lessons, but do not
  copy prototype architecture blindly.
- `schemas/debug/*.schema.json`: debug responses may add fields, but required
  fields and meanings must remain compatible unless the schema version changes.
