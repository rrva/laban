# Make Laban trustworthy for Chinese macOS developers

This ExecPlan is a living document maintained in accordance with `../../PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add
optional sections only when they contain information that will help a fresh
contributor. A fresh contributor should be able to read only this file and the
current working tree and proceed.

## Purpose / Big Picture

Laban is a native macOS terminal emulator (Swift/AppKit + Metal rendering; VT
parsing delegated to the vendored `libghostty-vt` C/Zig library). This plan's
thesis: **Chinese developers will not love Laban because it has a Chinese UI.
They will love it if Chinese text input and rendering are boringly correct under
their daily terminal workflows** — Apple Pinyin and Rime/Squirrel composition,
mixed Chinese/English, CJK double-width cells, ambiguous-width characters, emoji
prompts, Nerd Font / Powerline symbols, tmux, vim/neovim, lazygit/fzf/starship,
and copy/paste with legacy remote systems. Trust in text input and rendering is
prioritized over broad product polish (localization, proxy/jump-host, visual
effects).

After this work a Chinese developer can: type `中文` with Apple Pinyin or
Rime/Squirrel and see the candidate window at the cursor and the committed text
land in the right cells; run a Hanzi-dense TUI (vim, lazygit, fzf, starship) and
see crisp, vertically-aligned glyphs that do not overflow their cells; see emoji
and Powerline prompts render correctly; and copy/paste CJK through SSH without
column drift or truncation. Every fix is proven by an automated test, a debug
endpoint, or a screenshot/capture artifact, per the `AGENTS.md`
autonomous-verifiability rule.

**This plan does not assume the source audit is correct.** Milestone 0 records,
with `file:line` evidence, exactly what is already correct (a large fraction),
what is genuinely broken, and what is absent. Several audit hypotheses were
**refuted or narrowed** by direct source reading (see the verified-gaps table)
so nobody re-investigates them.

### Glossary (define before use)

- **CJK**: Chinese / Japanese / Korean ideographic text. A Han ideograph such as
  `中` occupies **two** terminal columns ("double-width" / "wide").
- **Cell / column**: one fixed-width slot in the terminal grid. A wide glyph
  occupies two cells: a head cell (`WIDE`) and an empty placeholder
  (`SPACER_TAIL`).
- **Display width**: how many cells a piece of text occupies. For grid text the
  engine (`libghostty-vt`) decides this; Laban must consume that decision, never
  re-derive it (ADR 0021).
- **IME (input method editor)**: the OS subsystem that turns keystrokes into CJK
  text. macOS exposes it through the `NSTextInputClient` protocol. Apple Pinyin
  and Rime/Squirrel are two IMEs Chinese developers use daily.
- **Preedit / marked text**: the in-progress, not-yet-committed composition the
  IME shows (e.g. the pinyin letters and the candidate window). AppKit reports it
  through `hasMarkedText()` / `setMarkedText(...)`. Preedit text has **not entered
  the terminal grid**, so the engine has no width for it; Laban sizes it with a
  Swift fallback width helper.
- **Ambiguous-width character**: a Unicode character (UAX #11 class "A", e.g.
  `±`, `§`, arrows, some box-drawing) that East-Asian contexts traditionally
  render two cells wide and Western contexts one cell wide.
- **East Asian Width (UAX #11)**: the Unicode annex that classifies each code
  point as Narrow / Wide / Ambiguous / etc.
- **Grapheme cluster / DEC mode 2027**: a user-perceived character possibly made
  of several code points (emoji ZWJ sequences, flags, combining marks). DEC
  private mode 2027 makes the terminal measure width per-cluster instead of
  per-code-point. Owned by ADR 0021 (see Context); this plan **consumes** it.
- **Color / bitmap glyph**: Apple Color Emoji glyphs are stored as color bitmaps
  (`sbix`/`COLR` tables), not monochrome outlines. They have **no Bézier outline**.
- **Renderer backends**: `software` (CPU bitmap; headless/fixtures/capture),
  `classic` (Metal, the default), `gpuDriven` (Metal GPU-cell path, opt-in on
  macOS 26), and the in-progress opt-in `vectorGlyph` (ADR 0022).
- **HeadlessDebugRuntime parity (hard rule)**: any new subsystem must be wired
  into both `Sources/LabanApp/MainWindowController.swift` `makeAndShow` and
  `Sources/LabanDebug/HeadlessDebugRuntime.swift`, with an HTTP debug endpoint
  for autonomous verification.

## Progress

- [x] (2026-06-20) Plan authored. Six independent fresh-state verification agents
      re-checked every audit claim against current source; results folded into the
      Milestone 0 verified-gaps and deferred tables with `file:line` evidence. Key
      corrections to the audit hypothesis recorded (Metal preedit bug is
      `gpuDriven`-only; scrollback/find/copy/word-select/IME-caret width already
      fixed by ADR 0021 + the 2026-06-19 bug audit; OSC 52 already shipped; no
      legacy CJK encodings exist anywhere).
- [ ] M0 — Evidence and scope lock (this revision establishes it; keep current).
- [ ] M1 — Chinese text trust gate fixture.
- [ ] M2 — CJK font pairing and metrics.
- [ ] M3 — IME/preedit correctness (Metal `gpuDriven` preedit display-column fix).
- [ ] M4 — Width policy coherence (verify single truth; ambiguous-width policy).
- [ ] M5 — Emoji / color glyph path.
- [ ] M6 — Keyboard and paste polish.
- [ ] M7 — Product polish and ecosystem (zh-Hans / proxy / vibrancy) — deferred,
      spec-gated.
- [ ] Review Gate passed.

Milestones are ordered by trust priority. M1–M3 are highest value and have no
inter-dependencies (they may land in any order or in parallel). M4 consolidates
the width story. M5 is orthogonal renderer work. M6 is small high-value polish.
M7 is product-scope and gated on `docs/product/spec.md` amendments.

## Context and Orientation

Read this as if you know nothing about Laban. Every path is repository-relative
from the repo root `~/wrk/laban`. Build with `./scripts/build-app` (assembles the
bundle; **never** `swift build` alone for the app). Run tests with `swift test`.
Do **not** `open`/launch `Laban.app` from a shell — it grabs a single-instance
lock; for live checks install with
`LABAN_INSTALL_PATH="$HOME/Laban-cjk.app" ./scripts/install-app` and let the user
launch it. Verify the running bundle's `Info.plist:LABANBuildCommit` matches HEAD
before debugging a "shipped fix that doesn't work".

### How width truth flows today (the load-bearing architecture)

ADR 0021 (`docs/adr/0021-dec-mode-2027-grapheme-cluster-width.md`) settled the
width contract: **`libghostty-vt` is the single source of truth for grapheme
segmentation and display width.** Laban consumes the engine's per-cell `wide`
flag for live cells and engine-carried per-grapheme width for scrolled-off rows;
it never re-derives UAX #29 boundaries or cluster width in Swift. The Swift
helper `Sources/LabanCore/TerminalDisplayWidth.swift` is a **demoted fallback**
for text that never entered the grid (its own doc comment, lines 3–13, says it is
"no longer the source of truth"; `isWide(_:)` at lines 30–82 is a hardcoded
per-Unicode-scalar legacy table, **not** generated UAX #11 data).

The scrollback width plumbing is already built and shipped:
`ScrollbackBlock.graphemeWidths` (`Sources/LabanCore/TerminalFind.swift:40-56`,
field at `:44`) carries engine width, populated by the versioned C extraction
`laban_session_scrollback_extract2_alloc`
(`Sources/LabanTerminalCore/include/LabanTerminalCore.h:809-821`) via
`Session.scrollbackBlock` (`Sources/LabanCore/Session.swift:870-955`).
Scrollback find (`TerminalFind.swift:156-159` engine path, `:234-247` fallback)
and copy (`TerminalSelection.swift:284-314`, fallback at `:307`) are **engine-first
with the pinned table only as a fallback**. So the two prior efforts (ADR 0021 M3
and the 2026-06-19 bug audit M2) layered correctly; there is no conflicting second
width truth to untangle.

### What this plan must NOT duplicate (overlapping ExecPlans)

| Plan | Owns | This plan's relationship |
|---|---|---|
| ADR 0021 + `execplans/active/dec-mode-2027-grapheme-cluster-support.md` | Engine width source-of-truth; `GraphemeWidthSettings` (`auto`/`preferGrapheme`); scrollback width; `GET /debug/terminal-modes`; `TerminalWidthConformanceTests`. | **Consume.** Do not re-derive width. M4 verifies the boundary holds; it does not add a second truth. |
| `execplans/active/user-facing-bug-audit-fixes-2026-06-19.md` (M2 done) | Scrollback find/copy column drift, word-selection of CJK/emoji, IME caret/mask width (BUG-12/13/24/25). | **Do not redo.** The remaining preedit gap (M3 here) is the `gpuDriven` Metal overlay only, which that plan did not touch. |
| `execplans/active/kimi-code-terminal-capability-gaps.md` (not started) | Kitty inline images (M2), tmux/screen DCS passthrough unwrap (M3), emoji/grapheme width conformance suite (M4). | **Cross-reference.** tmux *escape-sequence* trust (OSC under tmux) depends on its M3; this plan exercises tmux *text* rendering only. M1's fixture consumes its width conformance model. |
| `execplans/active/glyph-correctness-matrix.md` (M0 partial) | Cross-renderer glyph corpus: cell occupancy / width / fallback-font parity across software/classic/gpuDriven, incl. CJK + emoji as *width* cases. | **Coordinate.** M2 extends its corpus with CJK-font-pairing cases; it does not fork a second renderer test harness. |
| `execplans/active/vector-glyph-renderer.md` (active) | Opt-in `vectorGlyph` renderer (runtime Bézier rasterization). Explicitly **defers** color/bitmap emoji to "the existing color/bitmap path" (`vector-glyph-renderer.md:759-761,774-777`). | **Orthogonal.** M5's color-emoji work is new; coordinate via Decision Log so the vector plan's "existing color path" becomes real instead of monochrome. |
| `execplans/completed/native-text-input-ime-fixes.md` | Basic IME routing: `route(hasMarkedText:)`, `unmarkText()` on commit, `firstRect` computed from the cursor cell. | **Build upon.** Already shipped; M3 extends correctness, does not redo routing. |

### Key files (verified by fresh-state agents, 2026-06-20)

| Area | File:line |
|---|---|
| Grapheme-width default setting | `Sources/LabanCore/GraphemeWidthSettings.swift:17-30` |
| Swift fallback width table (per-scalar, demoted) | `Sources/LabanCore/TerminalDisplayWidth.swift:3-13, 30-82` |
| Preedit mask width (FrameProducer) — **correct** | `Sources/LabanCore/FrameProducer.swift:577` |
| **Metal `gpuDriven` preedit width — BUG** | `Sources/LabanRenderer/MetalRenderer.swift:2732, 2744` |
| IME caret cells — **correct** | `Sources/LabanApp/TerminalBitmapView.swift:3696` |
| `NSTextInputClient` (setMarkedText/insertText/firstRect/hasMarkedText) | `Sources/LabanApp/TerminalBitmapView.swift:3681, 3661, 3742, 3737` |
| preedit wiring into snapshot | `Sources/LabanApp/TerminalBitmapView.swift:2069-2070` |
| Marked-text key routing | `Sources/LabanApp/TerminalInputView.swift:76, 99` (called `TerminalBitmapView.swift:3628`) |
| Preedit frame command source | `Sources/LabanRenderer/FrameCommand.swift` (`FrameSource.preedit`) |
| Primary font resolution (user → JetBrains Mono → Menlo) | `Sources/LabanRenderer/FontAtlas.swift:75-94`; bundled in `Package.swift:49-50` |
| Terminal-UI-symbol fallback (no CJK) | `Sources/LabanRenderer/TerminalGlyphFallback.swift:6-11, 38-68, 83-98` |
| Cell metrics from primary font 'M' | `Sources/LabanRenderer/FontAtlas.swift:150-161` |
| CJK fallback via CoreText cascade | `Sources/LabanRenderer/MetalGlyphAtlas.swift:383-393, 395-402` |
| **Glyph atlas is R8 monochrome alpha mask** | `Sources/LabanRenderer/MetalGlyphAtlas.swift:124, 89, 295-307`; shader `Sources/LabanRenderer/Shaders.metal:131, 133-134, 86` |
| Paste → UTF-8 | `Sources/LabanApp/TerminalClipboard.swift:19,22`; `Sources/LabanCore/Session.swift:1279`; `Sources/LabanApp/TerminalBitmapView.swift:4336` |
| Bracketed paste mode check | `Sources/LabanApp/TerminalBitmapView.swift:4364`; `Sources/LabanCore/Session.swift:1258-1265` |
| OSC 52 clipboard (base64/UTF-8, ADR 0014) | `Sources/LabanCore/OSC52Clipboard.swift`; `Sources/LabanApp/TerminalClipboard.swift:40,49-56` |
| Copy trailing-trim (ASCII `\s` only; U+3000 preserved) | `Sources/LabanCore/TerminalSelection.swift:353-355` |
| `.option` → `.alt` modifier mapping | `Sources/LabanApp/TerminalInputView.swift:439` |
| Settings window (global-only; no profiles, no Option-as-Meta) | `Sources/LabanApp/SettingsWindowController.swift:16-29` |
| `ssh://`/`telnet://` URL→argv | `Sources/LabanCore/TerminalURLCommand.swift:1-40`; `Sources/LabanApp/AppDelegate.swift:136-158` |
| Reduce-Transparency opaque clamp (only transparency code) | `Sources/LabanCore/FrameProducer.swift:23-26` |
| Debug endpoints / fixtures / screenshot | `docs/process/dev-process.md` (`/debug/atlas`, `/debug/screenshot`, `/debug/frame-commands`, `/debug/terminal-modes`, `/debug/actions`, `/debug/pixel-probe`) |

