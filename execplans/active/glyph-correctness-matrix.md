# Harden Terminal Glyph Correctness Across Renderers

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then make Laban render terminal UI glyphs predictably across software,
classic Metal, and GPU-driven cell paths.

## Purpose / Big Picture

Terminal programs and agent TUIs use symbols such as `⎿`, `↳`, arrows, box
drawing, block drawing, braille, Powerline separators, emoji, CJK, and combining
marks as part of their UI. Laban recently fixed a class of glyph-width failures
where Core Text fallback fonts produced ink that did not match terminal cell
geometry. This plan turns that fix into a broader glyph correctness matrix so
future renderer changes do not reintroduce blank cells, over-wide fallback
glyphs, or software/GPU disagreements.

After this work, a developer can run tests that render a representative glyph
corpus through all renderer paths, produce pixel artifacts for differences, and
assert that glyph ink stays inside the terminal cells promised by the terminal
core.

## Progress

- [x] Created this ExecPlan from the recent `⎿` / `↳` diagnosis and GPU renderer
      parity work.
- [ ] Define a checked-in glyph corpus that covers terminal UI, Unicode width,
      font fallback, and shaping edge cases.
- [ ] Add test helpers that report fallback font choice, expected terminal cell
      width, measured ink bounds, and pixel diffs.
- [ ] Extend software/classic/GPU-driven tests so the same glyph corpus is
      exercised through every renderer path.
- [ ] Fix any mismatches by sharing renderer-neutral font fallback and glyph
      geometry policy.
- [ ] Add optional iTerm comparison artifacts for diagnosis, without making
      iTerm behavior the CI oracle.

## Decision Log

- Decision: Laban's oracle is its own terminal cell contract and
  software-vs-Metal parity, not visual imitation of iTerm.
  Rationale: iTerm is useful as a product comparison, but Laban must first be
  internally consistent and faithful to the cell widths produced by its terminal
  core. Different apps may choose different fallback fonts.
  Date/Author: 2026-06-02 / Codex.

- Decision: Single-cell terminal UI symbols should prefer monospaced fallback
  over arbitrary Core Text fallback when the primary terminal font lacks the
  glyph.
  Rationale: Recent diagnosis showed `↳` could fall back to a proportional font
  under one font stack, painting as a two-cell-looking glyph in a one-cell
  terminal slot. Terminal UI symbols are layout elements; they need terminal
  geometry before typographic preference.
  Date/Author: 2026-06-02 / Codex.

## Context and Orientation

The current renderer stack has three relevant drawing surfaces:

- `Sources/LabanRenderer/SoftwareRenderer.swift` draws `[FrameCommand]` values
  into a `BitmapSurface` using Core Graphics and Core Text. It is the
  software/offscreen reference path for debug and replay.
- `Sources/LabanRenderer/MetalRenderer.swift` draws the visible AppKit surface.
  In `classic` mode it consumes `[FrameCommand]` glyph and rectangle instances.
  In `gpuDriven` mode on macOS 26 it can consume `TerminalCellPayload` and patch
  persistent GPU cell buffers for local interactive sessions.
- `Sources/LabanRenderer/MetalGlyphAtlas.swift` rasterizes glyphs into a Metal
  texture atlas. The Metal shaders sample this atlas and tint the alpha mask.

`Sources/LabanRenderer/TerminalGlyphFallback.swift` contains the current shared
policy for terminal-oriented fallback glyphs. It should remain the central
place for choosing monospaced fallback for terminal UI symbols. The software and
Metal renderers should not drift into separate fallback decisions for the same
cell.

`Sources/LabanCore/FrameProducer.swift` and `TerminalCellPayload` carry the
terminal core's view of cell geometry: a glyph may occupy one terminal cell,
two terminal cells, or a shaped cluster. The renderer must not infer a different
terminal width from the fallback font's natural advance. If a font's ink is
wide, the renderer may allow bounded overhang when the terminal already reserved
enough columns, but it must not let a one-cell symbol erase or visually occupy
the next unrelated cell.

Definitions used in this plan:

- Cell width means the number of terminal columns assigned by the terminal core,
  not the width Core Text would naturally advance for a fallback font.
- Ink bounds are the actual non-background pixels drawn by a glyph.
- Fallback font is the font Core Text or Laban chooses when the primary terminal
  font lacks a glyph.
