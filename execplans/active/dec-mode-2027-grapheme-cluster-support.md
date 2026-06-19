# True elite DEC private mode 2027 (Unicode grapheme-cluster width) support

This ExecPlan is a living document maintained in accordance with `../../PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add
optional sections only when they contain information that will help a fresh
contributor.

## Purpose / Big Picture

Laban is a native macOS terminal emulator (Swift/AppKit + Metal). It does **not**
parse VT escape sequences itself: it links the vendored static library
`libghostty-vt` (the terminal engine extracted from the Ghostty terminal) and
drives its *full terminal model* — grid, cursor, mode state — through a C API.
Laban then flattens that model into its own `LabanSnapshot` struct that the Swift
renderer draws.

**DEC private mode 2027** (also called "grapheme clustering mode" or "Unicode core
mode") is an opt-in terminal mode that fixes how the terminal computes the
*display width* — the number of fixed-width character cells — of complex Unicode
text such as emoji, flags, and combining sequences. A program running in the
terminal turns it on by writing the escape sequence `ESC [ ? 2027 h`, off with
`ESC [ ? 2027 l`, and asks the terminal whether it is supported/active with the
DECRQM query `ESC [ ? 2027 $ p`. The number `2027` is the mode's identifier.

Why it matters to a user: today, paste a line containing `👩‍🌾` (a single
"farmer" emoji built from three Unicode code points: person U+1F9D1 + zero-width
joiner U+200D + ear-of-rice U+1F33E) into a TUI such as `vim`, `fish`, or a chat
client, and the program and the terminal can disagree about how many cells that
emoji occupies. The program assumes the legacy rule (each code point measured on
its own → 2 + 0 + 2 = **4 cells**); a mode-2027-aware terminal treats the whole
cluster as one unit → **2 cells**. When they disagree, the cursor lands in the
wrong place, the prompt redraws over itself, and selection/copy grabs the wrong
columns. After this change a user can run a modern TUI that negotiates mode 2027
with Laban and have emoji, flags, ZWJ ("zero-width joiner") sequences, and
combining marks line up correctly — cursor, rendering, selection, copy, find, and
the input method editor (IME) preedit all agree — and a developer can verify the
negotiation handshake works with a one-line shell probe.

The headline research finding that shapes this plan: **most of the engine-level
behavior is already present**, because `libghostty-vt` implements mode 2027 and
Laban passes every byte of the child program's output to it. The work here is to
(1) *prove* the engine contract end-to-end with conformance tests, (2) close the
one genuine code gap — the Swift-side width consumers (scrollback find/copy,
word selection, IME preedit) that today assume the *legacy* width rule and drift
when the mode flips, and (3) make the whole thing autonomously verifiable
(debug-state endpoint + conformance fixture), per the `AGENTS.md`
autonomous-verifiability rule.

## Glossary (define before use)

- **Code point**: one Unicode scalar value (e.g. U+1F9D1). UTF-8 encodes each code
  point as 1–4 bytes.
- **Grapheme cluster**: what a human perceives as a single character, possibly made
  of several code points (e.g. `👩‍🌾` = three code points; `é` = `e` + combining
  acute; `🏳️‍⚧️` = several). The boundaries are defined by Unicode Standard Annex
  #29 ("UAX #29", *extended grapheme cluster* rules). "Grapheme clustering" =
  splitting a stream of code points into these clusters.
- **Cell / column**: one fixed-width slot in the terminal grid. A "narrow" glyph
  occupies 1 cell, a "wide" one occupies 2 (the second cell is an empty
  placeholder, the **spacer tail**).
- **Display width**: how many cells a piece of text occupies. The whole point of
  mode 2027 is *who decides this and how*.
- **`wcwidth` / legacy width**: the historical rule where each code point is
  measured independently (a C function `wcwidth` returns 0/1/2 per code point).
  This is "mode 2027 OFF". It mis-measures multi-code-point graphemes.
- **Mode 2027 ON (grapheme width)**: the terminal segments the stream into grapheme
  clusters and assigns each cluster a single width (derived from its base, with
  special rules below). `👩‍🌾` → 2 cells as one unit.
- **DECSET / DECRST**: "DEC Set/Reset Mode" — the escape sequences `ESC [ ? <n> h`
  (set/enable) and `ESC [ ? <n> l` (reset/disable) for a private mode `<n>`.
- **DECRQM / DECRPM**: "DEC Request/Report Mode" — a program asks
  `ESC [ ? <n> $ p` (DECRQM) and the terminal replies `ESC [ ? <n> ; <v> $ y`
  (DECRPM), where `<v>` is: `0` not recognized, `1` set, `2` reset, `3`
  permanently set, `4` permanently reset.
- **VS15 / VS16**: "variation selectors" U+FE0E / U+FE0F. VS16 after an emoji base
  forces *emoji presentation* and width 2; VS15 forces *text presentation* and
  width 1. Example: `▶` (U+25B6) is width 1; `▶️` (U+25B6 U+FE0F) is width 2.
- **ZWJ**: zero-width joiner U+200D; glues code points into one emoji (family,
  profession, flag-with-modifier sequences). Width 0 on its own.
- **Regional indicator**: pairs of code points U+1F1E6–U+1F1FF that form flag
  emoji (`🇸🇪` = two regional indicators); the pair is one 2-cell grapheme.
- **TUI**: "text user interface" — a full-screen terminal program (vim, fish,
  tmux, Claude Code).
- **Snapshot**: Laban's flattened, renderer-facing copy of the terminal grid at one
  instant — the C struct `LabanSnapshot` (see `Context` below). The Swift renderer
  never reads ghostty directly; it reads snapshots.
- **Scrollback fallback path**: when selection/find reaches rows that scrolled out
  of the live viewport, Laban reconstructs text from a `String`-based extraction
  that (unlike the live snapshot) carries **no per-cell width metadata**. This is
  the root cause of the width drift this plan must fix.

## Progress

- [x] (2026-06-19) Plan authored from research: spec sources (Terminal Unicode
      Core / Mitchell Hashimoto write-up), reference implementations (ghostty,
      contour, foot, wezterm, kitty), and a code map of Laban's libghostty
      integration. Key finding recorded: mode 2027 is largely already wired
      through `libghostty-vt`; the genuine gap is Swift-side width coherence.
- [x] (2026-06-19) Plan reviewed by an independent fresh-state agent. All six
      load-bearing factual claims verified against the source (see file:line
      evidence folded into Context below). Minor revisions applied: scrollback
      extraction is now flagged as an ABI/format change with a safe migration
      note; a mode-OFF regression gate was added; a mid-session mode-flip probe
      was added to M0; a DECRPM-value decision was logged; a render-glyph proof
      was added to M2; the "genuine gap" consumer list was split into true
      scrollback bugs vs. legitimate fallbacks; and M0/M1 now cite the existing
      `testDECRQMModeQueryUsesTerminalState` proof as a template.
- [x] (2026-06-19) M0 — Characterization harness. Result: **every assumption
      confirmed, no gaps.** Mode toggles via passthrough; DECRQM answers
      `?2027;1$y`(ON)/`?2027;2$y`(OFF); snapshot carries the full cluster; ON lays
      one WIDE+spacer (cursor +2), OFF lays two WIDE+spacer clusters (cursor +4).
      Probe E: scrollback extraction is String-only and carries **no** width
      (not re-derived) — so M3 adds width at extraction time; no scroll-off
      snapshot needed. Test `Tests/LabanTerminalCoreTests/Mode2027CharacterizationTests.swift`
      (5 tests). nm confirms grapheme tables compiled into the vendored `.a`.
- [x] (2026-06-19) M1 — Locked the handshake + observability. Added
      `LabanSnapshot.grapheme_cluster_2027` (mirrors the mode-2026
      `synchronized_output` field) and a `GET /debug/terminal-modes` endpoint wired
      into both `HeadlessDebugRuntime` and `MainWindowController` (parity). Tests:
      `testMode2027HandshakeAndSnapshotField` (DECSET→`?2027;1$y`+field true;
      DECRST→`?2027;2$y`+field false) and
      `testDebugHTTPServerTerminalModesReflectsMode2027Handshake`. `swift build` +
      `swift test --filter Mode2027`/debug-smoke green.
- [x] (2026-06-19) M2 — Grid & cursor-advance conformance. Test-only (no source
      change — re-confirms the engine). `Mode2027GridConformanceTests` pins
      `(wide layout, cursor advance, CSI 6n col)` for `a`, `中`, farmer, VS16/VS15,
      regional pair, ZWJ family under both modes; `FrameProducerGraphemeClusterTests`
      proves a wide cluster renders as ONE glyph run. Mutation check verified
      (farmer ON→OFF expectation makes exactly that row fail). Two measured nuances:
      (a) VS16 is NARROW in mode-OFF — it only widens to 2 cells under clustering
      (the glossary's "VS16 forces width 2" is the mode-ON behavior); (b) the
      canonical farmer bytes `F0 9F A7 91…` decode to U+1F9D1 🧑 (person), not 👩
      (woman) — prose elsewhere writes 👩‍🌾 but the bytes/tests are authoritative.
- [x] (2026-06-19) M3 — Swift width-consumer coherence. Added a versioned C
      extraction `laban_session_scrollback_extract2_alloc` (v1 text path byte-
      identical) that walks the engine grid to emit per-grapheme
      `(byteLength, displayWidth)`; `ScrollbackBlock` gained an optional
      `graphemeWidths`; the class-A scrollback consumers (`TerminalFind.rowBuffer`,
      `TerminalSelection.plainLineText`) now advance columns by the engine's width
      and fall back to `TerminalDisplayWidth` only when metadata is absent (self-
      correcting per row). Class-B consumers (IME preedit, word classification)
      keep the fallback by design. New `Mode2027ScrollbackWidthTests` (7) prove
      farmer = 2 cols ON / 4 OFF and exact copy bytes; mutation guard confirmed.
      Regression suites byte-identical green (TerminalFindTests 13,
      TerminalSelectionTests 21, TerminalDisplayWidthTests 8). Discovery: extraction
      uses ghostty's formatter (not engine cells), so width is sourced via a
      parallel grid-ref walk aligning grid screen-row R to formatter row R.
- [x] (2026-06-19) M4 — Conformance fixture + end-to-end handshake demo.
      Test-only (no engine/source change — re-confirms the engine). New
      `Tests/LabanCoreTests/TerminalWidthConformanceTests.swift` (7 tests) drives
      the real fixture session and pins, in BOTH modes, the grid `wide` layout +
      cursor advance (cross-checked against the engine's own `CSI 6n`), the
      scrollback find columns (M3 `graphemeWidths` v2 path), and the scrollback
      copy bytes — for ASCII, CJK, ZWJ farmer, ZWJ trans flag, regional pair,
      skin-tone, Hangul, Devanagari conjunct, VS16, VS15. ON widths are hard
      literals; a measurement test prints the full table (see Artifacts → M4
      conformance table). Two measured surprises (documented, NOT gaps — each
      agrees with CSI 6n): trans-flag OFF lays two NARROW cells (VS16 only widens
      under clustering); Devanagari `क्षि` OFF lays THREE narrow cells (advance 3),
      ON folds to one WIDE+tail (advance 2). The end-to-end demo is
      `testHandshakeDemo_negotiateThenPrintFarmer` (asserts `ESC[?2027;2$y` →
      `ESC[?2027;1$y` → `ESC[1;3R`) plus a reproducible `printf` transcript in
      Artifacts. `swift build` + `swift test --filter TerminalWidthConformance`
      (7) / `Mode2027` (19) green.
- [x] (2026-06-19) M5 — Settings UI. New `Sources/LabanCore/GraphemeWidthSettings.swift`
      (`enum GraphemeWidthMode { auto, preferGrapheme }`, default `.auto`, key
      `LabanGraphemeWidthMode`); an "Unicode width" `NSPopUpButton` row in
      `SettingsWindowController`; engine wiring via a new C bridge
      `laban_session_set_grapheme_cluster_mode` called from `Session.init`
      `applyGraphemeWidthPreference()` — the single creation funnel both the app
      and the headless runtime route through (new sessions only; `.auto` leaves the
      engine OFF). **Decision (chosen): post-create bridge call from `Session.init`,
      not a `LabanLaunchConfig` field** — reaches both runtimes with no per-factory
      duplication. Tests: store (13), settings-UI (4), headless (4) — the headless
      test proves `.preferGrapheme` → fresh session reports `grapheme_cluster_2027:
      true` before any output via `GET /debug/terminal-modes`, `.auto` → false, and
      a program's DECSET/DECRST overrides either default. `swift build` +
      `Mode2027`/`GraphemeWidth`/`LabanDebugSmokeTests` green.
- [x] (2026-06-19) M6 — Elite polish. Wrote `docs/adr/0021-dec-mode-2027-grapheme-cluster-width.md`
      (engine = single source of truth; default OFF/opt-in + user-selectable
      default; DECRQM SET/RESET; scrollback width via versioned extraction; kitty
      text-sizing protocol and freeze-against-program-toggle as future work) and
      indexed it in `docs/adr/README.md`. The `TerminalDisplayWidth` doc-comment
      demotion to "fallback" already landed in M3.
- [x] (2026-06-19) Review Gate passed — fresh-state review ALL PASS; two Low
      findings closed (selection under-tiling guard + wrapped-row alignment test);
      `swift test` 1673/0, `./scripts/build-app` exit 0.

Milestones are ordered: M0 is a *characterization* milestone whose output is the
precise specification for M1–M3 (we measure what `libghostty-vt` already does
before changing anything). M1/M2 are mostly verification-and-harden; M3 is the
real code change. M4 locks behavior. M5 is optional.

## Context and Orientation

Read this as if you know nothing about Laban. Every path is repository-relative
from the repo root `~/wrk/laban`. Build with `./scripts/build-app` (assembles the
app bundle; **never** `swift build` alone for the app). Run tests with
`swift test`. Do **not** `open`/launch `Laban.app` from a shell — it grabs a
single-instance lock; for live checks install with
`LABAN_INSTALL_PATH="$HOME/Laban-2027.app" ./scripts/install-app` and let the user
launch it.

### How Laban talks to the terminal engine

- The terminal engine is the vendored static library
  `.external/libghostty-vt/zig-out/lib/libghostty-vt.a`, with C headers under
  `.external/libghostty-vt/include/ghostty/vt/`. `Package.swift` links it into the
  `LabanTerminalCore` target (see `Package.swift` lines ~6–7 and ~37–43).
- **Laban uses ghostty's full terminal model, not just its parser.** The C bridge
  lives in `Sources/LabanTerminalCore/`. Every byte the child program writes is
  forwarded verbatim to the engine: search for `ghostty_terminal_vt_write` (the
  passthrough is documented in `Sources/LabanTerminalCore/decscusr.c:22` —
  "every byte still flows unchanged to ghostty_terminal_vt_write"). The PTY read
  loop is `Sources/LabanTerminalCore/pty_io.c` (`laban_vt_write_capture` at
  ~line 148).
- The engine owns mode state. Laban reads/sets modes through
  `ghostty_terminal_mode_get` / `ghostty_terminal_mode_set`
  (`Sources/LabanTerminalCore/terminal_effects.c`, e.g. lines ~139, ~192). Mode
  identifiers are defined in `.external/libghostty-vt/include/ghostty/vt/modes.h`;
  the relevant one is `GHOSTTY_MODE_GRAPHEME_CLUSTER` =
  `ghostty_mode_new(2027, false)` (`modes.h:93`).
- **Engine → host responses** (DECRQM replies, device status reports) are delivered
  through a callback the host registers: `GHOSTTY_TERMINAL_OPT_WRITE_PTY`
  (`.external/libghostty-vt/include/ghostty/vt/terminal.h:~409`, callback type
  `GhosttyTerminalWritePtyFn`) — the comment states it fires "in response to a
  DECRQM query or device status report". Laban's response plumbing is
  `Sources/LabanTerminalCore/terminal_effects.c`
  (`laban_write_terminal_response`, `laban_session_capture_response`). Responses
  Laban sends back to the child are also mirrored to capture artifacts as
  `terminal-response.bin` (see `AGENTS.md` → Runtime Artifacts).
- The DECRPM report values are enumerated in `modes.h`:
  `GHOSTTY_MODE_REPORT_NOT_RECOGNIZED=0`, `_SET=1`, `_RESET=2`,
  `_PERMANENTLY_SET=3`, `_PERMANENTLY_RESET=4`; `ghostty_mode_report_encode`
  (`modes.h:185`) encodes a DECRPM reply.

### The snapshot already carries grapheme clusters

`Sources/LabanTerminalCore/snapshot.c` builds a `LabanSnapshot`. For each cell it
reads ghostty's per-cell data including the grapheme codepoints
(`GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN` /
`..._GRAPHEMES_BUF`, around lines 325–407) and UTF-8-encodes *all* code points of
the cluster into the snapshot's shared `utf8_storage`. The cell type
(`Sources/LabanTerminalCore/include/LabanTerminalCore.h`, struct `LabanCell`,
lines ~88–99) is:

```
typedef struct {
    uint32_t codepoint;      /* First codepoint; 0 if empty or multi-codepoint */
    uint32_t utf8_offset;    /* Byte offset into LabanSnapshot.utf8_storage */
    uint32_t utf8_length;    /* Byte length in utf8_storage; 0 if empty */
    ...
    uint8_t  wide;           /* LABAN_CELL_WIDE_* (NARROW=0, WIDE=1,
                                SPACER_TAIL=2, SPACER_HEAD=3) */
} LabanCell;
```

So the live viewport path has the *full* cluster text (`utf8_offset`/`utf8_length`
→ the bytes in `utf8_storage`) and the engine's authoritative width
(`wide`). Rendering and live-viewport width are therefore already grapheme- and
mode-correct: they read what the engine decided. `LABAN_CELL_WIDE_*` is defined in
`LabanTerminalCore.h:82–85` and mirrors ghostty's `GhosttyCellWide`.

### The genuine gap: the Swift-side width consumers

When selection or find reaches **scrolled-off** rows, Laban does **not** use the
snapshot's per-cell `wide` flag — it reconstructs text from a `String`-only
scrollback extraction (`Sources/LabanTerminalCore/scrollback_extract.c` feeding
the Swift scrollback model). That `String` has no width metadata, so the Swift
side recomputes width with a *pinned table*,
`Sources/LabanCore/TerminalDisplayWidth.swift` (`cells(of:)`, `isWide(_:)`). That
table deliberately implements the **legacy / mode-2027-OFF** rule (sum width per
Unicode scalar). Its own doc comment (recently added, lines ~4–8) pins the
assumption:

```
/// ... models libghostty layout with DEC mode 2027 (grapheme_cluster) DISABLED
/// — Laban's configuration ... Width is summed per Unicode scalar ... If mode
/// 2027 is ever enabled, these per-scalar-width consumers (scrollback find/copy,
/// word selection, IME preedit) ... must switch to per-grapheme-head width.
```

There are two distinct classes of consumer here, and only the first is the bug.

**(A) Scrollback `String` consumers — the actual mode-2027 bug.** These derive a
*column* from `String` text using the pinned table because the scrollback fallback
discarded the engine's per-cell width. These drift under mode 2027 and are what M3
fixes:

| Consumer | File | Symbol |
|---|---|---|
| Scrollback copy | `Sources/LabanCore/TerminalSelection.swift` | `plainLineText(...)` (~lines 279–284) |
| Scrollback find | `Sources/LabanCore/TerminalFind.swift` | `rowBuffer(fromUTF8Row:)` (~lines 194–204) |

**(B) Non-grid consumers that legitimately keep the pinned table as a fallback.**
These size text that never entered the grid, or use the table for word
*classification* (is-this-character-a-word-constituent), not for grid column math,
so there is no engine width to consult:

| Consumer | File | Symbol | Why fallback is OK |
|---|---|---|---|
| Word selection | `Sources/LabanApp/TerminalSelectionInput.swift` | `wordBounds`, `isWord` (~:208) | reads live `cells`/`storage` for layout; uses `TerminalDisplayWidth.isWide` only to classify word constituents |
| IME preedit caret | `Sources/LabanApp/TerminalBitmapView.swift` | `markedTextCaretCells` (~:3696) | preedit text not yet committed to the grid |
| IME preedit mask | `Sources/LabanCore/FrameProducer.swift` | preedit `runWidth` (~:577) | preedit text not yet committed to the grid |

M3 reroutes class (A) to engine-carried width and demotes the pinned table to the
last-resort role it already plays for class (B).

The live-viewport selection/find paths (`snapshotLineText`,
`snapshot`-based hit-testing) already consult the real `wide` flag and are fine;
only the scrollback `String` fallback is wrong. This was previously visible even
with mode OFF (the "BUG-12/13" column drift fixed by introducing the pinned
table) — but with mode ON the pinned table is *also* wrong, because the engine
now lays `👩‍🌾` into 2 cells while the per-scalar table still counts 4.

### Rendering

`Sources/LabanCore/FrameProducer.swift` builds glyph-run draw commands from
snapshot cells; the macOS text stack (CoreText) shapes a cell's `utf8_storage`
bytes, so a cluster like `👩‍🌾` carried in one cell already shapes to one glyph.
Wide clusters occupy two cells (head + spacer tail) per the engine's `wide` flag.
Confirm during M2 that this holds; it is expected to already work.

### Tests and existing width coverage

- C-bridge / engine tests: `Tests/LabanTerminalCoreTests/` (and the smoke file
  `Sources/LabanTerminalCore/ghostty_vt_bridge_smoke.c`).
- Swift width tests added by the prior audit work: `TerminalDisplayWidthTests`,
  `TerminalFindTests`, `TerminalSelectionTests`, `FrameProducerPreeditTests`,
  `TerminalSelectionInputTests` (all under `Tests/LabanCoreTests` and
  `Tests/LabanAppTests`). These currently pin the **mode-OFF** behavior.
- There is **no** `TerminalWidthConformanceTests` yet (an earlier plan referenced
  it as future work). M4 creates it.

### Headless / debug parity (a Laban hard rule)

Any new subsystem must be reachable from both the GUI path
(`Sources/LabanApp/MainWindowController.swift` `makeAndShow`) and the headless
path (`Sources/LabanDebug/HeadlessDebugRuntime.swift`), with an HTTP debug
endpoint for autonomous verification. Debug endpoints live in
`Sources/LabanDebug/DebugStateEndpoints.swift` /
`Sources/LabanDebug/DebugHTTPServer.swift` / `Sources/LabanDebug/DebugModels.swift`.
M1 adds mode-2027 state there.

## What "true elite" means here (scope and non-goals)

"Elite" = the whole stack is coherent and provably correct, not just "DECRQM
answers". Concretely:

1. The **handshake** is correct: `ESC [ ? 2027 h/l` toggles the engine, and
   `ESC [ ? 2027 $ p` returns the right DECRPM value (set/reset), so real TUIs
   that negotiate (the recommended pattern) behave.
2. The **cursor advances correctly** under each mode — the single behavior most
   terminals get wrong and the reason naive clustering breaks `fish` (see
   Decision Log). A program that prints `👩‍🌾` then asks the cursor position
   (`ESC [ 6 n`) gets back the column the engine actually used.
3. **Every width consumer agrees** with the active mode: rendering, cursor,
   selection, copy, find, and IME preedit — including the scrollback fallback.
4. It is **autonomously verifiable**: a debug endpoint reports mode state, and a
   conformance fixture pins the spec's hard examples under *both* modes.
5. The **factory default is OFF** (opt-in by the program), matching every correct
   implementation and avoiding the `fish` breakage (Decision Log) — with a
   first-class **Settings UI** (M5) letting a user choose a "prefer grapheme width"
   default for sessions, which a program's DECSET/DECRST still overrides.

Non-goals (explicitly out of scope, record as decisions, do not implement here):

- **Kitty's text-sizing protocol** (an OSC-based alternative to mode 2027). It is
  a different mechanism; kitty deliberately does *not* implement 2027. Out of
  scope; note as future work in M5.
- **Reimplementing UAX #29 segmentation in Swift.** The engine is the single source
  of truth. The Swift side must *consume* the engine's width, never re-derive
  grapheme boundaries itself (see Decision Log).
- **Shipping with mode 2027 forced ON out of the box.** The factory default stays
  OFF/opt-in. A user *may* opt into a "prefer grapheme width" default via the new
  Settings UI (M5), but Laban never forces it on without the user choosing it, and
  a program's DECSET/DECRST still overrides the per-session default.

## Plan of Work

### M0 — Characterization harness: measure what already works

**Why first:** we believe `libghostty-vt` already implements mode 2027, but we must
*measure* the exact current behavior through Laban's bridge before changing code,
so M1–M3 target real gaps rather than assumed ones. This milestone adds tests that
**document current behavior**; some assertions may be written as "record the
observed value" first, then tightened once observed.

**What to build:** a new C or Swift test that drives a real session via the
`LabanTerminalCore` API (mirror the existing pattern in
`Tests/LabanTerminalCoreTests/` and `Sources/LabanTerminalCore/session_smoke.c`):

1. Create a session, feed bytes (use the same entry the PTY loop uses,
   `ghostty_terminal_vt_write` via the bridge, or the session's write-input path).
2. Probe A (mode OFF, default): write `👩‍🌾` (`\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\x8C\xBE`),
   then snapshot; record `cursor_col`, and for the printed cells record `wide` and
   the `utf8_storage` bytes. Expectation from research: engine lays the cluster as
   per-code-point cells (≈4 columns) when OFF.
3. Probe B: write `ESC [ ? 2027 h`, then `👩‍🌾`, snapshot; record `cursor_col`,
   cell `wide`, and `utf8_storage`. Expectation: 2 columns, one wide cell + spacer
   tail, full cluster bytes in the head cell.
4. Probe C (handshake): register/observe the `WRITE_PTY` response callback (the
   bridge already wires `laban_write_terminal_response`); write `ESC [ ? 2027 $ p`
   and capture the bytes the engine emits back. Record the exact DECRPM reply
   (expected `ESC [ ? 2027 ; 1 $ y` when set, `; 2` when reset).
5. Probe D: `ESC [ 6 n` (Device Status Report — cursor position) after printing
   the cluster in each mode; record the reported row/column.
6. Probe E (mid-session flip — the one place "single source of truth" could
   silently fail): set `?2027h`, print `👩‍🌾`, scroll it off the live viewport,
   set `?2027l`, then run the scrollback extraction. Record whether the extracted
   row reports the cluster as **2 columns** (the engine retained the historical
   width it laid down) or **4 columns** (the engine/extractor re-derived width
   under the now-current mode). This determines whether M3's "carry the width the
   engine used" is sufficient or whether the width must be snapshotted at the
   moment a row scrolls off. Record the answer in **Surprises & Discoveries**.

A ready-made template exists: `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`
`testDECRQMModeQueryUsesTerminalState` (~line 2659) already proves the DECRQM drain
end-to-end for mode `?7` (writes `\e[?7$p`, calls `drainResponse`, asserts
`\e[?7;1$y`), using `makeFixtureSession` / `writeBytes` / `drainResponse` helpers.
Copy that structure for the 2027 probes — only 2027-specific behavior is unverified;
the handshake *mechanism* is already proven for a sibling mode.

**Acceptance (observable):** First a 10-second pre-flight that fails fast if a
future re-vendor stripped the Unicode tables:
`nm .external/libghostty-vt/zig-out/lib/libghostty-vt.a | grep -i graphemeBreak`
returns at least one symbol. Then `swift test --filter Mode2027CharacterizationTests`
runs and prints (via test log) the measured cursor columns, cell widths, the raw
DECRPM bytes for both modes, and the Probe E mid-flip column. The plan's
**Surprises & Discoveries** section is updated with the measured table. This
milestone *cannot fail to inform*: its job is to convert "probably works" into
"here is exactly what works and what doesn't."

### M1 — Lock the engine handshake + debug observability

Using M0's measurements:

- If DECRQM `?2027$p` already returns the correct DECRPM value (`1` when set, `2`
  when reset) through the existing `WRITE_PTY`/`laban_write_terminal_response`
  path, this milestone *verifies and pins* it with a test. If M0 shows the reply
  is wrong/absent (e.g. the engine emits it but Laban drops it, or it reports a
  wrong number — a known class of bug in other terminals), fix the drain in
  `Sources/LabanTerminalCore/terminal_effects.c` so the engine's encoded report
  reaches the child and the capture's `terminal-response.bin`.
- Confirm `DECSET/DECRST 2027` toggles `ghostty_terminal_mode_get(...,
  GHOSTTY_MODE_GRAPHEME_CLUSTER, ...)`.
- **Observability (hard rule):** surface mode-2027 state. Extend the snapshot or a
  debug query so `GET /debug/terminal-modes` (new or extend an existing
  state endpoint in `Sources/LabanDebug/DebugStateEndpoints.swift`) returns
  `{ "grapheme_cluster_2027": true|false, ... }`. Wire it into both
  `HeadlessDebugRuntime` and `MainWindowController` (parity). Add the field to the
  snapshot if convenient (the snapshot already exposes mode booleans like
  `synchronized_output` for mode 2026 — follow that exact pattern in
  `LabanTerminalCore.h` / `snapshot.c`).

**Acceptance:** a headless test sends `?2027h`, asserts `GET /debug/terminal-modes`
reports it on, sends `?2027$p`, and asserts the captured response bytes equal the
DECRPM "set" reply; sends `?2027l` and asserts "reset". A `grep` shows the debug
field wired in both runtimes. Model the response assertion on the existing
`testDECRQMModeQueryUsesTerminalState` (`Tests/LabanTerminalCoreTests/LabanSessionTests.swift`
~line 2659), which already does exactly this for mode `?7`.

### M2 — Grid & cursor-advance conformance under both modes

Verify (fix only if M0/M2 expose a gap) that the **engine grid** is correct:

- Mode ON: a grapheme cluster occupies its cluster width (1 or 2), stored as one
  head cell (`wide=WIDE` for 2-cell) + a `SPACER_TAIL`; `cursor_col` after the
  cluster advanced by exactly that width; the head cell's `utf8_storage` holds all
  cluster code points.
- Mode OFF: legacy per-code-point layout; `cursor_col` advances by the legacy sum.
- VS16/VS15: `▶`+VS16 → 2 cells; base+VS15 → 1 cell. Regional indicator pair → one
  2-cell grapheme. ZWJ family (`👨‍👩‍👧`) → one 2-cell grapheme when ON.

Drive these through the real session and assert against the snapshot + the
`ESC [ 6 n` cursor report. This is primarily a verification milestone proving the
engine path; if a discrepancy appears (e.g. Laban's snapshot mis-maps a wide
spacer), fix it in `snapshot.c`.

**Acceptance:** `swift test --filter Mode2027GridConformanceTests` passes; a table
of clusters asserts `(wide, cursor advance)` for ON and OFF; mutating an expected
ON-width to the OFF value makes exactly the affected row fail. **Render proof
(separate from grid width):** a width-correct cell can still render as two glyphs.
Add an assertion via the existing `FrameProducer` draw-command tests (see
`Tests/.../FrameProducerTests`) that `👩‍🌾` carried in one wide cell produces a
**single** glyph run, not two — or, if the draw-command layer cannot express that,
a screenshot artifact of the rendered cluster. This proves the cluster shapes as
one glyph, which grid width alone does not.

### M3 — Swift width-consumer coherence (the real code change)

Make the scrollback fallback consumers honor the engine's width regardless of
mode, eliminating the pinned-table assumption as the *primary* width source:

1. **Carry width into scrollback.** Extend the scrollback extraction
   (`Sources/LabanTerminalCore/scrollback_extract.c` and the Swift scrollback
   model it feeds) so each extracted row carries per-display-cell metadata
   (the cluster boundaries and `wide` value the engine used), not just a `String`.
   Minimum viable: alongside the row `String`, emit a parallel array of
   `(utf8_range, displayColumns)` so the Swift side can map a display column to the
   right cluster without guessing. This is the same information the live snapshot
   already exposes per cell; the task is to preserve it through the scrollback
   path instead of discarding it.

   **This is an ABI/format change — make it additive and safe.** Today the C
   functions `laban_session_scrollback_extract*`
   (`Sources/LabanTerminalCore/include/LabanTerminalCore.h` ~lines 723–772) emit
   only `text_buffer` + `row_offsets`, and the Swift `ScrollbackBlock`
   (`Sources/LabanCore/TerminalFind.swift` ~line 21, built transiently by
   `Session.scrollbackBlock` in `Session.swift` ~lines 840–866) holds `text:
   String` + `rowOffsets`. Reassuring fact (verified): `ScrollbackBlock` /
   `scrollback_extract` are a **transient in-memory query result, not a persisted
   capture/replay artifact or the snapshot ring** — they are *not* referenced by
   `Sources/Laband*` or `Sources/LabanDebug`, so capture/replay determinism and the
   laband multi-client path are **not** at risk. To keep the change low-risk: add a
   **new versioned C entry point** (e.g. `..._extract2` / an additional
   out-parameter) rather than mutating the existing signatures, and give
   `ScrollbackBlock` the metadata as an **optional** field so existing call sites
   compile unchanged and fall through to the current behavior when metadata is
   absent.

   If Probe E (M0) shows the engine re-derives width under the *current* mode for
   already-scrolled-off rows, the metadata must be captured at the instant a row
   scrolls off (snapshot it then), not recomputed at extraction time. Record M0's
   answer here before implementing.
2. **Consume it.** Update `TerminalSelection.plainLineText`,
   `TerminalFind.rowBuffer(fromUTF8Row:)`, `TerminalSelectionInput.wordBounds`,
   `TerminalBitmapView.markedTextCaretCells`, and `FrameProducer` preedit width to
   read the carried metadata when present. Keep `TerminalDisplayWidth` as a
   *last-resort fallback only* (used when metadata is genuinely unavailable, e.g.
   IME preedit text that never entered the grid). Update its doc comment to say it
   is a fallback, not the model.
3. The result: find/copy/word-select are correct whether mode 2027 is on or off,
   because they use the engine's actual layout, not a re-derivation.

**Acceptance:** new tests place `👩‍🌾` and a CJK char into scrollback under mode ON
and assert that scrollback find returns the column the engine used (2 per cluster)
and copy returns the exact cluster bytes; the same tests under mode OFF assert the
legacy columns. Mutating the consumer to fall back to per-scalar width makes the
mode-ON assertions fail. This permanently subsumes the earlier per-scalar fix:
the pinned table is no longer the source of truth for grid-derived text.

### M4 — Conformance fixture + end-to-end handshake demo

- Create `Tests/LabanCoreTests/TerminalWidthConformanceTests.swift` (and/or a
  `LabanTerminalCore` C test) with a table of the spec's hard cases driven through
  the real engine in **both** modes:
  `a` (1/1), `中` (2/2), `👩‍🌾` (4 off / 2 on), `🏳️‍⚧️` (transgender flag, ZWJ),
  `🇸🇪` (regional pair), `👋🏽` (skin-tone modifier), `각` (Hangul), `क्षि`
  (Devanagari cluster), `▶️`/`▶︎` (VS16/VS15). For each, assert engine cell width
  + cursor advance + scrollback find/copy column.
- Provide a documented, scriptable **end-to-end demo** a human can run: a short
  program that does the DECRQM handshake (`printf '\e[?2027$p'`, read reply),
  prints the farmer emoji, and reports the negotiated width — used as the manual
  acceptance transcript. Capture the transcript in `Artifacts and Notes`.

**Acceptance:** `swift test --filter TerminalWidthConformanceTests` passes; the
documented demo transcript shows Laban replying `ESC [ ? 2027 ; 1 $ y` after
`?2027h` and the emoji occupying 2 columns.

### M5 — Settings UI for Unicode width

**Why it matters:** mode 2027 is normally negotiated by the running program, but a
user has no way to express a *default* preference or to make modern TUIs that
*don't* negotiate (or that assume an always-on terminal, like programs tuned for
wezterm) render emoji correctly. This milestone adds a first-class, discoverable
preference in Laban's native Settings window. A user can open Settings, pick how
Laban should treat Unicode width, and see emoji line up — without any program
sending an escape sequence.

**Where the settings UI lives (orientation, so this milestone is self-contained):**
Laban has one native settings window, `Sources/LabanApp/SettingsWindowController.swift`
(~375 lines). Each preference is a row built from either an `NSPopUpButton` (multi-
choice, e.g. `cursorStylePopUp`, `scrollModePopUp`, `identityPopUp`) or an
`NSButton(checkboxWithTitle:)` (toggle, e.g. `restoreCheckbox`, `blinkCheckbox`),
labelled with the `makeLabel(_:)` helper, and a `@objc` change handler that writes
to a typed settings store. The typed stores live in `Sources/LabanCore/*Settings.swift`
(e.g. `CursorSettings.swift`, `ScrollSettings.swift`, `TerminalIdentitySettings.swift`,
`Persistence/RestoreOnLaunchSettings.swift`); each wraps a `UserDefaults` key with
static `current`/`set(...)` accessors over a small enum. Copy that exact pattern.

**What to build:**

1. **New typed store** `Sources/LabanCore/GraphemeWidthSettings.swift` mirroring
   `TerminalIdentitySettings.swift`: an enum
   `GraphemeWidthMode { case auto, preferGrapheme }` persisted under a
   `UserDefaults` key (e.g. `"LabanGraphemeWidthMode"`), default `.auto`. Plain
   English of each option:
   - **Auto (recommended, default):** a new terminal session starts with mode 2027
     OFF; programs opt in by sending `ESC [ ? 2027 h`. This is today's behavior and
     the safe default (see the `fish` rationale in the Decision Log).
   - **Prefer grapheme width:** a new session starts with mode 2027 ON, so emoji and
     clusters use grapheme width immediately; a program can still turn it off with
     `ESC [ ? 2027 l` (the per-session default is a starting point, not a lock — this
     matches Ghostty, where a program's DECSET/DECRST overrides the configured
     default).
   - (A third "force legacy / ignore program toggles" lock is intentionally **not**
     shipped here — it needs an engine "frozen mode" capability, like Contour's
     `frozen_dec_modes`, that the current C API does not expose. Note it as future
     work in M6.)

2. **New Settings row.** In `SettingsWindowController.swift`, add a
   `graphemeWidthPopUp = NSPopUpButton(...)` with the two titles ("Auto
   (recommended)", "Prefer grapheme width"), a `makeLabel("Unicode width")`, an
   `@objc graphemeWidthChanged(_:)` handler calling `GraphemeWidthSettings.set(...)`,
   and initialize its selection from `GraphemeWidthSettings.current` in the same
   place the other popups are populated. Place it logically near the cursor/scroll
   rows.

3. **Apply the preference to the engine at session start.** When a session is
   created (the C entry is `laban_session_create` in
   `Sources/LabanTerminalCore/include/LabanTerminalCore.h`; the Swift backend
   wiring is around `TerminalBackendSettings.swift` / session setup in
   `LabanCore`), if the mode is `.preferGrapheme`, set the engine mode ON right
   after creation using the same call `terminal_effects.c` already uses for other
   modes — `ghostty_terminal_mode_set(terminal, GHOSTTY_MODE_GRAPHEME_CLUSTER,
   true)`. For `.auto`, do nothing (engine default is OFF). Either add an initial-
   mode field to `LabanLaunchConfig` or set it immediately post-create; pick one in
   a Decision Log entry. Existing sessions are unaffected until they restart (state
   the preference applies to *new* sessions; do not retroactively toggle live
   sessions, to avoid the mid-session reflow the Decision Log warns about).

4. **Observability/parity (hard rule):** the `GET /debug/terminal-modes` endpoint
   from M1 already reports the effective 2027 state; that is sufficient to verify
   the setting's effect headlessly (a fresh session under `.preferGrapheme` reports
   2027 active before any program output).

**Acceptance (observable):**
- A `LabanAppTests` test constructs `SettingsWindowController`, selects "Prefer
  grapheme width", and asserts `GraphemeWidthSettings.current == .preferGrapheme`
  and the `UserDefaults` key is written (mirror the existing settings tests, e.g.
  the cursor/restore settings tests).
- A headless test sets `GraphemeWidthSettings` to `.preferGrapheme`, starts a fresh
  session, and asserts `GET /debug/terminal-modes` reports `grapheme_cluster_2027:
  true` **before** any program sends a sequence; with `.auto` it reports `false`
  until a program sends `ESC [ ? 2027 h`.
- Manual: open Settings, switch "Unicode width" to "Prefer grapheme width", open a
  new tab, `printf '👩‍🌾'`, and observe a single 2-cell emoji (capture screenshot
  in Artifacts).

### M6 — Elite polish (optional)

- Write/append an ADR under `docs/adr/` recording the mode-2027 contract: engine is
  the single source of truth, factory default OFF/opt-in with a user-selectable
  "prefer grapheme width" default, DECRPM semantics, and the kitty-text-sizing-
  protocol non-goal. (Check `docs/adr/README.md` first.)
- Note as future work: a "force legacy / freeze mode against program toggles"
  setting option, which needs an engine frozen-mode capability (cf. Contour
  `frozen_dec_modes`) not in the current C API.
- Update `Sources/LabanCore/TerminalDisplayWidth.swift` doc comment to reflect its
  demoted role (fallback, not the model).

## Decision Log

- Decision: Mode 2027 default stays **OFF** (opt-in by the running program via
  DECSET); Laban never enables it unilaterally.
  Rationale: The Ghostty author's write-up documents that enabling grapheme
  clustering unilaterally broke `fish` — the shell assumed legacy `wcwidth` while
  the terminal used clustering, so the prompt redrew in the wrong place. The mode
  exists precisely so programs negotiate it. Every correct implementation
  (ghostty, contour, foot) defaults OFF and falls back to legacy width when off;
  wezterm is the outlier (permanently on). Opt-in is the safe, spec-aligned choice.
  Date/Author: 2026-06-19, plan author.
- Decision: The terminal **engine (`libghostty-vt`) is the single source of truth**
  for grapheme segmentation and width. The Swift side consumes the engine's width;
  it must not re-implement UAX #29 segmentation.
  Rationale: Laban already drives ghostty's full terminal model and snapshots its
  per-cell width and cluster bytes. Re-deriving widths in Swift (the current pinned
  table) is exactly what causes drift. One source of truth eliminates whole classes
  of disagreement and tracks Unicode updates with the vendored engine.
  Date/Author: 2026-06-19, plan author.
- Decision: Kitty's **text-sizing protocol is out of scope** (non-goal).
  Rationale: It is a separate OSC-based mechanism; kitty deliberately does not
  implement mode 2027. Supporting both is a larger, independent effort. Record as
  future work in M5.
  Date/Author: 2026-06-19, plan author.
- Decision: Treat M0 as a **characterization milestone** before any code change.
  Rationale: PLANS.md encourages prototyping/measurement when feasibility hinges on
  unknowns. The central unknown is "how much already works through libghostty"; M0
  measures it so M1–M3 target real gaps.
  Date/Author: 2026-06-19, plan author.
- Decision: Laban reports DECRPM **SET (1) / RESET (2)** for mode 2027 — i.e. a
  genuinely toggleable mode — not PERMANENTLY_SET/RESET (3/4).
  Rationale: Laban delegates all width to `libghostty-vt`, which truly implements
  grapheme-cluster width and toggles the mode, so the mode is genuinely
  on/off-able. This differs from `foot`, which reports PERMANENTLY_RESET when its
  configured width method cannot conform to the spec — Laban has no such
  width-method caveat. Whatever value M0 actually observes the engine emit must be
  recorded here and treated as authoritative; if the engine reports 3/4 for its own
  reasons, defer to it rather than overriding.
  Date/Author: 2026-06-19, plan author (folded in from independent review).
- Decision: The "Unicode width" Settings preference (M5) sets the **per-session
  starting default** for mode 2027; a program's `DECSET/DECRST 2027` still
  overrides it at runtime. Laban ships two options (Auto = start OFF; Prefer
  grapheme width = start ON). A hard "freeze / ignore the program's toggle" option
  is deferred.
  Rationale: Setting-as-default-with-program-override matches Ghostty's model and is
  implementable with the existing C API (`ghostty_terminal_mode_set` at session
  start). A true freeze would need an engine frozen-mode capability (cf. Contour's
  `frozen_dec_modes`) the vendored C API does not expose, so it is out of scope for
  this plan. The preference applies to *new* sessions only — live sessions are not
  retroactively toggled, to avoid a mid-session grid reflow.
  Date/Author: 2026-06-19, plan author (settings UI added per user request).

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan is
considered complete. The executing agent must not mark the plan done until this
gate passes. See `../../PLANS.md` "Review gate and review-fix loop".

- [x] `./scripts/build-app` exits 0 at the review commit (built `LabanApp`,
      `laband`, `labpty`).
- [x] `swift test` exits 0 — **1673 tests, 7 skipped, 0 failures**.
- [x] M1: `testMode2027HandshakeAndSnapshotField` asserts `?2027h`→snapshot field
      true + `\e[?2027;1$y` and `?2027l`→false + `\e[?2027;2$y`; `/debug/terminal-modes`
      registered (`DebugHTTPServer.swift:122`) reading `grapheme_cluster_2027`, wired
      in both `HeadlessDebugRuntime`/`DebugStateEndpoints` and the GUI path
      `MainWindowController`/`TerminalBitmapView` (parity). Snapshot field
      `LabanTerminalCore.h:132`, populated `snapshot.c:621`.
- [x] M2: `Mode2027GridConformanceTests` hard-codes ON/OFF `(wide, advance)` per
      cluster (farmer ON adv 2 vs OFF adv 4), CSI 6n cross-check; render proof
      `FrameProducerGraphemeClusterTests` asserts a single glyph run. Mutation
      sensitivity confirmed by the reviewer (reading the literals).
- [x] M3: `Mode2027ScrollbackWidthTests` returns column 2 (not 4) for the farmer ON
      and exact cluster bytes on copy; `testMutationGuard_*` proves the scalar path
      would give 4. Versioned `*_extract2_alloc` added; v1 functions intact.
- [x] M4: `Tests/LabanCoreTests/TerminalWidthConformanceTests.swift` exists and
      passes (7 tests); it covers ASCII, CJK, ZWJ emoji (farmer + trans flag),
      regional indicator, skin-tone modifier, Hangul, Devanagari cluster, and
      VS15/VS16 under both modes (grid layout + cursor advance + CSI 6n cross-check
      + scrollback find columns + scrollback copy bytes), with hard-coded ON
      literals and a mutation-guard test. The end-to-end handshake demo
      (`testHandshakeDemo_negotiateThenPrintFarmer`) asserts the DECRPM replies and
      `ESC[1;3R`; transcript captured in Artifacts and Notes.
- [x] M5: `GraphemeWidthSettings.swift` exists, default `.auto`; `GraphemeWidthHeadlessTests`
      asserts `.preferGrapheme`→`grapheme_cluster_2027: true` before output, `.auto`→false,
      plus DECSET/DECRST override; the "Unicode width" popup is wired in
      `SettingsWindowController.swift`.
- [x] M3 regression guard: `TerminalFindTests` (13), `TerminalSelectionTests` (21),
      `TerminalDisplayWidthTests` (8) all exit 0 with byte-identical counts; the
      regression test files were not modified by any milestone commit, yet they
      drive the new v2 `scrollbackBlock` path under mode-OFF.
- [x] No regression to MVP behavior: the change is additive (new files + versioned
      C entry points; legacy regression suites unmodified; `GraphemeWidthSettings`
      defaults OFF); confirmed mechanically by the regression guard + full `swift test`.

Review status: **PASSED** (2026-06-19). Independent fresh-state review verified all
six load-bearing factual claims against source and every gate item by static
inspection; verdict ALL PASS. The two Low findings it raised were then closed:
(1) `TerminalSelection.plainLineTextFromClusters` gained an under-tiling guard
mirroring `TerminalFind.rowBufferFromClusters`; (2) a wrapped multi-screen-row
alignment test (`testWrappedMultiRowClusterWidthsAlignPerScreenRow`) was added.
Authoritative closeout: `swift test` = 1673 tests / 0 failures, `./scripts/build-app`
exit 0.

Review findings (filled in by the review agent):

- ALL PASS. Cross-cutting notes (both Low, now addressed): under-tiling guard added
  to the selection consumer; wrapped-row width coverage added. Locking and
  headless/GUI parity verified correct; commit hygiene exemplary (one milestone per
  commit).

## Validation and Acceptance

- Automated: `swift test` green, with the new `Mode2027CharacterizationTests`,
  `Mode2027GridConformanceTests`, scrollback coherence tests, and
  `TerminalWidthConformanceTests`. Each new behavioral test must fail before its
  milestone's change and pass after (note the red→green transition in `Progress`).
- Headless: `GET /debug/terminal-modes` reflects 2027 on/off after DECSET/DECRST.
- Manual end-to-end (capture transcript in Artifacts): with a debug build installed
  to `~/Laban-2027.app`, run a probe such as
  `printf '\e[?2027$p'` (observe the DECRPM reply), then
  `printf '\e[?2027h👩‍🌾\e[6n'` and confirm the cursor report shows a
  2-column advance.

## Idempotence and Recovery

- M0/M2/M4 are additive (tests + a read-only debug field) and safe to re-run.
- M1 touches the response-drain only if M0 proves a gap; otherwise it is
  verification-only. M3 is the one behavior-changing milestone — it is additive
  (carry metadata, consume when present, keep the pinned table as fallback), so the
  mode-OFF default path is preserved and the change is revertible per file. M3's
  scrollback metadata is a **transient query result** (`ScrollbackBlock` is rebuilt
  on demand, never serialized) and is not referenced by the capture/replay or
  laband multi-client code, so it cannot break replay determinism; still, add the
  new C surface as a versioned entry point so old signatures keep working.
- Rebuilding the vendored engine is **not** part of this plan: `libghostty-vt`
  already ships mode 2027 in `zig-out/lib`. If a future engine bump is needed,
  that is a separate change (rebuild Zig lib + re-vendor); call it out in
  `Surprises & Discoveries` if M0 reveals the vendored build lacks the mode.
- A regenerated `.rpg/graph.json` alone marks a build `+dirty`; if a built bundle
  "doesn't work", verify `Info.plist:LABANBuildCommit` matches HEAD before
  debugging source.

## Artifacts and Notes

### M4 — End-to-end handshake demo (manual transcript + automated stand-in)

A human reproduces the negotiation against an installed debug build
(`LABAN_INSTALL_PATH="$HOME/Laban-2027.app" ./scripts/install-app`, then launch
Laban yourself — never `open` it from a shell). In a Laban tab:

```sh
# 1) Ask whether mode 2027 is active (DECRQM). Default is OFF, so the reply is
#    ESC [ ? 2027 ; 2 $ y  (";2" = RESET). Pipe through cat -v to see the bytes.
printf '\e[?2027$p' ; sleep 0.1 ; echo        # reply: ^[[?2027;2$y

# 2) Enable mode 2027 (DECSET), re-query — now SET (";1").
printf '\e[?2027h' ; printf '\e[?2027$p' ; sleep 0.1 ; echo   # reply: ^[[?2027;1$y

# 3) With mode 2027 ON, print the farmer emoji then ask the cursor position
#    (CSI 6n). It reports column 3 — the cursor after a 2-cell cluster printed
#    at column 1, i.e. the emoji occupied exactly 2 columns.
printf '\e[?2027h\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\x8C\xBE\e[6n' ; sleep 0.1 ; echo
#    reply: ^[[1;3R
```

Expected transcript (DECRPM reply bytes / cursor report), based on M0's measured
values and confirmed by the automated test below:

| Step | Sent | Laban replies |
|---|---|---|
| DECRQM (OFF) | `ESC [ ? 2027 $ p` | `ESC [ ? 2027 ; 2 $ y` (RESET) |
| DECSET | `ESC [ ? 2027 h` | (none) |
| DECRQM (ON) | `ESC [ ? 2027 $ p` | `ESC [ ? 2027 ; 1 $ y` (SET) |
| print 👩‍🌾 + DSR | `…F09FA791E2808DF09F8CBE… ESC [ 6 n` | `ESC [ 1 ; 3 R` (col 3 ⇒ 2-cell advance) |

Because a GUI run is not scriptable here, the automated stand-in is
`TerminalWidthConformanceTests.testHandshakeDemo_negotiateThenPrintFarmer`
(`Tests/LabanCoreTests/TerminalWidthConformanceTests.swift`): it runs the exact
sequence through a real fixture session and asserts the DECRQM reply bytes
(`ESC[?2027;2$y` then `ESC[?2027;1$y`) AND the resulting cursor report
(`ESC[1;3R`). Result: **PASS**.

### M4 — Conformance table (measured 2026-06-19 through the real bridge)

Per grapheme, OFF (default) vs ON (`ESC[?2027h`). Grid = per-cell `wide` (`N`
narrow, `W` wide head, `T` spacer tail); adv = `cursor_col` advance, which equals
the engine's own `CSI 6n` column − 1 in every row (grid agrees with what a
program is told); find = scrollback find end-column. Copy returns the exact input
bytes in both modes (carries text, not width). Pinned as literals in
`TerminalWidthConformanceTests`.

| Grapheme | OFF grid / adv / find | ON grid / adv / find |
|---|---|---|
| `a` U+0061 | N / 1 / 1 | N / 1 / 1 |
| `中` U+4E2D | W T / 2 / 2 | W T / 2 / 2 |
| farmer U+1F9D1 ZWJ U+1F33E | W T W T / 4 / 4 | W T / 2 / 2 |
| trans flag U+1F3F3 FE0F ZWJ U+26A7 FE0F | N N / 2 / 2 | W T / 2 / 2 |
| regional `🇸🇪` U+1F1F8 U+1F1EA | W T W T / 4 / 4 | W T / 2 / 2 |
| skin-tone `👋🏽` U+1F44B U+1F3FD | W T W T / 4 / 4 | W T / 2 / 2 |
| Hangul `각` U+AC01 | W T / 2 / 2 | W T / 2 / 2 |
| Devanagari `क्षि` U+0915 U+094D U+0937 U+093F | N N N / 3 / 3 | W T / 2 / 2 |
| VS16 `▶️` U+25B6 U+FE0F | N / 1 / 1 | W T / 2 / 2 |
| VS15 `▶︎` U+25B6 U+FE0E | N / 1 / 1 | N / 1 / 1 |

Measured nuances (NOT engine gaps — each agrees with the engine's own CSI 6n):
- **Trans flag OFF = two NARROW cells (advance 2).** Both emoji bases (🏳 U+1F3F3,
  ⚧ U+26A7) stay narrow with mode OFF because their VS16 emoji-presentation only
  widens under clustering — the same VS16 nuance the standalone `▶️` row shows.
- **Devanagari OFF = three NARROW cells (advance 3), ON = one WIDE+tail (advance
  2).** The legacy rule does not collapse the conjunct (the virama U+094D combines
  to 0, but the two consonants + the vowel sign each take a cell); clustering folds
  the whole human-perceived grapheme into one 2-cell unit. So Devanagari is
  *narrower-per-cell but more cells* OFF, and a compact 2-cell cluster ON.
- **Hangul precomposed U+AC01 = WIDE+tail in both modes** — no surprise, a single
  2-cell syllable; clustering does not change it.

Research sources consulted while authoring (knowledge embedded above; links for
provenance only — the plan is self-contained without them):

- Spec: "Terminal Unicode Core" by Christian Parpart (Contour author), repo
  `contour-terminal/terminal-unicode-core` (spec defines mode 2027 + DECRPM).
- Mitchell Hashimoto (Ghostty), "Grapheme Clusters and Terminal Emulators":
  the opt-in/default-off rationale (fish breakage), the DECRQM + `CSI 6n`
  detection handshake, and the `👩‍🌾` 4-vs-2 example.
- Reference implementations (via DeepWiki):
  - **ghostty** (`ghostty-org/ghostty`): mode `grapheme_cluster`; `print()` uses
    `unicode.graphemeBreak()`; cluster code points stored on the cell +
    spacer-tail for wide; VS16/VS15 explicit; config `grapheme-width-method`.
    This is the engine Laban vendors.
  - **contour** (`contour-terminal/contour`): `DECMode::Unicode` = 2027;
    `graphemeClusterWidth` (base width, VS16 forces 2); DECRQM handshake.
  - **foot** (`dnkl/foot` PR #1489): toggles "grapheme shaping" at runtime; ties
    spec conformance to its `grapheme-width-method=double-width`; reports
    "permanently reset" via DECRQM when the width method can't conform.
  - **wezterm**: mode 2027 *permanently enabled* (query-only); uses
    `finl_unicode` grapheme iterator + HarfBuzz shaping.
  - **kitty**: does **not** implement 2027; uses its own OSC text-sizing protocol
    (the M5 non-goal).
- Code map (this repo, measured during authoring): `Package.swift` (links
  `libghostty-vt.a`); `Sources/LabanTerminalCore/{snapshot.c, terminal_effects.c,
  pty_io.c, decscusr.c, include/LabanTerminalCore.h}`; `.external/libghostty-vt/
  include/ghostty/vt/{modes.h, terminal.h, screen.h, grid_ref.h}`;
  `Sources/LabanCore/{TerminalDisplayWidth.swift, TerminalSelection.swift,
  TerminalFind.swift, FrameProducer.swift}`;
  `Sources/LabanApp/{TerminalSelectionInput.swift, TerminalBitmapView.swift}`.

## Surprises & Discoveries

- Observation: Mode 2027 is largely already wired end-to-end via `libghostty-vt`.
  The C API exposes `GHOSTTY_MODE_GRAPHEME_CLUSTER` (2027), DECRPM report values
  0–4, and `ghostty_mode_report_encode`; Laban forwards all child bytes to the
  engine and the engine emits DECRQM replies through the `WRITE_PTY` callback;
  the snapshot already carries each cell's full grapheme cluster bytes plus the
  engine's `wide` flag. The real work is therefore *verification + Swift-side
  width coherence + conformance*, not implementing the mode from scratch.
  Evidence: `.external/libghostty-vt/include/ghostty/vt/modes.h:93,152-185`;
  `Sources/LabanTerminalCore/snapshot.c:325-407`;
  `Sources/LabanTerminalCore/terminal_effects.c` (mode get/set + response drain);
  `.external/libghostty-vt/include/ghostty/vt/terminal.h:~409` (WRITE_PTY callback).
- Observation (M0 measured, 2026-06-19 — every assumption CONFIRMED, no gaps).
  Farmer emoji `👩‍🌾` (`F0 9F A7 91 E2 80 8D F0 9F 8C BE`) through the real bridge:
  | Measure | Mode OFF (default) | Mode ON (`\e[?2027h`) |
  |---|---|---|
  | cursor advance | 4 cols (two WIDE+spacer clusters: `[👩‍ZWJ]`, `[🌾]`) | 2 cols (one WIDE+spacer, full 11 bytes in head cell) |
  | DECRQM `\e[?2027$p` reply | `\e[?2027;2$y` (RESET=2) | `\e[?2027;1$y` (SET=1) |
  | `\e[6n` cursor report | `\e[1;5R` (col 5) | `\e[1;3R` (col 3) |
  Evidence: `Tests/LabanTerminalCoreTests/Mode2027CharacterizationTests.swift`.
  Sharpening for M2: OFF is **not** strictly per-codepoint — the engine forms two
  grapheme clusters (`[👩‍ZWJ]` and `[🌾]`), each one WIDE cell + spacer tail; the
  ZWJ rides with the head cluster rather than becoming its own zero-width cell.
  M2's OFF-mode assertions must expect this layout, not four singleton cells.
- Observation: The DECRQM drain is already proven for another mode. The test
  `Tests/LabanTerminalCoreTests/LabanSessionTests.swift:~2659`
  (`testDECRQMModeQueryUsesTerminalState`) writes `\e[?7$p` and asserts the engine
  replies `\e[?7;1$y` through Laban's bridge. So the handshake *mechanism* is
  verified end-to-end; only 2027-specific support is unmeasured. This is the
  copy-paste template for M0/M1.
  Evidence: independent review of this plan, 2026-06-19.
- Resolved (M0 Probe E, 2026-06-19): the scrollback extraction
  (`laban_session_scrollback_extract`) is **String-only — it carries no width at
  all**, and crucially it does **not** re-derive width under the current mode (it
  simply has none). So M3 can capture the engine's width at extraction time and
  thread it through; it does **not** need to snapshot per-row width at the moment a
  row scrolls off. This is the cleaner of the two possible outcomes and removes the
  one place the "single source of truth" claim could have silently failed.
