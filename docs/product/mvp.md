# Minimal Terminal Application MVP

> **Post-MVP — this is a regression contract, not a plan.** The MVP shipped
> 2026-05-17.
>
> - **Binding (do not break):** *Required Behavior* and *Quality Bar* describe
>   shipped behavior that must keep working.
> - **Historical (non-binding):** *Explicit Non-Goals*, *Suggested Work Order*,
>   and *Later Milestones* record what was deferred **for the MVP** — not what
>   is forbidden now. Those deferred items are the post-MVP roadmap; current and
>   future scope lives in `docs/product/spec.md`.

## Status

**Shipped on 2026-05-17.** Every requirement in this document is implemented
in the current tree and exercised by `./scripts/check`. This document is now
the regression contract: every behavior described here must continue to
work. New product scope goes through `docs/product/spec.md`; new
implementation work that strictly maintains MVP behavior (bug fixes, polish,
performance, refactors) does not need spec.md approval but must not break
anything required here.

This document defines an implementation-agnostic MVP for a macOS terminal
application based on the behavioral direction in `docs/product/spec.md`. It
intentionally does not prescribe programming language, macOS UI framework,
renderer, build system, or terminal-emulation library.

The product target is macOS. Cross-platform code is valuable when it supports
headless agent-driven development, reusable terminal-core behavior, fixtures,
or CI, but it must not turn the MVP into a generic cross-platform UI product.

## Goal

Ship the smallest credible macOS terminal app that proves the core product shape:
multiple terminal sessions organized by vertical tabs, with correct enough
interactive shell behavior to run real command-line tools.

The MVP should optimize for reliable terminal behavior over broad product
surface. It should be small enough for agents and humans to reason about
without hiding session lifecycle, input routing, or rendering policy behind
premature abstractions.

## User-Facing Scope

The first usable version has:

- one top-level macOS window
- a vertical tab sidebar
- one active terminal viewport
- one independent shell session per tab
- create tab, close tab, and select tab actions
- terminal title reflected in the tab and window UI
- process-exited state visible to the user
- resize behavior that keeps terminal rows/columns correct
- keyboard input suitable for real shell and TUI usage
- mouse scrollback and terminal mouse reporting
- color terminal output
- enough glyph coverage for common TUI borders and symbols
- terminal text selection, copy, and paste with full clipboard support
- drag-and-drop file and screenshot paths into the active terminal
- minimal native macOS menus for tab and edit commands
- fixed Selenized Light theme
- bundled JetBrains Mono font

## Explicit Non-Goals

The MVP does not include:

- split panes
- multiple windows
- workspace persistence
- recently closed workspaces
- saved library workspaces
- browser panes
- shell integration markers
- full settings UI
- themes beyond Selenized Light
- dark-mode adaptation
- font preferences
- ligatures or complex font shaping
- Kitty graphics display
- tab drag reordering
- close confirmation for running processes
- plugin systems
- collaboration features
- cloud sync
- automated update channels
- notarized release packaging

These are valid later product requirements, but they should not block the MVP.

## Core Concepts

### Window

The MVP has one macOS window. The window owns tab ordering, selected tab
identity, application commands, and global focus routing for the visible
terminal area. The model should still use window-scoped ownership names so
multi-window support remains feasible later.

### Tab

A tab is app-level state. It has a stable ID, title, status, and a reference to
one terminal session. Tab identity does not change when the terminal title
changes.

### Terminal Session

A terminal session owns process lifetime and terminal state. It owns the pty,
child process identity, terminal parser/state, render snapshot state, input
encoders, scrollback state, title state, and exit status.

Views may display a session but must not accidentally restart or destroy it
because the UI was rebuilt, resized, reordered, or hidden.

The MVP terminal core uses libghostty through a narrow C ABI. The first core
implementation should be C using libghostty's C API. Swift/AppKit owns app UI
and lifecycle; it must not own raw libghostty state. Zig remains available for
libghostty's build and for future justified core internals, but not as the
default MVP core language.

## Implementation Shape

The product shell is AppKit-first. The terminal viewport, sidebar, input
routing, menus, and window behavior should be implemented with native macOS
control. SwiftUI may be used later for non-critical preferences or panels, but
it is not required for the MVP and must not own the terminal surface.

The app uses a custom explicit vertical sidebar model, layout, hit testing, and
rendering. Native tab controls must not own tab state.

Rendering uses a unified frame-command system. Separate producers create frame
commands for sidebar chrome, terminal grid, selection, cursor, and future
images. Shared Metal and software/offscreen backends consume the same command
language. The frame-command list is extracted each frame from authoritative app
and terminal state. Renderer-owned resources such as glyph atlases, texture
caches, pipelines, and buffers may be retained, but no retained scene graph may
be the source of truth.