- Ambiguous-width glyphs are Unicode characters that some terminals treat as
  one column and some East Asian contexts treat as two. Laban's renderer must
  follow the terminal core's chosen width for the current session.
- A cluster is one user-perceived character made from one or more Unicode
  scalars, such as a base letter plus combining mark or an emoji ZWJ sequence.

## Plan of Work

### M0 - Glyph Corpus And Expected Cell Contract

Add a checked-in glyph corpus for renderer tests. It can be a Swift fixture in
`Tests/LabanRendererTests` or a data file under `fixtures/renderer/`. The corpus
must include at least:

- terminal prompt/UI symbols: `⎿`, `↳`, `→`, `←`, `↑`, `↓`, `▶`, `▸`, `▾`, `●`,
  `○`;
- box drawing: `─`, `│`, `┌`, `┐`, `└`, `┘`, `┼`, `═`, `║`;
- block and shade glyphs: `█`, `▁`, `▂`, `▃`, `▄`, `▅`, `▆`, `▇`, `░`, `▒`,
  `▓`;
- braille spinner glyphs: `⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`, `⠦`, `⠧`, `⠇`,
  `⠏`;
- Powerline and Nerd Font private-use examples when a bundled font supplies
  them, with graceful skip or fallback when not available;
- ambiguous-width symbols such as `·`, `±`, `§`, `Ω`, `λ`, `✓`, `✗`;
- CJK and Hangul examples such as `界`, `語`, `니`;
- emoji and emoji clusters such as `🙂`, `🧑‍💻`, and a variation-selector case;
- combining sequences such as `é` and `ä`;
- invalid or unsupported payload cases only as defensive tests, never as normal
  rendering expectations.

For each corpus entry, record the expected terminal cell count as observed from
the current terminal core or existing frame/payload fixtures. Do not hard-code a
width from a web table if Laban's terminal core disagrees; the renderer follows
the terminal core.

Acceptance for M0:

```sh
rtk swift test --filter 'GPUCellParityTests/testGPUCellPayloadAcceptsRepresentativeNarrowGlyphEdgeScalars|GPUCellParityTests/testGPUCellPayloadAcceptsStyledNarrowGlyphEdgeScalars'
```

The existing narrow-glyph edge tests still pass, and the new corpus can be
loaded by tests without rendering anything yet.

### M1 - Metrics And Pixel Artifact Helpers

Add test helpers that can render a corpus entry into a small deterministic grid
and report:

- selected primary font;
- fallback font name, when the fallback path is used and the information is
  available;
- expected terminal cell count;
- measured ink bounds in pixels;
- whether ink spills into a neighboring sentinel cell;
- raw-RGBA diff artifacts when software, classic Metal, and GPU-driven disagree.

Prefer helpers under `Tests/LabanRendererTests` that reuse existing
`GPUCellParityTests` and smoke-test infrastructure. If production code needs to
expose fallback metadata, keep it internal or test-only and avoid shipping
always-on debug logging.

Acceptance for M1:

```sh
rtk swift test --filter 'LabanRendererSmokeTests|MetalRendererSmokeTests'
```

At least one test must deliberately render a glyph with a known monospaced
fallback and assert that a sentinel cell next to it remains visibly separate.

### M2 - Cross-Renderer Glyph Matrix

Extend `GPUCellParityTests` and renderer smoke tests so every corpus category is
covered by at least one automated assertion:

- software renderer nonblank output for fallback glyphs;
- classic Metal nonblank output for fallback glyphs;
- GPU-driven payload builder accepts supported one-cell and two-cell glyphs;
- GPU-driven path falls back gracefully, with a visible classic retry, when a
  shaped cluster or unsupported attribute cannot be safely represented in the
  cell payload;
- software and Metal agree on cell occupancy and sentinel-cell preservation;
- raw-RGBA parity remains zero-tolerance for the GPU cell cases that claim
  support.

Do not compare screenshots only by "nonblank" when exact parity is feasible.
Use nonblank checks for font-dependent external comparisons and raw-RGBA checks
for internal renderer paths.

Acceptance for M2:

```sh
rtk swift test --filter 'GPUCellParityTests|LabanRendererSmokeTests|MetalRendererSmokeTests'
```