## Plan of Work

### Milestone 0 — Evidence and scope lock

**Goal:** confirm current state with `file:line` evidence, refute/narrow the
audit's wrong hypotheses, and avoid duplicate work. No implementation.

**Verified gaps (real, in scope here):**

| # | Gap | Evidence | Verdict | Milestone |
|---|---|---|---|---|
| G1 | Grapheme/DEC2027 default; Swift fallback over-counts clusters | `TerminalDisplayWidth.swift:30-82` per-scalar table; ADR 0021 default OFF/`.auto` (`GraphemeWidthSettings.swift:17-30`) | Real but **mostly settled**; remaining question is a *product policy* (should Chinese-developer default be `preferGrapheme`?), not a code bug | M4 (Decision) |
| G2 | IME preedit display-column bug in Metal `gpuDriven` overlay | `MetalRenderer.swift:2732` `CGFloat(text.count)*glyphCellAdvance`; `:2744` `for (cellIndex, cluster) in text.enumerated()` (one cell per Character) | **CONFIRMED real bug**, narrowed: only `gpuDriven`; `classic`/`software` use `FrameProducer.swift:577` which is display-width-correct | M3 |
| G3 | Ambiguous-width policy; no UAX #11 data; no ambiguous-as-wide setting | `TerminalDisplayWidth.swift:30-82` hardcoded ranges; no setting in `SettingsWindowController.swift:16-29` | Real **design gap**; engine owns live-grid width, so this is fallback-overlay + policy only | M4 |
| G4 | CJK font pairing & cell-metric correctness | Single primary font `FontAtlas.swift:75-94`; CJK absent from `TerminalGlyphFallback.swift:83-98`; CJK → CoreText cascade `MetalGlyphAtlas.swift:395-402`; metrics from primary 'M' `FontAtlas.swift:150-161` | **CONFIRMED**: no dual-font architecture, no CJK-specific metric guarantee | M2 |
| G5 | Color emoji renders monochrome / tofu | `MetalGlyphAtlas.swift:124` `.r8Unorm`, `:295-307` `alphaOnly`; shader `Shaders.metal:131` samples `.r`; no `kCTFontColorGlyphsTrait`/`sbix`/`COLR` detection anywhere | **CONFIRMED**; **no existing plan owns it** (vector plan defers it to a path that is monochrome) | M5 |
| G6 | No legacy CJK paste/copy encodings; U+3000 trim unverified | `GBK/GB18030/iconv/CFStringEncoding/Big5/Shift_JIS` = **0 hits** repo-wide; trim is ASCII `\s` (`TerminalSelection.swift:353-355`) | **CONFIRMED absent**; U+3000 is **preserved, not trimmed** (correct) | M6 (investigation) / deferred |
| G7 | No Option-as-Meta setting; IME candidate-key safety | No toggle `SettingsWindowController.swift:16-29`; no `macos_option_as_alt` in C API `LabanTerminalCore.h:1186-1233`; `.option`→`.alt` at `TerminalInputView.swift:439`; candidate keys protected by `hasMarkedText` guard at `TerminalInputView.swift:99` | Setting **absent** (real gap); candidate-key safety **already correct** (verify-only) | M6 |
| G8 | zh-Hans localization absent | no `.lproj`/`NSLocalizedString`/`.xcstrings`; hardcoded English `MenuCommands.swift:13,18,27` | **CONFIRMED absent**; needs spec amendment | M7 (deferred) |
| G9 | Proxy/jump-host/cloud-profile ecosystem absent | no `SOCKS`/`proxy`/`ProxyJump`; `ssh://` handler is argv-only (`TerminalURLCommand.swift`); cloud-sync is MVP non-goal (`mvp.md:86`) | **CONFIRMED absent**; needs spec amendment | M7 (deferred) |

