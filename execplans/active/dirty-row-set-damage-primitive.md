# Introduce DirtyRowSet Row-Space Damage Primitive

This ExecPlan is a living document maintained in accordance with `PLANS.md` in
the repository root. Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current as work proceeds. This plan is self-contained: a
contributor should be able to start from a clean checkout, read this file, and
complete the change without prior conversation context.

This plan is a refresh of an out-of-repo proposal drafted 2026-06-20 (by
GPT-5.5 Pro). Line references, type names, and coordination points were
re-verified against the tree on 2026-07-05; substantive changes from the
original are recorded in the Decision Log with that date.

## Purpose / Big Picture

Laban already receives precise per-row dirty information from
`LabanSnapshot.dirty_rows` (one byte per visible row), but the Swift side
repeatedly converts that information into unrelated forms: pixel Y bands for
`RenderDamage`, `[Int]` row arrays for `TerminalCellPayload`, laband
`(startRow, endRow)` pairs for the shared-memory snapshot ring, and
diagnostics ranges. The Metal renderer then collapses sparse dirty Y bands
into one union bounding box (`DamageYBounds`,
`Sources/LabanRenderer/MetalRenderer.swift:3501-3521`), losing the fact that
two far-apart dirty rows do not make the clean rows between them dirty.

After this change, the codebase has one canonical Swift representation for
changed terminal rows: `DirtyRowSet`. It stores sorted, coalesced half-open
row ranges in terminal row-space, where row `0` is the top visible terminal
row. Existing user-visible behavior stays the same; internal damage handling
becomes more precise and easier to test. The effect is visible indirectly:
sparse partial frames with dirty rows separated by clean rows must preserve
clean interior rows and must not accumulate anti-aliased glyph edges on the
persistent Metal target (the failure shape documented at
`MetalRenderer.swift:1968`).

This plan does not change the C `LabanSnapshot` ABI or the laband
snapshot-ring ABI. It adds a Swift value type and migrates Swift call sites.

## Relationship to other plans

- `execplans/active/slug-render-loop-perf-and-aa-quality.md` (in flight as of
  2026-07-05) introduces the y-space half of this idea: a normalized
  `DirtyYRangeSet` in `Sources/LabanRenderer/DirtyYRangeSet.swift`, used by
  the Slug renderer's per-band scissoring (its M2). This plan owns the
  row-space half and the cross-layer migration. Coordination rule:
  `DirtyRowSet.toYRanges(...)` produces `[DirtyYRange]`, which feeds
  `DirtyYRangeSet` at the renderer boundary. **Check whether
  `Sources/LabanRenderer/DirtyYRangeSet.swift` exists before starting
  Milestone 5**: if the Slug plan's M2 has landed it, use it as-is; if not,
  create it exactly per the spec in that plan's Interfaces and Dependencies
  section (normalization: drop non-positive heights, sort by `y`,
  epsilon-merge overlapping/adjacent bands with epsilon `0.0001`; `union`;
  `overlaps(y:height:)` exact per band, false for non-positive height;
  imports `CoreGraphics`/`Foundation` only).
- Do not start Milestone 5 while the Slug plan's M2 is actively being executed
  in the same working tree (as of this writing another agent is executing that
  plan); both touch renderer damage plumbing. Milestones 1-4 here are
  independent of it.

## Progress

- [ ] M1: Add `Sources/LabanRenderer/DirtyRowSet.swift` and
      `Tests/LabanRendererTests/DirtyRowSetTests.swift`.
- [ ] M2: Migrate `TerminalSurfaceController` damage/payload/diagnostics
      derivation to `DirtyRowSet`.
- [ ] M3: Migrate laband snapshot-ring dirty-range serialization to
      `DirtyRowSet` (ABI unchanged).
- [ ] M4: Make `TerminalCellPayload`/`FrameProducer` hot paths row-set based
      with `dirtyRows: [Int]` kept as a compatibility computed property.
- [ ] M5: Replace `MetalRenderer.DamageYBounds` union filtering with exact
      `DirtyYRangeSet` overlap and patch-row logic.
