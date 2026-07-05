# Chinese / CJK Support Inventory

This file tracks confirmed gaps, latent bugs, and improvement opportunities for
Chinese and CJK users. It covers rendering, input, copy/paste, locale/encoding,
and product-scope items. Each entry includes the evidence and a concrete fix
suggestion.

For the active implementation plan, see
`execplans/active/chinese-text-and-terminal-trust-gate.md`. For the foundational
decisions, see `docs/adr/0021-dec-mode-2027-grapheme-cluster-width.md` and
`docs/adr/0025-cjk-font-pairing-and-metrics.md`.

## Status summary

The core CJK trust work is complete and green in CI: engine-owned width, explicit
CJK font pairing, IME composition, color-emoji rendering, Option-as-Meta, and
U+3000 copy preservation are all implemented. The remaining items are mostly
edge cases, observability, and product scope.

| Priority | Count | Theme |
| --- | --- | --- |
| P1 — should fix now | 2 | child-shell locale; gpuDriven preedit width consistency |
| P2 — fix soon | 3 | decoration width math; CJK font observability; Rime/Squirrel verification |
| P3 — product/spec gated | 3 | bundled CJK font / picker; ambiguous-width setting; zh-Hans UI |
| P4 — deferred/tracked | 2 | legacy GB18030/GBK; selection-scroll bug |

---

## P1 — should fix now

### 1. Child shells are not guaranteed a UTF-8 locale

**Why it matters:** `build_spawn_env` inherits `LANG`/`LC_CTYPE` from the launch
environment. If Laban is started from a sanitized launcher, over SSH without
locale forwarding, or from a parent that does not set a UTF-8 locale, child
shells can default to `C`/`POSIX`. Common CJK tools (`ls`, `grep`, `git`, `less`)
then either mangle multibyte input or fall back to escape sequences, breaking
the trust of Chinese users even though the terminal renderer is correct.

**Evidence:** `Sources/LabanTerminalCore/session_lifecycle.c:65-73` injects
`TERM`, `COLORTERM`, and `TERM_PROGRAM` but never sets `LANG` or `LC_CTYPE`.

**Suggested fix:** In `build_spawn_env`, if the inherited env does not already
provide a UTF-8 `LANG`/`LC_CTYPE`, set `LANG=en_US.UTF-8` (or the first
UTF-8 locale available on the system). Add a regression test that spawns a
session with an empty inherited env and asserts `locale` reports UTF-8.

---

### 2. gpuDriven preedit width is recomputed from the mask rect

**Why it matters:** The `gpuDriven` overlay derives `preeditCellCount` from the
width of the preedit mask rectangle rather than from the producer’s computed
display-cell count. For ZWJ emoji preedit (e.g. `👩‍💻`), the legacy scalar
fallback used for non-grid text reports 4 columns while the engine/mode-2027
would report 2. The mask can therefore be wider than the glyph cells, causing
visual mismatch during inline composition.

**Evidence:** `Sources/LabanCore/FrameProducer.swift:581` sizes the preedit mask
with `TerminalDisplayWidth.cells(of:)`; `Sources/LabanRenderer/MetalRenderer.swift:3002-3107`
recomputes the overlay cell count from that rect.

**Suggested fix:** Thread the producer’s computed display-cell count into the
preedit frame command or overlay state, and use it directly for glyph
placement. Eliminate the second derivation. Add a ZWJ-emoji preedit regression
test to `Tests/LabanCoreTests/FrameProducerPreeditTests.swift`.

---

## P2 — fix soon

### 3. Decoration layout still uses `text.count` in places

**Why it matters:** Underlines and strikethroughs are drawn with
`TextDecorationLayout.make(cellCount: text.count, ...)`. For multi-cell preedit
clusters this under-counts cells, so underlines may not span the full width of
wide CJK or ZWJ preedit text.

**Evidence:** `Sources/LabanRenderer/SoftwareRenderer.swift:412-421` and
`Sources/LabanRenderer/SlugGlyphRenderer.swift:1193-1202`.

**Suggested fix:** Replace `text.count` with the display-width cell count
(`TerminalDisplayWidth.cells(of:)` for non-grid text, or the command’s carried
cell count for grid text). Add a focused regression test for wide preedit
underline span.

---

### 4. CJK font fallback is not observable to users

**Why it matters:** If PingFang SC is missing, disabled, or the user installs a
preferred CJK font, the cascade silently changes. Today the only way to see
which CJK font was selected is `GET /debug/atlas`, which is not user-facing.

**Evidence:** `Sources/LabanRenderer/TerminalCJKFontPolicy.swift:25-76` defines
the cascade; `Sources/LabanDebug/DebugRenderEndpoints.swift` exposes it only
through the debug HTTP endpoint.

**Suggested fix:** Surface the selected CJK font name and `glyphAvailable` state
in the Settings window or in a startup log line. This makes fallback degradation
easy to diagnose without requiring a debug client.

---

### 5. Rime/Squirrel IME has not been manually verified