**Deferred / won't-fix (corrected audit hypotheses — do not re-investigate):**

| Item | Why deferred / corrected | Evidence |
|---|---|---|
| "Scrollback find/copy/word-select/IME-caret drift on CJK/emoji" | **Already fixed** by ADR 0021 M3 + bug audit M2 (engine-first width + pinned fallback) | `TerminalFind.swift:156-159`; `TerminalSelection.swift:284-314`; `TerminalBitmapView.swift:3696`; `FrameProducer.swift:577` |
| "FrameProducer preedit uses `text.count`" | **Refuted** — it uses `TerminalDisplayWidth.cells(of:)` | `FrameProducer.swift:577` |
| "OSC 52 may be missing/UTF-8 only" | **Refuted** — shipped (ADR 0014), base64+UTF-8, write-on/read-opt-in | `OSC52Clipboard.swift`; `TerminalClipboard.swift:40,49-56` |
| "Soft-wrapped copy joins wrong" | **Already handled** + owned by another plan | `TerminalSelection.swift:101-117`; `execplans/active/terminal-copy-unwraps-soft-wrapped-lines.md` |
| "U+3000 may be wrongly trimmed on copy" | **Refuted** — ASCII `\s` regex does not match U+3000; ideographic space preserved | `TerminalSelection.swift:353-355` |
| "Flip mode 2027 globally" | **Out of scope** — ADR 0021 mandates opt-in default OFF (fish/wcwidth regression risk) | `docs/adr/0021-...:55-67` |
| GB18030/GBK paste/copy conversion | **Deferred to M6 investigation, likely P3** — no evidence many users hit it daily; modern remote stacks are UTF-8 | G6 |
| zh-Hans UI, proxy/jump-host, cloud profiles, vibrancy/transparency | **Deferred to M7, spec-gated** — product scope, not text correctness | G8, G9; `spec.md` (no authorization) |

**Spec/ADR conflicts:** none that block M1–M6. M2 may require a new ADR (CJK
font-pairing/metrics policy — decide in M2). M4's ambiguous-width decision stays
inside the ADR 0001/0021 engine boundary. M5 (color atlas) and M7 (zh-Hans /
proxy) require, respectively, an ADR and `spec.md` amendments (Decision Log).

