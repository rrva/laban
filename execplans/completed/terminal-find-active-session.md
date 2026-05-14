# Add Local Find For The Active Terminal Session

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then deliver a working "find in active terminal" feature
end-to-end.

## Purpose / Big Picture

Laban has a working terminal viewport, scrollback, AppKit input, selection,
copy/paste, a debug HTTP server, capture/replay, and a deterministic software
renderer. The next user-visible gap is the one this plan closes: there is no
way to search the terminal output. iTerm2 and macOS Terminal both bind
Command-F to a find toolbar; pressing Command-F in Laban does nothing.

After this change:

- Pressing **Command-F** while a terminal tab is active opens a small floating
  "find chip" at the top-right corner of the terminal viewport. The chip is a
  rectangle containing a text input, a "current/total" match counter (such as
  `12/47`), up/down step buttons, and a close button.
- Typing into the chip performs an incremental literal substring search of
  the visible viewport and scrollback. Every match is rendered with a
  highlighted background through the existing frame-command renderer; the
  currently selected match uses a stronger highlight color.
- Pressing **Return** scrolls the viewport to the next match (most recent
  first) and advances the selection. **Shift+Return** steps to the previous
  match. **Escape** dismisses the chip and clears the highlight.
- Closing the chip leaves the terminal exactly as it was. Find never writes
  to the PTY, never moves the cursor, and never changes session state.
- In headless mode, agents can drive the same flow through
  `POST /debug/find/start`, `POST /debug/find/step`, `POST /debug/find/stop`,
  and `GET /debug/find/state`. The frame command stream emits dedicated
  `findMatch` and `findSelected` rectangles so capture/replay tests can
  assert which cells are highlighted on which frame.

The feature ships **synchronously**: the search runs on the main thread,
bound to existing dirty-snapshot and user-input events. There is no
background search thread and no cross-tab workspace search; both are
explicitly deferred (see *Out Of Scope*). The viewport portion of the
result set *does* refresh when the active terminal area changes
(typing into a `tail -f`, for example), but the refresh is a main-thread,
frame-bound recomputation — not a background search loop. Full
scrollback rescans happen on open and step immediately; AppKit needle
typing stores the pending needle cheaply and coalesces the full rescan
after a short pause so the search field remains responsive, then scrolls
once to reveal the selected first match. The exact policy is in *Plan of
Work* → M2.2b.

The MVP document (`docs/product/mvp.md:215-218`) excludes "search integration"
with terminal selection but does not forbid find itself; this is a post-MVP
enhancement that does not block the MVP's quality bar. The product spec now
captures the shipped v1 behavior in `docs/product/spec.md` section 22.

## Progress

Use this list to track granular work. Update it whenever a step changes
state. Timestamps are encouraged once implementation starts.

- [x] (2026-05-13) Surveyed libghostty-vt's search internals. Confirmed the
  Zig side has a complete `ScreenSearch` engine in
  `.external/libghostty-vt/src/terminal/search/`, but the public C ABI
  (`.external/libghostty-vt/include/ghostty/vt/*.h`) exposes none of it.
  See *Surprises & Discoveries* for the per-file findings.
- [x] (2026-05-13) Decided synchronous v1, no `Thread.zig` dependency, no
  libxev. See *Decision Log*.
- [x] (2026-05-13) Decided to anchor matches by `(row, column-range)` in the
  current terminal generation, refreshing after any terminal output, rather
  than by libghostty-vt page serials (which are not exposed via the C ABI).
- [x] (2026-05-13) Decided to ship viewport find first (Milestone 1), extend
  to scrollback second (Milestone 2), polish/debug third (Milestone 3).
- [x] (2026-05-14) M1 implementation completed in the `cmd_f` worktree:
  `TerminalFind.swift`, `TerminalFindState.swift`, AppModel ownership,
  rendering, debug, and AppKit wiring are in place.
- [x] M1: Add a Swift-side substring search over `LabanSnapshot` for the
  visible viewport.
- [x] M1: Add a `Find` state object owned by `Session` (or `AppModel`) that
  holds needle, matches, and selected index.
- [x] M1: Render `findMatch` and `findSelected` rectangles via
  `FrameProducer` so they appear under text in the Metal and software
  renderers.
- [x] M1: Add the floating "find chip" AppKit view, the Command-F shortcut,
  and Enter/Shift+Enter/Escape handling.
- [x] M1: Add `POST /debug/find/start`, `/debug/find/step`, `/debug/find/stop`
  and `GET /debug/find/state` to `DebugHTTPServer`, plus the matching
  schemas in `schemas/debug/`.
- [x] M1: Unit tests for the search algorithm, headless tests for the debug
  endpoints, and an end-to-end fixture that asserts highlight rectangles.
- [x] M2: Add a C ABI to read scrollback rows by row index
  (`laban_session_scrollback_extract`) and extend the Swift `Find` engine to
  scan scrollback. Scroll the viewport on selection so off-screen matches
  become visible.
- [x] M2: Apply the refresh policy (active-area-only on streaming
  output; full scrollback rescan only on needle change, step, and open)
  with the integration point inside `AppModel`.
- [x] M2: Tests covering scrollback search, scroll-on-step behavior,
  and the refresh policy (assert that a streaming output event does
  not trigger a scrollback rescan).
- [x] M3: Polish — drag-to-reposition the chip, accessible role/label,
  checked-in `fixtures/find-viewport.json`, and capture/replay coverage
  through `scripts/test-e2e`. Explicit case-mode UI is deferred in the
  product spec; v1 keeps smart case as the only exposed behavior.
- [x] M3: Update `docs/product/spec.md` with a short "Find" section and a
  one-line decision note in `docs/adr/` if the find architecture warrants
  it.
- [x] (2026-05-15) First repeated-navigation performance pass completed:
  full-history match results are cached by session, needle, and row count;
  cache hits avoid scrollback extraction, search, and sorting.
- [x] (2026-05-15) M4: Reduce first-scan cost by adding a terminal-core direct find path
  that returns match coordinates without first copying the whole scrollback
  into a Swift `String`.
- [x] (2026-05-15) M4: Validate that the direct path preserves current ASCII find behavior,
  falls back safely for unsupported Unicode rows, and improves release-mode
  `find.start` timings.
- [x] (2026-05-15) Added a tracked release-mode find performance guard:
  `scripts/test-find-perf` runs the `find-perf` SwiftPM executable and fails
  on large regressions in cold start, cached step, or pending-needle update.
- [x] (2026-05-15) Merged and pushed the terminal-find work to `origin/main`
  at merge commit `136bcac`, then archived this plan to `execplans/completed/`.

## Decision Log

- Decision: Ship synchronous v1; do not depend on libghostty-vt's
  `Thread.zig` or libxev.
  Rationale: The threaded variant requires the caller to provide a
  `*std.Thread.Mutex` held during every terminal read/write
  (`.external/libghostty-vt/src/terminal/search/Thread.zig:432-434`). That
  contract is a structural change to `LabanTerminalCore`'s C ABI and to
  every Swift caller of `Session`. The visible benefits of threading (live
  re-search of streaming output, alt-screen survival, render-thread
  isolation) all have synchronous workarounds: refresh on output via the
  existing snapshot path, retain `Find` state across alt-screen toggles in
  Swift, and run search incrementally between input events. Synchronous
  also keeps the capture/replay harness deterministic without needing
  thread fences. Migration to threaded later is additive — the Swift `Find`
  surface stays the same.
  Date/Author: 2026-05-13 / Codex.