- [ ] Run the validation matrix and record results in Artifacts and Notes.
- [ ] Pass the Review Gate.

## Decision Log

Decisions carried over from the 2026-06-20 original (rationales re-verified):

- Decision: Put `DirtyRowSet` in the `LabanRenderer` target, not `LabanCore`.
  Rationale: `RenderDamage`, `DirtyYRange`, and `TerminalCellPayload` live in
  `Sources/LabanRenderer`, and `LabanCore` depends on `LabanRenderer`
  (verified in `Package.swift`: target `LabanCore` lists `LabanRenderer` in
  its dependencies). The reverse placement would create a cycle.
  `DirtyRowSet` must not import `LabanCore`.
  Date/Author: 2026-06-20 / GPT-5.5 Pro; re-verified 2026-07-05.
- Decision: Keep the C snapshot ABI and laband ring ABI unchanged.
  Rationale: `dirty_rows` (one byte per row) and the ring's
  `(startRow, endRow)` pairs already carry the information; `DirtyRowSet` is
  a Swift canonicalization layer over them. ABI changes would need separate
  versioning work.
  Date/Author: 2026-06-20 / GPT-5.5 Pro.
- Decision: Keep `RenderDamage.partial(yRanges:)` as the public renderer
  damage contract; convert via `DirtyRowSet.toYRanges(...)` at the boundary.
  Rationale: adding a `partialRows` case would force all renderers and tests
  to switch at once. A later plan can make `RenderDamage` row-aware. (The
  empty-`yRanges` "nothing changed, re-present" semantics documented in
  `RendererBackend.swift` must be preserved exactly.)
  Date/Author: 2026-06-20 / GPT-5.5 Pro.
- Decision: Preserve conservative full-damage semantics for unknown or
  ambiguous damage: missing mask, undersized mask, globally dirty snapshot
  with zero row bits, or empty laband dirty-range list all mean `.full`.
  `DirtyRowSet.empty(rowCount:)` means "known clean", never "unknown";
  unknown stays `nil` at parsing seams.
  Date/Author: 2026-06-20 / GPT-5.5 Pro.
- Decision: `TerminalCellPayload.dirtyRowSet` becomes the hot-path source of
  truth; `dirtyRows: [Int]` survives only as a compatibility computed
  property.
  Date/Author: 2026-06-20 / GPT-5.5 Pro.

Decisions made in this 2026-07-05 refresh:

- Decision: Use `Range<Int>` for `DirtyRowSet.ranges` instead of the
  original's new `DirtyRowRange` struct.
  Rationale: `TerminalSurfaceFrameDiagnostics.DirtyRowRange` already exists
  (`Sources/LabanCore/TerminalSurfaceController.swift:178`, Codable), so a
  top-level `DirtyRowRange` in `LabanRenderer` would collide at import sites.
  `Range<Int>` is `Equatable`, `Sendable`, `Codable`, and already half-open;
  a dedicated struct adds nothing. Diagnostics mapping constructs the nested
  diagnostics type from `lowerBound`/`upperBound`.
  Date/Author: 2026-07-05 / plan refresh.
- Decision: `DirtyYRangeSet` is owned by the Slug plan, not duplicated here.
  Milestone 5 consumes it (creating it per that plan's spec only if it does
  not yet exist).
  Rationale: two plans defining the same public type is a merge hazard; the
  Slug plan's M2 needs it first chronologically.
  Date/Author: 2026-07-05 / plan refresh.
- Decision: Milestone 4 must preserve byte-identical output between
  `FrameProducer`'s macOS-26 Span/UTF8Span fast path and its legacy fallback.
  Rationale: the glyph pass has two parallel implementations that are pinned
  byte-identical by `Tests/LabanCoreTests/FrameProducerSpanParityTests.swift`;
  any `forEachRow`-based restructuring must be applied to both paths and that
  test must stay green.
  Date/Author: 2026-07-05 / plan refresh.

## Context and Orientation

Build and test from the repository root. SwiftPM macOS project; relevant
targets:

