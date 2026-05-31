# Terminal Session Core: libghostty-vt Integration and PTY Lifecycle

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add
optional sections only when they contain information that will help a fresh
contributor.

## Purpose / Big Picture

After this shard, `LabanTerminalCore` (the C target inside Laban's SwiftPM
package) can start a real shell through a pseudo-terminal, feed its byte
output through the libghostty-vt terminal emulator, and return a cell
snapshot—codepoints, true foreground/background colors, cursor position,
title, exit status—to Swift. No hand-written VT/ANSI parser is involved.
Swift tests prove the session loop works end-to-end in C before any AppKit
code exists.

The change is visible in two ways:

1. `swift test` passes a controlled real-shell test: run
   `/bin/sh -lc "printf 'ok\n'"`, poll until exit, and see `ok` in the
   snapshot grid alongside an exited status.
2. `swift test` passes a fixture-mode test: create a session, inject
   synthesized VT bytes, snapshot cells, resize, and destroy—all without a
   real PTY or child process.

## Progress

- [x] Write `scripts/fetch-libghostty-vt`: clone Ghostty at commit
  `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b`, run `zig build -Demit-lib-vt`,
  and place artifacts under `.external/libghostty-vt/zig-out/`.
- [x] Update `Package.swift`: use `#file` to compute the package root path, then
  add `unsafeFlags` to `LabanTerminalCore` pointing to the zig-out include and
  lib directories. (Note: linker must reference `libghostty-vt.a` by full path,
  not `-lghostty-vt`, to avoid dylib preference; see Surprises.)
- [x] Run `scripts/fetch-libghostty-vt` and confirm artifacts exist at
  `.external/libghostty-vt/zig-out/lib/libghostty-vt.a` and
  `.external/libghostty-vt/zig-out/include/ghostty/vt.h`.
- [x] Add a link smoke test to `Tests/LabanTerminalCoreTests/`: call
  `ghostty_terminal_new`, verify `GHOSTTY_SUCCESS`, call
  `ghostty_terminal_free`. `swift test` passes:
  `testGhosttyVTLinkSmoke` passed (0.002 seconds).
- [x] Retire `scripts/fetch-libghostty` (v1.3.1 sparse-header fetch, no longer
  needed) after confirming no other step depends on it.
- [x] Expand `Sources/LabanTerminalCore/include/LabanTerminalCore.h` with the
  full public C ABI: `LabanSession`, `LabanLaunchConfig`, `LabanTerminalSize`,
  `LabanCell`, `LabanSnapshot`, and the six required functions.
- [x] Implement `session.c` with `laban_session_create` (fixture-mode only:
  `ghostty_terminal_new` + render state) and `laban_session_destroy`.
- [x] Implement `laban_session_poll`: no-op in fixture mode (returns 0).
- [x] Implement `laban_session_resize`: `ghostty_terminal_resize` (+ `TIOCSWINSZ`
  when `pty_fd >= 0`).
- [x] Implement `laban_session_write`: in fixture mode calls
  `ghostty_terminal_vt_write` directly; PTY path returns -1 (not yet implemented).
- [x] Implement `laban_session_snapshot` and `laban_snapshot_destroy`: traverse
  `ghostty_render_state_*` iterators to populate `LabanSnapshot` cells with
  codepoints, fg/bg RGBA.
- [x] Add fixture-mode tests: synthesize VT bytes, verify cell values, resize,
  destroy. Three tests pass: `testFixtureCreatePollSnapshotDestroy`,
  `testFixtureResizeChangesSize`, `testFixtureSnapshotDestroyIsSafe`.
- [x] Update `scripts/check` to call `./scripts/fetch-libghostty-vt` before
  `swift build` so missing artifacts produce a clear failure, not a cryptic one.
- [x] Run `./scripts/check` and confirm it passes end to end.
- [x] Implement PTY byte feed in `laban_session_poll`: nonblocking `read` +
  `ghostty_terminal_vt_write`; treat EIO as PTY-closed; reap child with `waitpid(WNOHANG)`.
- [x] Implement `laban_session_write` PTY path: write bytes to PTY master fd
  (was already wired; verified in PTY shard).
- [x] Implement `laban_session_create` PTY path: executable pre-flight via
  `access(exe, X_OK)`, shared terminal/render-state allocation, `forkpty`,
  child env setup + exec, parent sets `O_NONBLOCK` + initial `TIOCSWINSZ`.
