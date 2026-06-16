# Close the terminal-capability gaps that block agent TUIs (Kimi Code) on Laban

This ExecPlan is a living document maintained in accordance with `../../PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add
optional sections only when they contain information that will help a fresh
contributor.

## Purpose / Big Picture

Laban is a native macOS terminal emulator (Swift/AppKit + Metal, with VT parsing
delegated to the vendored `libghostty-vt` C/Zig library). Coding-agent TUIs run
*inside* a terminal; Kimi Code (`~/wrk/kimi-code`, an `@earendil-works/pi-tui`
app) is one such TUI, in the same family as OpenAI Codex and Claude Code.

A capability audit of Kimi Code's terminal requirements against Laban found that
Laban already satisfies the overwhelming majority (ANSI/SGR, 16/256/truecolor,
kitty keyboard + `modifyOtherKeys` + legacy keys, bracketed paste, focus
reporting, synchronized output, resize/SIGWINCH, alternate screen, mouse, OSC
8/9/0/52/7/99/777, shell-integration markers, theme-change reports, and — verified
during this plan's research — the `CSI 14/16/18 t` cell-size query and the
`OSC 10/11` color reply). Three real gaps remain, plus one piece of missing
infrastructure:

1. **Inline images are not displayed.** Laban parses nothing of the Kitty
   graphics protocol at the app layer and draws no images. After this change, an
   image emitted with the Kitty graphics protocol appears inline in a Laban tab.
   You can see it working by running the `icat`-style kitty graphics test, or
   Kimi Code's image-returning tool, in a Laban tab and seeing a picture instead
   of a text placeholder.

2. **tmux/screen DCS passthrough is dropped.** When a program runs *inside* tmux
   or GNU screen, those multiplexers wrap escape sequences they don't understand
   in a `DCS tmux; … ST` passthrough envelope. Laban's host scanners skip DCS
   bodies entirely, so OSC 8 hyperlinks, OSC 9 notifications, and OSC 10/11 color
   queries never reach Laban when an agent runs under tmux. After this change,
   those sequences are unwrapped and honored. You can see it working by running
   `tmux` in a Laban tab and emitting an OSC 9 notification from inside it: a
   native notification fires, where before nothing happened.

3. **Emoji / grapheme cluster width may not match what TUIs assume.** pi-tui
   computes column width with `Intl.Segmenter` (grapheme granularity),
   `get-east-asian-width`, and "RGI emoji = 2 columns". Laban places graphemes in
   the cells libghostty assigned. If those disagree, alignment-sensitive UI
   (rainbow headers, table borders) drifts by a column. After this change, we
   have a measured, regression-locked answer to whether they agree, and a fix or
   a documented, bounded divergence.

4. **There is no autonomous terminal-capability conformance suite.** Laban's
   `AGENTS.md` requires user-visible terminal behavior to be autonomously
   verifiable. Today each capability is tested ad hoc. After this change, a
   single conformance test target encodes every Kimi-Code-class requirement as a
   mechanical assertion (driven through the existing C-bridge query/response
   helpers and the headless debug harness), turning "does Laban host agent TUIs
   correctly?" into one green/red signal that also guards the three fixes above.

This plan delivers item 4 first (it establishes the pass/fail baseline and makes
the other three gaps show up as explicit failing checks), then items 1–3.

## Progress

- [x] (2026-06-16) Research complete: verified current Laban state against the
  Kimi Code requirements; reconciled a stale external audit (cell-size query and
  OSC 10/11 color reply are already implemented, not gaps). Confirmed
  `libghostty-vt` exposes a full Kitty-graphics consumption API and that the
  renderer already accepts `texturedQuad` frame commands.
- [ ] M1 — Terminal-capability conformance suite (baseline; gaps appear as
  pending failures).
- [ ] M2 — Inline image display via the Kitty graphics protocol (completed: —;
  remaining: prototype, terminal-core image state, Metal draw, parity, debug
  endpoint).
- [ ] M3 — tmux/screen DCS passthrough unwrap, re-fed to the OSC host scanners.
- [ ] M4 — Emoji / grapheme width fidelity: measure, then fix-or-document.
- [ ] Review Gate passed.

## Context and Orientation

Read this as if you know nothing about Laban. Every path is repository-relative
from the repo root `~/wrk/laban`.

### Terms

- **VT / escape sequence**: the byte language a program writes to a terminal to
  move the cursor, set colors, etc. (e.g. `ESC [ 2 J` clears the screen).
- **`libghostty-vt`**: the vendored terminal library at `.external/libghostty-vt`
  that parses the VT byte stream and owns terminal state (the grid of cells,
  cursor, modes, and — relevant here — stored Kitty-graphics images). Laban
  embeds its VT-only C API. Worktrees symlink `.external` from the main repo; if
  `.external/libghostty-vt` is missing run
  `ln -s "$LABAN_MAIN_REPO/.external" .external`.
- **Side-channel scanner**: a small byte state-machine in
  `Sources/LabanTerminalCore` that scans the *same* PTY output bytes libghostty
  sees, to act on sequences the VT C API does not surface as a callback. Existing
  examples: `osc133.c` (shell-integration prompt marks), `tab_status.c` (OSC
  21337), `osc_host.c` (OSC 9 notifications + OSC 10/11 color replies). New work
  here re-uses this pattern.
- **Effect callback**: a C function Laban registers with libghostty so the
  library can ask Laban a question or hand it a reply to write back to the child.
  They live in `Sources/LabanTerminalCore/terminal_effects.c` (e.g.
  `laban_effect_size`, which reports `rows/columns/cell_width/cell_height` and is
  what makes `CSI 14/16/18 t` work today).
- **PTY**: pseudo-terminal; the byte pipe between Laban and the child process
  (shell, or an agent TUI). Child→terminal output arrives in
  `Sources/LabanTerminalCore/capture.c` and is fed to libghostty via
  `ghostty_terminal_vt_write`. Laban writes replies back with
  `laban_write_terminal_response` (`terminal_effects.c`).
- **Frame command**: the renderer's drawing instruction. Defined in
  `Sources/LabanRenderer/FrameCommand.swift`. It already has
  `case texturedQuad(rect: CGRect, resourceId: UInt64, source: FrameSource)` —
  the renderer abstraction was deliberately built to accept image quads even
  though display was deferred (see `docs/product/mvp.md` lines ~287 and ~143).
- **Headless debug harness**: `Sources/LabanDebug/HeadlessDebugRuntime.swift`
  runs the full app stack without a window and exposes an HTTP debug server. The
  hard rule in `AGENTS.md` is that `HeadlessDebugRuntime` stays in feature parity
  with `Sources/LabanApp/MainWindowController.swift` `makeAndShow`: wire every new
  subsystem into both, and expose HTTP endpoints for autonomous verification.

### Key files (verified during research)

| Area | File |
|---|---|
| PTY output → libghostty + side-channel scanners | `Sources/LabanTerminalCore/capture.c` |
| Existing OSC host scanner (9/10/11) + DCS-skip state | `Sources/LabanTerminalCore/osc_host.c`, `Sources/LabanTerminalCore/session_internal.h` (state `OH_STRING`) |
| Shell-integration scanner (DCS-skip precedent) | `Sources/LabanTerminalCore/osc133.c` |
| Effect callbacks (size/DA/xtversion/color-scheme) | `Sources/LabanTerminalCore/terminal_effects.c` |
| Session lifecycle / option registration | `Sources/LabanTerminalCore/session_lifecycle.c` |
| Public C ABI | `Sources/LabanTerminalCore/include/LabanTerminalCore.h` |
| Snapshot of the grid (cells, widths, colors) | `Sources/LabanTerminalCore/snapshot.c` |
| Swift session wrapper | `Sources/LabanCore/Session.swift` |
| App/session model, attention/notification fan-out | `Sources/LabanCore/AppModel.swift` |
| Frame production (cells → frame commands) | `Sources/LabanCore/FrameProducer.swift` |
| Renderer frame-command type (has `texturedQuad`) | `Sources/LabanRenderer/FrameCommand.swift` |
| Metal renderer | `Sources/LabanRenderer/MetalRenderer.swift`, `Sources/LabanRenderer/MetalGlyphAtlas.swift` |
| Software renderer (currently no-ops `texturedQuad`) | `Sources/LabanRenderer/SoftwareRenderer.swift` (line ~70) |
| App window wiring | `Sources/LabanApp/MainWindowController.swift` |
| Headless parity + HTTP endpoints | `Sources/LabanDebug/HeadlessDebugRuntime.swift` |
| C-bridge tests (query/response helpers) | `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` (`feedOutput` / `drainResponse`) |

### The Kimi Code requirement set (embedded so this plan is self-contained)

These are the requirement IDs the conformance suite must encode. They come from
Kimi Code's own requirements docs; reproduced here so this plan needs no external
file. **Status** is Laban's verified current state.

| ID | Requirement | Status |
|---|---|---|
| TTY-01..03 | stdin/stdout TTY, `setRawMode`, SIGWINCH + accurate cols/rows | ✅ |
| ANSI-01..04 | Cursor positioning, screen/line clear, cursor visibility, SGR | ✅ |
| COL-01..04 | Truecolor; advertise `COLORTERM=truecolor`; honor `NO_COLOR`/`FORCE_COLOR`/`CI`; `COLORFGBG` | ✅ |
| UNI-01 | Grapheme segmentation matches `Intl.Segmenter` grapheme granularity | ⚠️ measure (M4) |
| UNI-02 | East Asian Width honored (wide = 2 cols) | ✅ |
| UNI-03 | RGI emoji = 2 cols; zero-width combining = 0 cols | ⚠️ measure (M4) |
| UNI-04 | Box-drawing chars render as single cells | ✅ |
| KEY-01..05 | Kitty keyboard (`CSI ? u`, `CSI > 7 u` flags 1/2/4); `modifyOtherKeys` mode 2; legacy CSI/SS3; tmux extended-keys csi-u; `stty -ixon` | ✅ (tmux variant depends on M3) |
| MOD-01 | Bracketed paste `?2004`, wrap `ESC[200~…ESC[201~` | ✅ |
| MOD-02 | Focus reporting `?1004`, `CSI I`/`CSI O` | ✅ |
| MOD-03 | Synchronized output `?2026` | ✅ |
| MOD-04 | `OSC 11;?` → `OSC 11;rgb:RR/GG/BB` | ✅ |
| MOD-05 | Theme-change reports `CSI ?996 n`, `CSI ?997;1/2 n`, `CSI ?2031 h/l` | ✅ |
| ADV-01 | Inline images (Kitty graphics or iTerm2) | ❌ → M2 (Kitty) |
| ADV-02 | `CSI 16 t` / `CSI 14 t` cell-size query for image scaling | ✅ (via `laban_effect_size`) |
| ADV-03 | OSC 8 hyperlinks | ✅ (native; under tmux depends on M3) |
| ADV-04 | OSC 0 title | ✅ |
| ADV-05 | OSC 9 notifications + OSC 9;4 progress | ✅ (under tmux depends on M3) |

### Verified facts that shape the design (do not re-derive)

- **The cell-size query is already answered.** `laban_effect_size`
  (`terminal_effects.c`) reports `cell_width`/`cell_height`; libghostty answers
  `CSI 14 t` (text-area pixels), `CSI 16 t` (cell pixels), `CSI 18 t` (text-area
  chars). The earlier external audit listing `CSI 16 t` as missing was stale.
- **`libghostty-vt` exposes a complete Kitty-graphics *consumption* API**, so M2
  does not need a hand-written graphics parser. From
  `.external/libghostty-vt/include/ghostty/vt/kitty_graphics.h`:
  - Enable storage: `ghostty_terminal_set(GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, …)`
    with a non-zero limit.
  - Install a PNG decoder: `ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, …)`
    (Laban already has PNG/CoreGraphics decode available; see
    `Sources/LabanRenderer/PNGEncoder.swift`).
  - Borrow the image store: `ghostty_terminal_get(GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &handle)`
    (handle invalidated by the next mutating terminal call — read it right after
    `ghostty_terminal_vt_write`, before any further mutation).
  - Iterate placements: `ghostty_kitty_graphics_placement_iterator_new` →
    `ghostty_kitty_graphics_get(GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR)`
    → optional z-filter via `…placement_iterator_set` →
    `…placement_next` / `…placement_get` (`GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID`)
    → `…placement_iterator_free`.
  - Geometry helpers: `…placement_grid_size` (cols×rows the placement covers),
    `…placement_viewport_pos` (viewport-relative grid origin, may be negative),
    `…placement_pixel_size`, `…placement_source_rect`, `…placement_rect`.
  - Image data: `ghostty_kitty_graphics_image(handle, image_id)` →
    `ghostty_kitty_graphics_image_get(…)` for dimensions, pixel format,
    compression, and a borrowed pixel pointer.
  All handles borrowed from the terminal are invalidated by any mutating terminal
  call; the iterator is independently owned and must be freed.
- **The renderer already accepts image quads.** `FrameCommand.texturedQuad` exists;
  `SoftwareRenderer.swift` (~line 70) accepts but does not draw it. The Metal path
  needs the texture upload + draw; the software path may draw a placeholder.
- **spec.md sanctions inline images as terminal-core state.**
  `docs/product/spec.md` line ~139: "Inline image protocols are terminal-core
  state … The terminal core owns image IDs, storage limits, and placement
  metadata; the renderer maps visible placements to cell coordinates." This plan
  follows that ownership split exactly, so M2 needs no new spec approval.
- **DCS passthrough is genuinely dropped.** Both `osc_host.c` and `osc133.c` jump
  to the DCS/SOS/PM/APC terminator without scanning the body (`session_internal.h`
  state `OH_STRING` = "inside a DCS/SOS/PM/APC string: skip, do not scan"). tmux's
  passthrough envelope is `DCS tmux; <payload> ST` where every `ESC` inside
  `<payload>` is doubled (`ESC ESC`). M3 adds a scanner that recognizes the
  `tmux;` introducer, un-doubles the payload, and re-feeds the inner bytes to the
  existing OSC host scanner.
- **`libghostty-vt` has a tmux *control mode* build flag**
  (`GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE`), which is a different feature (tmux
  `-CC`) and is **out of scope** for M3. M3 handles ordinary DCS passthrough only.

## Decision Log

- Decision: Deliver the conformance suite (M1) before the three fixes.
  Rationale: It establishes a mechanical pass/fail baseline, proves the ~19
  already-passing requirements so a fix does not silently regress them, and turns
  each gap into a named failing check that M2–M4 flip green. This is the
  autonomous-verification spine `AGENTS.md` requires.
  Date/Author: 2026-06-16, plan author.
- Decision: Implement inline images via the **Kitty graphics protocol consumed
  from libghostty**, not a side-channel parser and not iTerm2/Sixel first.
  Rationale: libghostty already parses and stores Kitty graphics and exposes a
  full consumption API (placements, images, geometry helpers, PNG-decode hook);
  the renderer already accepts `texturedQuad`; spec.md describes exactly this
  ownership split. iTerm2 inline images and Sixel can be added later behind the
  same terminal-core image-state seam. Kimi Code prefers Kitty graphics.
  Date/Author: 2026-06-16, plan author.
- Decision: M3 covers DCS *passthrough* unwrap only, not tmux control mode.
  Rationale: Passthrough is what gates OSC 8/9/10/11 under tmux for an agent TUI;
  control mode (`tmux -CC`) is a much larger, separate feature.
  Date/Author: 2026-06-16, plan author.
- Decision: M4 is measure-first. Rationale: We do not yet know whether
  libghostty's per-cell widths disagree with pi-tui's model. The milestone first
  produces evidence (a width-conformance fixture), then either fixes a concrete
  divergence or documents a bounded, accepted one with a regression lock.
  Date/Author: 2026-06-16, plan author.

## Plan of Work

Milestones are independently verifiable and land in order. Each ends with
`./scripts/build-app` green and `swift test` green.

### M1 — Terminal-capability conformance suite (baseline)

Scope: a new XCTest target/suite, `Tests/LabanTerminalCoreTests/` (and a headless
companion under `Sources/LabanDebug` exposed over HTTP), that encodes each
requirement ID above as a mechanical assertion. At the end, every ✅ row passes,
and ADV-01 (images), and the UNI-01/UNI-03 width checks exist as **explicitly
skipped/pending** assertions referencing M2/M4 so they are visible, not hidden.

What exists at the end that did not before: one command
(`swift test --filter TerminalCapabilityConformance`) prints a per-requirement
pass/fail line, and a headless route `GET /debug/terminal-capabilities` returns
the same matrix as JSON for screenshot/CI capture.

How to build it: drive query/response requirements through the existing C-bridge
helpers in `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` (`feedOutput`
writes child→terminal bytes; `drainResponse` reads Laban's reply). Examples to
assert (extend, do not limit to these):

- COL-01: feeding nothing, assert `COLORTERM=truecolor` is in the child env Laban
  sets (read the env table the session launches with).
- MOD-04: feed `OSC 11;?` → `drainResponse` equals `\x1b]11;rgb:RRRR/GGGG/BBBB\x1b\\`.
- ADV-02: feed `CSI 16 t` → reply is `CSI 6;<h>;<w> t` with `<w>`/`<h>` equal to
  the configured `cell_width`/`cell_height`; feed `CSI 14 t` → `CSI 4;<H>;<W> t`.
- KEY-01: feed `CSI ? u` → reply reports the current kitty keyboard flags.
- MOD-03: enter `?2026 h`, feed a frame, `?2026 l`; assert the render gate held.
- MOD-05: call the color-scheme setter; assert `CSI ?997;1n`/`CSI ?997;2n` emitted.
- ADV-01: assert `kittyGraphicsPlacementCount == 0` today (pending → flips in M2).
- UNI-03 (pending): feed a known RGI emoji; record the snapshot cell width; mark
  pending until M4 sets the reference.

Acceptance: `swift test --filter TerminalCapabilityConformance` exits 0 with all
non-pending checks green; `GET /debug/terminal-capabilities` returns the matrix.

### M2 — Inline image display (Kitty graphics protocol)

Scope: make a Kitty-graphics image emitted by a child program appear inline in a
Laban tab, with the terminal core owning image/placement state and the renderer
drawing visible placements as textured quads. Follow spec.md's ownership split.

Sub-steps (prototype-first to de-risk the C API before touching the renderer):

- **M2a (prototype, additive, test-only).** In a C-bridge test, enable Kitty
  storage (`GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT`), install the PNG
  decoder (`GHOSTTY_SYS_OPT_DECODE_PNG`) backed by CoreGraphics/`PNGEncoder.swift`
  decode, feed a minimal Kitty graphics escape that transmits and places a tiny
  PNG, then iterate placements and assert: one placement, expected `image_id`,
  expected `grid_size` (cols×rows), expected `viewport_pos`, and non-null pixel
  data of the expected dimensions. This proves the consumption API end-to-end
  with zero renderer risk. Reference the library example
  `c-vt-kitty-graphics/src/main.c` under `.external/libghostty-vt`.
- **M2b (terminal-core image state).** Add a C ABI in `LabanTerminalCore.h`/`.c`
  that, after each `ghostty_terminal_vt_write`, snapshots visible placements into
  a stable, Swift-readable list: `{imageId, originCol, originRow, cols, rows,
  pixelWidth, pixelHeight, zLayer}` plus a way to fetch the decoded RGBA bytes for
  an `imageId` once (renderer uploads, then caches by identity). Enable the
  storage limit and PNG decoder in `session_lifecycle.c` next to the existing
  option registration. Keep handle lifetime rules: read placements immediately
  after `vt_write`, copy out, never retain a borrowed handle across a mutation.
- **M2c (renderer draw).** In `FrameProducer.swift`, translate the placement list
  into `FrameCommand.texturedQuad` commands mapped to cell coordinates. In
  `MetalRenderer.swift`/`MetalGlyphAtlas.swift`, upload each image's RGBA to a
  Metal texture keyed by `imageId`, draw the quad, and destroy the texture only
  after in-flight frames no longer reference it (spec.md's caching rule). In
  `SoftwareRenderer.swift`, replace the no-op with a visible placeholder rectangle
  (so headless screenshots prove placement geometry even without Metal).
- **M2d (parity + observability).** Wire image state into both
  `MainWindowController.makeAndShow` and `HeadlessDebugRuntime` (hard rule). Add
  `GET /debug/kitty-graphics` returning the current placement list as JSON, and
  emit a capture/debug event when a placement is added/removed.

What exists at the end: a real picture renders inline in a Metal-backed Laban
tab; a headless screenshot shows the placeholder at correct cell geometry;
`GET /debug/kitty-graphics` lists the placement; the M1 ADV-01 check flips green.

Acceptance: see Validation. This milestone may be promoted or deferred
independently of M3/M4; it is the largest and is the one explicitly framed in
spec.md.

### M3 — tmux/screen DCS passthrough unwrap

Scope: a side-channel scanner (new state path in `osc_host.c` or a sibling file
following the `osc133.c`/`tab_status.c` pattern) that recognizes the tmux/screen
passthrough envelope `DCS tmux; <payload> ST` (`ESC P tmux ; … ESC \`),
un-doubles `ESC ESC` → `ESC` inside `<payload>`, and re-feeds the recovered inner
bytes to the existing OSC host scanner so OSC 8/9/10/11 are honored as if emitted
directly. GNU screen's `DCS <payload> ST` (no `tmux;` introducer, split at 768
bytes) is handled as a documented best-effort variant.

What exists at the end: emitting an OSC 9 notification from inside `tmux` in a
Laban tab fires the native notification; an OSC 11 query from inside tmux gets a
color reply.

Acceptance: a C-bridge test feeds a `DCS tmux;` envelope wrapping `OSC 9;hello ST`
and asserts the notification callback fires with `hello`; another wraps `OSC 11;?`
and asserts the color reply drains. The M1 KEY-04/ADV-03/ADV-05 "under tmux"
checks flip green.

### M4 — Emoji / grapheme width fidelity (measure, then fix-or-document)

Scope: a width-conformance fixture that feeds a curated set (ASCII, CJK wide,
RGI emoji, ZWJ emoji sequences, variation selectors, zero-width combining marks,
flags) and compares the per-cell width libghostty assigned (read from the
snapshot) against the reference width pi-tui computes (RGI emoji = 2, ZWJ cluster
= 2, combining = 0, EAW wide = 2). Then: if they agree, lock it with the
regression test and mark UNI-01/UNI-03 green. If a concrete divergence exists,
either bump/patch libghostty's width table (only with an ADR, per the terminal
library decision boundary) or document the bounded divergence in this plan and in
`docs/quality/` and accept it, keeping the regression test as the contract.

What exists at the end: a definitive, regression-locked answer to "do Laban's
grapheme widths match what agent TUIs assume?" and either a fix or a documented
boundary.

Acceptance: `swift test --filter TerminalWidthConformance` green; M1 UNI checks
no longer pending.

## Concrete Steps

Run everything from the repo root `~/wrk/laban`.

```
# Build the app + C bridge (debug; assembles the bundle). Do NOT use `swift build`.
./scripts/build-app

# Run the conformance suite created in M1
swift test --filter TerminalCapabilityConformance

# Full C-bridge + model suites (as the codex plan did)
swift test
```

For headless verification (M1/M2 parity + endpoints), start the headless runtime
and query the debug endpoints (exact start command per
`docs/process/dev-process.md`; the headless server exposes the routes added in
each milestone):

```
# Example shape — confirm the route names against HeadlessDebugRuntime
GET /debug/terminal-capabilities     # M1 matrix as JSON
GET /debug/kitty-graphics            # M2 current placements as JSON
```

Do not `open`/launch `Laban.app` from the shell (it grabs the single-instance
lock); for the live-Metal image check, install a dedicated build and let the user
launch it:

```
LABAN_INSTALL_PATH="$HOME/Laban-kimi-compat.app" ./scripts/install-app
# then the user launches it and runs the kitty-graphics image test in a tab
```

## Validation and Acceptance

Phrase every acceptance as observable behavior.

- **M1.** `swift test --filter TerminalCapabilityConformance` exits 0; every
  non-pending requirement check passes; the suite prints one line per requirement
  ID. `GET /debug/terminal-capabilities` returns a JSON matrix whose ✅ rows match
  the table in this plan. Each conformance assertion must fail if its capability
  is broken — prove this for at least one check by mutating the responder (e.g.
  break the `OSC 11;?` reply), observing the red, and reverting.
- **M2.** In a Metal-backed Laban tab, run a Kitty-graphics image emitter (the
  library's `c-vt-kitty-graphics` example payload, an `icat`-style script, or
  Kimi Code's image-returning tool): a picture appears inline at the correct cell
  position, survives a scroll within the viewport, and is removed when the program
  clears it. Headless: `GET /debug/kitty-graphics` lists exactly one placement
  with the expected grid origin and size, and a headless screenshot shows the
  software-renderer placeholder at that geometry. The M1 ADV-01 check is green.
  The M2a prototype test passes (placement count, image_id, grid_size,
  viewport_pos, pixel dimensions).
- **M3.** A C-bridge test feeding `DCS tmux; OSC 9;hello ST` fires the OSC-9
  notification callback with exactly `hello`; feeding `DCS tmux; OSC 11;? ST`
  drains an `OSC 11;rgb:…` reply. End-to-end: running `tmux` in a Laban tab and
  emitting `printf '\033]9;done\007'` inside it produces a native notification.
- **M4.** `swift test --filter TerminalWidthConformance` exits 0; the fixture
  asserts agreement (or a documented, bounded divergence) for ASCII, CJK, RGI
  emoji, ZWJ sequences, variation selectors, combining marks, and flags. The M1
  UNI-01/UNI-03 checks are no longer pending.

Whole-plan acceptance: `./scripts/build-app` green; `swift test` green; an agent
TUI (Kimi Code) runs in a Laban tab with no capability warnings, images render
inline, and notifications fire even under tmux.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is considered complete. The executing agent must not mark the plan done until
this gate passes. See PLANS.md "Review gate and review-fix loop".

- [ ] `./scripts/build-app` exits 0 on a clean checkout at the review commit.
- [ ] `swift test` exits 0; record the passed count.
- [ ] `swift test --filter TerminalCapabilityConformance` exits 0 and prints one
      line per requirement ID listed in this plan's requirement table.
- [ ] Mutation check (M1 is a real gate, not a stub): break the `OSC 11;?` reply
      in `Sources/LabanTerminalCore/terminal_effects.c` (or `osc_host.c`), rerun
      the MOD-04 conformance check, observe it FAIL, then revert and observe PASS.
- [ ] M2 prototype: `swift test` includes a passing test that iterates a Kitty
      placement and asserts non-zero `grid_size` and non-null pixel data.
- [ ] M2 parity: `grep -n "kitty\|Kitty\|graphics" Sources/LabanDebug/HeadlessDebugRuntime.swift`
      and `Sources/LabanApp/MainWindowController.swift` both show the image
      subsystem wired (parity hard rule); `GET /debug/kitty-graphics` route exists.
- [ ] M3: a test feeding `DCS tmux; OSC 9;<text> ST` fires the notification
      callback with exactly `<text>`; a test feeding `DCS tmux; OSC 11;? ST`
      drains a non-empty `OSC 11;rgb:` reply.
- [ ] M4: `swift test --filter TerminalWidthConformance` exits 0; if any divergence
      is accepted, it is documented in this plan's `Surprises & Discoveries` and a
      regression test pins it.
- [ ] If any new ADR was required (e.g. a libghostty width-table patch in M4), it
      exists under `docs/adr/` and is listed in `docs/adr/README.md`.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- All milestones are additive. M1 adds tests/endpoints. M2 adds an opt-in storage
  limit + decoder + read path; with the storage limit at 0 (default) Kitty
  graphics is inert, so partial M2 cannot regress existing behavior. M3 adds a
  scanner branch reached only inside a `DCS tmux;` envelope; non-tmux output is
  untouched. M4 adds tests (and at most an ADR-gated library patch).
- Re-running `./scripts/build-app` and `swift test` is safe and repeatable.
- If the M2 C API behaves unexpectedly, stop at the M2a prototype: it is
  test-only and proves/falsifies feasibility before any renderer change.
- Do not modify vendored `libghostty-vt` except under M4 with an ADR (the
  terminal-library decision boundary in `docs/adr/README.md`). M1–M3 require no
  library changes.
- A regenerated `.rpg/graph.json` alone marks the build `+dirty`; if a built
  bundle "doesn't work", verify `Info.plist:LABANBuildCommit` matches HEAD before
  debugging source.

## Interfaces and Dependencies

- **libghostty-vt Kitty-graphics C API** (`.external/libghostty-vt/include/ghostty/vt/kitty_graphics.h`):
  `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT`, `GHOSTTY_SYS_OPT_DECODE_PNG`,
  `GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS`, `ghostty_kitty_graphics_placement_iterator_new/_get/_set/_next/_free`,
  `ghostty_kitty_graphics_placement_get` (`…PLACEMENT_DATA_IMAGE_ID`),
  `ghostty_kitty_graphics_placement_grid_size/_viewport_pos/_pixel_size/_source_rect/_rect`,
  `ghostty_kitty_graphics_image` + `…image_get`.
- **New `LabanTerminalCore` C ABI (M2b):** a placement-snapshot function and a
  decoded-RGBA fetch-by-imageId function, declared in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`, mirroring the existing
  snapshot/effect patterns. Lifetime rule: borrowed handles are read immediately
  after `ghostty_terminal_vt_write` and copied out.
- **Renderer (M2c):** reuse `FrameCommand.texturedQuad(rect:resourceId:source:)`;
  textures keyed by `imageId`, destroyed only after in-flight frames release them.
- **Swift wiring (M2d):** `Session.swift` exposes the placement list;
  `AppModel.swift` fans it to `FrameProducer.swift`; parity in both
  `MainWindowController` and `HeadlessDebugRuntime`; HTTP route
  `GET /debug/kitty-graphics`.
- **M3 scanner:** extends `Sources/LabanTerminalCore/osc_host.c` (or a sibling)
  using the `session_internal.h` scanner-state pattern; re-feeds unwrapped bytes
  to `laban_scan_osc_host`.
- **Tests:** `Tests/LabanTerminalCoreTests/LabanSessionTests.swift` helpers
  `feedOutput` / `drainResponse`; new suites `TerminalCapabilityConformanceTests`
  and `TerminalWidthConformanceTests`.