- Decision: Build find on top of Laban's existing `LabanSnapshot` and a new
  scrollback extraction API; do not modify the vendored
  `.external/libghostty-vt` library.
  Rationale: libghostty-vt's public C ABI does not expose `ScreenSearch`,
  `Pin`, or `Flattened` highlights — these are Zig-only public modules
  (`.external/libghostty-vt/src/lib_vt.zig:47,52,68`) with no
  `GHOSTTY_API` C entry points. Adding C bindings to the vendored library
  is a cross-boundary change that belongs in a follow-up plan. The public
  C ABI does expose row iteration (`ghostty_render_state_row_iterator_*`
  for the viewport, `ghostty_terminal_grid_ref` with
  `GHOSTTY_POINT_TAG_HISTORY` for scrollback) plus a bulk text formatter
  (`ghostty_formatter_format_alloc`). Either is sufficient for v1.
  Date/Author: 2026-05-13 / Codex.

- Decision: Match identity is `(row, column-range)` in the current terminal
  generation. After terminal output, find refreshes visible rows from the
  current snapshot and re-maps the selected match. Full scrollback search is
  deliberately limited to open, needle change, and step.
  Rationale: The Zig internals use page serials (`PageList.Pin` plus the
  `serial: u64` carried by each `Flattened.Chunk`,
  `.external/libghostty-vt/src/terminal/highlight.zig:128-133`) so the
  selected match can survive output. Those serials are not in the C ABI.
  Without them, the simplest honest model is: matches are positions in the
  current generation; new output invalidates the visible range, while older
  offscreen matches are retained until an explicit full refresh. This keeps
  typing responsive without repeatedly scanning all scrollback during verbose
  streaming output.
  Date/Author: 2026-05-13 / Codex.

- Decision: Default behavior is literal substring match, ASCII-fold
  case-insensitive when the needle is all lowercase, case-sensitive
  otherwise ("smart case"). No regex toggle in v1.
  Rationale: libghostty-vt's upstream matcher uses
  `std.ascii.indexOfIgnoreCase`
  (`.external/libghostty-vt/src/terminal/search/sliding_window.zig:179,205,219`),
  which is ASCII-only. We mirror that semantically in our Swift matcher so
  the experience matches what would happen if we later switch to the
  upstream engine. Slash-delimited regex (`/foo/`) was considered and
  rejected because the most common terminal needles (paths like
  `/tmp/foo`, `/usr/local`) would collide. If regex is added later, it
  should be a `re:` prefix or an explicit toggle in the chip UI, not the
  default.
  Date/Author: 2026-05-13 / Codex.

- Decision: Hybrid interaction (type-to-highlight, Enter-to-jump,
  Shift+Enter-to-step-back, Escape-to-exit), not pure filter-in-place.
  Rationale: Decades of Command-F muscle memory across browsers, editors,
  and terminals. The GTK Ghostty search overlay
  (`.external/libghostty-vt/src/apprt/gtk/ui/1.2/search-overlay.blp`)
  uses the same shape (`search-changed` + `next-match`/`previous-match` +
  `stop-search`). Filter-in-place was attractive for its "don't move my
  viewport" property but loses the established navigation contract.
  Date/Author: 2026-05-13 / Codex.

- Decision: M2's scrollback extraction C ABI uses caller-allocated
  buffers under the session lock, not session-owned storage with a
  "valid until next call" contract.
  Rationale: Laban runs the PTY reader on a dedicated background
  thread (`Sources/LabanCore/SessionRunner.swift:69-80` —
  `laban.session.reader`) that calls `laban_session_poll_blocking` in
  a tight loop. A "valid until next call" pointer would race with that
  thread: the reader can finish a drain and trigger the next call
  between the extract returning and Swift copying its bytes,
  invalidating the buffer mid-read. A probe-then-extract pattern with
  caller-owned buffers (mirroring `laban_session_encode_paste` and
  `laban_session_send_key_encoded`) avoids the race entirely because
  the returned storage belongs to the caller, not the session.
  Date/Author: 2026-05-13 / Codex.

- Decision: The find chip is a floating overlay anchored top-right of the
  terminal viewport, not a toolbar at the top or bottom that reflows
  terminal content.
  Rationale: A toolbar steals a row of terminal display, which is
  particularly destructive in TUIs (vim/htop redraw on every row change).
  The floating overlay leaves the terminal unchanged. The GTK reference
  implementation uses the same anchoring (`halign: end, valign: start`).
  Date/Author: 2026-05-13 / Codex.

- Decision: Capture/replay records debug find actions as `input.event`
  entries and replays them into `AppModel` before comparing frame-command
  hashes.
  Rationale: Find highlights are app state, not terminal bytes. When the
  E2E capture first included find frames, terminal replay reconstructed the
  terminal grid but not the find state, so `frame.commands` hashes diverged
  on the frames containing `findMatch` and `findSelected`. Recording
  `find.start`, `find.step`, and `find.stop` as replayable input events
  keeps capture/replay deterministic without serializing renderer pixels as
  source of truth.
  Date/Author: 2026-05-14 / Codex.

- Decision: M4 should add a LabanTerminalCore C-side direct match scan over
  the existing plain formatter output, not a raw `ghostty_terminal_grid_ref`
  traversal.
  Rationale: A raw history scan would require resolving many arbitrary grid
  references, and the Ghostty C API documents `ghostty_terminal_grid_ref` as
  unsuitable for render-loop-scale traversal. The direct C scan still uses the
  formatter as the source of terminal text, preserving current row and wrapping
  semantics, but removes the extra copied text buffer, row-offset array,
  Swift `String` decode, and Swift byte scan from first-search hot paths. It
  is an incremental improvement that keeps the raw-grid or upstream Zig search
  binding available for a later, larger change.
  Date/Author: 2026-05-15 / Codex.

## Surprises & Discoveries

- Observation: libghostty-vt has a mature search subsystem in Zig but
  none of it is in the public C ABI.
  Evidence: `.external/libghostty-vt/src/terminal/search/` contains
  ~5300 lines across `active.zig`, `pagelist.zig`, `screen.zig`,
  `sliding_window.zig`, `Thread.zig`, and `viewport.zig`. `lib_vt.zig:52`
  exposes `pub const search = terminal.search` to the Zig module surface,
  but `grep -r 'ghostty_search\\|ghostty_highlight\\|ghostty_pin'
  .external/libghostty-vt/include/` returns zero matches.
- Observation: GTK Ghostty (the reference apprt that ships with the
  vendored library) implements a working find UI on top of the Zig
  internals, but it is GTK-specific and the C ABI gap means we cannot
  reuse the engine on AppKit without writing C bindings.
  Evidence: `.external/libghostty-vt/src/apprt/gtk/class/search_overlay.zig`
  (~500 lines) and `.external/libghostty-vt/src/apprt/gtk/ui/1.2/search-overlay.blp`
  (a Blueprint UI definition with `SearchEntry`, prev/next buttons, match
  counter label, and drag-to-reposition).
- Observation: The upstream substring matcher is ASCII-fold only.
  Multi-byte UTF-8 needles match literally as raw bytes (so `café` finds
  `café`), but case folding does not apply to non-ASCII (so `Á` does not
  match `á`).
  Evidence: `.external/libghostty-vt/src/terminal/search/sliding_window.zig`
  lines 179, 205, 219 use `std.ascii.indexOfIgnoreCase`. There is no
  Unicode case-folding path in the Zig search engine.
- Observation: The Zig `ScreenSearch` re-initialises on any rows/cols
  change.
  Evidence: `.external/libghostty-vt/src/terminal/search/screen.zig:263-279`
  reinitialises the entire search when the page dimensions change. Our
  Swift v1 will do the same: window resize during find drops the result
  set and re-searches at the new size. This is acceptable because resize
  is rare and the user explicitly initiated it.
- Observation: The libghostty-vt formatter API
  (`ghostty_formatter_format_alloc` in
  `.external/libghostty-vt/include/ghostty/vt/formatter.h`) can emit the
  full active screen (and, depending on options, the historical
  scrollback) as a plain-text buffer. This is one viable path for
  Milestone 2 scrollback search.
  Evidence: `formatter.h:36-49` declares `GHOSTTY_FORMATTER_FORMAT_PLAIN`;
  `formatter.h:200` declares `ghostty_formatter_format_alloc`. The
  formatter walks rows internally without exposing the per-row pin pain
  that `ghostty_terminal_grid_ref` warns about.
