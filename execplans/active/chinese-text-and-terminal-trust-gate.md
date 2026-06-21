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
- [x] M1 — Chinese text trust gate fixture.
- [x] (2026-06-21) M2 — CJK font pairing and metrics. Implemented explicit
      shared CJK fallback policy, fixed two-cell CJK atlas metrics, `/debug/atlas`
      CJK diagnostics, focused renderer/debug tests, and ADR 0025. Automated
      validation passed; durable screenshot matrix artifacts were not captured in
      this execution and remain a Review Gate/manual artifact task.
- [x] (2026-06-21) M3 — IME/preedit correctness. Fixed the Metal `gpuDriven`
      preedit overlay to use the `FrameProducer` preedit rect width when present
      and per-cluster atlas logical width as fallback instead of `text.count` /
      one-column `Character` enumeration. `swift test --filter FrameProducerPreedit`
      passed 8 tests; `./scripts/build-app` passed. Manual gpuDriven IME
      screenshot artifacts remain to be captured.
- [x] (2026-06-21) M4 — Width policy coherence. Added
      `TerminalWidthPolicyGuardTests`, kept `preferGrapheme` as opt-in rather
      than default, rejected Swift-side ambiguous-width overrides without a
      libghostty C API knob, and recorded preedit width as an intentional
      non-grid `TerminalDisplayWidth` fallback.
- [x] (2026-06-21) M6 — Keyboard and paste polish. Added global
      Option-as-Meta setting plumbing through Settings, Swift key routing, C ABI,
      and `key_input.c`; preserved default Option-as-text behavior; preserved
      trailing U+3000 on copy by trimming only ASCII whitespace; and added
      IME candidate-key and bracketed CJK paste regressions.
- [x] (2026-06-21) M5 — Emoji / color glyph path. Added global
      `Emoji rendering: Monochrome / Color` setting, defaulted to Monochrome;
      implemented CoreText color-glyph detection, software color rendering,
      classic Metal BGRA `ColorGlyphAtlas` + shader path, debug state reporting,
      and a gpuDriven fail-closed route that keeps terminal commands available
      and uses the classic command path for color-glyph frames.
- [ ] M7 — Product polish and ecosystem (zh-Hans / proxy / vibrancy) — deferred,
      spec-gated.
- [ ] Review Gate passed.

Milestones are ordered by trust priority. M1–M3 are highest value and have no
inter-dependencies (they may land in any order or in parallel). M4 consolidates
the width story. **Execution order after M4 is M6 before M5**: land keyboard and
paste polish before the heavier emoji renderer work. M5 remains the color-emoji
milestone number because G5 maps to it, but its implementation must now include a
user-visible emoji rendering setting. M7 is product-scope and gated on
`docs/product/spec.md` amendments.

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
| Copy trailing-trim (`"\\s+$"` ICU regex — **also strips trailing U+3000**) | `Sources/LabanCore/TerminalSelection.swift:353-355` |
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
| G6 | No legacy CJK paste/copy encodings (absent); trailing U+3000 wrongly trimmed on copy | `GBK/GB18030/iconv/CFStringEncoding/Big5/Shift_JIS` = **0 hits** repo-wide; `rightTrim` uses `"\\s+$"` with `.regularExpression` (`TerminalSelection.swift:353-355`) — Foundation's ICU `\s` matches `\p{Z}`, so a trailing U+3000 IDEOGRAPHIC SPACE **is** stripped (verified empirically) | Legacy encodings **CONFIRMED absent** (P3); U+3000 trim is a **CONFIRMED copy-correctness bug / product decision** | M6 |
| G7 | No Option-as-Meta setting; IME candidate-key safety | No toggle `SettingsWindowController.swift:16-29`; the C encoder option **exists and is already wired** — `key_input.c:132-138` calls `ghostty_key_encoder_setopt(GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, …)` but hard-codes `GHOSTTY_OPTION_AS_ALT_FALSE` ("a future settings path can override this"); `.option`→`.alt` at `TerminalInputView.swift:439`; candidate keys protected by `hasMarkedText` guard at `TerminalInputView.swift:99` | Swift setting **absent** (real gap); the C API is **present, not missing** — plumb a toggle through to `key_input.c:136`; candidate-key safety **already correct** (verify-only) | M6 |
| G8 | zh-Hans localization absent | no `.lproj`/`NSLocalizedString`/`.xcstrings`; hardcoded English `MenuCommands.swift:13,18,27` | **CONFIRMED absent**; needs spec amendment | M7 (deferred) |
| G9 | Proxy/jump-host/cloud-profile ecosystem absent | no `SOCKS`/`proxy`/`ProxyJump`; `ssh://` handler is argv-only (`TerminalURLCommand.swift`); cloud-sync is MVP non-goal (`mvp.md:86`) | **CONFIRMED absent**; needs spec amendment | M7 (deferred) |

