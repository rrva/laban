import LabanTerminalCore
import XCTest

final class GhosttyVTLinkTests: XCTestCase {
  func testGhosttyVTLinkSmoke() {
    let result = laban_ghostty_vt_link_smoke()
    XCTAssertEqual(result, 0, "ghostty_terminal_new returned non-zero: \(result)")
  }
}