- [x] Add real-shell smoke test: run `/bin/sh -lc "printf 'ok\n'"`, poll until
  exit, verify `ok` cell and exited status. (`testRealShellSmokeOkOutput` passes in 0.064s)
- [x] Add forced-spawn-failure test: ensure partial init is cleaned up correctly.
  (`testForcedSpawnFailureDoesNotLeak` passes; `access()` pre-flight returns -1
  before any allocation.)
- [x] Add PTY resize test: create PTY session, resize to 10×30, verify snapshot
  reports rows=10, cols=30, cell_count=300. (`testPTYResizeSetsSize` passes)

## Decision Log

- Decision: Use libghostty-vt at Ghostty commit
  `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b` (version string `1.3.2-dev`)
  instead of GhosttyKit (v1.3.1) or a hand-written VT parser.
  Rationale: GhosttyKit v1.3.1 requires a live `NSView*` inside
  `ghostty_surface_config_s`; there is no headless constructor. libghostty-vt
  at this commit is a standalone VT terminal library with no GUI dependency.
  It provides full VT parsing, render state with true colors and grapheme
  clusters, and a cursor, all accessible from C without AppKit. This is
  discovered by inspecting ghostling (`/Users/dev/wrk/ghostling`), which pins
  the same commit and uses libghostty-vt with Raylib.
  Date/Author: 2026-05-03 / Codex.

- Decision: Application owns the PTY; libghostty-vt does NOT own the PTY.
  Rationale: ghostty_terminal_new does not accept a PTY fd and does not fork a
  child process. The calling application forks a child (via `forkpty` or POSIX
  equivalents), reads bytes from the PTY master, and feeds them to
  `ghostty_terminal_vt_write`. This is the architecture demonstrated in
  ghostling and is the only valid approach for this library.
  Date/Author: 2026-05-03 / Codex.

- Decision: Use `#file` in `Package.swift` to compute absolute paths for
  `unsafeFlags` instead of hardcoding machine-specific paths or relying on env
  vars.
  Rationale: SwiftPM's `unsafeFlags` passes the flags verbatim to clang. Relative
  paths are unreliable because clang may run from the build directory. `#file`
  resolves to the absolute path of `Package.swift` itself, so
  `URL(fileURLWithPath: #file).deletingLastPathComponent().path` gives the
  portable package root.
  Date/Author: 2026-05-03 / Codex.

- Decision: Key/mouse encoders (`ghostty_key_encoder`, `ghostty_mouse_encoder`)
  are NOT implemented in this shard.
  Rationale: The umbrella plan places these in the AppKit shard alongside
  NSTextInputClient. They require AppKit event objects. Adding them here would
  couple the C core to AppKit prematurely.
  Date/Author: 2026-05-03 / Codex.

## Surprises & Discoveries

- Observation: GhosttyKit v1.3.1 requires `void* nsview` in
  `ghostty_surface_config_s`. There is no headless surface constructor. This
  makes it unsuitable for a C terminal core that must run headless.
  Evidence: Documented in `execplans/active/swiftpm-libghostty-skeleton.md`,
  Probe Results section.

- Observation: libghostty-vt at commit `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b`
  builds as a standalone static library with no GUI dependency.
  `ghostty_terminal_new(NULL, &t, opts)` uses the default libc allocator.
  Evidence: `ghostty_terminal_new` signature in
  `zig-out/include/ghostty/vt/terminal.h`; `NULL` allocator call in
  ghostling `main.c:1455`.

- Observation: Link spike confirmed: SwiftPM can compile a C file that includes
  `<ghostty/vt/terminal.h>` and links against `libghostty-vt.a` with `-lc++`
  via `unsafeFlags`. `swift build` exits 0 with those flags pointing to
  pre-built ghostling artifacts.
  Evidence: Build output `[2/9] Compiling LabanTerminalCore ghostty_vt_spike.c`
  followed by `Build complete! (0.77s)`.

- Observation: Milestone 1 fully validated. `scripts/fetch-libghostty-vt` cloned
  Ghostty from GitHub at the exact commit using `git init + fetch --depth=1`,
  `zig build -Demit-lib-vt` produced `libghostty-vt.a` and `vt.h`, Package.swift
  with `#file`-based path computation compiled and linked, `swift test` passes
  `testGhosttyVTLinkSmoke`. `./scripts/check` exits 0.

- Observation: `-L<dir> -lghostty-vt` causes `swift test` to fail at runtime with
  `dlopen... libghostty-vt.dylib: Library not loaded`. The linker picks the dylib
  over the static archive when both are in the same dir. Fix: specify the static
  archive by full path (`"\(_vtLib)/libghostty-vt.a"`) rather than `-l`.
  Evidence: initial `swift test` crash, fixed by removing `-L/-l` and using the
  full `.a` path in `linkerSettings`.