**Deferred / won't-fix (corrected audit hypotheses — do not re-investigate):**

| Item | Why deferred / corrected | Evidence |
|---|---|---|
| "Scrollback find/copy/word-select/IME-caret drift on CJK/emoji" | **Already fixed** by ADR 0021 M3 + bug audit M2 (engine-first width + pinned fallback) | `TerminalFind.swift:156-159`; `TerminalSelection.swift:284-314`; `TerminalBitmapView.swift:3696`; `FrameProducer.swift:577` |
| "FrameProducer preedit uses `text.count`" | **Refuted** — it uses `TerminalDisplayWidth.cells(of:)` | `FrameProducer.swift:577` |
| "OSC 52 may be missing/UTF-8 only" | **Refuted** — shipped (ADR 0014), base64+UTF-8, write-on/read-opt-in | `OSC52Clipboard.swift`; `TerminalClipboard.swift:40,49-56` |
| "Soft-wrapped copy joins wrong" | **Already handled** + owned by another plan | `TerminalSelection.swift:101-117`; `execplans/active/terminal-copy-unwraps-soft-wrapped-lines.md` |
| "U+3000 may be wrongly trimmed on copy" | **CONFIRMED — earlier refutation reversed.** `rightTrim`'s `"\\s+$"` uses `.regularExpression`; Foundation's ICU `\s` matches `\p{Z}`, so trailing U+3000 **is** stripped (verified empirically). Now a tracked item in G6/M6, **not** deferred. | `TerminalSelection.swift:353-355` |
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

**Staged assertions (so M1 is never a permanently-red CI gate).** M1 must not
introduce a test that fails until M2/M3/M5 land. The first `ChineseTrustGateTests`
asserts only **fixture-load and debug-endpoint integrity** (the fixture loads,
frames advance, and `/debug/atlas` / `/debug/frame-commands` / `/debug/screenshot`
respond) and records a **baseline artifact** (screenshots + atlas/frame-command
dumps) — it does **not** assert CJK-font metrics, preedit columns, or color-emoji
pixels yet. Each correctness assertion is enabled milestone-by-milestone as its fix
lands (M2 → font metrics, M3 → preedit columns, M5 → color pixels); the final
Review Gate flips the whole trust gate into a hard pass/fail requirement.

**Validation (M1):**
- Files implemented: `fixtures/cjk/trust-gate.fixture.json`,
  `Tests/LabanDebugTests/ChineseTrustGateTests.swift`, and this plan's Artifacts section.
- Tests/fixtures: `ChineseTrustGateTests.testTrustGateFixtureEndpointIntegrity`
  loads the fixture in headless mode, steps through all fixture rows, and asserts
  `/debug/atlas`, `/debug/frame-commands`, and `/debug/screenshot` are available.
- Debug/artifact: baseline endpoint payloads are persisted as
  `trust-gate-atlas.json`, `trust-gate-frame-commands.json`, plus the path
  returned by `POST /debug/screenshot`.
- `./scripts/build-app` exit 0; `swift test --filter ChineseTrustGate` green —
  baseline integrity assertions only at M1; correctness assertions activate as
  M2/M3/M5 land, so the gate is never red before its dependency ships.