**Validation (M0):** no implementation; this ExecPlan cites every relevant file
with `file:line`; every proposed milestone below has explicit acceptance
criteria; the verified-gaps and deferred tables above are complete.

### Milestone 1 — Chinese text trust gate fixture

**Goal:** one reproducible acceptance scenario proving Laban handles real Chinese
developer text, runnable headlessly and observable through the debug harness, so
every later milestone has a single red/green trust signal instead of synthetic
unit-only checks.

**What to build.** A checked-in fixture under `fixtures/cjk/` (a `.fixture.json`
loadable via `POST /debug/fixture {"action":"load",...}`, per
`docs/process/dev-process.md` "Test Fixture Mode") plus a Swift end-to-end test
in `Tests/LabanDebugTests/` (e.g. `ChineseTrustGateTests.swift`) that loads it,
advances frames, and asserts via debug endpoints. The fixture emits a single
screenful covering:

- mixed Chinese/English prompt line (`用户@主机 ~/项目 $ npm run build`);
- a full-width CJK block (dense Hanzi paragraph) to check alignment;
- ambiguous-width samples (`± § ° ← → ↑ ↓ │ ┌ ┐`) on their own row;
- an emoji/ZWJ prompt segment (`✳ 🧑‍💻 🇨🇳 ▶️`);
- a Nerd Font / Powerline row (`    `) with graceful skip
  if the bundled font lacks them (assert via `/debug/atlas` `missingCodepoints`);
- a box-drawing UI frame with Chinese text inside it (`│ 设置 │`);
- (where feasible in fixture mode) a `tmux` and a `vim`/`neovim` redraw segment —
  if a real-shell smoke variant is needed, gate it as a sanitized smoke session
  per `docs/process/dev-process.md` and note tmux *escape-sequence* fidelity is
  owned by `kimi-code-terminal-capability-gaps.md` M3.

The manual companion (documented transcript in Artifacts) lists the **Apple
Pinyin** and **Rime/Squirrel** steps a human runs against an installed
`~/Laban-cjk.app` build: compose `中文`, observe the candidate window at the
cursor, commit, and confirm cell placement.

**Validation (M1):**
- Predicted files: `fixtures/cjk/trust-gate.fixture.json`,
  `Tests/LabanDebugTests/ChineseTrustGateTests.swift`, and a documented manual
  transcript in this plan's Artifacts.
- Tests/fixtures: `ChineseTrustGateTests.testTrustGateRendersWithoutMissingGlyphs`
  (asserts `/debug/atlas` `missing == 0` for non-PUA rows, or records the PUA
  skips), `...testWideCellAlignment` (asserts wide cells lay head+spacer via
  `/debug/frame-commands?source=terminal`).
- Debug/artifact: `GET /debug/screenshot?target=terminal` PNG captured for each
  renderer; `GET /debug/atlas` for missing-glyph/cell-metric check;
  `GET /debug/frame-commands` for cell occupancy.
- `./scripts/build-app` exit 0; `swift test --filter ChineseTrustGate` green.
- Renderer parity: capture the fixture through `software`, `classic`, and
  `gpuDriven` and compare cell occupancy (frame-command equivalence) — exact-RGBA
  where the renderers claim parity, non-blank where font-dependent.
- HeadlessDebugRuntime: the fixture loads in headless mode (primary CI gate);
  GUI parity is the same fixture loaded interactively.
- Rollback: fixture + test are additive; deleting them is the rollback.

### Milestone 2 — CJK font pairing and metrics

**Goal:** make Hanzi crisp, aligned, and predictable. Today there is a single
primary font (`FontAtlas.swift:75-94`) and CJK is left to CoreText's automatic
cascade (`MetalGlyphAtlas.swift:395-402`) with no metric guarantee; the
bounded-advance check (`TerminalGlyphFallback.swift:52-66`, `≤ cellAdvance*1.25`)
applies **only** to the terminal-UI-symbol path (`isSingleCellTerminalUIScalar`,
`:83-98`), which **excludes CJK**. So a Hanzi glyph can render from whatever font
CoreText picks, with an ascent/descent/advance that need not match the cell
derived from the primary font's 'M' (`FontAtlas.swift:150-161`).

