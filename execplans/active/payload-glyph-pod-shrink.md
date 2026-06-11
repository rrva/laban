# Shrink TerminalCellPayload.Glyph To A POD Struct

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. It serves the "Evaluate optimization candidates one at a time"
step of `execplans/active/gpu-renderer-default-readiness-perf.md`.

## Purpose / Big Picture

Every frame, Laban's terminal renderer ships cell content from the terminal
state to the GPU through `TerminalCellPayload` (defined in
`Sources/LabanRenderer/TerminalCellPayload.swift`). Its per-cell element,
`TerminalCellPayload.Glyph`, is today a ~104-byte struct containing a `String`
and three `Optional` fields. Because of the `String`, every copy, array append,
and array destroy of a `Glyph` pays automatic reference counting (ARC), and a
full 160×48 grid moves ~7,680 of them per frame. Instruments traces
(2026-06-11, heavy scroll) showed `initializeWithCopy for
TerminalCellPayload.Glyph`, `swift_arrayDestroy`, and `memcpy` frames totalling
several percent of process CPU even after the producer and consumer loops were
optimized.

After this change `Glyph` is a fixed-size, pointer-free ("POD": plain old
data — no references, trivially copyable) struct of ~48 bytes. Arrays of it
copy with `memcpy`, destroy for free, and never touch ARC. Glyph text that is
not a single Unicode scalar lives only in the payload's existing `utf8Bytes`
side buffer, addressed by offset+length. Observable result: the
`TerminalCellPayload` fill microbench and the GPU-cell payload builder
microbench hold or improve in every case, all parity suites stay green, and
the ARC/destroy frames disappear from fresh traces.

## Progress

- [x] (2026-06-11) Surveyed all `Glyph` producers/consumers (listed in Context).
- [x] (2026-06-11) Decision: POD array-of-structs, not struct-of-arrays (see Decision Log).
- [x] (2026-06-11) Rewrite `Glyph` storage + compatibility accessors (`@inlinable`, see Surprises).
- [x] (2026-06-11) Add `TerminalCellPayload.appendGlyph(cluster:)` fixture helper.
- [x] (2026-06-11) Migrate `FrameProducer.fillTerminalCellPayload` (drop `text:`, spacer merge via accessors).
- [x] (2026-06-11) Migrate `MetalRenderer` payload builder (drop `text` branch, fix failure preview).
- [x] (2026-06-11) Migrate test fixtures (bench + parity) to scalar/utf8Range storage.
- [x] (2026-06-11) Add POD/stride layout assertion test (`Tests/LabanCoreTests/PayloadGlyphLayoutTests.swift`).
- [x] (2026-06-11) Follow-up forced by profile: hoist `FrameProducer` raw attribute masks from `static let` to instance properties and make the gpuCell-renderable check raw (see Surprises).
- [x] (2026-06-11) Run full verification matrix and record before/after bench numbers (Artifacts).
- [ ] Commit; then pass Review Gate via a fresh agent.

## Decision Log

- Decision: Shrink to a POD array-of-structs (AoS); do not convert
  `payload.glyphs` to a struct-of-arrays (SoA).
  Rationale: The renderer's hot loop
  (`MetalRenderer.buildGPUCellPayloadInstanceListsOnce`) reads 7–9 of the 12
  fields per glyph and the producer writes all of them, so SoA's benefit
  (skipping unread columns) is marginal here, while its cost is large: N
  parallel arrays to size/track (the zero-growth capacity tests in
  `Tests/LabanCoreTests/TerminalCellPayloadAllocationBench.swift` multiply),
  the spacer-tail merge in `FrameProducer.fillTerminalCellPayload` mutates the
  previously appended glyph across all arrays, and every fixture site becomes
  index arithmetic. The measured costs (ARC retain/release, arrayDestroy,
  oversized memcpy) are all eliminated by POD alone. Revisit SoA only if a
  future trace shows a pass that reads a small field subset dominating.
  Date/Author: 2026-06-11 / Claude.
