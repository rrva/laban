import XCTest

@testable import LabanCore

final class ViewportStateTests: XCTestCase {
  func testScrollDeltaToActiveBottomIsZeroAtBottom() {
    XCTAssertEqual(
      ViewportState.scrollDeltaToActiveBottom(
        viewportOffset: 90,
        totalRows: 100,
        viewportRows: 10
      ),
      0
    )
  }

  func testScrollDeltaToActiveBottomMovesForwardFromOlderHistory() {
    XCTAssertEqual(
      ViewportState.scrollDeltaToActiveBottom(
        viewportOffset: 72,
        totalRows: 100,
        viewportRows: 10
      ),
      18
    )
  }

  func testScrollDeltaToActiveBottomIsZeroWhenContentFitsViewport() {
    XCTAssertEqual(
      ViewportState.scrollDeltaToActiveBottom(
        viewportOffset: 0,
        totalRows: 8,
        viewportRows: 20
      ),
      0
    )
  }
}