**Must specify (deliverables of this milestone's design + implementation):**
- **Candidate fonts** to evaluate as the CJK pair: PingFang SC (system, always
  present, not monospaced), Noto Sans Mono CJK, Sarasa Gothic / Sarasa Term SC
  (designed to pair with a Latin monospace at 2:1 cell ratio).
- **Fallback order**: define an explicit CJK cascade (primary → bundled/system CJK
  pair → CoreText cascade) so CJK no longer silently depends on `CTLine`'s default
  cascade. Implement via `kCTFontCascadeListAttribute` or an explicit CJK branch
  in `MetalGlyphAtlas`/`TerminalGlyphFallback` so software and Metal share one
  decision (the glyph-correctness-matrix invariant: renderers must not drift).
- **Cell metric policy**: a CJK glyph must occupy exactly two cells with ink that
  stays inside `2*cellWidth × cellHeight`, baseline aligned to the primary font's
  baseline. Extend the wide-glyph tile sizing (`MetalGlyphAtlas.swift:254-268`) to
  clamp/scale a mismatched CJK fallback rather than overflow or misalign.
- **Settings/preset UI** (if needed): whether to surface a "CJK font" pick or a
  preset alongside the existing Font row (`SettingsWindowController.swift`). Decide
  in Decision Log; default to zero new UI if the system pair is good enough.
- **Bundling decision**: whether to bundle a CJK font (license + binary size) or
  rely on system PingFang SC. Decision Log entry required.
- **ADR**: write a CJK font-pairing/metrics ADR if this establishes durable
  policy (it likely does — a dual-font cascade is an architecture boundary).

**Validation (M2):**
- Predicted files: `Sources/LabanRenderer/TerminalGlyphFallback.swift`,
  `Sources/LabanRenderer/MetalGlyphAtlas.swift`,
  `Sources/LabanRenderer/FontAtlas.swift`; possibly
  `Sources/LabanApp/SettingsWindowController.swift` + a new
  `Sources/LabanCore/*FontSettings.swift`; possibly `docs/adr/00NN-cjk-font-pairing.md`.
- Tests: extend `Tests/LabanRendererTests/GPUCellParityTests` and the
  `glyph-correctness-matrix` corpus (`glyph-correctness-matrix.md:115-118`) with
  CJK pairing cases (`界 語 니 中文`) asserting two-cell occupancy + sentinel-cell
  preservation across software/classic/gpuDriven; new
  `CJKFontMetricsTests.testHanziInkStaysInTwoCells`.
- Debug/artifact: `GET /debug/atlas` reports the chosen CJK font + `missing == 0`;
  `POST /debug/screenshot` artifacts for: dense Chinese text; mixed ASCII+Chinese;
  Chinese inside box-drawing UI; Chinese next to Nerd Font symbols; Chinese at
  multiple font sizes and Retina (scale=1/2). Captured for each renderer.
- `./scripts/build-app` exit 0; `swift test --filter 'GPUCellParity|CJKFontMetrics'` green.
- Renderer parity: software vs classic vs gpuDriven cell occupancy equal for CJK
  cases (frame-command/raw-RGBA where supported).
- HeadlessDebugRuntime: `/debug/atlas` works headlessly; screenshots from the
  offscreen software surface.
- Rollback: keep the current single-font path behind the new cascade so removing
  the CJK branch restores prior behavior byte-identically (predictable-font CI
  rule, `dev-process.md` "Determinism").

### Milestone 3 — IME/preedit correctness

**Goal:** make Chinese composition stable in **all** renderers. The
`classic`/`software` preedit path is already correct (`FrameProducer.swift:577`
uses `TerminalDisplayWidth.cells(of:)`; caret at `TerminalBitmapView.swift:3696`
likewise). The verified bug is the **`gpuDriven` Metal overlay**: it lays preedit
out itself, one cell per `Character`.

**Exact bug surface (verified):**
- `Sources/LabanRenderer/MetalRenderer.swift:2732` —
  `width: CGFloat(text.count) * glyphCellAdvance` (uses grapheme/Character count,
  not display columns).
- `Sources/LabanRenderer/MetalRenderer.swift:2744` —
  `for (cellIndex, cluster) in text.enumerated()` with `col = baseCol + cellIndex`
  (advances one column per Character; a wide CJK preedit cluster must advance two).
- Consequence: composing `中文` (or a clustered emoji) in the `gpuDriven` renderer
  draws the preedit underline/mask and candidate anchor at the wrong columns.

**Source path from `NSTextInputClient` to renderer (trace, for the fix):**
`setMarkedText` (`TerminalBitmapView.swift:3681`) sets `markedText` +
`markedTextCaretCells` (`:3696`, display-width-correct) → snapshot carries
`preedit`/`preeditCaretCells` (`:2069-2070`) → `FrameProducer` emits preedit
glyph-run/mask commands with `FrameSource.preedit` (`FrameProducer.swift:577`,
correct) → `classic` Metal consumes those commands verbatim → **`gpuDriven`
overlay re-derives placement itself at `MetalRenderer.swift:2707-2760` (the bug)**.

**Fix:** replace the `text.count` width and per-`Character` loop in the
`gpuDriven` overlay with the same display-width source the rest of the stack uses
(`TerminalDisplayWidth.cells(of:)`, advancing two columns per wide cluster), or —
preferably — make the overlay consume the `FrameProducer`-emitted preedit columns
instead of recomputing, eliminating the second computation entirely. Keep
`TerminalDisplayWidth` as the fallback here because preedit text never entered the
grid (ADR 0021 class-B consumer; engine has no width for it).

**Test additions + manual acceptance (the trust core):**
- Extend `Tests/LabanCoreTests/FrameProducerPreeditTests.swift`
  (`testOverlayCommandsEmitPreeditForGPUCellPath` exists) with a **wide-CJK
  preedit at a nonzero cursor column** asserting the overlay column equals the
  display-width column (red before fix, green after); mutate to `text.count` →
  the test fails.
- Add an emoji/ZWJ preedit case if feasible (clustered emoji preedit advance = 2).
- Add a preedit-under-redraw case (tmux/neovim) at the fixture level (M1) where
  feasible.
- Manual: Apple Pinyin composing `中文`; Rime/Squirrel composing Chinese text;
  wide CJK preedit at a nonzero cursor column; candidate window at cursor (relies
  on `firstRect`, `TerminalBitmapView.swift:3742`). Capture screenshots in Artifacts
  for the `gpuDriven` renderer specifically.

**Validation (M3):**
- Predicted files: `Sources/LabanRenderer/MetalRenderer.swift`,
  `Tests/LabanCoreTests/FrameProducerPreeditTests.swift`.
- Tests: `FrameProducerPreeditTests` new wide-CJK/emoji preedit cases;
  `swift test --filter FrameProducerPreedit` green; mutation guard documented.
- Debug/artifact: `/debug/frame-commands?source=preedit` shows the corrected
  columns; `gpuDriven` screenshot artifact of `中文` composition.
- `./scripts/build-app` exit 0; `swift test` green.
- Renderer parity: after the fix, `classic` and `gpuDriven` preedit columns match
  for the same composition (assert equal frame-command preedit rects).
- HeadlessDebugRuntime: preedit state is exercised through the snapshot path; the
  overlay test runs without a window.
- Rollback: single-function change in the `gpuDriven` overlay; `classic`/`software`
  paths untouched, so reverting restores prior `gpuDriven` behavior. Compatibility:
  `gpuDriven` is opt-in (macOS 26), so blast radius is bounded.

### Milestone 4 — Width policy coherence

**Goal:** ensure grapheme, CJK, ambiguous-width, and overlay/preedit width policies
do not diverge — one truth (the engine) for grid text, one explicit fallback for
non-grid text — and decide the ambiguous-width product policy.

**Must specify:**
- **Engine/app boundary (verify, don't add a second truth):** confirm every
  grid-derived width consumer reads the engine (snapshot `wide` flag or
  `ScrollbackBlock.graphemeWidths`), and `TerminalDisplayWidth` is used **only**
  for non-grid text (preedit, word-classification). Mechanical check: grep that no
  *new* grid consumer calls `TerminalDisplayWidth.cells(of:)`/`isWide(_:)` outside
  the documented fallback sites (`FrameProducer.swift:577`,
  `TerminalBitmapView.swift:3696`, `TerminalFind.swift:247`,
  `TerminalSelection.swift:307`, and the M3-fixed Metal overlay).
- **Session mode-2027 threading into overlay/preedit helpers:** since preedit is
  sized by the Swift fallback, document that the fallback intentionally uses legacy
  per-scalar width and that this is acceptable for not-yet-committed text (ADR 0021
  class-B). If a session defaults to `preferGrapheme`, note that committed text
  still gets engine width; only the transient preedit uses the fallback.
- **Ambiguous-width policy decision (Decision Log):** choose one — (a) keep
  engine-as-truth for grid (no app-layer ambiguous override; ambiguous chars get
  whatever the engine assigns), (b) add a user setting "ambiguous = wide" that maps
  to a libghostty capability **iff** one is exposed (investigate the C API; if
  absent it is **unsupported**, not a Swift second-truth), or (c) locale policy.
  Default recommendation: (a) unless the C API exposes an ambiguous-width knob,
  because option (b)-in-Swift would violate the ADR 0001/0021 boundary.
- **Fallback helper replacement or isolation:** keep `TerminalDisplayWidth` as the
  documented fallback; do **not** regenerate it into a UAX #11 table (that would
  invite re-creating a second width truth). Its hardcoded ranges
  (`TerminalDisplayWidth.swift:30-82`) are acceptable for preedit sizing.
- **Compatibility risks:** document the fish/wcwidth regression that forced
  mode-2027 opt-in (ADR 0021), so any "default to grapheme width for Chinese
  users" recommendation (G1) is made with eyes open.

**Validation (M4):**
- Predicted files: mostly verification + docs; possibly
  `Sources/LabanCore/TerminalDisplayWidth.swift` (doc only) and a Decision Log
  entry; an ambiguous-width setting only if the C API supports it.
- Tests: a grep-based guard test or Review-Gate check that grid consumers don't
  introduce a second width truth; reuse `TerminalWidthConformanceTests` (ADR 0021)
  as the engine-truth oracle.
- Debug/artifact: `GET /debug/terminal-modes` proves the effective 2027 mode;
  conformance test prints the width table.
- `./scripts/build-app` exit 0; `swift test --filter 'TerminalWidthConformance|Mode2027'` green.
- Renderer parity: N/A (width is renderer-independent) — but confirm the M3 fix
  keeps `classic`/`gpuDriven` equal.
- HeadlessDebugRuntime: `/debug/terminal-modes` already wired both runtimes (ADR 0021).
- Rollback: documentation/guard-only; no behavioral change unless an ambiguous
  setting is added (then it is additive and default-off).

### Milestone 5 — Emoji / color glyph path

**Goal:** render Apple Color Emoji in color (or make a deliberate, documented
choice not to) without breaking terminal cell metrics. Verified state: the glyph
atlas is **R8 monochrome** (`MetalGlyphAtlas.swift:124` `.r8Unorm`; `:295-307`
`alphaOnly` grayscale context; shader samples `.r` and tints,
`Shaders.metal:131,133-134`). There is **no** color/bitmap-glyph detection
(`kCTFontColorGlyphsTrait`/`CTFontCreatePathForGlyph` nil-check/`sbix`/`COLR` =
0 hits). Color emoji therefore render as monochrome silhouettes or tofu. **No
existing ExecPlan owns the fix:** `vector-glyph-renderer.md:759-761` defers color
emoji to "the existing color/bitmap path", but that path is monochrome;
`glyph-correctness-matrix.md` only covers emoji *width*, not color.

**Must specify:**
- **Interaction with the vector glyph renderer plan:** M5 is the "existing color
  path" the vector plan assumes. Coordinate so `vectorGlyph` routes bitmap/color
  glyphs to M5's color path (Decision Log + cross-link both plans). Do not
  duplicate the vector renderer's outline pipeline.
- **Color rendering strategy (Decision Log):** choose vector / bitmap / hybrid.
  Recommended: a **separate color (BGRA8) atlas** for detected color glyphs
  (detect via `CTFontGetSymbolicTraits` color trait or
  `CTFontCreatePathForGlyph == nil` on a bitmap font), rasterized with
  `CTFontDrawGlyphs` into a color CGContext, sampled full-RGBA in a new shader
  variant — leaving the R8 atlas + tint path unchanged for monochrome glyphs.
- **Cell-metric safety:** color emoji must still occupy the engine-assigned cells
  (one or two) without changing cell metrics — the M2/atlas wide-glyph clamp
  applies.
- **Tests/captures and mode-2027 behavior:** assert color (non-grayscale) pixels
  for an emoji via `/debug/pixel-probe`; assert two-cell occupancy in both
  mode-2027 ON and OFF (cluster vs per-scalar layout) via `/debug/frame-commands`.

**Acceptance scenarios (captures):** emoji in a prompt; emoji next to Chinese
text; emoji in the preedit/overlay path if supported (M3); mode-2027 ON/OFF
behavior. Captured for `software` and `classic`; `gpuDriven` if the color path is
wired there.

**Validation (M5):**
- Predicted files: `Sources/LabanRenderer/MetalGlyphAtlas.swift`,
  `Sources/LabanRenderer/Shaders.metal`,
  `Sources/LabanRenderer/SoftwareRenderer.swift`,
  `Sources/LabanRenderer/MetalRenderer.swift`; possibly a new
  `Sources/LabanRenderer/ColorGlyphAtlas.swift`; coordination note in
  `vector-glyph-renderer.md`; possibly `docs/adr/00NN-color-glyph-atlas.md`.
- Tests: `Tests/LabanRendererTests/ColorEmojiTests.testEmojiRendersWithColorPixels`
  (probe asserts R≠G≠B somewhere in the emoji cell); occupancy test reuses the
  glyph-correctness-matrix corpus.
- Debug/artifact: `POST /debug/pixel-probe` color assertion; `/debug/screenshot`
  emoji artifacts; `/debug/atlas` for the color atlas.
- `./scripts/build-app` exit 0; `swift test --filter 'ColorEmoji|GPUCellParity'` green.
- Renderer parity: software and classic both produce color emoji; if `gpuDriven`
  can't, it must fail-closed to `classic` for color-glyph cells (per
  glyph-correctness-matrix M2 graceful-fallback rule), not draw a blank.