- `LabanTerminalCore`: C wrapper around libghostty snapshots.
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h` defines
  `LabanSnapshot` with `dirty`, `rows`, `dirty_rows`, `dirty_row_count`.
- `LabanRenderer`: renderer-neutral command/payload types plus backends.
  `Sources/LabanRenderer/RendererBackend.swift` (defines `RenderDamage.full`,
  `RenderDamage.partial(yRanges: [DirtyYRange])`, `DirtyYRange(y:height:)`),
  `Sources/LabanRenderer/TerminalCellPayload.swift`,
  `Sources/LabanRenderer/MetalRenderer.swift`.
- `LabanCore`: session/model/frame production.
  `Sources/LabanCore/TerminalSurfaceController.swift`,
  `Sources/LabanCore/FrameProducer.swift`,
  `Sources/LabanCore/LabandSnapshotRingLayout.swift`.

Definitions:

- **Dirty row**: a terminal row whose visible content may have changed since
  the previous committed frame. Rows are top-down: row `0` is the top visible
  row.
- **Half-open range**: `start..<end` includes `start`, excludes `end`.
- **Normalized range set**: sorted, no empty ranges, no overlap, no adjacent
  ranges left unmerged. `[3..<4, 1..<3, 4..<5]` normalizes to `[1..<5]`.
- **Y range**: a vertical band in Core Graphics points, **y-up from the
  surface bottom** (rows are top-down, so conversion flips).
- **Persistent target**: MetalRenderer's offscreen texture that survives
  across frames; partial damage loads it and redraws only dirty regions.
- **Union bounding box**: one interval from lowest to highest dirty Y. If
  rows 1 and 9 are dirty, the union covers clean rows 2-8 too. This is the
  precision loss this plan removes for logical row operations.

Current code to read before editing (line numbers verified 2026-07-05):

- `Sources/LabanCore/TerminalSurfaceController.swift` scans
  `snapshot.dirty_rows` in four places:
  - `damage(snapshot:forceFull:cellHeight:originY:)` at `:939` emits
    `DirtyYRange` values from a byte scan.
  - `payloadRows(...)` at `:975` and `fillPayloadRows(...)` at `:984` scan
    again and materialize `[Int]` rows (a reusable buffer
    `reusablePayloadRows` at `:363` is filled at `:678` and passed as
    `includedRows` at `:682`).
  - `damage(rows:dirtyRanges:forceFull:cellHeight:originY:)` at `:1014`
    converts remote laband row ranges to Y ranges separately.
  - `dirtyRowsSummary(...)` at `:1125` scans a fourth time for diagnostics;
    `ambiguousDirtyNoRows` is computed at `:1086` (snapshot path) and `:1121`
    (remote path).
- `Sources/LabanCore/LabandSnapshotRingLayout.swift`:
  `writeDirtyRanges(slot:snapshot:rows:)` at `:518`,
  `readDirtyRanges(slot:rows:)` at `:825`.
- `Sources/LabanRenderer/TerminalCellPayload.swift`: stored
  `public var dirtyRows: [Int]` at `:150`, initializer label at `:167`,
  `CapacitySnapshot.dirtyRows` at `:209` reporting `dirtyRows.capacity` at
  `:219`.
- `Sources/LabanCore/FrameProducer.swift`:
  `terminalCellPayload(from:includedRows:...)` at `:602` (array label at
  `:604`), `fillTerminalCellPayload(into:from:includedRows:...)` at `:726`.
  Both feed the dual Span/legacy glyph-pass implementations pinned by
  `FrameProducerSpanParityTests`.
- `Sources/LabanRenderer/MetalRenderer.swift`:
  - `DamageYBounds` struct at `:3501`, `damageYBounds(_:)` at `:3511` —
    collapses all dirty Y ranges into one min/max interval.
  - Gate flag `useClassicDamageScoped` at `:98`; `damageBounds` locals built
    at `:2222`, `:2460`, `:3196`; overlap filtering via `damageBounds` in
    `appendSolid`-style paths at `:2501`/`:3233`-ish call sites.
  - `rowsToPatch(for:geometry:)` at `:2359` derives patch rows from the
    union interval; used at `:3270`.
  - `scissorRectFromYRanges(_:)` at `:2192` (used at `:1715`, `:1892`, and
    per-range at `:1987`/`:2002` in the GPU-cell glyph pass).
  - The comment near `:1968` documents the failure shape: redrawing clean
    rows under a union scissor re-composites anti-aliased glyph edges onto
    the loaded persistent target every frame, and text slowly accumulates
    weight.
  - Test hooks: `cellGlyphUploadRangesForTesting` at `:558`,
    `rebuildInstancesForTesting` at `:564`,
    `rebuildGPUCellInstancesForTesting` at `:573`.
  - `payloadFillsAllIncludedRows` / `payloadFillsEntireGrid` at `:2517-2520`
    read `payload.dirtyRows.count`.

## Interfaces and Dependencies

No third-party dependencies. Swift standard library, `Foundation`,
`CoreGraphics` only in the renderer target.

Create `Sources/LabanRenderer/DirtyRowSet.swift`:

```swift
import CoreGraphics
import Foundation