The suite includes corpus-driven tests, writes useful artifacts on pixel
mismatch, and fails on blank or over-wide rendering for supported glyphs.

### M3 - Product Fixes For Any Mismatches

If M2 exposes mismatches, fix the renderer policy in the smallest shared place.
Likely fixes include:

- extend `TerminalGlyphFallback.swift` ranges when a terminal UI symbol falls
  through to proportional fallback;
- make `MetalGlyphAtlas` and `SoftwareRenderer` use the same fallback line
  policy for the same cluster;
- clamp or position glyph ink so one-cell fallback symbols cannot erase the
  next cell while preserving intentional wide glyphs;
- add a graceful fail-closed path when the GPU cell payload cannot represent a
  cluster safely, so the classic command path renders visible text instead of a
  blank GPU frame;
- update payload build failure diagnostics only behind an explicit debug flag
  or failure-triggered artifact, not always-on logging.

Acceptance for M3:

```sh
rtk swift test --filter 'GPUCellParityTests|LabanRendererSmokeTests|MetalRendererSmokeTests|FrameProducerTests'
rtk git diff --check
```

Every retained product fix has a reproducing test that fails without the fix and
passes with it.

### M4 - Optional External Comparison Artifacts

Add an optional, manually run script or documented recipe that renders the glyph
corpus in Laban and iTerm using the same font family and size where practical.
This is diagnostic only. It should help answer product questions such as "why
does iTerm look different?" without making iTerm the automated oracle.

Acceptance for M4:

The recipe writes labeled screenshots and a short JSON or Markdown summary under
`LABAN_ARTIFACTS`, including the Laban git SHA, iTerm profile font, Laban font,
backing scale, and corpus entries that visually differ.

## Validation and Acceptance

This plan is complete when supported glyphs in the corpus render visibly and
with stable cell occupancy across software, classic Metal, and GPU-driven paths.
The important observable outcome is that terminal UI text does not become blank,
does not unexpectedly consume neighboring cells, and does not differ between
renderer modes for cases Laban claims to support.

Minimum validation from the repository root:

```sh
rtk swift test --filter 'GPUCellParityTests|LabanRendererSmokeTests|MetalRendererSmokeTests|FrameProducerTests'
rtk git diff --check
```

Expected outcome: tests pass; new corpus-driven tests are present; pixel
artifacts are produced on mismatch; every product fix has a targeted
reproducer.

## Idempotence and Recovery

The corpus and tests are additive and safe to rerun. If a glyph's behavior is
font-dependent, record the font and skip only when the required font is truly
unavailable. Do not weaken a failing exact-parity assertion into a nonblank
assertion unless the rendering is intentionally font-dependent and the plan
records why exact parity is not the right oracle.

Do not refresh or commit `.rpg/graph.json` as part of this plan unless a human
explicitly asks for semantic-graph maintenance.

## Artifacts and Notes

When mismatches are found, record the artifact directory, glyph, font, renderer
mode, and first differing pixel or ink-bound measurement here. Keep screenshots
out of git unless the repository already uses that fixture style for renderer
tests.

## Review Gate

A separate fresh-state review agent must verify these checks before this
ExecPlan is considered complete:

- [ ] Run `rtk swift test --filter 'GPUCellParityTests|LabanRendererSmokeTests|MetalRendererSmokeTests|FrameProducerTests'`;
      expect exit 0.
- [ ] Grep tests for corpus entries `⎿` and `↳`; expect both to be covered by a
      renderer test that checks cell occupancy or sentinel-cell preservation.
- [ ] Grep tests for at least one box-drawing glyph, one block glyph, one
      braille glyph, one ambiguous-width glyph, one CJK glyph, one emoji or ZWJ
      cluster, and one combining sequence.
- [ ] Grep production code for `TerminalGlyphFallback`; expect both software
      and Metal glyph drawing paths to use the shared helper or a documented
      wrapper around it.
- [ ] If a glyph mismatch fix changed production code, identify the test that
      fails without the fix and passes with it; record the test name in this
      plan before checking this item.
- [ ] Confirm no always-on glyph debug logging is added; any logging or journal
      dump must be behind an explicit flag or triggered only by a failure path.

Review status: NOT REVIEWED.