- Observation: Capture replay must understand find actions, because find
  rectangles are generated from app state and are not implied by replaying
  PTY output.
  Evidence: The first `scripts/test-e2e` run after adding find to the capture
  window failed terminal replay on frames 3 and 4 with `frameCommandsHash`
  mismatches while renderer replay passed. Adding replay handling for
  `find.start`, `find.step`, and `find.stop` fixed the mismatch, and the
  subsequent `scripts/test-e2e` run exited 0.
- Observation: The M4 direct C scan removes Swift search from the cold
  first-search profile but does not remove the dominant formatter cost.
  Evidence: `find.start lines=10000` improved from about `2.394ms` to
  `2.122ms` mean in the release harness. A sampled cold loop showed
  `Session.findMatchesInScrollback` calling
  `laban_session_find_matches_alloc`, with the dominant stack still inside
  `ghostty_formatter_format_alloc` and `terminal.formatter.PageListFormatter`.
  No `TerminalFind.search` samples appeared in that cold loop.

## Review Gate

A separate fresh-state agent must verify the checks below after each
milestone is reported complete. Items are mechanical: each names a
specific file, command, or grep. The executing agent must not mark the
plan as done until all items pass for the milestone under review.

Milestone 1 (Viewport Find):

- [x] `grep -nE 'find_match|findMatch|findSelected' schemas/debug/frame-commands.schema.json`
  returns at least one match for `findMatch` and one for `findSelected`.
- [x] `grep -nE 'find/(start|step|stop|state)' Sources/LabanDebug/DebugHTTPServer.swift`
  returns four entries, one per route.
- [x] Running `./scripts/test` from the repository root exits 0 with the
  new tests included. (`scripts/test` is a thin wrapper that runs
  `swift test` from the repo root; verified 2026-05-14.)
- [x] `curl -s -H "Authorization: Bearer $TOKEN"
  -X POST -d '{"needle":"hello"}' "http://localhost:$PORT/debug/find/start"`
  on a fixture session whose scrollback contains "hello world" returns
  HTTP 200 and a body whose JSON has `total >= 1`.
- [x] `grep -nE 'placeholder-text|Find' Sources/LabanApp/*.swift` returns at
  least one entry that maps to the find chip text input placeholder.
- [x] The fresh agent runs the project headlessly (`./scripts/test-e2e` or
  equivalent), starts a find with needle `apple`, and observes the
  resulting screenshot diff includes at least one yellow-tinted rectangle.

Milestone 2 (Scrollback Find):

- [x] `grep -nE 'laban_session_scrollback_extract|scrollback_search'
  Sources/LabanTerminalCore/include/LabanTerminalCore.h` returns at
  least one entry.
- [x] In a fixture session populated with 200 lines of test data, running
  the debug `find/start` action with a needle present only at line 5 of
  scrollback returns `total >= 1` and a subsequent `find/step` action
  scrolls the viewport so the match becomes visible.

Milestone 3 (Polish):

- [x] Terminal fixture `fixtures/find-viewport.json` exists and parses as
  JSON. Running `./scripts/test-e2e` records a capture whose frame-command
  sidecars include `findSelected`, and `./scripts/replay-capture` passes
  on that capture.
- [x] `grep -nE 'AXSearchField|isAccessibilityElement' Sources/LabanApp/*.swift`
  returns evidence that the chip text input is accessible.

Review status: PASSED 2026-05-14 by fresh-state reviewer agent `Gauss`
(`019e284d-1e92-7ce0-a7cd-514ea70f4488`). The reviewer edited no files.

Reviewer evidence:

- `schemas/debug/frame-commands.schema.json` contains both `findMatch`
  and `findSelected`.
- `Sources/LabanDebug/DebugHTTPServer.swift` exposes all four
  `/debug/find/*` routes.
- `rtk ./scripts/test` exited 0: 480 tests executed, 2 skipped, 0 failures.
- Live curl check for `hello` returned HTTP 200 with `total=2`.
- `Sources/LabanApp/TerminalFindChipView.swift` contains
  `searchField.placeholderString = "Find…"` and accessibility label
  `"Find"`.
- `rtk ./scripts/test-e2e` exited 0. The reviewer inspected the script's
  `apple` find flow, yellow pixel probe, `findSelected` sidecar check, and
  replay invocation.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` exposes
  `laban_session_scrollback_extract_size` and
  `laban_session_scrollback_extract`.
- Live 200-line CRLF scrollback check returned `total=1`; `find/step`
  kept `selectedIndex=0`, and `/debug/wait` reported the needle visible.
- `fixtures/find-viewport.json` exists and parses as JSON.
- `Sources/LabanApp/TerminalFindChipView.swift` sets raw
  `AXSearchField` accessibility role.

## Outcomes & Retrospective

As of 2026-05-15, the `cmd_f` worktree contains an end-to-end implementation:
Command-F opens the AppKit chip, debug endpoints drive the same model state,
find highlights render as `findMatch`/`findSelected`, scrollback search uses
caller-owned C extraction buffers, and capture/replay can reproduce frames that
contain find highlights.

M4 added `laban_session_find_matches_alloc` to `LabanTerminalCore`, exposed
it through `Session.findMatchesInScrollback`, and routed full-history
`AppModel` find refreshes through that fast path before the existing
scrollback-block fallback. The fast path is intentionally ASCII-only. If the
needle or any selected row contains non-ASCII bytes, it reports an incomplete
result so Swift falls back to the existing `ScrollbackBlock` search and
preserves current Unicode column mapping.

The feature was merged and pushed to `origin/main` at merge commit `136bcac`.
After merge, a tracked performance guard was added as `scripts/test-find-perf`
and `find-perf`. The guard runs the release-mode fixture benchmark that was
previously ad hoc under `.tmp/find-perf`, prints cold and cached timings, and
fails only on generous thresholds intended to catch large regressions without
making normal CI noisy.

Validation run by the executing agent:

```text
rtk ./scripts/test
  Executed 488 tests, with 2 tests skipped and 0 failures.

rtk ./scripts/test-e2e
  test-e2e passed

rtk swift test --filter TerminalFind
  Executed 21 tests, with 0 failures.

rtk swift run -c release --package-path .tmp/find-perf find-perf
  find.start lines=10000 mean=2.122ms p95=2.206ms
  find.step lines=10000 mean=0.003ms p95=0.008ms

rtk ./scripts/test-find-perf
  find performance guard passed

rtk git diff --check
rtk ./scripts/check-docs
rtk ./scripts/check-debug-contract
rtk ./scripts/lint
rtk proxy sh -c 'find schemas fixtures -name "*.json" -print0 | xargs -0 -n1 jq empty'
  all exited 0

rtk ./scripts/check
  check passed
```

The Review Gate passed on 2026-05-14 via a separate fresh-state reviewer
agent. That reviewer independently ran the mechanical checks, live curl
find probes, `rtk ./scripts/test`, and `rtk ./scripts/test-e2e`.

## Context and Orientation

Laban's terminal core is a small C library, `LabanTerminalCore`, that wraps
libghostty-vt's C ABI behind a flat `LabanSession` handle. The relevant
files in this repo:

- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` — the public C
  ABI. `LabanSession` opaque handle; `LabanSnapshot` materialised cell
  grid; `laban_session_create/destroy/resize/poll/snapshot/...` functions.
  The snapshot covers the *visible viewport only* (rows × cols cells),
  plus `utf8_storage` holding the UTF-8 bytes for cells with multi-byte
  graphemes, plus per-row dirty flags. This plan adds
  `laban_session_scrollback_extract_size` and
  `laban_session_scrollback_extract` so Swift can copy a bounded plain-text
  scrollback block through caller-owned buffers.
