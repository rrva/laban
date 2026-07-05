import XCTest

@testable import LabanRenderer

final class DirtyYRangeSetTests: XCTestCase {
  func testDropsNonPositiveHeightBands() {
    let set = DirtyYRangeSet([
      DirtyYRange(y: 10, height: 0),
      DirtyYRange(y: 20, height: -5),
      DirtyYRange(y: 30, height: 5),
    ])
    XCTAssertEqual(set.ranges, [DirtyYRange(y: 30, height: 5)])
  }

  func testSortsBandsByY() {
    let set = DirtyYRangeSet([
      DirtyYRange(y: 30, height: 2),
      DirtyYRange(y: 10, height: 2),
      DirtyYRange(y: 20, height: 2),
    ])
    XCTAssertEqual(set.ranges.map(\.y), [10, 20, 30])
  }

  func testMergesOverlappingBands() {
    let set = DirtyYRangeSet([
      DirtyYRange(y: 0, height: 10),
      DirtyYRange(y: 5, height: 10),
    ])
    XCTAssertEqual(set.ranges, [DirtyYRange(y: 0, height: 15)])
  }

  func testMergesEpsilonAdjacentBands() {
    let set = DirtyYRangeSet([
      DirtyYRange(y: 0, height: 10),
      DirtyYRange(y: 10.00005, height: 10),
    ])
    XCTAssertEqual(set.ranges.count, 1)
    XCTAssertEqual(set.ranges[0].y, 0, accuracy: 1e-9)
    XCTAssertEqual(set.ranges[0].height, 20.00005, accuracy: 1e-9)
  }

  func testKeepsDisjointBandsSeparateWithGapPreserved() {
    let set = DirtyYRangeSet([
      DirtyYRange(y: 0, height: 5),
      DirtyYRange(y: 100, height: 5),
    ])
    XCTAssertEqual(set.ranges, [
      DirtyYRange(y: 0, height: 5),
      DirtyYRange(y: 100, height: 5),
    ])
  }

  func testEmptyInputIsEmpty() {
    XCTAssertTrue(DirtyYRangeSet([]).isEmpty)
    XCTAssertTrue(DirtyYRangeSet([DirtyYRange(y: 1, height: 0)]).isEmpty)
  }

  func testUnionMergesAcrossSets() {
    let a = DirtyYRangeSet([DirtyYRange(y: 0, height: 5)])
    let b = DirtyYRangeSet([DirtyYRange(y: 4, height: 5), DirtyYRange(y: 50, height: 2)])
    let union = a.union(b)
    XCTAssertEqual(union.ranges, [
      DirtyYRange(y: 0, height: 9),
      DirtyYRange(y: 50, height: 2),
    ])
  }

  func testUnionWithEmptyIsIdentity() {
    let a = DirtyYRangeSet([DirtyYRange(y: 0, height: 5)])
    XCTAssertEqual(a.union(DirtyYRangeSet([])), a)
    XCTAssertEqual(DirtyYRangeSet([]).union(a), a)
  }

  func testOverlapsIsExactPerBandNotUnionRange() {
    // Two disjoint bands with a gap between them; a query entirely inside the
    // gap must not report an overlap, proving no min/max collapse happened.
    let set = DirtyYRangeSet([
      DirtyYRange(y: 0, height: 5),
      DirtyYRange(y: 100, height: 5),
    ])
    XCTAssertTrue(set.overlaps(y: 0, height: 5))
    XCTAssertTrue(set.overlaps(y: 3, height: 10))
    XCTAssertTrue(set.overlaps(y: 100, height: 5))
    XCTAssertFalse(set.overlaps(y: 10, height: 80))
    XCTAssertFalse(set.overlaps(y: 5, height: 0))
  }

  func testOverlapsFalseForNonPositiveHeightQuery() {
    let set = DirtyYRangeSet([DirtyYRange(y: 0, height: 100)])
    XCTAssertFalse(set.overlaps(y: 10, height: 0))
    XCTAssertFalse(set.overlaps(y: 10, height: -5))
  }
}
