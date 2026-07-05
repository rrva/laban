import CoreGraphics
import Foundation

/// A normalized, y-space damage set: sorted, non-overlapping `DirtyYRange`
/// bands with positive height, merging bands that overlap or sit within
/// `mergeEpsilon` of each other.
///
/// This is the y-space half of the out-of-repo "Introduce DirtyRowSet
/// Row-Space Damage Primitive" proposal (see
/// `execplans/active/dirty-row-set-damage-primitive.md`), scoped here to
/// `SlugGlyphRenderer`'s per-ring-slot damage accumulation
/// (`execplans/active/slug-render-loop-perf-and-aa-quality.md`, M2). Unlike
/// `MetalRenderer`'s `DamageYBounds`, which collapses all dirty bands into one
/// min/max interval, this type keeps disjoint bands exact: two far-apart
/// dirty rows do not make the rows between them dirty. Renderer-neutral (only
/// `CoreGraphics`/`Foundation`) so other backends or the row-space plan above
/// can adopt it at the `RenderDamage` boundary via `DirtyRowSet.toYRanges(...)`.
public struct DirtyYRangeSet: Equatable, Sendable {
  /// Bands within this many points of touching are merged. Guards against
  /// floating-point seams between adjacent cell rows producing two bands that
  /// should be one.
  private static let mergeEpsilon: CGFloat = 0.0001

  public private(set) var ranges: [DirtyYRange]

  /// Normalizes on construction: drops non-positive-height bands, sorts by
  /// `y`, and merges overlapping or epsilon-adjacent bands.
  public init(_ ranges: [DirtyYRange]) {
    self.ranges = Self.normalize(ranges)
  }

  public var isEmpty: Bool { ranges.isEmpty }

  public func union(_ other: DirtyYRangeSet) -> DirtyYRangeSet {
    if other.isEmpty { return self }
    if isEmpty { return other }
    return DirtyYRangeSet(ranges + other.ranges)
  }

  /// Exact per-band overlap test: a gap between two bands is never reported
  /// as overlapping, even if it sits between them (no min/max collapse).
  /// `false` for non-positive `height`.
  public func overlaps(y: CGFloat, height: CGFloat) -> Bool {
    guard height > 0 else { return false }
    let lo = y
    let hi = y + height
    for range in ranges where range.y < hi && lo < range.y + range.height {
      return true
    }
    return false
  }

  private static func normalize(_ input: [DirtyYRange]) -> [DirtyYRange] {
    let positive = input.filter { $0.height > 0 }
    guard !positive.isEmpty else { return [] }
    let sorted = positive.sorted { $0.y < $1.y }
    var merged: [DirtyYRange] = []
    merged.reserveCapacity(sorted.count)
    for range in sorted {
      if let last = merged.last, range.y <= last.y + last.height + mergeEpsilon {
        let mergedHi = max(last.y + last.height, range.y + range.height)
        merged[merged.count - 1] = DirtyYRange(y: last.y, height: mergedHi - last.y)
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}