- `Sources/LabanTerminalCore/snapshot.c` — builds `LabanSnapshot` from
  libghostty-vt's render state. Uses
  `ghostty_render_state_row_iterator_*` to walk visible rows.
- `Sources/LabanTerminalCore/session_lifecycle.c` — owns the
  `LabanSession` (terminal handle, render state, PTY, capture state).
- `Sources/LabanCore/Session.swift` — Swift wrapper around `LabanSession`.
  Used by `AppModel`. Exposes typed Swift methods that call into the C
  ABI.
- `Sources/LabanCore/AppModel.swift` — top-level app state. Owns the
  `Tab` array, the selected tab, the session registry, and frame
  production scheduling.
- `Sources/LabanCore/FrameProducer.swift` — produces `FrameCommand`
  values consumed by the Metal and software renderers. This is where the
  selection highlight is emitted today; find highlights must plug in
  beside it.
- `Sources/LabanApp/TerminalBitmapView.swift` — the AppKit `NSView` that
  hosts the terminal. ~2300 lines. Owns Command-key shortcuts (selection
  copy/paste, Cmd-T new tab, etc.), mouse routing, scroll, IME input.
  Command-F lives here.
- `Sources/LabanApp/MenuCommands.swift` — top-level menu items including
  Edit menu. Add an "Edit › Find…" item here that emits the same action
  as Command-F.
- `Sources/LabanDebug/DebugHTTPServer.swift` — the headless debug HTTP
  server. `routes` table at line 78. Each route delegates to a function
  in one of the `Debug*Endpoints.swift` files.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` — owns the same state
  the AppKit window owns, but for headless mode. Find state must live
  here too.
- `schemas/debug/` — JSON schemas for the debug protocol. `action.schema.json`
  lists every action verb; `frame-commands.schema.json` lists every
  emitted frame command shape; `state.schema.json` describes what
  `/debug/state` returns. Find adds entries to all three.

The libghostty-vt vendored library is at `.external/libghostty-vt/`. The
relevant public C surfaces for this plan:

- `.external/libghostty-vt/include/ghostty/vt/render.h` — `GhosttyRenderState`
  and its row iterator. Already used by `snapshot.c`.
- `.external/libghostty-vt/include/ghostty/vt/terminal.h:1063` —
  `ghostty_terminal_grid_ref(terminal, point, &out_ref)`. Accepts a
  `GhosttyPoint` whose tag is one of `ACTIVE`, `VIEWPORT`, `SCREEN`,
  `HISTORY`. Returns a `GhosttyGridRef` valid only until the next
  terminal mutation.
- `.external/libghostty-vt/include/ghostty/vt/point.h` — `GhosttyPoint`
  with the four coordinate tags and a coordinate struct (`x: uint16_t,
  y: uint32_t`).
- `.external/libghostty-vt/include/ghostty/vt/grid_ref.h` — `GhosttyGridRef`
  plus `ghostty_grid_ref_cell`, `ghostty_grid_ref_row`,
  `ghostty_grid_ref_graphemes` (returns the grapheme codepoints at a
  cell), `ghostty_grid_ref_hyperlink_uri`, `ghostty_grid_ref_style`.
- `.external/libghostty-vt/include/ghostty/vt/terminal.h:702-709` —
  `GHOSTTY_TERMINAL_DATA_TOTAL_ROWS` and
  `GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS` accessible via
  `ghostty_terminal_get`. Together these bound the scrollback range.
- `.external/libghostty-vt/include/ghostty/vt/formatter.h:150-203` —
  `ghostty_formatter_terminal_new` + `ghostty_formatter_format_alloc`.
  Produces a plain-text buffer of the current screen (the *active*
  screen, which means viewport plus scrollback for normal-buffer
  sessions; alt-buffer sessions yield only the alt screen). One call
  returns the whole text; rows are separated by `\n`.

Architectural map for find:

```text
                  ┌──────────────────────────────────┐
                  │ AppKit chip view (overlay)       │
                  │   text input, counter, buttons   │
                  └─────────────────┬────────────────┘
                                    │ needle, step, stop
                                    ▼
   ┌─────────────────────────────────────────────────┐
   │ Find engine (Swift, in LabanCore/TerminalFind…) │
   │   - run literal substring on viewport (M1)      │
   │   - run substring on scrollback (M2)            │
   │   - hold matches[], selectedIndex               │
   └──────────────┬─────────────────────────┬────────┘
                  │                         │
   LabanSnapshot  │                         │  laban_session_scrollback_extract (M2)
                  │                         │
                  ▼                         ▼
        ┌─────────────────────┐   ┌──────────────────────┐
        │ LabanTerminalCore   │   │ libghostty-vt        │
        │ (existing snapshot) │   │ (formatter for M2)   │
        └─────────────────────┘   └──────────────────────┘
```

Frame production maps the engine's `matches[]` and `selectedIndex` into
two new frame-command shapes: `findMatch` (one rectangle per match in
the viewport) and `findSelected` (one rectangle for the selected match
when it is in the viewport). The renderer paints these between the cell
background pass and the glyph pass, the same way selection is painted
today.

## Plan of Work

The work is divided into three milestones. Each milestone leaves the
repository in a runnable state with passing tests.

### Milestone 1 — Viewport Find

#### M1.1: Add the Swift-side substring matcher

Create `Sources/LabanCore/TerminalFind.swift` containing:

```swift
public struct TerminalFindMatch: Equatable, Sendable {
  public let row: Int           // 0-indexed terminal row in the snapshot
  public let startColumn: Int   // inclusive
  public let endColumn: Int     // exclusive
}

public enum TerminalFindCaseMode: Sendable {
  case smart   // case-sensitive iff needle has any uppercase ASCII
  case literal // case-sensitive always
}

public enum TerminalFind {
  public static func search(
    needle: String,
    inSnapshot snapshot: UnsafePointer<LabanSnapshot>,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch] {
    // 1. Empty needle returns [].
    // 2. Decide ASCII fold: fold iff caseMode == .smart && needle has
    //    no uppercase ASCII characters in [A-Z].
    // 3. Do NOT use Swift's `.caseInsensitive` string option, which
    //    applies full Unicode case folding (Turkish I, German ß,
    //    Greek sigma, etc.). The libghostty-vt matcher this code
    //    mirrors does ASCII-only folding
    //    (`std.ascii.indexOfIgnoreCase`), and any future migration to
    //    the upstream engine must keep the same observable behavior.
    // 4. Implement the matcher as a manual byte/grapheme scan: when
    //    folding, both needle and haystack are lowercased only on
    //    ASCII bytes in [A-Z] (subtract 0x20); all other bytes pass
    //    through unchanged. Compare byte-for-byte.
    // 5. For each row 0..<snapshot.rows, build a row buffer of UTF-8
    //    bytes plus a parallel per-byte column map (so a multi-byte
    //    grapheme contributes N bytes but a single column entry).
    //    Skip cells with wide == LABAN_CELL_WIDE_SPACER_TAIL — they
    //    are the right half of a wide character and have no text.
    // 6. Convert each match's byte range back to a column range via
    //    the column map.
    // 7. Soft-wrapped rows are NOT joined for v1 — a needle that
    //    spans a wrap will not match. Document this in the function
    //    header.
    return []
  }
}
```

`LabanSnapshot` is the C struct defined in
`Sources/LabanTerminalCore/include/LabanTerminalCore.h:98-130`. Swift
accesses it through `UnsafePointer<LabanSnapshot>` produced by
`Session.snapshot()` (see `Sources/LabanCore/Session.swift:212-215`).
Cell data lives in `snapshot.pointee.cells` (a `LabanCell` array of
length `rows * cols`); per-cell graphemes are reconstructed from
`utf8_storage[utf8_offset ..< utf8_offset + utf8_length]`. Build any
helpers needed for ergonomic access (per-row substrings, per-cell
column maps) inside `TerminalFind.swift` rather than mutating
`Session.swift`'s public surface.

Add `Tests/LabanCoreTests/TerminalFindTests.swift` with at least:

- empty needle returns no matches
- single-row match at the start of the row
- two non-overlapping matches on the same row
- case-insensitive match when needle is all lowercase
- case-sensitive match when needle has uppercase
- wide-character row: needle that overlaps a wide cell finds it
- a soft-wrapped match across rows is NOT found (documents the v1 limit)
- no false positives on cells with `LABAN_CELL_FLAG_INVISIBLE` (skip
  invisible cells from the row string)

#### M1.2: Add the Find state object

Add a `Find` value type to `Sources/LabanCore/AppModel.swift` (or split
into `Sources/LabanCore/TerminalFindState.swift` if AppModel is already
crowded — at the time of writing AppModel is 18 KB; split):

```swift
public struct TerminalFindState: Equatable, Sendable {
  public var isActive: Bool
  public var needle: String
  public var matches: [TerminalFindMatch]
  public var selectedIndex: Int?  // nil when matches.isEmpty