public struct DirtyRowSet: Equatable, Sendable, Codable {
  public let rowCount: Int
  public private(set) var ranges: [Range<Int>]  // normalized, half-open, top-down

  public var isEmpty: Bool { ranges.isEmpty }
  public var dirtyCount: Int { ranges.reduce(0) { $0 + $1.count } }
  public var isFull: Bool { ranges.count == 1 && ranges[0] == 0..<rowCount }

  public static func empty(rowCount: Int) -> DirtyRowSet
  public static func full(rowCount: Int) -> DirtyRowSet
  public init(rowCount: Int, ranges: [Range<Int>])   // clamps + normalizes
  public init(rowCount: Int, rows: [Int])            // dedups + sorts + coalesces

  /// nil when rowCount <= 0, dirtyRows == nil, or dirtyRowCount < rowCount.
  /// Never reads past dirtyRowCount. nil means "unknown", not "clean".
  public static func fromDirtyBytes(
    rowCount: Int,
    dirtyRowCount: Int,
    dirtyRows: UnsafePointer<UInt8>?
  ) -> DirtyRowSet?

  public func contains(_ row: Int) -> Bool
  public func intersects(_ range: Range<Int>) -> Bool
  public func union(_ other: DirtyRowSet) -> DirtyRowSet
  public func intersection(_ other: DirtyRowSet) -> DirtyRowSet
  public func subtracting(_ other: DirtyRowSet) -> DirtyRowSet
  public func forEachRow(_ body: (Int) -> Void)
  public func toRows() -> [Int]
  public func appendRows(into result: inout [Int])
  public func toYRanges(cellHeight: CGFloat, originY: CGFloat) -> [DirtyYRange]
  public func bottomUpCellIndexRanges(cols: Int) -> [Range<Int>]
}
```

Implementation rules:

- Normalization: clamp bounds into `0...rowCount`, drop empty ranges, sort by
  `lowerBound`, merge overlapping or adjacent (`next.lowerBound <=
  previous.upperBound`) ranges.
- `toYRanges(cellHeight:originY:)` flips top-down rows to bottom-up Y:

  ```swift
  let y = originY + CGFloat(rowCount - range.upperBound) * cellHeight
  let height = CGFloat(range.count) * cellHeight
  ```

- `bottomUpCellIndexRanges(cols:)`: top-down `start..<end` maps to bottom-up
  row interval `(rowCount - end)..<(rowCount - start)`, then to cell indices
  `bottomStart * cols ..< bottomEnd * cols`; result sorted and coalesced.
- Set algebra operands must share `rowCount`; `precondition` on mismatch.
- Linear scans are fine; viewports have tens to hundreds of rows.

`DirtyYRangeSet` (Milestone 5 only): consume
`Sources/LabanRenderer/DirtyYRangeSet.swift` if the Slug plan has landed it;
otherwise create it per that plan's spec (see Relationship to other plans).

## Plan of Work

### Milestone 1 — Add and test the value type

Create `Sources/LabanRenderer/DirtyRowSet.swift` per Interfaces and
Dependencies. Add `Tests/LabanRendererTests/DirtyRowSetTests.swift`:

1. `testNormalizesClampsSortsAndCoalescesRanges`: rowCount 8, ranges
   `5..<6, 1..<3, 3..<5, (-4)..<1, 7..<20, 4..<4` (construct pre-clamp inputs
   as `(Int, Int)` pairs if `Range` traps on negative literals) → `0..<6`,
   `7..<8`.
2. `testRowsInitializerDeduplicatesAndSorts`: rows `[4, 1, 4, 2, -1, 99]`,
   rowCount 6 → `1..<3`, `4..<5`.
3. `testDirtyBytesParsingBuildsRanges`: bytes `[0,1,1,0,1]`, rowCount 5 →
   `1..<3`, `4..<5`.
4. `testDirtyBytesParsingRejectsUnknownOrUndersizedMasks`: nil pointer → nil;
   `dirtyRowCount < rowCount` → nil.
5. `testTopDownRowsMapToBottomUpYRanges`: rowCount 4, range `1..<3`,
   cellHeight 5, originY 10 → `DirtyYRange(y: 15, height: 10)`.
6. `testBottomUpCellIndexRangesSortAndCoalesce`: rowCount 8, cols 10,
   ranges `1..<3`, `5..<6` → `20..<30`, `50..<70`.
7. `testSetAlgebra`: union/intersection/subtracting including
   adjacent-range coalescing.

Validation: `swift test -c release --filter DirtyRowSetTests` — all pass.

### Milestone 2 — Migrate snapshot and remote damage conversion

In `Sources/LabanCore/TerminalSurfaceController.swift`, add private bridging
helpers near the damage helpers (`:939` region):

```swift
private static func dirtyRowSet(snapshot: LabanSnapshot) -> DirtyRowSet? {
  DirtyRowSet.fromDirtyBytes(
    rowCount: Int(snapshot.rows),
    dirtyRowCount: Int(snapshot.dirty_row_count),
    dirtyRows: snapshot.dirty_rows)
}