- Observation: The zig build for this commit requires zig >= 0.15.2
  (`minimum_zig_version` in `build.zig.zon`). System zig 0.15.2 passes.

- Observation: The render state iterator API uses a "pre-allocate, then populate"
  pattern different from what was initially described. Accurate pattern from
  `render.h` and ghostling `main.c`:
  (1) Allocate a row iterator once: `ghostty_render_state_row_iterator_new(NULL, &row_iter)`.
  (2) Populate it from the render state:
      `ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter)`.
  (3) Allocate a row cells container once: `ghostty_render_state_row_cells_new(NULL, &cells)`.
  (4) Loop: `while (ghostty_render_state_row_iterator_next(row_iter))`.
  (5) For each row: `ghostty_render_state_row_get(row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)`.
  (6) Loop: `while (ghostty_render_state_row_cells_next(cells))`.
  (7) Per cell: call `ghostty_render_state_row_cells_get(cells, DATA_KIND, &out)` for each needed kind.
  (8) Grapheme buffer (`DATA_GRAPHEMES_BUF`) returns `uint32_t[]` Unicode codepoints, NOT UTF-8.
      The implementation must encode codepoints to UTF-8 manually.
  Row iterator and cells container are reused across rows; allocate once at session creation.
  Evidence: `render.h` signatures; ghostling `main.c:931-1060`.

- Observation: `laban_session_write` in fixture mode calls
  `ghostty_terminal_vt_write(terminal, bytes, len)` directly — there is no PTY to
  write to. This is the correct path for feeding synthesized VT bytes into a
  headless terminal session. The ABI comment in `LabanTerminalCore.h` documents
  this. Non-fixture callers that want to send keystrokes to a real shell write to
  `pty_fd` (not yet implemented in this shard).
  Evidence: Fixture test `testFixtureCreatePollSnapshotDestroy` writes `"hello"` and
  confirms cell (0,0) has codepoint `0x68`; `./scripts/check` exits 0.

- Observation: `GhosttyRenderStateColors` is a sized struct; it must be initialized
  with `GHOSTTY_INIT_SIZED(GhosttyRenderStateColors)` before passing to
  `ghostty_render_state_colors_get`. Forgetting this would write to an undefined
  `.size` field and the library would skip filling fields it can't fit.
  Evidence: `render.h` doc + `types.h` macro definition.

- Observation: `GHOSTTY_TERMINAL_DATA_TITLE` returns a borrowed `GhosttyString`
  whose `.ptr` is NOT null-terminated. The pointer is invalidated by the next
  `ghostty_terminal_vt_write` call. `laban_session_snapshot` copies `len` bytes
  into a fresh `malloc`-ed buffer before returning.
  Evidence: `terminal.h` comment on `GHOSTTY_TERMINAL_DATA_TITLE`.

- Observation: Milestone 2 (fixture mode) fully validated. All three session tests
  pass: create/poll/write/snapshot/destroy, resize, destroy-is-safe. `./scripts/check`
  exits 0. PTY lifecycle (`forkpty`, real shell, forced-spawn-failure) is deferred
  to the next shard.

- Observation: macOS PTY EOF is `read() == -1 && errno == EIO`, not `n == 0`.
  The slave side closing (child exits) sends EIO to the master reader. Treating
  EIO as normal end-of-life and reaping via `waitpid(WNOHANG)` is the correct
  macOS pattern. `n == 0` is also handled defensively.

- Observation: `access(exe, X_OK)` pre-flight before `forkpty` is sufficient for
  the forced-spawn-failure test. It returns -1 before any resources are allocated,
  so there is nothing to leak. Post-fork exec-failure detection (self-pipe trick)
  is out of scope.

- Observation: Terminal and render-state objects are created in the parent BEFORE
  `forkpty`, so they are never duplicated into the child and resource cleanup on
  fork failure is straightforward.

- Observation: `laban_session_destroy` must not block. Strategy: close PTY fd
  (sends SIGHUP), `waitpid(WNOHANG)`, if alive send `SIGTERM` + loop 5×10ms
  `WNOHANG`, then `SIGKILL` + blocking `waitpid`. Validated: shell sessions
  started by tests exit before the SIGTERM loop fires.

- Observation: Milestone 2 (PTY shard) fully validated. Six session tests pass
  (3 fixture + 3 PTY). `./scripts/check` exits 0 with 11 total tests.

