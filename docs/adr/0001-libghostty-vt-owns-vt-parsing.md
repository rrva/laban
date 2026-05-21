# 1. libghostty-vt Owns VT Parsing; Application Owns the PTY

Date: 2026-05-03

## Status

Accepted

## Context

Laban needs a VT/ANSI terminal emulator to parse shell output and produce a
cell grid (codepoints, foreground/background colors, cursor, title) that Swift
can consume as an owned snapshot. The first candidate was GhosttyKit — the
public C API shipped with Ghostty v1.3.1.

Probing GhosttyKit revealed that `ghostty_surface_config_s` requires a live
`void* nsview` pointer; there is no headless surface constructor. Every session
therefore requires an AppKit window to exist before the terminal can be
initialized. This makes headless testing, fixture sessions, and the
`laban-agent` executable impossible without a screen.

A second library exists in the Ghostty source tree at a later commit:
`libghostty-vt`. It is a standalone VT terminal library with no GUI dependency.
`ghostty_terminal_new` accepts only `{cols, rows, max_scrollback}`; there is no
NSView requirement. The library parses VT sequences, maintains a terminal grid,
exposes cell colors and grapheme clusters through a render-state API, and
provides key and mouse encoders. A link spike confirmed that SwiftPM can compile
a C file against the self-built `libghostty-vt.a` and that `swift test` passes.

libghostty-vt does not own a PTY or spawn child processes. The calling
application is responsible for launching the shell, owning the PTY master fd,
reading bytes from it, and feeding them to `ghostty_terminal_vt_write`. This
"application owns the PTY" model is the only valid architecture for this
library. The concrete PTY launch mechanism is governed by
`docs/adr/0002-pty-launch-uses-openpty-constrained-fork.md`.

## Decision

**libghostty-vt at commit `46d54ed673a004df09078bee56e809421a82370e` is the
VT parsing library for `LabanTerminalCore`. GhosttyKit is not used.
`LabanTerminalCore` owns the PTY and child process lifecycle.**

The pin was advanced from
`fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b` to
`46d54ed673a004df09078bee56e809421a82370e` by
`docs/adr/0004-advance-libghostty-vt-pin.md`.

### Rules

1. **No hand-written VT or ANSI parser.** VT sequence parsing belongs to
   libghostty-vt. Adding a separate parser for any subset of escape codes is a
   divergence from this decision and requires a new ADR.

2. **The PTY belongs to `LabanTerminalCore`.** Swift must not hold PTY file
   descriptors or child process PIDs. The C layer owns fork, exec, PTY setup,
   nonblocking read, resize (`TIOCSWINSZ`), and child reaping.

3. **Swift sees snapshots, not libghostty state.** Swift imports only
   `LabanTerminalCore.h`. Opaque `LabanSession*` handles and owned `LabanSnapshot*`
   structs are the only surface. Swift must not hold `GhosttyTerminal` or any
   libghostty pointer directly.

4. **Key and mouse encoders stay in the AppKit shard.** `ghostty_key_encoder`
   and `ghostty_mouse_encoder` require AppKit event objects and belong in
   `LabanApp` beside `NSTextInputClient`, not in `LabanTerminalCore`.

5. **The Ghostty commit is pinned and verified.** `scripts/fetch-libghostty-vt`
   clones at the exact commit, runs `zig build -Demit-lib-vt`, and verifies the
   artifact exists before returning. The pin must not be advanced without a
   new ADR entry recording what changed and why.

6. **Static archive, not dylib.** Package.swift links `libghostty-vt.a` by
   full path. On macOS, `-L<dir> -lghostty-vt` causes the linker to prefer the
   dylib, which then fails to load at `swift test` runtime. The static path
   avoids this.

## Consequences

- The terminal core is headless from day one. `laban-agent`, fixture sessions,
  and unit tests all work without a screen or AppKit event loop.
- Zig (>= 0.15.2) is a build-time requirement for any developer or CI machine
  that needs to build from source. The fetch script checks for it.
- The render-state API uses a "pre-allocate, then populate" iterator pattern.
  Row iterator and row cells container are allocated once per session and reused.
  Grapheme data is returned as `uint32_t[]` Unicode codepoints; the C layer must
  encode them to UTF-8 for the snapshot.
- Colors may return `GHOSTTY_INVALID_VALUE` when a cell has no explicit color;
  the C layer falls back to terminal-default colors from
  `ghostty_render_state_colors_get`.
- GhosttyKit and the `scripts/fetch-libghostty` v1.3.1 header script are
  removed. The only Ghostty artifact is the libghostty-vt static archive.
- Advancing the pin to a future Ghostty commit that changes the libghostty-vt
  API requires updating `LabanTerminalCore.h` bindings and adding a Surprises
  entry in the relevant ExecPlan.

## Applies To New Code

Before any change to terminal library, PTY ownership, or snapshot shape, answer:

1. Does the change require a headless terminal? Can `ghostty_terminal_new` be
   called without a window?
2. Is PTY fd management staying in `LabanTerminalCore`?
3. Is the libghostty-vt pin intentionally advancing? If yes, document the API
   delta and open a new ADR.
4. Does Swift still see only `LabanSession*` and `LabanSnapshot*` — no raw
   libghostty types?
5. If adding a key or mouse encoder: does it belong in `LabanApp` (AppKit
   events) or `LabanTerminalCore` (raw byte feed)?

If any answer is "no" or "unclear", resolve it before merging.