**Why it matters:** The trust-gate ExecPlan requires both Apple Pinyin and
Rime/Squirrel manual acceptance. Apple Pinyin was verified with screenshots and
a transcript; Rime/Squirrel was not installed on the host, so the Review Gate is
still blocked for that IME.

**Evidence:** `execplans/active/chinese-text-and-terminal-trust-gate.md:806-820`
records the partial status.

**Suggested fix:** Install/enable Rime/Squirrel, compose `中文`, capture the
candidate window at the cursor and the committed cells, and add the screenshots
plus transcript to `.artifacts/ime-trust-review/rime-squirrel/`. Update the
ExecPlan’s Review Gate checklist.

---

## P3 — product/spec gated

### 6. No bundled CJK font or user-selectable CJK font

**Why it matters:** The current policy relies on system PingFang SC. Users who
prefer a monospaced Hanzi look (e.g. Noto Sans Mono CJK SC or Sarasa Term SC)
have no way to choose it. If PingFang SC is unavailable, the app falls through
to CoreText’s cascade non-deterministically.

**Evidence:** `docs/adr/0025-cjk-font-pairing-and-metrics.md:46-47` and
`Sources/LabanRenderer/TerminalCJKFontPolicy.swift:25-76`.

**Suggested fix:** Add a Settings row for CJK font selection (default
PingFang SC, with installed Noto/Sarasa as explicit candidates). If evidence
shows system fonts are insufficient, evaluate bundling Noto Sans Mono CJK SC or
Sarasa Term SC and update `Package.swift`/licenses. Requires a `spec.md`
amendment.

---

### 7. No ambiguous-width character override

**Why it matters:** East-Asian users often expect ambiguous-width characters
(e.g. `±`, `§`, arrows, some box-drawing) to render 2 cells wide. Laban has no
user-facing control; grid width is owned by libghostty, and the Swift fallback
table is hardcoded.

**Evidence:** `Sources/LabanCore/TerminalDisplayWidth.swift:30-82`;
`execplans/active/chinese-text-and-terminal-trust-gate.md:423-450` explicitly
rejected a Swift-only setting to avoid a second width truth.

**Suggested fix:** Do not add a Swift-only ambiguous-width toggle. Coordinate
with libghostty to expose an ambiguous-width C API knob (or environment
variable), then surface it in Settings. Until then, document the current
behavior in the ADR Decision Log.

---

### 8. No zh-Hans UI localization

**Why it matters:** A Chinese UI is not required for Chinese text to be correct,
but it materially affects product feel for non-English-speaking users. There is
no i18n infrastructure at all today.

**Evidence:** No `.lproj`, `.xcstrings`, or `NSLocalizedString` in the repo;
menus are hardcoded English in `Sources/LabanApp/MenuCommands.swift`.

**Suggested fix:** Amend `docs/product/spec.md` to authorize localization, then
build i18n infrastructure from scratch (`.xcstrings`, extraction tooling,
localized menu strings). Sequence after all P1/P2 text-correctness items.

---

## P4 — deferred/tracked

### 9. No legacy CJK encoding support (GB18030/GBK/Big5/Shift_JIS)

**Why it matters:** Copying/pasting through legacy-locale remote systems could
mangle bytes. Modern UTF-8 workflows are unaffected.

**Evidence:** Zero hits for GB18030/GBK/Big5/Shift_JIS/iconv/CFStringEncoding in
the repo; `execplans/active/chinese-text-and-terminal-trust-gate.md:542-573`
time-boxed and deferred this.

**Suggested fix:** Keep deferred. Reopen only with a concrete legacy-locale
repro and an opt-in conversion design that never silently mangles UTF-8 bytes.

---

### 10. Selection stays pinned when a mouse-tracking app scrolls

**Why it matters:** This is a general selection bug, not CJK-specific, but it
affects selection UX in agent/TUI workflows that display CJK text. It is already
documented separately.

**Evidence:** `bughunt/SELECTION_SCROLL_BUG.md`.

**Suggested fix:** Invalidate the local selection when a wheel event is
forwarded to a mouse-tracking fullscreen app or when alternate-screen content
under the selection changes. Track in the existing bug file, not this
inventory.

---

## Related files

- `execplans/active/chinese-text-and-terminal-trust-gate.md` — active plan
- `docs/adr/0021-dec-mode-2027-grapheme-cluster-width.md` — width authority
- `docs/adr/0025-cjk-font-pairing-and-metrics.md` — CJK font policy
- `Sources/LabanRenderer/TerminalCJKFontPolicy.swift` — CJK cascade
- `Sources/LabanCore/TerminalDisplayWidth.swift` — non-grid fallback width
- `Sources/LabanTerminalCore/session_lifecycle.c` — child spawn environment
- `Sources/LabanRenderer/MetalRenderer.swift` — gpuDriven overlay
- `Tests/LabanCoreTests/FrameProducerPreeditTests.swift` — preedit width tests
- `Tests/LabanCoreTests/TerminalWidthConformanceTests.swift` — width conformance