- Decision: Sentinels instead of Optionals: `scalarValue` stored as `UInt32`
  with `0xFFFF_FFFF` = none (valid Unicode scalars end at `0x10FFFF`);
  `underlineColor` stored as `UInt32` with `0` = none (matches
  `FrameProducer.resolvedVisuals`, which already maps
  `cell.underline_color_rgba == 0` to nil); utf8 text stored as
  `utf8Start`/`utf8Length: Int32` with length `0` = none (the producer and all
  fixtures only ever store non-empty ranges). Public computed properties keep
  the Optional-typed API so consumers stay source-compatible.
  Date/Author: 2026-06-11 / Claude.
- Decision: Remove the stored `text: String` field and the `text:` init
  parameter entirely (no deprecated shim). A POD struct cannot carry a String;
  a silently-dropped parameter would corrupt fixtures that rely on it. The
  resulting compile errors are the migration checklist.
  Date/Author: 2026-06-11 / Claude.
- Decision: `row`/`col` stay `Int` (8 bytes each). Squeezing to `Int32` saves
  8 bytes of stride (48→40) but forces conversions at every consumer; both
  strides fit a cache line.
  Date/Author: 2026-06-11 / Claude.

## Context and Orientation

Build/test from the repository root. `swift test -c release --filter <X>`
runs test suites; benches are gated by `LABAN_RUN_PERF_BENCH=1` and require
`-c release`.

Key files:

- `Sources/LabanRenderer/TerminalCellPayload.swift` — the payload struct.
  `Glyph` (line ~33) currently stores `row/col: Int`, `text: String`,
  `scalarValue: UInt32?`, `foreground/background: UInt32`,
  `attributes: TextAttributes` (an `OptionSet` over `UInt16`, defined in
  `Sources/LabanRenderer/FrameCommand.swift`), `underlineStyle: UnderlineStyle`
  (`UInt8` enum, same file), `underlineColor: UInt32?`, `hasHyperlink: Bool`,
  `wide: UInt8`, `utf8Range: Range<Int>?`. `payload.utf8Bytes: [UInt8]` is the
  side buffer that `utf8Range` indexes into.
- `Sources/LabanCore/FrameProducer.swift` — the producer.
  `fillTerminalCellPayload` (line ~602) constructs glyphs with `text: ""`
  always; real text goes through `scalarValue` (single Unicode scalar) or
  `utf8Bytes`+`utf8Range` (multi-scalar cluster). Its row-local helpers
  `glyphBytes` (reads `glyph.text` as a last resort) and
  `appendGlyphOrMergeAfterSpacer` (writes `payload.glyphs[i].text = ""` when
  merging a wide-glyph spacer) are the only producer uses of `text`.
- `Sources/LabanRenderer/MetalRenderer.swift` — the consumer.
  `buildGPUCellPayloadInstanceListsOnce` (line ~2123) iterates
  `payload.glyphs` via unsafe buffer pointers; its entry lookup has a third
  branch `else if let character = glyph.pointee.text.first` and a
  "missingGlyphText" guard that consults `glyph.text`. The failure helper
  `gpuCellPayloadFailurePreview` (line ~2040) also falls back to `glyph.text`.
- Tests constructing glyphs directly: `Tests/LabanRendererTests/GPUCellParityTests.swift`
  (~12 sites incl. two `glyphs[0].text = ""` mutations that invalidate a glyph
  to force a build failure), `Tests/LabanRendererTests/MetalFrameTimingBench.swift`
  (`appendM6Glyph`, payload-builder micro fixtures),
  `Tests/LabanCoreTests/TerminalCellPayloadAllocationBench.swift` (append*Row
  helpers), `Tests/LabanCoreTests/TerminalSurfaceControllerTests.swift` (one
  `glyph.text == ""` assertion), `Tests/LabanCoreTests/GPUCellRetainedRingRegressionTests.swift`.
- `Sources/LabanApp/RenderJournal.swift` only reads `payload.glyphs.count` —
  unaffected.

## Plan of Work