  // Viewport scroll offset (in scrollback rows) at the moment find
  // opened. Restored when find exits via Escape or stop. nil means
  // "no restore on exit" (e.g., after a resize that invalidated the
  // saved position).
  public var viewportScrollOffsetAtStart: Int?

  public static let inactive = TerminalFindState(
    isActive: false, needle: "", matches: [],
    selectedIndex: nil, viewportScrollOffsetAtStart: nil)
}
```

Add a `findStateBySession: [Session.ID: TerminalFindState]` map on
`AppModel`, sibling to `selectionBySession`. Update mutators that change
session state (resize, snapshot refresh, output drain) to call
`refreshFind(for:)` which re-runs the search with the current needle
against the latest snapshot. After refresh:

- If `matches.isEmpty`, set `selectedIndex = nil`.
- Otherwise, try to keep the previously-selected match identity. Match
  identity for refresh is `(row, startColumn)`. If the previous identity
  is still present in the new `matches`, keep that index; otherwise pick
  the match closest to the previous identity by row distance.

Expose `AppModel.startFind(sessionID:needle:)`,
`AppModel.stepFind(sessionID:direction:)`,
`AppModel.stopFind(sessionID:)`, and
`AppModel.updateFindNeedle(sessionID:needle:)`.

`direction` is `.next` or `.previous`. Stepping wraps: stepping `.next`
past the last match returns to the first; `.previous` past the first
returns to the last.

`startFind` records the current viewport scroll offset (from
`laban_session_viewport_state`) into
`TerminalFindState.viewportScrollOffsetAtStart`. `stopFind` restores
the viewport scroll offset to that recorded value via
`laban_session_scroll_viewport` before resetting `TerminalFindState`.
If the viewport's row count has changed since `startFind` (window
resize), skip the restore and leave `viewportScrollOffsetAtStart =
nil`. Add a `TerminalFindStateTests` case that asserts the restore
happens on stop after a step that scrolled the viewport.

Tests: extend `Tests/LabanCoreTests/AppModelTests.swift` (or create
`TerminalFindStateTests.swift` if no AppModel tests exist for this
area).

#### M1.3: Render find rectangles via the FrameCommand pipeline

`FrameCommand` is the renderer's pixel-level command language, defined
in `Sources/LabanRenderer/FrameCommand.swift:98-115`. Commands carry
`CGRect` geometry in pixel coordinates, not row/column logical
coordinates. Existing precedent: selection is its own case,
`case selection(CGRect, color: UInt32)`. Mirror that pattern for find.

Add two cases to the `FrameCommand` enum in
`Sources/LabanRenderer/FrameCommand.swift`:

```swift
case findMatch(CGRect, color: UInt32)
case findSelected(CGRect, color: UInt32)
```

Add a new case to the `FrameSource` enum at
`Sources/LabanRenderer/FrameCommand.swift:3-9`:

```swift
case find
```

In `Sources/LabanCore/FrameProducer.swift`, extend the snapshot →
commands transform to accept a `TerminalFindState` for the active
session (alongside the existing `selectionBySession` parameter —
see how selection is plumbed through `commands(from:selection:)` and
mirror it). For each match in the current viewport rows, compute the
pixel `CGRect` from (row, startColumn, endColumn) using the same
`cellWidth`/`cellHeight` math used for selection, then emit:

1. cell backgrounds (existing)
2. `selection(CGRect, color:)` (existing)
3. `findMatch(CGRect, color:)` for every match in the viewport that
   is not the selected one
4. `findSelected(CGRect, color:)` for the selected match if it lies
   in the viewport
5. glyphs (existing)
6. `cursor(CGRect, color:)` (existing)

Render-backend updates: extend both renderers in
`Sources/LabanRenderer/` (the software backend in
`SoftwareFrameRenderer.swift` or similar — locate by grepping
`case .selection` and matching the file) to draw the two new cases.
The drawing is the same alpha-blended fill as selection, just with
a different color.

Colors — Selenized Light has a defined palette; look up the yellow in
`Sources/LabanCore/ThemePaletteInjector.swift`. Use the standard
yellow at ~30 % alpha for `findMatch` and the bright yellow at
~70 % alpha for `findSelected`, both distinct from selection blue.
Exact RGBA values are not load-bearing; pick concrete numbers during
implementation and record them in the *Decision Log* only if the
choice ended up being contentious.

Serializer: extend
`Sources/LabanDebug/DebugFrameCommandSerializer.swift` (see line 14
for the dispatch). Add cases mirroring `.selection`'s shape:

```swift
case .findMatch(let rect, let color):
  return FrameCommandResponse(
    id: id, index: index, kind: "findMatch", source: "find",
    rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
case .findSelected(let rect, let color):
  return FrameCommandResponse(
    id: id, index: index, kind: "findSelected", source: "find",
    rect: Self.rectResponse(rect), color: Self.rgbaArray(color))
```

Apply the same change to `traceCommand` farther down in that file.

Schema: add `findMatch` and `findSelected` `kind` values to
`schemas/debug/frame-commands.schema.json`, matching the shape of
the existing `selection` entry (a `rect` plus an optional `color`).

Tests: extend `Tests/LabanCoreTests/FrameProducerTests.swift` (or
equivalent) with a test that constructs a snapshot containing the
needle, starts find, and asserts the emitted command list contains the
expected number of `findMatch` plus one `findSelected`.

#### M1.4: Add the AppKit chip view

Create `Sources/LabanApp/TerminalFindChipView.swift`. The chip is an
`NSView` subclass containing:

- An `NSTextField` for needle input. Placeholder `"Find…"`. Becomes
  first responder when the chip opens.
- An `NSTextField` (label, non-editable) showing `"\(selected+1)/\(total)"`
  when matches exist, `"0/0"` when needle is non-empty but matches are
  zero, and empty when needle is empty.
- Two `NSButton`s — up (previous) and down (next). Use SF Symbols
  `chevron.up` and `chevron.down`. Disabled when matches are empty.
- A close `NSButton` with `xmark` SF Symbol.

Layout: horizontal stack, fixed height ~28 pt, anchored 8 pt from the
top edge and 8 pt from the trailing edge of the terminal viewport.
Z-order above the terminal content but below any system overlays.

Wire `TerminalBitmapView` (the host view) to:

- Intercept Command-F when the terminal is the first responder. If find
  is not active, open the chip and make its text field first responder;
  if find is active and the chip is open, re-focus the text field and
  select-all its contents (so a second Command-F lets the user type a
  new needle without manually clearing).
- Intercept Escape inside the chip's text field (via `NSTextFieldDelegate.control(_:textView:doCommandBy:)`)
  to dismiss the chip. Dismiss calls `AppModel.stopFind(sessionID:)`,
  which restores the viewport scroll offset recorded at find open
  (see M1.2).
- Intercept Return / Shift+Return inside the chip's text field to call
  `stepFind(.next)` / `stepFind(.previous)`.
- On text-field changes (`controlTextDidChange`), call
  `updateFindNeedle`.

Add an `Edit › Find…` menu item in `Sources/LabanApp/MenuCommands.swift`
bound to the same action.

When find is active and the chip is open, **do not** forward Command-F
to the terminal as raw input (Command-F is already swallowed by the app
shortcut path; verify this in `keyDown(with:)` in `TerminalBitmapView`).

Tests: AppKit tests are not part of the project's CI per
`docs/process/dev-process.md` — verify by running the headless harness
through the debug endpoints in M1.5.

#### M1.5: Add debug HTTP endpoints

Add `Sources/LabanDebug/DebugFindEndpoints.swift` and
`Sources/LabanDebug/DebugFindActions.swift` (mirror the pattern from
`DebugSelectionEndpoints.swift` and `DebugSelectionActions.swift`).
Routes:

- `POST /debug/find/start` with body `{"sessionID": "…", "needle": "hello"}`
  → 200 `{"total": N, "selected": 0|null, "matches": [{"row":…,
  "startColumn":…, "endColumn":…}, …]}`. Begins find on the named
  session.
- `POST /debug/find/step` with body `{"sessionID": "…", "direction":
  "next"|"previous"}` → 200 with updated state.
- `POST /debug/find/stop` with body `{"sessionID": "…"}` → 200
  `{"stopped": true}`.
- `GET /debug/find/state?sessionID=…` → 200 with the current state.

Register the routes in `DebugHTTPServer.swift`'s `routes` table (line
78 at the time of writing — append, do not reorder).

Add `find.start`, `find.step`, `find.stop` action variants to
`schemas/debug/action.schema.json`. Add `find.state` to the
discoverable state in `schemas/debug/state.schema.json` if a session's
find state should be observable via `/debug/state` (recommended:
include it so capture/replay snapshots cover find state automatically).

Wire `HeadlessDebugRuntime` to call the same `AppModel` methods so the
GUI and headless paths share one implementation.

Tests: add `Tests/LabanDebugTests/FindEndpointsTests.swift`
covering:

- start with a needle present in a fixture session returns the expected
  matches
- step `.next` and `.previous` walk and wrap correctly
- stop clears the state and the next `/debug/find/state` returns
  `{"isActive": false, …}`
- start with empty needle is rejected with HTTP 400 and a JSON error
- start on a non-existent session returns HTTP 404

#### M1.6: End-to-end fixture

Add `fixtures/find-viewport/` containing a small PTY-output capture
that writes a known multi-line string (e.g., `apple\nbanana\napple
pie\n`). Wire it into `scripts/test-e2e` (or whichever script the repo
uses for end-to-end tests — read the script first; the repo has both
`scripts/build-app` and references to `scripts/test-e2e` in other
plans). The E2E asserts:

1. `/debug/find/start` with needle `apple` returns `total: 2`.
2. After stepping, `/debug/state` reports `selectedIndex: 1`.
3. The frame-command stream for the current frame includes exactly two
   `findMatch` rectangles (or one `findMatch` plus one `findSelected`,
   depending on whether `findSelected` is emitted separately — confirm
   the chosen convention during M1.3).
4. A screenshot diff against a checked-in golden shows the yellow
   highlight rectangles. The golden is produced by the capture/replay
   harness during the fixture run; this repository does not currently
   expose a dedicated "regenerate goldens" flag. Follow the capture
   pattern already used by the `colored-boxes` fixture in
   `scripts/test-e2e` (around line 87 at the time of writing) and any
   helper code in `Sources/LabanDebug/CaptureRecorder.swift` /
   `CaptureReplayRunner.swift`.

### Milestone 2 — Scrollback Find

#### M2.1: Add scrollback extraction to the C ABI

Extend `Sources/LabanTerminalCore/include/LabanTerminalCore.h` with
a caller-allocated extraction API. The session must not retain any
output buffer across calls, because a background reader thread
(`Sources/LabanCore/SessionRunner.swift:69-80`, `laban.session.reader`
thread running `laban_session_poll_blocking`) can invalidate
session-owned storage between the call returning and Swift copying
the bytes. Caller-allocated buffers fix the race entirely.

```c
/* Probe sizes for a scrollback extraction without copying any bytes.
 *
 * On success, *out_rows is the number of rows that would be returned
 * for the given [row_offset, row_offset+max_rows) range, and
 * *out_text_capacity is the number of UTF-8 bytes (including '\n'
 * separators and a trailing NUL) the caller must allocate to receive
 * them. Both pointers must be non-NULL. Holds the session lock
 * during the probe. Returns 0 on success, -1 on error.
 */
int laban_session_scrollback_extract_size(
    LabanSession *session,
    size_t row_offset,
    size_t max_rows,
    size_t *out_rows,
    size_t *out_text_capacity);

/* Extract a contiguous block of scrollback as plain text.
 *
 * The caller pre-allocates two buffers sized using
 * laban_session_scrollback_extract_size: `text_buffer` of length
 * `text_capacity` bytes, and `row_offsets` of length
 * `row_offsets_capacity` entries (one per row to be returned).
 *
 * On success, the call holds the session lock for the duration of the
 * copy, writes a NUL-terminated UTF-8 string into `text_buffer` (rows
 * separated by '\n'), writes one entry per row into `row_offsets`
 * holding that row's byte offset within `text_buffer`, and reports
 * the actual counts via *out_rows and *out_text_len. The buffers are
 * fully owned by the caller and remain valid regardless of background
 * session activity.
 *
 * Returns 0 on success. Returns 1 if either buffer is too small,
 * setting *out_required_text_capacity and *out_required_row_offsets
 * to the actual required sizes. Returns -1 on permanent error.
 */
int laban_session_scrollback_extract(
    LabanSession *session,
    size_t row_offset,
    size_t max_rows,
    char *text_buffer,
    size_t text_capacity,
    uint32_t *row_offsets,
    size_t row_offsets_capacity,
    size_t *out_rows,
    size_t *out_text_len,
    size_t *out_required_text_capacity,
    size_t *out_required_row_offsets);
```

The two-call probe-then-extract pattern matches `laban_session_encode_paste`
and `laban_session_send_key_encoded` in the existing C ABI, which
also use "GHOSTTY_OUT_OF_SPACE-style" return values. The Swift
wrapper hides the two calls behind a single method that allocates a
`Data` and `[UInt32]`, retries once if the size grew between probe
and extract, and returns owned Swift values to the find engine.

Implementation in a new file
`Sources/LabanTerminalCore/scrollback_extract.c`. Strategy:

- Use `ghostty_terminal_get` with
  `GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS` and
  `GHOSTTY_TERMINAL_DATA_TOTAL_ROWS` to determine the available range.
- Iterate rows using `ghostty_terminal_grid_ref` with
  `GHOSTTY_POINT_TAG_HISTORY` for the scrollback portion and
  `GHOSTTY_POINT_TAG_ACTIVE` for the visible portion (so the API can
  cover both in a single call).
- For each row, walk cells via `ghostty_grid_ref_cell` and emit
  graphemes. Append `\n` between rows. Skip
  `GHOSTTY_CELL_WIDE_SPACER_TAIL` cells.
- The buffer is owned by the session (allocate inside the
  `LabanSession` struct and reuse across calls).

Performance note: `ghostty_terminal.h:1045-1048` warns that screen and
history tags may require traversing the page list per point. To avoid
O(N²) behaviour, resolve the start point once and then advance via
`ghostty_grid_ref_row` after a single `grid_ref` lookup per page, not
per row. Implementation detail — measure during work and add a
*Surprises & Discoveries* entry if the simple path is too slow.

Alternative path: use `ghostty_formatter_terminal_new` +
`ghostty_formatter_format_alloc` with `GHOSTTY_FORMATTER_FORMAT_PLAIN`
to get the whole screen in one call. Evaluate during implementation;
the formatter likely handles the page traversal more cheaply because
it iterates internally.

#### M2.2: Extend the Swift Find engine to scan scrollback

Update `TerminalFind.search` (or add `searchScrollback`) to accept a
scrollback text block plus row offsets. Match results carry a global
row index: scrollback rows 0..S-1 followed by viewport rows
S..S+R-1, where S is `scrollbackRows` and R is `rows`.

Update `FrameProducer` to translate global row indices into viewport
y-coordinates. A match at global row `i` is in the current viewport iff
`scrollOffsetRows <= i < scrollOffsetRows + R`. `scrollOffsetRows`
comes from `LabanViewportState.history_row_offset` (verify the field
name — `laban_session_viewport_state` exists per
`LabanTerminalCore.h:294`).

#### M2.2b: Bound the refresh cost on streaming output

Re-running scrollback search on every output drain is fine for typing
but a perf cliff when find stays open during a `tail -f`, a verbose
build, or any other streaming workload. Adopt this refresh policy:

- **Active-area-only refresh** runs whenever a session's snapshot
  becomes dirty (driven by `laban_session_render_dirty`). It rescans
  only the visible viewport via the M1 path and updates match indices
  in the viewport range.
- **Full scrollback refresh** runs only on three triggers: (a) the
  user changes the needle, (b) the user presses Enter/Shift+Enter to
  step, (c) the find is being newly opened. Streaming output does not
  trigger a scrollback rescan; new lines arriving after find opened
  are searched as they become part of the active area, then as they
  scroll into history they are *not* re-discovered until the next
  step or needle change.
- **Integration point**: refresh is triggered from
  `AppModel.applyPendingSnapshot(sessionID:)` (or whichever AppModel
  method already handles "session snapshot changed" — read
  `AppModel.swift` to find the actual entry point and reuse it). Do
  not refresh from `Session`'s drain loop directly: that runs on a
  background poll thread (`laban_session_poll_blocking`, see
  `LabanTerminalCore.h:142-153`) and find state lives on the main
  thread alongside `AppModel`.

Document this policy in the *Decision Log* as a v1 tradeoff (a streaming
needle that appears only in scrollback after find opens will not show
up until the user steps; acceptable for v1, fixable later by adding a
"new history" event from the C ABI).

#### M2.3: Scroll-to-match on selection

In `AppModel.stepFind(...)`, after picking the new `selectedIndex`,
check whether the selected match's global row is within the current
viewport. If not, scroll the viewport so the match's row is centered
(or at one-third from the top — match iTerm's heuristic) and refresh
the snapshot. Scroll uses the existing
`laban_session_scroll_viewport(session, delta_rows)` API (see
`LabanTerminalCore.h:293`).

Tests: extend the E2E from M1.6 with a needle that exists only in
scrollback, then assert that stepping causes the viewport to scroll
(observable via `/debug/state` reporting a non-zero scrollback offset).

### Milestone 3 — Polish

#### M3.1: Drag-to-reposition the chip

Add an `NSGestureRecognizer` (drag) to `TerminalFindChipView` so the
user can move the chip if it covers important terminal content. Persist
the chip position in `UserDefaults` keyed by something simple like
`"FindChipOriginFraction"` (a `CGPoint` of fractions in the viewport
rect, so resize keeps the chip in roughly the same relative place).
Snap to the nearest corner when dropped within ~20 pt of one — the
default is top-right.

#### M3.2: Accessibility

The chip's text field receives an accessibility role of
`NSAccessibility.Role.searchField`. The match counter exposes a value
description ("12 of 47"). The prev/next buttons have accessibility
labels "Previous Match" / "Next Match".

#### M3.3: Capture/replay coverage

Add fixtures under `fixtures/find-*/` that exercise:

- viewport find with one match
- viewport find with many matches
- scrollback find that triggers a scroll
- find with a needle that wraps across a soft-wrap (asserts the
  documented v1 limitation: no match)

Each fixture has a deterministic recorded byte stream and a checked-in
JSON of expected frame commands plus a PNG golden.

#### M3.4: Spec and ADR

Add a "Find" subsection to `docs/product/spec.md` describing the v1
behavior and the deferred features (regex, Unicode case folding,
pinned anchors, workspace search, OSC 133 block grouping, threaded
search).

Decide whether to write an ADR for "find uses laban-side snapshot scan,
not libghostty-vt's ScreenSearch engine, until C ABI bindings exist
upstream." If yes, follow the pattern of `docs/adr/0001-…` /
`docs/adr/0002-…` and add a one-line entry in `AGENTS.md` under
*Decision Index*.

## Concrete Steps

These commands assume the working directory is the repository root
(`/Users/rrj/wrk/laban` for the original author; any clone path is
fine). All commands are idempotent.

Build the app once to confirm the baseline compiles:

```sh
./scripts/build-app
```

Expected: `.build/laban/Laban.app` exists with no compiler errors
(path defined at `scripts/build-app:50`). If the build fails because
`.external/` is missing in a worktree, follow the worktree setup
instructions in `AGENTS.md` (symlink `.external` from the main
checkout).

Run the unit test suite to confirm the baseline passes:

```sh
./scripts/test
```

`scripts/test` is a wrapper that runs `swift test` from the repo
root. Expected: all tests pass. Record the count for diffing later.

Implement Milestone 1 in commits (one per sub-milestone is reasonable;
commit messages follow `AGENTS.md` *Hard Rules* — reason statements,
not "what" statements). After each commit, re-run `swift test` and
confirm the new tests added by that sub-milestone pass.

When M1 is complete, run the headless smoke:

```sh
./scripts/test-e2e
```

Expected: existing E2E tests plus the new `find-viewport` fixture pass.

When M2 is complete:

```sh
./scripts/test-e2e
```

Expected: existing E2E tests plus the new scrollback fixture pass. The
scrollback fixture's recorded frame-command stream demonstrates a
viewport scroll triggered by `find/step`.

When M3 is complete, inspect fixture artifacts for unintended drift:

```sh
./scripts/test-e2e
git status fixtures/
git diff fixtures/
```

This repository does not currently expose an explicit
"regenerate goldens" flag; fixtures and any checked-in screenshots
under `fixtures/` are produced by the capture/replay harness. If a
rendering tweak intentionally changes existing fixtures, the
implementer updates them by re-running the capturing flow and
inspecting `git diff fixtures/` before committing. Confirm during
implementation by reading `scripts/test-e2e` and the capture/replay
sources in `Sources/LabanDebug/CaptureRecorder.swift` and
`Sources/LabanDebug/CaptureReplayRunner.swift`; if a flag is
introduced as part of this work, record it in *Surprises &
Discoveries* and update this section.

## Validation and Acceptance

Acceptance is observable user behavior, not internal attributes.

**Viewport (M1):**

1. Launch the app with `./scripts/build-app && open .build/laban/Laban.app`
   (or the equivalent local invocation).
2. In an active terminal tab, run `echo "apple banana apple pie"` and
   press **Command-F**.
3. The find chip appears at the top-right of the terminal viewport.
   Its text field has focus.
4. Type `apple`. Two yellow highlight rectangles appear over the two
   occurrences of "apple". The counter reads `1/2`. The first match
   has the stronger (selected) highlight.
5. Press **Return**. The counter advances to `2/2` and the selected
   highlight moves to the second occurrence.
6. Press **Shift+Return**. The counter goes back to `1/2`.
7. Press **Escape**. The chip closes; all highlights disappear; the
   terminal is unchanged.
8. Press **Command-F** again. The chip reopens with focus in the text
   field and the previous needle is selected (so typing replaces it).

**Scrollback (M2):**

9. Continuing the same tab, type `for i in $(seq 1 200); do echo
   "line $i"; done` and press Return.
10. Press **Command-F**, type `line 5`. The counter shows the total
    matches (line 5, 50, 51, …, 59, 150…159; the exact total depends
    on the literal substring match). The currently-selected match is
    the most recent — likely "line 199 line 5" in some output not
    relevant here; what matters is that the viewport scrolls to show
    the selected match.
11. Press Shift+Return to step backward to older matches; the viewport
    scrolls up.
12. Press Escape. The viewport restores to its position before find
    opened (record this position when find starts; restore on exit).

**Polish (M3):**

13. Drag the find chip from the top-right to the bottom-left. Release.
    The chip stays there. Close and reopen the app — the chip starts
    in the bottom-left.
14. Use VoiceOver: focus the chip's text field. VoiceOver announces
    "Find, search field".

**Headless / debug:**

15. Start the debug server (the exact command depends on the harness;
    `./scripts/test-e2e` boots it). Curl:

    ```sh
    curl -s -H "Authorization: Bearer $TOKEN" \
      -X POST -d '{"sessionID":"S","needle":"apple"}' \
      http://127.0.0.1:$PORT/debug/find/start | jq .
    ```

    Expected:

    ```json
    {
      "isActive": true,
      "needle": "apple",
      "total": 2,
      "selectedIndex": 0,
      "matches": [
        {"row": 0, "startColumn": 0, "endColumn": 5},
        {"row": 0, "startColumn": 13, "endColumn": 18}
      ]
    }
    ```

16. `GET /debug/find/state?sessionID=S` reflects the same state.

**Unit and integration tests:**

Run `swift test --package-path .` and expect all pre-existing tests to
pass plus:

- `TerminalFindTests` (≥ 8 cases, M1)
- `TerminalFindStateTests` (≥ 4 cases, M1)
- `FrameProducerFindTests` (≥ 2 cases, M1)
- `FindEndpointsTests` in `LabanDebugTests` (≥ 5 cases, M1; ≥ 2
  more for M2)

Each new test must fail before its corresponding implementation and
pass after.

## Idempotence and Recovery

Every step in this plan is additive. If the implementing agent stops
mid-milestone, the repository remains buildable as long as each commit
is itself green. To resume, read `Progress` and continue at the first
unchecked box.

If M2's scrollback extraction proves slower than ~50 ms for 10 000
rows on the developer's machine, escalate by trying the formatter path
(`ghostty_formatter_format_alloc`) instead of grid_ref iteration, and
record the result in *Surprises & Discoveries*. Do not attempt a
threaded fallback within this plan — that is a separate ExecPlan and
crosses a significant architectural line.

To roll back the entire feature: revert the commits touching
`Sources/LabanCore/TerminalFind*`,
`Sources/LabanApp/TerminalFindChipView.swift`,
`Sources/LabanDebug/DebugFind*.swift`,
`Sources/LabanTerminalCore/scrollback_extract.c`, and the schema
additions. Find is fully optional and removing it does not break any
other feature.

## Artifacts and Notes

Sample of the search-overlay UI pattern this plan mirrors, from
`.external/libghostty-vt/src/apprt/gtk/ui/1.2/search-overlay.blp`:

```text
template $GhosttySearchOverlay: Adw.Bin {
  visible: bind template.active;
  halign-target: end;
  valign-target: start;
  …
  SearchEntry search_entry {
    placeholder-text: _("Find…");
    width-chars: 20;
    stop-search => $stop_search();
    search-changed => $search_changed();
    next-match => $next_match();
    previous-match => $previous_match();
  }
  Label { /* match counter "12/47" */ }
  Button prev_button { icon-name: "go-up-symbolic"; … }
  Button next_button { icon-name: "go-down-symbolic"; … }
  Button close_button { icon-name: "window-close-symbolic"; … }
}
```

Sample debug response shape:

```json
{
  "isActive": true,
  "needle": "apple",
  "total": 2,
  "selectedIndex": 1,
  "matches": [
    {"row": 12, "startColumn": 4, "endColumn": 9},
    {"row": 18, "startColumn": 0, "endColumn": 5}
  ]
}
```

`row` is global: scrollback rows come first (indices `0..S-1`),
viewport rows follow (`S..S+R-1`). When the chip is open and a match
scrolls off the top, its row index does not change; only the
viewport's scroll offset does.

## Interfaces and Dependencies

Public Swift API exposed at the end of this plan:

```swift
// In LabanCore
public struct TerminalFindMatch: Equatable, Sendable
public enum TerminalFindCaseMode: Sendable
public enum TerminalFind {
  public static func search(
    needle: String,
    inSnapshot snapshot: UnsafePointer<LabanSnapshot>,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch]

  public static func searchScrollbackAndViewport(  // M2
    needle: String,
    scrollback: ScrollbackBlock,
    viewportSnapshot: UnsafePointer<LabanSnapshot>,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch]
}

public struct TerminalFindState: Equatable, Sendable {
  public var isActive: Bool
  public var needle: String
  public var matches: [TerminalFindMatch]
  public var selectedIndex: Int?
}

extension AppModel {
  public mutating func startFind(sessionID: Session.ID, needle: String)
  public mutating func updateFindNeedle(sessionID: Session.ID, needle: String)
  public mutating func stepFind(sessionID: Session.ID, direction: StepDirection)
  public mutating func stopFind(sessionID: Session.ID)
}
```

Public C ABI added in M2:

```c
int laban_session_scrollback_extract_size(
    LabanSession *session,
    size_t row_offset,
    size_t max_rows,
    size_t *out_rows,
    size_t *out_text_capacity);

int laban_session_scrollback_extract(
    LabanSession *session,
    size_t row_offset,
    size_t max_rows,
    char *text_buffer,
    size_t text_capacity,
    uint32_t *row_offsets,
    size_t row_offsets_capacity,
    size_t *out_rows,
    size_t *out_text_len,
    size_t *out_required_text_capacity,
    size_t *out_required_row_offsets);
```

Both calls take the session lock for the duration of their work and
copy into caller-allocated buffers so the background reader thread
(`Sources/LabanCore/SessionRunner.swift:69-80`) cannot mutate the
underlying scrollback during the read.

Debug HTTP endpoints:

```text
POST /debug/find/start    body: {sessionID, needle}             → 200 TerminalFindState
POST /debug/find/step     body: {sessionID, direction}          → 200 TerminalFindState
POST /debug/find/stop     body: {sessionID}                     → 200 {stopped: true}
GET  /debug/find/state?sessionID=…                              → 200 TerminalFindState
```

Frame commands added (in `Sources/LabanRenderer/FrameCommand.swift`):

```swift
case findMatch(CGRect, color: UInt32)
case findSelected(CGRect, color: UInt32)
```

Plus a new `FrameSource` value: `case find`. Debug serialization
emits `kind: "findMatch"` / `kind: "findSelected"` with
`source: "find"` in `DebugFrameCommandSerializer`.

Schemas updated:

- `schemas/debug/action.schema.json` — add `find.start`, `find.step`,
  `find.stop` action variants.
- `schemas/debug/state.schema.json` — add `findStateBySession` to the
  session state shape.
- `schemas/debug/frame-commands.schema.json` — add `findMatch` and
  `findSelected` command shapes.

External dependencies:

- libghostty-vt's public C ABI for row iteration and (M2) the
  formatter. No modification to `.external/libghostty-vt`.
- AppKit's `NSSearchField` / `NSTextField`, `NSButton`, SF Symbols.
- No new third-party libraries.

Out Of Scope (explicit deferrals; do not implement in this plan):

- Threaded search backed by `Thread.zig` and libxev.
- Regex needles via `re:` prefix or any other syntax.
- Unicode case folding beyond ASCII.
- Pinned anchors (Command-D leaves a marker; Command-] / Command-[ jump
  between them).
- Workspace search across all open tabs (Command-Option-F).
- OSC 133 block grouping ("group results by command output block").
- Action-bearing matches (copy-on-click, open URL, open path,
  copy-git-hash). The chip's close button is the only action; matches
  themselves are inert in v1.
- Persistence of the find needle or chip state across app launches
  beyond the chip-position polish in M3.1.
- Selection integration. Find does not move the selection and does not
  alter clipboard state.
