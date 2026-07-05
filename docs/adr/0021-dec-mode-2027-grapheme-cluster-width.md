# 21. DEC Mode 2027 Grapheme-Cluster Width: Engine Is The Source Of Truth

Date: 2026-06-19

## Status

Accepted.

This decision stays inside the ADR 0001 boundary (libghostty-vt owns VT parsing,
mode state, and the grid). Unlike ADR 0011/0012/0019, it adds **no** vendored
patch and **no** Laban-side responder: the vendored engine already implements DEC
private mode 2027, so this ADR records how Laban *consumes* that capability
coherently and what the app-facing contract is. Implemented by the ExecPlan
`execplans/active/dec-mode-2027-grapheme-cluster-support.md`.

## Context

**DEC private mode 2027** ("grapheme clustering" / "Unicode core" mode) changes how
a terminal computes the *display width* — the number of fixed-width cells — of
complex Unicode text. With the mode OFF (the historical default), width is computed
per Unicode code point (`wcwidth`-style): the farmer emoji `🧑‍🌾`
(U+1F9D1 ZWJ U+1F33E) measures 2+0+2 = 4 cells. With the mode ON, the terminal
segments the stream into UAX #29 extended grapheme clusters and gives each cluster
one width: the farmer is 2 cells. A program enables it with `CSI ? 2027 h`, disables
with `CSI ? 2027 l`, and queries it with the DECRQM request `CSI ? 2027 $ p`
(reply `CSI ? 2027 ; <v> $ y`, `<v>`: 1 set, 2 reset, 3 perm-set, 4 perm-reset).

The mode must be **opt-in**: enabling grapheme clustering unilaterally breaks legacy
apps (the canonical example is `fish`, which assumed `wcwidth` and redrew its prompt
in the wrong place when a terminal silently switched). Programs and terminals
negotiate via DECRQM; the terminal that flips behavior without being asked desyncs
the cursor.

Characterization (ExecPlan milestone M0) established that the vendored
`libghostty-vt` *already* implements mode 2027 end-to-end through Laban's bridge:
all child bytes flow to `ghostty_terminal_vt_write`, so `CSI ? 2027 h/l` toggles the
engine's `GHOSTTY_MODE_GRAPHEME_CLUSTER`; DECRQM is answered through the engine's
`WRITE_PTY` callback (`CSI ? 2027 ; 1/2 $ y`); the grid lays a cluster into one WIDE
cell + spacer tail when ON; and `LabanSnapshot` already carries each cell's full
cluster bytes plus the engine's `wide` flag. So the live viewport, cursor, and
rendering were already correct in both modes.

The one genuine gap was Swift-side: the **scrollback fallback** path
(`Sources/LabanTerminalCore/scrollback_extract.c` → `Session.scrollbackBlock` →
find/copy) reconstructs scrolled-off rows as a `String` with no per-cell width and
recomputed width from a pinned per-scalar table
(`Sources/LabanRenderer/TerminalDisplayWidth.swift`) that implements the *legacy* rule
only. Under mode 2027 ON that table drifts (counts the farmer as 4 columns when the
engine used 2).

## Decision

1. **The engine is the single source of truth for grapheme segmentation and
   width.** Laban never re-derives UAX #29 boundaries or cluster width in Swift. All
   width consumers read the engine's decision — the snapshot `wide` flag for the
   live viewport, and engine-carried width for scrollback.

2. **Factory default OFF / opt-in, with a user-selectable default.** Laban does not
   enable mode 2027 on its own. A program opts in via DECSET. A user may set a
   per-session default through the native Settings "Unicode width" preference
   (`Sources/LabanCore/GraphemeWidthSettings.swift`: `.auto` = start OFF;
   `.preferGrapheme` = start ON), applied at session creation via the C bridge
   `laban_session_set_grapheme_cluster_mode` called from `Session.init`. The setting
   is a *starting default* only: a program's DECSET/DECRST still overrides it at
   runtime, and the default applies to **new** sessions (live sessions are never
   retroactively toggled, to avoid a mid-session reflow).