1. In `TerminalCellPayload.swift`, replace `Glyph`'s stored properties with the
   POD layout (`scalarRaw`, `underlineColorRaw`, `utf8Start`, `utf8Length`
   private; the rest public as today minus `text`). Add public computed
   properties `scalarValue: UInt32?`, `underlineColor: UInt32?`,
   `utf8Range: Range<Int>?` (get and set) so existing reads/writes compile
   unchanged. Keep the memberwise-style public init with the same labels and
   defaults, minus `text:`.
2. Add `TerminalCellPayload.appendGlyph(row:col:cluster:...)` — a small
   mutating helper that stores a single-scalar cluster as `scalarValue` and
   anything else into `utf8Bytes` + `utf8Range`, mirroring the producer's
   storage rule. Test fixtures use it for arbitrary cluster text.
3. In `FrameProducer.fillTerminalCellPayload`: delete the `text:` arguments,
   delete the `glyph.text` fallback in `glyphBytes`, and drop the
   `.text = ""` spacer-merge write (the merge already rewrites
   `scalarValue`/`utf8Range`).
4. In `MetalRenderer.buildGPUCellPayloadInstanceListsOnce`: drop the
   `text.first` entry branch and the `text` clause of the "missingGlyphText"
   guard (a glyph is now drawable iff `scalarValue != nil || utf8Range != nil`).
   In `gpuCellPayloadFailurePreview`, drop the `text` fallback.
5. Migrate the test fixture sites: single-scalar sites just delete `text:`;
   cluster sites switch to `appendGlyph(cluster:)` or explicit
   `utf8Bytes`/`utf8Range` storage; the two "make it invalid" mutations clear
   `scalarValue`/`utf8Range` instead of `text`; the `text == ""` assertion is
   deleted.
6. Add a layout test asserting `_isPOD(TerminalCellPayload.Glyph.self)` and
   `MemoryLayout<TerminalCellPayload.Glyph>.stride <= 56`.
7. Run the verification matrix; record numbers here; commit.

## Concrete Steps

From the repository root:

    swift build -c release 2>&1 | tail -5        # expect: Build complete!
    swift test -c release --filter 'FrameProducer|TerminalCellPayload|GPUCellParityTests|TerminalSurfaceController|GPUCellRetainedRing' 2>&1 | tail -5
    LABAN_RUN_PERF_BENCH=1 swift test -c release --filter 'TerminalCellPayloadAllocationBench' 2>&1 | tail -25
    LABAN_RUN_PERF_BENCH=1 swift test -c release --filter 'MetalFrameTimingBench/testGPUCellPayloadBuilderMicrobench' 2>&1 | tail -25
    swift test -c release --filter 'LabanRendererTests' 2>&1 | tail -5

## Validation and Acceptance

- All suites above pass (GPUCellParityTests is the pixel/record parity guard;
  FrameProducerSpanParityTests guards the unrelated Span/legacy glyph-run dual
  path and must stay green to prove no accidental coupling).
- `TerminalCellPayloadAllocationBench.testOneDirtyRowPayloadHasZeroWarmStorageGrowth`
  still reports zero storage growth (POD must not change capacity behavior).
- Fill microbench baseline (case / p50 µs, measured 2026-06-11 on this
  machine at commit 6994626, 160×48): ascii 1 row 1.8, ascii 5 rows 8.6,
  ascii full 81.2, dense colors 10.2, decorated 8.5, hyperlink 20.7,
  wide 18.4. Acceptance: no case regresses >10%; ascii full p50 is expected
  to drop materially (it is append/destroy bound).
- Payload-builder microbench baseline (build path p50 µs, same commit):
  plain 1 row 5.4, full repaint 50.8, fast scroll 50.7. Same acceptance rule.
- The new layout test passes.

## Review Gate

- [ ] Run `rg -n "var text" Sources/LabanRenderer/TerminalCellPayload.swift`; expect zero hits.
- [ ] Run `rg -n "glyph\.text|\.text = " Sources/LabanCore/FrameProducer.swift Sources/LabanRenderer/MetalRenderer.swift`; expect zero hits.
- [ ] Run the five commands in Concrete Steps; expect exit 0 each, with both bench tables printed and no case >10% above the baselines listed in Validation.
- [ ] Run the layout assertion test; expect pass.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Surprises & Discoveries

