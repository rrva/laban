import LabanControl
import XCTest

final class ControlUDSClientErrorTests: XCTestCase {
  func testAttachRedeem401ExplainsLazyAttachRecovery() {
    let message = String(describing: ControlUDSClientError.attachRedeemFailed(status: 401))

    XCTAssertTrue(message.contains("direct session attach was rejected"))
    XCTAssertTrue(message.contains("HTTP 401"))
    XCTAssertTrue(message.contains("already-running agent/tool subprocess"))
    XCTAssertTrue(message.contains("lazy attach"))
    XCTAssertTrue(message.contains("laban agent run -- <agent>"))
    XCTAssertFalse(message.contains("attachRedeemFailed(status: 401)"))
  }
}