- Renderer parity and multi-renderer snapshot comparisons are deferred to later
  milestones (M2/M3/M5).
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
  draws the preedit underline/mask/glyph cells at the wrong columns. The
  candidate-window anchor is driven separately by `firstRect`
  (`TerminalBitmapView.swift:3742`), **not** by this overlay, so it is confirmed by
  manual acceptance and is not the primary verified bug surface here.

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
- **Preedit width decision (resolved):** preedit text never entered the grid in this release,
  so engine width is unavailable and fallback sizing remains Swift-side via
  `TerminalDisplayWidth` at the documented callsites (`FrameProducer.swift:577`,
  `TerminalBitmapView.swift:3696`). This is the ADR 0021 class-B contract.
  Session-aware preedit width is deferred pending C API support for a non-grid text-width
  helper so the fallback remains intentional even if it can differ from committed text
  under mode 2027.
- **Ambiguous-width policy decision (resolved):** engine remains the grid truth for all
  production grid width (mode ON/OFF already includes whichever ambiguous behavior the
  negotiated engine mode chooses). Ambiguous-width overrides are **unsupported in Swift**
  because the libghostty C API exposes no ambiguous-width knob in this branch.
  Therefore no Swift setting was added here; adding one now would create a second width
  truth and conflict with ADR 0001/0021.
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
- **Emoji rendering setting:** surface a global user setting in Settings, e.g.
  `Emoji rendering: Color / Monochrome`. `Monochrome` must preserve today's R8
  tint path for compatibility and rollback. `Color` enables the new BGRA/color
  path. The setting must be exposed through the same runtime/debug state surfaces
  used by other renderer settings so headless tests can assert both modes.
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
  `Sources/LabanRenderer/MetalRenderer.swift`,
  `Sources/LabanApp/SettingsWindowController.swift`, a new
  `Sources/LabanCore/EmojiRenderingSettings.swift` or equivalent settings store;
  possibly a new `Sources/LabanRenderer/ColorGlyphAtlas.swift`; coordination note in
  `vector-glyph-renderer.md`; possibly `docs/adr/00NN-color-glyph-atlas.md`.
- Tests: `Tests/LabanRendererTests/ColorEmojiTests.testEmojiRendersWithColorPixels`
  (probe asserts R≠G≠B somewhere in the emoji cell); occupancy test reuses the
  glyph-correctness-matrix corpus; a setting test proves `Monochrome` keeps the
  legacy tint path and `Color` produces non-grayscale pixels.
- Debug/artifact: `POST /debug/pixel-probe` color assertion; `/debug/screenshot`
  emoji artifacts; `/debug/atlas` for the color atlas; debug state reports the
  effective emoji rendering setting.
- `./scripts/build-app` exit 0; `swift test --filter 'ColorEmoji|GPUCellParity'` green.
- Renderer parity: software and classic both produce color emoji; if `gpuDriven`
  can't, it must fail-closed to `classic` for color-glyph cells (per
  glyph-correctness-matrix M2 graceful-fallback rule), not draw a blank.
- HeadlessDebugRuntime: color atlas works on the offscreen software surface
  (primary CI gate).
- Rollback: gate the color atlas behind a feature path; falling back to the R8
  path restores monochrome behavior. Compatibility: the `Monochrome` setting keeps
  the current glyph path byte-identical where feasible.

### Milestone 6 — Keyboard and paste polish

**Goal:** address smaller, high-value Chinese-developer workflow issues.

**Must specify:**
- **Option-as-Meta setting:** add a user setting so Option can act as Alt/Meta for
  terminal apps that want it, without breaking the "native text wins" rule.
  Verified state: `.option` maps to `.alt` (`TerminalInputView.swift:439`) but
  Option-produced text routes to native text with Option consumed
  (`TerminalKeyInputTests.swift:180-195`); there is **no** user toggle
  (`SettingsWindowController.swift:16-29`). The C encoder API **does exist and is
  already wired** — `key_input.c:132-138` calls
  `ghostty_key_encoder_setopt(GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, …)` but
  hard-sets `GHOSTTY_OPTION_AS_ALT_FALSE` with the comment "a future settings path
  can override this." So the work is **not** "no C API exists" (G7's original
  evidence was wrong); it is to thread a Swift setting through `LabanKeyEvent` / the
  session down to that call site so the hardcoded `FALSE` becomes the setting's
  value. Add a `GraphemeWidthSettings`-style store + a Settings row; the setting
  changes whether a bare Option chord (no text produced) encodes as Alt. Per-profile
  is out of scope (no profile architecture exists — global setting only).
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
- **U+3000 copy/trim (CONFIRMED bug / product decision):** `rightTrim`
  (`TerminalSelection.swift:353-355`) uses `"\\s+$"` with `.regularExpression`;
  Foundation's ICU `\s` matches `\p{Z}`, so a trailing U+3000 IDEOGRAPHIC SPACE
  **is** stripped on copy (verified empirically). A trailing full-width space is
  meaningful in CJK text, so the default should likely be **preserve** — restrict
  the trim to ASCII spaces. Add a regression test for the chosen behavior and
  record the decision in the Decision Log.