- HeadlessDebugRuntime: color atlas works on the offscreen software surface
  (primary CI gate).
- Rollback: gate the color atlas behind a feature path; falling back to the R8
  path restores monochrome behavior. Compatibility: monochrome glyph path is
  byte-identical-preserved.

### Milestone 6 — Keyboard and paste polish

**Goal:** address smaller, high-value Chinese-developer workflow issues.

**Must specify:**
- **Option-as-Meta setting:** add a user setting so Option can act as Alt/Meta for
  terminal apps that want it, without breaking the "native text wins" rule.
  Verified state: `.option` maps to `.alt` (`TerminalInputView.swift:439`) but
  Option-produced text routes to native text with Option consumed
  (`TerminalKeyInputTests.swift:180-195`); there is **no** user toggle
  (`SettingsWindowController.swift:16-29`) and **no** `macos_option_as_alt` in the
  C API (`LabanTerminalCore.h:1186-1233`). Add a `GraphemeWidthSettings`-style
  store + a Settings row; the setting changes whether a bare Option chord (no text
  produced) encodes as Alt. Per-profile is out of scope (no profile architecture
  exists — global setting only).
- **IME candidate-key safety (verify-only):** confirm Space and digit keys 1–9
  (IME candidate selection) reach the IME during composition. Already correct: the
  `hasMarkedText` guard (`TerminalInputView.swift:99`) precedes app-command routing
  (tab-by-number), proven by
  `TerminalKeyInputTests.swift:15-18 testCommandKeyRoutesToNativeTextWhenMarkedTextExists`.
  Add an explicit digit-key-during-marked-text regression test.