Metal is the preferred production-facing macOS backend. A deterministic
software/offscreen backend is required for autonomous tests. The renderer
command language must support textured quads and resource IDs from day one so
future Kitty graphics can plug in without redesigning the renderer.

## Required Behavior

### Session Creation

Creating a tab creates one new terminal session and selects it. Session creation
is all-or-nothing: if any required resource fails to initialize, the app leaves
existing tabs and selection unchanged.

Interactive mode shell launch resolves in this order:

1. explicit user/app configuration, if present
2. environment shell
3. platform account shell
4. a known-safe system shell

The shell runs under a pseudo-terminal and receives an initial terminal size
before interactive use begins.

Headless real-shell smoke tests use a sanitized fixed shell/command instead of
the user's login shell or dotfiles.

### Session Teardown

Closing a tab immediately tears down its terminal session. The MVP does not ask
for close confirmation. Teardown closes the pty, signals a still-running child
as a normal terminal disconnect, reaps the child where the platform requires
it, and releases terminal resources.

Closing the final tab closes the window, which quits the app; the MVP does not
create a replacement tab. This is the deliberate final-tab policy `spec.md`
permits, not an oversight. Selection must never point at freed state: the tab
list is emptied before the window closes.

### Tab Sidebar

The sidebar shows a new-tab affordance and one row per tab. Each row shows a
stable one-based position as a quiet fixed gutter, a title, and a close
affordance.

Clicking a tab row selects it. Clicking its close affordance closes that tab.
Clicking the new-tab affordance creates and selects a new tab.

Pointer input inside the sidebar is consumed by the sidebar and is not sent to
the active terminal session.

Titles are constrained so a long title cannot overlap controls or resize the
sidebar unexpectedly.

Tab order is stable by creation order. Drag reordering is deferred, but the tab
model should not prevent adding reorder later.

### Keyboard Input

Application shortcuts are handled before terminal input. The MVP requires:

- create tab
- close active tab
- select tab by number for the visible tab range
- copy selected terminal text
- paste macOS clipboard contents into the active terminal
- drop local files or screenshots into the active terminal as shell-quoted paths

Handled application shortcuts consume both the key event and any text generated
by that key event.

Terminal key input uses the terminal core's key encoding rules rather than
hand-written escape tables when an encoder is available. Encoder state is
synchronized from current terminal modes before encoding.

Native text input wins over raw modifier interpretation. If the platform text
system produces text, consumed modifiers are reported as consumed before the
event reaches terminal encoding. Layout-specific characters, including
Option-produced characters on macOS-style layouts, must be delivered as text
rather than as unintended modified key chords.

Paste reads from the macOS clipboard. Text paste uses the terminal core paste
path: if the active terminal has bracketed paste enabled and terminal state
exposes that mode, paste is wrapped in bracketed paste sequences; otherwise it
is written as plain text. Full clipboard support is part of the MVP; non-text
clipboard contents, terminal-initiated clipboard operations, and
foreground-application clipboard handoff paths must be handled through
supported terminal or macOS clipboard mechanisms rather than silently ignored.

File and screenshot drag-and-drop is part of the MVP. Dropping existing files
inserts shell-quoted local paths into the active terminal through the same
bracketed-paste-aware terminal input path as text paste. Dropped screenshot
thumbnails or raw images are first materialized into a Laban-owned local drop
cache, then inserted as paths. Sidebar drops are rejected and must not leak to
the terminal session.

Basic native menus are part of the MVP: app menu, tab commands, and edit
commands for copy and paste. Unhandled Command chords must not leak into
terminal input.

### Selection And Copy

The MVP requires primitive visible-text selection in the terminal viewport so
basic copy works. Selection may be linear or rectangular, whichever fits the
render snapshot most directly. Copy writes selected visible text to the macOS
clipboard.

Selection does not need semantic word/line expansion, scroll-drag extension,
alternate-screen special behavior, search integration, or rectangular selection
unless those are the simplest path. When terminal mouse tracking is active,
mouse events go to the terminal app rather than starting local text selection.

### Mouse And Scrollback

Mouse input in terminal content is delivered according to terminal mode.

If terminal mouse tracking is active, pointer and wheel events are encoded
through libghostty's mouse encoder for the terminal app. If mouse tracking is
not active, wheel events scroll scrollback. Holding Shift always scrolls Laban's
own scrollback, even while a fullscreen app holds the mouse — the universal
terminal escape hatch (iTerm2/Terminal.app/kitty).

Wheel/debug scrollback is required. A visible scroll indicator is preferred,
but a visible draggable scrollbar is optional for the first scaffold.