3. **DECRQM reports genuine SET (1) / RESET (2), not PERMANENTLY_* (3/4).** Because
   Laban delegates width entirely to libghostty — which truly implements and toggles
   grapheme width — the mode is genuinely on/off-able. This differs from terminals
   (e.g. foot) that report PERMANENTLY_RESET when a configured width method cannot
   conform; Laban has no such caveat.

4. **Scrollback width is carried through a versioned C extraction.**
   `laban_session_scrollback_extract2_alloc` emits, alongside the byte-identical v1
   text + row offsets, per-grapheme `(byteLength, displayColumns)` read from a
   parallel engine grid-ref walk. `ScrollbackBlock` gains an optional
   `graphemeWidths`; `TerminalFind.rowBuffer` and `TerminalSelection.plainLineText`
   advance columns by the carried width and fall back to `TerminalDisplayWidth` only
   when metadata is absent (self-correcting per row). The pinned table is demoted to
   a **fallback**, not the width model. Non-grid consumers (IME preedit, word-
   constituent classification) legitimately keep the fallback — they size text that
   never entered the grid.

5. **Observability for autonomous verification.** `LabanSnapshot.grapheme_cluster_2027`
   (mirroring the mode-2026 `synchronized_output` field) and the
   `GET /debug/terminal-modes` endpoint report the effective mode, wired into both
   `HeadlessDebugRuntime` and `MainWindowController`.

## Consequences

- A modern TUI that negotiates mode 2027 with Laban gets correct, consistent width
  across cursor, rendering, selection, copy, find, and IME — proven by
  `Tests/LabanCoreTests/TerminalWidthConformanceTests.swift` over ASCII, CJK, ZWJ
  emoji, regional-indicator flags, skin-tone modifiers, Hangul, Devanagari clusters,
  and VS15/VS16, in both modes.
- The legacy default path is unchanged (the mode-OFF regression suites
  `TerminalFindTests`/`TerminalSelectionTests`/`TerminalDisplayWidthTests` stay
  byte-identical), so existing apps are unaffected.
- A "force legacy / freeze the mode against a program's toggle" Settings option is
  **future work**: it needs an engine frozen-mode capability (cf. Contour's
  `frozen_dec_modes`) the current C API does not expose.
- Kitty's OSC-based **text-sizing protocol** is a separate, competing mechanism and
  is an explicit **non-goal** here; supporting it is independent future work.

## Decision Log

- **2026-07-05 — Ambiguous-width characters.** East-Asian users sometimes expect
  ambiguous-width characters (`±`, `§`, arrows, box-drawing) to render as two
  cells. Laban has no user-facing control for this today: grid width is owned by
  libghostty, and the Swift fallback table (`TerminalDisplayWidth`) is hardcoded.
  We intentionally do **not** add a Swift-only ambiguous-width toggle, because that
  would create a second width truth next to the engine. The correct path is to
  coordinate with libghostty to expose an ambiguous-width C API knob (or
  environment variable) and then surface it in Settings. Until that upstream
  capability exists, behavior follows libghostty's current rule.

## Applies To New Code

- Any new consumer of cell width MUST read the engine's width — the snapshot `wide`
  flag for live cells, or the carried scrollback width metadata — never re-derive
  grapheme boundaries or cluster width in Swift. `TerminalDisplayWidth` is a
  last-resort fallback for text that never entered the grid (e.g. IME preedit), not
  a width authority.
- When threading new data through scrollback extraction, follow the versioned-entry-
  point pattern (`*_extract2_alloc`) so existing callers keep the byte-identical v1
  behavior.
- Treat mode 2027 as opt-in: do not enable it implicitly; a program's DECSET/DECRST
  is authoritative over any Laban default, and defaults apply only to new sessions.