- **GB18030/GBK investigation:** time-boxed investigation only (G6). No encoding
  library exists (0 hits). Decide scope in Decision Log; default **deferred to
  P3** unless evidence shows daily user pain. If pursued, add a fixture copying CJK
  through a legacy-locale remote and an opt-in conversion at the
  `TerminalClipboard`/`TerminalPaste` seam (never silently mangle UTF-8).
- **U+3000 copy/trim (verify-only):** confirmed preserved (`TerminalSelection.swift:353-355`
  trims ASCII `\s` only). Add a regression test asserting a trailing U+3000 is
  preserved (or, if product chooses, trimmed — Decision Log).
- **Bracketed paste with Chinese text:** add a test that pasting CJK with bracketed
  paste enabled (`TerminalBitmapView.swift:4364`; `Session.swift:1258-1265`)
  delivers exact UTF-8 bytes wrapped in the fence (ADR 0020 sanitizer preserved).

**Validation (M6):**
- Predicted files: `Sources/LabanApp/SettingsWindowController.swift`, a new
  `Sources/LabanCore/OptionKeySettings.swift`,
  `Sources/LabanApp/TerminalInputView.swift`;
  `Tests/LabanAppTests/TerminalKeyInputTests.swift`;
  `Tests/LabanCoreTests` paste/selection tests.
- Tests: `testOptionAsMetaSettingEncodesAltChord`,
  `testDigitKeyDuringMarkedTextRoutesToNativeText`,
  `testTrailingIdeographicSpacePreservedOnCopy`,
  `testBracketedPasteDeliversCJKBytesExactly`.
- Debug/artifact: `GET /debug/input-log` shows the Option routing decision;
  `GET /debug/clipboard` shows paste text + bracketed flag.
- `./scripts/build-app` exit 0; `swift test --filter 'TerminalKeyInput|TerminalPaste|TerminalSelection'` green.
- Renderer parity: N/A (input/clipboard).
- HeadlessDebugRuntime: drive via `/debug/actions` `typeText`/`paste`/`key`.
- Rollback: each is additive; the Option setting defaults to today's behavior
  (Option-as-text), so default behavior is unchanged.

### Milestone 7 — Product polish and ecosystem (deferred, spec-gated)

**Goal:** plan zh-Hans docs/UI, proxy/jump-host/cloud profiles, and terminal
visual polish **only if** product scope allows — and explain why these are lower
priority than text correctness.

**Must specify:**
- **spec.md amendment needs:** `docs/product/spec.md` currently authorizes none of
  zh-Hans localization, proxy/jump-host, cloud profiles, or window transparency
  (verified: 0 mentions). Each requires a `spec.md` amendment before
  implementation. Decision Log entries required.
- **Localization strategy (G8):** no i18n infrastructure exists (no `.lproj`,
  `NSLocalizedString`, `.xcstrings`; hardcoded English at `MenuCommands.swift:13,18,27`).
  zh-Hans UI means building i18n from scratch — a large product effort, **not** a
  text-correctness fix. Sequence it after M1–M6.
- **Proxy/jump-host scope (G9):** only an `ssh://`/`telnet://` URL→argv handler
  exists (`TerminalURLCommand.swift:1-40`); no SOCKS/ProxyJump/cloud profile. Scope
  is a product decision, not terminal-core correctness.
- **Terminal background vibrancy/transparency scope (P3):** no transparency feature
  exists (only the Reduce-Transparency opaque clamp, `FrameProducer.swift:23-26`).
  A vibrancy/opacity setting is pure polish.
- **Why lower priority:** none of these affect whether Chinese *text* is correct.
  The thesis is trust in input/rendering first; a Chinese UI on top of incorrect
  Hanzi rendering would not earn trust.

**Validation (M7):** no implementation until `spec.md` is amended. Acceptance for
this milestone is: Decision Log entries recording the required `spec.md` changes
and the explicit deferral, plus a note in `Progress`. If/when implemented, each
sub-item gets its own milestone with the full validation checklist.

## Validation and Acceptance

This plan is accepted only when every attempted milestone has its milestone-
specific acceptance evidence (above), the Review Gate (below) has passed in a
fresh context, and the repository gates are green:

- `./scripts/build-app` exits 0 (builds `LabanApp`, `laband`, `labpty`).
- `swift test` exits 0; record the passed count.
- The Milestone 1 trust-gate fixture proves a **real** Chinese workflow (mixed
  text + wide CJK + ambiguous-width + emoji/ZWJ + Powerline + box-drawing UI),
  observed through `/debug/screenshot`, `/debug/atlas`, and `/debug/frame-commands`
  across the software/classic/gpuDriven renderers — not a synthetic unit-only pass.
- The Metal `gpuDriven` preedit display-column bug (`MetalRenderer.swift:2732,2744`)
  is fixed and regression-locked.
- The width truth stays consistent with the libghostty/ADR 0021 boundary (no new
  Swift second-truth for grid text).
- IME acceptance includes both Apple Pinyin and Rime/Squirrel (manual transcript +
  screenshots in Artifacts).
- No regression to MVP behavior (`docs/product/mvp.md`), especially the glyph
  requirements (`mvp.md:290-294`: fixed-cell atlas, no ligatures/shaping, fallback
  must not change cell metrics).

## Decision Log

- Decision: **Do not assume the audit is correct; record refutations.**
  Rationale: direct source verification refuted/narrowed several claims (Metal
  preedit bug is `gpuDriven`-only; scrollback/find/copy/word-select/IME-caret width
  already fixed; OSC 52 already shipped; U+3000 already preserved; no legacy CJK
  encodings exist). Recording them prevents re-investigation.
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M4): **Whether `preferGrapheme` should be
  recommended/default for Chinese users.** Leaning: keep factory default `.auto`
  (mode 2027 OFF) per ADR 0021 — defaulting ON risks the documented fish/wcwidth
  prompt-redraw regression — but document `preferGrapheme` as a recommended *opt-in*
  for modern CJK/emoji workflows.
  Rationale/risk: ADR 0021 Decision Log (fish breakage). Resolve with evidence.
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M4): **Ambiguous-width-as-wide is a user setting,
  locale policy, or unsupported.** Leaning: **unsupported in Swift** unless the
  libghostty C API exposes an ambiguous-width knob (must not create a second width
  truth, ADR 0001/0021). If the engine exposes it, surface it as a setting.
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M2): **CJK dual-font architecture.** Adopt an
  explicit CJK cascade (primary Latin monospace + a CJK pair) shared by software
  and Metal, replacing reliance on CoreText's default `CTLine` cascade. Likely an
  ADR.
  Rationale: today CJK has no metric guarantee (`MetalGlyphAtlas.swift:395-402`).
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M2): **Whether bundled CJK fonts are acceptable.**
  Trade license + binary size (Sarasa/Noto) against relying on system PingFang SC.
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M5): **Color emoji path: vector, bitmap, or
  hybrid.** Leaning: a separate BGRA8 color atlas + color-glyph detection + a new
  shader variant (hybrid), leaving the R8 + tint path unchanged. This is the
  "existing color path" `vector-glyph-renderer.md` assumes; coordinate so it is no
  longer monochrome.
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M6): **Whether GB18030/GBK support is in scope.**
  Leaning: **deferred to P3** — zero encoding code exists and modern remote stacks
  are UTF-8; pursue only with evidence of daily user pain.
  Date/Author: 2026-06-20, plan author.