## Context and Orientation

### What exists now

The repository is a SwiftPM package at the repo root. Running `swift build`
and `swift test` from the repo root both pass. The current state:

```
Package.swift                      — SwiftPM package definition
Sources/
  LabanTerminalCore/
    include/LabanTerminalCore.h    — full session ABI (LabanSession, LabanSnapshot, six functions)
    session.c                      — fixture-mode session implementation (Milestone 2)
    session_smoke.c                — laban_terminal_core_smoke_version
    ghostty_vt_bridge_smoke.c      — laban_ghostty_vt_link_smoke (Milestone 1 link proof)
  LabanApp/main.swift              — AppKit window + smoke path
  ... (other targets are stubs)
Tests/
  LabanTerminalCoreTests/
    LabanSessionTests.swift        — fixture create/poll/write/snapshot/resize/destroy tests
    GhosttyVTLinkTests.swift       — Milestone 1 link smoke
    LabanTerminalCoreSmokeTests.swift
scripts/
  fetch-libghostty-vt              — clones Ghostty at pinned commit, zig build
  check                            — fetch-libghostty-vt + JSON lint + swift build+test + smoke-runtime
```

`LabanTerminalCore` is a C target. Its public header is at
`Sources/LabanTerminalCore/include/LabanTerminalCore.h`. Swift targets import
this module, never libghostty headers directly.

### What libghostty-vt is