### Resize

When the window or terminal viewport size changes, every live session receives
updated rows, columns, and pixel dimensions. The pty window size is updated for
the child process.

Rows and columns are derived from measured cell size and available viewport
space. The terminal must always have at least one row and one column.

### Rendering

Rendering consumes terminal render state produced by the terminal core. The UI
does not parse terminal escape sequences itself.

The renderer must support:

- foreground and background colors
- 256-color and truecolor output when the terminal core provides it
- inverse video
- cursor visibility and cursor position
- bold and italic, either through real font faces or deterministic fallback
- UTF-8 grapheme rendering from terminal-provided codepoints
- scrollback viewport rendering
- textured quad render commands in the renderer abstraction, even though Kitty
  graphics display is deferred

The bundled font is JetBrains Mono. It must cover common terminal UI symbols:
box drawing, block elements, arrows, Braille patterns, geometric symbols,
dingbats, currency symbols, and common private-use terminal glyphs. The MVP
uses fixed-cell glyph atlas rendering with no ligatures or complex shaping.
Fallback must not change cell metrics.

The built-in theme is fixed Selenized Light. The MVP does not adapt to system
dark mode.

Software/headless rendering must be deterministic and behavior-equivalent to
the Metal backend, but it does not need to be pixel-identical. Tests should use
command-list equivalence, deterministic software goldens, and Metal semantic
smoke or pixel-probe checks.

### Environment

Interactive shells should receive terminal capability environment variables
that make common tools behave correctly.

The MVP should choose a broadly available `TERM` value unless it also installs
and manages a more specific terminfo entry. Truecolor support should be
advertised separately.

Automation-oriented environment inherited from the launcher must not silently
degrade interactive use. In particular, color suppression should not be passed
through unless configured by the user.

No shell integration wrappers or OSC 133 injection are required in the MVP.

### Titles And Exit State

Terminal title changes update the tab label and window title. Title updates do
not change tab identity, session identity, focus, or ordering.

Title data from terminal output is untrusted. It must be bounded or stored in
owned strings safely.

If a child process exits, the tab records that state. The active terminal view
shows a non-destructive exited indicator, including the exit status when known.

### Headless And Fixtures

Headless mode supports both fixture sessions and controlled real-shell smoke
sessions. Fixture sessions are the primary CI gate and feed deterministic
bytes/events at the terminal-core boundary while still using libghostty, app
state, the renderer pipeline, debug server, screenshots, and state
introspection. Real-shell smoke sessions use a sanitized fixed shell/command to
exercise PTY lifecycle without depending on user dotfiles or prompt state.

The debug protocol is app-level. The C terminal core must not own HTTP, JSON,
artifact, or debug-server concerns.

### Packaging

The MVP produces a local developer `.app` bundle. Production signing,
notarization, sandboxing, and auto-update are deferred.

macOS CI is required once implementation starts. Non-macOS CI is optional for
portable core, schema, fixture, or software-renderer tests when it falls out
naturally.

## Quality Bar

The MVP is acceptable when it can:

- open a shell
- run an interactive editor
- run a fullscreen TUI
- display colored CLI output
- display common TUI borders without fallback question marks
- use JetBrains Mono with fixed cell metrics
- render the built-in Selenized Light theme
- create and switch between multiple tabs without restarting sessions
- close tabs without leaving stale references
- resize without corrupting terminal layout
- type layout-specific characters correctly
- copy visible selected text, paste supported macOS clipboard contents, and
  drop files/screenshots as terminal paths
- scroll shell output when no app mouse tracking is active
- pass mouse events to terminal apps that request mouse tracking
- produce deterministic headless screenshots through the software renderer
- run controlled real-shell smoke tests without user shell configuration

## Suggested Work Order

1. Terminal session lifecycle: pty spawn, read/write, resize, exit state.
2. Render-state based terminal viewport.
3. Keyboard input and application shortcuts.
4. Vertical tab model and sidebar.
5. Frame-command renderer with Metal and software backend seams.
6. Mouse input and scrollback behavior.
7. Selection, copy, full clipboard paste support, and file/screenshot drops.
8. Title handling, environment defaults, theme, and glyph coverage.
9. Debug/headless fixtures and controlled shell smoke tests.
10. Cleanup paths and failure handling.

## Later Milestones

After the MVP is stable, extend toward `docs/product/spec.md` in this order:

1. split panes backed by stable session IDs
2. multi-window scene identity
3. window-scoped command publication
4. persistence and restoration
5. shell integration markers
6. Kitty graphics
7. draggable tab reordering
8. close confirmation for busy processes
9. richer accessibility
10. production packaging and release engineering