- Decision (open, to resolve in M7): **Whether zh-Hans / proxy / cloud profiles /
  vibrancy require product-spec amendment.** Finding: **yes** — `docs/product/spec.md`
  authorizes none of them today; each needs a spec amendment before implementation.
  Date/Author: 2026-06-20, plan author.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is considered complete. The executing agent must not mark the plan done until this
gate passes. See `../../PLANS.md` "Review gate and review-fix loop". Prefer
mechanical checks.

- [ ] `./scripts/build-app` exits 0 at the review commit; `swift test` exits 0
      (record passed count).
- [ ] All nine verified audit gaps (G1–G9 in Milestone 0) are each addressed by a
      milestone or explicitly deferred with a reason in the deferred table.
- [ ] The P0 trust gate (M1) proves a real Chinese workflow: the fixture
      `fixtures/cjk/trust-gate.fixture.json` exists and includes mixed Chinese/
      English, full-width CJK, ambiguous-width, emoji/ZWJ, a Powerline/Nerd-Font
      symbol, and a box-drawing UI with Chinese inside; the test asserts via
      `/debug/atlas`, `/debug/frame-commands`, and `/debug/screenshot`, not unit-
      only. Grep the fixture for at least one char in each category.
- [ ] M3: `grep -n 'text.count' Sources/LabanRenderer/MetalRenderer.swift` around
      the preedit overlay (was `:2732`) shows the display-width fix, and a
      `FrameProducerPreeditTests` case asserts a wide-CJK preedit column equals the
      display-width column; mutating it to `text.count` makes it FAIL.
- [ ] No duplicated work: this plan does not re-implement DEC mode 2027 width
      (ADR 0021), the bug-audit M2 scrollback/find/copy/word-select/IME-caret fix,
      the kimi-code Kitty-image/tmux-DCS/width-conformance work, the glyph-
      correctness-matrix harness, or the vector-glyph-renderer outline pipeline —
      verify by the cross-reference table in Context.
- [ ] Width truth consistency: grep shows no *new* grid-text consumer of
      `TerminalDisplayWidth.cells(of:)`/`isWide(_:)` outside the documented fallback
      sites (preedit, word-classification, scrollback fallback, the M3-fixed overlay).
- [ ] CJK rendering acceptance (M2) includes screenshot/capture artifacts for dense
      Chinese, mixed ASCII+Chinese, Chinese in box-drawing UI, Chinese next to
      Nerd-Font symbols, and multiple sizes/Retina, across software/classic/gpuDriven.
- [ ] IME acceptance includes both Apple Pinyin and Rime/Squirrel (manual transcript
      + screenshots recorded in Artifacts).
- [ ] HeadlessDebugRuntime parity: any new debug surface is wired into both
      `MainWindowController.makeAndShow` and `HeadlessDebugRuntime` (grep both).
- [ ] No regression to MVP behavior (`docs/product/mvp.md`), especially the glyph
      contract (`mvp.md:290-294`).
- [ ] No code was implemented by the planning revision (this gate item applies to
      the plan-authoring commit only; implementation milestones flip it as they land).

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Artifacts and Notes

- Verification provenance: six fresh-state agents (2026-06-20) re-checked every
  audit claim against current source; their `file:line` evidence is folded into
  Context and the Milestone 0 tables. Headline confirmations: Metal preedit width
  bug (`MetalRenderer.swift:2732,2744`); R8 monochrome atlas (`MetalGlyphAtlas.swift:124`);
  no dual-font (`FontAtlas.swift:75-94`); no legacy encodings (0 hits); no zh-Hans
  i18n; OSC 52 already shipped (ADR 0014).
- Overlapping ExecPlans (do not duplicate): `dec-mode-2027-grapheme-cluster-support.md`,
  `user-facing-bug-audit-fixes-2026-06-19.md`, `kimi-code-terminal-capability-gaps.md`,
  `glyph-correctness-matrix.md`, `vector-glyph-renderer.md`,
  `completed/native-text-input-ime-fixes.md`.
- Relevant ADRs: 0001 (libghostty owns VT parsing), 0014 (OSC 52), 0017
  (gpu-driven cell renderer), 0020 (paste sanitize), 0021 (DEC mode 2027 width),
  0022 (vector glyph renderer).
- Debug/acceptance surface (`docs/process/dev-process.md`): `/debug/atlas`
  (font/missing-glyphs/cell metrics), `/debug/screenshot`, `/debug/frame-commands`,
  `/debug/terminal-modes`, `/debug/pixel-probe`, `/debug/clipboard`,
  `/debug/input-log`, `/debug/actions` (typeText/paste/key/setFontSize),
  `/debug/fixture`; capture/replay via `./scripts/replay-capture`.
- Manual IME transcript (to fill on first execution): install
  `LABAN_INSTALL_PATH="$HOME/Laban-cjk.app" ./scripts/install-app`; with Apple
  Pinyin and then Rime/Squirrel, compose `中文`, screenshot the candidate window at
  the cursor and the committed cells, in `classic` and `gpuDriven` renderers.

## Idempotence and Recovery

- M0/M1/M4/M7 are additive (evidence, fixtures, docs, guards) and safe to re-run.
- M2/M3/M5/M6 are additive with explicit fallback paths: the CJK cascade (M2), the
  `gpuDriven` overlay fix (M3), the color atlas (M5), and the Option-as-Meta setting
  (M6) all preserve the prior default path so each is revertible per file and keeps
  the mode-OFF / monochrome / Option-as-text defaults byte-identical.
- A regenerated `.rpg/graph.json` alone marks a build `+dirty`; if a built bundle
  "doesn't work", verify `Info.plist:LABANBuildCommit` matches HEAD before debugging.
- In a git worktree, edit code with native Edit/Write (Serena symbolic edits escape
  the worktree to the root checkout); Serena read tools are safe.
