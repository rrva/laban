# Close the terminal-capability and integration gaps for modern agent workspace multiplexers

This ExecPlan is a living document maintained in accordance with `../../PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add
optional sections only when they contain information that will help a fresh
contributor.

## Purpose / Big Picture

Laban (`~/wrk/laban`) is a native macOS terminal emulator (Swift/AppKit + Metal,
with VT parsing delegated to the vendored `libghostty-vt` C/Zig library and session
persistence owned by `laband`/`labpty`). Modern agent workspace managers and
multiplexers (built with Rust, `crossterm`, and `ratatui`) run *inside* host
terminals as interactive TUI clients, managing multiple agent child PTYs and
exercising advanced terminal capabilities (SGR mouse tracking, progressive Kitty
keyboard protocol, bracketed paste, synchronized output DEC 2026, focus reporting
DEC 1004, OSC 10/11 color queries, OSC 52 clipboard, OSC 9/99 desktop
notifications, and dynamic theme synchronization).

An audit of modern multiplexer terminal requirements against Laban shows that
Laban already satisfies the majority of requirements (24-bit TrueColor, alternate
screen buffer `CSI ? 1049 h`, SGR 1006 / 1016 mouse tracking with drag forwarding,
Kitty keyboard progressive enhancement + `modifyOtherKeys`, bracketed paste,
synchronized updates `CSI ? 2026 h/l`, focus reporting `CSI ? 1004 h/l`, OSC 52
clipboard, OSC 10/11 color queries, OSC 9/99 notifications, and DECSCUSR cursor
shapes).

However, four gaps and integration seams remain between Laban and advanced
agent multiplexers:

1. **Host appearance reporting (DEC Mode 2031 & `CSI ? 996 n`) is unanswered.**
   Multiplexers enable live appearance reporting (`\x1b[?2031h`) and query theme
   mode (`\x1b[?996n`), expecting `\x1b[?997;1n` (dark) or `\x1b[?997;2n` (light)
   when macOS appearance changes. `libghostty-vt` defines the mode, but Laban does
   not emit live scheme reports. After this change, running TUIs adapt their theme
   live when macOS toggles dark/light mode.

2. **OSC 4 palette queries (`\x1b]4;<index>;?\x1b\`) are dropped.** TUIs query the
   host terminal's full 256-color palette to align syntax highlighting. Laban's
   `osc_host.c` currently filters out OSC 4. After this change, Laban replies
   with the indexed RGB palette values.

3. **Kitty Graphics Protocol (`\x1b_G...`) vs `TERM_PROGRAM=ghostty` compatibility.**
   Laban defaults to `TerminalIdentity.ghosttyCompat` (`TERM_PROGRAM=ghostty`),
   causing programs that check for Ghostty to emit direct Kitty graphics payloads
   (`\x1b_G...`) for inline previews. Laban's `osc_host.c` skips APC strings safely
   without crashing, but `MetalRenderer` does not yet render image quads. After
   this change, Laban consumes and renders Kitty graphics quads.

4. **Workspace multiplexer session restore adapter.** Laban's
   `AgentSessionDetector` identifies active processes for tab restoration.
   Adding a multiplexer reattach adapter (`AgentSupport.swift`) allows Laban's
   session persistence to restore and reattach workspace multiplexer client
   sessions on cold restart.

## Progress

- [x] (2026-08-24) Capability audit complete: analyzed modern multiplexer TUI
  requirements (raw mode, SGR mouse, Kitty keyboard, DEC 2026/2004/1004/2031, OSC 4/10/11/52/99)
  against Laban source (`LabanTerminalCore/`, `LabanRenderer/`, `LabanCore/`).
- [ ] M1 — Conformance baseline: Add multiplexer-specific terminal capability tests in
  `Tests/LabanTerminalCoreTests/`.
- [ ] M2 — Host Appearance Reporting: Implement `CSI ? 996 n` query replies and live
  DEC Mode 2031 `CSI ? 997;1/2 n` notifications in `osc_host.c`.
- [ ] M3 — OSC 4 Palette Query Responses: Implement `OSC 4;<idx>;?` handling in `osc_host.c`.
- [ ] M4 — Kitty Graphics Rendering Pipeline: Implement Kitty graphics consumption
  in `LabanTerminalCore` and textured quad rendering in `MetalRenderer` (aligning
  with M2 of `kimi-code-terminal-capability-gaps.md`).
- [ ] M5 — Workspace Multiplexer Session Resume Adapter in `AgentSupport.swift`.
- [ ] Review Gate passed.

## Context and Orientation

Every path is repository-relative to `~/wrk/laban`.

### Key Concepts and Repository Landmarks

- **`LabanTerminalCore`** (`Sources/LabanTerminalCore/`): The C target wrapping
  `libghostty-vt`. Owns PTY I/O (`capture.c`, `pty_io.c`), key encoding
  (`key_input.c`), mouse encoding (`mouse_input.c`), and side-channel escape
  scanners (`osc_host.c`, `osc133.c`, `tab_status.c`).
- **`osc_host.c`** (`Sources/LabanTerminalCore/osc_host.c`): Laban-side scanner
  that parses OSC sequences and dispatches replies back to the PTY via
  `laban_write_terminal_response`. Currently handles OSC 7 (cwd), OSC 9/99/777
  (notifications), OSC 10/11/12 (color queries), and OSC 52 (clipboard).
- **`TerminalIdentitySettings.swift`** (`Sources/LabanCore/TerminalIdentitySettings.swift`):
  Controls what `TERM_PROGRAM` Laban advertises. Defaults to `ghosttyCompat`
  (`TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION=1.3.1`).
- **`AgentSupport.swift`** (`Sources/LabanCore/Persistence/AgentSupport.swift`):
  Defines per-agent resume adapters and session ID extractors used by
  `AgentSessionDetector.swift` during tab persistence/restore.

### Terminal Capability Requirement Matrix

| Capability | Sequence / Protocol | Laban Current Status | Action Needed |
| :--- | :--- | :--- | :--- |
| **SGR Extended Mouse** | `CSI ? 1006 h`, `1000h`, `1002h`, `1003h`, `1016h` | ✅ Supported | None (verified in `mouse_input.c` + ADR 0016) |
| **Kitty Keyboard Protocol** | `CSI > <flags> u`, `CSI < 1 u`, `\x1b[>4;2m` | ✅ Supported | None (verified in `key_input.c` via Ghostty key encoder) |
| **Bracketed Paste** | `CSI ? 2004 h/l` | ✅ Supported | None (handled in `paste.c` / ADR 0020) |
| **Focus Reporting** | `CSI ? 1004 h/l` -> `\x1b[I` / `\x1b[O` | ✅ Supported | None (handled via `NativeFocusStatusMonitor`) |
| **Synchronized Output** | `CSI ? 2026 h/l` | ✅ Supported | None (parsed by `libghostty-vt`, held in frame presentation) |
| **OSC 10/11 Color Queries** | `\x1b]10;?\x1b\`, `\x1b]11;?\x1b\` | ✅ Supported | None (replies formatted in `osc_host.c:39`) |
| **OSC 52 Clipboard** | `\x1b]52;c;<base64>\x1b\` | ✅ Supported | None (bridged to pasteboard in `osc_host.c:102`) |
| **OSC 9/99 Notifications** | `\x1b]9;<msg>\x1b\`, `\x1b]99;...\x1b\` | ✅ Supported | None (parsed in `osc_host.c:272` and posted to macOS) |
| **Host Appearance Mode 2031** | `CSI ? 2031 h/l`, `CSI ? 996 n` -> `CSI ? 997;1/2 n` | ❌ Gap | Implement responder in `osc_host.c` (Milestone M2) |
| **OSC 4 Palette Queries** | `\x1b]4;<idx>;?\x1b\` -> `\x1b]4;<idx>;rgb:...\x1b\` | ❌ Gap | Implement responder in `osc_host.c` (Milestone M3) |
| **Kitty Graphics Protocol** | `\x1b_G...;payload\x1b\` | ⚠️ Partial | Renderer ignores quads (Milestone M4) |
| **Workspace Restore Adapter** | Process restore / auto-reattach invocation | ❌ Missing | Add adapter to `AgentSupport.swift` (Milestone M5) |

## Decision Log

- **Decision:** Implement DEC mode 2031 / `CSI ? 996 n` and OSC 4 responses directly
  in Laban's `osc_host.c` side-channel scanner.
  *Rationale:* `libghostty-vt`'s VT-only API does not reply to these queries directly.
  Laban's `osc_host.c` already owns side-effect-free OSC 10/11 queries and replies
  through `laban_write_terminal_response` under `SESSION_LOCK`. Adding 2031/996 and
  OSC 4 follows the exact established ADR 0012 pattern without modifying the
  vendored library.
  *Date:* 2026-08-24

- **Decision:** Align Kitty Graphics implementation with M2 of
  `kimi-code-terminal-capability-gaps.md`.
  *Rationale:* Both agent TUIs and workspace multiplexers use the standard Kitty
  graphics protocol (`\x1b_G...`). Laban's `libghostty-vt` already provides image
  storage and placement geometry helpers (`ghostty/vt/kitty_graphics.h`), and
  `FrameCommand.texturedQuad` exists in `LabanRenderer`.
  *Date:* 2026-08-24

- **Decision:** Maintain `ghosttyCompat` as Laban's default `TERM_PROGRAM` while
  supporting honest `TERM_PROGRAM=Laban`.
  *Rationale:* TUI notification detection allowlists standard terminal identities
  (`ghostty`, `WezTerm`, `iTerm.app`). Advertising `ghostty` guarantees rich
  desktop notifications out of the box.
  *Date:* 2026-08-24

## Plan of Work

### M1 — Conformance Test Baseline

Create test cases in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` (or a
dedicated test file `Tests/LabanTerminalCoreTests/MultiplexerCompatibilityTests.swift`)
asserting:
1. SGR mouse reporting mode 1006 / 1016 encodes correctly.
2. Kitty keyboard protocol flags push/pop round-trips correctly.
3. OSC 10 / 11 query responses drain expected `rgb:RRRR/GGGG/BBBB` formats.
4. `CSI ? 996 n` query receives `\x1b[?997;1n` (dark) or `\x1b[?997;2n` (light). *(Fails initially)*
5. `OSC 4;0;?` query receives `\x1b]4;0;rgb:...\x1b\`. *(Fails initially)*

### M2 — Host Appearance Reporting (DEC Mode 2031 & CSI ? 996 n)

1. Extend `osc_host.c` to parse `CSI ? 996 n` (or add a CSI query scanner in
   `capture.c` / `terminal_effects.c`).
2. When `CSI ? 996 n` is received, reply with `\x1b[?997;1n` if `s->color_scheme == LABAN_COLOR_SCHEME_DARK`
   or `\x1b[?997;2n` if `LABAN_COLOR_SCHEME_LIGHT`.
3. In `Session.swift` / `AppModel.swift`, when macOS appearance changes (light <-> dark)
   and DEC mode 2031 is active, emit the corresponding `\x1b[?997;1/2n` sequence to the PTY.

### M3 — OSC 4 Palette Query Responses

1. In `Sources/LabanTerminalCore/osc_host.c`:
   - Add `4` to `osc_host_interesting(int n)`.
   - In `dispatch_osc_host`, parse `OSC 4 ; <index> ; ?`.
   - Read the palette color from `ghostty_terminal_get` (or theme defaults).
   - Reply via `laban_write_terminal_response` with `\x1b]4;<index>;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\`.

### M4 — Kitty Graphics Rendering Pipeline

1. Follow M2 of `execplans/active/kimi-code-terminal-capability-gaps.md`:
   - Set `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` in `session_lifecycle.c`.
   - Register CoreGraphics PNG decoder with `GHOSTTY_SYS_OPT_DECODE_PNG`.
   - Snapshot placements in `snapshot.c` and expose via `LabanTerminalCore.h`.
   - Render `FrameCommand.texturedQuad` in `MetalRenderer.swift`.

### M5 — Workspace Multiplexer Session Resume Adapter

1. In `Sources/LabanCore/Persistence/AgentSupport.swift`:
   - Implement a resume adapter for workspace multiplexers to reconnect or reattach.
   - Register the adapter in `AgentRegistry.supported`.

## Concrete Steps

Run from the repository root `~/wrk/laban`:

```bash
# Verify build and test harness
./scripts/build-app
swift test

# Run specific compatibility tests
swift test --filter MultiplexerCompatibilityTests

# Check formatting and local quality gate
./scripts/check
```

## Validation and Acceptance

- **Appearance Query & Reporting (M2):** Feeding `\x1b[?996n` via `feedOutput` yields
  `\x1b[?997;1n` or `\x1b[?997;2n` in `drainResponse`. Running an advanced TUI in
  Laban and toggling macOS system appearance updates its theme without manual redraw.
- **Palette Queries (M3):** Feeding `\x1b]4;1;?\x1b\` yields `\x1b]4;1;rgb:...\x1b\`.
  TUI palette query probes successfully read all 256 color entries.
- **Interactive Verification:** Running an agent workspace multiplexer inside a live
  Laban tab allows full mouse navigation (clicking tabs, dragging splitters, scrolling
  pane buffers), full keyboard navigation (including prefix keys and copy-mode),
  clipboard copy/paste via OSC 52, and native desktop notifications on task completion.

## Review Gate

- [ ] `./scripts/build-app` exits 0.
- [ ] `swift test` exits 0 with all compatibility tests passing.
- [ ] `feedOutput("\x1b[?996n")` test produces a valid `CSI ? 997` response.
- [ ] `feedOutput("\x1b]4;0;?\x1b\\")` test produces a valid `OSC 4` response.
- [ ] No manual/ad-hoc modifications made to `.external/libghostty-vt` without an ADR.
