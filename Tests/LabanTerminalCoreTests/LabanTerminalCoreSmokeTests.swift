import LabanTerminalCore
import XCTest

final class LabanTerminalCoreSmokeTests: XCTestCase {
  func testSmokeVersion() {
    let raw = laban_terminal_core_smoke_version()
    XCTAssertNotNil(raw)
    XCTAssertEqual(String(cString: raw!), "laban-terminal-core-smoke")
  }
}