private static func dirtyRowSet(
  rows: Int, dirtyRanges: [LabandSnapshotDirtyRange]?
) -> DirtyRowSet? {
  guard rows > 0, let dirtyRanges else { return nil }
  return DirtyRowSet(
    rowCount: rows, ranges: dirtyRanges.map { $0.startRow..<$0.endRow })
}
```

(If `LabandSnapshotDirtyRange` bounds can be negative or inverted, map via
clamping before forming `Range` to avoid a trap; check its producer first.)

Update `damage(snapshot:forceFull:cellHeight:originY:)` (`:939`): keep the
`forceFull` early return; parse once; nil → `.full`; empty set with
`snapshot.dirty != 0` → `.full`; `isFull` → `.full`; else
`.partial(yRanges: set.toYRanges(...))`.

Update `payloadRows`/`fillPayloadRows` (`:975`/`:984`): `.full` → append all
rows via `DirtyRowSet.full(rowCount:).appendRows(into:)`; `.partial` → parsed
set's rows; parse failure on partial → all rows (current conservative
fallback).

Update `damage(rows:dirtyRanges:...)` (`:1014`): through `DirtyRowSet`; nil
or empty → `.full`; full → `.full`; else partial.

Update diagnostics (`:1081` region): replace the `dirtyRowsSummary` scan;
`dirtyRowsSetCount = set?.dirtyCount ?? 0`; `dirtyRowRanges = set?.ranges.map
{ TerminalSurfaceFrameDiagnostics.DirtyRowRange(startRow: $0.lowerBound,
endRow: $0.upperBound) } ?? []`; preserve `dirtyRowCount:
Int(snapshot.dirty_row_count)` (it reports mask length) and the
`ambiguousDirtyNoRows` expressions at `:1086`/`:1121` semantically unchanged.
Delete the now-unused `dirtyRowsSummary` (`:1125`).

Tests (`Tests/LabanCoreTests/TerminalSurfaceControllerTests.swift`): keep
`testDirtyRowDamageMapsTopDownRowsToBottomUpYRanges` (`:1028`) and
`testGloballyDirtySnapshotWithNoRowBitsForcesFullDamage` (`:1048`) passing
with unchanged expectations. Add:

- `testDirtyRowDamageNormalizesSeparatedBandsWithoutUnioningThem`: bytes
  `[1,0,0,1]`, rows 4, cellHeight 5, originY 10 → two bands, e.g.
  `[DirtyYRange(y: 25, height: 5), DirtyYRange(y: 10, height: 5)]` in
  top-down emission order; if the implementation sorts by Y, assert that
  order consistently and document it.
- `testRemoteDirtyRangesAreClampedAndCoalesced`: ranges `(-2,1), (1,3),
  (7,9)`, rows 8 → normalized `0..<3`, `7..<8`, mapped to Y ranges.

Validation: `swift test -c release --filter TerminalSurfaceControllerTests`.

### Milestone 3 — Migrate laband snapshot-ring dirty-range serialization

In `Sources/LabanCore/LabandSnapshotRingLayout.swift`:

`writeDirtyRanges(slot:snapshot:rows:)` (`:518`): build the set first; if
parse fails or the set is empty, serialize one full range `0..<rows`
(current conservative behavior); otherwise serialize `set.ranges` into the
existing slot layout. Preserve the existing maximum of `rows` serialized
ranges; if more ranges than fit, serialize one full range rather than
truncating (truncation under-reports dirt).

`readDirtyRanges(slot:rows:)` (`:825`): keep the per-range ABI validation
(reject the slot with nil on `start >= end`, `start < 0`, `end > rows`);
normalize the surviving raw ranges through `DirtyRowSet(rowCount:ranges:)`;
nil when the normalized set is empty, else `LabandSnapshotDirtyRange` values
from `set.ranges`.

Tests: extend `Tests/LabanCoreTests/LabandSnapshotRingReaderFuzzTests.swift`
or add `LabandSnapshotRingDirtyRangeTests.swift`:

1. Two separated dirty byte runs publish two ranges (after the forced-full
   attach frame).
2. No row bits still publishes a full range.
3. A manually mutated slot with overlapping/adjacent ranges reads back
   normalized.
4. A manually mutated invalid range is rejected or reported as full fallback
   without crashing; existing fuzz tests stay as-is.

Validation:
`swift test -c release --filter 'LabandSnapshotRing|LabandControlProtocolTests'`.

### Milestone 4 — Make TerminalCellPayload row-damage row-set based

In `Sources/LabanRenderer/TerminalCellPayload.swift`:

1. Replace stored `dirtyRows: [Int]` (`:150`) with stored
   `public var dirtyRowSet: DirtyRowSet`.
2. Compatibility property:

   ```swift
   public var dirtyRows: [Int] {
     get { dirtyRowSet.toRows() }
     set { dirtyRowSet = DirtyRowSet(rowCount: rows, rows: newValue) }
   }
   ```

3. Keep the `dirtyRows: [Int] = []` initializer label (`:167`) initializing
   the set; add a `dirtyRowSet:`-labeled initializer for hot paths.
4. `reset(...)` sets `dirtyRowSet = .empty(rowCount: rows)`.
5. `CapacitySnapshot.dirtyRows` (`:209`) becomes
   `dirtyRowSet.ranges.capacity` with a comment that it now tracks range
   storage; keep the field name so benchmark output names do not change in
   this changeset.

In `Sources/LabanCore/FrameProducer.swift`: add
`includedRows: DirtyRowSet` overloads of `terminalCellPayload` (`:602`) and
`fillTerminalCellPayload` (`:726`); keep the `[Int]` overloads as wrappers
constructing `DirtyRowSet(rowCount: Int(snap.pointee.rows), rows:)`. In the
set overloads: assign `payload.dirtyRowSet` (clamped to snapshot rows) after
`reset`, reserve capacity from `dirtyCount`, scan rows via `forEachRow`.
**Constraint: the Span/UTF8Span fast path and the legacy fallback must both
receive the same restructuring and stay byte-identical;
`swift test --filter FrameProducerSpanParityTests` is a gate for this
milestone.**

In `Sources/LabanCore/TerminalSurfaceController.swift`: in the
`cellPayloadPreferred` path (`:678` region), compute the `DirtyRowSet` once
from snapshot + damage decision and pass it directly; drop
`reusablePayloadRows` (`:363`) if nothing else uses it. `.full` damage passes
`.full(rowCount:)`; unparseable partial passes `.full(rowCount:)`.

In `Sources/LabanRenderer/MetalRenderer.swift`: replace hot-path
`payload.dirtyRows` reads with the set —
`payloadFillsAllIncludedRows` (`:2517`) uses
`payload.dirtyRowSet.dirtyCount * geometry.cols`; `payloadFillsEntireGrid`
(`:2519`) uses `payload.dirtyRowSet.isFull`; row loops use `forEachRow`;
retained cell upload ranges may use
`bottomUpCellIndexRanges(cols: geometry.cols)`.

Validation:

```sh
swift test -c release --filter 'FrameProducer|TerminalCellPayload|TerminalSurfaceController|GPUCellRetainedRingRegressionTests|GPUCellParityTests'
```

`FrameProducerSpanParityTests` must be in the passing set. Metal-dependent
tests must pass on a Metal-capable machine before merge.

### Milestone 5 — Replace union damage filtering in MetalRenderer

Precondition: `Sources/LabanRenderer/DirtyYRangeSet.swift` exists (see
Relationship to other plans), and the Slug plan's M2 is not concurrently
editing renderer damage plumbing in this tree.

In `Sources/LabanRenderer/MetalRenderer.swift`:

1. Delete `DamageYBounds` (`:3501`) and `damageYBounds(_:)` (`:3511`).
2. Add:

   ```swift
   private static func dirtyYRangeSet(_ damage: RenderDamage) -> DirtyYRangeSet? {
     guard case .partial(let ranges) = damage else { return nil }
     let set = DirtyYRangeSet(ranges)
     return set.isEmpty ? nil : set
   }
   ```

3. Rename `damageBounds` locals (`:2222`, `:2460`, `:3196`) to
   `damageRanges`; keep the `useClassicDamageScoped` (`:98`) gating exactly
   as-is.
4. Overlap filtering switches from the union's `overlaps(y:height:)` to the
   set's exact per-band `overlaps(y:height:)` (same call shape).
5. Rewrite `rowsToPatch` (`:2359`) to mark rows from each exact band (same
   row math the old helper applied to the union, applied per band); no
   global min/max first.
6. Keep `scissorRectFromYRanges(_:)` (`:2192`) unchanged: the render-pass
   scissor may stay a union in this plan. The purpose here is exact
   *logical* row/instance filtering; the GPU-cell glyph pass already
   iterates exact ranges (`:1987`/`:2002`). (The Slug plan demonstrates
   per-band scissor loops if a follow-up wants them for MetalRenderer.)

Tests (`Tests/LabanRendererTests/GPUCellParityTests.swift`):

- `testGPUCellCommandPathPatchesExactSparseDirtyRows`: via
  `rebuildGPUCellInstancesForTesting` (`:573`), build a frame with rows 1
  and 6 dirty and a gap between; after a full build, run a partial build
  with damage for only those rows; assert
  `cellGlyphUploadRangesForTesting` (`:558`) contains only the bottom-up
  cell ranges for rows 1 and 6, not the interval between.
- A classic-path instance-count test through `rebuildInstancesForTesting`
  (`:564`) with three separated dirty rows and damage for the first and
  last: middle-row instances are absent. If full-terminal background
  commands make this unobservable, record the limitation in Surprises &
  Discoveries and rely on the GPU-cell test plus pixel parity.

Validation: `swift test -c release --filter GPUCellParityTests` (no new
skips on a Metal-capable machine).

## Concrete Steps

From the repository root, one milestone per commit, in order M1 to M5. Each
step: edit the files listed for that milestone, run that milestone's
validation command, commit only when green. Final matrix:

```sh
swift test -c release --filter 'DirtyRowSetTests|TerminalSurfaceControllerTests|LabandSnapshotRing|LabandControlProtocolTests|GPUCellParityTests|GPUCellRetainedRingRegressionTests|FrameProducerSpanParityTests'
./scripts/build-app --profile
```

Optional perf sanity (Metal-capable machine, release):

```sh
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter TerminalCellPayloadAllocationBench
LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench
```

Record before/after p50/p95 for the one-dirty-row payload fill path in
Artifacts and Notes; if numbers regress, do not hide them — decide whether to
keep M4 or split it out.

## Validation and Acceptance

Accepted when all of the following hold:

1. `DirtyRowSetTests` prove the algebra (mask parsing, normalization,
   bottom-up Y conversion, cell-index ranges, set operations).
2. `TerminalSurfaceControllerTests` prove damage semantics are preserved
   (top-down to bottom-up mapping unchanged; globally-dirty-no-bits still
   forces `.full`; remote ranges normalized; separated bands stay separate).
3. Laband ring tests prove ABI compatibility (same slot layout, forced-full
   first attach frame, malformed ranges rejected without crashing,
   empty/unknown masks still conservative-full).
4. Renderer tests prove sparse damage stays sparse logically (no retained
   cell uploads for clean rows between dirty rows; pixel parity unchanged).
5. `FrameProducerSpanParityTests` passes (Span and legacy paths still
   byte-identical).
6. `./scripts/build-app --profile` succeeds.

## Review Gate

A separate fresh-state reviewer must perform these checks before this plan is
considered complete. The executing agent must not mark the plan done until
this gate passes.

- [ ] `test -f Sources/LabanRenderer/DirtyRowSet.swift`; exit 0.
- [ ] `rg -n "struct DirtyRowSet" Sources/LabanRenderer/DirtyRowSet.swift`;
      exactly one definition, and
      `rg -n "struct DirtyRowRange" Sources/LabanRenderer/` returns zero
      hits (refresh decision: `Range<Int>`, no new range struct).
- [ ] `rg -n "private static func dirtyRowsSummary" Sources/LabanCore/TerminalSurfaceController.swift`;
      zero matches.
- [ ] `rg -n "DamageYBounds|damageYBounds" Sources/LabanRenderer/MetalRenderer.swift`;
      zero matches.
- [ ] `rg -n "dirtyRowSet" Sources/LabanRenderer/TerminalCellPayload.swift Sources/LabanCore/FrameProducer.swift Sources/LabanRenderer/MetalRenderer.swift`;
      matches in all three files.
- [ ] `swift test -c release --filter DirtyRowSetTests`; success.
- [ ] `swift test -c release --filter TerminalSurfaceControllerTests`;
      success.
- [ ] `swift test -c release --filter 'LabandSnapshotRing|LabandControlProtocolTests'`;
      success.
- [ ] `swift test -c release --filter FrameProducerSpanParityTests`; success.
- [ ] `swift test -c release --filter GPUCellParityTests`; success on a
      Metal-capable machine (record skip reasons otherwise and require a
      Metal-capable run before merge).
- [ ] `./scripts/build-app --profile`; success.

Review status: NOT REVIEWED

## Idempotence and Recovery

All changes are ordinary source edits and test additions, applied one
milestone per commit in the order M1 to M5. Reverting a failed milestone's
commit leaves earlier milestones intact. No migration writes user data,
changes fixture formats, or changes the C/laband binary ABI. If benchmarks
regress after M4, keep M1-M3 and split M4-M5 into a follow-up. If M5's
precondition is blocked (Slug plan mid-flight in the same tree), stop after
M4; the plan remains coherent.

## Artifacts and Notes

Record validation output here as work proceeds; keep snippets short. For perf
benches record hardware, OS version, commit SHA, command, and p50/p95. Do not
compare debug-build numbers.