- **Bracketed paste with Chinese text:** add a test that pasting CJK with bracketed
  paste enabled (`TerminalBitmapView.swift:4364`; `Session.swift:1258-1265`)
  delivers exact UTF-8 bytes wrapped in the fence (ADR 0020 sanitizer preserved).

**Validation (M6):**
- Predicted files: `Sources/LabanApp/SettingsWindowController.swift`, a new
  `Sources/LabanCore/OptionKeySettings.swift`,
  `Sources/LabanApp/TerminalInputView.swift`,
  `Sources/LabanTerminalCore/key_input.c` (replace the hardcoded
  `GHOSTTY_OPTION_AS_ALT_FALSE` at `:136` with the threaded setting),
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h` (carry the toggle on
  `LabanKeyEvent`), `Sources/LabanCore/Session.swift` (Swift→C plumbing),
  `Sources/LabanCore/TerminalSelection.swift` (U+3000 trim fix);
  `Tests/LabanAppTests/TerminalKeyInputTests.swift`, a new
  `Tests/LabanTerminalCoreTests/LabanSessionKeyEncodingTests.swift`;
  `Tests/LabanCoreTests` paste/selection tests.
- Tests: `testOptionAsMetaSettingEncodesAltChord`,
  `testDigitKeyDuringMarkedTextRoutesToNativeText`,
  `testTrailingIdeographicSpacePreservedOnCopy`,
  `testBracketedPasteDeliversCJKBytesExactly`.
- Debug/artifact: `GET /debug/input-log` shows Option routing (encoded route
  when option-as-Meta is on); `GET /debug/clipboard` shows paste text +
  bracketed flag.
- `./scripts/build-app` exit 0; `swift test --filter 'TerminalKeyInput|TerminalPaste|TerminalSelection'` green.
- Renderer parity: N/A (input/clipboard).
- HeadlessDebugRuntime: drive via `/debug/actions` `typeText`/`paste`/`key`.
- Rollback: each is additive; the Option setting defaults to today's behavior
  (Option-as-text), so default behavior is unchanged.

  Recommended M6 regression assertions:
  - `testOptionAsMetaSettingEncodesAltChord` (TerminalKeyInput / TerminalSessionKeyEncoding),
  - `testDigitKeyDuringMarkedTextRoutesToNativeText` (TerminalKeyInput),
  - `testTrailingIdeographicSpacePreservedOnCopy` (TerminalSelection),
  - `testBracketedPasteDeliversCJKBytesExactly` (TerminalPaste).

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
- M5 acceptance includes a user-visible `Emoji rendering` setting whose
  `Monochrome` mode preserves today's rendering path and whose `Color` mode
  proves non-grayscale emoji pixels.
- No regression to MVP behavior (`docs/product/mvp.md`), especially the glyph
  requirements (`mvp.md:290-294`: fixed-cell atlas, no ligatures/shaping, fallback
  must not change cell metrics).

## Decision Log

- Decision: **Do not assume the audit is correct; record refutations — and
  re-verify our own refutations.**
  Rationale: direct source verification refuted/narrowed several claims (Metal
  preedit bug is `gpuDriven`-only; scrollback/find/copy/word-select/IME-caret width
  already fixed; OSC 52 already shipped; no legacy CJK encodings exist). One earlier
  refutation was itself wrong: U+3000 is **not** preserved on copy — `rightTrim`'s
  `"\\s+$"` ICU regex strips it (verified empirically), now tracked in G6/M6.
  Date/Author: 2026-06-20, plan author.
- Decision (resolved, 2026-06-21): **Whether `preferGrapheme` should be recommended/default for Chinese users.**
  Keep factory default `.auto` (mode 2027 OFF) per ADR 0021 to avoid the fish/wcwidth
  prompt-redraw regression documented there. `preferGrapheme` is an explicit
  *opt-in* recommendation for workflows that prefer cluster width by default, and is
  already persisted as a start-mode preference only for fresh sessions.
  Date/Author: 2026-06-21, Codex.
- Decision (resolved, 2026-06-21): **Ambiguous-width-as-wide is a user setting, locale policy, or unsupported.**
  The C API currently has no ambiguous-width control surface. Therefore this Milestone
  resolves it as **unsupported**, keeping ambiguous-width behavior engine-owned for grid
  text and confined Swift fallback to non-grid text only.
  Date/Author: 2026-06-21, Codex.
- Decision (resolved, 2026-06-21): **Preedit width follows legacy fallback vs.
  session grapheme mode.** Keep legacy Swift fallback for preedit (not yet committed),
  documented at `TerminalDisplayWidth.swift` and measured in `FrameProducer.swift`/`MetalRenderer.swift`.
  Session-aware preedit width is explicitly deferred until libghostty exposes a non-grid
  width helper; committed text stays on engine width.
  Date/Author: 2026-06-21, Codex.
- Decision: **M2 uses an explicit shared CJK cascade and fixed two-cell atlas
  metrics.** The cascade is primary terminal font → PingFang SC → Noto Sans Mono
  CJK SC → Sarasa Term/Mono/Gothic SC → CoreText cascade. The software renderer
  and Metal atlas share `TerminalGlyphFallback` / `TerminalCJKFontPolicy`; Metal
  CJK atlas entries reserve exactly `2 * cellWidth` and scale down only if the
  fallback's natural ink would overflow those two cells.
  Rationale: this replaces unobservable CoreText-default CJK fallback with a
  deterministic font-pairing policy while preserving ADR 0021's engine-owned grid
  width. It is durable renderer policy, recorded in
  `docs/adr/0025-cjk-font-pairing-and-metrics.md`.
  Date/Author: 2026-06-21, Codex.
- Decision: **Do not bundle a CJK font or add CJK font UI in M2.** Rely on system
  PingFang SC first; keep Noto/Sarasa as explicit preferred candidates if a user
  has them installed.
  Rationale: local CoreText evidence on macOS selected `PingFangSC-Regular` with a
  valid Hanzi glyph and a 14 pt natural advance inside the 18 pt two-cell target.
  Bundling Noto/Sarasa would add license and binary-size cost without current
  evidence that PingFang is insufficient; a font picker is product/settings scope.
  Date/Author: 2026-06-21, Codex.
- Decision: **Execute M6 before M5, and make M5 user-controllable.**
  Rationale: keyboard/paste polish is smaller and should land before the higher-
  blast-radius color atlas work. Color emoji also needs an explicit compatibility
  escape hatch, so M5 must surface a global `Emoji rendering: Color / Monochrome`
  setting rather than silently replacing the monochrome path.
  Date/Author: 2026-06-21, user direction recorded by Codex.
- Decision: **M6 Option-as-Meta is a global, no-profile setting; default is false.**
  Rationale: this preserves today’s behavior for users and existing copy flows, and
  keeps profile-scope behavior out of scope until a profile architecture exists.
  The UTF-8 selection trim change is explicit: preserve U+3000 in copied text and
  only trim ASCII whitespace at the right edge.
  Date/Author: 2026-06-21, Codex.
- Decision (resolved, 2026-06-21): **Color emoji path: vector, bitmap, or
  hybrid.** Use a hybrid raster path: `EmojiRenderingSettings` defaults to
  `monochrome`, preserving the existing R8 alpha-atlas + tint path; `color`
  detects CoreText color/bitmap glyphs and routes terminal glyphs through a
  separate BGRA8 `ColorGlyphAtlas` and `color_glyph_fragment` in classic Metal,
  while software draws CoreText color glyphs directly. The gpuDriven cell-payload
  accelerator is intentionally disabled in color mode by keeping terminal
  commands in the frame; frames with color glyphs render through the classic
  command pass rather than the R8 cell buffer. `vectorGlyph` must route
  bitmap/color/no-outline glyphs to this M5 path, not duplicate the outline
  pipeline.
  Rationale: this makes the vector plan's "existing color/bitmap path" real,
  leaves monochrome as the compatibility/rollback path, and keeps cell metrics
  owned by the existing frame/payload geometry rather than by emoji rasterization.
  Date/Author: 2026-06-21, Codex.
- Decision (resolved, 2026-06-21): **GB18030/GBK support is deferred.**
  Rationale: M6 found no existing encoding library or daily-workflow evidence
  that legacy CJK encodings should enter this text-trust slice. Modern remote
  workflows remain UTF-8, and silent conversion would risk corrupting bytes.
  Reopen only with a concrete legacy-locale repro and an opt-in conversion design.
  Date/Author: 2026-06-21, Codex.
- Decision (open, to resolve in M7): **Whether zh-Hans / proxy / cloud profiles /
  vibrancy require product-spec amendment.** Finding: **yes** — `docs/product/spec.md`
  authorizes none of them today; each needs a spec amendment before implementation.
  Date/Author: 2026-06-20, plan author.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is considered complete. The executing agent must not mark the plan done until this
gate passes. See `../../PLANS.md` "Review gate and review-fix loop". Prefer
mechanical checks.

- [x] `./scripts/build-app` exits 0 at the review commit; `swift test` exits 0
      (record passed count). Latest automated closeout is the executing agent's
      `./scripts/check` result at implementation commit `84f7061`, including
      `swift test` 1745 tests / 8 skipped / 0 failures; smoke-runtime, test-e2e,
      and coverage-labpty also passed.
- [x] All nine verified audit gaps (G1–G9 in Milestone 0) are each addressed by a
      milestone or explicitly deferred with a reason in the deferred table.
- [x] The P0 trust gate (M1) proves a real Chinese workflow: the fixture
      `fixtures/cjk/trust-gate.fixture.json` exists and includes mixed Chinese/
      English, full-width CJK, ambiguous-width, emoji/ZWJ, a Powerline/Nerd-Font
      symbol, and a box-drawing UI with Chinese inside; the test asserts via
      `/debug/atlas`, `/debug/frame-commands`, and `/debug/screenshot`, not unit-
      only. Grep the fixture for at least one char in each category.
- [x] M3: `grep -n 'text.count' Sources/LabanRenderer/MetalRenderer.swift` around
      the preedit overlay (was `:2732`) shows the display-width fix, and a
      `FrameProducerPreeditTests` case asserts a wide-CJK preedit column equals the
      display-width column; mutating it to `text.count` makes it FAIL.
- [x] M6: the Option-as-Meta plumbing landed — `key_input.c:136` no longer
      hard-codes `GHOSTTY_OPTION_AS_ALT_FALSE` independent of the new setting — and a
      copy test asserts the chosen trailing-U+3000 behavior (`rightTrim`'s ASCII-only
      trim in `TerminalSelection.swift:353-355` preserves trailing ideographic space).
- [x] M5: `EmojiRenderingSettings.current()` defaults to `monochrome`; Settings
      has an `Emoji rendering:` row; `/state`, `/debug/render`, and `/debug/atlas`
      include `emojiRendering.mode` and `effectiveMode`; `ColorEmojiTests` prove
      non-grayscale pixels in Color mode, grayscale/tinted pixels in Monochrome
      mode, and `ColorGlyphAtlas` keeps emoji at two-cell logical width. Grep
      `Sources/LabanRenderer/MetalRenderer.swift` for `colorGlyphPipeline` and
      `Sources/LabanRenderer/Shaders.metal` for `color_glyph_fragment`.
- [x] No duplicated work: this plan does not re-implement DEC mode 2027 width
      (ADR 0021), the bug-audit M2 scrollback/find/copy/word-select/IME-caret fix,
      the kimi-code Kitty-image/tmux-DCS/width-conformance work, the glyph-
      correctness-matrix harness, or the vector-glyph-renderer outline pipeline —
      verify by the cross-reference table in Context.
- [x] Width truth consistency: grep shows no *new* grid-text consumer of
      `TerminalDisplayWidth.cells(of:)`/`isWide(_:)` outside the documented fallback
      sites (preedit, word-classification, scrollback fallback, the M3-fixed overlay).  
      Verified by `Tests/LabanCoreTests/TerminalWidthPolicyGuardTests` and live
      `rg` sweep of `Sources/`.
- [x] CJK rendering acceptance (M2) includes screenshot/capture artifacts for dense
      Chinese, mixed ASCII+Chinese, Chinese in box-drawing UI, Chinese next to
      Nerd-Font symbols, and multiple sizes/Retina, across software/classic/gpuDriven.
      Verified by
      `LABAN_CJK_TRUST_ARTIFACTS=.artifacts/cjk-trust-review swift test --filter GPUCellParityTests/testCJKTrustMatrixArtifactsWhenRequested`,
      which wrote six PNGs plus `manifest.json` for software/classic/gpuDriven at
      `font14-scale1` and `font18-scale2-retina`.
- [ ] IME acceptance includes both Apple Pinyin and Rime/Squirrel (manual transcript
      + screenshots recorded in Artifacts).
      **PARTIAL 2026-06-21:** Apple Pinyin was exercised manually in a clean Laban
      tab with active input source `com.apple.inputmethod.SCIM.ITABC`. The marked
      `zhong wen` preedit remained out of the terminal accessibility value until
      Space committed `中文`; local window captures are recorded at
      `.artifacts/ime-trust-review/apple-pinyin/preedit-zhongwen-window.png` and
      `.artifacts/ime-trust-review/apple-pinyin/final-zhongwen-window.png`, with
      transcript notes at `.artifacts/ime-trust-review/apple-pinyin/transcript.md`.
      **BLOCKED:** Rime/Squirrel is not installed on this host (`/Library/Input Methods`
      is empty; `~/Library/Input Methods` contains only `.localized`), so the required
      Rime/Squirrel transcript/screenshots are still missing.
- [x] HeadlessDebugRuntime parity: any new debug surface is wired into both
      `MainWindowController.makeAndShow` and `HeadlessDebugRuntime` (grep both).
- [x] No regression to MVP behavior (`docs/product/mvp.md`), especially the glyph
      contract (`mvp.md:290-294`).
- [x] No code was implemented by the planning revision (this gate item applies to
      the plan-authoring commit only; implementation milestones flip it as they land).

Review status: BLOCKED

Review findings (filled in by the review agent):

- [FAIL] CJK rendering acceptance artifact set is missing for M2: no dense/mixed/box-drawing/
  Nerd-Font/Retina screenshots are present in-repo (`.artifacts` contains only log/snapshot
  artifacts). **RESOLVED 2026-06-21:** added an opt-in renderer artifact test and
  generated `.artifacts/cjk-trust-review/manifest.json` plus six PNGs covering
  software/classic/gpuDriven at normal and Retina scale.
- [FAIL] IME acceptance artifact set is incomplete: Apple Pinyin now has local
  transcript/window-capture evidence under `.artifacts/ime-trust-review/apple-pinyin/`,
  but Rime/Squirrel is not installed on this host, so no Rime/Squirrel transcript or
  screenshots exist yet.
- [PASS] Automated verification requirements are satisfied for automated items (M1, M3, M5, M6,
  headless parity, and G1–G9 gap accounting).

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
- M2 automated evidence (2026-06-21): local CoreText probe resolved
  `PingFangSC-Regular` for Hanzi (`中`) with a valid glyph and 14 pt natural
  advance; `swift test --filter 'CJKFontMetrics|GPUCellParityTests/testGPUCellPayloadAcceptsRepresentativeCJKWideGlyphs|GPUCellParityTests/testGPUCellPayloadMatchesClassicForRepresentativeCJKWideGlyphs|ChineseTrustGate|LabanDebugExploratoryControlTests/testSessionDetailAndAtlasDiagnosticsAreQueryable'`
  passed 7 tests; `swift test --filter 'GPUCellParity|CJKFontMetrics'` passed 48
  tests; `git diff --check` passed; `./scripts/build-app` exited 0. Follow-up
  artifact evidence: `LABAN_CJK_TRUST_ARTIFACTS=.artifacts/cjk-trust-review swift test --filter GPUCellParityTests/testCJKTrustMatrixArtifactsWhenRequested`
  passed 1 test and wrote six local PNG artifacts plus `manifest.json`, covering
  dense Chinese, mixed ASCII+Chinese, Chinese in box-drawing UI, Chinese next to
  Nerd Font symbols, and multiple font-size/Retina scale across software/classic/
  gpuDriven renderers.
- M3 automated evidence (2026-06-21): `swift test --filter FrameProducerPreedit`
  passed 8 tests, including wide CJK preedit at a nonzero cursor column and ZWJ
  mask-width regressions; `./scripts/build-app` exited 0 in the worker. A local
  preedit-overlay scan over `MetalRenderer.swift` lines 2700-2800 found no old
  `text.count` / `enumerated()` column-stepping pattern. Deviation: no manual
  `gpuDriven` Apple Pinyin/Rime screenshot artifact was captured in this slice.
- M4 automated evidence (2026-06-21): `swift test --filter 'TerminalWidthConformance|Mode2027|TerminalWidthPolicyGuard'`
  passed 28 tests, including `Tests/LabanCoreTests/TerminalWidthPolicyGuardTests`,
  confirming `TerminalDisplayWidth` usage is confined to fallback sites.
- M5 automated evidence (2026-06-21): `swift test --filter 'ColorEmoji|EmojiRendering'`
  passed 10 tests, including `ColorEmojiTests.testEmojiRendersWithColorPixelsInColorMode`,
  `ColorEmojiTests.testMonochromeModePreservesTintedMaskPath`,
  `ColorEmojiTests.testColorGlyphAtlasKeepsEmojiInsideTwoCells`, and
  `EmojiRenderingHeadlessTests` for `/state` + `/debug/render` reporting. The
  broader focused gate
  `swift test --filter 'ColorEmoji|EmojiRendering|GPUCellParity|RendererModeSettings|GraphemeWidthSettingsUI'`
  passed 64 tests, including 45 `GPUCellParityTests`; `git diff --check` passed;
  `./scripts/build-app` exited 0 with module-cache/codesign replacement warnings
  only. Deviation: no durable screenshot artifacts were captured in this slice;
  the color proof is automated pixel/atlas/debug-state coverage. The gpuDriven
  color route deliberately fail-closes to the classic command path instead of
  adding a separate retained BGRA cell buffer.
- Review-gate automated closeout (2026-06-21): `./scripts/check` passed at
  implementation commit `84f7061`, including full `swift test` 1745 tests / 8
  skipped / 0 failures, smoke-runtime (`foundExpectedText: true`), `test-e2e`,
  and `coverage-labpty` with daemon MC/DC 46.86% holding the 45% floor. Remaining
  Review Gate blocker is only the manual Rime/Squirrel IME transcript/screenshots.
- Manual IME evidence (Apple Pinyin, partial, 2026-06-21): active input source
  `com.apple.inputmethod.SCIM.ITABC`; running bundle
  `/Users/rrj/Laban.app` stamped `bd3df0d+dirty`; clean tab 12 showed
  `zhong wen` as marked preedit while the accessibility value stayed `~$`, then
  Space committed `中文` and the accessibility value became `~$ 中文`. Local
  artifacts: `.artifacts/ime-trust-review/apple-pinyin/transcript.md`,
  `.artifacts/ime-trust-review/apple-pinyin/preedit-zhongwen-window.png`, and
  `.artifacts/ime-trust-review/apple-pinyin/final-zhongwen-window.png`.
  `screencapture -x` failed with `could not create image from display`, so the
  PNGs were captured with `CGWindowListCreateImage` and Swift availability checks
  disabled. An interrupted run and an Apple Pinyin segmented-candidate run were
  discarded; the recorded evidence is the clean tab 12 pass. A candidate-panel
  expansion attempt with Down-arrow was also discarded because it left raw
  `zhongwen` in the terminal value.
- Manual IME transcript still required: install/enable Rime/Squirrel, compose
  `中文`, screenshot the candidate window at the cursor and the committed cells,
  in `classic` and `gpuDriven` renderers.

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
