# Minimal Terminal Application MVP

This document defines an implementation-agnostic MVP for a desktop terminal
application based on the behavioral direction in `docs/product/spec.md`. It
intentionally does not prescribe programming language, GUI framework, renderer,
build system, or terminal-emulation library.

## Goal

Ship the smallest credible terminal app that proves the core product shape:
multiple terminal sessions organized by vertical tabs, with correct enough
interactive shell behavior to run real command-line tools.

The MVP should optimize for reliable terminal behavior over broad product
surface. It should be small enough for agents and humans to reason about
without hiding session lifecycle, input routing, or rendering policy behind
premature abstractions.

## User-Facing Scope

The first usable version has:

- one top-level window
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
- themes beyond a built-in default
- plugin systems
- collaboration features
- cloud sync
- automated update channels
- notarized release packaging

These are valid later product requirements, but they should not block the MVP.

## Core Concepts

### Window

The MVP has one window. The window owns tab ordering, selected tab identity,
application commands, and global focus routing for the visible terminal area.

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

## Required Behavior

### Session Creation

Creating a tab creates one new terminal session and selects it. Session creation
is all-or-nothing: if any required resource fails to initialize, the app leaves
existing tabs and selection unchanged.

The shell launch configuration resolves in this order:

1. explicit user/app configuration, if present
2. environment shell
3. platform account shell
4. a known-safe system shell

The shell runs under a pseudo-terminal and receives an initial terminal size
before interactive use begins.

### Session Teardown

Closing a tab tears down its terminal session unless a later implementation
adds a deliberate grace/undo policy. Teardown closes the pty, signals a
still-running child as a normal terminal disconnect, reaps the child where the
platform requires it, and releases terminal resources.

Closing the final tab follows one explicit MVP policy: immediately create a
replacement tab. Selection must never point at freed state.

### Tab Sidebar

The sidebar shows a new-tab affordance and one row per tab. Each row shows a
stable one-based position, a title, and a close affordance.

Clicking a tab row selects it. Clicking its close affordance closes that tab.
Clicking the new-tab affordance creates and selects a new tab.

Pointer input inside the sidebar is consumed by the sidebar and is not sent to
the active terminal session.

Titles are constrained so a long title cannot overlap controls or resize the
sidebar unexpectedly.

### Keyboard Input

Application shortcuts are handled before terminal input. The MVP requires:

- create tab
- close active tab
- select tab by number for the visible tab range

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

### Mouse And Scrollback

Mouse input in terminal content is delivered according to terminal mode.

If terminal mouse tracking is active, pointer and wheel events are encoded for
the terminal app. If mouse tracking is not active, wheel events scroll
scrollback.

The MVP includes a visible scrollbar or equivalent scroll position indicator
when scrollback exceeds the viewport. Dragging it adjusts scrollback and does
not also send duplicate mouse events to the terminal app.

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

The default font stack or bundled font must cover common terminal UI symbols:
box drawing, block elements, arrows, Braille patterns, geometric symbols, and
common private-use terminal glyphs.

### Environment

Interactive shells should receive terminal capability environment variables
that make common tools behave correctly.

The MVP should choose a broadly available `TERM` value unless it also installs
and manages a more specific terminfo entry. Truecolor support should be
advertised separately.

Automation-oriented environment inherited from the launcher must not silently
degrade interactive use. In particular, color suppression should not be passed
through unless configured by the user.

### Titles And Exit State

Terminal title changes update the tab label and window title. Title updates do
not change tab identity, session identity, focus, or ordering.

Title data from terminal output is untrusted. It must be bounded or stored in
owned strings safely.

If a child process exits, the tab records that state. The active terminal view
shows a non-destructive exited indicator, including the exit status when known.

## Quality Bar

The MVP is acceptable when it can:

- open a shell
- run an interactive editor
- run a fullscreen TUI
- display colored CLI output
- display common TUI borders without fallback question marks
- create and switch between multiple tabs without restarting sessions
- close tabs without leaving stale references
- resize without corrupting terminal layout
- type layout-specific characters correctly
- scroll shell output when no app mouse tracking is active
- pass mouse events to terminal apps that request mouse tracking

## Suggested Work Order

1. Terminal session lifecycle: pty spawn, read/write, resize, exit state.
2. Render-state based terminal viewport.
3. Keyboard input and application shortcuts.
4. Vertical tab model and sidebar.
5. Mouse input, scrollback, and scrollbar behavior.
6. Title handling, environment defaults, and glyph coverage.
7. Cleanup paths and failure handling.

## Later Milestones

After the MVP is stable, extend toward `docs/product/spec.md` in this order:

1. split panes backed by stable session IDs
2. multi-window scene identity
3. window-scoped command publication
4. persistence and restoration
5. shell integration markers
6. accessibility
7. production packaging and release engineering