libghostty-vt is a C library extracted from the Ghostty terminal emulator
(https://github.com/ghostty-org/ghostty). It does one thing: given a stream
of bytes from a PTY, it parses VT/ANSI escape sequences and maintains a
terminal grid. You can query the grid at any time to get cell codepoints,
foreground/background colors (as 24-bit RGB), cursor position, window title,
and whether cells changed since the last query (the "dirty" flag).

libghostty-vt does NOT:
- Spawn a child process or own a PTY file descriptor.
- Draw to a window or know about AppKit, Metal, or any GUI framework.
- Run on a separate thread or use any async mechanism.

The caller (Laban) is responsible for forking a child process, holding the
PTY master file descriptor, reading bytes from it, and feeding them to
`ghostty_terminal_vt_write()`. This is the "application owns the PTY" model.

### What a PTY is

A pseudo-terminal (PTY) is an OS facility that makes a child process (a shell)
believe it is attached to a real terminal. The parent process (Laban) holds
the "master" side as an ordinary file descriptor. Bytes written by the child
(shell output) appear on the master fd; bytes written to the master fd by the
parent appear as keyboard input to the child. Laban reads the master fd and
feeds those bytes to libghostty-vt. When Laban wants to send input to the
shell, it writes raw bytes to the master fd.

On macOS, `forkpty(3)` is the simplest way to create a PTY + fork a child
process in one call.

### What a terminal snapshot is

A snapshot is an owned, bounded copy of terminal state returned from C to
Swift. It contains: rows × cols cells, cursor position, title, exit status,
and dirty state. Swift holds a snapshot; it never holds a raw libghostty
pointer. This protects session identity across AppKit view rebuilds and
resizes.

### Where the zig-built artifacts go

After `scripts/fetch-libghostty-vt` completes:

```
.external/libghostty-vt/           — git clone of Ghostty at the pinned commit
  zig-out/
    include/
      ghostty/
        vt.h                       — umbrella header (includes all sub-headers)
        vt/
          terminal.h               — ghostty_terminal_new/free/resize/vt_write/get/set
          render.h                 — ghostty_render_state_new/update/free + iterators
          types.h                  — GhosttyResult, GhosttyTerminal, GhosttyString, etc.
          allocator.h              — GhosttyAllocator (NULL = libc default)
          color.h                  — GhosttyColorRgb struct
    lib/
      libghostty-vt.a              — static library
      libghostty-vt.dylib          — shared library (not used by Laban)
    share/
      pkgconfig/
        libghostty-vt.pc           — pkg-config metadata (Libs.private includes -lc++)
```

`.external/` is git-ignored (not committed). Run `scripts/fetch-libghostty-vt`
before `swift build`.

## Plan of Work

### Milestone 1: Integrate libghostty-vt and prove the link

This milestone adds the fetch script, wires Package.swift, and runs one Swift
test calling `ghostty_terminal_new`. Nothing about PTY or session lifecycle.
Its only purpose is to establish that `swift build` and `swift test` work with
libghostty-vt linked in. Do not proceed to Milestone 2 until this test passes.

#### Step 1: Write `scripts/fetch-libghostty-vt`

Create `scripts/fetch-libghostty-vt` (executable, sh). The script:

1. Checks `zig` is in PATH and is version >= 0.15.2 (required by the build).
2. Clones Ghostty at commit `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b` into
   `.external/libghostty-vt/` if not already present at the right commit.
3. Runs `zig build -Demit-lib-vt` from within the clone.
4. Verifies that `.external/libghostty-vt/zig-out/lib/libghostty-vt.a` and
   `.external/libghostty-vt/zig-out/include/ghostty/vt.h` both exist.

Idempotent: if `.external/libghostty-vt/` already has the right commit AND the
artifacts exist, the script prints a message and exits 0 without re-cloning or
re-building.

For cloning a specific commit (not a tag) from GitHub, use:

```sh
mkdir -p "$DEST"
git init "$DEST"
git -C "$DEST" remote add origin https://github.com/ghostty-org/ghostty
git -C "$DEST" fetch --depth=1 origin "$GHOSTTY_COMMIT"
git -C "$DEST" checkout FETCH_HEAD
```

The zig build for this commit needs zig to fetch its own dependencies from the
network. This takes a few minutes on first run. Subsequent runs are fast
because zig caches dependencies in its global cache (~/.cache/zig by default).

#### Step 2: Update `Package.swift`

Add `import Foundation` at the top (needed for `URL`). Then, before the
`Package(...)` literal, compute the absolute paths:

```swift
import Foundation

let _pkgDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let _vtInclude = "\(_pkgDir)/.external/libghostty-vt/zig-out/include"
let _vtLib     = "\(_pkgDir)/.external/libghostty-vt/zig-out/lib"
```

Update the `LabanTerminalCore` target:

```swift
.target(
    name: "LabanTerminalCore",
    publicHeadersPath: "include",
    cSettings: [
        .unsafeFlags(["-I\(_vtInclude)"]),
    ],
    linkerSettings: [
        .unsafeFlags(["\(_vtLib)/libghostty-vt.a", "-lc++"]),
    ]
),
```

**Important**: reference the static archive by its full path (`libghostty-vt.a`)
rather than `-L<dir> -lghostty-vt`. When both `.a` and `.dylib` exist in the
same directory, the macOS linker prefers the dylib, causing a runtime
`dlopen` failure when `swift test` runs. Using the full `.a` path forces
static linking. `-lc++` is required for Zig's C++ stdlib dependencies.

#### Step 3: Add a link smoke test

Add a new test file at
`Tests/LabanTerminalCoreTests/GhosttyVTLinkTests.swift`:

```swift
import XCTest
import LabanTerminalCore

final class GhosttyVTLinkTests: XCTestCase {
    func testGhosttyTerminalNewAndFree() {
        var t: OpaquePointer?
        let r = laban_ghostty_vt_link_smoke()
        XCTAssertEqual(r, 0, "ghostty_terminal_new returned non-zero")
    }
}
```

Add a C bridge function in a new file
`Sources/LabanTerminalCore/ghostty_vt_bridge_smoke.c`:

```c
#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>

int laban_ghostty_vt_link_smoke(void) {
    GhosttyTerminalOptions opts = {.cols = 80, .rows = 24, .max_scrollback = 1000};
    GhosttyTerminal t = NULL;
    GhosttyResult r = ghostty_terminal_new(NULL, &t, opts);
    if (r != GHOSTTY_SUCCESS) return (int)r;
    ghostty_terminal_free(t);
    return 0;
}
```

Declare `laban_ghostty_vt_link_smoke` in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h`:

```c
int laban_ghostty_vt_link_smoke(void);
```

Run `swift build && swift test` and expect both to exit 0 with the new test
passing.

#### Step 4: Add `.external/` to `.gitignore`

`.external/libghostty-vt/` must not be committed. Add `.external/` to
`.gitignore` if not already present. Also add the zig cache if it lands under
the repo root.

#### Step 5: Retire `scripts/fetch-libghostty`

The old script fetched Ghostty v1.3.1 headers for the skeleton probe. It is
no longer needed. Delete it. If any other script calls it, update that call.

### Milestone 2: C terminal session ABI and PTY lifecycle

This milestone implements the full `LabanSession` C ABI specified in the
umbrella plan (`execplans/active/swiftpm-appkit-software-renderer-mvp.md`,
Milestone 2 section). By the end, Swift can create a real-shell session, poll
it, snapshot cells with colors, and destroy it.

The C implementation lives in `Sources/LabanTerminalCore/`. Do not expose
libghostty types in the public header. Swift imports only `LabanTerminalCore.h`.

#### The public ABI

Update `Sources/LabanTerminalCore/include/LabanTerminalCore.h` to declare the
full ABI. The smoke functions (`laban_terminal_core_smoke_version`,
`laban_ghostty_vt_link_smoke`) remain; add these:

```c
#include <stddef.h>
#include <stdint.h>

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

Status values for `LabanSnapshot.status`: 0 = running, 1 = exited normally,
2 = exited by signal. `exit_status` is the raw exit code when status = 1.

#### The implementation: `session.c`

Create `Sources/LabanTerminalCore/session.c`. This file implements the ABI.
Include only these headers at the top:

```c
#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/render.h>
#include <util.h>       /* forkpty */
#include <sys/ioctl.h>  /* TIOCSWINSZ */
#include <sys/wait.h>   /* waitpid */
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
```

The internal struct:

```c
struct LabanSession {
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iter;   /* pre-allocated; reused each snapshot */
    GhosttyRenderStateRowCells row_cells;     /* pre-allocated; reused each snapshot */
    int pty_fd;          /* master side; -1 in fixture mode */
    pid_t child_pid;     /* -1 in fixture mode */
    int status;          /* 0=running, 1=exited, 2=signaled */
    int exit_status;
    char *title;
    int fixture_mode;
};
```

Key behaviors per function:

`laban_session_create`:
- If `config->fixture_mode` is 1, create a `ghostty_terminal_new` terminal
  with no PTY or child. Set `pty_fd = -1`, `child_pid = -1`.
- Otherwise: call `forkpty(&pty_fd, NULL, NULL, NULL)` (start without window
  size; resize sets it). In the child: set `TERM=xterm-256color`,
  `COLORTERM=truecolor`, unset `NO_COLOR`, apply `config->envp` overrides,
  `chdir(config->cwd)` if non-null, then `execv(config->executable,
  config->argv)`. In the parent: set the PTY to nonblocking with `fcntl(fd,
  F_SETFL, O_NONBLOCK)`, call `ghostty_terminal_new(NULL, &term, opts)`,
  create `ghostty_render_state_new(&render_state, term)`.
- On any failure, free partial resources. Return 0 on success, -1 on error.

`laban_session_poll`:
- In fixture mode, return 0 immediately (no PTY to read).
- Otherwise: `poll` on `pty_fd` with a 0 timeout (nonblocking check). If
  readable, `read` into a 4096-byte stack buffer; call
  `ghostty_terminal_vt_write(terminal, buf, n)` for each read chunk. Loop
  until `EAGAIN`. If `read` returns 0 or a permanent error, mark exited and
  `waitpid(child_pid, &ws, WNOHANG)` to collect status. Return 0.

`laban_session_resize`:
- Call `ghostty_terminal_resize(terminal, (uint16_t)size.cols,
  (uint16_t)size.rows, (uint32_t)size.cell_width,
  (uint32_t)size.cell_height)`.
- If `pty_fd >= 0`: set `struct winsize ws = {.ws_row=rows, .ws_col=cols,
  .ws_xpixel=pixel_width, .ws_ypixel=pixel_height};` and call
  `ioctl(pty_fd, TIOCSWINSZ, &ws)`.

`laban_session_write`:
- If `pty_fd < 0`, return -1. Otherwise `write(pty_fd, bytes, len)`.

`laban_session_snapshot`:
- Allocate `LabanSnapshot`. Call `ghostty_render_state_update(render_state)`.
- Traverse rows then cells using the render state iterators. For each cell,
  read the grapheme cluster (UTF-8 bytes) and store it in `utf8_storage`, and
  store the offset/length in the cell. Set `foreground_rgba` and
  `background_rgba` from the cell's `GhosttyColorRgb` fields packed as
  `(r << 24) | (g << 16) | (b << 8) | 0xFF`. The `codepoint` fast path: if
  the grapheme is a single ASCII byte (0x20–0x7E), store it directly in
  `LabanCell.codepoint` as well for convenience; otherwise store 0.
- Set cursor and title fields from session state. Return 0 on success.

`laban_snapshot_destroy`:
- Free `utf8_storage`, `cells`, `title` copy, and the snapshot struct itself.

`laban_session_destroy`:
- If `pty_fd >= 0`, close it.
- If `child_pid > 0`, `kill(child_pid, SIGTERM)` and `waitpid` with timeout.
- `ghostty_render_state_free(render_state)`.
- `ghostty_terminal_free(terminal)`.
- Free `title`, `session`.

#### Render state iterator pattern

The libghostty-vt render state uses a "pre-allocate, then populate" pattern.
Allocate the row iterator and row cells container ONCE at session creation and
store them in `struct LabanSession`. Reuse them on every snapshot.

```c
// --- At session creation ---
ghostty_render_state_new(NULL, &session->render_state);
ghostty_render_state_row_iterator_new(NULL, &session->row_iter);
ghostty_render_state_row_cells_new(NULL, &session->row_cells);

// --- At snapshot time ---
// 1. Sync render state from the terminal.
ghostty_render_state_update(session->render_state, session->terminal);

// 2. Populate the pre-allocated row iterator from the render state.
ghostty_render_state_get(session->render_state,
    GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iter);

// 3. Walk rows.
while (ghostty_render_state_row_iterator_next(session->row_iter)) {
    // 4. Populate the pre-allocated cells container from the current row.
    ghostty_render_state_row_get(session->row_iter,
        GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &session->row_cells);

    // 5. Walk cells.
    while (ghostty_render_state_row_cells_next(session->row_cells)) {
        // Grapheme codepoint count (0 = empty cell).
        uint32_t grapheme_len = 0;
        ghostty_render_state_row_cells_get(session->row_cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);

        if (grapheme_len > 0) {
            // Grapheme buffer: Unicode codepoints (uint32_t[]), NOT UTF-8.
            // Must encode to UTF-8 manually.
            uint32_t codepoints[16];
            uint32_t len = grapheme_len < 16 ? grapheme_len : 16;
            ghostty_render_state_row_cells_get(session->row_cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);
            // encode codepoints[0..len-1] to UTF-8 here
        }

        // Foreground and background colors. Both return GHOSTTY_INVALID_VALUE
        // when the cell has no explicit color — fall back to terminal defaults.
        GhosttyColorRgb fg = default_fg, bg = default_bg;
        ghostty_render_state_row_cells_get(session->row_cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
        bool has_bg = (ghostty_render_state_row_cells_get(session->row_cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS);
        // GhosttyColorRgb has .r, .g, .b (uint8_t). Pack as (r<<24)|(g<<16)|(b<<8)|0xFF.
    }
}

// --- At session destroy ---
ghostty_render_state_row_cells_free(session->row_cells);
ghostty_render_state_row_iterator_free(session->row_iter);
ghostty_render_state_free(session->render_state);
```

Internally, `struct LabanSession` needs fields:
```c
GhosttyRenderState render_state;
GhosttyRenderStateRowIterator row_iter;
GhosttyRenderStateRowCells row_cells;
```

The terminal default colors (foreground and background) can be read from the
render state colors:
```c
GhosttyRenderStateColors colors;
ghostty_render_state_colors_get(session->render_state, &colors);
// colors.foreground and colors.background are GhosttyColorRgb defaults.
```

#### Shell resolution

`laban_session_create` must not assume a specific shell path. Resolve the
shell in this order (first non-empty path that exists):

1. `config->executable` if non-null.
2. The value of the `SHELL` environment variable in the inherited environment.
3. The account shell from `getpwuid(getuid())->pw_shell`.
4. `/bin/sh`.

The real-shell smoke test bypasses shell resolution: it passes `executable =
"/bin/sh"` with `argv = ["/bin/sh", "-lc", "printf 'ok\n'", NULL]` directly.

#### Environment setup for child

Before `exec`, always set:
- `TERM=xterm-256color`
- `COLORTERM=truecolor`
- Unset `NO_COLOR` (using `unsetenv`)

Apply any extra entries from `config->envp` after these baseline overrides.

## Concrete Steps

All commands run from the repo root (`/path/to/laban`). This is the directory
containing `Package.swift`.

```sh
# 1. Ensure zig is installed (required for Milestone 1)
zig version
# Expected: 0.15.2 or later

# 2. Run the fetch script (writes to .external/libghostty-vt/)
./scripts/fetch-libghostty-vt
# Expected (first run): clones Ghostty, runs zig build (~5 min)
# Expected (subsequent runs): prints "already at <commit>" and exits 0

# 3. Confirm artifacts
ls .external/libghostty-vt/zig-out/lib/libghostty-vt.a
ls .external/libghostty-vt/zig-out/include/ghostty/vt.h
# Expected: both exist

# 4. Build and test (Milestone 1 done when this passes)
swift build && swift test
# Expected: Build complete, all tests pass including GhosttyVTLinkTests

# 5. Full check (run before each commit)
./scripts/check
# Expected: check passed
```

## Validation and Acceptance

### Milestone 1 acceptance

From the repo root:

```sh
swift build
```
Exits 0. No linker errors.

```sh
swift test --filter GhosttyVTLinkTests
```
Exits 0. Output includes `Test Suite 'GhosttyVTLinkTests' passed`.

### Milestone 2 acceptance (fixture shard — DONE)

From the repo root:

```sh
swift test --filter LabanTerminalCoreTests
```
Exits 0. The following named tests pass (✅ = validated 2026-05-03):

- ✅ `testGhosttyVTLinkSmoke` — `ghostty_terminal_new` + `ghostty_terminal_free` returns 0.
- ✅ `testFixtureCreatePollSnapshotDestroy` — fixture mode session: create,
  inject `"hello"` as VT bytes, snapshot, verify `h` appears in cell (0,0),
  resize to 40×12, destroy.
- ✅ `testFixtureResizeChangesSize` — resize to 40×12, verify snapshot rows/cols.
- ✅ `testFixtureSnapshotDestroyIsSafe` — create/snapshot/destroy with no data.

```sh
./scripts/check
```
✅ Exits 0 with `check passed` (validated 2026-05-03).

### Milestone 2 (PTY shard — DONE)

From the repo root (worktree):

```sh
swift test --filter LabanSessionTests
```
Exits 0. The following named tests pass (✅ = validated 2026-05-03):

- ✅ `testFixtureCreatePollSnapshotDestroy` — fixture mode.
- ✅ `testFixtureResizeChangesSize` — fixture mode.
- ✅ `testFixtureSnapshotDestroyIsSafe` — fixture mode.
- ✅ `testRealShellSmokeOkOutput` — PTY: `/bin/sh -lc "printf 'ok\n'"` exits with
  status 1 and `ok` appears in the cell grid (0.064s).
- ✅ `testForcedSpawnFailureDoesNotLeak` — invalid exe returns -1, nil session.
- ✅ `testPTYResizeSetsSize` — PTY resize to 10×30, snapshot confirms rows/cols/cell_count.

```sh
./scripts/check
```
✅ Exits 0 with `check passed`, 11 tests total (validated 2026-05-03).

## Idempotence and Recovery

- `scripts/fetch-libghostty-vt` is idempotent. Re-running it when artifacts are
  present does nothing.
- To force a rebuild: `rm -rf .external/libghostty-vt && ./scripts/fetch-libghostty-vt`.
- `swift build` is idempotent.
- If `swift build` fails with a missing header error, the fetch script has not
  been run or the artifacts are at the wrong path. Re-run `scripts/fetch-libghostty-vt`.
- `.external/` is git-ignored. Do not commit it.

## Interfaces and Dependencies

### libghostty-vt API summary

Header: `#include <ghostty/vt/terminal.h>` (also `render.h`, `types.h`).

Required for this shard:

```c
// types.h
typedef int GhosttyResult;
#define GHOSTTY_SUCCESS 0
typedef struct GhosttyTerminalImpl* GhosttyTerminal;

// terminal.h
typedef struct {
    uint16_t cols;
    uint16_t rows;
    size_t max_scrollback;
} GhosttyTerminalOptions;

GhosttyResult ghostty_terminal_new(
    const GhosttyAllocator* allocator,   // NULL = libc default
    GhosttyTerminal* out_terminal,
    GhosttyTerminalOptions options
);
void ghostty_terminal_free(GhosttyTerminal terminal);
void ghostty_terminal_vt_write(GhosttyTerminal terminal,
                               const uint8_t* data, size_t len);
GhosttyResult ghostty_terminal_resize(GhosttyTerminal terminal,
    uint16_t cols, uint16_t rows,
    uint32_t cell_width, uint32_t cell_height);
```

Render state API: see `render.h`. Verify function names and struct field names
against the built header before using them; update the Surprises section if
they differ from the iterator pattern shown in Plan of Work.

### Link requirements

- Static library: `.external/libghostty-vt/zig-out/lib/libghostty-vt.a`
- Linker flags: `-lghostty-vt -lc++`
- Compile flag: `-I.external/libghostty-vt/zig-out/include`
- zig required to build the library: version >= 0.15.2

### External tooling

- `zig` >= 0.15.2: build libghostty-vt from source.
- `git`: clone Ghostty source.
- `jq`: already required by `scripts/check`.
- macOS system headers: `util.h` for `forkpty`, `sys/ioctl.h`, `poll.h`.