- Observation: After the POD rewrite, plain-ASCII small fills regressed
  (ascii 5 rows 8.6 → 15.9 µs p50) while heavier cases improved. A
  `sample`-based profile of the bench showed three per-cell costs in the fill
  loop: the `swift_once`-guarded accessors of `FrameProducer`'s `static let`
  raw attribute masks (~15% of samples), the cross-module
  `TextAttributes.subtracting(.gpuCellRenderableMask)` call (~12%), and stray
  `swift_release` (~8%). The POD change itself was innocent — moving the loop
  into the `withUnsafeBufferPointer` closure changed inlining topology so the
  optimizer no longer hoisted those accessors.
  Evidence: `/tmp/ascii-sample.txt` (2026-06-11); hot lines
  `FrameProducer.swift:47-51` (mask accessors) and `:766` (subtracting).
  Fix: masks became instance stored properties (plain loads), the renderable
  check became a raw bitmask test, and `Glyph` accessors/init were annotated
  `@inlinable` / `@inline(__always)`. Result: ascii 5 rows 5.0 µs — faster
  than both the pre-POD and pre-merge baselines.
- Observation: the bench's wide-glyph phase spends most of its time in
  `appendGlyphOrMergeAfterSpacer` allocating `Array(String(scalar).utf8)` per
  spacer merge — a follow-up candidate, out of scope here.
  Evidence: `/tmp/fillbench-sample.txt` (2026-06-11).

## Artifacts and Notes

Fill microbench p50 µs (160×48, release, same machine, 2026-06-11):

    case          pre-plan (6994626)   post-plan
    ascii 1 row          1.8              1.1
    ascii 5 rows         8.6              5.0
    ascii full          81.2             46.5   (p95 153.7 -> 53.1)
    dense colors        10.2              6.3
    decorated            8.5              4.9
    hyperlink           20.7             15.7
    wide glyphs         18.4             13.3

GPU-cell payload builder microbench held: full repaint build 50.8 → 49.0,
fast scroll 50.7 → 49.0, plain rows flat. All suites green: 134
LabanCoreTests (filtered set), 42 GPUCellParityTests, full LabanRendererTests,
FrameProducerSpanParityTests, PayloadGlyphLayoutTests (stride 48, `_isPOD`
true).

## Idempotence and Recovery

Pure refactor of in-repo types; no migrations, no persisted formats
(`Glyph` never crosses a debug endpoint; verify with
`rg -l "TerminalCellPayload" schemas/ Sources/LabanDebug/`, expect no schema
hits). Safe to retry any step; `git checkout -- <file>` reverts. If the
parity suite fails after migration, diff
`classicTerminalGlyphRecordsForTesting` vs `gpuCellGlyphRecordsForTesting` for
the failing fixture — the usual cause is a fixture that previously relied on
stored `text` and now stores neither `scalarValue` nor `utf8Range`.

## Interfaces and Dependencies

End state in `Sources/LabanRenderer/TerminalCellPayload.swift`:

    public struct Glyph: Equatable, Sendable {
      public var row: Int
      public var col: Int
      public var foreground: UInt32
      public var background: UInt32
      public var attributes: TextAttributes
      public var underlineStyle: UnderlineStyle
      public var hasHyperlink: Bool
      public var wide: UInt8
      // private: scalarRaw, underlineColorRaw, utf8Start, utf8Length
      public var scalarValue: UInt32? { get set }      // 0xFFFF_FFFF = none
      public var underlineColor: UInt32? { get set }   // 0 = none
      public var utf8Range: Range<Int>? { get set }    // length 0 = none
      public init(row:col:scalarValue:foreground:background:attributes:
                  underlineStyle:underlineColor:hasHyperlink:wide:utf8Range:)
    }
    extension TerminalCellPayload {
      public mutating func appendGlyph(row:col:cluster:foreground:background:
        attributes:underlineStyle:underlineColor:hasHyperlink:wide:)
    }

No new dependencies. `LabanCore` and `LabanRenderer` keep their existing
target boundary (`TerminalCellPayload` lives in `LabanRenderer`;
`FrameProducer` in `LabanCore` already imports it — no change).
