# Make dictation pre-edit opaque and wrapping

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

When macOS dictation or another input method supplies marked text, Laban draws
that pending text over the terminal at the application cursor. The pending text
must hide application-owned placeholder text beneath it and must wrap through
the remaining terminal rows instead of continuing off the right edge. The
result is observable with Codex: dictation replaces the input hint visually,
wraps at the terminal width, and keeps the caret at the actual insertion point.

## Progress

- [x] Reproduced the two faulty producer contracts in source: the mask accepts a
  transparent default background, and pre-edit is emitted as one unbounded run.
- [x] Add focused regressions for opaque masking, row wrapping, and wrapped caret
  placement; observed six expected failures before the implementation.
- [x] Implement shared pre-edit grid layout for local, overlay, and remote frame
  production paths.
- [x] Verify focused producer, debug-frame, GPU-cell, classic screenshot, and
  vector screenshot paths.
- [x] Run the repository gate; all pre-edit and renderer checks passed. Two
  unrelated suite-order failures passed immediately when rerun in isolation.
- [x] Fix all four accepted structured-review findings and verify them with
  focused tests and overlap screenshots. A clean final review rerun was
  attempted three times but the Codex review lane hit its usage limit (one
  retry also hit a transient docs-MCP transport failure).

## Context and Orientation

`Sources/LabanApp/TerminalBitmapView.swift` receives AppKit marked text and
passes the composition plus its caret width into `FrameProducer`.
`Sources/LabanCore/FrameProducer.swift` emits renderer-neutral `.preedit` mask
rectangles and glyph runs. All renderers consume those commands; the
GPU-driven Metal path also replays pre-edit after terminal cell payloads so the
mask remains above application content. Focused producer coverage lives in
`Tests/LabanCoreTests/FrameProducerPreeditTests.swift`, and the headless debug
contract is exercised in `Tests/LabanDebugTests/LabanDebugSmokeTests.swift`.

## Decision Log

- Decision: Wrap pre-edit in `FrameProducer`, not separately in renderers.
  Rationale: every backend and both visible/headless paths must consume the same
  row geometry.
- Decision: Resolve the pre-edit mask to an opaque color over Laban's terminal
  canvas.
  Rationale: preserving a transparent alpha defeats the mask and exposes TUI
  placeholders such as Codex's input hint.
- Decision: Emit pre-edit masks and glyphs before Laban's cursor, and replay
  pre-edit rectangles after GPU cell payload backgrounds.
  Rationale: the mask must cover application content without covering the IME
  insertion caret; mask-only wide-wrap spacer cells must also survive the GPU
  payload pass.

## Surprises & Discoveries

- The first structured review found that making the mask reliably opaque also
  made command ordering observable: the old cursor-before-pre-edit order hid a
  caret positioned inside marked text. It also identified the unmasked spacer
  cell left when a wide grapheme wraps from the final column. Both now have
  focused regressions.
- The second structured review caught that several GPU renderers batch solids
  before glyphs regardless of command order. The renderer builders now omit
  application glyphs covered by pre-edit masks, while the GPU-cell payload path
  also clears retained glyph entries covered by mask-only spacers. Overlap
  screenshots for Vector and Slug show `Dictation` replacing the same cells of
  `Explain this codebase` rather than blending with them.
- `scripts/vector-glyph-parity-matrix` still treats `debugServer` as an HTTP URL,
  while the current agent reports a Unix control socket. Renderer verification
  used the supported `curl --unix-socket` path and left that unrelated script
  unchanged.

## Plan of Work

First pin command-level behavior with tests that set a transparent snapshot
background and place a composition near the right edge. Then replace the
single-run pre-edit emission with a small grid layout that splits only at
grapheme boundaries, accounts for display-cell width, and returns the wrapped
caret row and column. Use that layout in all three producer entry points.
Finally extend the debug smoke assertion to prove multiple pre-edit rows are
externally visible and run the visual parity fixture against the renderer paths.

## Concrete Steps

From `/Users/rrj/wrk/laban.worktrees/pre-edit`:

1. Run `rtk swift test --filter FrameProducerPreeditTests` before and after the
   fix; the new tests must fail before and pass after.
2. Run `rtk swift test --filter LabanDebugSmokeTests/testSetPreeditActionProducesPreeditFrameCommands`.
3. Launch `laban-agent` with classic and vector renderers and use the readiness
   socket with `curl --unix-socket` to set long pre-edit text, inspect frame
   commands, and capture screenshots.
4. Run `rtk ./scripts/check` and `rtk git diff --check`.

## Validation and Acceptance

The focused tests must prove that every pre-edit mask has alpha `0xFF`, a
composition wider than the columns remaining on its first row produces
multiple mask/run pairs within the grid, and the caret advances to the wrapped
row. The debug endpoint must expose those multiple rows. In the installed or
development app, dictating into Codex must cover its hint rather than blending
with it and must continue on the following terminal row.

## Idempotence and Recovery

All test and parity commands are safe to rerun. Preserve the unrelated existing
`.rpg/graph.json` modification and do not stage or rewrite it.

## Outcomes & Retrospective

Pre-edit masks now resolve to the terminal canvas as fully opaque, compositions
wrap by grapheme/display-cell width, wrapped carets follow the AppKit insertion
point, and wide-wrap spacer cells are masked. Classic Metal, GPU-cell, Vector,
and Slug suppress application glyphs beneath those masks; GPU-cell additionally
clears retained glyph cache entries before writing pre-edit glyphs. Focused
producer/debug/GPU tests, full GPU parity, Slug correctness/damage suites,
format/lint, and visual overlap captures pass. The broad repository gate reached
all relevant checks successfully; its unrelated labpty timing and Slug hash
failures both passed immediately in isolation. A standalone Vector fidelity
threshold test remains red in isolation without any pre-edit commands and is
therefore unrelated to this change.
